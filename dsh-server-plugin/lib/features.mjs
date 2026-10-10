/**
 * Gateway capabilities added in bridge 1.14 for heavy remote operation:
 * queue/steer, schedules, background jobs, deliverables, workspace diff,
 * token usage and ntfy push.
 *
 * Everything in this module is either a pure function (unit-testable without
 * an engine) or a route handler that receives its dependencies explicitly.
 * `lib/index.js` stays the single owner of the HTTP surface, the engine RPC
 * caller and the upstream MUX; this file must not import either of them, so a
 * unit test can exercise every decision here without a live DSH.
 *
 * The one exception is `sendFile`: it imports it directly (rather than taking it
 * from `deps`) because a route test must exercise the *real* byte writer. When
 * it was injectable, the test harness supplied a two-argument stub that needed
 * no response object, so it happily passed while the real function threw
 * `ReferenceError: res is not defined` on every download.
 */
import { sendFile } from './send-file.mjs';

import path from 'node:path';

/* ------------------------------------------------------------------ *
 * 1. Queue / steer (running-session input)
 * ------------------------------------------------------------------ */

/**
 * Normalize the `inbox` projection into queue rows the phone can render.
 *
 * The projection carries durable `UserMessage` values under `next-turn`
 * (queued turns) and `next-step` (input staged for the next step). We only
 * expose `next-turn`: those are the rows the queue dock offers to edit,
 * remove or steer. A row's text is the concatenation of its text parts, and
 * attachments are reduced to a count so the phone never receives image bytes.
 *
 * @param values - the `values` object of a `session/projections` answer.
 * @returns queue rows, oldest first.
 */
export function selectQueueRows(values) {
  const inbox = values?.inbox;
  if (!inbox || typeof inbox !== 'object') return [];
  const rows = Array.isArray(inbox['next-turn']) ? inbox['next-turn'] : [];
  const out = [];
  for (const row of rows) {
    if (!row || typeof row !== 'object') continue;
    const id = typeof row.id === 'string' ? row.id : '';
    if (!id) continue;
    const rawContent = row.content;
    // A queued row always carries parts. A row with nothing renderable (missing
    // content, or an empty part list) is malformed — dropping it beats showing
    // an empty row the user cannot identify or safely steer.
    if (!Array.isArray(rawContent) && typeof rawContent !== 'string') continue;
    const content = Array.isArray(rawContent) ? rawContent : [{ type: 'text', text: rawContent }];
    if (content.length === 0) continue;
    let text = '';
    let attachments = 0;
    for (const part of content) {
      if (!part || typeof part !== 'object') continue;
      if (part.type === 'text' && typeof part.text === 'string') text += part.text;
      else if (part.type === 'image' || part.type === 'file') attachments += 1;
    }
    if (!text.trim() && attachments === 0) continue;
    out.push({
      id,
      text: text.trim(),
      attachments,
      createdAt: typeof row.createdAt === 'number' ? row.createdAt : null
    });
  }
  return out;
}

/**
 * Validate one queue mutation coming from the phone.
 *
 * Mirrors the engine's own admission rules (queue edits accept non-empty text
 * only) so an invalid edit is rejected with a usable message here instead of
 * surfacing as an opaque `session/attachment-invalid` after a round trip.
 *
 * @param raw - untrusted request body fragment.
 * @returns `{ ok: true, action }` or `{ ok: false, error }`.
 */
export function normalizeQueueAction(raw) {
  if (!raw || typeof raw !== 'object') return { ok: false, error: 'action is required' };
  const kind = String(raw.kind || raw.type || '').trim();
  if (kind === 'remove') return { ok: true, action: { kind: 'remove' } };
  if (kind === 'steer') return { ok: true, action: { kind: 'steer' } };
  if (kind === 'edit') {
    const text = typeof raw.text === 'string' ? raw.text : '';
    if (!text.trim()) return { ok: false, error: 'queue edits require non-empty text' };
    return { ok: true, action: { kind: 'edit', content: [{ type: 'text', text }] } };
  }
  return { ok: false, error: `unknown queue action: ${kind || '(empty)'}` };
}

/* ------------------------------------------------------------------ *
 * 2. Deliverables (present tool)
 * ------------------------------------------------------------------ */

/**
 * Collect every `deliverables/presented` declaration from session records.
 *
 * Newest declaration wins per path: a file presented in two turns is one row,
 * attributed to the later turn. Paths are resolved to absolute form for the
 * download route, while `display` keeps the relative label the phone shows.
 *
 * @param records - `session/page` records (`{ event }` entries).
 * @param cwd - the session's working directory, used to resolve relatives.
 * @returns deliverable rows, newest first.
 */
export function extractDeliverables(records, cwd) {
  if (!Array.isArray(records)) return [];
  const byPath = new Map();
  for (const record of records) {
    const ev = record?.event;
    if (!ev || ev.type !== 'deliverables/presented') continue;
    const files = Array.isArray(ev.data?.files) ? ev.data.files : [];
    for (const file of files) {
      const raw = typeof file?.path === 'string' ? file.path.trim() : '';
      if (!raw) continue;
      const absolute = path.isAbsolute(raw) ? raw : path.resolve(cwd || '.', raw);
      byPath.set(absolute, {
        path: absolute,
        display: raw,
        description: typeof file.description === 'string' ? file.description : '',
        turn: ev.data?.turn ?? null,
        seq: typeof ev.seq === 'number' ? ev.seq : null,
        time: typeof ev.time === 'number' ? ev.time : null
      });
    }
  }
  return [...byPath.values()].sort((a, b) => (b.seq ?? 0) - (a.seq ?? 0));
}

