/**
 * Bridge extensions (P0/P1, 2026-10-13): git-root-aware diff, custom approval
 * presets, one-tap push topics, deliverable text preview, a whitelisted command
 * panel, a goal board, session fork/checkpoints, and a read-only file browser.
 *
 * Structure mirrors `features.mjs` on purpose: pure functions at the top (unit
 * testable with no engine), one `handleExtensionRoute` dispatcher at the bottom
 * that receives every host dependency through `deps`. `lib/index.js` remains the
 * single owner of the HTTP surface, the engine RPC caller and the upstream MUX.
 *
 * Only two imports reach outside this module, both deliberate:
 *   - `host-ops.mjs`, for the file/exec primitives (no engine, no HTTP);
 *   - `store.mjs`, for preset persistence (no engine, no HTTP).
 * Neither can start a request, so a unit test can drive every branch here with
 * nothing but plain objects.
 */
import crypto from 'node:crypto';
import path from 'node:path';

import {
  contentTypeFor,
  discoverGitRepos,
  isInside,
  listDirectory,
  quickCommandCatalog,
  readTextFile,
  resolveConfined,
  resolveQuickCommand,
  runQuickCommand
} from './host-ops.mjs';

import {
  RESERVED_PRESET_IDS,
  loadPresets,
  maxCustomPresets,
  savePresets
} from './store.mjs';

/* ------------------------------------------------------------------ *
 * 1. Files the agent actually touched (the diff fallback)
 * ------------------------------------------------------------------ */

/**
 * Tools that CHANGE a file, with the argument that names it.
 *
 * Taken from the engine's own definition rather than invented:
 * `@deepseek-ai/dsh-agent-instructions` declares
 * `FILE_TOUCH_TOOL_NAMES = new Set(['read','write','edit'])` and reads
 * `arguments.file_path`. `read` is excluded here because a read neither creates
 * a change nor explains one; it is tracked separately by callers that want
 * "recently opened" rather than "changed".
 */
const MUTATING_TOOLS = new Set(['write', 'edit']);

/** Tools that only observe a file. */
const READING_TOOLS = new Set(['read']);

/**
 * Every file path the agent named in a `tool/call`, newest first.
 *
 * Why this exists: `workspace/changes` in the engine carries only a turn number
 * and its snapshot stays on the Host, so when a session's workspace is not a
 * repository (or the repository is an ancestor the phone cannot see), git has
 * nothing to say and the diff panel went permanently blank. The tool calls are
 * the other half of the truth — they are exactly what the agent meant to do,
 * recorded durably in the session log — so they are the honest fallback.
 *
 * @param records - `session/page` records (`{ event }` entries).
 * @param cwd - session working directory, used to resolve relative paths.
 * @returns `{ changed, read }` — arrays of `{ path, display, tool, seq, time }`,
 *   newest first. `changed` are mutating calls; `read` are observations.
 */
export function extractToolCallFiles(records, cwd) {
  const changed = new Map();
  const read = new Map();
  if (!Array.isArray(records)) return { changed: [], read: [] };
  const base = typeof cwd === 'string' && cwd ? cwd : null;

  for (const record of records) {
    const ev = record?.event;
    if (!ev || ev.type !== 'tool/call') continue;
    const name = typeof ev.data?.name === 'string' ? ev.data.name : '';
    if (!name) continue;
    const isChange = MUTATING_TOOLS.has(name);
    const isRead = READING_TOOLS.has(name);
    if (!isChange && !isRead) continue;

    let args = ev.data?.arguments;
    if (typeof args === 'string') {
      try {
        args = JSON.parse(args);
      } catch {
        args = null; // a truncated streamed argument object is not a path source
      }
    }
    const rawPath = typeof args?.file_path === 'string' ? args.file_path.trim() : '';
    if (!rawPath) continue;

    // Keep the caller inside the session workspace: a path the agent was given
    // outside it is real, but showing it would turn the diff panel into a host
    // filesystem browser.
    if (base) {
      const resolved = path.isAbsolute(rawPath) ? path.resolve(rawPath) : path.resolve(base, rawPath);
      if (!isInside(base, resolved)) continue;
    }

    const row = {
      path: rawPath,
      display: base
        ? path.relative(base, path.isAbsolute(rawPath) ? rawPath : path.resolve(base, rawPath)).split(path.sep).join('/')
        : rawPath,
      tool: name,
      seq: typeof ev.seq === 'number' ? ev.seq : null,
      time: typeof ev.time === 'number' ? ev.time : null
    };
    const bucket = isChange ? changed : read;
    // Newest call wins for one path: that is the one whose result the phone
    // user is looking at.
    const key = row.display || row.path;
    const prev = bucket.get(key);
    if (!prev || (row.seq ?? 0) >= (prev.seq ?? 0)) bucket.set(key, row);
  }

  const byNewest = (a, b) => (b.seq ?? 0) - (a.seq ?? 0);
  return {
    changed: [...changed.values()].sort(byNewest),
    read: [...read.values()].sort(byNewest)
  };
}

/* ------------------------------------------------------------------ *
 * 2. Custom approval presets
 * ------------------------------------------------------------------ */

/**
 * Translate one engine `workspaceFiles/*` refusal into a phone-facing answer.
 *
 * Returning `null` means "this was not a domain refusal" — the caller then falls
 * back to its own host-fs path. Keeping the two apart matters: a genuine
 * `outside-workspace` must never silently become a fallback read, because the
 * engine has just told us the path is not reachable in this Session.
 */
function mapWorkspaceFileError(message) {
  const text = String(message || '');
  const has = (code) => text.includes(code);
  if (has('workspace-file/outside-workspace')) {
    return { status: 403, error: '该路径在会话工作区之外' };
  }
  if (has('workspace-file/not-found')) return { status: 404, error: '文件或目录不存在' };
  if (has('workspace-file/not-directory')) return { status: 404, error: '该路径不是目录' };
  if (has('workspace-file/not-regular-file')) return { status: 404, error: '该路径不是普通文件' };
  if (has('workspace-file/not-text')) {
    // The engine refuses NUL bytes and undecodable UTF-8; the phone should offer
    // a download rather than render mojibake.
    return { status: 200, error: null, binary: true };
  }
  if (has('workspace-file/too-large')) return { status: 413, error: '文件超过可预览上限' };
  return null;
}

