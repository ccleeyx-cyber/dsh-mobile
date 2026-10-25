/**
 * Gateway feature layer tests (bridge 1.14).
 *
 * These exercise the pure decisions that used to be impossible to check without
 * a live DSH: queue row shaping, action validation, deliverable path security,
 * git output parsing, usage summarization, ntfy request building, and the route
 * table itself (driven through a fake dependency bag so no engine is needed).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import { readFileSync } from 'node:fs';
import { PassThrough } from 'node:stream';

import {
  selectQueueRows,
  normalizeQueueAction,
  extractDeliverables,
  resolveDeliverable,
  parsePorcelain,
  parseNumstat,
  combineChanges,
  parseUnifiedDiff,
  summarizeUsage,
  summarizeSessionStats,
  SESSION_STATS_FIELDS,
  describeSchedule,
  normalizeSchedule,
  buildNtfyRequest,
  pushForEvent,
  countDeliverableClients,
  shouldPushNtfy,
  describeNtfyTarget,
  redactNtfyDetail,
  deliverNtfy,
  collectSessionRecords,
  parseCursorFromPastSeqError,
  projectionCacheFileNames,
  claimsMobileFeatureRoute,
  FEATURE_ROUTES,
  convertSessionRecordsToMessages,
  handleFeatureRoute
} from '../../dsh-server-plugin/lib/features.mjs';
import {
  classifyHarnessNotice,
  createAuditSink,
  readUserMessageSource
} from '../../dsh-server-plugin/lib/core.mjs';

/* ------------------------------------------------------------------ *
 * queue
 * ------------------------------------------------------------------ */

test('selectQueueRows: keeps text, counts attachments, drops unusable rows', () => {
  const values = {
    inbox: {
      'next-turn': [
        { id: 'm1', content: [{ type: 'text', text: ' 部署 GZ ' }] },
        { id: 'm2', content: [{ type: 'text', text: '看图' }, { type: 'image', data: 'x' }, { type: 'file', receiptId: 'r1' }] },
        { id: '', content: [{ type: 'text', text: 'no id' }] },
        { id: 'm3' },
        null
      ],
      'next-step': [{ id: 'step1', content: [{ type: 'text', text: '忽略' }] }]
    }
  };
  const rows = selectQueueRows(values);
  assert.equal(rows.length, 2, 'rows without an id or content must be dropped');
  assert.equal(rows[0].text, '部署 GZ');
  assert.equal(rows[0].attachments, 0);
  assert.equal(rows[1].attachments, 2);
  assert.equal(rows[1].text, '看图');
});

test('selectQueueRows: absent inbox is an empty list, not a crash', () => {
  assert.deepEqual(selectQueueRows(undefined), []);
  assert.deepEqual(selectQueueRows({}), []);
  assert.deepEqual(selectQueueRows({ inbox: { 'next-turn': 'nope' } }), []);
});

test('normalizeQueueAction: remove and steer need no payload', () => {
  assert.deepEqual(normalizeQueueAction({ kind: 'remove' }), { ok: true, action: { kind: 'remove' } });
  assert.deepEqual(normalizeQueueAction({ kind: 'steer' }), { ok: true, action: { kind: 'steer' } });
  assert.deepEqual(normalizeQueueAction({ type: 'remove' }), { ok: true, action: { kind: 'remove' } });
});

test('normalizeQueueAction: edit requires non-empty text (engine rule mirror)', () => {
  const ok = normalizeQueueAction({ kind: 'edit', text: '你好' });
  assert.equal(ok.ok, true);
  assert.deepEqual(ok.action.content, [{ type: 'text', text: '你好' }]);

  assert.equal(normalizeQueueAction({ kind: 'edit', text: '   ' }).ok, false);
  assert.equal(normalizeQueueAction({ kind: 'edit' }).ok, false);
  assert.equal(normalizeQueueAction({ kind: 'nope' }).ok, false);
  assert.equal(normalizeQueueAction(null).ok, false);
});

/* ------------------------------------------------------------------ *
 * deliverables
 * ------------------------------------------------------------------ */

test('extractDeliverables: relative paths resolve against cwd, newest wins', () => {
  const cwd = path.resolve('/work/proj');
  const records = [
    { event: { type: 'deliverables/presented', seq: 10, data: { turn: 1, files: [{ path: 'out/a.docx', description: 'v1' }] } } },
    { event: { type: 'deliverables/presented', seq: 20, data: { turn: 2, files: [{ path: 'out/a.docx', description: 'v2' }, { path: 'C:/tmp/b.pdf' }] } } }
  ];
  const rows = extractDeliverables(records, cwd);
  assert.equal(rows.length, 2, 'the same path must appear once');
  const a = rows.find((r) => r.display === 'out/a.docx');
  assert.equal(a.description, 'v2', 'the later declaration wins');
  assert.equal(a.turn, 2);
  assert.equal(a.path, path.resolve(cwd, 'out/a.docx'));
  const b = rows.find((r) => r.display === 'C:/tmp/b.pdf');
  assert.ok(b, 'absolute paths are kept as given');
});

test('extractDeliverables: malformed input yields an empty list', () => {
  assert.deepEqual(extractDeliverables(null, '/w'), []);
  assert.deepEqual(extractDeliverables([{ event: { type: 'other' } }], '/w'), []);
  assert.deepEqual(extractDeliverables([{ event: { type: 'deliverables/presented', data: { files: [{ path: '  ' }] } } }], '/w'), []);
});

test('resolveDeliverable: only exact declared paths are downloadable', () => {
  const rows = extractDeliverables(
    [{ event: { type: 'deliverables/presented', seq: 1, data: { files: [{ path: 'out/report.docx' }] } } }],
    path.resolve('/work/proj')
  );
  assert.ok(resolveDeliverable(rows, path.resolve('/work/proj/out/report.docx')));
  assert.ok(resolveDeliverable(rows, '/work/proj/out/report.docx'));
  // A sibling, a traversal and an unrelated absolute path are all refused.
  assert.equal(resolveDeliverable(rows, '/work/proj/out/other.docx'), null);
  assert.equal(resolveDeliverable(rows, '/work/proj/out/../secret.txt'), null);
  assert.equal(resolveDeliverable(rows, '/etc/shadow'), null);
  assert.equal(resolveDeliverable(rows, ''), null);
});

/* ------------------------------------------------------------------ *
 * workspace changes
 * ------------------------------------------------------------------ */

test('parsePorcelain: -z format, including rename pairs', () => {
  const entries = parsePorcelain(' M src/a.ts\0?? new.txt\0R  new-name.ts\0old-name.ts\0');
  assert.deepEqual(entries, [
    { status: 'M', path: 'src/a.ts', origPath: null },
    { status: '??', path: 'new.txt', origPath: null },
    { status: 'R', path: 'new-name.ts', origPath: 'old-name.ts' }
  ]);
  assert.deepEqual(parsePorcelain(''), []);
  assert.deepEqual(parsePorcelain(undefined), []);
});

test('parseNumstat: counts and binary markers', () => {
  const rows = parseNumstat('12\t3\tsrc/a.ts\n-\t-\tassets/logo.png\n');
  assert.deepEqual(rows[0], { path: 'src/a.ts', added: 12, deleted: 3, binary: false });
  assert.equal(rows[1].binary, true);
  assert.equal(rows[1].added, null);
});

test('combineChanges: merges both sources and never invents counts', () => {
  const status = [
    { status: 'M', path: 'src/a.ts', origPath: null },
    { status: '??', path: 'new.txt', origPath: null },
    { status: 'D', path: 'gone.md', origPath: null }
  ];
  const numstat = [
    { path: 'src/a.ts', added: 5, deleted: 1, binary: false },
    { path: 'src/only-in-numstat.ts', added: 2, deleted: 0, binary: false }
  ];
  const files = combineChanges(status, numstat);
  assert.equal(files.length, 4);
  const a = files.find((f) => f.path === 'src/a.ts');
  assert.equal(a.added, 5);
  const untracked = files.find((f) => f.path === 'new.txt');
  assert.equal(untracked.added, null, 'an untracked file has no line counts, not zero');
  const extra = files.find((f) => f.path === 'src/only-in-numstat.ts');
  assert.equal(extra.status, 'M');
});

test('parseUnifiedDiff: hunks with per-line kinds, headers dropped', () => {
  const text = [
    'diff --git a/x.ts b/x.ts',
    'index 111..222 100644',
    '--- a/x.ts',
    '+++ b/x.ts',
    '@@ -1,3 +1,4 @@',
    ' const a = 1;',
    '-const b = 2;',
    '+const b = 3;',
    '+const c = 4;'
  ].join('\n');
  const hunks = parseUnifiedDiff(text);
  assert.equal(hunks.length, 1);
  assert.equal(hunks[0].header, '@@ -1,3 +1,4 @@');
  assert.deepEqual(hunks[0].lines.map((l) => l.kind), ['context', 'del', 'add', 'add']);
  assert.equal(hunks[0].lines[1].text, 'const b = 2;', 'the +/- prefix is stripped once');
  assert.deepEqual(parseUnifiedDiff(''), []);
});

/* ------------------------------------------------------------------ *
 * usage
 * ------------------------------------------------------------------ */

test('summarizeUsage: live projection wins and totals add up', () => {
  const stats = summarizeUsage({
    tokenUsage: { uncachedInputTokens: 100, outputTokens: 40, cacheReadTokens: 10, cacheWriteTokens: 5 },
    contextPressure: { pressureTokens: 155, projectedTokens: 200, contextWindow: 128000 }
  }, null);
  assert.equal(stats.source, 'live');
  assert.equal(stats.totalTokens, 155);
  assert.equal(stats.contextWindow, 128000);
  assert.equal(stats.goal, null);
});

test('summarizeUsage: falls back to the projection cache and never fakes numbers', () => {
  const rows = {
    tokenUsage: { ver: 2, seq: 9, val: { uncachedInputTokens: 7, outputTokens: 3 } },
    contextPressure: { ver: 4, seq: 9, val: { pressureTokens: 10 } },
    goal: {
      ver: 6,
      seq: 9,
      val: { goal: { objective: '把 GZ 部署跑通', phase: 'active', maxGoalRounds: 40 }, roundsStarted: 3, createdAt: 1, updatedAt: 2 }
    }
  };
  const stats = summarizeUsage(null, rows);
  assert.equal(stats.source, 'cache');
  assert.equal(stats.totalTokens, 10);
  assert.equal(stats.cacheReadTokens, 0, 'a missing bucket is zero, which is meaningful here');
  assert.equal(stats.goal.objective, '把 GZ 部署跑通');
  assert.equal(stats.goal.roundsStarted, 3);

  const empty = summarizeUsage(null, null);
  assert.equal(empty.source, 'none');
  assert.equal(empty.totalTokens, null, 'unknown must be null, never 0');
  assert.equal(empty.contextWindow, null);
});

