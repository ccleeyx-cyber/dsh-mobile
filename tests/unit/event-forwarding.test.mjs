/**
 * Event forwarding: user-questions / todo / attachments (patch 0003).
 *
 * Boots the real Cordis entry against a throwaway DSH_HOME, exactly like
 * archived-filter.test.mjs, and never touches the live ~/.dsh.
 *
 * The fake engine stands up BOTH halves of the channel the gateway uses:
 *   - a WebSocket upgrade on /api/remote.mux, so item frames can be injected
 *     the same way api-gateway's pump() emits them in production;
 *   - a plain HTTP handler for POST /api/$events/result, so the answer path can
 *     be observed rather than inferred.
 *
 * It runs on an OS-assigned free port. It must NOT use 3080: the real dsh web
 * owns that port on this machine, and a test that quietly talked to the live
 * engine would be both wrong and dangerous. This is why dshPort is passed
 * explicitly through `internals` — that is the only override the entry exposes.
 *
 * Why the answer path matters: `user-questions/request` is a waterfall, but its
 * `next` continuation cannot survive a JSON hop. A design that stored a local
 * Promise and resolved it would pass a naive test and hang the agent in
 * production. These tests therefore assert on the RPC that actually leaves the
 * process, which is the only evidence that the engine can see the answer.
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

/**
 * `ws` is resolved from the PLUGIN's node_modules rather than the repo root.
 *
 * Two reasons, and the second is the important one:
 *   1. the root install does not currently materialise `ws`, and adding a
 *      dependency to make a test run is the wrong trade;
 *   2. this is the exact `ws` the gateway itself connects upstream with, so the
 *      test exercises the real client/server pair rather than a second copy that
 *      happens to satisfy the same API.
 */
const require_ = createRequire(
  path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'dsh-server-plugin', 'index.js')
);
const { WebSocketServer, WebSocket: WsClient } = require_('ws');

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-events-home-'));
process.env.DSH_HOME = TMP_HOME;

const { apply, MAX_CLIENT_BUFFER_BYTES, shouldDivertForBackpressure } =
  await import('../../dsh-server-plugin/lib/index.js');
const { loadConfig } = await import('../../dsh-server-plugin/lib/store.mjs');
const TOKEN = loadConfig().token;

async function pickFreePort() {
  const srv = http.createServer();
  await new Promise((res, rej) => { srv.once('error', rej); srv.listen(0, '127.0.0.1', res); });
  const { port } = srv.address();
  await new Promise((res) => srv.close(res));
  return port;
}

const FAKE_ENGINE_PORT = await pickFreePort();
const MOBILE_PORT = await pickFreePort();
const BASE = `http://127.0.0.1:${MOBILE_PORT}`;

// --------------------------------------------------------- fake engine --

/** Every RPC the gateway sent, in order: { method, payload }. */
const rpcCalls = [];
let engineWs = null;

function startFakeEngine() {
  const srv = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      let parsed = null;
      try { parsed = JSON.parse(body); } catch { /* ignore */ }
      rpcCalls.push({ method: parsed?.method ?? req.url, payload: parsed?.payload ?? null, url: req.url });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      // Shape the RPC caller requires: {result:{ok:true,value:...}}.
      res.end(JSON.stringify({ result: { ok: true, value: {} } }));
    });
  });

  const wss = new WebSocketServer({ server: srv, path: '/api/remote.mux' });
  wss.on('connection', (sock) => {
    engineWs = sock;
    sock.on('error', () => {});
  });

  return new Promise((resolve) => {
    srv.listen(FAKE_ENGINE_PORT, '127.0.0.1', () => resolve({ srv, wss }));
  });
}

/** An engine item frame: exactly the shape api-gateway's pump() sends. */
function itemFrame(streamId, value) {
  return { type: 'item', streamId, value };
}

/** A pending user-questions waterfall. Note: no `next` — JSON cannot carry one. */
function questionFrame(questions, opts = {}) {
  return itemFrame('gw-events-stream', {
    type: 'request',
    event: 'user-questions/request',
    id: opts.id,
    agent: opts.agent ?? 'session-abc',
    request: { questions }
  });
}