const POLICY_VALUES = new Set(['ask', 'auto-read', 'danger-full-access']);
const SANDBOX_VALUES = new Set(['sandboxed', 'workspace-write', 'danger-full-access']);
const MAX_STEPS_MIN = 1;
const MAX_STEPS_MAX = 200;

/** Strip control characters and collapse whitespace; never trust the wire. */
function cleanText(value, maxLength) {
  if (typeof value !== 'string') return '';
  // eslint-disable-next-line no-control-regex
  const stripped = value.replace(/[\x00-\x1f\x7f]/g, ' ');
  return stripped.replace(/\s+/g, ' ').trim().slice(0, maxLength);
}

/**
 * Validate and normalize one client-supplied preset.
 *
 * Refuses rather than clamps where a wrong value would change meaning: a
 * `maxSteps` of `0` or `9999` is a user error about a *policy*, and silently
 * rounding it would let the App display one thing while the host stores another.
 * The one deliberate exception is `danger-full-access`, which is allowed — it is
 * the whole point of a custom preset — but is always reported back with
 * `dangerous: true` so the phone cannot present it as a safe choice.
 *
 * @returns `{ ok: true, preset }` or `{ ok: false, error }`.
 */
export function validatePresetInput(body) {
  const label = cleanText(body?.label, 24);
  if (!label) return { ok: false, error: '预设名称必填（1–24 字）' };

  const summary = cleanText(body?.summary, 80);

  const cfg = body?.config;
  if (!cfg || typeof cfg !== 'object') return { ok: false, error: '缺少配置项 config' };

  const defaultPolicy = typeof cfg.defaultPolicy === 'string' ? cfg.defaultPolicy.trim() : '';
  if (!POLICY_VALUES.has(defaultPolicy)) {
    return { ok: false, error: `执行策略取值非法：${defaultPolicy || '(空)'}` };
  }
  const sandboxMode = typeof cfg.sandboxMode === 'string' ? cfg.sandboxMode.trim() : '';
  if (!SANDBOX_VALUES.has(sandboxMode)) {
    return { ok: false, error: `沙箱模式取值非法：${sandboxMode || '(空)'}` };
  }
  const maxSteps = Number(cfg.maxSteps);
  if (!Number.isInteger(maxSteps) || maxSteps < MAX_STEPS_MIN || maxSteps > MAX_STEPS_MAX) {
    return { ok: false, error: `单轮步数上限必须是 ${MAX_STEPS_MIN}–${MAX_STEPS_MAX} 的整数` };
  }
  if (typeof cfg.protectGit !== 'boolean') return { ok: false, error: 'protectGit 必须是布尔值' };

  const requestedId = cleanText(body?.id, 32);
  if (requestedId && RESERVED_PRESET_IDS.includes(requestedId)) {
    return { ok: false, error: `「${requestedId}」是内置预设，不能被覆盖` };
  }
  if (requestedId && !/^custom-[a-z0-9]{6,16}$/.test(requestedId)) {
    return { ok: false, error: '自定义预设 id 非法' };
  }

  return {
    ok: true,
    preset: {
      id: requestedId || `custom-${randomHex(8)}`,
      label,
      summary,
      config: { defaultPolicy, sandboxMode, maxSteps, protectGit: cfg.protectGit },
      dangerous: defaultPolicy === 'danger-full-access' || sandboxMode === 'danger-full-access',
      updatedAt: Date.now()
    }
  };
}

function randomHex(bytes) {
  // `crypto` is a Node core module, so this cannot fail on a supported runtime;
  // it is imported at the top rather than required lazily so the module stays a
  // plain ESM unit with no conditional loading.
  return crypto.randomBytes(bytes).toString('hex');
}

/** Wire form of a stored preset: the App merges these with its built-ins. */
export function presetToWire(preset) {
  return {
    id: String(preset?.id || ''),
    label: String(preset?.label || ''),
    summary: String(preset?.summary || ''),
    builtin: false,
    dangerous: preset?.dangerous === true,
    config: {
      defaultPolicy: String(preset?.config?.defaultPolicy || ''),
      sandboxMode: String(preset?.config?.sandboxMode || ''),
      maxSteps: Number(preset?.config?.maxSteps) || 0,
      protectGit: preset?.config?.protectGit === true
    },
    updatedAt: typeof preset?.updatedAt === 'number' ? preset.updatedAt : null
  };
}

/* ------------------------------------------------------------------ *
 * 3. One-tap push topic
 * ------------------------------------------------------------------ */

/**
 * Mint a topic that is unguessable and self-describing.
 *
 * ntfy topics are public-by-name on the public server: anyone who knows the
 * topic can read the stream. So the topic must be random — a memorable default
 * like `dsh-mobile` would publish every approval prompt to the world. 16 hex
 * characters (64 bits) is far beyond guessing, and the `dsh-` prefix keeps it
 * recognisable in the ntfy app's subscription list.
 */
export function generatePushTopic(randomBytesFn) {
  const bytes = typeof randomBytesFn === 'function' ? randomBytesFn(8) : null;
  const hex = Buffer.isBuffer(bytes) && bytes.length >= 8
    ? bytes.subarray(0, 8).toString('hex')
    : Array.from({ length: 16 }, () => Math.floor(Math.random() * 16).toString(16)).join('');
  return `dsh-${hex}`;
}

/**
 * Deep links for one topic, so the App can offer "open in ntfy" instead of
 * asking the user to retype a 20-character random string.
 */
export function ntfyLinks(baseUrl, topic) {
  const host = (() => {
    try {
      return new URL(baseUrl || 'https://ntfy.sh').host;
    } catch {
      return 'ntfy.sh';
    }
  })();
  const safeTopic = encodeURIComponent(String(topic || ''));
  return {
    host,
    subscribeUrl: `ntfy://${host}/${safeTopic}`,
    webUrl: `https://${host}/${safeTopic}`
  };
}

/* ------------------------------------------------------------------ *
 * 4. Goal board
 * ------------------------------------------------------------------ */

/** Decode a projection-cache row (`@{ver, seq, val}` marker or a bare value). */
function decodeRow(row) {
  if (!row || typeof row !== 'object') return undefined;
  if ('val' in row) return row.val;
  return row;
}

const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);