/**
 * Resolve a download request against the declared deliverables.
 *
 * Only paths the session actually presented may be downloaded — the phone
 * cannot turn this route into an arbitrary file read, and a path traversal in
 * the query is rejected by exact membership rather than by string filtering.
 *
 * @param deliverables - rows from {@link extractDeliverables}.
 * @param requested - the path the client asked for.
 * @returns the matching row, or null.
 */
export function resolveDeliverable(deliverables, requested) {
  if (!requested || typeof requested !== 'string') return null;
  const wanted = path.resolve(requested);
  for (const row of deliverables) {
    if (path.resolve(row.path) === wanted) return row;
  }
  return null;
}

/* ------------------------------------------------------------------ *
 * 2b. Session event-log paging (the deliverable scan's data source)
 * ------------------------------------------------------------------ */

/**
 * Candidate projection-cache filenames for one session id, in lookup order.
 *
 * ⚠️ The cache filename is NOT always the bare session id. Measured on this
 * install (2026-10-10): 2133 of 2468 files are named `session-<uuid>.json` and
 * only 335 are named `<uuid>.json`. The previous lookup stripped the `session-`
 * prefix and read `${clean}.json` unconditionally, so it reached only 13.6% of
 * sessions — `readSessionCwd()` returned null for the other 86.4%, which made
 * relative deliverable paths resolve against the dsh web process's own working
 * directory and made `/api/mobile/workspace/changes` answer `no-workspace` for
 * sessions that do have a workspace.
 *
 * @param sessionId - session id with or without the `session-` prefix.
 * @returns the filenames to try, or an empty list for a blank id.
 */
export function projectionCacheFileNames(sessionId) {
  const raw = typeof sessionId === 'string' ? sessionId.trim() : '';
  if (!raw) return [];
  const clean = raw.replace(/^session-/, '');
  if (!clean) return [];
  return [`${clean}.json`, `session-${clean}.json`];
}

/**
 * Parse the cursor out of the engine's "past cursor" rejection.
 *
 * ⚠️ This exists because `session/page` has NO other way to learn a session's
 * current cursor. Verified against the live engine (2026-10-10, dsh web
 * 16:03:54 / bridge 1.14.0):
 *
 *   - `SessionPageRequest.throughSeq` is a REQUIRED wire field
 *     (`typert.host.js`: `'throughSeq': z.number().readonly()`, where
 *     `maxMessages` is the `...optional()` one). Omitting it is rejected by
 *     boundary validation with `gateway/input-invalid`, before the engine ever
 *     looks at the session.
 *   - `session/projections` does not expose a cursor (22 projection rows, none
 *     of them `turnBoundary`), and `SessionSummary` from `session/list` has no
 *     sequence field either.
 *   - `throughSeq: -1` is accepted but answers an EMPTY page: the engine maps it
 *     to `end = min(throughSeq + 1, …) = 0`, so nothing is sliced.
 *   - Asking for a page past the end answers, in 221 bytes,
 *     `gateway/bad-request: session page through seq N is past cursor C`,
 *     where C is exactly the cursor a correct request needs (verified equal to
 *     the projection cache's `rows.turnBoundary.seq` on every session tried).
 *
 * So the probe is the authoritative cursor source; a changed message shape
 * degrades to "no cursor", which yields no records rather than a wrong page.
 *
 * @param message - an engine error message.
 * @returns the cursor, or null when the message is not a past-cursor rejection.
 */
export function parseCursorFromPastSeqError(message) {
  if (typeof message !== 'string') return null;
  const m = /past cursor (\d+)/.exec(message);
  if (!m) return null;
  const n = Number(m[1]);
  return Number.isSafeInteger(n) && n >= 0 ? n : null;
}

/** Messages per page. Only `user/message`/`assistant/message` count toward it. */
export const SESSION_PAGE_MESSAGES = 500;

/**
 * How many pages the deliverable scan will walk back through.
 *
 * `maxMessages` is a MESSAGE budget, not an event budget: measured on a real
 * 4378-event session, `maxMessages: 200` returned 1418 records but covered only
 * seq [2961..4378], and it silently dropped 2 of that session's 8
 * `deliverables/presented` events. Raising `maxMessages` is the wrong axis —
 * the same session cost 3.9 MB at 200 and 11.2 MB at full depth. Walking
 * backwards in bounded pages keeps the common case tiny (86% of real sessions
 * have cursor <= 500, i.e. one small page) while still reaching old
 * declarations in long ones.
 */
export const SESSION_MAX_PAGES = 8;

/**
 * Read a session's event log, newest page first, walking backwards.
 *
 * Returns records in ascending sequence order (what `extractDeliverables`
 * expects) plus an honest `truncated` flag when the page budget ran out before
 * history was exhausted — never a silent partial answer.
 *
 * @param deps - `{ callDshRpc, sessionId, maxPages?, messagesPerPage? }`.
 * @returns `{ records, cursor, pages, truncated }`; `records` is empty when the
 *   session has no readable cursor (unknown/not-found session).
 */