function pushToEngine(obj) {
  if (!engineWs || engineWs.readyState !== WsClient.OPEN) throw new Error('fake engine has no gateway socket');
  engineWs.send(JSON.stringify(obj));
}

async function waitForEngineSocket(timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (engineWs && engineWs.readyState === WsClient.OPEN) return;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error('gateway never connected to the fake engine');
}

const QUESTION = [
  { id: 'q1', question: '要继续吗？', options: [{ label: '继续' }, { label: '停止' }] }
];

// ------------------------------------------------------- mobile client --

async function connectClient() {
  const ws = new WsClient(`ws://127.0.0.1:${MOBILE_PORT}/mobile-ws`, {
    headers: { Authorization: `Bearer ${TOKEN}` }
  });
  const frames = [];
  const waiters = [];
  await new Promise((res, rej) => {
    ws.once('open', res);
    ws.once('error', rej);
  });
  ws.on('message', (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    frames.push(msg);
    for (let i = waiters.length - 1; i >= 0; i--) {
      if (waiters[i].match(msg)) {
        waiters[i].resolve(msg);
        waiters.splice(i, 1);
      }
    }
  });
  return {
    ws,
    frames,
    send: (obj) => ws.send(JSON.stringify(obj)),
    waitFor(match, ms = 5000) {
      const hit = frames.find(match);
      if (hit) return Promise.resolve(hit);
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error('timeout waiting for frame')), ms);
        waiters.push({ match, resolve: (m) => { clearTimeout(t); resolve(m); } });
      });
    },
    /** Subscribe and wait for the ack, which is what tests usually need first. */
    async subscribe() {
      this.send({ type: 'subscribe_questions' });
      return this.waitFor((m) => m.type === 'question_subscribed');
    },
    close: () => new Promise((res) => {
      if (ws.readyState === WsClient.CLOSED) return res();
      ws.once('close', res);
      ws.close();
    }),
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// -------------------------------------------------------------- setup ---

let teardown = null;
let engine = null;

before(async () => {
  engine = await startFakeEngine();

  const effectFns = [];
  const mockCtx = {
    logger: () => ({ info() {}, warn() {}, error() {}, log() {} }),
    webServer: { port: FAKE_ENGINE_PORT },
    connection: { rpc: { handle: () => async () => {} } },
    effect: (fn) => { effectFns.push(fn); return () => {}; },
    on: (evt, fn) => { if (evt === 'dispose') effectFns.push(fn); }
  };
  const disposer = apply(
    mockCtx,
    { port: MOBILE_PORT },
    { port: MOBILE_PORT, dshPort: FAKE_ENGINE_PORT, isListening: true }
  );
  teardown = async () => {
    try { await disposer?.(); } catch { /* ignore */ }
    for (const fn of effectFns) {
      try { await fn(); } catch { /* ignore */ }
    }
    try { engine?.wss.close(); } catch { /* ignore */ }
    try { await new Promise((r) => engine?.srv.close(r)); } catch { /* ignore */ }
  };

  for (let i = 0; i < 60; i++) {
    try { await fetch(`${BASE}/api/mobile/health`); break; } catch { await sleep(100); }
  }
  await waitForEngineSocket();
});

after(async () => {
  await teardown?.();
  fs.rmSync(TMP_HOME, { recursive: true, force: true });
});

// ================================================================ tests ==

describe('背压阈值（可测的纯函数）', () => {
  it('阈值是 8 MB', () => {
    assert.equal(MAX_CLIENT_BUFFER_BYTES, 8 * 1024 * 1024);
  });

  it('只是超过阈值才断开，等于阈值不断开', () => {
    assert.equal(shouldDivertForBackpressure(MAX_CLIENT_BUFFER_BYTES), false);
    assert.equal(shouldDivertForBackpressure(MAX_CLIENT_BUFFER_BYTES + 1), true);
  });

  it('正常与异常输入都不误判', () => {
    assert.equal(shouldDivertForBackpressure(0), false);
    assert.equal(shouldDivertForBackpressure(1024), false);
    // 不是数字时不能因为 NaN 比较而误断一个健康连接
    assert.equal(shouldDivertForBackpressure(undefined), false);
    assert.equal(shouldDivertForBackpressure(null), false);
    assert.equal(shouldDivertForBackpressure('999999999'), false);
    assert.equal(shouldDivertForBackpressure(NaN), false);
    assert.equal(shouldDivertForBackpressure(Infinity), false);
  });
});