/* ------------------------------------------------------------------ *
 * sessionStats 投影 —— 电脑端状态条那行「6 轮 351 步 · 210 tok/s」  [feat 2026-10-17]
 *
 * 手机端状态行要轮/步/速度，而这三样只有引擎的 `sessionStats` 投影有（电脑端
 * dsh-client-ui-chat 的 StatsPills 读 useProjection('sessionStats')，它的兜底
 * deriveStats 的字段名是"deliberately mirror the projection's field names"）。
 * 网关以前没转发，手机端于是永远显示 —。
 *
 * 两级读法照抄 agentteam.mjs：① session/projections RPC（live 会话的权威值）；
 * ② 冷会话回落投影缓存 `rows.<投影>.val`。只白名单 8 个数字字段。
 * ------------------------------------------------------------------ */

const FULL_SESSION_STATS = {
  turns: 6,
  steps: 351,
  llmMs: 128400,
  toolMs: 40200,
  ttftMs: 5200,
  ttftSteps: 340,
  decodeMs: 61200,
  decodeTokens: 12852
};

test('summarizeUsage: live 有 sessionStats 时带回 8 个白名单字段，既有字段一个不少', () => {
  const stats = summarizeUsage({ sessionStats: FULL_SESSION_STATS }, null);
  assert.deepEqual(stats.sessionStats, FULL_SESSION_STATS);
  assert.deepEqual(Object.keys(stats.sessionStats).sort(), [...SESSION_STATS_FIELDS].sort(), '正好这 8 个键，不多不少');
  // 状态条那行：6 轮 351 步 · 210 tok/s = decodeTokens / (decodeMs / 1000)
  assert.equal(stats.sessionStats.turns, 6);
  assert.equal(stats.sessionStats.steps, 351);
  assert.equal(Math.round(stats.sessionStats.decodeTokens / (stats.sessionStats.decodeMs / 1000)), 210);
  // 既有字段不能少、不能改名（App 已在用）
  for (const key of [
    'source', 'uncachedInputTokens', 'outputTokens', 'cacheReadTokens',
    'cacheWriteTokens', 'totalTokens', 'pressureTokens', 'projectedTokens', 'contextWindow', 'goal'
  ]) {
    assert.ok(key in stats, `既有字段 ${key} 不能丢`);
  }
});

test('summarizeUsage: 投影缺失时 sessionStats 是 null（不编 0），非法值也不混进来', () => {
  const none = summarizeUsage(null, null);
  assert.equal(none.sessionStats, null, '读不到就是 null，手机端据此显示 —');
  assert.equal('sessionStats' in none, true, '键要在（值为 null），App 才能区分"未知"与"老网关没有这个字段"');

  // 单个字段非法：字符串 / NaN / Infinity / 负数 → 那个字段 null；合法字段照传。
  const garbage = summarizeUsage({
    sessionStats: {
      turns: '6',
      steps: Number.NaN,
      llmMs: -1,
      toolMs: Number.POSITIVE_INFINITY,
      ttftMs: 5200,
      ttftSteps: null,
      decodeMs: 0,
      decodeTokens: 12852,
      // 投影里还有这些"状态字段"，一个都不许白名单外泄
      lastTurn: 6,
      openStep: { turn: 6, step: 3 }
    }
  }, null);
  assert.equal(garbage.sessionStats.turns, null, '字符串不是数字');
  assert.equal(garbage.sessionStats.steps, null, 'NaN 不是数字');
  assert.equal(garbage.sessionStats.llmMs, null, '时长不可能为负，负数按"没有"处理');
  assert.equal(garbage.sessionStats.toolMs, null, 'Infinity 不是有限数字');
  assert.equal(garbage.sessionStats.ttftMs, 5200, '合法值照传');
  assert.equal(garbage.sessionStats.ttftSteps, null);
  assert.equal(garbage.sessionStats.decodeMs, 0, 'decodeMs: 0 是合法事实（没有成功的解码步），照实传 0');
  assert.deepEqual(Object.keys(garbage.sessionStats).sort(), [...SESSION_STATS_FIELDS].sort(), '白名单以外一个键都不带');
  assert.equal(garbage.sessionStats.lastTurn, undefined, 'openStep/lastTurn 这种状态字段不外泄');

  // 有对象但一个数都读不出来 = 读不到。
  assert.equal(summarizeUsage({ sessionStats: { turns: 'x' } }, null).sessionStats, null);
  assert.equal(summarizeSessionStats('nope'), null);
});

test('summarizeUsage: 冷会话从投影缓存行 rows.sessionStats.val 读，steps: 0 照实传 0', () => {
  const rows = {
    sessionStats: { ver: 1, seq: 42, val: { ...FULL_SESSION_STATS, turns: 0, steps: 0 } }
  };
  const stats = summarizeUsage(null, rows);
  assert.equal(stats.sessionStats.turns, 0, '空会话的 0 是合法事实，不是"读不到"');
  assert.equal(stats.sessionStats.steps, 0, '只有字段缺失/非数字才是 null，绝不把 0 当缺失');
  assert.equal(stats.sessionStats.decodeTokens, 12852);
});

test('route: GET session/stats 把 sessionStats 挂在 stats 子对象上，既有字段不变', async () => {
  const { deps, calls } = makeHarness({
    projections: {
      tokenUsage: { uncachedInputTokens: 100, outputTokens: 40, cacheReadTokens: 10, cacheWriteTokens: 5 },
      contextPressure: { pressureTokens: 155, projectedTokens: 200, contextWindow: 128000 },
      sessionStats: FULL_SESSION_STATS
    }
  });
  deps.pathname = '/api/mobile/session/stats';
  deps.parsedUrl = { query: { sessionId: 'session-1' } };
  assert.equal(await handleFeatureRoute(deps), true);
  const body = calls.sent[0].body;
  assert.equal(body.ok, true);
  assert.equal(body.stats.totalTokens, 155);
  assert.equal(body.stats.goal, null);
  assert.deepEqual(body.stats.sessionStats, FULL_SESSION_STATS);

  // 会话不在内存里（RPC 失败 → readProjections 给 null）、缓存也没有这一行 → null。
  const { deps: deps2, calls: calls2 } = makeHarness({ projections: null, rows: { tokenUsage: { ver: 1, seq: 9, val: { uncachedInputTokens: 7 } } } });
  deps2.pathname = '/api/mobile/session/stats';
  deps2.parsedUrl = { query: { sessionId: 'session-1' } };
  assert.equal(await handleFeatureRoute(deps2), true);
  assert.equal(calls2.sent[0].body.stats.sessionStats, null);
  assert.equal(calls2.sent[0].body.stats.totalTokens, 7);
});

/* ------------------------------------------------------------------ *
 * schedules
 * ------------------------------------------------------------------ */

test('describeSchedule: every rule kind renders a readable line', () => {
  assert.equal(describeSchedule({ kind: 'every', every_seconds: 3600 }), '每 1 小时');
  assert.equal(describeSchedule({ kind: 'every', every_seconds: 90 }), '每 90 秒');
  assert.equal(describeSchedule({ kind: 'daily', time: '09:00:00' }), '每天 09:00:00');
  assert.equal(describeSchedule({ kind: 'weekly', weekdays: [1, 5], time: '08:00:00' }), '每周 1/5 08:00:00');
  assert.equal(describeSchedule({ kind: 'cron', expression: '*/5 * * * *' }), 'cron: */5 * * * *');
  assert.equal(describeSchedule(null), '');
});

test('normalizeSchedule: drops records without an id', () => {
  const ok = normalizeSchedule({ id: 's1', kind: 'daily', title: '日报', prompt: '总结', time: '09:00:00', scheduledAt: '2026-10-11T01:00:00Z' });
  assert.equal(ok.id, 's1');
  assert.equal(ok.schedule, '每天 09:00:00');
  assert.equal(normalizeSchedule({ kind: 'daily' }), null);
  assert.equal(normalizeSchedule(null), null);
});

/* ------------------------------------------------------------------ *
 * ntfy
 * ------------------------------------------------------------------ */

test('buildNtfyRequest: posts to the ROOT path with topic in the body (ntfy JSON publish contract)', () => {
  const req = buildNtfyRequest(
    { ntfyUrl: 'https://ntfy.sh/', ntfyTopic: 'dsh-abc', ntfyToken: 'tk_x' },
    { title: '需要你授权', body: 'pwsh：删除文件', priority: 5, tags: ['lock'], click: 'dshmobile://open?session=session-1' }
  );
  // [fix 2026-10-12] ntfy 的 "Publish as JSON" 契约：POST 根路径 + body.topic。
  // 旧行为（topic 拼 URL、body 无 topic）会被 ntfy 当成纯文本消息，用户手机上
  // 看到一坨转义 JSON，click/actions 全部失效 —— 这是用户实测抓到的。
  assert.equal(req.url, 'https://ntfy.sh/');
  assert.equal(req.body.topic, 'dsh-abc');
  assert.equal(req.headers.Authorization, 'Bearer tk_x');
  assert.equal(req.headers['Content-Type'], 'application/json');
  assert.equal(req.body.title, '需要你授权');
  assert.equal(req.body.priority, 5);
  assert.equal(req.body.click, 'dshmobile://open?session=session-1');
  assert.equal(req.body.actions[0].url, 'dshmobile://open?session=session-1');
});

test('buildNtfyRequest: refuses to build without a base URL or topic', () => {
  assert.equal(buildNtfyRequest({ ntfyUrl: '', ntfyTopic: 't' }, {}), null);
  assert.equal(buildNtfyRequest({ ntfyUrl: 'https://ntfy.sh', ntfyTopic: '' }, {}), null);
  assert.equal(buildNtfyRequest({ ntfyUrl: 'not a url', ntfyTopic: 't' }, {}), null);
});