export async function collectSessionRecords({ callDshRpc, sessionId, maxPages = SESSION_MAX_PAGES, messagesPerPage = SESSION_PAGE_MESSAGES }) {
  if (typeof callDshRpc !== 'function' || !sessionId) return { records: [], cursor: null, pages: 0, truncated: false };
  const address = { kind: 'session', sessionId };

  // 1. Authoritative cursor. A past-cursor rejection IS the answer.
  let cursor = null;
  try {
    await callDshRpc('session/page', { args: { request: { address, throughSeq: Number.MAX_SAFE_INTEGER, maxMessages: 1 } } });
  } catch (err) {
    cursor = parseCursorFromPastSeqError(err?.message);
  }
  if (cursor === null) return { records: [], cursor: null, pages: 0, truncated: false };

  // 2. Walk backwards. `beforeSeq` moves the window's old end; `throughSeq`
  //    stays pinned at the cursor so the schema stays satisfied.
  const bySeq = new Map();
  let before;
  let pages = 0;
  let truncated = false;
  while (pages < maxPages) {
    const request = { address, throughSeq: cursor, maxMessages: messagesPerPage };
    if (before !== undefined) request.beforeSeq = before;
    let page;
    try {
      page = await callDshRpc('session/page', { args: { request } });
    } catch {
      // A failed page must not discard the pages already in hand: the newest
      // declarations are the ones the phone wants, and we have them. Report the
      // partial answer instead of throwing the whole scan away.
      truncated = true;
      break;
    }
    const records = Array.isArray(page?.records) ? page.records : [];
    if (records.length === 0) break;
    pages += 1;
    for (const record of records) {
      const seq = record?.event?.seq;
      if (typeof seq === 'number') bySeq.set(seq, record);
      else bySeq.set(`p${pages}:${bySeq.size}`, record);
    }
    const firstSeq = records[0]?.event?.seq;
    if (typeof firstSeq !== 'number' || firstSeq <= 0) break;
    if (page?.hasMore === false) break;
    before = firstSeq;
    if (pages >= maxPages) truncated = true;
  }

  const records = [...bySeq.entries()]
    .sort((a, b) => (typeof a[0] === 'number' && typeof b[0] === 'number' ? a[0] - b[0] : 0))
    .map(([, record]) => record);
  return { records, cursor, pages, truncated };
}

/* ------------------------------------------------------------------ *
 * 3. Workspace changes (what the agent edited)
 * ------------------------------------------------------------------ */

/** Parse `git status --porcelain=v1 -z` output into entries. */
export function parsePorcelain(text) {
  if (typeof text !== 'string' || text.length === 0) return [];
  const parts = text.split('\0').filter((p) => p.length > 0);
  const out = [];
  for (let i = 0; i < parts.length; i += 1) {
    const entry = parts[i];
    if (entry.length < 4) continue;
    const status = entry.slice(0, 2).trim();
    const file = entry.slice(3);
    // A rename/copy record is followed by its original path as a separate
    // NUL-terminated field.
    let origPath = null;
    if (status.startsWith('R') || status.startsWith('C')) {
      origPath = parts[i + 1] ?? null;
      i += 1;
    }
    out.push({ status, path: file, origPath });
  }
  return out;
}

/** Parse `git diff --numstat -z` output into per-file line counts. */
export function parseNumstat(text) {
  if (typeof text !== 'string' || text.length === 0) return [];
  const out = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    const [added, deleted, ...rest] = line.split('\t');
    const file = rest.join('\t');
    if (!file) continue;
    out.push({
      path: file,
      added: added === '-' ? null : Number(added),
      deleted: deleted === '-' ? null : Number(deleted),
      binary: added === '-' || deleted === '-'
    });
  }
  return out;
}

/**
 * Merge status and numstat into one change list.
 *
 * numstat covers tracked modifications; status additionally covers untracked,
 * added and deleted files, which numstat alone omits. A file present in both
 * keeps its counts; a file only in status gets null counts (the phone renders
 * "—" instead of a fake zero).
 */
export function combineChanges(statusEntries, numstatEntries) {
  const stats = new Map();
  for (const entry of numstatEntries || []) {
    if (!entry?.path) continue;
    stats.set(entry.path, entry);
  }
  const seen = new Set();
  const out = [];
  for (const entry of statusEntries || []) {
    if (!entry?.path) continue;
    seen.add(entry.path);
    const stat = stats.get(entry.path);
    out.push({
      path: entry.path,
      status: entry.status,
      origPath: entry.origPath ?? null,
      added: stat?.added ?? null,
      deleted: stat?.deleted ?? null,
      binary: stat?.binary ?? false
    });
  }
  for (const [file, stat] of stats) {
    if (seen.has(file)) continue;
    out.push({
      path: file,
      status: 'M',
      origPath: null,
      added: stat.added,
      deleted: stat.deleted,
      binary: stat.binary
    });
  }
  return out.sort((a, b) => a.path.localeCompare(b.path));
}

/**
 * Split a unified diff into hunks for rendering.
 *
 * Only the hunk header and its lines are kept: a phone renders hunks, and the
 * file header would be duplicated by the file row above them. `kind` is what
 * drives the colour, so an addition never has to be detected by prefix on the
 * client.
 */
export function parseUnifiedDiff(text) {
  if (typeof text !== 'string' || !text.trim()) return [];
  const hunks = [];
  let current = null;
  for (const line of text.split('\n')) {
    if (line.startsWith('@@')) {
      current = { header: line, lines: [] };
      hunks.push(current);
      continue;
    }
    if (!current) continue;
    if (line.startsWith('diff --git') || line.startsWith('index ') ||
        line.startsWith('--- ') || line.startsWith('+++ ')) continue;
    let kind = 'context';
    if (line.startsWith('+')) kind = 'add';
    else if (line.startsWith('-')) kind = 'del';
    current.lines.push({ kind, text: line.slice(1) });
  }
  return hunks;
}

/* ------------------------------------------------------------------ *
 * 4. Token usage
 * ------------------------------------------------------------------ */

/**
 * Summarize token usage and context pressure for one session.
 *
 * Prefers the session projection (`tokenUsage` / `contextPressure`), which is
 * provider-reported, and falls back to the projection cache rows so a cold
 * session still shows its last known numbers instead of an empty card.
 *
 * @param values - `session/projections` values, when a live read succeeded.
 * @param rows - decoded projection-cache rows, when only the cache exists.
 * @returns a card payload; every numeric field is null when unknown.
 */
