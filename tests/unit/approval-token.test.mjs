/**
 * v1.35 / 2.1 — 单次审批令牌
 *
 * 纯模块测试（注入时钟），不起网关、不打网络。
 *
 * 每一条都对应一个真实的误用场景：
 *  - 连点两下通知 → 同向重复必须幂等，反向必须冲突（不能"最后一下赢"）；
 *  - 手机时间不准/审批挂太久 → 过期必须硬失效；
 *  - 截屏/转发出去的令牌被换一条审批用 → mismatch；
 *  - 完全访问策略下给一键批准 → 一次误触等于无确认执行，禁止。
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

const {
  createApprovalTokens,
  isSensitiveApprovalPolicy,
  APPROVAL_TOKEN_TTL_MS
} = await import('../../dsh-server-plugin/lib/core.mjs');

describe('approval tokens', () => {
  it('铸造后校验通过，令牌是 URL 安全的随机串', () => {
    const store = createApprovalTokens();
    const token = store.mint('appr_1');
    assert.match(token, /^[A-Za-z0-9_-]{30,}$/);
    assert.deepEqual(store.check('appr_1', token), { ok: true, code: 'ok' });
    assert.equal(store.size, 1);
  });

  it('未知审批返回 unknown', () => {
    const store = createApprovalTokens();
    assert.equal(store.check('nope', 'whatever').code, 'unknown');
  });

  it('令牌不匹配返回 mismatch（换一条审批复用无效）', () => {
    const store = createApprovalTokens();
    store.mint('appr_1');
    store.mint('appr_2');
    const t2 = store.mint('appr_3');
    assert.equal(store.check('appr_1', t2).code, 'mismatch');
    assert.equal(store.check('appr_1', '').code, 'mismatch');
  });

  it('过期硬失效（默认 15 分钟）', () => {
    let now = 1_000_000;
    const store = createApprovalTokens({ now: () => now });
    const token = store.mint('appr_1');

    now += APPROVAL_TOKEN_TTL_MS - 1;
    assert.equal(store.check('appr_1', token).code, 'ok');

    now += 2;
    assert.equal(store.check('appr_1', token).code, 'expired');
  });

  it('消费后同向是幂等、反向是冲突', () => {
    const store = createApprovalTokens();
    const token = store.mint('appr_1');
    assert.equal(store.consume('appr_1', 'approve'), true);

    const after = store.check('appr_1', token);
    assert.equal(after.ok, false);
    assert.equal(after.code, 'consumed');
    assert.equal(after.decision, 'approve', '调用方靠它区分同向幂等与反向冲突');
  });

  it('consume 未知 id 返回 false', () => {
    const store = createApprovalTokens();
    assert.equal(store.consume('missing', 'deny'), false);
  });

  it('prune 只清理过期超过一分钟的条目', () => {
    let now = 0;
    const store = createApprovalTokens({ now: () => now, ttlMs: 1000 });
    store.mint('old');
    now += 2000 + 30_000; // 过期 31 秒：还没到一分钟宽限
    store.mint('fresh');
    store.prune();
    assert.equal(store.size, 2);

    now += 60_000;
    store.prune();
    assert.equal(store.size >= 1, true, '新条目不能被误删');
    assert.equal(store.check('old', 'x').code, 'unknown', '过期条目应被清掉');
  });

  it('每次铸造都是不同令牌（同一审批重投也不行）', () => {
    const store = createApprovalTokens();
    const a = store.mint('appr_1');
    const b = store.mint('appr_1');
    assert.notEqual(a, b);
    assert.equal(store.check('appr_1', a).code, 'mismatch', '后铸的令牌覆盖前者');
    assert.equal(store.check('appr_1', b).code, 'ok');
  });
});

describe('sensitive approval policy', () => {
  it('完全访问策略不给一键批准', () => {
    assert.equal(isSensitiveApprovalPolicy('danger-full-access'), true);
  });

  it('其余策略都允许（ask / auto-read / 空值）', () => {
    assert.equal(isSensitiveApprovalPolicy('ask'), false);
    assert.equal(isSensitiveApprovalPolicy('auto-read'), false);
    assert.equal(isSensitiveApprovalPolicy(''), false);
    assert.equal(isSensitiveApprovalPolicy(undefined), false);
  });
});