/**
 * Full goal view for the phone's goal board.
 *
 * The engine has no goal-READ remote (verified against the installed
 * `@deepseek-ai/dsh-goal` remote map, which exposes only create/edit/pause/
 * resume/complete/clear), so the `goal` projection row is the only source of
 * `{ id, revision }` — and therefore the only way the phone can drive a
 * mutation at all. Everything here comes from the row, and every field is
 * reported as null rather than guessed when the row is missing.
 *
 * `roundsStarted / maxGoalRounds` is the progress the board draws; a
 * `blockedReason` is surfaced as prose because the engine's own reason carries a
 * human-readable `message` that the round driver wrote.
 */
export function summarizeGoalBoard(values, rows) {
  const live = values?.goal;
  const cached = decodeRow(rows?.goal);
  const row = (live && typeof live === 'object') ? live : (cached && typeof cached === 'object' ? cached : null);
  const g = row?.goal ?? null;

  if (!g || typeof g !== 'object') {
    return { present: false, source: live ? 'live' : (cached ? 'cache' : 'none') };
  }

  const roundsStarted = num(row?.roundsStarted);
  const maxGoalRounds = num(g.maxGoalRounds);
  const phase = typeof g.phase === 'string' ? g.phase : 'active';

  return {
    present: true,
    source: live ? 'live' : 'cache',
    goalId: typeof g.id === 'string' ? g.id : null,
    revision: num(g.revision),
    objective: typeof g.objective === 'string' ? g.objective : '',
    phase,
    // `phase` is the durable lifecycle; `activation` is process-local and is
    // deliberately absent from the projection, so the board must not imply it.
    blockedReason: typeof g.blockedReason?.message === 'string' ? g.blockedReason.message : null,
    blockedCode: typeof g.blockedReason?.code === 'string' ? g.blockedReason.code : null,
    roundsStarted,
    maxGoalRounds,
    roundsRemaining: (roundsStarted === null || maxGoalRounds === null) ? null : Math.max(0, maxGoalRounds - roundsStarted),
    progress: (roundsStarted === null || !maxGoalRounds) ? null : Math.min(1, roundsStarted / maxGoalRounds),
    createdAt: num(row?.createdAt),
    updatedAt: num(row?.updatedAt)
  };
}

/**
 * Goal board from the engine's live `goals/get` answer (`GoalView`).
 *
 * `GoalView extends GoalSnapshot` and adds `roundsStarted`, `createdAt`,
 * `updatedAt` and `activation`. `activation` (`armed` | `disarmed`) is
 * process-local and never persisted, so it is surfaced verbatim but must not be
 * confused with `phase`: an `active` goal can be `disarmed`, meaning this process
 * will not auto-continue it, and the board has to be able to say that.
 *
 * @returns the board, or null when the engine reported no goal for the session.
 */
export function summarizeLiveGoal(view) {
  if (!view || typeof view !== 'object') return null;
  const id = typeof view.id === 'string' ? view.id : '';
  if (!id) return null;

  const roundsStarted = num(view.roundsStarted);
  const maxGoalRounds = num(view.maxGoalRounds);
  const phase = typeof view.phase === 'string' ? view.phase : 'active';

  return {
    present: true,
    source: 'live',
    goalId: id,
    revision: num(view.revision),
    objective: typeof view.objective === 'string' ? view.objective : '',
    phase,
    // Process-local continuation eligibility; mirrors the engine's own field.
    activation: view.activation === 'disarmed' ? 'disarmed' : (view.activation === 'armed' ? 'armed' : null),
    blockedReason: typeof view.blockedReason?.message === 'string' ? view.blockedReason.message : null,
    blockedCode: typeof view.blockedReason?.code === 'string' ? view.blockedReason.code : null,
    roundsStarted,
    maxGoalRounds,
    roundsRemaining: (roundsStarted === null || maxGoalRounds === null) ? null : Math.max(0, maxGoalRounds - roundsStarted),
    progress: (roundsStarted === null || !maxGoalRounds) ? null : Math.min(1, roundsStarted / maxGoalRounds),
    createdAt: num(view.createdAt),
    updatedAt: num(view.updatedAt)
  };
}

/**
 * The engine's permission-preset catalog in wire form.
 *
 * Shape is `{ options: [{ value, name }, …] }` on the installed engine. Every
 * unknown shape collapses to `null` so the caller can say "the engine did not
 * report a catalog" instead of rendering an empty picker.
 */
export function normalizePresetCatalog(catalog) {
  if (!catalog || typeof catalog !== 'object') return null;
  const raw = catalog.options;
  if (!Array.isArray(raw)) return null;
  const options = raw
    .map((opt) => {
      const value = typeof opt?.value === 'string' ? opt.value : '';
      if (!value) return null;
      return { value, name: typeof opt?.name === 'string' && opt.name ? opt.name : value };
    })
    .filter(Boolean);
  return { options };
}

/* ------------------------------------------------------------------ *
 * 5. Session fork checkpoints
 * ------------------------------------------------------------------ */

/**
 * Turn boundaries a session can be forked from.
 *
 * The engine's `session/fork` takes an optional `atSeq` and rounds it UP to the
 * next `turn/end` (see `SessionCommandController.fork`), refusing with
 * `session/fork-unavailable` when the reference turn has not completed. So the
 * only safe anchors to offer are the `turn/end` seqs themselves — offering a
 * mid-turn seq would produce a request the engine rejects.
 *
 * Each checkpoint is labelled with the user prompt that started its turn, which
 * is what makes the picker usable: "第 4 轮 · 修一下登录接口" beats "seq 812".
 *
 * @param records - `session/records` ascending.
 * @returns checkpoints, newest first, capped at `max`.
 */