describe('user-questions：不假装作答', () => {
  it('没有手机订阅者时既不转发也不回空答案', async () => {
    const before = rpcCalls.length;
    pushToEngine(questionFrame(QUESTION, { id: 'evt-nosub' }));
    await sleep(400);
    assert.equal(rpcCalls.length, before,
      '无人能答时必须保持沉默，让引擎的 waterfall 落到 Web UI；' +
      '回一个 {answers:[]} 会告诉 agent「人回答了空内容」，那是假话');
  });

  it('缺少 id 的帧不会被转发（mint 一个 id 也答不回去）', async () => {
    const c = await connectClient();
    await c.subscribe();
    pushToEngine(questionFrame(QUESTION, { id: undefined }));
    await sleep(400);
    assert.equal(c.frames.filter((m) => m.type === 'question_request').length, 0);
    await c.close();
  });
});

describe('user-questions：领取与作答', () => {
  it('有订阅者时把问题送到手机上', async () => {
    const c = await connectClient();
    await c.subscribe();
    pushToEngine(questionFrame(QUESTION, { id: 'evt-claim' }));

    const got = await c.waitFor((m) => m.type === 'question_request');
    assert.equal(got.eventId, 'evt-claim');
    assert.equal(got.sessionId, 'session-abc');
    assert.equal(got.questions.length, 1);
    assert.equal(got.questions[0].question, '要继续吗？');
    await c.close();
  });

  it('回答通过 $events/result 回传，形状严格符合引擎的 args 契约', async () => {
    const c = await connectClient();
    await c.subscribe();
    pushToEngine(questionFrame(QUESTION, { id: 'evt-answer' }));
    await c.waitFor((m) => m.type === 'question_request' && m.eventId === 'evt-answer');

    const before = rpcCalls.length;
    c.send({
      type: 'question_answer',
      eventId: 'evt-answer',
      answer: { answers: [{ id: 'q1', selected: ['继续'] }] }
    });

    const ack = await c.waitFor((m) => m.type === 'question_ack');
    assert.equal(ack.ok, true, ack.error || '');

    assert.equal(rpcCalls.length, before + 1, '必须且只能产生一次 RPC');
    const call = rpcCalls[rpcCalls.length - 1];
    assert.ok(call.url.includes('$events/result'), `RPC 路径应为 $events/result，实际 ${call.url}`);

    /* ------------------------------------------------------------------ *
     * ⚠️ 这里断言的是**真实引擎的校验规则**，不是我们自己方便的形状。
     *
     * 这条测试以前是这么写的：
     *     assert.equal(call.payload.eventId, 'evt-answer');
     *     assert.equal(call.payload.outcome.kind, 'result');
     * 也就是把 clientId/eventId/outcome **平铺在外层**当作正确契约 —— 而引擎
     * 恰恰拒绝这种形状。它要求外层**有且只有** `args` 一个键：
     *
     *     // dsh-api-gateway: parseRemoteEventResultPayload
     *     if (!isPlainObject(payload)
     *         || Reflect.ownKeys(payload).length !== 1
     *         || !Object.hasOwn(payload, 'args')) {
     *       throw new Error('... requires exactly one plain-object args field');
     *     }
     *     return parseRemoteEventResult(payload.args);
     *     // 而 payload.args 必须 exactKeys(args, ['clientId','eventId','outcome'])
     *
     * 为什么它没拦住 bug：这个测试里的引擎是**我们自己写的桩**，桩什么都收，
     * 于是"形状不对"永远测不出来 —— 测试反而给了一个错误的契约背书，让人以为
     * 这条路是通的。整整几轮都没有人去问真实引擎要什么形状。
     * 教训：边界契约必须照抄对方源码，不能照抄自己的桩。
     * ------------------------------------------------------------------ */
    assert.deepEqual(
      Reflect.ownKeys(call.payload),
      ['args'],
      `外层 payload 必须只有 args 一个键，实际 ${JSON.stringify(Reflect.ownKeys(call.payload))}`
    );
    assert.deepEqual(
      Reflect.ownKeys(call.payload.args).sort(),
      ['clientId', 'eventId', 'outcome'],
      'args 内部必须恰好是 clientId / eventId / outcome 三个键'
    );
    assert.equal(call.payload.args.eventId, 'evt-answer');
    assert.equal(call.payload.args.outcome.kind, 'result');
    assert.deepEqual(call.payload.args.outcome.value, { answers: [{ id: 'q1', selected: ['继续'] }] });

    await c.waitFor((m) => m.type === 'question_settled' && m.eventId === 'evt-answer');
    await c.close();
  });

  it('未知 eventId 被明确拒绝，不静默丢弃', async () => {
    const c = await connectClient();
    await c.subscribe();
    const before = rpcCalls.length;
    c.send({ type: 'question_answer', eventId: 'never-existed', answer: { answers: [] } });
    const ack = await c.waitFor((m) => m.type === 'question_ack');
    assert.equal(ack.ok, false);
    assert.equal(ack.error, 'unknown-question');
    assert.equal(rpcCalls.length, before, '未知问题绝不能产生一次冒充的作答');
    await c.close();
  });

  it('重复回答只兑现一次，第二次明确失败', async () => {
    const c = await connectClient();
    await c.subscribe();
    pushToEngine(questionFrame(QUESTION, { id: 'evt-dup' }));
    await c.waitFor((m) => m.type === 'question_request' && m.eventId === 'evt-dup');

    const reply = {
      type: 'question_answer',
      eventId: 'evt-dup',
      answer: { answers: [{ id: 'q1', selected: ['继续'] }] }
    };
    const before = rpcCalls.length;
    c.send(reply);
    await c.waitFor((m) => m.type === 'question_settled' && m.eventId === 'evt-dup');
    c.send(reply);
    await c.waitFor((m) => {
      const acks = c.frames.filter((x) => x.type === 'question_ack' && x.eventId === 'evt-dup');
      return acks.length === 2;
    });

    const acks = c.frames.filter((m) => m.type === 'question_ack' && m.eventId === 'evt-dup');
    assert.equal(acks[0].ok, true);
    assert.equal(acks[1].ok, false);
    assert.equal(rpcCalls.length, before + 1, '重复作答不得再打一次 RPC');
    await c.close();
  });

  it('订阅晚到的手机会收到仍在等待的问题回放', async () => {
    const a = await connectClient();
    await a.subscribe();
    pushToEngine(questionFrame(QUESTION, { id: 'evt-replay' }));
    await a.waitFor((m) => m.type === 'question_request' && m.eventId === 'evt-replay');

    const b = await connectClient();
    const sub = await b.subscribe();
    assert.equal(sub.ok, true);
    assert.ok(Array.isArray(sub.pending));
    assert.ok(sub.pending.some((p) => p.eventId === 'evt-replay'),
      '中途连接的手机不该看到一个看起来卡住的会话');

    await a.close();
    await b.close();
  });

  it('未订阅的连接收不到问题帧', async () => {
    const silent = await connectClient();
    const subscriber = await connectClient();
    await subscriber.subscribe();

    pushToEngine(questionFrame(QUESTION, { id: 'evt-scoped' }));
    await subscriber.waitFor((m) => m.type === 'question_request' && m.eventId === 'evt-scoped');
    await sleep(300);

    assert.equal(silent.frames.filter((m) => m.type === 'question_request').length, 0,
      '只是浏览列表的手机不该拿到它永远不会回答的提问');

    await silent.close();
    await subscriber.close();
  });

  it('最后一个持有者断开后该问题不再被提供', async () => {
    const a = await connectClient();
    await a.subscribe();
    const b = await connectClient();
    await b.subscribe();

    pushToEngine(questionFrame(QUESTION, { id: 'evt-orphan' }));
    await a.waitFor((m) => m.type === 'question_request' && m.eventId === 'evt-orphan');
    await b.waitFor((m) => m.type === 'question_request' && m.eventId === 'evt-orphan');

    // 一台断开：另一台仍持有，问题必须还在（多手机修复的核心行为）。
    await a.close();
    await sleep(300);
    assert.equal(b.frames.filter((m) => m.type === 'questions_invalidated').length, 0,
      '还有别的手机持有该提问时，不应广播失效');

    // 最后一个持有者也断开：问题应被释放，晚来的手机不得再看到它。
    await b.close();
    await sleep(300);

    // A phone connecting now must not be shown a prompt that is no longer live.
    const c = await connectClient();
    const sub = await c.subscribe();
    assert.equal(sub.pending.some((p) => p.eventId === 'evt-orphan'), false);

    await c.close();
  });
});

