/**
 * Unit tests for the bridge extensions (2026-10-13): path confinement, the
 * command whitelist, git-repo discovery, job frames from `session/control`,
 * preset validation, git-repo-relative tool-call extraction, goal board, fork
 * checkpoints, and the route dispatcher.
 *
 * Hermetic on purpose: every test builds its own tree under `os.tmpdir()` and
 * imports the real implementations. No gateway, no engine, no session, no LLM.
 * `handleExtensionRoute` is driven directly with a fake `sendJson`, exactly the
 * shape `lib/index.js` calls it with — so a route that answers the wrong status
 * or forgets to return `true` fails here rather than on a phone.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  describeDeliverableRefusal,
  extractDeliverables,
  resolveDeliverable
} from '../../dsh-server-plugin/lib/core.mjs';

import {
  QUICK_COMMANDS,
  contentTypeFor,
  discoverGitRepos,
  isInside,
  isTextLike,
  listDirectory,
  quickCommandCatalog,
  readTextFile,
  resolveConfined,
  resolveQuickCommand
} from '../../dsh-server-plugin/lib/host-ops.mjs';

import {
  EXTENSION_ROUTES,
  claimsExtensionRoute,
  extractCheckpoints,
  extractToolCallFiles,
  generatePushTopic,
  handleExtensionRoute,
  lastUserTurnStartSeq,
  normalizeJob,
  normalizeJobChunk,
  normalizePresetCatalog,
  ntfyLinks,
  orderJobs,
  presetToWire,
  summarizeGoalBoard,
  summarizeJobFollow,
  summarizeLiveGoal,
  validatePresetInput
} from '../../dsh-server-plugin/lib/extensions.mjs';

/* ------------------------------------------------------------------ *
 * fixtures
 * ------------------------------------------------------------------ */

/** A throwaway tree: `<tmp>/<workspace>/…`, removed when the test ends. */
function makeWorkspace(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-bridge-ext-'));
  const ws = path.join(root, 'workspace');
  fs.mkdirSync(path.join(ws, 'src', 'deep'), { recursive: true });
  fs.mkdirSync(path.join(ws, 'docs'), { recursive: true });
  fs.mkdirSync(path.join(ws, 'node_modules', 'ignored'), { recursive: true });
  fs.writeFileSync(path.join(ws, 'README.md'), '# hello\n');
  fs.writeFileSync(path.join(ws, 'src', 'main.dart'), 'void main() {}\n');
  fs.writeFileSync(path.join(ws, 'src', 'deep', 'x.txt'), 'deep\n');
  fs.writeFileSync(path.join(ws, 'blob.bin'), Buffer.from([0x00, 0x01, 0x02, 0xff]));
  fs.mkdirSync(path.join(root, 'outside'), { recursive: true });
  fs.writeFileSync(path.join(root, 'outside', 'secret.txt'), 'secret\n');
  t.after(() => {
    try { fs.rmSync(root, { recursive: true, force: true }); } catch { /* best effort */ }
  });
  return { root, ws };
}

