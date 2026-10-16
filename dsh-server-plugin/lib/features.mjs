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
import fs from 'node:fs';
import os from 'node:os';

import {
  coerceToolInput,
  describeTurnEnd,
  isCarriedContext,
  isFailedTurnEnd
} from './core.mjs';

import {
  normalizeAgentTeam,
  agentTeamFromProjectionRows,
  summarizeAgentTeam
} from './agentteam.mjs';

import { orderJobs, summarizeJobFollow } from './extensions.mjs';

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
  // [fix 2026-10-11] Path-traversal gate: these names are joined under the
  // projcache dir by every caller. Keep the same charset rule core.mjs's
  // assertSessionId enforces (and which deleteSession applies).
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(clean)) return [];
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
/**
 * Probe the engine's authoritative session cursor (the newest event seq).
 *
 * The ONLY reliable way to learn a session's cursor is the "past cursor"
 * rejection: ask for a page at throughSeq=MAX_SAFE_INTEGER and parse the real
 * cursor out of the error message (see parseCursorFromPastSeqError notes).
 * getSessionHistory used to take the paging upper bound from the projection
 * cache's max row seq instead — but the projcache is an asynchronously
 * flushed COPY and can lag the event log indefinitely (measured in production:
 * projcache stuck at seq 723 while the log had reached 794 — the missing
 * turn, user prompt + assistant reply, was silently sliced off the snapshot
 * and the phone never saw it again). This probe reads the truth.
 *
 * @returns the cursor, or null when it cannot be determined (caller keeps
 * whatever fallback it had).
 */
export async function probeSessionCursor({ callDshRpc, sessionId }) {
  if (typeof callDshRpc !== 'function' || !sessionId) return null;
  try {
    await callDshRpc('session/page', {
      args: { request: { address: { kind: 'session', sessionId }, throughSeq: Number.MAX_SAFE_INTEGER, maxMessages: 1 } }
    });
    // An accepted probe means the engine's cursor is at/above MAX_SAFE_INTEGER
    // (or it does not enforce the bound). Treat "latest" as the anchor.
    return Number.MAX_SAFE_INTEGER;
  } catch (err) {
    return parseCursorFromPastSeqError(err?.message);
  }
}

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
 * 2b. Chat-history paging (mobile infinite scroll-up)  [feat 2026-10-12]
 * ------------------------------------------------------------------ */

/**
 * Convert `session/page` records into the same chat-message shape
 * `getSessionHistory` in lib/index.js has always returned, so the phone can
 * render a history page and the live tail with one renderer.
 *
 * Extracted from index.js (which previously inlined this loop) so the two
 * callers cannot drift. Differences from the inline version are deliberate and
 * documented:
 *   - every message carries `seq` (the event seq that produced it) — the phone
 *     needs it as the `beforeSeq` cursor and for dedup against the live stream;
 *   - `tool/call` after a page boundary (no preceding assistant/message in this
 *     page) is dropped rather than silently attached to the wrong message;
 *   - `turn/end` is ignored here: lastTurn is a tail concern owned by
 *     getSessionHistory, not something a deep-history page should report.
 *
 * @param records - `session/page` records (`{ event }` entries), ascending.
 * @returns `{ messages }` — ascending, same fields as getSessionHistory plus seq.
 */