export function summarizeUsage(values, rows) {
  const live = values?.tokenUsage;
  const cached = decodeCachedRow(rows?.tokenUsage);
  const usage = live && typeof live === 'object' ? live : (cached && typeof cached === 'object' ? cached : null);

  const pressureLive = values?.contextPressure;
  const pressureCached = decodeCachedRow(rows?.contextPressure);
  const pressure = pressureLive && typeof pressureLive === 'object'
    ? pressureLive
    : (pressureCached && typeof pressureCached === 'object' ? pressureCached : null);

  const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  // Cache buckets follow provider semantics: a usage record that omits them
  // reports zero cache traffic, which is meaningful. Input/output are the
  // provider's core numbers and stay null when the record does not carry them.
  const usageNum = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : 0);

  const uncachedInput = num(usage?.uncachedInputTokens);
  const output = num(usage?.outputTokens);
  const cacheRead = usage ? usageNum(usage.cacheReadTokens) : null;
  const cacheWrite = usage ? usageNum(usage.cacheWriteTokens) : null;
  const parts = [uncachedInput, output, cacheRead, cacheWrite].filter((v) => v !== null);

  return {
    source: live ? 'live' : (cached ? 'cache' : 'none'),
    uncachedInputTokens: uncachedInput,
    outputTokens: output,
    cacheReadTokens: cacheRead,
    cacheWriteTokens: cacheWrite,
    totalTokens: parts.length ? parts.reduce((a, b) => a + b, 0) : null,
    pressureTokens: num(pressure?.pressureTokens),
    projectedTokens: num(pressure?.projectedTokens),
    contextWindow: num(pressure?.contextWindow),
    goal: (() => {
      const goalRow = decodeCachedRow(rows?.goal);
      const g = goalRow?.goal ?? null;
      if (!g || typeof g !== 'object') return null;
      return {
        objective: typeof g.objective === 'string' ? g.objective : '',
        phase: typeof g.phase === 'string' ? g.phase : 'active',
        roundsStarted: num(goalRow?.roundsStarted),
        maxGoalRounds: num(g.maxGoalRounds),
        blockedReason: g.blockedReason?.message ?? null
      };
    })()
  };
}

/** Projection-cache rows are stored as `@{ver, seq, val}` markers. */
function decodeCachedRow(row) {
  if (!row || typeof row !== 'object') return undefined;
  if ('val' in row) return row.val;
  return row;
}

/* ------------------------------------------------------------------ *
 * 5. Schedules
 * ------------------------------------------------------------------ */

/** One-line human description of a stored schedule record. */
export function describeSchedule(record) {
  if (!record || typeof record !== 'object') return '';
  const every = (n) => {
    if (typeof n !== 'number' || !Number.isFinite(n)) return '';
    if (n % 3600 === 0) return `每 ${n / 3600} 小时`;
    if (n % 60 === 0) return `每 ${n / 60} 分钟`;
    return `每 ${n} 秒`;
  };
  switch (record.kind) {
    case 'after': return every(record.after_seconds ?? record.afterSeconds);
    case 'every': return every(record.every_seconds ?? record.everySeconds);
    case 'at': return `在 ${record.at || ''}`;
    case 'daily': return `每天 ${record.time}`;
    case 'weekly': {
      const days = Array.isArray(record.weekdays) ? record.weekdays.join('/') : '';
      return `每周 ${days} ${record.time}`;
    }
    case 'cron': return `cron: ${record.expression}`;
    default: return record.kind ? String(record.kind) : '';
  }
}

/** Normalize one engine schedule record for the phone. */
export function normalizeSchedule(record) {
  if (!record || typeof record !== 'object') return null;
  const id = typeof record.id === 'string' ? record.id : '';
  if (!id) return null;
  return {
    id,
    kind: typeof record.kind === 'string' ? record.kind : 'unknown',
    title: typeof record.title === 'string' ? record.title : '',
    prompt: typeof record.prompt === 'string' ? record.prompt : '',
    schedule: describeSchedule(record),
    scheduledAt: typeof record.scheduledAt === 'string' ? record.scheduledAt : null,
    timeZone: typeof record.timeZone === 'string' ? record.timeZone : null
  };
}

/* ------------------------------------------------------------------ *
 * 6. ntfy push
 * ------------------------------------------------------------------ */

/**
 * Build the ntfy request for one event.
 *
 * The JSON publish form is used (not the simple form) because it carries the
 * click-through URL that opens the phone's session directly. Returns null when
 * push is not configured, so callers never have to branch on empty strings.
 *
 * @param config - ntfy settings from the bridge config.
 * @param message - `{ title, body, priority, tags, click, topic }`.
 * @returns `{ url, headers, body }` or null.
 */
export function buildNtfyRequest(config, message) {
  const base = typeof config?.ntfyUrl === 'string' ? config.ntfyUrl.trim() : '';
  if (!base) return null;
  const topic = String(message?.topic || config?.ntfyTopic || '').trim();
  if (!topic) return null;

  let url;
  try {
    const u = new URL(base);
    u.pathname = `${u.pathname.replace(/\/+$/, '')}/${encodeURIComponent(topic)}`;
    url = u.toString();
  } catch {
    return null;
  }

  const headers = { 'Content-Type': 'application/json' };
  const token = typeof config?.ntfyToken === 'string' ? config.ntfyToken.trim() : '';
  if (token) headers.Authorization = `Bearer ${token}`;

  const body = {
    title: String(message?.title || 'DSH'),
    message: String(message?.body || ''),
    priority: typeof message?.priority === 'number' ? message.priority : 3
  };
  if (Array.isArray(message?.tags) && message.tags.length) body.tags = message.tags;
  if (message?.click) {
    const click = String(message.click);
    body.click = click;
    // An explicit view action so the notification's button opens the session
    // even in clients that read actions instead of the click URL.
    body.actions = [{ action: 'view', label: '打开会话', url: click }];
  }

  return { url, headers, body };
}

