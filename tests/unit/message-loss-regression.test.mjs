/**
 * [fix 2026-10-14] 消息丢失回归测试（对应现网事故：会话 05d6c00d 的投影缓存
 * 停在 seq 723、事件日志已到 794，最新一问一答被 getSessionHistory 的
 * throughSeq=投影水位线整轮切掉，手机上"少了一问一答"）。
 *
 * 覆盖四个修复：
 *   1. probeSessionCursor：past-cursor 拒绝解析出权威 cursor（探测成功时
 *      返回 MAX_SAFE_INTEGER）。
 *   2. 纯工具/空文本 assistant 回合生成占位宿主消息（工具不再被丢弃）。
 *   3. 纯附件/空文本用户消息触发 auditDropped 留痕。
 *   4. carried-context 过滤命中时触发 auditDropped 留痕。
 *
 * 全部合成数据；不触碰 ~/.dsh。
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

import {
  probeSessionCursor,
  convertSessionRecordsToMessages
} from '../../dsh-server-plugin/lib/features.mjs';

/* ------------------------------------------------------------------ *
 * 1. probeSessionCursor — the fix for the projcache-watermark truncation
 * ------------------------------------------------------------------ */

describe('probeSessionCursor', () => {
  it('parses the authoritative cursor out of a past-cursor rejection', async () => {
    // 事故形状：日志真实 cursor=794，任何大于它的 throughSeq 都被拒绝。
    const callDshRpc = async (method, payload) => {
      assert.equal(method, 'session/page');
      if (payload.args.request.throughSeq === Number.MAX_SAFE_INTEGER) {
        throw new Error('typert gateway: session/page: gateway/bad-request: session page through seq 9007199254740991 is past cursor 794');
      }
      return { records: [], hasMore: false };
    };
    assert.equal(await probeSessionCursor({ callDshRpc, sessionId: 'session-x' }), 794);
  });

  it('returns MAX_SAFE_INTEGER when the engine accepts the probe', async () => {
    const callDshRpc = async () => ({ records: [], hasMore: false });
    assert.equal(await probeSessionCursor({ callDshRpc, sessionId: 'session-x' }), Number.MAX_SAFE_INTEGER);
  });

  it('returns null on an unparseable error so callers keep their fallback', async () => {
    const callDshRpc = async () => { throw new Error('totally different failure'); };
    assert.equal(await probeSessionCursor({ callDshRpc, sessionId: 'session-x' }), null);
  });

  it('degrades to null without a session id or rpc function', async () => {
    assert.equal(await probeSessionCursor({ callDshRpc: null, sessionId: 'session-x' }), null);
    assert.equal(await probeSessionCursor({ callDshRpc: async () => ({}), sessionId: '' }), null);
  });
});

/* ------------------------------------------------------------------ *
 * 2. empty assistant/message hosts tools instead of dropping the turn
 * ------------------------------------------------------------------ */

describe('convertSessionRecordsToMessages: tool-only assistant turns', () => {
  it('creates a placeholder assistant host so tool calls are not silently lost', () => {
    const records = [
      { event: { type: 'user/message', seq: 10, time: 1000, data: { content: [{ type: 'text', text: '查一下' }] } } },
      // 空文本 assistant/message（事故形状：seq 753/764 TEXT= 空）
      { event: { type: 'assistant/message', seq: 11, time: 2000, data: { message: { content: [] } } } },
      { event: { type: 'tool/call', seq: 12, time: 2100, data: { name: 'db_query', arguments: { sql: 'SELECT 1' }, callId: 'c1' } } },
      { event: { type: 'assistant/message', seq: 13, time: 3000, data: { message: { content: [{ type: 'text', text: '结果如下' }] } } } }
    ];
    const { messages } = convertSessionRecordsToMessages(records);
    // 注意：占位 host 已存在时，后续正文 segment 按"连续 assistant 合并"语义
    // 追加进同一宿主 —— user + host(占位+工具+正文) 共 2 条。
    assert.equal(messages.length, 2, 'user + assistant host (placeholder then merged text)');
    assert.equal(messages[1].role, 'assistant');
    assert.equal(messages[1].content, '结果如下', 'later text segment merges into the placeholder host');
    assert.equal(messages[1].tools.length, 1, 'the tool call survived on the placeholder host');
    assert.equal(messages[1].tools[0].name, 'db_query');
  });

  it('appends later empty segments to the existing host instead of new placeholders', () => {
    const records = [
      { event: { type: 'assistant/message', seq: 1, data: { message: { content: [{ type: 'text', text: 'A' }] } } } },
      { event: { type: 'assistant/message', seq: 2, data: { message: { content: [] } } } },
      { event: { type: 'tool/call', seq: 3, data: { name: 't', arguments: {}, callId: 'c' } } }
    ];
    const { messages } = convertSessionRecordsToMessages(records);
    assert.equal(messages.length, 1, 'no extra placeholder after an existing host');
    assert.equal(messages[0].tools.length, 1);
  });
});