export function convertSessionRecordsToMessages(records, opts = {}) {
  const messages = [];
  const auditDropped = typeof opts.auditDropped === 'function' ? opts.auditDropped : null;
  let currentAssistantMsg = null;
  for (const record of Array.isArray(records) ? records : []) {
    const ev = record?.event;
    if (!ev) continue;

    if (ev.type === 'user/message') {
      currentAssistantMsg = null;
      let text = '';
      if (Array.isArray(ev.data?.content)) {
        for (const part of ev.data.content) {
          if (part.type === 'text' && part.text) text += part.text;
        }
      } else if (typeof ev.data?.content === 'string') {
        text = ev.data.content;
      }

      // Same injected-context filter as the live tail — otherwise a history
      // page would surface memory snapshots and system reminders as if the
      // user had typed them.
      // [fix 2026-10-14] 误杀审计：过滤条件是内容启发式（子串匹配），真实用户
      // 消息引用了这些字样就会被整条丢弃且无迹可查。命中必须留痕，60 秒/会话
      // 最多一条，避免轮询刷爆审计环形缓冲。
      if (isCarriedContext(text, ev) ||
          text.startsWith('Time sampled while preparing turn') ||
          text.startsWith('Memory recall guidance') ||
          text.includes('<system_information>')) {
        if (auditDropped && typeof ev.seq === 'number') {
          auditDropped({ seq: ev.seq, why: 'carried-context', length: text.length });
        }
        continue;
      }

      if (text.trim()) {
        messages.push({
          id: `hist_${typeof ev.seq === 'number' ? ev.seq : messages.length}`,
          role: 'user',
          content: text.trim(),
          time: ev.time || Date.now(),
          seq: typeof ev.seq === 'number' ? ev.seq : null
        });
      } else if (auditDropped && typeof ev.seq === 'number') {
        // [fix 2026-10-14] 纯附件/空文本用户消息以前是静默消失；现在留痕
        //（是否生成占位消息由 App 端显示层决定，网关至少不能无声吞掉）。
        auditDropped({ seq: ev.seq, why: 'empty-user-text', length: 0 });
      }
    } else if (ev.type === 'assistant/message') {
      const msgObj = ev.data?.message;
      let reasoning = '';
      let text = '';
      if (Array.isArray(msgObj?.content)) {
        for (const part of msgObj.content) {
          if (part.type === 'reasoning') reasoning += part.text || '';
          if (part.type === 'text') text += part.text || '';
        }
      } else if (typeof msgObj?.content === 'string') {
        text = msgObj.content;
      }

      if (reasoning || text) {
        if (!currentAssistantMsg) {
          currentAssistantMsg = {
            id: `hist_${typeof ev.seq === 'number' ? ev.seq : messages.length}`,
            role: 'assistant',
            content: text,
            thinking: reasoning,
            tools: [],
            time: ev.time || Date.now(),
            seq: typeof ev.seq === 'number' ? ev.seq : null
          };
          messages.push(currentAssistantMsg);
        } else {
          if (reasoning) {
            currentAssistantMsg.thinking = (currentAssistantMsg.thinking ? currentAssistantMsg.thinking + '\n' : '') + reasoning;
          }
          if (text) {
            currentAssistantMsg.content = (currentAssistantMsg.content ? currentAssistantMsg.content + '\n' : '') + text;
          }
        }
      } else {
        // [fix 2026-10-14] 空文本的 assistant/message 也要建宿主消息：一个只有
        // 工具调用、没有正文的回复以前整轮不可见（工具结果挂在 null 宿主上被
        // 一起丢掉）。空占位 + 后续 tool/call 填充 = 手机至少能看到"这轮跑了什么"。
        if (!currentAssistantMsg) {
          currentAssistantMsg = {
            id: `hist_${typeof ev.seq === 'number' ? ev.seq : messages.length}`,
            role: 'assistant',
            content: '',
            thinking: '',
            tools: [],
            time: ev.time || Date.now(),
            seq: typeof ev.seq === 'number' ? ev.seq : null
          };
          messages.push(currentAssistantMsg);
        }
      }
    } else if (ev.type === 'tool/call') {
      const callData = ev.data;
      if (currentAssistantMsg && callData?.name) {
        currentAssistantMsg.tools.push({
          name: callData.name,
          input: coerceToolInput(callData.arguments),
          id: callData.callId
        });
      }
    }
    // turn/end and every other event type: not a chat message.
  }
  return { messages };
}

/**
 * Fetch ONE reverse page of older history, ending just above `beforeSeq`.
 *
 * Unlike `collectSessionRecords` (which probes the cursor and walks up to 8
 * pages for the deliverable scan), this answers a single scroll-up: the phone
 * asks for one page, the gateway answers with one page. The cursor probe is
 * reused (the past-cursor rejection IS the cursor) but capped at one page walk
 * so a scroll cannot hammer the engine.
 *
 * @param deps - `{ callDshRpc, sessionId, beforeSeq?, max? }`. `sessionId` must
 *   already be the full `session-…` id.
 * @returns `{ messages, hasMore, oldestSeq }`. On ANY engine failure this
 *   degrades to `{ messages: [], hasMore: false, oldestSeq: null }` — an
 *   endpoint that answers 500 turns one bad scroll into a broken chat.
 */