/**
 * Decide whether one bridge event deserves a push.
 *
 * Only events where the agent is blocked on a human, or a long run finished,
 * are worth waking a phone for; deltas and tool frames would be noise.
 *
 * @param kind - event kind emitted by the gateway.
 * @returns push descriptor or null.
 */
export function pushForEvent(kind, detail = {}) {
  switch (kind) {
    case 'approval':
      return {
        title: '需要你授权',
        body: `${detail.toolName || '工具'}：${detail.reason || '等待授权'}`,
        priority: 5,
        tags: ['lock'],
        sessionId: detail.sessionId
      };
    case 'question':
      return {
        title: 'Agent 在等你回答',
        body: detail.question || '有提问等待回答',
        priority: 5,
        tags: ['question'],
        sessionId: detail.sessionId
      };
    case 'turn-end':
      return {
        title: '任务已完成',
        body: detail.summary || '本轮已结束',
        priority: 3,
        tags: ['white_check_mark'],
        sessionId: detail.sessionId
      };
    case 'turn-failed':
      return {
        title: '本轮执行失败',
        body: detail.summary || '需要你查看',
        priority: 4,
        tags: ['warning'],
        sessionId: detail.sessionId
      };
    default:
      return null;
  }
}

/* ------------------------------------------------------------------ *
 * 6b. ntfy delivery: dedupe, attribution, redaction
 * ------------------------------------------------------------------ */

/**
 * `WebSocket.OPEN`. Passed in rather than imported so this module stays free of
 * a transport dependency and can be unit-tested with plain objects.
 */
export const WS_OPEN = 1;

/**
 * Count the mobile sockets a frame can actually reach right now.
 *
 * Two conditions, both taken from state the gateway already maintains:
 *
 *   * `readyState === OPEN` — the same predicate `broadcastToMobileClients`
 *     uses to decide it can deliver a frame. Anything else cannot receive.
 *   * `isAlive !== false` — the heartbeat flag (`wss.on('connection')` sets it
 *     true; `ws.on('pong')` and every inbound message set it true again). The
 *     30-second sweep sets it false and pings, then TERMINATES any socket still
 *     false on the next sweep, so `false` means "a full ping interval went by
 *     with no pong".
 *
 * ⚠️ The trade-off is deliberate. Treating a socket whose pong is still in
 * flight (false for one RTT, milliseconds) as dead costs a duplicate
 * notification — annoying. Treating a socket that is OPEN but whose peer is
 * gone as alive costs a MISSED notification — the user is never told anything.
 * So the sweep flag is honoured, and the millisecond window is accepted.
 *
 * @param clients - iterable of sockets.
 * @param openReadyState - the OPEN constant for the transport in use.
 */
export function countDeliverableClients(clients, openReadyState = WS_OPEN) {
  if (!clients || typeof clients[Symbol.iterator] !== 'function') return 0;
  let live = 0;
  for (const ws of clients) {
    if (!ws || ws.readyState !== openReadyState) continue;
    if (ws.isAlive === false) continue;
    live += 1;
  }
  return live;
}

/**
 * Whether this event must be delivered over ntfy.
 *
 * The App shows its own local notification for exactly these events (approval /
 * question / turn end) while its socket is up, so pushing as well would hand the
 * user two notifications for one event. ntfy is the FALLBACK for "no socket":
 * process killed, phone asleep, radio gone.
 *
 * @param config - bridge config; `ntfyEnabled` must be strictly true.
 * @param clients - iterable of mobile sockets.
 */
export function shouldPushNtfy(config, clients, openReadyState = WS_OPEN) {
  if (config?.ntfyEnabled !== true) return false;
  return countDeliverableClients(clients, openReadyState) === 0;
}

/**
 * Redacted description of the configured ntfy target, for the audit trail.
 *
 * The host is useful ("is this going to ntfy.sh or to my own server?") and is
 * not a secret. The TOPIC is the shared secret of the channel — anyone who
 * knows it can subscribe — and the token is a credential. Neither may reach the
 * audit buffer, which is served to any authenticated client. So only the host
 * and the topic's LENGTH are recorded.
 */
export function describeNtfyTarget(config) {
  const base = typeof config?.ntfyUrl === 'string' ? config.ntfyUrl.trim() : '';
  let host = '';
  if (base) {
    try { host = new URL(base).host; } catch { host = ''; }
  }
  const topic = typeof config?.ntfyTopic === 'string' ? config.ntfyTopic.trim() : '';
  return { host, topicLength: topic.length };
}

/**
 * Strip the channel secret out of any text bound for the audit trail.
 *
 * A transport error message is normally host-only ("getaddrinfo ENOTFOUND
 * host"), but it is produced by a library we do not control and the URL it was
 * talking to contains the topic. Substituting both secrets covers the case where
 * one of them is echoed back verbatim, and the length cap stops a pathological
 * message from bloating the 200-entry audit ring.
 */
export function redactNtfyDetail(text, config) {
  let out = typeof text === 'string' ? text : String(text ?? '');
  const secrets = [
    typeof config?.ntfyToken === 'string' ? config.ntfyToken.trim() : '',
    typeof config?.ntfyTopic === 'string' ? config.ntfyTopic.trim() : ''
  ];
  for (const secret of secrets) {
    if (secret) out = out.split(secret).join('[redacted]');
  }
  return out.slice(0, 160);
}

