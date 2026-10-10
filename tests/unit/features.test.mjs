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
  describeSchedule,
  normalizeSchedule,
  buildNtfyRequest,
  pushForEvent,
  handleFeatureRoute
} from '../../dsh-server-plugin/lib/features.mjs';

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

test('buildNtfyRequest: joins topic onto the base URL and carries the token', () => {
  const req = buildNtfyRequest(
    { ntfyUrl: 'https://ntfy.sh/', ntfyTopic: 'dsh-abc', ntfyToken: 'tk_x' },
    { title: '需要你授权', body: 'pwsh：删除文件', priority: 5, tags: ['lock'], click: 'dshmobile://open?session=session-1' }
  );
  assert.equal(req.url, 'https://ntfy.sh/dsh-abc');
  assert.equal(req.headers.Authorization, 'Bearer tk_x');
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

test('buildNtfyRequest: an inline topic overrides the configured one', () => {
  const req = buildNtfyRequest({ ntfyUrl: 'https://ntfy.sh', ntfyTopic: 'default' }, { topic: 'per-device' });
  assert.equal(req.url, 'https://ntfy.sh/per-device');
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
 * route table
 * ------------------------------------------------------------------ */

function makeHarness(overrides = {}) {
  const calls = { sent: [], rpc: [], audits: [], streams: [], files: [] };
  const deps = {
    pathname: '',
    req: { method: 'GET' },
    parsedUrl: { query: {} },
    jsonBody: {},
    auth: { device: { id: 'test', role: 'readwrite' } },
    sendJson: (status, body) => calls.sent.push({ status, body }),
    sendFile: async (p, name) => { calls.files.push({ p, name }); return true; },
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
  assert.equal(calls.files.length, 0, 'no file may be streamed');
  assert.equal(calls.sent[0].status, 403);
});

test('route: deliverable download streams a declared file', async () => {
  const { deps, calls } = makeHarness({
    sessionRecords: { records: [{ event: { type: 'deliverables/presented', seq: 1, data: { files: [{ path: 'out/ok.docx' }] } } }], cwd: '/w' }
  });
  deps.pathname = '/api/mobile/deliverables/download';
  deps.parsedUrl = { query: { sessionId: 's', path: path.resolve('/w/out/ok.docx') } };
  await handleFeatureRoute(deps);
  assert.equal(calls.files.length, 1);
  assert.equal(calls.files[0].name, 'out/ok.docx');
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