test('buildNtfyRequest: refuses plaintext and private targets unless admin opts in', () => {
  const message = { title: 'x', body: 'y' };
  assert.equal(
    buildNtfyRequest({ ntfyUrl: 'http://ntfy.sh', ntfyTopic: 't' }, message),
    null,
    'public HTTP would leak the token'
  );
  assert.equal(
    buildNtfyRequest({ ntfyUrl: 'https://192.168.1.10', ntfyTopic: 't' }, message),
    null,
    'private targets are SSRF even over https'
  );

  const previous = process.env.DSH_NTFY_ALLOW_PRIVATE;
  process.env.DSH_NTFY_ALLOW_PRIVATE = '1';
  try {
    const local = buildNtfyRequest({ ntfyUrl: 'http://127.0.0.1:2586', ntfyTopic: 't' }, message);
    assert.ok(local, 'self-hosted ntfy works after explicit admin opt-in');
    assert.equal(local.url, 'http://127.0.0.1:2586/');
  } finally {
    if (previous === undefined) delete process.env.DSH_NTFY_ALLOW_PRIVATE;
    else process.env.DSH_NTFY_ALLOW_PRIVATE = previous;
  }
});

test('buildNtfyRequest: an inline topic overrides the configured one (in the body)', () => {
  const req = buildNtfyRequest({ ntfyUrl: 'https://ntfy.sh', ntfyTopic: 'default' }, { topic: 'per-device' });
  assert.equal(req.url, 'https://ntfy.sh/');
  assert.equal(req.body.topic, 'per-device');
});

test('pushForEvent: only human-blocking and completion events push', () => {
  assert.equal(pushForEvent('delta'), null);
  assert.equal(pushForEvent('tool-start'), null);
  assert.equal(pushForEvent('approval', { toolName: 'pwsh', reason: '要删文件' }).priority, 5);
  assert.equal(pushForEvent('question', { question: '选哪个？' }).body, '选哪个？');
  assert.match(pushForEvent('turn-end', { summary: '完成' }).title, /完成/);
  assert.match(pushForEvent('turn-failed', {}).title, /失败/);
});

/* ------------------------------------------------------------------ *
 * ntfy: dedupe, attribution, redaction
 * ------------------------------------------------------------------ */

const OPEN = 1; // WebSocket.OPEN
const liveSocket = () => ({ readyState: OPEN, isAlive: true });

function makePushDeps(overrides = {}) {
  const calls = { audit: [], warns: [], sent: [], infos: [] };
  return {
    calls,
    deps: {
      kind: 'turn-end',
      detail: { sessionId: 'session-1', summary: '本轮已结束' },
      config: { ntfyEnabled: true, ntfyUrl: 'https://ntfy.example.com', ntfyTopic: 'TOPIC-SECRET', ntfyToken: 'tk_TOKEN_SECRET' },
      clients: [],
      openReadyState: OPEN,
      // Stub transport: NO network is ever touched.
      send: async (request) => { calls.sent.push(request); return overrides.sendResult ?? { ok: true, status: 200 }; },
      audit: (action, payload) => calls.audit.push({ action, payload }),
      logger: {
        warn: (...a) => calls.warns.push(a.join(' ')),
        info: (...a) => calls.infos.push(a.join(' '))
      },
      ...overrides.deps
    }
  };
}

test('countDeliverableClients: only OPEN sockets the heartbeat has not written off', () => {
  assert.equal(countDeliverableClients([]), 0);
  assert.equal(countDeliverableClients(null), 0);
  assert.equal(countDeliverableClients(undefined), 0);
  assert.equal(countDeliverableClients([liveSocket()]), 1);
  // Not OPEN: cannot receive (CONNECTING=0, CLOSING=2, CLOSED=3).
  assert.equal(countDeliverableClients([{ readyState: 0, isAlive: true }]), 0);
  assert.equal(countDeliverableClients([{ readyState: 2, isAlive: true }]), 0);
  assert.equal(countDeliverableClients([{ readyState: 3, isAlive: true }]), 0);
  // The 30s sweep declared it dead (a full ping interval with no pong).
  assert.equal(countDeliverableClients([{ readyState: OPEN, isAlive: false }]), 0);
  // `isAlive === undefined` is a socket that has not been swept yet — count it.
  assert.equal(countDeliverableClients([{ readyState: OPEN }]), 1);
  assert.equal(countDeliverableClients([liveSocket(), { readyState: 3 }, { readyState: OPEN, isAlive: false }]), 1);
});

test('shouldPushNtfy: the switch must be strictly on, and a live App wins', () => {
  assert.equal(shouldPushNtfy({ ntfyEnabled: true }, []), true, 'no client -> push');
  assert.equal(shouldPushNtfy({ ntfyEnabled: true }, [liveSocket()]), false, 'App alive -> the App notifies locally');
  assert.equal(shouldPushNtfy({ ntfyEnabled: true }, [{ readyState: 3 }]), true, 'socket gone -> push');
  assert.equal(shouldPushNtfy({ ntfyEnabled: true }, [{ readyState: OPEN, isAlive: false }]), true, 'heartbeat-dead -> push');
  assert.equal(shouldPushNtfy({ ntfyEnabled: false }, []), false);
  // Only a real boolean true enables pushing: a stray string must not.
  assert.equal(shouldPushNtfy({ ntfyEnabled: 'true' }, []), false);
  assert.equal(shouldPushNtfy({}, []), false);
  assert.equal(shouldPushNtfy(null, []), false);
});

test('deliverNtfy: a live App suppresses the push and the audit says why', async () => {
  const { deps, calls } = makePushDeps({ deps: { clients: [liveSocket()] } });
  const out = await deliverNtfy(deps);
  assert.equal(out.outcome, 'skipped');
  assert.equal(out.reason, 'app-connected');
  assert.equal(calls.sent.length, 0, 'no push may go out while the App can receive');
  assert.equal(calls.audit.length, 1);
  assert.equal(calls.audit[0].action, 'ntfy/push');
  assert.equal(calls.audit[0].payload.outcome, 'skipped');
  assert.equal(calls.audit[0].payload.reason, 'app-connected');
  assert.equal(calls.audit[0].payload.liveClients, 1);
});

test('deliverNtfy: with no live App the push goes out and the status is recorded', async () => {
  const { deps, calls } = makePushDeps();
  const out = await deliverNtfy(deps);
  assert.equal(out.outcome, 'sent');
  assert.equal(out.status, 200);
  assert.equal(calls.sent.length, 1, 'exactly one push');
  assert.equal(calls.audit[0].payload.outcome, 'sent');
  assert.equal(calls.audit[0].payload.status, 200);
  // [fix 2026-10-12] JSON 发布 POST 到**根路径**，topic 只在 body 里
  // （ntfy "Publish as JSON"）。断言随之从 URL 挪到 body，并反向钉住
  // "topic 绝不进 URL / 绝不进 audit" —— 那才是这条用例真正要守的东西。
  assert.equal(calls.sent[0].body.topic, 'TOPIC-SECRET', 'the topic belongs in the JSON body');
  assert.equal(calls.sent[0].url, 'https://ntfy.example.com/', 'the URL is the bare root path');
  assert.ok(!calls.sent[0].url.includes('TOPIC-SECRET'), 'the topic must not leak into the URL');
  assert.equal(calls.sent[0].headers.Authorization, 'Bearer tk_TOKEN_SECRET', 'the bearer token is carried by header');
  assert.ok(!JSON.stringify(calls.audit).includes('TOPIC-SECRET'), 'the topic never reaches the audit ring');
  assert.ok(!JSON.stringify(calls.audit).includes('tk_TOKEN_SECRET'), 'the bearer token never reaches the audit ring');
});

test('deliverNtfy: a rejected push is audited with its status, never swallowed', async () => {
  const { deps, calls } = makePushDeps({ sendResult: { ok: false, status: 403, reason: 'ntfy 返回 HTTP 403' } });
  const out = await deliverNtfy(deps);
  assert.equal(out.outcome, 'failed');
  assert.equal(out.status, 403);
  assert.equal(calls.audit[0].payload.outcome, 'failed');
  assert.equal(calls.audit[0].payload.status, 403);
  assert.equal(calls.audit[0].payload.reason, 'ntfy 返回 HTTP 403');
  assert.equal(calls.warns.length, 1, 'the failure is also on the warn channel');
});

test('deliverNtfy: a transport exception is audited, not thrown at the caller', async () => {
  const { deps, calls } = makePushDeps({ deps: { send: async () => { throw new Error('getaddrinfo ENOTFOUND ntfy.example.com'); } } });
  const out = await deliverNtfy(deps);
  assert.equal(out.outcome, 'failed');
  assert.equal(out.status, null);
  assert.match(out.reason, /ENOTFOUND/);
  assert.equal(calls.audit[0].payload.outcome, 'failed');
  assert.equal(calls.audit[0].payload.reason, 'getaddrinfo ENOTFOUND ntfy.example.com');
});

test('deliverNtfy: never logs the token or the topic (any outcome)', async () => {
  const cases = [
    { name: 'sent', deps: {} },
    { name: 'rejected', deps: { sendResult: { ok: false, status: 500, reason: 'topic TOPIC-SECRET rejected' } } },
    { name: 'throw-with-secrets', deps: { deps: { send: async () => { throw new Error('POST https://ntfy.example.com/TOPIC-SECRET failed with tk_TOKEN_SECRET'); } } } },
    { name: 'app-connected', deps: { deps: { clients: [liveSocket()] } } },
    { name: 'disabled', deps: { deps: { config: { ntfyEnabled: false, ntfyUrl: 'https://ntfy.example.com', ntfyTopic: 'TOPIC-SECRET', ntfyToken: 'tk_TOKEN_SECRET' } } } }
  ];
  for (const c of cases) {
    const { deps, calls } = makePushDeps(c.deps);
    await deliverNtfy(deps);
    const blob = JSON.stringify(calls.audit) + JSON.stringify(calls.warns) + JSON.stringify(calls.infos);
    assert.ok(!blob.includes('TOPIC-SECRET'), `${c.name}: the topic must never be recorded`);
    assert.ok(!blob.includes('tk_TOKEN_SECRET'), `${c.name}: the token must never be recorded`);
    // What IS recorded: the host (diagnosable, not secret).
    assert.equal(calls.audit[0].payload.host, 'ntfy.example.com', `${c.name}: the host is recorded`);
  }
});

test('deliverNtfy: disabled / not-pushable / unconfigured are distinguishable', async () => {
  const off = makePushDeps({ deps: { config: { ntfyEnabled: false } } });
  assert.equal((await deliverNtfy(off.deps)).reason, 'disabled');

  const noop = makePushDeps({ deps: { kind: 'delta' } });
  assert.equal((await deliverNtfy(noop.deps)).reason, 'not-pushable');
  assert.equal(noop.calls.sent.length, 0);

  const bare = makePushDeps({ deps: { config: { ntfyEnabled: true } } });
  assert.equal((await deliverNtfy(bare.deps)).reason, 'unconfigured');
  assert.equal(bare.calls.sent.length, 0);

  // Every skip is still audited: "I got no push" must be answerable.
  for (const h of [off, noop, bare]) assert.equal(h.calls.audit[0].payload.outcome, 'skipped');
});