/**
 * Deliver one ntfy push through an injected transport, and record the outcome.
 *
 * Split out of `lib/index.js` so every decision — dedupe, retry-free failure
 * handling, and what reaches the audit log — is testable without a network or a
 * real WebSocket. Never rejects: a push must not fail the approval or turn it
 * reports on.
 *
 * Audit outcomes, so "I got no notification" is answerable from the audit ring:
 *   * `skipped` + `reason: 'disabled'`      — the switch is off
 *   * `skipped` + `reason: 'app-connected'` — a socket is up; the App notifies
 *   * `skipped` + `reason: 'not-pushable'`  — the event kind is not push-worthy
 *   * `skipped` + `reason: 'unconfigured'`  — no URL or no topic
 *   * `sent`    + `status`
 *   * `failed`  + `status` / `reason`
 *
 * @param deps - `{ kind, detail, config, clients, openReadyState, send, audit,
 *   logger }`. `send(request)` resolves `{ ok, status, reason }`.
 * @returns `{ outcome, status?, reason? }`.
 */
export async function deliverNtfy({
  kind,
  detail = {},
  config,
  clients = [],
  openReadyState = WS_OPEN,
  send,
  audit,
  logger
} = {}) {
  const target = describeNtfyTarget(config);
  const liveClients = countDeliverableClients(clients, openReadyState);

  const record = (outcome, extra = {}) => {
    const payload = {
      kind: kind ?? '',
      outcome,
      liveClients,
      host: target.host,
      topicLength: target.topicLength,
      ...extra
    };
    try { audit?.('ntfy/push', payload); } catch { /* the audit sink is best effort */ }
    return payload;
  };

  if (config?.ntfyEnabled !== true) {
    record('skipped', { reason: 'disabled' });
    return { outcome: 'skipped', reason: 'disabled' };
  }
  if (liveClients > 0) {
    // The App is alive and will raise its own local notification for this event.
    record('skipped', { reason: 'app-connected' });
    return { outcome: 'skipped', reason: 'app-connected' };
  }

  const message = pushForEvent(kind, detail);
  if (!message) {
    record('skipped', { reason: 'not-pushable' });
    return { outcome: 'skipped', reason: 'not-pushable' };
  }
  const withClick = detail.clickUrl ? { ...message, click: detail.clickUrl } : message;
  const request = buildNtfyRequest(config, withClick);
  if (!request) {
    record('skipped', { reason: 'unconfigured' });
    return { outcome: 'skipped', reason: 'unconfigured' };
  }
  if (typeof send !== 'function') {
    record('failed', { reason: 'no-transport' });
    return { outcome: 'failed', reason: 'no-transport' };
  }

  try {
    const res = await send(request);
    if (res?.ok) {
      const status = typeof res.status === 'number' ? res.status : null;
      record('sent', { status });
      logger?.info?.('[dsh-mobile-bridge] ntfy 推送已送达: HTTP %s', status);
      return { outcome: 'sent', status };
    }
    const status = typeof res?.status === 'number' ? res.status : null;
    const reason = redactNtfyDetail(res?.reason || 'rejected', config);
    record('failed', { status, reason });
    logger?.warn?.('[dsh-mobile-bridge] ntfy 推送失败: HTTP %s %s', status, reason);
    return { outcome: 'failed', status, reason };
  } catch (err) {
    const reason = redactNtfyDetail(err?.message || 'transport-error', config);
    record('failed', { status: null, reason });
    logger?.warn?.('[dsh-mobile-bridge] ntfy 推送异常: %s', reason);
    return { outcome: 'failed', status: null, reason };
  }
}

/* ------------------------------------------------------------------ *
 * Route handling
 * ------------------------------------------------------------------ */

/**
 * Every method+path this module claims, as `[method, pathname]` pairs.
 *
 * ⚠️ This list exists so the legacy `/api/mobile/sessions/*` GET wildcard in
 * `lib/index.js` can refuse to handle these paths. That wildcard treats
 * everything after `/api/mobile/sessions/` as a session id and hands it to
 * `getSessionHistory()`, so it swallows any GET feature route registered under
 * that prefix — silently. Measured on the live instance before the fix:
 *
 *   GET /api/mobile/sessions/queue?sessionId=session-03ba0334…
 *   -> {"ok":true,"code":0,"data":{"sessionId":"queue","isRunning":false,
 *       "messages":[]}}          ← a fake session literally named "queue"
 *
 * `sessions/search` had already been bitten by the same trap (it returned an
 * empty history forever) and was patched with a single exclusion. The dispatch
 * is now ordered before the wildcard AND the wildcard carries this guard, so a
 * future addition under `/api/mobile/sessions/` cannot silently regress.
 * `tests/unit/features.test.mjs` cross-checks this list against
 * `handleFeatureRoute`'s real behaviour, so the two cannot drift apart.
 */
export const FEATURE_ROUTES = [
  ['GET', '/api/mobile/sessions/queue'],
  ['POST', '/api/mobile/sessions/queue'],
  ['GET', '/api/mobile/schedules'],
  ['POST', '/api/mobile/schedules/delete'],
  ['GET', '/api/mobile/jobs'],
  ['POST', '/api/mobile/jobs/kill'],
  ['GET', '/api/mobile/deliverables'],
  ['GET', '/api/mobile/deliverables/download'],
  ['GET', '/api/mobile/workspace/changes'],
  ['GET', '/api/mobile/workspace/diff'],
  ['GET', '/api/mobile/session/stats'],
  ['GET', '/api/mobile/push/config'],
  ['POST', '/api/mobile/push/config'],
  ['POST', '/api/mobile/push/test']
];