export async function readHistoryPage({ callDshRpc, sessionId, beforeSeq, max = 60 }) {
  const empty = { messages: [], hasMore: false, oldestSeq: null };
  if (typeof callDshRpc !== 'function' || !sessionId) return empty;

  const address = { kind: 'session', sessionId };
  const pageSize = Math.min(Math.max(Number(max) || 60, 1), 200);

  // 1. Cursor probe — identical mechanism to collectSessionRecords.
  let cursor;
  try {
    await callDshRpc('session/page', { args: { request: { address, throughSeq: Number.MAX_SAFE_INTEGER, maxMessages: 1 } } });
    // The engine should reject a probe past the cursor; an accepted probe means
    // the cursor is at/above MAX_SAFE_INTEGER — treat "latest" as the anchor.
    cursor = Number.MAX_SAFE_INTEGER;
  } catch (err) {
    const parsed = parseCursorFromPastSeqError(err?.message);
    if (parsed === null) return empty;
    cursor = parsed;
  }

  // 2. The upper bound of THIS page: the oldest seq the phone already has.
  //    Engine contract (verified, see parseCursorFromPastSeqError notes):
  //    `{ address, throughSeq: U, maxMessages: N }` answers the newest N events
  //    with seq <= U; `beforeSeq` is optional and only narrows the lower end.
  //    So for "older than S" we pass throughSeq = S and let maxMessages bound
  //    the window — the phone dedups the possibly-included boundary seq itself.
  let upperBound;
  if (typeof beforeSeq === 'number' && Number.isFinite(beforeSeq) && beforeSeq > 0) {
    upperBound = Math.min(beforeSeq, cursor);
  } else {
    // No beforeSeq: first page. Anchor at the cursor so we get the same newest
    // window getSessionHistory would show.
    upperBound = cursor;
  }
  if (upperBound <= 0) return empty;

  let page;
  try {
    page = await callDshRpc('session/page', {
      args: {
        request: {
          address,
          throughSeq: upperBound,
          maxMessages: pageSize
        }
      }
    });
  } catch {
    return empty;
  }

  const records = Array.isArray(page?.records) ? page.records : [];
  const { messages } = convertSessionRecordsToMessages(records);

  // Records come back ascending; oldestSeq is the seq of the oldest event we
  // actually saw (message-bearing or not — it is the paging anchor).
  const seqs = records.map((r) => r?.event?.seq).filter((s) => typeof s === 'number');
  const oldestSeq = seqs.length ? Math.min(...seqs) : null;

  // hasMore: the engine said there is more, AND the page was not empty, AND
  // there is still room above the oldest seq we saw.
  const engineHasMore = page?.hasMore !== false;
  const hasMore = records.length > 0 && engineHasMore && (oldestSeq === null || oldestSeq > 1);

  return { messages, hasMore, oldestSeq };
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
        blockedReason: g.blockedReason?.message ?? null,
        // [feat 2026-10-12] CAS ref for goals/pause|resume|complete. The engine
        // has no goal-read RPC, so the projection row is the only source of
        // { id, revision }; the phone sends both back verbatim on an action.
        goalId: typeof g.id === 'string' ? g.id : null,
        revision: num(g.revision)
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

  // [fix 2026-10-12] JSON 发布必须 POST 到**根路径**且 body 带 `topic` 字段
  // （ntfy 官方文档 "Publish as JSON"）。之前的实现 POST 到
  // `/<topic>` 且 body 里没有 topic —— ntfy 认不出这是 JSON 发布请求，把整个
  // JSON 字符串当成纯文本消息展示，用户手机上看到的就是一坨转义代码，click /
  // actions 字段也全部失效（它们只有 JSON body 形态才生效）。改为根路径 +
  // body.topic，与官方 curl 示例完全一致。
  let url;
  try {
    const u = new URL(base);
    u.pathname = `${u.pathname.replace(/\/+$/, '')}/`;
    url = u.toString();
  } catch {
    return null;
  }

  const headers = { 'Content-Type': 'application/json' };
  const token = typeof config?.ntfyToken === 'string' ? config.ntfyToken.trim() : '';
  if (token) headers.Authorization = `Bearer ${token}`;

  const body = {
    topic,
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
 * 7. One-tap connection diagnostics [feat 2026-10-12]
 * ------------------------------------------------------------------ */

/**
 * Redact anything that could leak a secret or a host path from one diagnostic
 * detail string. Tokens and absolute paths never reach the phone; a detail is
 * a short reason code, not a message from the engine (engine error text can
 * embed a URL with the topic or a home path, so it is never passed through).
 */
export function redactDiagnosticDetail(text) {
  let s = typeof text === 'string' ? text : String(text ?? '');
  // Collapse any absolute path (posix or win32) to its last two segments so
  // "which file" survives but the home directory does not.
  s = s.replace(/([A-Za-z]:)?(?:[\\/][^\s"']*)+/g, (m) => {
    const parts = m.split(/[\\/]/).filter(Boolean);
    return parts.length ? `…/${parts.slice(-2).join('/')}` : '[path]';
  });
  // Credential-shaped fragments (bearer tokens, long hex/base64 runs) never
  // pass through: an engine error message can echo an auth header verbatim.
  s = s.replace(/\b(?:Bearer\s+|token[=:\s]+|sk-)[A-Za-z0-9._~+/=-]{8,}/gi, '[credential]');
  s = s.replace(/\b[A-Fa-f0-9]{32,}\b/g, '[credential]');
  return s.slice(0, 120);
}

/**
 * Probe the engine's live RPC surface with the cheapest real call.
 *
 * `session/page` was chosen over `workspace/list` because it is the RPC the
 * bridge already speaks with a shape we know is accepted (a past-cursor
 * rejection is itself proof the engine answered), and it does not depend on
 * any workspace being registered. Any answer — including an engine-side
 * rejection — counts as "the engine is reachable"; only transport failure
 * (ECONNREFUSED / timeout / parse error) counts as down.
 *
 * @param deps - `{ callDshRpc, timeoutMs? }`.
 * @returns `{ ok, detail, ms }`.
 */
export async function probeEngineRpc({ callDshRpc, timeoutMs = 4000 } = {}) {
  const started = Date.now();
  if (typeof callDshRpc !== 'function') {
    return { ok: false, detail: 'rpc caller unavailable', ms: 0 };
  }
  try {
    // `throughSeq: 0` is a valid wire field for a REQUIRED number; an engine
    // that is alive answers (possibly with an input error, which still proves
    // the transport + gateway are up).
    await withTimeout(callDshRpc('session/page', {
      args: { request: { address: { kind: 'session', sessionId: 'diagnostics-probe' }, throughSeq: 0, maxMessages: 1 } }
    }), timeoutMs);
    return { ok: true, detail: 'ok', ms: Date.now() - started };
  } catch (err) {
    return { ok: false, detail: redactDiagnosticDetail(err?.message || 'unreachable'), ms: Date.now() - started };
  }
}

function withTimeout(promise, ms) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`engine rpc timeout after ${ms}ms`)), ms);
    Promise.resolve(promise).then(
      (v) => { clearTimeout(timer); resolve(v); },
      (e) => { clearTimeout(timer); reject(e); }
    );
  });
}