test('describeNtfyTarget / redactNtfyDetail: expose the host, bury the secrets', () => {
  const cfg = { ntfyEnabled: true, ntfyUrl: 'https://ntfy.example.com/', ntfyTopic: 'SECRET-TOPIC', ntfyToken: 'SECRET-TOKEN' };
  assert.deepEqual(describeNtfyTarget(cfg), { host: 'ntfy.example.com', topicLength: 12 });
  assert.deepEqual(describeNtfyTarget({}), { host: '', topicLength: 0 });
  assert.deepEqual(describeNtfyTarget(null), { host: '', topicLength: 0 });
  assert.deepEqual(describeNtfyTarget({ ntfyUrl: 'not a url', ntfyTopic: 'ab' }), { host: '', topicLength: 2 });

  assert.equal(redactNtfyDetail('GET https://h/SECRET-TOPIC 401', cfg), 'GET https://h/[redacted] 401');
  assert.equal(redactNtfyDetail('token=SECRET-TOKEN', cfg), 'token=[redacted]');
  assert.equal(redactNtfyDetail('plain failure', cfg), 'plain failure');
  assert.equal(redactNtfyDetail(undefined, cfg), '');
  assert.equal(redactNtfyDetail('x'.repeat(500), cfg).length, 160, 'the audit ring is bounded');
});

test('the REAL audit sink can be served to a client without leaking the channel', async () => {
  // The audit buffer is readable through an authenticated route, so "we passed a
  // safe payload" is not enough — the sink's own normalization (it derives
  // `command` from `reason` and falls back to JSON.stringify) must not resurrect
  // a secret either. This drives the payload through the actual sink.
  const sink = createAuditSink({ size: 50 });
  const cfg = { ntfyEnabled: true, ntfyUrl: 'https://ntfy.example.com', ntfyTopic: 'SECRET-TOPIC', ntfyToken: 'SECRET-TOKEN' };
  const scenarios = [
    {},
    { sendResult: { ok: false, status: 429, reason: 'rate limited on SECRET-TOPIC' } },
    { deps: { send: async () => { throw new Error('connect to https://ntfy.example.com/SECRET-TOPIC with SECRET-TOKEN'); } } },
    { deps: { clients: [liveSocket()] } }
  ];
  for (const s of scenarios) {
    const { deps } = makePushDeps({ ...s, deps: { ...(s.deps ?? {}), config: cfg } });
    await deliverNtfy({ ...deps, audit: (action, payload) => sink.record(action, payload) });
  }
  const readable = JSON.stringify(sink.read(50));
  assert.ok(readable.includes('ntfy/push'), 'the entries are actually there');
  assert.ok(!readable.includes('SECRET-TOPIC'), 'no entry may carry the topic');
  assert.ok(!readable.includes('SECRET-TOKEN'), 'no entry may carry the token');
  assert.ok(readable.includes('ntfy.example.com'), 'the host stays, so failures are attributable');
});

/* ------------------------------------------------------------------ *
 * route table
 * ------------------------------------------------------------------ */

/**
 * A response double that is a real Writable, so `stream.pipe(res)` works.
 *
 * The download route now calls the **real** `sendFile` (imported by
 * features.mjs), not an injected stub. That is deliberate: the old harness
 * supplied `sendFile: async (p, name) => true` — a fake with no response object
 * — so the route tests stayed green while the real function threw
 * `ReferenceError: res is not defined` and every download answered 500.
 */
function makeFakeRes() {
  const res = new PassThrough();
  const chunks = [];
  res.on('data', (c) => chunks.push(c));
  res.statusCode = null;
  res.headers = null;
  res.bytes = () => Buffer.concat(chunks);
  res.writeHead = function writeHead(status, headers) {
    this.statusCode = status;
    this.headers = headers;
    return this;
  };
  return res;
}

function makeHarness(overrides = {}) {
  const calls = { sent: [], rpc: [], audits: [], streams: [], files: [] };
  const deps = {
    pathname: '',
    req: { method: 'GET' },
    res: makeFakeRes(),
    parsedUrl: { query: {} },
    jsonBody: {},
    auth: { device: { id: 'test', role: 'readwrite' } },
    sendJson: (status, body) => calls.sent.push({ status, body }),
    // No `sendFile` key on purpose: features.mjs imports the real one so that a
    // route test can never pass against a fake that does not resemble it.
    callDshRpc: async (method, payload) => { calls.rpc.push({ method, payload }); return overrides.rpcResult ?? {}; },
    readStreamOnce: async (endpoint, args, opts) => { calls.streams.push({ endpoint, args, opts }); return overrides.streamResult ?? null; },
    readProjections: async () => overrides.projections ?? null,
    readProjectionRows: () => overrides.rows ?? null,
    readSessionRecords: async () => overrides.sessionRecords ?? { records: [], cwd: '/w' },
    readWorkspaceChanges: async (sessionId, wanted) => (wanted
      ? { available: true, path: wanted, hunks: [{ header: '@@', lines: [] }], empty: false, binary: false }
      : (overrides.changes ?? { available: true, cwd: '/w', files: [{ path: 'src/a.ts', status: 'M', origPath: null, added: 1, deleted: 0, binary: false }] })),
    readConfig: () => overrides.config ?? {},
    writeConfig: (patch) => ({ ...(overrides.config ?? {}), ...patch }),
    pushTest: async () => overrides.pushOk ?? true,
    audit: (action, payload) => calls.audits.push({ action, payload }),
    logger: { warn() {}, info() {} },
    ...overrides.deps
  };
  return { deps, calls };
}

test('route: GET queue returns shaped rows', async () => {
  const { deps, calls } = makeHarness({
    projections: { inbox: { 'next-turn': [{ id: 'm1', content: [{ type: 'text', text: 'A' }] }] } }
  });
  deps.pathname = '/api/mobile/sessions/queue';
  deps.parsedUrl = { query: { sessionId: 'session-1' } };
  assert.equal(await handleFeatureRoute(deps), true);
  assert.equal(calls.sent[0].status, 200);
  assert.deepEqual(calls.sent[0].body.queue, [{ id: 'm1', text: 'A', attachments: 0, createdAt: null }]);
});

test('route: queue mutation sends the engine its exact action shape', async () => {
  const { deps, calls } = makeHarness();
  deps.pathname = '/api/mobile/sessions/queue';
  deps.req = { method: 'POST' };
  deps.jsonBody = { sessionId: 'session-1', itemId: 'm1', action: { kind: 'edit', text: '改一下' } };
  assert.equal(await handleFeatureRoute(deps), true);
  assert.equal(calls.rpc[0].method, 'session/updateQueue');
  assert.deepEqual(calls.rpc[0].payload.args.request, {
    sessionId: 'session-1',
    itemId: 'm1',
    action: { kind: 'edit', content: [{ type: 'text', text: '改一下' }] }
  });
  assert.equal(calls.sent[0].status, 200);
});

test('route: a bad queue action is rejected before any RPC', async () => {
  const { deps, calls } = makeHarness();
  deps.pathname = '/api/mobile/sessions/queue';
  deps.req = { method: 'POST' };
  deps.jsonBody = { sessionId: 's', itemId: 'm1', action: { kind: 'edit', text: '  ' } };
  await handleFeatureRoute(deps);
  assert.equal(calls.rpc.length, 0);
  assert.equal(calls.sent[0].status, 400);
});

test('route: jobs degrades honestly when the MUX cannot answer', async () => {
  const { deps, calls } = makeHarness({ streamResult: null });
  deps.pathname = '/api/mobile/jobs';
  deps.parsedUrl = { query: { sessionId: 'session-1' } };
  await handleFeatureRoute(deps);
  assert.equal(calls.sent[0].status, 200);
  assert.deepEqual(calls.sent[0].body.jobs, []);
  assert.equal(calls.sent[0].body.degraded, 'jobs-unavailable');
});

test('route: jobs maps the first whole-set frame', async () => {
  const { deps, calls } = makeHarness({
    streamResult: { type: 'rows', jobs: [{ id: 'bash-1', kind: 'bash', label: 'npm test', status: 'running', startedAt: 1 }] }
  });
  deps.pathname = '/api/mobile/jobs';
  deps.parsedUrl = { query: { sessionId: 'session-1' } };
  await handleFeatureRoute(deps);
  assert.equal(calls.streams[0].endpoint, 'job/list');
  assert.equal(calls.sent[0].body.jobs[0].label, 'npm test');
  assert.equal(calls.sent[0].body.degraded, undefined);
});

test('route: deliverable download refuses anything not presented', async () => {
  const { deps, calls } = makeHarness({
    sessionRecords: { records: [{ event: { type: 'deliverables/presented', seq: 1, data: { files: [{ path: 'out/ok.docx' }] } } }], cwd: '/w' }
  });
  deps.pathname = '/api/mobile/deliverables/download';
  deps.parsedUrl = { query: { sessionId: 's', path: '/etc/shadow' } };
  await handleFeatureRoute(deps);
  // Assert on the response itself, not on a stubbed call count: the property
  // that matters is that no bytes and no 200 ever reach the client.
  assert.equal(deps.res.statusCode, null, 'no file may be streamed');
  assert.equal(deps.res.bytes().length, 0);
  assert.equal(calls.sent[0].status, 403);
});

test('route: deliverable download writes the real bytes to the response', async () => {
  // A real file on disk, so the real sendFile actually streams something. The
  // previous version of this test only counted calls into an injected stub and
  // would pass no matter what the real writer did.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'deliverable-'));
  const real = path.join(dir, 'ok.docx');
  const content = Buffer.from('PK deliverable bytes', 'utf8');
  fs.writeFileSync(real, content);

  const { deps } = makeHarness({
    sessionRecords: { records: [{ event: { type: 'deliverables/presented', seq: 1, data: { files: [{ path: real, description: 'x' }] } } }], cwd: dir }
  });
  deps.pathname = '/api/mobile/deliverables/download';
  deps.parsedUrl = { query: { sessionId: 's', path: real } };

  assert.equal(await handleFeatureRoute(deps), true);
  await new Promise((r) => setImmediate(r));

  assert.equal(deps.res.statusCode, 200, 'the download must answer 200');
  assert.equal(deps.res.headers['Content-Length'], content.length);
  assert.equal(deps.res.bytes().length, content.length, 'the phone must receive every byte');
  assert.equal(deps.res.bytes().toString('utf8'), content.toString('utf8'));
});