describe('消息稳定身份与跨端同步', () => {
  it('真人消息透出引擎 requestId，且重复发送的 retry 能关联同一身份', () => {
    const records = [
      { event: { type: 'user/message', seq: 10, time: 1000, data: {
        source: { kind: 'user', rpcId: 'request-1' },
        content: [{ type: 'text', text: '查一下' }]
      } } },
      { event: { type: 'user/message', seq: 20, time: 2000, data: {
        source: { kind: 'user', rpcId: 'request-2' },
        content: [{ type: 'text', text: '查一下' }]
      } } }
    ];
    const { messages } = convertSessionRecordsToMessages(records);
    assert.deepEqual(messages.map((m) => m.rpcId), ['request-1', 'request-2']);
  });

  it('远端回合也有稳定提示词身份，历史到达后不靠时间戳制造副本', () => {
    const { messages } = convertSessionRecordsToMessages([
      { event: { type: 'user/message', seq: 30, time: 3000, data: {
        source: { kind: 'user', rpcId: 'request-web' },
        content: [{ type: 'text', text: 'Web 发起' }]
      } } }
    ]);
    assert.equal(messages[0].id, 'hist_30');
    assert.equal(messages[0].rpcId, 'request-web');
  });
});

/* ------------------------------------------------------------------ *
 * 3+4. auditDropped — silent drops become observable
 * ------------------------------------------------------------------ */

describe('convertSessionRecordsToMessages: auditDropped', () => {
  it('reports carried-context filtered user messages with their seq', () => {
    const dropped = [];
    const records = [
      { event: { type: 'user/message', seq: 730, data: { content: 'Contents of foo.txt: ...' } } },
      { event: { type: 'user/message', seq: 731, data: { content: '真问题' } } }
    ];
    const { messages } = convertSessionRecordsToMessages(records, {
      auditDropped: (info) => dropped.push(info)
    });
    assert.equal(messages.length, 1);
    assert.equal(dropped.length, 1);
    assert.equal(dropped[0].seq, 730);
    assert.equal(dropped[0].why, 'carried-context');
  });

  it('reports empty/attachment-only user messages', () => {
    const dropped = [];
    const records = [
      { event: { type: 'user/message', seq: 42, data: { content: [{ type: 'image', mediaType: 'image/png' }] } } }
    ];
    const { messages } = convertSessionRecordsToMessages(records, {
      auditDropped: (info) => dropped.push(info)
    });
    assert.equal(messages.length, 0);
    assert.equal(dropped.length, 1);
    assert.equal(dropped[0].seq, 42);
    assert.equal(dropped[0].why, 'empty-user-text');
  });

  it('does not call the callback when nothing is dropped', () => {
    const dropped = [];
    const records = [
      { event: { type: 'user/message', seq: 1, data: { content: '普通问题' } } }
    ];
    convertSessionRecordsToMessages(records, { auditDropped: (info) => dropped.push(info) });
    assert.equal(dropped.length, 0);
  });
});
