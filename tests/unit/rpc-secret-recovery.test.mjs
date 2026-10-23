/**
 * [fix 2026-10-23] 引擎密钥轮换后，网关必须能自愈 —— 而不是等到重启。
 *
 * 事故现场（本机实测）：
 *   * dsh web 00:26 启动，网关在 apply() 里把 `~/.dsh/.credentials.yaml` 的 secret
 *     读进 cookieFactory；
 *   * 10:19 那个文件被重写（密钥轮换），网关还拿旧 secret 签名；
 *   * 从此每一次 RPC 都是 `unauthorized`（事件流也连不上）。
 *
 * 用户看到的现象：「手机端突然没有会话信息显示了，只有我发送的第一段文字」——
 * 因为历史走不到引擎的 `session/page`，只能掉到投影缓存里 titleInput 的兜底。
 *
 * 这里钉住的是自愈本身的边界：只重试一次、只在密钥**真的变了**时重试、别的错误
 * 不许触发重载（否则一次网络抖动就会让网关偷偷换掉密钥状态）。
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

const { createRetryingRpcCaller, isUnauthorizedRpcError } = await import(
  '../../dsh-server-plugin/lib/core.mjs'
);

describe('密钥轮换自愈：识别 unauthorized', () => {
  it('HTTP 401 被当成文本吞掉时也算（本机实际形状）', () => {
    assert.equal(
      isUnauthorizedRpcError(new Error('Failed to parse RPC response: unauthorized')),
      true
    );
  });

  it('JSON 错误里的 unauthorized / 401 也算', () => {
    assert.equal(isUnauthorizedRpcError(new Error('unauthorized')), true);
    assert.equal(isUnauthorizedRpcError(new Error('HTTP 401 Unauthorized')), true);
  });

  it('别的失败不算：网络、超时、方法不存在', () => {
    for (const msg of ['ECONNREFUSED', 'RPC timed out', 'no such method session/page', '']) {
      assert.equal(isUnauthorizedRpcError(new Error(msg)), false, `不该算: ${msg}`);
    }
    assert.equal(isUnauthorizedRpcError(null), false);
  });
});

describe('密钥轮换自愈：只重试一次', () => {
  it('第一次 401 → 重载密钥 → 重试成功', async () => {
    const calls = [];
    let reloads = 0;
    const caller = createRetryingRpcCaller({
      makeClient: () => async (method) => {
        calls.push(method);
        if (calls.length === 1) throw new Error('Failed to parse RPC response: unauthorized');
        return { ok: true };
      },
      reloadCredentials: () => { reloads += 1; return true; }
    });

    const value = await caller.call('session/page', { args: {} });
    assert.deepEqual(value, { ok: true });
    assert.equal(reloads, 1);
    assert.equal(calls.length, 2);
  });

  it('重载之后仍然 401 就如实抛错，不无限重试', async () => {
    let reloads = 0;
    let attempts = 0;
    const caller = createRetryingRpcCaller({
      makeClient: () => async () => {
        attempts += 1;
        throw new Error('Failed to parse RPC response: unauthorized');
      },
      reloadCredentials: () => { reloads += 1; return true; }
    });

    await assert.rejects(() => caller.call('session/page', {}), /unauthorized/);
    assert.equal(reloads, 1, '只该重载一次');
    assert.equal(attempts, 2, '只该重试一次');
  });

  it('密钥没变就不重试，原样抛（问题不在密钥上）', async () => {
    let attempts = 0;
    const caller = createRetryingRpcCaller({
      makeClient: () => async () => { attempts += 1; throw new Error('unauthorized'); },
      reloadCredentials: () => false
    });

    await assert.rejects(() => caller.call('x', {}), /unauthorized/);
    assert.equal(attempts, 1);
  });

  it('非 401 的失败不触发重载', async () => {
    let reloads = 0;
    const caller = createRetryingRpcCaller({
      makeClient: () => async () => { throw new Error('ECONNREFUSED'); },
      reloadCredentials: () => { reloads += 1; return true; }
    });

    await assert.rejects(() => caller.call('x', {}), /ECONNREFUSED/);
    assert.equal(reloads, 0);
  });

  it('重载本身抛错时，抛的是原始 RPC 错误（不掩盖真相）', async () => {
    const caller = createRetryingRpcCaller({
      makeClient: () => async () => { throw new Error('unauthorized'); },
      reloadCredentials: () => { throw new Error('credentials.yaml 读不了'); }
    });
    await assert.rejects(() => caller.call('x', {}), /unauthorized/);
  });

  it('onReloaded 只在真的重载后触发一次', async () => {
    let notified = 0;
    let first = true;
    const caller = createRetryingRpcCaller({
      makeClient: () => async () => {
        if (first) { first = false; throw new Error('unauthorized'); }
        return 'ok';
      },
      reloadCredentials: () => true,
      onReloaded: () => { notified += 1; }
    });
    await caller.call('x', {});
    await caller.call('x', {});
    assert.equal(notified, 1);
  });
});