test('route: a declared file that vanished answers 404, never a silent hang', async () => {
  // The file was presented earlier but is gone from the host now. sendFile
  // writes NOTHING in that case, so the route must answer for it -- otherwise
  // the socket stays open and the phone waits out its full 60s timeout, which
  // is exactly what "点不开" looked like before.
  const gone = path.join(os.tmpdir(), `vanished-${Date.now()}.docx`);
  const { deps, calls } = makeHarness({
    sessionRecords: { records: [{ event: { type: 'deliverables/presented', seq: 1, data: { files: [{ path: gone }] } } }], cwd: os.tmpdir() }
  });
  deps.pathname = '/api/mobile/deliverables/download';
  deps.parsedUrl = { query: { sessionId: 's', path: gone } };

  assert.equal(await handleFeatureRoute(deps), true);

  assert.equal(deps.res.statusCode, null, 'no 200 may be committed when nothing was streamed');
  assert.equal(deps.res.bytes().length, 0, 'nothing may be written to the body');
  assert.equal(calls.sent.length, 1, 'the route must answer instead of leaving the socket open');
  assert.equal(calls.sent[0].status, 404);
  assert.equal(calls.sent[0].body.path, gone, 'the reply names the path so the user can see what moved');
});

/* ------------------------------------------------------------------ *
 * deliverable scan data source (the "点不开" root cause)
 * ------------------------------------------------------------------ */

// The engine's real rejection text, captured from the live instance
// (dsh web 16:03:54, 2026-10-10). `session/page` cannot report a session's
// cursor any other way — see parseCursorFromPastSeqError's docblock.
const REAL_PAST_CURSOR = 'session page through seq 9007199254740991 is past cursor 4431';

test('parseCursorFromPastSeqError: reads the engine cursor, refuses anything else', () => {
  assert.equal(parseCursorFromPastSeqError(REAL_PAST_CURSOR), 4431);
  assert.equal(parseCursorFromPastSeqError('session page through seq 5 is past cursor 0'), 0);
  assert.equal(parseCursorFromPastSeqError('session "session-x" not found'), null);
  assert.equal(parseCursorFromPastSeqError('typert gateway: session/page: wire field "request" failed boundary validation'), null);
  assert.equal(parseCursorFromPastSeqError(undefined), null);
  assert.equal(parseCursorFromPastSeqError('past cursor -3'), null);
});

test('collectSessionRecords: every page carries the REQUIRED throughSeq', async () => {
  // Regression: the scan used to send {address, maxMessages} and the engine
  // answered `gateway/input-invalid`, which was swallowed into `records: []`.
  // The deliverable list was therefore empty for every session, forever.
  const sent = [];
  const callDshRpc = async (method, payload) => {
    sent.push({ method, request: payload.args.request });
    if (payload.args.request.throughSeq === Number.MAX_SAFE_INTEGER) {
      throw new Error(REAL_PAST_CURSOR); // the cursor probe
    }
    return { records: [{ event: { type: 'user/message', seq: 0 } }], hasMore: false };
  };
  const out = await collectSessionRecords({ callDshRpc, sessionId: 'session-x' });
  assert.equal(sent.length, 2, 'one cursor probe plus one page');
  for (const call of sent) {
    assert.equal(call.method, 'session/page');
    assert.equal(typeof call.request.throughSeq, 'number', 'throughSeq is a required wire field');
    assert.ok(call.request.address && call.request.address.kind === 'session');
  }
  assert.equal(out.cursor, 4431);
  assert.equal(out.records.length, 1);
  assert.equal(out.truncated, false);
});

test('collectSessionRecords: walks backwards with beforeSeq and never truncates silently', async () => {
  const pages = [
    { records: [{ event: { type: 'user/message', seq: 300 } }, { event: { type: 'deliverables/presented', seq: 310 } }], hasMore: true },
    { records: [{ event: { type: 'user/message', seq: 100 } }, { event: { type: 'user/message', seq: 150 } }], hasMore: true },
    { records: [{ event: { type: 'user/message', seq: 0 } }], hasMore: false }
  ];
  const requests = [];
  let n = 0;
  const callDshRpc = async (method, payload) => {
    const request = payload.args.request;
    if (request.throughSeq === Number.MAX_SAFE_INTEGER) throw new Error(REAL_PAST_CURSOR);
    requests.push(request);
    return pages[n++] ?? { records: [], hasMore: false };
  };
  const out = await collectSessionRecords({ callDshRpc, sessionId: 'session-x' });
  assert.equal(requests.length, 3);
  assert.equal(requests[0].beforeSeq, undefined, 'the first page starts at the cursor');
  assert.equal(requests[1].beforeSeq, 300, 'the next window starts at the previous page start');
  assert.equal(requests[2].beforeSeq, 100);
  for (const r of requests) assert.equal(r.throughSeq, 4431, 'throughSeq stays pinned at the cursor');
  // ascending, deduplicated, and the deliverable survives
  assert.deepEqual(out.records.map((r) => r.event.seq), [0, 100, 150, 300, 310]);
  assert.equal(out.truncated, false);
});

test('collectSessionRecords: page budget exhaustion is reported, not hidden', async () => {
  const callDshRpc = async (method, payload) => {
    const request = payload.args.request;
    if (request.throughSeq === Number.MAX_SAFE_INTEGER) throw new Error(REAL_PAST_CURSOR);
    return { records: [{ event: { type: 'user/message', seq: (request.beforeSeq ?? 1000) - 10 } }], hasMore: true };
  };
  const out = await collectSessionRecords({ callDshRpc, sessionId: 'session-x', maxPages: 2, messagesPerPage: 10 });
  assert.equal(out.pages, 2);
  assert.equal(out.truncated, true, 'a partial answer must say so');
});

test('collectSessionRecords: an unknown session yields no records, not an exception', async () => {
  const callDshRpc = async () => { throw new Error('session "session-x" not found'); };
  const out = await collectSessionRecords({ callDshRpc, sessionId: 'session-x' });
  assert.deepEqual(out, { records: [], cursor: null, pages: 0, truncated: false });
});

test('projectionCacheFileNames: reaches BOTH cache filename spellings', () => {
  // Regression: 2133/2468 real cache files are `session-<uuid>.json`; the old
  // single-candidate lookup reached 13.6% of them, so cwd was null for 86.4%.
  assert.deepEqual(projectionCacheFileNames('session-03ba0334-462f-4838-beac-783599a96e08'), [
    '03ba0334-462f-4838-beac-783599a96e08.json',
    'session-03ba0334-462f-4838-beac-783599a96e08.json'
  ]);
  // An already-bare id must still produce the prefixed candidate.
  assert.deepEqual(projectionCacheFileNames('03ba0334-462f-4838-beac-783599a96e08'), [
    '03ba0334-462f-4838-beac-783599a96e08.json',
    'session-03ba0334-462f-4838-beac-783599a96e08.json'
  ]);
  assert.deepEqual(projectionCacheFileNames(''), []);
  assert.deepEqual(projectionCacheFileNames('session-'), []);
  assert.deepEqual(projectionCacheFileNames(null), []);
});

test('route: deliverable download 404s instead of leaving the socket unanswered', async () => {
  // `sendFile` writes nothing when the file is gone; the route must answer or
  // the phone sits in its full 60s `http.get` timeout (what "点不开" looked like).
  // No stub here on purpose: the real sendFile is what must observe the missing
  // file and report false.
  const { deps, calls } = makeHarness({
    sessionRecords: { records: [{ event: { type: 'deliverables/presented', seq: 1, data: { files: [{ path: 'out/gone.docx' }] } } }], cwd: '/w' }
  });
  deps.pathname = '/api/mobile/deliverables/download';
  deps.parsedUrl = { query: { sessionId: 's', path: path.resolve('/w/out/gone.docx') } };
  await handleFeatureRoute(deps);
  assert.equal(calls.sent.length, 1, 'exactly one response');
  assert.equal(calls.sent[0].status, 404);
  assert.equal(calls.sent[0].body.code, 404);
  assert.equal(deps.res.statusCode, null, 'nothing may have been streamed');
});

test('route: deliverables reports the scan truncation flag', async () => {
  const { deps, calls } = makeHarness({
    sessionRecords: {
      records: [{ event: { type: 'deliverables/presented', seq: 9, data: { files: [{ path: 'out/a.docx' }] } } }],
      cwd: '/w',
      truncated: true
    }
  });
  deps.pathname = '/api/mobile/deliverables';
  deps.parsedUrl = { query: { sessionId: 's' } };
  await handleFeatureRoute(deps);
  assert.equal(calls.sent[0].status, 200);
  assert.equal(calls.sent[0].body.deliverables.length, 1);
  assert.equal(calls.sent[0].body.truncated, true);
});

/* ------------------------------------------------------------------ *
 * dispatch order: the sessions/* GET wildcard must not steal a feature route
 * ------------------------------------------------------------------ */

// The wildcard branch in index.js turns everything after `/api/mobile/sessions/`
// into a session id. Measured on the live (pre-fix) gateway:
//   GET /api/mobile/sessions/queue?sessionId=… ->
//   {"ok":true,"code":0,"data":{"sessionId":"queue","messages":[]}}
// i.e. a fake session literally named "queue", and the queue feature route
// unreachable in production. These tests are the guard for that class.

test('claimsMobileFeatureRoute: knows every route handleFeatureRoute really claims', async () => {
  // Cross-check the exported list against real behaviour, so list and handler
  // can never drift: every claimed pair must be handled, and nothing else.
  for (const [method, pathname] of FEATURE_ROUTES) {
    const { deps } = makeHarness({ sessionRecords: { records: [], cwd: '/w' } });
    deps.pathname = pathname;
    deps.req = { method };
    deps.parsedUrl = { query: { sessionId: 'session-1', path: '/w/a' } };
    assert.equal(await handleFeatureRoute(deps), true, `${method} ${pathname} must be claimed`);
  }
});

test('claimsMobileFeatureRoute: a real session id still belongs to history', () => {
  // The wildcard must keep working: these must NOT be claimed by the feature layer.
  for (const id of ['session-03ba0334-462f-4838-beac-783599a96e08', '03ba0334-462f-4838-beac-783599a96e08']) {
    assert.equal(claimsMobileFeatureRoute('GET', `/api/mobile/sessions/${id}`), false);
  }
  assert.equal(claimsMobileFeatureRoute('GET', '/api/mobile/sessions/queue'), true);
  assert.equal(claimsMobileFeatureRoute('POST', '/api/mobile/sessions/queue'), true);
  // Method-sensitive: no POST route may be claimed as a GET or vice versa.
  assert.equal(claimsMobileFeatureRoute('POST', '/api/mobile/sessions/search'), false);
  assert.equal(claimsMobileFeatureRoute('GET', '/api/mobile/sessions/archive'), false);
  assert.equal(claimsMobileFeatureRoute(undefined, '/api/mobile/sessions/queue'), false);
  assert.equal(claimsMobileFeatureRoute('GET', ''), false);
});