describe('todo 转发', () => {
  it('todo/write 按整表广播到所有手机（不需要订阅）', async () => {
    const a = await connectClient();
    const b = await connectClient();
    pushToEngine(itemFrame('gw-events-stream', {
      type: 'event',
      event: 'todo/write',
      agent: 'session-todo',
      data: {
        todos: [
          { content: '读一下网关源码', status: 'completed' },
          { content: '补上事件转发', status: 'in_progress' },
          { content: '写测试', status: 'pending' }
        ]
      }
    }));

    const got = await a.waitFor((m) => m.type === 'todo_list');
    assert.equal(got.sessionId, 'session-todo');
    assert.equal(got.todos.length, 3);
    assert.deepEqual(got.todos.map((t) => t.status), ['completed', 'in_progress', 'pending']);

    const alsoB = await b.waitFor((m) => m.type === 'todo_list');
    assert.equal(alsoB.todos.length, 3, 'TODO 是会话级广播，不需要订阅');

    await a.close();
    await b.close();
  });

  it('空数组照常广播（清空 TODO 是一个有意义的信号）', async () => {
    const c = await connectClient();
    pushToEngine(itemFrame('gw-events-stream', {
      type: 'event', event: 'todo/write', agent: 's-empty', data: { todos: [] }
    }));
    const got = await c.waitFor((m) => m.type === 'todo_list' && m.sessionId === 's-empty');
    assert.deepEqual(got.todos, []);
    await c.close();
  });

  it('缺少 payload 时不凭空造一个空列表', async () => {
    const c = await connectClient();
    pushToEngine(itemFrame('gw-events-stream', { type: 'event', event: 'todo/write', agent: 's-nopay' }));
    await sleep(300);
    assert.equal(c.frames.filter((m) => m.type === 'todo_list' && m.sessionId === 's-nopay').length, 0);
    await c.close();
  });
});