/**
 * Disk writability probe under one directory: write a temp file, delete it.
 * Never throws; returns { ok, detail } with no paths in the detail.
 */
export function probeDiskWritable(dir) {
  const probe = path.join(dir, `.diag-${process.pid}-${Date.now()}.tmp`);
  try {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(probe, 'dsh-mobile diagnostics');
    try { fs.unlinkSync(probe); } catch { /* already gone is fine */ }
    return { ok: true, detail: 'ok' };
  } catch (err) {
    return { ok: false, detail: redactDiagnosticDetail(err?.code || err?.message || 'write failed') };
  }
}

/**
 * Subagent catalog normalization: project the engine's `subagents/list`
 * result onto the rows the phone renders. One-shot children cannot take a
 * continuation, so they carry no interrupt affordance — the gateway marks them
 * and the App hides the button rather than sending an RPC that must fail.
 *
 * @param catalog - `SubagentCatalog` from the engine, when the RPC answered.
 * @returns list rows, or null when the engine has no listing capability.
 */
export function normalizeSubagentCatalog(catalog) {
  if (!catalog || !Array.isArray(catalog.entries)) return null;
  return {
    parentAvailable: catalog.parentAvailable === true,
    entries: catalog.entries.map((e) => {
      if (!e || typeof e !== 'object') return null;
      const id = typeof e.id === 'string' ? e.id : '';
      if (!id) return null;
      if (e.kind === 'diagnostic') {
        return { id, kind: 'diagnostic', reason: String(e.reason || 'unavailable') };
      }
      return {
        id,
        kind: 'child',
        activity: e.activity === 'running' ? 'running' : 'inactive',
        mode: e.mode === 'continuable' ? 'continuable' : 'one-shot',
        label: typeof e.label === 'string' ? e.label : '',
        hasChildren: e.hasChildren === true
      };
    }).filter(Boolean)
  };
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
  ['GET', '/api/mobile/diagnostics'], // [feat 2026-10-12] one-tap connection diagnostics
  ['GET', '/api/mobile/sessions/history/page'], // [feat 2026-10-12] reverse history paging
  ['GET', '/api/mobile/sessions/queue'],
  ['POST', '/api/mobile/sessions/queue'],
  ['GET', '/api/mobile/schedules'],
  ['POST', '/api/mobile/schedules/delete'],
  ['GET', '/api/mobile/jobs'],
  // [feat 2026-10-13] one job's output ring, resumable by byte offset (engine RPC: job/follow)
  ['GET', '/api/mobile/jobs/follow'],
  ['POST', '/api/mobile/jobs/kill'],
  ['GET', '/api/mobile/deliverables'],
  ['GET', '/api/mobile/deliverables/download'],
  ['GET', '/api/mobile/workspace/changes'],
  ['GET', '/api/mobile/workspace/diff'],
  ['GET', '/api/mobile/session/stats'],
  ['GET', '/api/mobile/push/config'],
  ['POST', '/api/mobile/push/config'],
  ['POST', '/api/mobile/push/test'],
  // [feat 2026-10-12] subagent control (engine RPC: subagents/list, subagents/interruptByParent)
  ['GET', '/api/mobile/sessions/subagents'],
  ['GET', '/api/mobile/sessions/team'], // [feat 2026-10-16] Agent Team roster + task board
  ['POST', '/api/mobile/sessions/subagents/interrupt'],
  // [feat 2026-10-12] goal control (engine RPC: goals/pause, goals/resume, goals/complete)
  ['POST', '/api/mobile/goals/pause'],
  ['POST', '/api/mobile/goals/resume'],
  ['POST', '/api/mobile/goals/complete'],
  // [feat 2026-10-12] slash-command discovery (engine RPC: commands/list)
  ['GET', '/api/mobile/sessions/commands']
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
    readProjections, readSessionRecords, readConfig, writeConfig, audit, logger,
    assertSessionId
  } = deps;

  /* ---- queue ---- */
  // [feat 2026-10-12] Reverse history paging for the mobile infinite scroll-up.
  // Degrades, never 500s: an engine failure answers hasMore:false so the phone
  // simply shows "已到会话开头" instead of a broken chat.
  if (pathname === '/api/mobile/sessions/history/page' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    if (!sessionId) { sendJson(400, { ok: false, error: 'sessionId is required' }); return true; }
    const idCheck = deps.assertSessionId
      ? deps.assertSessionId(sessionId)
      : { ok: true };
    if (!idCheck.ok) { sendJson(400, { ok: false, error: idCheck.error || 'invalid sessionId' }); return true; }
    const fullId = sessionId.startsWith('session-') ? sessionId : `session-${sessionId}`;
    const beforeSeqRaw = deps.parsedUrl.query?.beforeSeq;
    const beforeSeq = beforeSeqRaw != null && beforeSeqRaw !== '' ? Number(beforeSeqRaw) : undefined;
    if (beforeSeq !== undefined && (!Number.isFinite(beforeSeq) || beforeSeq < 0)) {
      sendJson(400, { ok: false, error: 'beforeSeq must be a non-negative number' });
      return true;
    }
    const max = Number(deps.parsedUrl.query?.max || 60);
    try {
      const page = await readHistoryPage({ callDshRpc, sessionId: fullId, beforeSeq, max });
      sendJson(200, { ok: true, code: 0, ...page });
    } catch (err) {
      // readHistoryPage already swallows engine errors; this belt-and-braces
      // guard keeps the contract: a paging hiccup must never 500 the chat.
      logger?.warn?.('[history/page] failed:', err?.message || err);
      sendJson(200, { ok: true, code: 0, messages: [], hasMore: false, oldestSeq: null });
    }
    return true;
  }

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

  /* ---- background jobs ----
   *
   * ⚠️ CORRECTION (2026-10-13, later the same day). An earlier revision of this
   * file claimed `job/list` does not exist and rerouted this to
   * `session/control`. That claim was WRONG, and it came from a scanner that
   * skipped nested `node_modules` — which hid
   * `@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-api-job-controller`, the sole
   * declarer of the `job` namespace. Verified against the RUNNING engine by
   * speaking its RPC protocol directly — a signed cookie plus
   * `POST /api/<method>`, the same transport `createRpcCaller` uses:
   * `job/list`, `job/follow` and `job/kill` are all served, and a production
   * `job/kill` answers a real engine error (`unknown job …`) rather than a
   * routing 404. The original call here was correct; this is the restored,
   * extended version.
   *
   * `job/list` is a stream Remote whose frames are whole-set replacements
   * (`{type:'rows', jobs: JobView[]}`), so the first frame IS the complete
   * answer — `take: 1` and cancel.
   */
  if (pathname === '/api/mobile/jobs' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    if (!sessionId) { sendJson(400, { ok: false, error: 'sessionId is required' }); return true; }
    const frame = await readStreamOnce('job/list', { request: { sessionId } }, { take: 1, timeoutMs: 5000 });
    if (!frame) {
      sendJson(200, { ok: true, code: 0, jobs: [], degraded: 'jobs-unavailable' });
      return true;
    }
    sendJson(200, { ok: true, code: 0, jobs: orderJobs(frame.jobs) });
    return true;
  }

  /* ---- one job's output, resumable by byte offset [feat 2026-10-13] ----
   *
   * `job/follow` is the real observation stream: `opened` (the job's projection
   * plus the offset the first `output` frame continues from), then coalesced
   * `output` batches, then one terminal `status` — after which the stream closes
   * normally. Status rides the same stream as output precisely so settlement can
   * never race a still-open output channel, so this route must consume it in
   * order rather than asking for the status separately.
   *
   * `from` is the caller's resume cursor: a query without it starts at the
   * oldest retained byte, and each answer returns `next` for the following poll.
   * This is a poll, not a held-open socket, because the bridge's HTTP surface is
   * request/response and the mobile app already owns one WebSocket.
   *
   * `lossy: true` means bytes were evicted from the producer's ring (or by
   * retention) between the requested offset and the returned chunks. That is
   * reported verbatim — the phone must be able to say "the beginning is gone"
   * instead of rendering a silently incomplete log.
   */
  if (pathname === '/api/mobile/jobs/follow' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    const jobId = String(deps.parsedUrl.query?.jobId || '').trim();
    if (!sessionId || !jobId) { sendJson(400, { ok: false, error: 'sessionId and jobId are required' }); return true; }
    const fromRaw = deps.parsedUrl.query?.from;
    const from = fromRaw != null && fromRaw !== '' ? Number(fromRaw) : undefined;
    if (from !== undefined && (!Number.isFinite(from) || from < 0)) {
      sendJson(400, { ok: false, error: 'from must be a non-negative number' });
      return true;
    }
    try {
      const collected = await deps.readStreamFrames(
        'job/follow',
        { request: { sessionId, jobId, ...(from === undefined ? {} : { from }) } },
        { maxFrames: 60, idleTimeoutMs: 2500, totalTimeoutMs: 12000 }
      );
      const view = summarizeJobFollow(collected);
      sendJson(200, { ok: true, code: 0, ...view });
    } catch (err) {
      // `job/not-found` is the engine's own refusal; a settled and evicted job is
      // not an error the user should see as a crash.
      const message = String(err?.message || '');
      const notFound = /job\/not-found|unknown job/i.test(message);
      sendJson(notFound ? 404 : 502, {
        ok: false,
        code: notFound ? 404 : 502,
        error: notFound ? '该后台任务已不存在或已超出保留窗口' : 'engine rpc not available'
      });
    }
    return true;
  }

  /* ---- stop a background job ----
   *
   * Real engine Remote: `job/kill(request:{ sessionId, jobId })` →
   * `{ outcome: 'requested' | 'already-finished' }`, with `job/not-found` when
   * the session's list no longer carries a killable row. There is therefore no
   * need to mediate through the Agent, and an earlier revision of this file that
   * did exactly that was reverted once the real interface was confirmed.
   *
   * `already-finished` is a 409 on purpose: the request is a no-op, not a
   * failure, and the phone should say "已经结束" rather than show an error.
   */
  if (pathname === '/api/mobile/jobs/kill' && req.method === 'POST') {
    const sessionId = String(jsonBody.sessionId || '').trim();
    const jobId = String(jsonBody.jobId || '').trim();
    if (!sessionId || !jobId) {
      sendJson(400, { ok: false, error: 'sessionId and jobId are required' });
      return true;
    }
    try {
      const result = await callDshRpc('job/kill', { args: { request: { sessionId, jobId } } });
      const outcome = result?.outcome === 'already-finished' ? 'already-finished' : 'requested';
      audit('job/kill', { sessionId, jobId, outcome });
      if (outcome === 'already-finished') {
        sendJson(409, { ok: false, code: 409, outcome, error: '该后台任务已经结束，无需停止' });
        return true;
      }
      sendJson(200, { ok: true, code: 0, outcome });
    } catch (err) {
      const message = String(err?.message || '');
      const notFound = /job\/not-found|unknown job/i.test(message);
      audit('job/kill-failed', { sessionId, jobId, notFound });
      sendJson(notFound ? 404 : 502, {
        ok: false,
        code: notFound ? 404 : 502,
        error: notFound ? '该后台任务不在本会话的可停止列表中' : 'engine rpc not available'
      });
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

  /* ---- one-tap diagnostics [feat 2026-10-12] ----
   *
   * Serial checks that never 500: every check is individually wrapped, and an
   * engine that is down only makes `engine_rpc` answer ok:false — the rest of
   * the report (bridge version, ws clients, stream state, devices, disk) is
   * gateway-local and stays meaningful. No token, no path, no engine error
   * text ever leaves this route: details pass through redactDiagnosticDetail.
   */
  if (pathname === '/api/mobile/diagnostics' && req.method === 'GET') {
    const checks = [];
    const push = (name, body) => checks.push({ name, ...body });

    // 1. bridge version (always known)
    push('bridge_version', { ok: true, value: deps.bridgeVersion ?? '' });

    // 2. engine RPC probe — one real lightweight call with its own timeout
    const rpc = await probeEngineRpc({ callDshRpc, timeoutMs: 4000 });
    push('engine_rpc', { ok: rpc.ok, detail: rpc.detail, value: `${rpc.ms}ms` });

    // 3. mobile WS clients (live count uses the same predicate the broadcast uses)
    push('ws_clients', { ok: true, value: countDeliverableClients(deps.mobileClients ?? []) });

    // 4. engine $events stream: the gateway's own subscription state
    const streamOk = deps.eventsStreamReady?.() === true;
    push('engine_events_stream', { ok: streamOk, detail: streamOk ? 'ready' : 'not connected' });

    // 5. paired devices
    push('devices', { ok: true, value: deps.deviceCount?.() ?? null });

    // 6. disk writability under dshHomeDir/storages
    const diskDir = deps.diagnosticsDir ?? path.join(deps.dshHomeDir ?? os.tmpdir(), 'storages');
    const disk = probeDiskWritable(diskDir);
    push('disk', { ok: disk.ok, detail: disk.detail });

    audit('diagnostics/run', {
      engineRpc: rpc.ok,
      eventsStream: streamOk,
      disk: disk.ok,
      wsClients: checks[2].value
    });

    sendJson(200, {
      ok: checks.every((c) => c.ok !== false),
      checks,
      generatedAt: new Date().toISOString()
    });
    return true;
  }

  /* ---- subagent control [feat 2026-10-12] ----
   *
   * Real engine RPCs verified against the installed engine's typert wire
   * definitions (@deepseek-ai/dsh-subagent): `subagents/list(parentSessionId)`
   * and `subagents/interruptByParent(childSessionId, parentSessionId,
   * mode:'continuable')`. Interrupt is continuable-mode only: one-shot
   * children are terminal by design and the engine rejects them.
   */
  if (pathname === '/api/mobile/sessions/subagents' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    if (!sessionId) { sendJson(400, { ok: false, error: 'sessionId is required' }); return true; }
    try {
      const catalog = await callDshRpc('subagents/list', { args: { parentSessionId: sessionId } });
      const view = normalizeSubagentCatalog(catalog);
      if (view === null) {
        // Engine answered but did not look like a catalog: say so honestly.
        sendJson(501, { ok: false, code: 501, error: 'engine rpc not available' });
        return true;
      }
      sendJson(200, { ok: true, code: 0, ...view });
    } catch (err) {
      sendJson(502, { ok: false, code: 502, error: 'engine rpc not available' });
    }
    return true;
  }

  if (pathname === '/api/mobile/sessions/subagents/interrupt' && req.method === 'POST') {
    const parentSessionId = String(jsonBody.parentSessionId || jsonBody.sessionId || '').trim();
    const childSessionId = String(jsonBody.childSessionId || '').trim();
    if (!parentSessionId || !childSessionId) {
      sendJson(400, { ok: false, error: 'parentSessionId and childSessionId are required' });
      return true;
    }
    try {
      const result = await callDshRpc('subagents/interruptByParent', {
        args: { childSessionId, parentSessionId, mode: 'continuable' }
      });
      audit('subagent/interrupt', { parentSessionId, childSessionId, accepted: result?.accepted === true });
      sendJson(200, { ok: true, code: 0, result });
    } catch (err) {
      audit('subagent/interrupt-failed', { parentSessionId, childSessionId });
      sendJson(502, { ok: false, code: 502, error: 'engine rpc not available' });
    }
    return true;
  }

  /* ---- Agent Team [feat 2026-10-16] ---- */
  //
  // The Web panel reads `projectionsBySession[lead].values.agentTeam`; the phone
  // has no projection subscription, so it polls this route instead.
  //
  // Two sources, RPC first: `session/projections` is authoritative for a live
  // session, while the projection cache is the only record of a finished team's
  // roster and task board — and on a cold session the RPC answers nothing at
  // all. An engine with no team support is a 501 (not an empty team), so the
  // App can tell "no such feature" from "your team is gone".
  if (pathname === '/api/mobile/sessions/team' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    if (!sessionId) { sendJson(400, { ok: false, error: 'sessionId is required' }); return true; }
    const idCheck = deps.assertSessionId ? deps.assertSessionId(sessionId) : { ok: true };
    if (!idCheck.ok) { sendJson(400, { ok: false, error: idCheck.error || 'invalid sessionId' }); return true; }

    let source = 'rpc';
    let team = normalizeAgentTeam((await readProjections(sessionId))?.agentTeam);
    if (!team && typeof deps.readProjectionRows === 'function') {
      const cached = agentTeamFromProjectionRows(deps.readProjectionRows(sessionId));
      if (cached) { team = cached; source = 'cache'; }
    }
    if (!team) {
      // Neither source produced anything. Distinguish "this engine has no team
      // projection at all" from "this session simply is not a team".
      const rows = typeof deps.readProjectionRows === 'function' ? deps.readProjectionRows(sessionId) : null;
      if (rows && !('agentTeam' in rows)) {
        sendJson(200, { ok: true, code: 0, team: null, supported: false, source });
      } else {
        sendJson(200, { ok: true, code: 0, team: { members: [], tasks: [], failure: '' }, supported: true, source });
      }
      return true;
    }
    sendJson(200, { ok: true, code: 0, team, supported: true, source, summary: summarizeAgentTeam(team) });
    return true;
  }

  /* ---- goal control [feat 2026-10-12] ----
   *
   * Real engine RPCs verified against @deepseek-ai/dsh-goal's wire
   * definitions: goals/pause, goals/resume, goals/complete — all shaped
   * `(agentId: SessionId, ref: { id, revision })`. The engine has NO
   * goal-read or goal-list RPC, so the phone must supply the ref (it gets
   * id+revision from the `goal` projection row the stats route already
   * serves). An unknown engine error is 502 with a stable string, never a
   * fabricated success.
   */
  const GOAL_ACTIONS = { pause: 'goals/pause', resume: 'goals/resume', complete: 'goals/complete' };
  if (pathname?.startsWith('/api/mobile/goals/') && req.method === 'POST') {
    const action = pathname.replace('/api/mobile/goals/', '');
    const rpcName = GOAL_ACTIONS[action];
    if (!rpcName) return false; // not ours
    const sessionId = String(jsonBody.sessionId || '').trim();
    const goalId = String(jsonBody.goalId || '').trim();
    const revision = Number(jsonBody.revision);
    if (!sessionId || !goalId || !Number.isSafeInteger(revision) || revision <= 0) {
      sendJson(400, { ok: false, error: 'sessionId, goalId and a positive revision are required' });
      return true;
    }
    try {
      const view = await callDshRpc(rpcName, { args: { agentId: sessionId, ref: { id: goalId, revision } } });
      audit(`goal/${action}`, { sessionId, goalId, revision, phase: view?.phase ?? null });
      sendJson(200, { ok: true, code: 0, view: view ?? null });
    } catch (err) {
      audit(`goal/${action}-failed`, { sessionId, goalId, revision });
      sendJson(502, { ok: false, code: 502, error: 'engine rpc not available' });
    }
    return true;
  }

  /* ---- slash commands [feat 2026-10-12] ----
   *
   * The engine HAS a real listing RPC: `commands/list(agentId)` in
   * @deepseek-ai/dsh-commands, answering `CommandDescriptor[]`
   * ({ name, description, input? }). Pass it through with no fabricated rows
   * when it fails — the App hides the "/" entry rather than showing a fake
   * menu.
   */
  if (pathname === '/api/mobile/sessions/commands' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    if (!sessionId) { sendJson(400, { ok: false, error: 'sessionId is required' }); return true; }
    try {
      const list = await callDshRpc('commands/list', { args: { agentId: sessionId } });
      const commands = (Array.isArray(list) ? list : [])
        .map((c) => (c && typeof c.name === 'string' && c.name
          ? { name: c.name, description: typeof c.description === 'string' ? c.description : '', hint: c?.input?.hint ?? null }
          : null))
        .filter(Boolean);
      sendJson(200, { ok: true, code: 0, commands });
    } catch (err) {
      // No static fallback on purpose: a stale hard-coded list would teach the
      // user slash names the engine may not accept. Empty + reason instead.
      sendJson(200, { ok: true, code: 0, commands: [], degraded: 'engine rpc not available' });
    }
    return true;
  }

  return false;
}