export function extractCheckpoints(records, { max = 40 } = {}) {
  if (!Array.isArray(records)) return [];
  const out = [];
  let pendingPrompt = null;

  for (const record of records) {
    const ev = record?.event;
    if (!ev) continue;
    if (ev.type === 'user/message') {
      const parts = Array.isArray(ev.data?.content) ? ev.data.content : [];
      let text = '';
      for (const part of parts) {
        if (part?.type === 'text' && part.text) text += part.text;
      }
      if (!text && typeof ev.data?.content === 'string') text = ev.data.content;
      const trimmed = String(text || '').trim();
      // Skip the injected context blocks: they are not something the user typed
      // and would make every checkpoint read the same.
      if (trimmed && !trimmed.startsWith('Time sampled while preparing turn') &&
          !trimmed.startsWith('Memory recall guidance') && !trimmed.includes('<system_information>')) {
        pendingPrompt = trimmed.slice(0, 120);
      }
      continue;
    }
    if (ev.type !== 'turn/end') continue;
    const kind = typeof ev.data?.reason?.kind === 'string' ? ev.data.reason.kind : '';
    out.push({
      seq: typeof ev.seq === 'number' ? ev.seq : null,
      turn: typeof ev.data?.turn === 'number' ? ev.data.turn : null,
      time: typeof ev.time === 'number' ? ev.time : null,
      reason: kind || null,
      // `forked` / `interrupted` turns are not clean prefixes to branch from.
      forkable: kind === 'completed' || kind === '',
      label: pendingPrompt || ''
    });
    pendingPrompt = null;
  }

  out.reverse();
  return out.slice(0, max);
}

/* ------------------------------------------------------------------ *
 * 6. Background jobs (real `job` namespace)
 * ------------------------------------------------------------------ */

/**
 * One job row in the shape the phone renders, from the engine's real `JobView`
 * (`@deepseek-ai/dsh-jobs/view`).
 *
 * ⚠️ CORRECTION (2026-10-13). An earlier revision of this module derived jobs
 * from the `session/control` baseline and carried a `jobsFromControlFrame`
 * helper, on the false premise that no `job/*` Remote exists. That premise came
 * from a package scan that skipped nested `node_modules` and therefore missed
 * `@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-api-job-controller`. Verified
 * against the running engine, `job/list`, `job/follow` and `job/kill` are all
 * served; `job/list`'s `{type:'rows', jobs: JobView[]}` frame is the roster, and
 * `session/control` was never the job transport. The misleading helper has been
 * removed rather than left as a trap.
 *
 * `output.total` / `output.earliest` are the ring's absolute coordinates: the
 * phone uses them to show how much output exists and to know whether the oldest
 * bytes are still readable. `spillPaths` is deliberately NOT forwarded — those
 * are host paths, and the phone has no use for them.
 */
export function normalizeJob(job) {
  if (!job || typeof job !== 'object') return null;
  const id = String(job.id ?? '').trim();
  if (!id) return null;
  const status = JOB_STATUSES.has(job.status) ? job.status : 'running';
  const startedAt = num(job.startedAt);
  const finishedAt = num(job.finishedAt);
  const output = (job.output && typeof job.output === 'object') ? job.output : null;
  return {
    id,
    kind: String(job.kind ?? ''),
    label: String(job.label ?? ''),
    // `owner` is absent for unowned jobs, which every session may see.
    owned: typeof job.owner === 'string' && job.owner.length > 0,
    status,
    live: status === 'running' || status === 'stopping',
    progress: typeof job.progress === 'string' ? job.progress : null,
    detail: typeof job.detail === 'string' ? job.detail : null,
    startedAt,
    finishedAt,
    durationMs: startedAt === null ? null : Math.max(0, (finishedAt ?? Date.now()) - startedAt),
    outputTotal: num(output?.total),
    outputEarliest: num(output?.earliest)
  };
}

const JOB_STATUSES = new Set(['running', 'stopping', 'completed', 'killed', 'failed']);

/** Live rows first in start order, then settled rows newest-first. */
export function orderJobs(jobs) {
  const rows = (Array.isArray(jobs) ? jobs : []).map(normalizeJob).filter(Boolean);
  return rows.sort((a, b) => {
    if (a.live !== b.live) return a.live ? -1 : 1;
    if (a.live) return (a.startedAt ?? 0) - (b.startedAt ?? 0);
    const af = a.finishedAt ?? a.startedAt ?? 0;
    const bf = b.finishedAt ?? b.startedAt ?? 0;
    return bf !== af ? bf - af : (a.startedAt ?? 0) - (b.startedAt ?? 0);
  });
}

/** One job-output chunk, as `job/follow` hands it out. */
export function normalizeJobChunk(chunk) {
  if (!chunk || typeof chunk !== 'object') return null;
  const text = typeof chunk.text === 'string' ? chunk.text : '';
  // `channel` is the producer's stream label; an unrecognized one is treated
  // like an absent one, exactly as the engine's own consumers do.
  const channel = ['stdout', 'stderr', 'log'].includes(chunk.channel) ? chunk.channel : '';
  return {
    at: num(chunk.at) ?? 0,
    text,
    channel,
    // Bytes immediately before this chunk were lost at the producer or to
    // retention. Forwarded so the phone can mark the gap rather than pretend the
    // log is continuous.
    gapBefore: chunk.gapBefore === true
  };
}

/**
 * Fold a `job/follow` frame sequence into one pollable answer.
 *
 * The stream's own ordering contract is what makes this safe: `opened` carries
 * the job's projection and the offset the first `output` continues from, output
 * batches follow, and exactly one terminal `status` arrives after the ring is
 * drained — so a settled job can never race a still-open output channel. This
 * function therefore reports settlement only when it actually saw `status`, and
 * never infers it from the absence of output.
 *
 * `lossy` is sticky across the batch: if ANY frame reported a loss, the whole
 * answer is lossy, because the phone's log is then incomplete somewhere and
 * saying "complete" would be a lie.
 *
 * @param frames - frames collected from one `job/follow` generation, in order.
 * @returns `{ ok, job, lines, next, lossy, settled }`; `job` is null when the
 *   stream produced no `opened`/`status` anchor at all.
 */
export function summarizeJobFollow(frames) {
  const list = Array.isArray(frames) ? frames : [];
  let job = null;
  let next = null;
  let lossy = false;
  const lines = [];

  for (const frame of list) {
    if (!frame || typeof frame !== 'object') continue;
    if (frame.type === 'opened' || frame.type === 'status') {
      const normalized = normalizeJob(frame.job);
      if (normalized) job = normalized;
      if (frame.type === 'opened' && typeof frame.from === 'number') next = frame.from;
      continue;
    }
    if (frame.type !== 'output') continue;
    if (frame.lossy === true) lossy = true;
    if (typeof frame.next === 'number') next = frame.next;
    const chunks = Array.isArray(frame.chunks) ? frame.chunks : [];
    for (const raw of chunks) {
      const chunk = normalizeJobChunk(raw);
      if (chunk) lines.push(chunk);
    }
  }

  return {
    ok: true,
    job,
    lines,
    // The caller's resume cursor for the next poll. Null means the engine never
    // told us an offset, so the phone must restart from the beginning rather
    // than send a bogus `from`.
    next,
    lossy,
    // Only true when the terminal frame arrived. A job that is still running has
    // no `status` frame yet, and its absence must not read as "finished".
    settled: Boolean(job && job.live === false)
  };
}