describe('附件转发', () => {
  it('只转发元数据，图片字节不跨 MUX', async () => {
    const c = await connectClient();
    pushToEngine(itemFrame('gw-events-stream', {
      type: 'event',
      event: 'session/attachment',
      agent: 'session-img',
      data: { attachment: { id: 'att-1', mimeType: 'image/png', width: 800, height: 600, bytes: 12345 } }
    }));
    const got = await c.waitFor((m) => m.type === 'attachment');
    assert.equal(got.sessionId, 'session-img');
    assert.equal(got.attachment.id, 'att-1');
    assert.equal(got.attachment.mimeType, 'image/png');
    assert.equal(got.attachment.data, undefined, '不应内联字节负载');
    assert.equal(got.attachment.base64, undefined);
    await c.close();
  });
});

describe('未知事件被忽略而不是打断处理', () => {
  it('不认识的事件不产生任何转发帧', async () => {
    const c = await connectClient();
    pushToEngine(itemFrame('gw-events-stream', {
      type: 'event', event: 'some/future-event', agent: 'session-x', data: { foo: 1 }
    }));
    await sleep(300);
    const leaked = c.frames.filter(
      (m) => m.type === 'todo_list' || m.type === 'attachment' || m.type === 'question_request'
    );
    assert.equal(leaked.length, 0);
    await c.close();
  });

  it('未知事件之后仍然正常工作（没有把处理链搞坏）', async () => {
    const c = await connectClient();
    pushToEngine(itemFrame('gw-events-stream', { type: 'event', event: 'weird/one', agent: 's1', data: {} }));
    await sleep(150);
    pushToEngine(itemFrame('gw-events-stream', {
      type: 'event', event: 'todo/write', agent: 's-after', data: { todos: [{ content: 'x', status: 'pending' }] }
    }));
    const got = await c.waitFor((m) => m.type === 'todo_list' && m.sessionId === 's-after');
    assert.equal(got.todos.length, 1);
    await c.close();
  });
});