test('index.js: the feature dispatch precedes the sessions/* GET wildcard', () => {
  // Regression lock for the ordering bug. On the pre-fix file the dispatch sat
  // ~420 lines BELOW the wildcard, so /api/mobile/sessions/queue was swallowed
  // by getSessionHistory('queue'). A source-level assertion is the only way to
  // pin the ORDER of two branches inside an unexported request handler without
  // binding a port and dialling the live engine.
  const source = readFileSync(new URL('../../dsh-server-plugin/lib/index.js', import.meta.url), 'utf8');
  const dispatchAt = source.indexOf('if (await handleFeatureRoute({');
  const wildcardAt = source.indexOf("pathname.startsWith('/api/mobile/sessions/')");
  assert.ok(dispatchAt > 0, 'the feature dispatch must exist');
  assert.ok(wildcardAt > 0, 'the sessions/* GET wildcard must exist');
  assert.ok(
    dispatchAt < wildcardAt,
    `handleFeatureRoute must run before the sessions/* wildcard (dispatch@${dispatchAt}, wildcard@${wildcardAt})`
  );
  // …and the wildcard must additionally refuse claimed feature routes.
  const wildcardBlock = source.slice(wildcardAt, wildcardAt + 300);
  assert.match(wildcardBlock, /!claimsMobileFeatureRoute\(/, 'the wildcard must carry the feature-route guard');
});

test('route: diff refuses a path outside the change list', async () => {
  const { deps, calls } = makeHarness();
  deps.pathname = '/api/mobile/workspace/diff';
  deps.parsedUrl = { query: { sessionId: 's', path: 'src/not-listed.ts' } };
  await handleFeatureRoute(deps);
  assert.equal(calls.sent[0].status, 404);
});

test('route: diff answers with hunks for a listed path', async () => {
  const { deps, calls } = makeHarness();
  deps.pathname = '/api/mobile/workspace/diff';
  deps.parsedUrl = { query: { sessionId: 's', path: 'src/a.ts' } };
  await handleFeatureRoute(deps);
  assert.equal(calls.sent[0].status, 200);
  assert.equal(calls.sent[0].body.hunks.length, 1);
});

test('route: push config never echoes the stored token', async () => {
  const { deps, calls } = makeHarness({ config: { ntfyEnabled: true, ntfyUrl: 'https://ntfy.sh', ntfyTopic: 't', ntfyToken: 'secret-token' } });
  deps.pathname = '/api/mobile/push/config';
  await handleFeatureRoute(deps);
  const body = JSON.stringify(calls.sent[0].body);
  assert.equal(calls.sent[0].body.push.hasToken, true);
  assert.equal(body.includes('secret-token'), false, 'the token itself must never leave the host');
});

test('route: unknown path is not claimed', async () => {
  const { deps, calls } = makeHarness();
  deps.pathname = '/api/mobile/something-else';
  assert.equal(await handleFeatureRoute(deps), false);
  assert.equal(calls.sent.length, 0);
});

test('route: schedules list normalizes what the engine returns', async () => {
  const { deps, calls } = makeHarness({
    rpcResult: [{ id: 's1', kind: 'daily', title: '日报', prompt: 'p', time: '09:00:00' }, { kind: 'daily' }]
  });
  deps.pathname = '/api/mobile/schedules';
  deps.parsedUrl = { query: { sessionId: 'session-1' } };
  await handleFeatureRoute(deps);
  assert.equal(calls.sent[0].body.schedules.length, 1);
  assert.equal(calls.sent[0].body.schedules[0].schedule, '每天 09:00:00');
});

/* ------------------------------------------------------------------ *
 * 引擎注入的通知（`user/message` 但没人打过字）
 * ------------------------------------------------------------------ */

const SETTLEMENT_TEXT =
  'Background subagent 915eb2f4-0d12-4b86-8922-b2b26cfc3ecc finished and will do no ' +
  'further work unless you send it more.Its closing message:2026-10-06 | 修复考勤报表；' +
  '新增绩效报表正常开班小组课班级数';

test('classifyHarnessNotice: 认得出子代理结算通知（来源字段缺失的老记录也认）', () => {
  const notice = classifyHarnessNotice(SETTLEMENT_TEXT, { data: {} });
  assert.equal(notice.kind, 'subagent-settlement');
  assert.equal(notice.variant, 'completed');
  assert.equal(notice.childId, '915eb2f4-0d12-4b86-8922-b2b26cfc3ecc');
  assert.ok(notice.body.startsWith('2026-10-06 | 修复考勤报表'), '收尾正文要切出来');
  assert.ok(!notice.body.includes('Its closing message:'), '分隔标记本身不该留在正文里');
});

test('classifyHarnessNotice: aborted / max-tokens 两个收尾分支也认，认不出只退化成 unknown', () => {
  const aborted = classifyHarnessNotice(
    'Background subagent c1 was stopped before it finished.',
    { data: {} }
  );
  assert.equal(aborted.variant, 'aborted');
  assert.equal(aborted.body, null, '没有收尾正文时 body 必须是 null，不能是空串');

  const maxTokens = classifyHarnessNotice(
    'Background subagent c1 ran out of room before it finished.',
    { data: {} }
  );
  assert.equal(maxTokens.variant, 'max-tokens');

  const other = classifyHarnessNotice('Background subagent c1 sent a new request to the parent.', { data: {} });
  assert.equal(other.kind, 'subagent-settlement', '锚定开头就说明是注入');
  assert.equal(other.variant, 'unknown', '认不出的分支只能退化成 unknown');
});

test('classifyHarnessNotice: 来源写明是人类 → 永不误伤（哪怕正文里满是这些字样）', () => {
  // 用户把这条通知复制到输入框里问"这是什么" —— 它必须仍是一条人类消息。
  assert.equal(classifyHarnessNotice(SETTLEMENT_TEXT, { data: { source: { kind: 'user' } } }), null);
  assert.equal(classifyHarnessNotice(SETTLEMENT_TEXT, { data: { origin: 'human' } }), null);
  assert.equal(classifyHarnessNotice(SETTLEMENT_TEXT, { data: { source: 'user-input' } }), null);
});

test('classifyHarnessNotice: 没有来源标记、又不是锚定文案 → 一律当真人消息', () => {
  assert.equal(classifyHarnessNotice('帮我看下前面那段 Background subagent 是什么', { data: {} }), null);
  assert.equal(classifyHarnessNotice('普通提问', { data: {} }), null);
  assert.equal(classifyHarnessNotice('', { data: {} }), null);
  assert.equal(classifyHarnessNotice(null, { data: {} }), null);
});

test('classifyHarnessNotice: 其它非人类来源按来源分类（批准通知 / agent 指令）', () => {
  const approval = classifyHarnessNotice('请批准这次写盘', {
    data: { source: { kind: 'plugin', plugin: 'user-approval' } }
  });
  assert.equal(approval.kind, 'plugin:user-approval');

  const instructions = classifyHarnessNotice('一段系统注入的指令', {
    data: { source: { kind: 'agent-instructions' } }
  });
  assert.equal(instructions.kind, 'agent-instructions');

  const bare = classifyHarnessNotice('来源存在但没写 kind', { data: { source: {} } });
  assert.equal(bare.kind, 'injected', '有 source 但读不出 kind 也不能当成真人');
});

test('readUserMessageSource: 三种形状都要读对，且"缺席"与"真人"必须分开', () => {
  assert.deepEqual(readUserMessageSource({ data: {} }), { present: false, human: false, kind: '' });
  assert.deepEqual(readUserMessageSource({ data: { origin: 'human' } }), { present: true, human: true, kind: 'human' });
  assert.deepEqual(
    readUserMessageSource({ data: { source: { kind: 'plugin', plugin: 'user-approval' } } }),
    { present: true, human: false, kind: 'plugin:user-approval' }
  );
});

test('convertSessionRecordsToMessages: 通知带标记、真人消息不带，且 role 都保持 user', () => {
  const records = [
    {
      event: {
        type: 'user/message',
        seq: 1,
        time: 1000,
        data: { source: { kind: 'user' }, content: [{ type: 'text', text: '帮我改一下登录' }] }
      }
    },
    {
      event: {
        type: 'user/message',
        seq: 2,
        time: 2000,
        data: { content: [{ type: 'text', text: SETTLEMENT_TEXT }] }
      }
    }
  ];

  const { messages } = convertSessionRecordsToMessages(records);
  assert.equal(messages.length, 2);

  assert.equal(messages[0].role, 'user');
  assert.equal(messages[0].noticeKind, undefined, '真人消息不该带任何通知字段');
  assert.equal(messages[0].content, '帮我改一下登录');

  assert.equal(messages[1].role, 'user', 'role 保持 user：老 App 的渲染行为不能变');
  assert.equal(messages[1].noticeKind, 'subagent-settlement');
  assert.equal(messages[1].noticeVariant, 'completed');
  assert.equal(messages[1].noticeChildId, '915eb2f4-0d12-4b86-8922-b2b26cfc3ecc');
  assert.ok(messages[1].noticeBody.startsWith('2026-10-06'));
});

/* ------------------------------------------------------------------ *
 * convertSessionRecordsToMessages: 附件回传（缺陷 A）  [feat 2026-10-17]
 *
 * 事故现象：手机发出去的图片"被吞"——循环只拼 text part，所有 image/file part
 * 被丢掉，而 Web 端读原始事件所以看得到。实测用户发的截图 sha256:d4ca… 在会话
 * 日志里，网关返回的历史里连字段都没有。
 *
 * 下面的样本形状都是实测抄下来的（同一条 user/message 的 file part 没有 mediaType）。
 * ------------------------------------------------------------------ */

const XLSX_MIME = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

test('convertSessionRecordsToMessages: image/file part 归一成 attachments，且不回传内联字节', () => {
  // 实测形状：file part 只有 attachmentId/name/bytes，image part 还带 mediaType/width/height。
  const INLINE = 'JVBERi0xLjQKJcOkw7zDtsO2';   // 内联 base64 的样本片段
  const records = [
    {
      event: {
        type: 'user/message',
        seq: 340,
        time: 1000,
        data: {
          source: { kind: 'user' },
          content: [
            { type: 'file', attachment: { attachmentId: 'sha256:16bb0000', name: '工作日报.xlsx', bytes: 21769, data: INLINE } },
            {
              type: 'image',
              attachment: {
                attachmentId: 'sha256:d4ca0000',
                mediaType: 'image/jpeg',
                width: 736,
                height: 1600,
                bytes: 229795,
                name: 'scaled_7125.jpg'
              }
            },
            { type: 'text', text: '现在我要你帮我把这个工作日报的内容…' }
          ]
        }
      }
    }
  ];

  const { messages } = convertSessionRecordsToMessages(records);
  assert.equal(messages.length, 1);
  assert.equal(messages[0].content, '现在我要你帮我把这个工作日报的内容…', '文字照旧拼在一起');
  assert.deepEqual(messages[0].attachments, [
    // file：没有 mediaType、没有 width/height → 只出现有的键（推断值见下一个用例）。
    { id: 'sha256:16bb0000', mimeType: 'application/octet-stream', bytes: 21769, filename: '工作日报.xlsx' },
    // image：图片与文件同一形状，App 用 mimeType.startsWith('image/') 分流渲染。
    {
      id: 'sha256:d4ca0000',
      mimeType: 'image/jpeg',
      width: 736,
      height: 1600,
      bytes: 229795,
      filename: 'scaled_7125.jpg'
    }
  ]);
  // 正文里绝不能夹 base64：字节由手机走已认证的 /api/mobile/attachment 按需取。
  assert.ok(!JSON.stringify(messages).includes(INLINE), '内联 base64 不能被回传');
  assert.equal(messages[0].attachments[0].data, undefined);
});

test('convertSessionRecordsToMessages: mediaType 缺失时按扩展名推断，再不行 octet-stream', () => {
  const records = [
    {
      event: {
        type: 'user/message',
        seq: 1,
        data: {
          content: [
            { type: 'file', attachment: { attachmentId: 'a1', name: 'SHOT.PNG' } },
            { type: 'file', attachment: { attachmentId: 'a2', name: 'report.xlsx' } },
            { type: 'file', attachment: { attachmentId: 'a3', name: 'noext' } },
            { type: 'file', attachment: { attachmentId: 'a4', name: 'x.webp', width: '736' } },
            { type: 'text', text: '四个文件' }
          ]
        }
      }
    }
  ];

  const { messages } = convertSessionRecordsToMessages(records);
  const atts = messages[0].attachments;
  assert.equal(atts.length, 4);
  assert.equal(atts[0].mimeType, 'image/png', '扩展名大小写不敏感');
  assert.equal(atts[1].mimeType, 'application/octet-stream', 'xlsx 不在图片表里，不猜');
  assert.equal(atts[2].mimeType, 'application/octet-stream');
  assert.equal(atts[3].mimeType, 'image/webp');
  assert.equal(atts[3].width, undefined, '非数字尺寸要省略，不能塞 "736" 或 null');
  assert.deepEqual(atts[3], { id: 'a4', mimeType: 'image/webp', filename: 'x.webp' });
});

test('convertSessionRecordsToMessages: 没有 attachmentId 的 part 跳过，附件只出现在有附件的消息上', () => {
  const records = [
    {
      event: {
        type: 'user/message',
        seq: 1,
        data: {
          content: [
            // 老/发信形状（没有 attachment 对象）与"有 attachment 却没有 id"都要跳过。
            { type: 'image', mediaType: 'image/png' },
            { type: 'file', attachment: { name: 'a.bin', bytes: 3 } },
            { type: 'text', text: '只有文字' }
          ]
        }
      }
    },
    { event: { type: 'user/message', seq: 2, data: { content: '下一条纯文字' } } },
    { event: { type: 'user/message', seq: 3, data: { content: [{ type: 'text', text: '也没有附件' }] } } }
  ];

  const { messages } = convertSessionRecordsToMessages(records);
  assert.equal(messages.length, 3);
  assert.deepEqual(messages[0].attachments, undefined, '没造出空壳时这个键根本不该出现');
  assert.equal(messages[1].attachments, undefined, '老形状消息不带 attachments 键');
  assert.equal(messages[2].attachments, undefined);
});

test('convertSessionRecordsToMessages: 只有附件、没有文字的消息也要产出（否则截图永远挂不上）', () => {
  const records = [
    {
      event: {
        type: 'user/message',
        seq: 7,
        data: { source: { kind: 'user' }, content: [{ type: 'image', attachment: { attachmentId: 'sha256:beef', mediaType: 'image/png', bytes: 12, name: 'p.png' } }] }
      }
    },
    { event: { type: 'turn/end', seq: 9, data: { turn: 1, reason: { kind: 'completed' } } } }
  ];

  const { messages } = convertSessionRecordsToMessages(records);
  assert.equal(messages.length, 1, '纯附件消息必须留下宿主，否则附件没有挂载点');
  assert.equal(messages[0].role, 'user');
  assert.equal(messages[0].content, '', '没有文字就是空串');
  assert.deepEqual(messages[0].attachments, [
    { id: 'sha256:beef', mimeType: 'image/png', bytes: 12, filename: 'p.png' }
  ]);
});

test('convertSessionRecordsToMessages: 真的什么都没有仍然是原来的 drop + 留痕', () => {
  const dropped = [];
  const records = [
    // 没有 attachmentId 的 image part：连附件都拿不到 → 仍然算空文本丢
    { event: { type: 'user/message', seq: 42, data: { content: [{ type: 'image', mediaType: 'image/png' }] } } }
  ];
  const { messages } = convertSessionRecordsToMessages(records, { auditDropped: (info) => dropped.push(info) });
  assert.equal(messages.length, 0);
  assert.equal(dropped.length, 1);
  assert.equal(dropped[0].why, 'empty-user-text');
});

/* ------------------------------------------------------------------ *
 * convertSessionRecordsToMessages: 逐轮用量（缺陷 B）  [feat 2026-10-17]
 *
 * 事故现象 1："本轮用量"经常显示 —：引擎每个 step 的 assistant/message 都带 usage，
 * 而网关把这份数据扔了，App 只能靠两次 stats 读数相减，基线没记到就永远 —。
 * 注意 `inputTokens` 是"未缓存输入"、`totalTokens` 是**累计**值，所以逐 step 只能加
 * inputTokens + outputTokens。
 *
 * 事故现象 2（[fix 2026-10-17] 第二版）：第一版把**每一条 user/message** 当成"新一轮开始"，
 * 引擎插在回合中间的注入消息于是把这一轮的 usage 抢走，**真人那条永远是 null**。活数据：
 *   turn/start 1899 → user 1902(source.kind=user) → user 1903(time-context)
 *   → user 1904(dsh-mnemon) → assistant 1906..2059(每条带 usage, turn=6)
 *   → user 1954(又一个真人追问) → …
 * 后果：1902/1954/2949 这些真人消息 tokens 全 null，而 1843(time-context) 拿到 10008。
 *
 * 现在的规则（下面每个用例对应一条）：
 *   a. turn/start 是**权威**回合边界（不再用 user/message 开轮）；
 *   b. 载体只能是真人消息（readUserMessageSource(ev).human === true）；
 *   c. 一轮多条真人消息 → 按分段给值（这条消息 → 下一次你说话之间的量）；
 *   d. 必须 turn/end + 见过 usage + turn/start 在本段记录里(openedInWindow) 三者齐全，
 *      否则 null（**绝不写 0**）；
 *   e. 没有真人载体的轮（纯 schedule 唤醒）→ 用量丢弃，不挪给别人。
 * ------------------------------------------------------------------ */

const usageOf = (inputTokens, outputTokens, totalTokens) => ({ inputTokens, outputTokens, totalTokens, cacheReadTokens: 35584 });

/** 真人 user/message（source.kind='user' → human，是载体）。 */
const humanMsg = (seq, text) => ({
  event: { type: 'user/message', seq, time: 1000 + seq, data: { source: { kind: 'user' }, content: [{ type: 'text', text }] } }
});
/** 引擎注入的 user/message（不是人类 → 不承载、不结算）。 */
const injectedMsg = (seq, text, kind) => ({
  event: { type: 'user/message', seq, time: 1000 + seq, data: { source: { kind }, content: [{ type: 'text', text }] } }
});
const turnStart = (seq, turn) => ({ event: { type: 'turn/start', seq, data: { turn } } });
const turnEnd = (seq, turn) => ({ event: { type: 'turn/end', seq, data: { turn, reason: { kind: 'completed' } } } });
const assistantMsg = (seq, text, inputTokens, outputTokens, turn = 1) => ({
  event: {
    type: 'assistant/message',
    seq,
    data: { turn, step: 1, message: { content: [{ type: 'text', text }] }, usage: usageOf(inputTokens, outputTokens, 0) }
  }
});

test('convertSessionRecordsToMessages: 一轮两个 assistant 的 usage 相加（input+output）', () => {
  const records = [
    turnStart(9, 1),
    humanMsg(10, '跑一下'),
    assistantMsg(11, 'A', 282, 312),
    assistantMsg(12, 'B', 1000, 500),
    turnEnd(13, 1)
  ];

  const { messages } = convertSessionRecordsToMessages(records);
  const user = messages.find((m) => m.role === 'user');
  assert.equal(user.tokens, 282 + 312 + 1000 + 500);
});

test('convertSessionRecordsToMessages: totalTokens 是累计值，绝不能被计入', () => {
  // 实测样本：input 282 / output 312 / total 36178 / cacheRead 35584。
  // 若把 totalTokens 加进去，这一轮会从 594 被吹成 36772（差一个量级）。
  const records = [
    turnStart(0, 1),
    humanMsg(1, 'x'),
    { event: { type: 'assistant/message', seq: 2, data: { message: { content: [{ type: 'text', text: 'a' }] }, usage: usageOf(282, 312, 36178) } } },
    { event: { type: 'assistant/message', seq: 3, data: { message: { content: [{ type: 'text', text: 'b' }] }, usage: usageOf(400, 100, 999999) } } },
    turnEnd(4, 1)
  ];

  const { messages } = convertSessionRecordsToMessages(records);
  assert.equal(messages[0].tokens, 282 + 312 + 400 + 100);
  assert.notEqual(messages[0].tokens, 282 + 312 + 36178 + 400 + 100 + 999999);
});

test('convertSessionRecordsToMessages: 未结束的轮 tokens 必须是 null（不是部分和、不是 0）', () => {
  const records = [
    turnStart(1, 1),            // 回合已经开始（openedInWindow 成立）
    humanMsg(2, '还在跑'),
    assistantMsg(3, 'a', 282, 312)
    // 没有 turn/end：回合还在跑
  ];

  const { messages } = convertSessionRecordsToMessages(records);
  assert.equal(messages[0].tokens, null, '中途值会被读成"这轮就花了这么多"，宁可不给');
  assert.ok('tokens' in messages[0], '字段要在（值为 null），App 才能区分"未知"与"老网关没有这个字段"');
});

test('convertSessionRecordsToMessages: 一条 usage 都没有的轮 → null，缺 usage 的工具步不影响整轮', () => {
  const noUsage = [
    turnStart(0, 1),
    humanMsg(1, '嗨'),
    { event: { type: 'assistant/message', seq: 2, data: { message: { content: [{ type: 'text', text: '在' }] } } } },
    turnEnd(3, 1)
  ];
  assert.equal(convertSessionRecordsToMessages(noUsage).messages[0].tokens, null, '全员缺 usage → null，绝不写 0');

  // 工具步（无 usage）夹在两个有 usage 的 step 之间：0 贡献，但整轮仍然成立。
  const mixed = [
    turnStart(9, 2),
    humanMsg(10, '查一下'),
    assistantMsg(11, 'A', 100, 10),
    { event: { type: 'tool/call', seq: 12, data: { name: 'gtw', arguments: {}, callId: 'c1' } } },
    { event: { type: 'assistant/message', seq: 13, data: { message: { content: [] } } } },   // 工具步：没有 usage
    assistantMsg(14, 'B', 200, 20),
    turnEnd(15, 2)
  ];
  assert.equal(convertSessionRecordsToMessages(mixed).messages[0].tokens, 100 + 10 + 200 + 20);
});

test('convertSessionRecordsToMessages: 多轮各自结算，跑到一半的那轮是 null', () => {
  const records = [
    // 第一轮：已结束
    turnStart(9, 1),
    humanMsg(10, '问题一'),
    assistantMsg(11, '答一', 100, 50),
    turnEnd(12, 1),
    // 第二轮：还在跑（没有 turn/end）
    turnStart(19, 2),
    humanMsg(20, '问题二'),
    assistantMsg(21, '答二', 700, 70)
  ];

  const { messages } = convertSessionRecordsToMessages(records);
  const users = messages.filter((m) => m.role === 'user');
  assert.equal(users.length, 2);
  assert.equal(users[0].tokens, 150, '第一轮已见到 turn/end → 结算');
  assert.equal(users[1].tokens, null, '第二轮没有 turn/end → null');
});

/* ------------------------------------------------------------------ *
 * [fix 2026-10-17] 用量归属的三个关键边界（第二版补的用例）
 * ------------------------------------------------------------------ */

test('convertSessionRecordsToMessages: 注入夹在真人与 assistant 之间时，用量落在真人那条上', () => {
  // 活数据时序：turn/start 1899 → user 1902(真人) → user 1903(time-context)
  // → assistant 带 usage → turn/end。第一版把 1902 的轮在 1903 处切掉，于是 1903 抢走了
  // 本轮的 usage，而 1902 是 null —— 注入消息要么被网关丢弃、要么在 App 里渲染成通知卡，
  // 用量就此凭空消失。
  const records = [
    turnStart(1899, 6),
    humanMsg(1902, '看一下网关日志'),
    injectedMsg(1903, 'Current time: 2026-10-17T09:24:13+08:00[Asia/Shanghai]', 'time-context'),
    assistantMsg(1906, '好', 2000, 300, 6),
    assistantMsg(1907, '继续', 1000, 96, 6),
    turnEnd(2059, 6)
  ];

  const { messages } = convertSessionRecordsToMessages(records);
  const humans = messages.filter((m) => m.role === 'user' && !m.noticeKind);
  const injected = messages.filter((m) => m.noticeKind === 'time-context');
  assert.equal(humans.length, 1, '只有一条真人消息');
  assert.equal(injected.length, 1, '注入消息仍然产出（App 渲染成通知卡），只是不承载用量');
  assert.equal(humans[0].tokens, 2000 + 300 + 1000 + 96, '本轮的用量必须落在真人那条上');
  assert.equal(injected[0].tokens, null, '注入消息不是载体：不承载、不结算（绝不能是从真人那儿抢走的）');
});

test('convertSessionRecordsToMessages: 一轮两条真人消息（回合中追问）各自拿分段值，两段之和 = 该轮总和', () => {
  // 活数据：1902 与 1954 同属 turn 6（1954 是用户在回合进行中的追问）。
  // 分段语义："这条消息到下一次你说话之间烧掉的量"；把整轮的量全塞给第一条会谎报单条成本。
  const records = [
    turnStart(1899, 6),
    humanMsg(1902, '看一下网关日志'),
    assistantMsg(1906, 'A', 1000, 100, 6),
    assistantMsg(1930, 'B', 500, 50, 6),
    humanMsg(1954, '顺便把测试也跑了'),      // 同一轮的第二条真人消息
    assistantMsg(1955, 'C', 400, 40, 6),
    assistantMsg(2000, 'D', 600, 60, 6),
    turnEnd(2059, 6)
  ];

  const { messages } = convertSessionRecordsToMessages(records);
  const humans = messages.filter((m) => m.role === 'user');
  assert.equal(humans.length, 2);
  const total = 1000 + 100 + 500 + 50 + 400 + 40 + 600 + 60;
  assert.equal(humans[0].tokens, 1000 + 100 + 500 + 50, '第一条：它之后到第二次说话之间烧掉的量');
  assert.equal(humans[1].tokens, 400 + 40 + 600 + 60, '最后一条：吃到轮尾');
  assert.equal(humans[0].tokens + humans[1].tokens, total, '两段之和必须等于该轮总和（不重不漏）');
});

test('convertSessionRecordsToMessages: 分页从轮中间切进来（有 turn/end 但窗口里没有 turn/start）→ null', () => {
  // 窗口从轮中间开始：这条真人消息是本轮的载体，但开头那段 usage 在上一页，
  // 累加和是残缺的 —— 宁可 null 也不错报（openedInWindow 不成立）。
  const midTurn = [
    humanMsg(1954, '顺便把测试也跑了'),
    assistantMsg(1955, 'C', 400, 40, 6),
    turnEnd(2059, 6)
  ];
  const cut = convertSessionRecordsToMessages(midTurn);
  assert.equal(cut.messages.filter((m) => m.role === 'user')[0].tokens, null, '窗口里没有 turn/start → 数据不全 → null');

  // 紧接着的下一个轮 turn/start 在窗口里 → 它自己是完整的，照常结算；
  // 上面残缺那段既不会算进它，也不会被它吞掉。
  const withNextTurn = [
    humanMsg(1954, '顺便把测试也跑了'),
    assistantMsg(1955, 'C', 400, 40, 6),
    turnEnd(2059, 6),
    turnStart(2100, 7),
    humanMsg(2102, '新问题'),
    assistantMsg(2103, '答', 100, 20, 7),
    turnEnd(2104, 7)
  ];
  const users = convertSessionRecordsToMessages(withNextTurn).messages.filter((m) => m.role === 'user');
  assert.equal(users[0].tokens, null, '残缺轮仍然是 null');
  assert.equal(users[1].tokens, 120, '下一个轮自己有 turn/start + turn/end + usage → 只算它自己的 120');

  // 同一个门也想挡住"真人消息排在它自己的 turn/start 之前"这种时序：那条消息没有
  // 在窗口里的 turn/start 可依，宁可 null 也不猜它属于哪个轮（实测时序不是这样）。
  const reversed = convertSessionRecordsToMessages([
    humanMsg(2102, '新问题'),
    turnStart(2103, 7),
    assistantMsg(2104, '答', 100, 20, 7),
    turnEnd(2105, 7)
  ]);
  assert.equal(reversed.messages.filter((m) => m.role === 'user')[0].tokens, null, '载体在自己的 turn/start 之前 → null，不猜');
});

test('convertSessionRecordsToMessages: 没有真人载体的轮（纯 schedule 唤醒）用量丢弃，前后都不沾', () => {
  const records = [
    // 第一轮：真人提问 → 正常结算
    turnStart(99, 1),
    humanMsg(100, '问题一'),
    assistantMsg(101, '答一', 100, 20, 1),
    turnEnd(102, 1),
    // 第二轮：只有 schedule 注入唤醒，一条真人消息都没有
    turnStart(199, 2),
    injectedMsg(200, '[SCHEDULE REMINDER BATCH] 提醒：看一下部署', 'schedule'),
    assistantMsg(201, '收到', 700, 70, 2),
    turnEnd(202, 2),
    // 第三轮：又是真人提问
    turnStart(299, 3),
    humanMsg(300, '问题三'),
    assistantMsg(301, '答三', 5, 5, 3),
    turnEnd(302, 3)
  ];

  const { messages } = convertSessionRecordsToMessages(records);
  const humans = messages.filter((m) => m.role === 'user' && !m.noticeKind);
  assert.equal(humans.length, 2);
  assert.equal(humans[0].tokens, 120, '第一轮的量不能被 schedule 轮抢走');
  assert.equal(humans[1].tokens, 10, '第三轮也不该把中间那轮的 770 吞进来');
  const injected = messages.filter((m) => m.noticeKind);
  assert.equal(injected.length, 1);
  assert.equal(injected[0].tokens, null, '没有载体的轮：用量丢弃，不挪给上一条或下一条');
});

test('convertSessionRecordsToMessages: 注入通知仍然保持既有语义，并同样带上 tokens', () => {
  const records = [
    { event: { type: 'user/message', seq: 1, time: 1000, data: { source: { kind: 'user' }, content: [{ type: 'text', text: '帮我改一下登录' }] } } },
    { event: { type: 'user/message', seq: 2, time: 2000, data: { content: [{ type: 'text', text: SETTLEMENT_TEXT }] } } }
  ];

  const { messages } = convertSessionRecordsToMessages(records);
  assert.equal(messages.length, 2);
  assert.equal(messages[0].role, 'user');
  assert.equal(messages[0].noticeKind, undefined, '真人消息不该带任何通知字段');
  assert.equal(messages[0].tokens, null, '窗口里没有 turn/start（更没有 turn/end）→ 不给值');
  assert.equal(messages[0].attachments, undefined);
  assert.equal(messages[1].role, 'user', 'role 保持 user：老 App 的渲染行为不能变');
  assert.equal(messages[1].noticeKind, 'subagent-settlement');
  assert.equal(messages[1].tokens, null, '注入消息不是载体：不承载用量');
  assert.equal(messages[1].attachments, undefined);
});