/* ------------------------------------------------------------------ *
 * Route surface
 * ------------------------------------------------------------------ */

/**
 * Every method+path this module claims, as `[method, pathname]` pairs.
 *
 * ⚠️ Same trap as `FEATURE_ROUTES`: the legacy
 * `startsWith('/api/mobile/sessions/')` GET wildcard in `lib/index.js` treats the
 * rest of the path as a session id, so any GET route registered under
 * `/api/mobile/sessions/` must be claimed here or it is swallowed silently.
 * `sessions/checkpoints` is exactly that shape, which is why this list exists
 * rather than relying on the dispatch order alone.
 */
export const EXTENSION_ROUTES = [
  // P0-1 git-repo discovery for the diff panel
  ['GET', '/api/mobile/workspace/repos'],
  // P0-2 custom approval presets
  ['GET', '/api/mobile/approval-presets'],
  ['POST', '/api/mobile/approval-presets/save'],
  ['POST', '/api/mobile/approval-presets/delete'],
  // P0-3 one-tap ntfy topic
  ['POST', '/api/mobile/push/auto-topic'],
  // P0-4 deliverable text preview
  ['GET', '/api/mobile/deliverables/text'],
  // P1-5 whitelisted command panel
  ['GET', '/api/mobile/quick-commands'],
  ['POST', '/api/mobile/quick-commands/run'],
  // P1-7 goal board
  ['GET', '/api/mobile/goals'],
  ['POST', '/api/mobile/goals/create'],
  ['POST', '/api/mobile/goals/edit'],
  // [feat 2026-10-13] the engine's own permission-preset vocabulary
  ['GET', '/api/mobile/permission-presets'],
  // P1-8 fork / checkpoints
  ['GET', '/api/mobile/sessions/checkpoints'],
  ['POST', '/api/mobile/sessions/fork'],
  // P1-9 read-only workspace browser
  ['GET', '/api/mobile/fs/list'],
  ['GET', '/api/mobile/fs/read']
];

/** True when a request belongs to this module. */
export function claimsExtensionRoute(method, pathname) {
  if (typeof pathname !== 'string' || pathname.length === 0) return false;
  const m = typeof method === 'string' ? method.toUpperCase() : '';
  if (!m) return false;
  return EXTENSION_ROUTES.some(([rm, rp]) => rm === m && rp === pathname);
}

/**
 * Handle one extension route.
 *
 * @param deps - `{ pathname, req, res, parsedUrl, jsonBody, sendJson, audit,
 *   logger, callDshRpc, readStreamOnce, readProjections, readProjectionRows,
 *   readSessionRecords, readSessionCwd, readWorkspaceChanges, readConfig,
 *   writeConfig, assertSessionId }`.
 * @returns true when the route was handled.
 */
