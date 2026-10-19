/**
 * v1.35 / 3.3 — 告警引擎
 *
 * 全 hermetic（注入时钟、内存态或临时文件），钉四条行为：
 *  1. 四条规则都能入收件箱，且严重级正确；
 *  2. 只有 critical 才推送（warning 推送 = 打扰 = 用户关掉通知）；
 *  3. 同规则同会话 10 分钟内只报一次；
 *  4. 已读状态与条目能落盘恢复（重启后收件箱不空、不复活）。
 */

import { describe, it, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const {
  createAlertEngine,
  ALERT_RULES,
  ALERT_DEDUPE_MS
} = await import('../../dsh-server-plugin/lib/alerts.mjs');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-alerts-'));

after(() => {
  try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* ignore */ }
});

describe('alerts: 规则与分级', () => {
  it('四种规则都有明确的严重级', () => {
    assert.equal(ALERT_RULES.turn_error.severity, 'warning');
    assert.equal(ALERT_RULES.context_high.severity, 'warning');
    assert.equal(ALERT_RULES.heartbeat_lost.severity, 'critical');
    assert.equal(ALERT_RULES.job_failed.severity, 'critical');
  });

  it('warning 入收件箱但不推送', () => {
    const pushed = [];
    const engine = createAlertEngine({ push: (a) => pushed.push(a) });
    const a = engine.ingest({ rule: 'turn_error', sessionId: 's1', message: 'boom' });
    assert.equal(a.severity, 'warning');
    assert.equal(engine.size, 1);
    assert.equal(pushed.length, 0, 'warning 不该打扰用户');
  });

  it('critical 同时推送', () => {
    const pushed = [];
    const engine = createAlertEngine({ push: (a) => pushed.push(a) });
    const a = engine.ingest({ rule: 'heartbeat_lost', message: 'engine gone' });
    assert.equal(a.severity, 'critical');
    assert.equal(pushed.length, 1);
    assert.equal(pushed[0].id, a.id);
  });

  it('推送抛错不影响告警入箱', () => {
    const engine = createAlertEngine({ push: () => { throw new Error('ntfy down'); } });
    assert.doesNotThrow(() => engine.ingest({ rule: 'job_failed', message: 'x' }));
    assert.equal(engine.size, 1);
  });
});

describe('alerts: 去重窗口', () => {
  it('同规则同会话 10 分钟内只报一次', () => {
    let t = 1_000_000;
    const engine = createAlertEngine({ now: () => t });

    assert.ok(engine.ingest({ rule: 'turn_error', sessionId: 's1', message: 'a' }));
    t += 60_000;
    assert.equal(engine.ingest({ rule: 'turn_error', sessionId: 's1', message: 'b' }), null);
    assert.equal(engine.size, 1);

    t += ALERT_DEDUPE_MS;
    assert.ok(engine.ingest({ rule: 'turn_error', sessionId: 's1', message: 'c' }));
    assert.equal(engine.size, 2);
  });

  it('不同会话互不影响', () => {
    const engine = createAlertEngine({ now: () => 0 });
    engine.ingest({ rule: 'turn_error', sessionId: 's1' });
    engine.ingest({ rule: 'turn_error', sessionId: 's2' });
    assert.equal(engine.size, 2);
  });

  it('不同规则互不影响', () => {
    const engine = createAlertEngine({ now: () => 0 });
    engine.ingest({ rule: 'turn_error', sessionId: 's1' });
    engine.ingest({ rule: 'heartbeat_lost', sessionId: 's1' });
    assert.equal(engine.size, 2);
  });

  it('空规则被丢弃', () => {
    const engine = createAlertEngine({ now: () => 0 });
    assert.equal(engine.ingest({ rule: '' }), null);
    assert.equal(engine.size, 0);
  });
});

describe('alerts: 收件箱与持久化', () => {
  it('列表新的在前，未读计数正确', () => {
    let t = 1_000_000;
    const engine = createAlertEngine({ now: () => t });
    engine.ingest({ rule: 'turn_error', sessionId: 'a' });
    t += 1000;
    engine.ingest({ rule: 'job_failed', sessionId: 'b' });

    const list = engine.list();
    assert.equal(list[0].rule, 'job_failed', '最新的事件在最上面');
    assert.equal(engine.unreadCount, 2);
  });

  it('标记已读可按 id，也可全部', () => {
    const engine = createAlertEngine({ now: () => 0 });
    const a = engine.ingest({ rule: 'turn_error', sessionId: 'a' });
    engine.ingest({ rule: 'turn_error', sessionId: 'b' });

    assert.equal(engine.markRead([a.id]), 1);
    assert.equal(engine.unreadCount, 1);
    assert.equal(engine.markRead([], { all: true }), 1);
    assert.equal(engine.unreadCount, 0);
  });

  it('落盘后重建：条目与已读状态都在，未读不会复活', () => {
    const file = path.join(TMP, 'alerts-state.json');
    let t = 1_000_000;
    const first = createAlertEngine({ stateFile: file, now: () => t });
    const a = first.ingest({ rule: 'turn_error', sessionId: 's1', message: 'x' });
    t += 1000;
    first.ingest({ rule: 'heartbeat_lost', message: 'y' });
    first.markRead([a.id]);

    const second = createAlertEngine({ stateFile: file, now: () => t });
    assert.equal(second.size, 2);
    assert.equal(second.unreadCount, 1, '已读的那条不该变回未读');
    const restored = second.list().find((x) => x.id === a.id);
    assert.ok(restored.readAt);
  });

  it('坏状态文件不阻断启动', () => {
    const file = path.join(TMP, 'bad-state.json');
    fs.writeFileSync(file, '{not json', 'utf8');
    const engine = createAlertEngine({ stateFile: file, now: () => 0 });
    assert.equal(engine.size, 0);
    assert.ok(engine.ingest({ rule: 'turn_error', sessionId: 's' }));
  });

  it('超过上限时淘汰最老的条目', () => {
    let t = 0;
    const engine = createAlertEngine({ now: () => t, maxEntries: 3 });
    for (let i = 0; i < 5; i++) {
      t += ALERT_DEDUPE_MS + 1;
      engine.ingest({ rule: 'turn_error', sessionId: `s${i}` });
    }
    assert.equal(engine.size, 3);
    const sessions = engine.list().map((a) => a.sessionId);
    assert.ok(!sessions.includes('s0'), '最老的应被淘汰');
  });
});