/** Mark a directory as a git repository root (worktrees use a `.git` file). */
function markRepo(dir) {
  fs.mkdirSync(path.join(dir, '.git'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.git', 'HEAD'), 'ref: refs/heads/main\n');
}

/** One `session/page` record: `{ event: { type, seq, time, data } }`. */
function rec(type, seq, data, time = 1000 + seq) {
  return { event: { type, seq, time, data } };
}

/* ------------------------------------------------------------------ *
 * 1. path confinement
 * ------------------------------------------------------------------ */

test('resolveConfined: accepts paths inside the workspace', (t) => {
  const { ws } = makeWorkspace(t);
  const root = resolveConfined(ws, '');
  assert.equal(root.ok, true);
  assert.equal(root.rel, '');

  const nested = resolveConfined(ws, 'src/deep/x.txt');
  assert.equal(nested.ok, true);
  assert.equal(nested.rel, 'src/deep/x.txt');
  assert.equal(fs.readFileSync(nested.abs, 'utf8'), 'deep\n');
});

test('resolveConfined: refuses every escape shape', (t) => {
  const { ws } = makeWorkspace(t);
  const cases = [
    ['../outside/secret.txt', 403],
    ['src/../../outside/secret.txt', 403],
    ['/etc/passwd', 403],
    ['C:/Windows/win.ini', 403],
    ['\\\\?\\C:\\Windows', 403],
    ['src/\u0000evil', 400],
    ['does-not-exist.txt', 404]
  ];
  for (const [requested, status] of cases) {
    const r = resolveConfined(ws, requested);
    assert.equal(r.ok, false, `expected refusal for ${JSON.stringify(requested)}`);
    assert.equal(r.status, status, `wrong status for ${JSON.stringify(requested)}`);
  }
});

test('resolveConfined: a symlink pointing outside the workspace is refused', (t) => {
  const { root, ws } = makeWorkspace(t);
  const link = path.join(ws, 'escape-link');
  try {
    fs.symlinkSync(path.join(root, 'outside'), link, 'dir');
  } catch {
    t.skip('symlink creation not permitted on this host');
    return;
  }
  const r = resolveConfined(ws, 'escape-link/secret.txt');
  assert.equal(r.ok, false);
  assert.equal(r.status, 403);
  assert.match(r.error, /symlink|escapes/);
});

test('resolveConfined: no workspace is a hard refusal, never a fallback', () => {
  for (const cwd of ['', null, undefined, '   ']) {
    const r = resolveConfined(cwd, 'x.txt');
    assert.equal(r.ok, false);
    assert.equal(r.status, 409);
    assert.equal(r.error, 'no-workspace');
  }
});

test('isInside: does not confuse a sibling prefix with a child', (t) => {
  const { root } = makeWorkspace(t);
  assert.equal(isInside(root, path.join(root, 'workspace')), true);
  assert.equal(isInside(path.join(root, 'work'), path.join(root, 'workspace')), false);
});

/* ------------------------------------------------------------------ *
 * 2. directory listing + text reads
 * ------------------------------------------------------------------ */

test('listDirectory: directories first, then case-insensitive name order', (t) => {
  const { ws } = makeWorkspace(t);
  const listed = listDirectory(ws);
  assert.equal(listed.ok, true);
  const names = listed.entries.map((e) => e.name);
  const dirs = listed.entries.filter((e) => e.kind === 'dir').map((e) => e.name);
  const files = listed.entries.filter((e) => e.kind === 'file').map((e) => e.name);
  assert.deepEqual(names, [...dirs, ...files]);
  assert.deepEqual(dirs, ['docs', 'node_modules', 'src']);
  assert.deepEqual(files, ['blob.bin', 'README.md']);
  const readme = listed.entries.find((e) => e.name === 'README.md');
  assert.equal(readme.size, 8);
  assert.equal(typeof readme.mtime, 'number');
});

test('listDirectory: caps rows and reports truncation instead of hiding it', (t) => {
  const { ws } = makeWorkspace(t);
  const listed = listDirectory(ws, { maxEntries: 2 });
  assert.equal(listed.truncated, true);
  assert.equal(listed.entries.length, 2);
  assert.equal(listed.total, 5);
});

test('listDirectory: a missing path reports a reason, never a raw fs error', () => {
  const listed = listDirectory(path.join(os.tmpdir(), 'dsh-definitely-absent-xyz'));
  assert.equal(listed.ok, false);
  assert.equal(listed.reason, 'not-found');
});

test('readTextFile: text in, binary flagged, truncation reported', (t) => {
  const { ws } = makeWorkspace(t);
  const good = readTextFile(path.join(ws, 'README.md'));
  assert.equal(good.ok, true);
  assert.equal(good.binary, false);
  assert.equal(good.content, '# hello\n');
  assert.equal(good.truncated, false);

  const binary = readTextFile(path.join(ws, 'blob.bin'));
  assert.equal(binary.ok, true);
  assert.equal(binary.binary, true);
  assert.equal(binary.content, undefined);

  const big = path.join(ws, 'big.txt');
  fs.writeFileSync(big, 'a'.repeat(5000));
  const clipped = readTextFile(big, { maxBytes: 1024 });
  assert.equal(clipped.truncated, true);
  assert.equal(clipped.content.length, 1024);
  assert.equal(clipped.size, 5000);
});

test('contentTypeFor / isTextLike: preview decisions', () => {
  assert.match(contentTypeFor('notes.md'), /text\/markdown/);
  assert.equal(contentTypeFor('photo.png'), 'image/png');
  assert.equal(contentTypeFor('archive.zip'), null);
  assert.equal(isTextLike('a.dart'), true);
  assert.equal(isTextLike('a.zip'), false);
  assert.equal(isTextLike('Dockerfile'), true);
  assert.equal(isTextLike('mystery'), false);
  assert.equal(isTextLike('mystery', 'plain ascii'), true);
  assert.equal(isTextLike('mystery', 'has\u0000nul'), false);
});

/* ------------------------------------------------------------------ *
 * 3. git repo discovery
 * ------------------------------------------------------------------ */

test('discoverGitRepos: cwd itself is a repo', (t) => {
  const { ws } = makeWorkspace(t);
  markRepo(ws);
  const found = discoverGitRepos(ws);
  assert.equal(found.self, true);
  assert.equal(found.primaryRoot, ws);
  assert.deepEqual(found.children, []);
});

test('discoverGitRepos: a nested cwd finds its ancestor repo', (t) => {
  const { ws } = makeWorkspace(t);
  markRepo(ws);
  const found = discoverGitRepos(path.join(ws, 'src', 'deep'));
  assert.equal(found.self, false);
  assert.equal(found.primaryRoot, ws);
  assert.ok(found.ancestors.includes(ws));
});

test('discoverGitRepos: the multi-project workspace case that used to go blank', (t) => {
  // This is the measured real layout: the session cwd is NOT a repo, but its
  // children are. The old code answered a flat not-a-git-repository.
  const { ws } = makeWorkspace(t);
  const alpha = path.join(ws, 'alpha');
  const beta = path.join(ws, 'beta');
  fs.mkdirSync(alpha, { recursive: true });
  fs.mkdirSync(beta, { recursive: true });
  markRepo(alpha);
  markRepo(beta);

  const found = discoverGitRepos(ws);
  assert.equal(found.self, false);
  assert.equal(found.primaryRoot, alpha);
  assert.deepEqual(found.children.map((c) => c.name), ['alpha', 'beta']);
});

test('discoverGitRepos: node_modules and dot directories are not candidates', (t) => {
  const { ws } = makeWorkspace(t);
  markRepo(path.join(ws, 'node_modules', 'ignored'));
  const hidden = path.join(ws, '.hidden');
  fs.mkdirSync(hidden, { recursive: true });
  markRepo(hidden);
  const found = discoverGitRepos(ws);
  assert.deepEqual(found.children, []);
  assert.equal(found.primaryRoot, null);
});

/* ------------------------------------------------------------------ *
 * 4. command whitelist
 * ------------------------------------------------------------------ */

test('quick commands: the catalog never leaks argv and ids resolve exactly', () => {
  const catalog = quickCommandCatalog();
  assert.equal(catalog.length, QUICK_COMMANDS.length);
  for (const row of catalog) {
    assert.deepEqual(Object.keys(row).sort(), ['danger', 'description', 'group', 'id', 'label']);
  }
  assert.equal(resolveQuickCommand('git-status')?.id, 'git-status');
  assert.equal(resolveQuickCommand('rm -rf /'), null);
  assert.equal(resolveQuickCommand('git-status; rm -rf /'), null);
  assert.equal(resolveQuickCommand(''), null);
  assert.equal(resolveQuickCommand(undefined), null);
});

test('quick commands: no entry accepts a client-supplied argument', () => {
  // The whole security argument rests on this: argv is a closed server-side
  // constant, so there is no injection surface to defend.
  for (const spec of QUICK_COMMANDS) {
    assert.ok(Array.isArray(spec.argv) && spec.argv.length > 0, `${spec.id} has argv`);
    assert.equal(spec.params, undefined, `${spec.id} must not declare parameters`);
  }
});

test('quick commands: only the mutating git add is flagged dangerous', () => {
  const dangerous = QUICK_COMMANDS.filter((c) => c.danger === true).map((c) => c.id);
  assert.deepEqual(dangerous, ['git-add-all']);
});

/* ------------------------------------------------------------------ *
 * 5. tool-call file extraction (diff fallback)
 * ------------------------------------------------------------------ */

test('extractToolCallFiles: keeps mutating calls, newest seq wins per path', (t) => {
  const { ws } = makeWorkspace(t);
  const records = [
    rec('tool/call', 10, { name: 'write', arguments: { file_path: 'src/a.dart' } }),
    rec('tool/call', 20, { name: 'edit', arguments: { file_path: 'src/a.dart' } }),
    rec('tool/call', 30, { name: 'edit', arguments: JSON.stringify({ file_path: 'docs/b.md' }) }),
    rec('tool/call', 40, { name: 'read', arguments: { file_path: 'README.md' } }),
    rec('tool/call', 50, { name: 'bash', arguments: { command: 'rm -rf /' } })
  ];
  const { changed, read } = extractToolCallFiles(records, ws);

  assert.deepEqual(changed.map((c) => c.display), ['docs/b.md', 'src/a.dart']);
  assert.equal(changed.find((c) => c.display === 'src/a.dart').tool, 'edit');
  assert.equal(changed.find((c) => c.display === 'src/a.dart').seq, 20);
  assert.deepEqual(read.map((r) => r.display), ['README.md']);
});

test('extractToolCallFiles: drops paths outside the workspace and unparsable args', (t) => {
  const { root, ws } = makeWorkspace(t);
  const records = [
    rec('tool/call', 10, { name: 'write', arguments: { file_path: path.join(root, 'outside', 'secret.txt') } }),
    rec('tool/call', 20, { name: 'write', arguments: { file_path: '../outside/secret.txt' } }),
    rec('tool/call', 30, { name: 'write', arguments: '{"file_path":"truncated' }),
    rec('tool/call', 40, { name: 'write', arguments: null }),
    rec('tool/call', 50, { name: 'write', arguments: { file_path: 'inside.txt' } })
  ];
  const { changed } = extractToolCallFiles(records, ws);
  assert.deepEqual(changed.map((c) => c.display), ['inside.txt']);
});

/* ---- turn membership (the "what did THIS turn change" half of the diff) ---- */

test('lastUserTurnStartSeq: answers the NEWEST human message, not the first', () => {
  const records = [
    rec('user/message', 5, {}),
    rec('tool/call', 10, { name: 'write', arguments: { file_path: 'a.txt' } }),
    rec('user/message', 30, {}),
    rec('tool/call', 40, { name: 'write', arguments: { file_path: 'b.txt' } })
  ];
  assert.equal(lastUserTurnStartSeq(records), 30);
});

test('lastUserTurnStartSeq: null when the window holds no human message', () => {
  assert.equal(lastUserTurnStartSeq([rec('tool/call', 10, { name: 'write' })]), null);
  assert.equal(lastUserTurnStartSeq([]), null);
  assert.equal(lastUserTurnStartSeq(null), null);
});

test('extractToolCallFiles: marks only post-message calls as this turn', (t) => {
  const { ws } = makeWorkspace(t);
  const records = [
    rec('tool/call', 10, { name: 'write', arguments: { file_path: 'src/old.dart' } }),
    rec('user/message', 30, {}),
    rec('tool/call', 40, { name: 'write', arguments: { file_path: 'src/new.dart' } })
  ];
  const { changed, turnStartSeq } = extractToolCallFiles(records, ws);

  assert.equal(turnStartSeq, 30);
  assert.equal(changed.find((c) => c.display === 'src/new.dart').thisTurn, true);
  assert.equal(changed.find((c) => c.display === 'src/old.dart').thisTurn, false);
});

test('extractToolCallFiles: unknown boundary is null, never an implicit true', (t) => {
  // The regression this guards: treating "no user/message in the window" as
  // "everything belongs to this turn" would relabel a repository's entire
  // uncommitted backlog as this turn's work, which is exactly the wrong answer.
  const { ws } = makeWorkspace(t);
  const records = [
    rec('tool/call', 10, { name: 'write', arguments: { file_path: 'src/a.dart' } })
  ];
  const { changed, turnStartSeq } = extractToolCallFiles(records, ws);

  assert.equal(turnStartSeq, null);
  assert.equal(changed[0].thisTurn, null);
});

/* ------------------------------------------------------------------ *
 * 6. jobs — the real `job` namespace (`JobView` / `JobChunk`)
 * ------------------------------------------------------------------ */

/**
 * A real `JobView` as `@deepseek-ai/dsh-jobs/view` declares it.
 *
 * ⚠️ These tests replaced a set built on `jobsFromControlFrame`, which encoded a
 * false premise (that no `job/*` Remote exists). The helper is gone; the shape
 * below is the engine's actual projection.
 */
function jobView(overrides = {}) {
  return {
    id: 'bash-1',
    kind: 'bash',
    label: 'sleep 60',
    status: 'running',
    startedAt: 1000,
    output: { total: 120, earliest: 0 },
    ...overrides
  };
}

test('normalizeJob: reads the real JobView, including output coordinates', () => {
  const row = normalizeJob(jobView({ status: 'running', owner: 'session-abc' }));
  assert.equal(row.id, 'bash-1');
  assert.equal(row.owned, true);
  assert.equal(row.live, true);
  assert.equal(row.outputTotal, 120);
  assert.equal(row.outputEarliest, 0);

  // An unowned job is visible to every session, which is a real engine state.
  assert.equal(normalizeJob(jobView()).owned, false);
  // `spillPaths` is a host path list and must never reach the wire.
  const withSpill = normalizeJob(jobView({ output: { total: 5, earliest: 2, spillPaths: ['C:/secret/spill.log'] } }));
  assert.equal(JSON.stringify(withSpill).includes('spill'), false);
});

test('normalizeJob: rejects rows without an id and refuses unknown statuses', () => {
  assert.equal(normalizeJob({ kind: 'bash' }), null);
  assert.equal(normalizeJob(null), null);
  // An unknown status must not be trusted verbatim.
  assert.equal(normalizeJob(jobView({ status: 'weird' })).status, 'running');
  // finishedAt + startedAt produce the settled duration.
  const done = normalizeJob(jobView({ status: 'completed', startedAt: 100, finishedAt: 350 }));
  assert.equal(done.live, false);
  assert.equal(done.durationMs, 250);
  assert.equal(done.outputTotal, 120);
});

test('orderJobs: live first in start order, settled newest-first', () => {
  const rows = orderJobs([
    jobView({ id: 'bash-1', status: 'completed', startedAt: 100, finishedAt: 200 }),
    jobView({ id: 'bash-2', status: 'running', startedAt: 300 }),
    jobView({ id: 'bash-3', status: 'running', startedAt: 250 }),
    jobView({ id: 'bash-4', status: 'failed', startedAt: 150, finishedAt: 400 })
  ]);
  assert.deepEqual(rows.map((r) => r.id), ['bash-3', 'bash-2', 'bash-4', 'bash-1']);
});

test('normalizeJobChunk: keeps the stream label and the loss markers', () => {
  assert.deepEqual(normalizeJobChunk({ at: 0, text: 'hi', channel: 'stdout' }), {
    at: 0, text: 'hi', channel: 'stdout', gapBefore: false
  });
  // Producer narration is a real channel; `stderr` must survive so the UI can
  // colour it.
  assert.equal(normalizeJobChunk({ at: 4, text: 'x', channel: 'stderr' }).channel, 'stderr');
  assert.equal(normalizeJobChunk({ at: 4, text: 'x', channel: 'log' }).channel, 'log');
  // An unrecognized or absent label reads like an absent one, matching the
  // engine's own consumer contract.
  assert.equal(normalizeJobChunk({ at: 4, text: 'x', channel: 'nope' }).channel, '');
  assert.equal(normalizeJobChunk({ at: 4, text: 'x' }).channel, '');
  assert.equal(normalizeJobChunk({ at: 4, text: 'x', gapBefore: true }).gapBefore, true);
  assert.equal(normalizeJobChunk(null), null);
});

test('summarizeJobFollow: opened + output + status, with the resume cursor', () => {
  const view = summarizeJobFollow([
    { type: 'opened', job: jobView({ status: 'running' }), from: 0 },
    { type: 'output', chunks: [{ at: 0, text: 'build ', channel: 'stdout' }], next: 6 },
    { type: 'output', chunks: [{ at: 6, text: 'failed\n', channel: 'stderr' }], next: 13, lossy: true },
    { type: 'status', job: jobView({ status: 'failed', detail: 'exit code: 1', finishedAt: 2000 }) }
  ]);
  assert.equal(view.ok, true);
  assert.equal(view.lines.length, 2);
  assert.equal(view.lines[0].text, 'build ');
  assert.equal(view.lines[1].channel, 'stderr');
  assert.equal(view.next, 13);
  // A loss in ANY frame makes the whole answer lossy: the phone's log is
  // incomplete somewhere, so claiming completeness would be a lie.
  assert.equal(view.lossy, true);
  assert.equal(view.settled, true);
  assert.equal(view.job.status, 'failed');
  assert.equal(view.job.detail, 'exit code: 1');
});

test('summarizeJobFollow: a still-running job is NOT reported as settled', () => {
  const view = summarizeJobFollow([
    { type: 'opened', job: jobView({ status: 'running' }), from: 0 },
    { type: 'output', chunks: [{ at: 0, text: 'partial' }], next: 7 }
  ]);
  // No `status` frame arrived, so settlement is unknown — never inferred from
  // the mere absence of further output.
  assert.equal(view.settled, false);
  assert.equal(view.lossy, false);
  assert.equal(view.next, 7);
});

test('summarizeJobFollow: an empty or anchorless stream is honestly empty', () => {
  assert.deepEqual(summarizeJobFollow([]), { ok: true, job: null, lines: [], next: null, lossy: false, settled: false });
  assert.equal(summarizeJobFollow(null).ok, true);
  // Output with no `opened` anchor cannot name a job; the lines still surface.
  const orphan = summarizeJobFollow([{ type: 'output', chunks: [{ at: 0, text: 'x' }], next: 1 }]);
  assert.equal(orphan.job, null);
  assert.equal(orphan.next, 1);
});

/* ------------------------------------------------------------------ *
 * 7. live goal view + preset catalog
 * ------------------------------------------------------------------ */

test('summarizeLiveGoal: reads GoalView and keeps activation distinct from phase', () => {
  const board = summarizeLiveGoal({
    id: 'goal-9',
    revision: 7,
    objective: 'ship',
    phase: 'active',
    activation: 'disarmed',
    maxGoalRounds: 8,
    roundsStarted: 2,
    createdAt: 1,
    updatedAt: 2
  });
  assert.equal(board.present, true);
  assert.equal(board.source, 'live');
  assert.equal(board.activation, 'disarmed');
  // The whole point of surfacing activation: an active goal can be disarmed.
  assert.equal(board.phase, 'active');
  assert.equal(board.roundsRemaining, 6);
  assert.equal(board.progress, 0.25);
  // No goal for this session: null, which the route turns into present:false.
  assert.equal(summarizeLiveGoal(null), null);
  assert.equal(summarizeLiveGoal({}), null);
});

test('normalizePresetCatalog: unwraps the engine options, null when shapeless', () => {
  const catalog = normalizePresetCatalog({ options: [{ value: 'read-only', name: 'read-only' }, { value: 'full-access' }] });
  assert.deepEqual(catalog.options[0], { value: 'read-only', name: 'read-only' });
  // A missing `name` falls back to the value rather than rendering blank.
  assert.equal(catalog.options[1].name, 'full-access');
  assert.equal(normalizePresetCatalog({}), null);
  assert.equal(normalizePresetCatalog(null), null);
});

/* ------------------------------------------------------------------ *
 * 8. custom approval presets (validation)
 * ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ *
 * 7. approval presets
 * ------------------------------------------------------------------ */

const GOOD_CONFIG = { defaultPolicy: 'auto-read', sandboxMode: 'workspace-write', maxSteps: 45, protectGit: true };

test('validatePresetInput: mints an id and reports danger honestly', () => {
  const ok = validatePresetInput({ label: '我的预设', summary: '  多余   空白  ', config: GOOD_CONFIG });
  assert.equal(ok.ok, true);
  assert.match(ok.preset.id, /^custom-[a-f0-9]{16}$/);
  assert.equal(ok.preset.label, '我的预设');
  assert.equal(ok.preset.summary, '多余 空白');
  assert.equal(ok.preset.dangerous, false);

  const dangerous = validatePresetInput({
    label: '全开', config: { ...GOOD_CONFIG, defaultPolicy: 'danger-full-access' }
  });
  assert.equal(dangerous.ok, true);
  assert.equal(dangerous.preset.dangerous, true);
});

test('validatePresetInput: refuses bad values instead of clamping them', () => {
  const bad = [
    { label: '', config: GOOD_CONFIG },
    { label: 'x', config: { ...GOOD_CONFIG, defaultPolicy: 'yolo' } },
    { label: 'x', config: { ...GOOD_CONFIG, sandboxMode: 'nope' } },
    { label: 'x', config: { ...GOOD_CONFIG, maxSteps: 0 } },
    { label: 'x', config: { ...GOOD_CONFIG, maxSteps: 9999 } },
    { label: 'x', config: { ...GOOD_CONFIG, maxSteps: 2.5 } },
    { label: 'x', config: { ...GOOD_CONFIG, protectGit: 'yes' } },
    { label: 'x', config: null },
    { label: 'x'.repeat(80), config: GOOD_CONFIG }
  ];
  for (const body of bad.slice(0, -1)) {
    const r = validatePresetInput(body);
    assert.equal(r.ok, false, `expected refusal for ${JSON.stringify(body)}`);
  }
  // An over-long label is truncated to the cap, not refused: the user meant it.
  const longLabel = validatePresetInput(bad[bad.length - 1]);
  assert.equal(longLabel.ok, true);
  assert.equal(longLabel.preset.label.length, 24);
});

test('validatePresetInput: a preset without the legacy knobs still saves', () => {
  // [2026-10-16] sandboxMode / maxSteps / protectGit 已从 App 侧删除（三者全链路
  // 无人消费，见 extensions.mjs 的说明）。新版客户端只发 defaultPolicy，网关必须
  // 接受并补上遗留默认值 —— 否则用户连预设都存不了。
  const r = validatePresetInput({ label: '只带策略', config: { defaultPolicy: 'auto-read' } });
  assert.equal(r.ok, true, r.error);
  assert.equal(r.preset.config.defaultPolicy, 'auto-read');
  // 补齐成与 store.mjs 一致的默认值，而不是 undefined：旧版 App 会读这些字段。
  assert.equal(r.preset.config.sandboxMode, 'workspace-write');
  assert.equal(r.preset.config.maxSteps, 30);
  assert.equal(r.preset.config.protectGit, true);
});

test('validatePresetInput: legacy knobs are still validated when present', () => {
  // 容错只针对"没带"，不包括"乱填" —— 带了就必须合法，否则等于把校验也删了。
  for (const bad of [
    { defaultPolicy: 'ask', maxSteps: 0 },
    { defaultPolicy: 'ask', maxSteps: 9999 },
    { defaultPolicy: 'ask', sandboxMode: 'nope' },
    { defaultPolicy: 'ask', protectGit: 'yes' }
  ]) {
    assert.equal(
      validatePresetInput({ label: 'x', config: bad }).ok,
      false,
      `expected refusal for ${JSON.stringify(bad)}`
    );
  }
});

test('validatePresetInput: built-in ids cannot be shadowed', () => {  for (const id of ['strict', 'balanced', 'autonomous', 'trusted']) {
    const r = validatePresetInput({ id, label: 'x', config: GOOD_CONFIG });
    assert.equal(r.ok, false);
    assert.match(r.error, /内置预设/);
  }
  const ok = validatePresetInput({ id: 'custom-abcdef12', label: 'x', config: GOOD_CONFIG });
  assert.equal(ok.ok, true);
  assert.equal(ok.preset.id, 'custom-abcdef12');
  const bad = validatePresetInput({ id: 'custom-!!', label: 'x', config: GOOD_CONFIG });
  assert.equal(bad.ok, false);
});

test('presetToWire: every field is typed, danger is never inferred by the client', () => {
  const wire = presetToWire({
    id: 'custom-1', label: 'a', summary: 'b', dangerous: true,
    config: { defaultPolicy: 'auto-read', sandboxMode: 'workspace-write', maxSteps: 30, protectGit: true }
  });
  assert.equal(wire.builtin, false);
  assert.equal(wire.dangerous, true);
  assert.deepEqual(wire.config, { defaultPolicy: 'auto-read', sandboxMode: 'workspace-write', maxSteps: 30, protectGit: true });
});

/* ------------------------------------------------------------------ *
 * 8. push topic
 * ------------------------------------------------------------------ */

test('generatePushTopic: unguessable, prefixed, hex-only', () => {
  const topic = generatePushTopic();
  assert.match(topic, /^dsh-[a-f0-9]{16}$/);
  const many = new Set(Array.from({ length: 200 }, () => generatePushTopic()));
  assert.equal(many.size, 200, 'topics must not repeat');
  // Deterministic path, used by the route with real entropy.
  const seeded = generatePushTopic(() => Buffer.from('0011223344556677', 'hex'));
  assert.equal(seeded, 'dsh-0011223344556677');
});

test('ntfyLinks: deep link and web link share the configured host', () => {
  const links = ntfyLinks('https://ntfy.example.com', 'dsh-abc');
  assert.equal(links.host, 'ntfy.example.com');
  assert.equal(links.subscribeUrl, 'ntfy://ntfy.example.com/dsh-abc');
  assert.equal(links.webUrl, 'https://ntfy.example.com/dsh-abc');
  const fallback = ntfyLinks('', 'dsh-abc');
  assert.equal(fallback.host, 'ntfy.sh');
});

/* ------------------------------------------------------------------ *
 * 9. goal board
 * ------------------------------------------------------------------ */

test('summarizeGoalBoard: progress, blocked prose, and the CAS ref', () => {
  const values = {
    goal: {
      goal: { id: 'goal-1', revision: 4, objective: 'ship it', phase: 'blocked', maxGoalRounds: 10, blockedReason: { code: 'no-progress', message: '连续两轮没有进展' } },
      roundsStarted: 3
    }
  };
  const board = summarizeGoalBoard(values, null);
  assert.equal(board.present, true);
  assert.equal(board.source, 'live');
  assert.equal(board.goalId, 'goal-1');
  assert.equal(board.revision, 4);
  assert.equal(board.phase, 'blocked');
  assert.equal(board.blockedReason, '连续两轮没有进展');
  assert.equal(board.blockedCode, 'no-progress');
  assert.equal(board.roundsRemaining, 7);
  assert.equal(board.progress, 0.3);
});

test('summarizeGoalBoard: an absent goal is reported as absent, not as zeros', () => {
  assert.deepEqual(summarizeGoalBoard(null, null), { present: false, source: 'none' });
  const cachedOnly = summarizeGoalBoard(null, {
    goal: { val: { goal: { id: 'g', revision: 1, objective: 'o', phase: 'active', maxGoalRounds: 4 }, roundsStarted: 4 } }
  });
  assert.equal(cachedOnly.present, true);
  assert.equal(cachedOnly.source, 'cache');
  assert.equal(cachedOnly.roundsRemaining, 0);
  assert.equal(cachedOnly.progress, 1);
});

/* ------------------------------------------------------------------ *
 * 10. fork checkpoints
 * ------------------------------------------------------------------ */

test('extractCheckpoints: anchors on turn/end, labelled by its user prompt', () => {
  const records = [
    rec('user/message', 5, { content: [{ type: 'text', text: '修一下登录接口' }] }),
    rec('assistant/message', 8, { message: { content: [{ type: 'text', text: 'ok' }] } }),
    rec('turn/end', 10, { turn: 1, reason: { kind: 'completed' } }),
    rec('user/message', 15, { content: [{ type: 'text', text: '再跑一下测试' }] }),
    rec('turn/end', 20, { turn: 2, reason: { kind: 'error', error: { message: 'boom' } } })
  ];
  const points = extractCheckpoints(records);
  assert.equal(points.length, 2);
  // Newest first, so the picker leads with the most recent branch point.
  assert.equal(points[0].seq, 20);
  assert.equal(points[0].label, '再跑一下测试');
  assert.equal(points[0].reason, 'error');
  assert.equal(points[0].forkable, false);
  assert.equal(points[1].seq, 10);
  assert.equal(points[1].label, '修一下登录接口');
  assert.equal(points[1].forkable, true);
  assert.equal(points[1].turn, 1);
});

test('extractCheckpoints: injected context is never used as a label', () => {
  const records = [
    rec('user/message', 5, { content: [{ type: 'text', text: 'Time sampled while preparing turn 1, step 1: 2026-10-13' }] }),
    rec('turn/end', 10, { turn: 1, reason: { kind: 'completed' } })
  ];
  const points = extractCheckpoints(records);
  assert.equal(points.length, 1);
  assert.equal(points[0].label, '');
});

test('extractCheckpoints: caps the list and tolerates an empty history', () => {
  const many = Array.from({ length: 60 }, (_, i) => rec('turn/end', i * 10 + 10, { turn: i + 1, reason: { kind: 'completed' } }));
  assert.equal(extractCheckpoints(many, { max: 5 }).length, 5);
  assert.deepEqual(extractCheckpoints([]), []);
  assert.deepEqual(extractCheckpoints(null), []);
});

/* ------------------------------------------------------------------ *
 * 11. route dispatch
 * ------------------------------------------------------------------ */

/** Collect the responses a route handler produces. */
function makeHarness(overrides = {}) {
  const calls = [];
  const deps = {
    pathname: '/api/mobile/none',
    req: { method: 'GET' },
    res: {},
    parsedUrl: { query: {} },
    jsonBody: {},
    sendJson: (status, body) => { calls.push({ status, body }); },
    audit: () => {},
    logger: { warn: () => {}, info: () => {} },
    callDshRpc: async () => { throw new Error('no engine in a unit test'); },
    readStreamOnce: async () => null,
    readProjections: async () => null,
    readProjectionRows: () => null,
    readSessionCwd: () => null,
    readSessionRecords: async () => ({ records: [], cwd: null, truncated: false }),
    readWorkspaceChanges: async () => ({ available: false, reason: 'no-workspace', files: [] }),
    resolveDeliverableFile: async () => null,
    readConfig: () => ({ ntfyEnabled: false, ntfyUrl: '', ntfyTopic: '', ntfyToken: '' }),
    writeConfig: (patch) => ({ ntfyEnabled: false, ntfyUrl: '', ntfyTopic: '', ntfyToken: '', ...patch }),
    assertSessionId: (id) => (/^[A-Za-z0-9_-]{1,64}$/.test(String(id)) ? { ok: true } : { ok: false, error: 'bad id' }),
    ...overrides
  };
  return { deps, calls, result: handleExtensionRoute(deps) };
}

test('claimsExtensionRoute: every declared route is claimed, and only those', () => {
  for (const [method, pathname] of EXTENSION_ROUTES) {
    assert.equal(claimsExtensionRoute(method, pathname), true, `${method} ${pathname}`);
  }
  assert.equal(claimsExtensionRoute('GET', '/api/mobile/nope'), false);
  assert.equal(claimsExtensionRoute('DELETE', '/api/mobile/fs/list'), false);
  assert.equal(claimsExtensionRoute('GET', ''), false);
});

test('an unclaimed path returns false so the caller can keep routing', async () => {
  const { result } = makeHarness();
  assert.equal(await result, false);
});

test('fs/list: an unknown session id is refused before any filesystem work', async () => {
  const { calls, result } = makeHarness({
    pathname: '/api/mobile/fs/list',
    parsedUrl: { query: { sessionId: '../etc' } }
  });
  assert.equal(await result, true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].status, 400);
});

test('fs/list: no workspace answers 409 rather than an empty directory', async () => {
  const { calls, result } = makeHarness({
    pathname: '/api/mobile/fs/list',
    parsedUrl: { query: { sessionId: 'abc' } }
  });
  assert.equal(await result, true);
  assert.equal(calls[0].status, 409);
});

test('fs/list and fs/read: a real workspace lists and reads', async (t) => {
  const { ws } = makeWorkspace(t);
  const base = {
    readSessionCwd: () => ws,
    assertSessionId: () => ({ ok: true })
  };

  const listed = makeHarness({ ...base, pathname: '/api/mobile/fs/list', parsedUrl: { query: { sessionId: 'abc', path: 'src' } } });
  assert.equal(await listed.result, true);
  assert.equal(listed.calls[0].status, 200);
  assert.deepEqual(listed.calls[0].body.entries.map((e) => e.name), ['deep', 'main.dart']);
  assert.equal(listed.calls[0].body.path, 'src');

  const read = makeHarness({ ...base, pathname: '/api/mobile/fs/read', parsedUrl: { query: { sessionId: 'abc', path: 'README.md' } } });
  assert.equal(await read.result, true);
  assert.equal(read.calls[0].body.content, '# hello\n');
  assert.equal(read.calls[0].body.binary, false);

  const escape = makeHarness({ ...base, pathname: '/api/mobile/fs/read', parsedUrl: { query: { sessionId: 'abc', path: '../../etc/passwd' } } });
  assert.equal(await escape.result, true);
  assert.equal(escape.calls[0].status, 403);
});

test('quick-commands/run: rejects an id that is not in the catalog', async () => {
  const { calls, result } = makeHarness({
    pathname: '/api/mobile/quick-commands/run',
    req: { method: 'POST' },
    jsonBody: { sessionId: 'abc', id: 'git status; rm -rf /' }
  });
  assert.equal(await result, true);
  assert.equal(calls[0].status, 400);
  assert.match(calls[0].body.error, /未知的命令/);
});

test('quick-commands: the catalog route ships no argv', async () => {
  const { calls, result } = makeHarness({ pathname: '/api/mobile/quick-commands' });
  assert.equal(await result, true);
  const rows = calls[0].body.commands;
  assert.ok(rows.length > 0);
  // `group` is legitimately the string "git", so the check has to look for
  // argv *artifacts* rather than the command name.
  const wire = JSON.stringify(rows);
  for (const marker of ['pwsh', '-NoProfile', '--porcelain', 'Get-Process', 'rm -rf', 'argv']) {
    assert.equal(wire.includes(marker), false, `catalog leaked ${marker}`);
  }
});

test('workspace/repos: names repositories without exposing absolute paths', async (t) => {
  const { ws } = makeWorkspace(t);
  const childRepo = path.join(ws, 'child-repo');
  fs.mkdirSync(childRepo, { recursive: true });
  markRepo(childRepo);

  const { calls, result } = makeHarness({
    pathname: '/api/mobile/workspace/repos',
    parsedUrl: { query: { sessionId: 'abc' } },
    readSessionCwd: () => ws,
    assertSessionId: () => ({ ok: true })
  });
  assert.equal(await result, true);
  const body = calls[0].body;
  assert.equal(body.available, true);
  assert.deepEqual(body.repos, [{ name: 'child-repo', path: 'child-repo' }]);
  // The absolute prefix must not be on the wire.
  assert.equal(JSON.stringify(body).includes(ws.replace(/\\/g, '\\\\')), false);
  assert.equal(JSON.stringify(body).includes(os.tmpdir().replace(/\\/g, '\\\\')), false);
});

test('goals/create: an over-long objective is refused before the RPC', async () => {
  const { calls, result } = makeHarness({
    pathname: '/api/mobile/goals/create',
    req: { method: 'POST' },
    jsonBody: { sessionId: 'abc', objective: 'x'.repeat(2001) }
  });
  assert.equal(await result, true);
  assert.equal(calls[0].status, 400);
});

test('goals/create: an engine failure is 502, never a fabricated success', async () => {
  const { calls, result } = makeHarness({
    pathname: '/api/mobile/goals/create',
    req: { method: 'POST' },
    jsonBody: { sessionId: 'abc', objective: 'do the thing' }
  });
  assert.equal(await result, true);
  assert.equal(calls[0].status, 502);
  assert.equal(calls[0].body.ok, false);
});

test('goals/edit: requires a positive revision (the CAS precondition)', async () => {
  for (const revision of [undefined, 0, -1, 1.5, 'x']) {
    const { calls, result } = makeHarness({
      pathname: '/api/mobile/goals/edit',
      req: { method: 'POST' },
      jsonBody: { sessionId: 'abc', goalId: 'g', revision, objective: 'new' }
    });
    assert.equal(await result, true);
    assert.equal(calls[0].status, 400, `revision=${revision}`);
  }
});

test('sessions/fork: forwards atSeq, and surfaces fork-unavailable as 409', async () => {
  let seen = null;
  const ok = makeHarness({
    pathname: '/api/mobile/sessions/fork',
    req: { method: 'POST' },
    jsonBody: { sessionId: 'session-abc', atSeq: 42 },
    callDshRpc: async (name, payload) => { seen = { name, payload }; return { sessionId: 'session-new' }; }
  });
  assert.equal(await ok.result, true);
  assert.equal(ok.calls[0].status, 200);
  assert.equal(ok.calls[0].body.sessionId, 'session-new');
  assert.equal(seen.name, 'session/fork');
  assert.deepEqual(seen.payload.args.request, { sessionId: 'session-abc', atSeq: 42 });

  const refused = makeHarness({
    pathname: '/api/mobile/sessions/fork',
    req: { method: 'POST' },
    jsonBody: { sessionId: 'session-abc', atSeq: 42 },
    callDshRpc: async () => { throw new Error('session/fork-unavailable: turn not complete'); }
  });
  assert.equal(await refused.result, true);
  assert.equal(refused.calls[0].status, 409);
  assert.match(refused.calls[0].body.error, /尚未结束/);
});

test('sessions/fork: omits atSeq entirely when the client does not name one', async () => {
  let seen = null;
  const { result } = makeHarness({
    pathname: '/api/mobile/sessions/fork',
    req: { method: 'POST' },
    jsonBody: { sessionId: 'session-abc' },
    callDshRpc: async (name, payload) => { seen = payload; return { sessionId: 'session-new' }; }
  });
  assert.equal(await result, true);
  assert.deepEqual(seen.args.request, { sessionId: 'session-abc' });
  assert.equal('atSeq' in seen.args.request, false);
});

test('sessions/checkpoints: answers from the session log', async () => {
  const { calls, result } = makeHarness({
    pathname: '/api/mobile/sessions/checkpoints',
    parsedUrl: { query: { sessionId: 'abc' } },
    assertSessionId: () => ({ ok: true }),
    readSessionRecords: async () => ({
      records: [rec('user/message', 1, { content: [{ type: 'text', text: 'hi' }] }), rec('turn/end', 9, { turn: 1, reason: { kind: 'completed' } })],
      cwd: null,
      truncated: false
    })
  });
  assert.equal(await result, true);
  assert.equal(calls[0].body.checkpoints.length, 1);
  assert.equal(calls[0].body.checkpoints[0].seq, 9);
});

test('push/auto-topic: mints, enables, and returns usable deep links', async () => {
  const { calls, result } = makeHarness({
    pathname: '/api/mobile/push/auto-topic',
    req: { method: 'POST' },
    jsonBody: {},
    writeConfig: (patch) => ({ ntfyEnabled: true, ntfyUrl: 'https://ntfy.sh', ntfyTopic: patch.ntfyTopic, ntfyToken: '' })
  });
  assert.equal(await result, true);
  assert.equal(calls[0].body.push.enabled, true);
  assert.match(calls[0].body.push.topic, /^dsh-[a-f0-9]{16}$/);
  assert.match(calls[0].body.links.subscribeUrl, /^ntfy:\/\/ntfy\.sh\/dsh-/);
});

test('deliverables/text: a path outside the declared set is refused', async () => {
  const { calls, result } = makeHarness({
    pathname: '/api/mobile/deliverables/text',
    parsedUrl: { query: { sessionId: 'abc', path: '../../secret.txt' } },
    assertSessionId: () => ({ ok: true }),
    resolveDeliverableFile: async () => null
  });
  assert.equal(await result, true);
  assert.equal(calls[0].status, 403);
  // The harness records no cwd, so the honest reason is "could not resolve",
  // not "not in the list" — the distinction the audit asked for.
  assert.equal(calls[0].body.reason, 'deliverable-cwd-unknown');
  assert.match(String(calls[0].body.hint), /不是权限问题/);
});

/* ---- refusal reasons (a resolution failure must not look like a permission one) ---- */

test('describeDeliverableRefusal: unknown cwd is reported as a resolution failure', () => {
  const refusal = describeDeliverableRefusal({ presented: [{ path: 'x' }], cwd: null });
  assert.equal(refusal.code, 'deliverable-cwd-unknown');
  assert.equal(refusal.status, 403);
  assert.match(refusal.hint, /不是权限问题/);
});

test('describeDeliverableRefusal: an empty listing says nothing was declared', () => {
  const refusal = describeDeliverableRefusal({ presented: [], cwd: '/ws' });
  assert.equal(refusal.code, 'deliverable-none-presented');
  assert.equal(refusal.presentedCount, 0);
});

test('describeDeliverableRefusal: a real set reports its size, never the paths', () => {
  const presented = [{ path: '/ws/a.xlsx' }, { path: '/ws/b.docx' }];
  const refusal = describeDeliverableRefusal({ presented, cwd: '/ws' });
  assert.equal(refusal.code, 'deliverable-not-in-set');
  assert.equal(refusal.presentedCount, 2);
  // A refusal must not become a file-enumeration surface.
  assert.doesNotMatch(refusal.hint, /a\.xlsx/);
  assert.doesNotMatch(refusal.error, /b\.docx/);
});

test('extractDeliverables/resolveDeliverable: exported from core and matched exactly', () => {
  const records = [
    { event: { type: 'deliverables/presented', seq: 10, data: { files: [{ path: 'out/report.xlsx' }] } } }
  ];
  const rows = extractDeliverables(records, '/ws');
  assert.equal(rows.length, 1);
  assert.equal(rows[0].path, path.resolve('/ws', 'out/report.xlsx'));
  assert.equal(resolveDeliverable(rows, path.resolve('/ws', 'out/report.xlsx'))?.display, 'out/report.xlsx');
  // Traversal never resolves to a declared row.
  assert.equal(resolveDeliverable(rows, '/ws/../../etc/passwd'), null);
});

test('deliverables/text: a binary deliverable says so instead of rendering mojibake', async (t) => {
  const { ws } = makeWorkspace(t);
  const { calls, result } = makeHarness({
    pathname: '/api/mobile/deliverables/text',
    parsedUrl: { query: { sessionId: 'abc', path: 'blob.bin' } },
    assertSessionId: () => ({ ok: true }),
    resolveDeliverableFile: async () => ({ path: path.join(ws, 'blob.bin'), display: 'blob.bin' })
  });
  assert.equal(await result, true);
  assert.equal(calls[0].body.binary, true);
  assert.equal(calls[0].body.content, undefined);
  assert.match(calls[0].body.note, /二进制/);
});

test('deliverables/text: a text deliverable comes back as content', async (t) => {
  const { ws } = makeWorkspace(t);
  const { calls, result } = makeHarness({
    pathname: '/api/mobile/deliverables/text',
    parsedUrl: { query: { sessionId: 'abc', path: 'README.md' } },
    assertSessionId: () => ({ ok: true }),
    resolveDeliverableFile: async () => ({ path: path.join(ws, 'README.md'), display: 'README.md' })
  });
  assert.equal(await result, true);
  assert.equal(calls[0].body.content, '# hello\n');
  assert.match(calls[0].body.contentType, /text\/markdown/);
});

test('approval-presets: GET lists customs, and a reserved id cannot be saved', async () => {
  const listed = makeHarness({ pathname: '/api/mobile/approval-presets' });
  assert.equal(await listed.result, true);
  assert.equal(listed.calls[0].status, 200);
  assert.deepEqual(listed.calls[0].body.reservedIds.sort(), ['autonomous', 'balanced', 'strict', 'trusted']);

  const save = makeHarness({
    pathname: '/api/mobile/approval-presets/save',
    req: { method: 'POST' },
    jsonBody: { id: 'strict', label: '假严格', config: GOOD_CONFIG }
  });
  assert.equal(await save.result, true);
  assert.equal(save.calls[0].status, 400);
});

test('goals: GET reports an absent goal honestly when the engine is cold', async () => {
  const { calls, result } = makeHarness({
    pathname: '/api/mobile/goals',
    parsedUrl: { query: { sessionId: 'abc' } },
    assertSessionId: () => ({ ok: true })
  });
  assert.equal(await result, true);
  assert.equal(calls[0].body.goal.present, false);
  assert.equal(calls[0].body.goal.source, 'none');
});