export async function handleExtensionRoute(deps) {
  const {
    pathname, jsonBody, sendJson, audit, logger, callDshRpc, readStreamOnce,
    readProjections, readProjectionRows, readSessionRecords, readSessionCwd,
    readWorkspaceChanges, readConfig, writeConfig
  } = deps;

  const q = deps.parsedUrl?.query || {};
  const method = deps.req?.method;

  /** Read one query session id and gate its charset. */
  const querySession = () => {
    const raw = String(q.sessionId || '').trim();
    if (!raw) return { ok: false, status: 400, error: 'sessionId is required' };
    if (typeof deps.assertSessionId === 'function') {
      const check = deps.assertSessionId(raw);
      if (!check?.ok) return { ok: false, status: 400, error: check?.error || 'invalid sessionId' };
    }
    return { ok: true, id: raw };
  };

  /* ---- P0-1: git repositories a workspace maps to ---- */
  if (pathname === '/api/mobile/workspace/repos' && method === 'GET') {
    const s = querySession();
    if (!s.ok) { sendJson(s.status, { ok: false, error: s.error }); return true; }
    const cwd = readSessionCwd(s.id);
    if (!cwd) { sendJson(200, { ok: true, code: 0, available: false, reason: 'no-workspace', repos: [] }); return true; }
    const found = discoverGitRepos(cwd);
    // Only names and the *relative* path of each candidate leave the host: the
    // phone never needs the absolute prefix, and not sending it means a stolen
    // token cannot enumerate the disk through this route.
    sendJson(200, {
      ok: true,
      code: 0,
      available: Boolean(found.primaryRoot),
      cwdIsRepo: found.self,
      reason: found.primaryRoot ? null : 'not-a-git-repository',
      repos: found.children.map((c) => ({ name: c.name, path: c.name })),
      ancestorCount: found.ancestors.length,
      primary: found.primaryRoot ? (found.self ? '.' : (found.children.find((c) => c.path === found.primaryRoot)?.name || '..')) : null
    });
    return true;
  }

  /* ---- P0-2: custom approval presets ---- */
  if (pathname === '/api/mobile/approval-presets' && method === 'GET') {
    const state = loadPresets();
    sendJson(200, {
      ok: true,
      code: 0,
      presets: state.presets.map(presetToWire),
      max: maxCustomPresets(),
      reservedIds: RESERVED_PRESET_IDS
    });
    return true;
  }

  if (pathname === '/api/mobile/approval-presets/save' && method === 'POST') {
    const checked = validatePresetInput(jsonBody);
    if (!checked.ok) { sendJson(400, { ok: false, error: checked.error }); return true; }
    const state = loadPresets();
    const idx = state.presets.findIndex((p) => p.id === checked.preset.id);
    if (idx >= 0) {
      state.presets[idx] = { ...state.presets[idx], ...checked.preset };
    } else {
      if (state.presets.length >= maxCustomPresets()) {
        sendJson(409, { ok: false, error: `自定义预设最多 ${maxCustomPresets()} 个，请先删除一个` });
        return true;
      }
      state.presets.push(checked.preset);
    }
    if (savePresets(state) === false) {
      sendJson(500, { ok: false, error: '预设保存失败' });
      return true;
    }
    audit('preset/save', { id: checked.preset.id, updated: idx >= 0, dangerous: checked.preset.dangerous });
    sendJson(200, { ok: true, code: 0, preset: presetToWire(checked.preset) });
    return true;
  }

  if (pathname === '/api/mobile/approval-presets/delete' && method === 'POST') {
    const id = String(jsonBody.id || '').trim();
    if (!id) { sendJson(400, { ok: false, error: 'id is required' }); return true; }
    if (RESERVED_PRESET_IDS.includes(id)) {
      sendJson(403, { ok: false, error: '内置预设不可删除' });
      return true;
    }
    const state = loadPresets();
    const next = state.presets.filter((p) => p.id !== id);
    if (next.length === state.presets.length) {
      sendJson(404, { ok: false, error: '预设不存在' });
      return true;
    }
    if (savePresets({ ...state, presets: next }) === false) {
      sendJson(500, { ok: false, error: '预设删除失败' });
      return true;
    }
    audit('preset/delete', { id, remaining: next.length });
    sendJson(200, { ok: true, code: 0, deleted: id, remaining: next.length });
    return true;
  }

  /* ---- P0-3: one-tap ntfy topic ---- */
  if (pathname === '/api/mobile/push/auto-topic' && method === 'POST') {
    const cfg = readConfig();
    const baseUrl = String(jsonBody.url || cfg.ntfyUrl || 'https://ntfy.sh').trim() || 'https://ntfy.sh';
    const topic = generatePushTopic((n) => crypto.randomBytes(n));
    const updated = writeConfig({ ntfyUrl: baseUrl, ntfyTopic: topic, ntfyEnabled: true });
    audit('push/auto-topic', { url: updated.ntfyUrl || '', enabled: true });
    sendJson(200, {
      ok: true,
      code: 0,
      push: {
        enabled: updated.ntfyEnabled === true,
        url: updated.ntfyUrl || '',
        topic: updated.ntfyTopic || '',
        hasToken: Boolean(updated.ntfyToken)
      },
      links: ntfyLinks(updated.ntfyUrl, updated.ntfyTopic)
    });
    return true;
  }

  /* ---- P0-4: deliverable text preview ---- */
  if (pathname === '/api/mobile/deliverables/text' && method === 'GET') {
    const s = querySession();
    if (!s.ok) { sendJson(s.status, { ok: false, error: s.error }); return true; }
    const wanted = String(q.path || '').trim();
    if (!wanted) { sendJson(400, { ok: false, error: 'path is required' }); return true; }
    const { records, cwd } = await readSessionRecords(s.id);

    // Membership is checked against the same listing the download route uses, so
    // this cannot become an arbitrary-file-read oracle. The resolver lives in
    // index.js because it also owns deliverable extraction.
    const resolved = await deps.resolveDeliverableFile(s.id, wanted);
    if (!resolved) {
      sendJson(403, { ok: false, code: 403, error: '该文件不在本会话的交付物清单中' });
      return true;
    }
    const maxBytes = Number(q.max) || undefined;
    const read = readTextFile(resolved.path, { maxBytes });
    if (!read.ok) { sendJson(404, { ok: false, code: 404, error: read.reason || 'unreadable' }); return true; }
    if (read.binary) {
      sendJson(200, {
        ok: true,
        code: 0,
        path: resolved.display,
        binary: true,
        size: read.size,
        contentType: contentTypeFor(resolved.display),
        note: '二进制文件不支持文本预览，请下载后用本机应用打开'
      });
      return true;
    }
    sendJson(200, {
      ok: true,
      code: 0,
      path: resolved.display,
      binary: false,
      content: read.content,
      size: read.size,
      truncated: read.truncated,
      contentType: contentTypeFor(resolved.display) || 'text/plain; charset=utf-8',
      cwdKnown: Boolean(cwd)
    });
    return true;
  }

  /* ---- P1-5: whitelisted command panel ---- */
  if (pathname === '/api/mobile/quick-commands' && method === 'GET') {
    sendJson(200, { ok: true, code: 0, commands: quickCommandCatalog() });
    return true;
  }

  if (pathname === '/api/mobile/quick-commands/run' && method === 'POST') {
    const s = querySession();
    const sessionId = s.ok ? s.id : String(jsonBody.sessionId || '').trim();
    if (!sessionId) { sendJson(400, { ok: false, error: 'sessionId is required' }); return true; }
    const spec = resolveQuickCommand(jsonBody.id);
    if (!spec) { sendJson(400, { ok: false, error: '未知的命令 id' }); return true; }

    const cwd = readSessionCwd(sessionId);
    if (!cwd) { sendJson(409, { ok: false, error: '该会话没有可用的工作目录' }); return true; }

    const result = await runQuickCommand(cwd, spec);
    audit('quick-command/run', { id: spec.id, ok: result.ok, exitCode: result.exitCode ?? null });
    if (!result.ok) {
      sendJson(502, { ok: false, code: 502, error: result.error, command: result.command });
      return true;
    }
    sendJson(200, {
      ok: true,
      code: 0,
      id: spec.id,
      label: spec.label,
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
      truncated: result.truncated === true,
      timedOut: result.timedOut === true,
      durationMs: result.durationMs
    });
    return true;
  }

  /* ---- P1-7: goal board ----
   *
   * ⚠️ CORRECTION (2026-10-13). This route originally read the goal solely from
   * the `session/projections` row, on the (then-believed) grounds that the engine
   * has no goal-read Remote. It does: `goals/get(agentId)` is served — confirmed
   * against the running engine. That matters because the projection row is a
   * *cache* for a cold session, whereas `goals/get` is the live answer and also
   * carries `activation`, which the projection deliberately omits.
   *
   * `goals/get` is tried first; the projection path stays as the fallback for a
   * cold session, and the board reports which source it used so the UI can label
   * a cached snapshot as cached.
   */
  if (pathname === '/api/mobile/goals' && method === 'GET') {
    const s = querySession();
    if (!s.ok) { sendJson(s.status, { ok: false, error: s.error }); return true; }
    try {
      const live = await callDshRpc('goals/get', { args: { agentId: s.id } });
      const board = summarizeLiveGoal(live);
      // A `null` value is the engine's way of saying "this session has no goal",
      // which is different from the call failing.
      if (board) { sendJson(200, { ok: true, code: 0, goal: board }); return true; }
      sendJson(200, { ok: true, code: 0, goal: { present: false, source: 'live' } });
      return true;
    } catch (err) {
      logger?.warn?.('[goals/get] unavailable, using the projection row:', err?.message || err);
    }
    const values = await readProjections(s.id);
    const rows = readProjectionRows(s.id);
    sendJson(200, { ok: true, code: 0, goal: summarizeGoalBoard(values, rows) });
    return true;
  }

  /* ---- permission preset catalog (the engine's own vocabulary) [feat 2026-10-13] ----
   *
   * `permissionPresets/catalog` is served and returns the engine's real option
   * list. The App's four built-in presets are its own reviewed bundles, but a
   * custom preset must use values the engine will actually accept, so the
   * catalog is what the editor offers as choices rather than a hardcoded list
   * that could drift from the installed engine.
   */
  if (pathname === '/api/mobile/permission-presets' && method === 'GET') {
    try {
      const catalog = await callDshRpc('permissionPresets/catalog', { args: {} });
      sendJson(200, { ok: true, code: 0, catalog: normalizePresetCatalog(catalog) });
    } catch (err) {
      logger?.warn?.('[permissionPresets/catalog] failed:', err?.message || err);
      sendJson(200, { ok: true, code: 0, catalog: null, degraded: 'engine rpc not available' });
    }
    return true;
  }

  if (pathname === '/api/mobile/goals/create' && method === 'POST') {
    const sessionId = String(jsonBody.sessionId || '').trim();
    const objective = String(jsonBody.objective || '').trim();
    if (!sessionId || !objective) { sendJson(400, { ok: false, error: 'sessionId and objective are required' }); return true; }
    if (objective.length > 2000) { sendJson(400, { ok: false, error: 'objective 过长（上限 2000 字）' }); return true; }
    const request = { objective };
    const rounds = Number(jsonBody.maxGoalRounds);
    if (Number.isInteger(rounds) && rounds > 0) request.maxGoalRounds = rounds;
    try {
      const result = await callDshRpc('goals/create', { args: { agentId: sessionId, request } });
      audit('goal/create', { sessionId, hasRounds: request.maxGoalRounds !== undefined });
      sendJson(200, { ok: true, code: 0, ref: result?.ref ?? null });
    } catch (err) {
      logger?.warn?.('[goal/create] failed:', err?.message || err);
      sendJson(502, { ok: false, code: 502, error: 'engine rpc not available' });
    }
    return true;
  }

  if (pathname === '/api/mobile/goals/edit' && method === 'POST') {
    const sessionId = String(jsonBody.sessionId || '').trim();
    const goalId = String(jsonBody.goalId || '').trim();
    const revision = Number(jsonBody.revision);
    if (!sessionId || !goalId || !Number.isSafeInteger(revision) || revision <= 0) {
      sendJson(400, { ok: false, error: 'sessionId, goalId and a positive revision are required' });
      return true;
    }
    const request = {};
    if (jsonBody.objective !== undefined) request.objective = String(jsonBody.objective || '').trim();
    const rounds = Number(jsonBody.maxGoalRounds);
    if (Number.isInteger(rounds) && rounds > 0) request.maxGoalRounds = rounds;
    if (Object.keys(request).length === 0) { sendJson(400, { ok: false, error: '至少要改一项（objective 或 maxGoalRounds）' }); return true; }
    try {
      const view = await callDshRpc('goals/edit', { args: { agentId: sessionId, ref: { id: goalId, revision }, request } });
      audit('goal/edit', { sessionId, goalId, revision });
      sendJson(200, { ok: true, code: 0, view: view ?? null });
    } catch (err) {
      logger?.warn?.('[goal/edit] failed:', err?.message || err);
      sendJson(502, { ok: false, code: 502, error: 'engine rpc not available' });
    }
    return true;
  }

  /* ---- P1-8: checkpoints + fork ---- */
  if (pathname === '/api/mobile/sessions/checkpoints' && method === 'GET') {
    const s = querySession();
    if (!s.ok) { sendJson(s.status, { ok: false, error: s.error }); return true; }
    const { records } = await readSessionRecords(s.id);
    const checkpoints = extractCheckpoints(records);
    sendJson(200, { ok: true, code: 0, checkpoints });
    return true;
  }

  if (pathname === '/api/mobile/sessions/fork' && method === 'POST') {
    const sessionId = String(jsonBody.sessionId || '').trim();
    if (!sessionId) { sendJson(400, { ok: false, error: 'sessionId is required' }); return true; }
    const atSeqRaw = jsonBody.atSeq;
    let atSeq;
    if (atSeqRaw !== undefined && atSeqRaw !== null && atSeqRaw !== '') {
      const n = Number(atSeqRaw);
      if (!Number.isInteger(n) || n < 0) { sendJson(400, { ok: false, error: 'atSeq 必须是非负整数' }); return true; }
      atSeq = n;
    }
    const request = atSeq === undefined ? { sessionId } : { sessionId, atSeq };
    try {
      const result = await callDshRpc('session/fork', { args: { request } });
      const forked = String(result?.sessionId || '').trim();
      audit('session/fork', { sessionId, atSeq: atSeq ?? null, forked: Boolean(forked) });
      if (!forked) { sendJson(502, { ok: false, code: 502, error: '引擎未返回新会话 id' }); return true; }
      sendJson(200, { ok: true, code: 0, sessionId: forked, atSeq: atSeq ?? null });
    } catch (err) {
      // `session/fork-unavailable` is the engine's own refusal for an anchor
      // whose turn never completed; surfacing the code lets the App say which
      // checkpoint is unusable instead of a generic failure.
      const code = err?.message || '';
      const unavailable = /fork-unavailable/.test(code);
      audit('session/fork-failed', { sessionId, atSeq: atSeq ?? null, unavailable });
      sendJson(unavailable ? 409 : 502, {
        ok: false,
        code: unavailable ? 409 : 502,
        error: unavailable ? '该检查点所在的轮次尚未结束，无法从此处分支' : 'engine rpc not available'
      });
    }
    return true;
  }

  /* ---- P1-9: read-only workspace browser ----
   *
   * ⚠️ CORRECTION (2026-10-13). This route was first written to read the host
   * disk with Node's `fs` behind a hand-rolled confinement check. That was
   * reinventing something the engine already owns: `workspaceFiles/list` and
   * `workspaceFiles/read` are real, served Remotes (confirmed against the
   * running engine) and they are scoped to the Session's workspace root **by the
   * engine itself**, with its own error vocabulary
   * (`workspace-file/outside-workspace`, `/not-found`, `/not-text`,
   * `/too-large`, `/not-regular-file`, `/not-directory`).
   *
   * Preferring the engine removes a whole invented attack surface: no path
   * resolution of ours decides what is reachable, the Session's own workspace
   * root does. The host-fs implementation is kept ONLY as a fallback for an
   * engine that does not expose these methods, and the response shape is
   * identical either way so the phone cannot tell (and does not need to).
   *
   * `read` speaks absolute paths in the engine's execution world for
   * `readBytes`/`stat`, but `read` accepts the same workspace-relative form its
   * sibling `list` does — which is what the browser has.
   */
  if ((pathname === '/api/mobile/fs/list' || pathname === '/api/mobile/fs/read') && method === 'GET') {
    const s = querySession();
    if (!s.ok) { sendJson(s.status, { ok: false, error: s.error }); return true; }
    const cwd = readSessionCwd(s.id);
    if (!cwd) { sendJson(409, { ok: false, error: '该会话没有可用的工作目录' }); return true; }

    const requested = String(q.path || '').trim();
    const scopeId = s.id.startsWith('session-') ? s.id : `session-${s.id}`;

    // Layer 1 (preferred): the engine's own workspace-scoped file API.
    try {
      if (pathname === '/api/mobile/fs/list') {
        const listing = await callDshRpc('workspaceFiles/list', {
          args: { workspaceFileScopeId: scopeId, path: requested }
        });
        const entries = (Array.isArray(listing?.entries) ? listing.entries : [])
          .map((entry) => ({
            name: String(entry?.name ?? ''),
            // The engine's vocabulary is file/directory/other; the phone's model
            // uses dir/file/other, so `directory` is translated here rather than
            // making the client know two spellings.
            kind: entry?.type === 'directory' ? 'dir' : (entry?.type === 'file' ? 'file' : 'other'),
            size: typeof entry?.size === 'number' ? entry.size : null,
            mtime: null
          }))
          .filter((e) => e.name.length > 0)
          .sort((a, b) => {
            if ((a.kind === 'dir') !== (b.kind === 'dir')) return a.kind === 'dir' ? -1 : 1;
            return a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
          });
        const rel = String(listing?.path ?? requested ?? '');
        sendJson(200, {
          ok: true,
          code: 0,
          path: rel,
          parent: rel ? path.posix.dirname(rel) : null,
          entries,
          truncated: listing?.truncated === true,
          total: entries.length,
          source: 'engine'
        });
        return true;
      }

      const limit = Math.max(1, Math.min(Number(q.max) || 2000, 5000));
      const file = await callDshRpc('workspaceFiles/read', {
        args: {
          workspaceFileScopeId: scopeId,
          path: requested,
          range: { offset: 1, limit }
        }
      });
      const text = typeof file?.text === 'string' ? file.text : '';
      sendJson(200, {
        ok: true,
        code: 0,
        path: requested,
        name: path.basename(requested || ''),
        binary: false,
        content: text,
        size: num(file?.bytes),
        // `eof:false` means the engine's line window stopped short, i.e. the
        // file is longer than the page. Reported as truncation so the phone can
        // say so instead of implying it holds the whole file.
        truncated: file?.eof === false,
        mtime: null,
        lines: num(file?.lines),
        contentType: contentTypeFor(requested) || 'text/plain; charset=utf-8',
        source: 'engine'
      });
      return true;
    } catch (err) {
      const message = String(err?.message || '');
      // A real domain refusal is the engine's answer, not a reason to fall back:
      // translating it keeps the phone's error text truthful.
      const domain = mapWorkspaceFileError(message);
      if (domain?.binary === true) {
        // The engine said "not text" (NUL bytes or undecodable UTF-8). That is a
        // successful answer about the file, not a failure: the phone shows the
        // download affordance instead of mojibake.
        sendJson(200, {
          ok: true,
          code: 0,
          path: requested,
          name: path.basename(requested || ''),
          binary: true,
          content: null,
          size: null,
          truncated: false,
          mtime: null,
          contentType: contentTypeFor(requested) || 'application/octet-stream',
          note: '该文件不是可解码的 UTF-8 文本，请下载后用本机应用打开',
          source: 'engine'
        });
        return true;
      }
      if (domain) {
        sendJson(domain.status, { ok: false, code: domain.status, error: domain.error, source: 'engine' });
        return true;
      }
      // Otherwise the method itself is unavailable on this engine (or the MUX is
      // down), and the host-fs fallback below answers instead.
      logger?.warn?.('[fs] engine workspaceFiles unavailable, falling back to host fs:', message);
    }

    const confined = resolveConfined(cwd, requested);
    if (!confined.ok) { sendJson(confined.status, { ok: false, error: confined.error, source: 'host' }); return true; }

    if (pathname === '/api/mobile/fs/list') {
      const listed = listDirectory(confined.abs, { maxEntries: Number(q.max) || undefined });
      if (!listed.ok) { sendJson(404, { ok: false, error: listed.reason, source: 'host' }); return true; }
      sendJson(200, {
        ok: true,
        code: 0,
        path: confined.rel,
        parent: confined.rel ? path.posix.dirname(confined.rel) : null,
        entries: listed.entries,
        truncated: listed.truncated,
        total: listed.total,
        source: 'host'
      });
      return true;
    }

    const read = readTextFile(confined.abs, { maxBytes: Number(q.max) || undefined });
    if (!read.ok) { sendJson(404, { ok: false, error: read.reason, source: 'host' }); return true; }
    sendJson(200, {
      ok: true,
      code: 0,
      path: confined.rel,
      name: path.basename(confined.abs),
      binary: read.binary === true,
      content: read.binary ? null : read.content,
      size: read.size,
      truncated: read.truncated === true,
      mtime: read.mtime ?? null,
      contentType: contentTypeFor(confined.abs) || (read.binary ? 'application/octet-stream' : 'text/plain; charset=utf-8'),
      source: 'host'
    });
    return true;
  }

  return false;
}