/**
 * True when a request belongs to this module rather than to session history.
 *
 * @param method - HTTP method.
 * @param pathname - request pathname (query string already stripped).
 */
export function claimsMobileFeatureRoute(method, pathname) {
  if (typeof pathname !== 'string' || pathname.length === 0) return false;
  const m = typeof method === 'string' ? method.toUpperCase() : '';
  if (!m) return false;
  return FEATURE_ROUTES.some(([rm, rp]) => rm === m && rp === pathname);
}

/**
 * Handle one of the new `/api/mobile/*` feature routes.
 *
 * @param deps - `{ pathname, req, res, parsedUrl, jsonBody, auth, sendJson,
 *   callDshRpc, readStreamOnce, readProjections, readSessionRecords, readConfig,
 *   saveConfig, audit, logger, pushTest }`.
 * @returns true when the route was handled.
 */
export async function handleFeatureRoute(deps) {
  const {
    pathname, req, res, jsonBody, sendJson, callDshRpc, readStreamOnce,
    readProjections, readSessionRecords, readConfig, writeConfig, audit, logger
  } = deps;

  /* ---- queue ---- */
  if (pathname === '/api/mobile/sessions/queue' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    if (!sessionId) { sendJson(400, { ok: false, error: 'sessionId is required' }); return true; }
    const values = await readProjections(sessionId);
    sendJson(200, { ok: true, code: 0, queue: selectQueueRows(values) });
    return true;
  }

  if (pathname === '/api/mobile/sessions/queue' && req.method === 'POST') {
    const sessionId = String(jsonBody.sessionId || '').trim();
    const itemId = String(jsonBody.itemId || jsonBody.id || '').trim();
    if (!sessionId || !itemId) { sendJson(400, { ok: false, error: 'sessionId and itemId are required' }); return true; }
    const normalized = normalizeQueueAction(jsonBody.action);
    if (!normalized.ok) { sendJson(400, { ok: false, error: normalized.error }); return true; }
    try {
      await callDshRpc('session/updateQueue', {
        args: { request: { sessionId, itemId, action: normalized.action } }
      });
      audit('session/queue-update', { sessionId, itemId, kind: normalized.action.kind });
      sendJson(200, { ok: true, code: 0 });
    } catch (err) {
      sendJson(502, { ok: false, code: 502, error: err?.message || 'queue update failed' });
    }
    return true;
  }

  /* ---- schedules ---- */
  if (pathname === '/api/mobile/schedules' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    if (!sessionId) { sendJson(400, { ok: false, error: 'sessionId is required' }); return true; }
    try {
      const records = await callDshRpc('schedule/list', { args: { request: { sessionId } } });
      const schedules = (Array.isArray(records) ? records : []).map(normalizeSchedule).filter(Boolean);
      sendJson(200, { ok: true, code: 0, schedules });
    } catch (err) {
      sendJson(502, { ok: false, code: 502, error: err?.message || 'schedule/list failed' });
    }
    return true;
  }

  if (pathname === '/api/mobile/schedules/delete' && req.method === 'POST') {
    const sessionId = String(jsonBody.sessionId || '').trim();
    const id = String(jsonBody.id || '').trim();
    if (!sessionId || !id) { sendJson(400, { ok: false, error: 'sessionId and id are required' }); return true; }
    try {
      const result = await callDshRpc('schedule/delete', { args: { request: { sessionId, id } } });
      audit('schedule/delete', { sessionId, id, deleted: result?.deleted === true });
      sendJson(200, { ok: true, code: 0, result });
    } catch (err) {
      sendJson(502, { ok: false, code: 502, error: err?.message || 'schedule/delete failed' });
    }
    return true;
  }

  /* ---- background jobs ---- */
  if (pathname === '/api/mobile/jobs' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    if (!sessionId) { sendJson(400, { ok: false, error: 'sessionId is required' }); return true; }
    // `job/list` is a stream Remote; it is opened on the MUX and only its first
    // whole-set frame is consumed (reconnect semantics guarantee that frame is
    // already the truth).
    const frame = await readStreamOnce('job/list', { request: { sessionId } }, { take: 1, timeoutMs: 5000 });
    if (!frame) {
      sendJson(200, { ok: true, code: 0, jobs: [], degraded: 'jobs-unavailable' });
      return true;
    }
    const jobs = (Array.isArray(frame.jobs) ? frame.jobs : []).map((job) => ({
      id: String(job?.id ?? ''),
      kind: String(job?.kind ?? ''),
      label: String(job?.label ?? ''),
      status: String(job?.status ?? 'running'),
      progress: job?.progress ?? null,
      detail: job?.detail ?? null,
      startedAt: typeof job?.startedAt === 'number' ? job.startedAt : null,
      finishedAt: typeof job?.finishedAt === 'number' ? job.finishedAt : null
    }));
    sendJson(200, { ok: true, code: 0, jobs });
    return true;
  }

  if (pathname === '/api/mobile/jobs/kill' && req.method === 'POST') {
    const sessionId = String(jsonBody.sessionId || '').trim();
    const jobId = String(jsonBody.jobId || '').trim();
    if (!jobId) { sendJson(400, { ok: false, error: 'jobId is required' }); return true; }
    try {
      const result = await callDshRpc('job/kill', { args: { request: { ...(sessionId ? { sessionId } : {}), jobId } } });
      audit('job/kill', { sessionId, jobId, outcome: result?.outcome });
      sendJson(200, { ok: true, code: 0, result });
    } catch (err) {
      sendJson(502, { ok: false, code: 502, error: err?.message || 'job/kill failed' });
    }
    return true;
  }

  /* ---- deliverables ---- */
  if (pathname === '/api/mobile/deliverables' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    if (!sessionId) { sendJson(400, { ok: false, error: 'sessionId is required' }); return true; }
    const { records, cwd, truncated } = await readSessionRecords(sessionId);
    const deliverables = extractDeliverables(records, cwd);
    sendJson(200, { ok: true, code: 0, deliverables, truncated: truncated === true });
    return true;
  }

  if (pathname === '/api/mobile/deliverables/download' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    const wanted = String(deps.parsedUrl.query?.path || '').trim();
    if (!sessionId || !wanted) { sendJson(400, { ok: false, error: 'sessionId and path are required' }); return true; }
    const { records, cwd } = await readSessionRecords(sessionId);
    const row = resolveDeliverable(extractDeliverables(records, cwd), wanted);
    if (!row) {
      // Exact membership in the presented set, never a string filter.
      sendJson(403, { ok: false, code: 403, error: '该文件不在本会话的交付物清单中' });
      return true;
    }
    // `sendFile` answers false when the declared file is gone or unreadable. It
    // deliberately writes nothing in that case, so the route MUST answer here —
    // otherwise the socket is left open with no response and the phone's
    // 60-second `http.get` timeout is the only thing that ends it (that is what
    // "点不开" looked like: a long spinner and then a generic timeout toast).
    //
    // `res` is passed explicitly: `sendFile` writes the 200 itself, and it used
    // to reference `res` as a free variable it could not see, which threw
    // `ReferenceError: res is not defined` on every download — a 500 for every
    // deliverable. The signature is (res, absPath, displayName).
    const sent = await sendFile(res, row.path, row.display);
    if (sent === false) {
      sendJson(404, {
        ok: false,
        code: 404,
        error: '交付物文件在宿主上已不存在或不可读',
        path: row.path
      });
    }
    return true;
  }

  /* ---- workspace changes / diff ---- */
  if (pathname === '/api/mobile/workspace/changes' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    if (!sessionId) { sendJson(400, { ok: false, error: 'sessionId is required' }); return true; }
    const changes = await deps.readWorkspaceChanges(sessionId);
    sendJson(200, { ok: true, code: 0, ...changes });
    return true;
  }

  if (pathname === '/api/mobile/workspace/diff' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    const wanted = String(deps.parsedUrl.query?.path || '').trim();
    if (!sessionId || !wanted) { sendJson(400, { ok: false, error: 'sessionId and path are required' }); return true; }
    // The path must be one the change list already reported: asking git for an
    // arbitrary path would let a client probe the filesystem through diff
    // output. Membership is checked on the same listing the phone renders.
    const listing = await deps.readWorkspaceChanges(sessionId);
    if (!listing.available) { sendJson(200, { ok: true, code: 0, ...listing, hunks: [] }); return true; }
    const known = (listing.files || []).some((f) => f.path === wanted);
    if (!known) {
      sendJson(404, { ok: false, code: 404, error: '该文件不在本次变更列表中' });
      return true;
    }
    const diff = await deps.readWorkspaceChanges(sessionId, wanted);
    sendJson(200, { ok: true, code: 0, ...diff });
    return true;
  }

  /* ---- token usage ---- */
  if (pathname === '/api/mobile/session/stats' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    if (!sessionId) { sendJson(400, { ok: false, error: 'sessionId is required' }); return true; }
    const values = await readProjections(sessionId);
    const rows = deps.readProjectionRows(sessionId);
    sendJson(200, { ok: true, code: 0, stats: summarizeUsage(values, rows) });
    return true;
  }

  /* ---- push config ---- */
  if (pathname === '/api/mobile/push/config' && req.method === 'GET') {
    const cfg = readConfig();
    sendJson(200, {
      ok: true,
      code: 0,
      push: {
        enabled: cfg.ntfyEnabled === true,
        url: cfg.ntfyUrl || '',
        topic: cfg.ntfyTopic || '',
        hasToken: Boolean(cfg.ntfyToken)
      }
    });
    return true;
  }

  if (pathname === '/api/mobile/push/config' && req.method === 'POST') {
    const patch = {};
    if (jsonBody.url !== undefined) patch.ntfyUrl = String(jsonBody.url || '').trim();
    if (jsonBody.topic !== undefined) patch.ntfyTopic = String(jsonBody.topic || '').trim();
    if (jsonBody.token !== undefined) patch.ntfyToken = String(jsonBody.token || '').trim();
    if (jsonBody.enabled !== undefined) patch.ntfyEnabled = jsonBody.enabled === true;
    const updated = writeConfig(patch);
    audit('push/config', {
      enabled: updated.ntfyEnabled === true,
      url: updated.ntfyUrl || '',
      topic: updated.ntfyTopic || '',
      tokenChanged: jsonBody.token !== undefined
    });
    return sendJson(200, {
      ok: true,
      code: 0,
      push: {
        enabled: updated.ntfyEnabled === true,
        url: updated.ntfyUrl || '',
        topic: updated.ntfyTopic || '',
        hasToken: Boolean(updated.ntfyToken)
      }
    }), true;
  }

  if (pathname === '/api/mobile/push/test' && req.method === 'POST') {
    const ok = await deps.pushTest();
    sendJson(ok ? 200 : 502, {
      ok,
      code: ok ? 0 : 502,
      error: ok ? undefined : '推送未配置或发送失败（检查 ntfy 地址与 topic）'
    });
    return true;
  }

  return false;
}
