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
  classifyHarnessNotice,
  coerceToolInput,
  describeDeliverableRefusal,
  describeTurnEnd,
  extractDeliverables,
  isCarriedContext,
  isFailedTurnEnd,
  readUserMessageSource,
  resolveDeliverable
} from './core.mjs';

// Re-exported for the callers and tests that used to import them from here.
export { extractDeliverables, resolveDeliverable };

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
 *
 * `extractDeliverables` / `resolveDeliverable` now live in core.mjs: this module
 * and extensions.mjs both need them, and this module already imports
 * extensions.mjs, so the shared half cannot live here without a cycle. They are
 * re-exported at the bottom of this import block so every existing importer —
 * including the unit tests — keeps working unchanged.
 * ------------------------------------------------------------------ */

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
 * 会话事件里附件的 `mediaType` 缺失时，按文件名扩展名推断的对照表。
 *
 * 实测的两种 part 形状（2026-10-17 活数据，同一条 user/message 的两个 part）：
 *   image: { type:'image', attachment:{ attachmentId:'sha256:d4ca…', mediaType:'image/jpeg',
 *                                        width:736, height:1600, bytes:229795, name:'scaled_7125.jpg' } }
 *   file : { type:'file',  attachment:{ attachmentId:'sha256:16bb…', name:'工作日报.xlsx', bytes:21769 } }
 * file part **没有** mediaType，所以这里必须兜底；只覆盖常见图片扩展名，其它一律
 * application/octet-stream —— App 靠 `mimeType.startsWith('image/')` 决定把附件渲染成
 * 缩略图还是文件行，猜错会把一个 xlsx 当图片去拉字节。
 */
const ATTACHMENT_IMAGE_MIME_BY_EXT = new Map([
  ['png', 'image/png'],
  ['jpg', 'image/jpeg'],
  ['jpeg', 'image/jpeg'],
  ['gif', 'image/gif'],
  ['webp', 'image/webp'],
  ['bmp', 'image/bmp']
]);

/** 只有有限数字才算数（尺寸 / 字节 / usage 字段同用）；其它一律 null，好让调用方省略而不是塞垃圾值。 */
function finiteNumber(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}

/**
 * 一个非 text part → App 侧 `AttachmentRef` 需要的字段
 * （见 dsh_mobile 的 `lib/models/user_question.dart` 里 `AttachmentRef.fromJson`：
 * 它读的正是 id / mimeType / width / height / bytes / filename）。
 *
 * 没有 `attachmentId` 的 part **直接返回 null**：日志里还存在老/发信形状的
 * `{ type:'image', mediaType:'image/png' }`（没有 attachment 对象），造一个 id 为空串的
 * 空壳会被 App 端的 `AttachmentRef.fromJson` 抛 FormatException 整条丢掉 —— 一样看不见，
 * 却多一层"看起来有数据"的假象。
 *
 * 字节**绝不回传**（`attachment.data` 的内联 base64 可能几十 MB，会把 MUX 打爆）：
 * 手机拿 id 走已认证的 `GET /api/mobile/attachment?id=…&sessionId=…` 按需取
 * （见 index.js 的附件读取分支，它转调引擎的 session/attachment RPC）。
 */
function toAttachmentRef(part) {
  const att = part?.attachment;
  const id = typeof att?.attachmentId === 'string' ? att.attachmentId.trim() : '';
  if (!id) return null;

  const name = typeof att.name === 'string' && att.name.length > 0 ? att.name : null;
  const declared = typeof att.mediaType === 'string' ? att.mediaType.trim() : '';
  const ext = name ? (/\.([A-Za-z0-9]+)$/.exec(name.trim())?.[1] || '').toLowerCase() : '';
  const ref = {
    id,
    mimeType: declared || ATTACHMENT_IMAGE_MIME_BY_EXT.get(ext) || 'application/octet-stream'
  };

  const width = finiteNumber(att.width);
  const height = finiteNumber(att.height);
  const bytes = finiteNumber(att.bytes);
  if (width !== null) ref.width = width;
  if (height !== null) ref.height = height;
  if (bytes !== null) ref.bytes = bytes;
  if (name) ref.filename = name;
  return ref;
}

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
 * [feat 2026-10-17] 两个字段是给手机补的，老 App 多收字段无害：
 *
 * 1) `attachments` —— 修"手机发出去的图片被吞"。此前这个循环只拼 `part.type === 'text'`
 *    的文本，**所有 image/file part 被直接丢弃**，而 Web 端读的是原始事件所以看得到。
 *    实测：用户发的截图 `sha256:d4ca…` 在会话日志里，网关返回的历史里连字段都没有，
 *    手机于是永远看不到附件。现在非 text part 归一成
 *    `[{ id, mimeType, width, height, bytes, filename }]` 挂在同一条消息上；图片与文件同一
 *    形状，App 用 `mimeType.startsWith('image/')` 分流渲染（缩略图 / 文件行）。
 *    **只有真的有附件时才加这个键**（没有就完全不加），老形状原样保留。
 *
 * 2) `tokens` —— 修"本轮用量经常显示 —"。引擎**每个 step 的 `assistant/message` 都带
 *    `usage`**（`inputTokens/outputTokens/totalTokens/cacheReadTokens`），而网关以前把这份
 *    数据整个扔掉，App 只能靠"两次 stats 读数相减"，基线没记到就永远是 —。
 *
 *    ## [fix 2026-10-17] 第二版：用量挂错消息了
 *
 *    第一版把**每一条 `user/message`** 都当成"新一轮开始"，于是引擎插在回合中间的注入
 *    消息把这一轮的用量抢走，**真人那条永远是 null**。活数据实证（2026-10-17）：
 *
 *      turn/end  1896 (turn5) → turn/start 1899 (turn6)       ← 权威回合边界
 *      user/message 1902  source.kind='user'                  真人提问 ← 应由它承载
 *      user/message 1903  source.kind='time-context'          注入
 *      user/message 1904  source.kind='dsh-mnemon'            注入
 *      assistant/message 1906..2059  data.turn=6，每条带 usage ← 本轮的用量在这里
 *      user/message 1954  source.kind='user'                  同一轮里用户追问
 *
 *    实测后果：网关返回的历史里 1902 / 1954 / 2949 这些**真人**消息 tokens 全是 null，
 *    而 1843(time-context) 拿到 10008、2932(tool-jobs) 拿到 1800 —— 注入要么被网关丢弃、
 *    要么在 App 里渲染成通知卡，那些用量就此凭空消失。
 *
 *    ### 现在的规则，以及每条的为什么
 *
 *    a. **`turn/start` 是权威回合边界**：见到它就结算上一轮、开一个新轮。**不**再用
 *       user/message 开轮（那正是挂错对象的根因）。依据：`turn/start` 的 `data.turn` 与
 *       `assistant/message` 的 `data.turn` 一致（引擎侧
 *       `dsh-agent-loop/lib/index.js:943 this.session.append("turn/start", { turn })`），
 *       且真实时序里 turn/start 排在真人消息**之前**（见上面 1899 → 1902）。
 *    b. **载体（carrier）只能是真人消息**：`readUserMessageSource(ev).human === true`。
 *       注入消息（time-context / dsh-mnemon / skill-catalog / agent-message /
 *       subagent-settled / compact-checkpoint / runtime-context / tool-jobs / schedule …）
 *       **不承载、不结算**，只属于当前这一轮。
 *    c. **一轮里可能有多条真人消息**（用户在回合进行中追问，如 1902 + 1954）→ 按**分段**
 *       给值：`tokens` 的语义是"**这条消息到下一次你说话之间**烧掉的量"。实现记
 *       `cuts = [{ msg, sumAtCut }]`，每条真人消息处记一次当时的累计和；轮结束时
 *       第 i 条 = `cuts[i+1].sumAtCut - cuts[i].sumAtCut`，最后一条 = `totalSum - cuts[last].sumAtCut`。
 *       （把整轮的量全塞给第一条会谎报单条成本；两条相邻真人消息之间没有任何 usage 时
 *       分段值可以是 0 —— 那是算出来的事实，不是"未知写 0"。）
 *    d. **只在轮完整且本轮 usage 完整时才给值**，否则 `tokens: null`（**绝不写 0**）：
 *       - 必须见过 `turn/end`（回合还在跑 → 中途和会被读成"这轮就花了这么多"）；
 *       - 必须见过至少一条带 usage 的 assistant（否则无从谈起）；
 *       - **必须 `turn/start` 也在这段记录里**（`openedInWindow`）：分页从轮中间切进来时
 *         累加和是残缺的 —— 比如 1902 在上一页、只有 1954 在这一页，前者的量根本算不进来，
 *         那时宁可 null 也不错报。这一条**单独有测试**。
 *         注意这条规则也意味着：万一某个引擎版本把真人消息排在它自己的 `turn/start`
 *         **之前**（实测时序不是这样：1899 在 1902 之前），那条消息同样会保持 null ——
 *         这是刻意的。宁可空着，也不"猜"它属于哪个轮（把上一条/下一条的量塞给它才是谎）。
 *    e. 没有任何真人载体的轮（例如纯 `[SCHEDULE REMINDER BATCH]` 唤醒的轮）→ 用量丢弃，
 *       不给值，也**不挪**给上一条或下一条。
 *
 *    为什么只加 `inputTokens + outputTokens`：`inputTokens` 是"未缓存输入"，
 *    `totalTokens` 是**跨 step 累计**值（实测一条 assistant 是 input 282 / output 312 /
 *    total 36178 / cacheRead 35584）——逐 step 累加 totalTokens 会把数字吹大一个量级，
 *    还会把前面 step 的量重复计很多遍。
 *
 *    边界：窗口内缺 usage 的 assistant（工具步）只是 0 贡献，**不会**把整轮判成 null；
 *    一条 usage 都没有的轮（含被 carried-context 过滤掉、没有产出消息的轮）是 null。
 *    老日志里**没有 `source` 标记**的 user/message 不算真人（`readUserMessageSource` 的
 *    human 是硬闸）→ 那一轮也不给值：宁可空着也不错填。被 carried-context 过滤掉的真人
 *    消息不产生 cuts，它那一段的量落到上一条载体的分段里。
 *
 * @param records - `session/page` records (`{ event }` entries), ascending.
 * @returns `{ messages }` — ascending, same fields as getSessionHistory plus seq
 *   (and, for user messages, `tokens` always; `attachments` only when present).
 */
export function convertSessionRecordsToMessages(records, opts = {}) {
  const messages = [];
  const auditDropped = typeof opts.auditDropped === 'function' ? opts.auditDropped : null;
  let currentAssistantMsg = null;

  // 逐轮用量累加器（见上面第 2 条）。`cuts[i].msg` 是本轮第 i 条**真人**消息产出的消息对象；
  // 一条真人消息都没有的轮 cuts 为空，这一轮的用量就地丢弃（不挪给别人）。
  let currentTurn = null;
  /**
   * 开一轮新的累加器。
   * @param openedInWindow - 这一轮的 `turn/start` 是否落在本段记录里。分页切在轮中间时为 false，
   *   此时累加和是残缺的，结算时会被挡掉（见规则 d）。
   */
  const openTurn = (openedInWindow) => {
    currentTurn = { openedInWindow, cuts: [], sum: 0, sawUsage: false, ended: false };
    return currentTurn;
  };
  const settleTurn = () => {
    if (!currentTurn) return;
    const turn = currentTurn;
    currentTurn = null;
    // 规则 d：三个条件缺一不可，否则所有载体保持 `tokens: null`（**绝不写 0**，也不写中途和）。
    if (!turn.ended || !turn.sawUsage || !turn.openedInWindow) return;
    for (let i = 0; i < turn.cuts.length; i += 1) {
      // 规则 c：这条消息 → 下一条真人消息之间烧掉的量；最后一条吃到轮尾。
      const end = i + 1 < turn.cuts.length ? turn.cuts[i + 1].sumAtCut : turn.sum;
      turn.cuts[i].msg.tokens = end - turn.cuts[i].sumAtCut;
    }
  };
  /**
   * 记一条真人载体（规则 b/c）。
   *
   * 没有开着的轮（分页切在轮中间，`turn/start` 在上一页）时也建一个 `openedInWindow: false`
   * 的容器：这样"这条消息是载体、但本轮数据不全"有唯一表示，而不是靠"没有容器"隐式表达；
   * 结算时被 openedInWindow 挡掉，值仍是 null（宁可 null 也不错报）。
   */
  const noteCarrier = (message) => {
    const turn = currentTurn ?? openTurn(false);
    turn.cuts.push({ msg: message, sumAtCut: turn.sum });
  };

  for (const record of Array.isArray(records) ? records : []) {
    const ev = record?.event;
    if (!ev) continue;

    if (ev.type === 'user/message') {
      // [fix 2026-10-17] 这里**不再**开轮/结算。注入消息也是 user/message，它们以前会把
      // 这一轮抢走、让真人那条拿到 null（见函数头部的活数据实证）。现在注入消息只是
      // "属于当前这一轮"的普通事件：不承载、不结算。
      currentAssistantMsg = null;
      const human = readUserMessageSource(ev).human;
      const attachments = [];
      let text = '';
      if (Array.isArray(ev.data?.content)) {
        for (const part of ev.data.content) {
          if (part?.type === 'text') {
            if (part.text) text += part.text;
            continue;
          }
          // 非 text part：图片/文件/将来别的种类都走同一条归一（没有 attachmentId 的跳过）。
          const ref = toAttachmentRef(part);
          if (ref) attachments.push(ref);
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

      if (text.trim() || attachments.length > 0) {
        // [feat 2026-10-17] 注入通知带标记。role 仍然是 'user'（老 App 行为不变），
        // 新 App 见到 noticeKind 就渲染成通知卡而不是"你说的话"。
        // [feat 2026-10-17] 只有附件、没有文字的消息**也要产出**：截图配一句话是常态，
        // 但"只发一张图"以前整条消失（text.trim() 为空 → 连宿主消息都不建），附件于是
        // 永远没有挂载点。content 允许为空串，App 靠 attachments 渲染附件气泡。
        const notice = classifyHarnessNotice(text, ev);
        const message = {
          id: `hist_${typeof ev.seq === 'number' ? ev.seq : messages.length}`,
          role: 'user',
          content: text.trim(),
          time: ev.time || Date.now(),
          seq: typeof ev.seq === 'number' ? ev.seq : null,
          // 逐轮用量先占位为 null：**只有真人消息**是载体，轮结束时由 settleTurn 按分段写值；
          // 注入消息永远是 null（新 App 靠这个字段区分"未知"与"老网关没有这个字段"）。
          tokens: null,
          ...(attachments.length > 0 ? { attachments } : {}),
          ...(notice
            ? {
                noticeKind: notice.kind,
                noticeVariant: notice.variant,
                noticeChildId: notice.childId,
                noticeBody: notice.body
              }
            : {})
        };
        messages.push(message);
        if (human) noteCarrier(message);
      } else if (auditDropped && typeof ev.seq === 'number') {
        // [fix 2026-10-14] 纯附件/空文本用户消息以前是静默消失；现在留痕
        //（是否生成占位消息由 App 端显示层决定，网关至少不能无声吞掉）。
        // [feat 2026-10-17] "纯附件"已不再走这里 —— 带 attachmentId 的 part 会产出消息；
        // 能落到这一支的是真的什么都没有（或只有没有 attachmentId 的老形状 part）。
        auditDropped({ seq: ev.seq, why: 'empty-user-text', length: 0 });
      }
    } else if (ev.type === 'turn/start') {
      // [fix 2026-10-17] 权威回合边界（规则 a）：先结算上一轮，再开新的一轮。
      // 它本身不是聊天消息，不产出任何 message。（引擎侧形状 `{ turn }`。）
      settleTurn();
      openTurn(true);
    } else if (ev.type === 'assistant/message') {
      // [feat 2026-10-17] 引擎每个 step 的 assistant/message 都带 usage，而它以前被整个
      // 扔掉（手机只能靠"两次 stats 相减"，基线没记到就永远显示 —）。这里把**属于当前
      // 这一轮**的量累加进 currentTurn。只加 inputTokens + outputTokens：inputTokens 是
      // 未缓存输入，totalTokens 是跨 step 的累计值（实测每条 assistant 都重复带着前面的
      // 总量），加它会把整轮吹大一个量级。缺 usage / 字段不是数字 → 0 贡献，**不**把整轮
      // 判成 null（工具步没有 usage 是常态）。currentTurn 为 null（窗口里还没有 turn/start，
      // 分页切在轮中间）时这轮没有承载容器，直接不计。
      if (currentTurn) {
        const usage = ev.data?.usage;
        if (usage && typeof usage === 'object') {
          currentTurn.sawUsage = true;
          const input = finiteNumber(usage.inputTokens) ?? 0;
          const output = finiteNumber(usage.outputTokens) ?? 0;
          currentTurn.sum += input + output;
        }
      }
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
    } else if (ev.type === 'turn/end') {
      // [fix 2026-10-17] 轮结束（`data.reason.kind` 是权威的结束信号）。三个条件里的
      // "见过 turn/end" 就在这里成立；同时**在这里结算**而不是等下一轮的 turn/start：
      // 轮闭合之后才到达的真人消息属于下一轮，如果还把它挂到一个已结束的轮上，只会算出一个
      // 0（那是另一种谎）。它本身不是聊天消息，不产出任何 message。
      if (currentTurn) {
        currentTurn.ended = true;
        settleTurn();
      }
    }
    // Every other event type: not a chat message.
  }
  // 窗口在轮中间就结束了（有 turn/start 无 turn/end）：这里再结算一次 —— `ended` 不成立，
  // settleTurn 会保持所有载体为 null。分页切在轮中间时同理（`openedInWindow` 不成立）。
  settleTurn();
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
 * `sessionStats` 投影里放行的字段 —— **只**这 8 个数字，一个都不多。
 *
 * 名单是照着电脑端抄的：`dsh-client-ui-chat` 的状态条（`StatsPills`，见
 * `lib/client.js:7135`）读 `useProjection('sessionStats')`，而它的兜底函数
 * `deriveStats`（`lib/client.js:6923`）明确写着 "Its field names deliberately mirror
 * the projection's so the two swap wholesale"，返回的正是这 8 个键。手机端状态行要显示的
 * 「6 轮 351 步 · 210 tok/s」就是 `turns` / `steps` / `decodeTokens`÷(`decodeMs`/1000)。
 *
 * 为什么不整包转发：投影是 `.strict()` 的 8 字段对象（引擎
 * `dsh-session-stats/lib/types/projection.js:27`），多带一个键只会让引擎将来加字段时
 * 变成客户端的解析风险；手机端要的也只有一个状态行。
 */
export const SESSION_STATS_FIELDS = ['turns', 'steps', 'llmMs', 'toolMs', 'ttftMs', 'ttftSteps', 'decodeMs', 'decodeTokens'];

/**
 * 把 `sessionStats` 投影（或其缓存行）收敛成手机端状态行要的 8 个数字。
 *
 * 单位（照引擎定义）：`llmMs` / `toolMs` / `ttftMs` / `decodeMs` 都是**毫秒**墙钟时长，
 * `decodeTokens` 是**解码出来的 completion token 数**（`outputTokens` 之和）。所以
 * "tok/s" 的算法是 `decodeTokens / (decodeMs / 1000)` —— 电脑端状态条就是这么算的。
 * `decodeMs` 为 0 时（会话没有成功的解码步）那个商是 Infinity/NaN：**这里不特殊处理**，
 * 电脑端是 `stats.decodeMs > 0 ? … : null`（`lib/client.js:7139`），手机端照同样规则显示
 * `—` 即可。网关的职责只是如实给出两个数字，不替客户端编一个"没有"。
 *
 * 边界（每条都有测试）：
 *   - 投影整体缺失（老引擎 / 冷会话且缓存里没这一行）→ `null`（**不是**全 0 对象，
 *     手机端据此显示 `—`）；
 *   - 单个字段缺失 / 不是数字 / 是负的 → 该字段 `null`（时长与计数不可能为负，负数是垃圾）；
 *   - **`steps: 0` / `turns: 0` 是合法事实**（空会话）→ 照实传 0，由 App 决定怎么显示；
 *     只有"字段缺失或非数字"才算没有 —— 这里刻意不做 `> 0` 的过滤；
 *   - 8 个字段一个都读不出来时整体给 `null`（有对象但没内容，和"读不到"是同一种事实）。
 *
 * @param value - `values.sessionStats`（live RPC）或 `rows.sessionStats.val`（缓存）。
 * @returns 8 字段对象，或 null。
 */
export function summarizeSessionStats(value) {
  if (!value || typeof value !== 'object') return null;
  const out = {};
  let usable = false;
  for (const field of SESSION_STATS_FIELDS) {
    const v = value[field];
    if (typeof v === 'number' && Number.isFinite(v) && v >= 0) {
      out[field] = v;
      usable = true;
    } else {
      out[field] = null;
    }
  }
  return usable ? out : null;
}

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

  // [feat 2026-10-17] 电脑端状态条那行「6 轮 351 步 · 210 tok/s」读的是引擎的 `sessionStats`
  // 投影，网关以前没给，手机端于是拿不到轮/步/速度。两级读法照抄同目录 agentteam.mjs
  // 已经验证过的那套（这也是 lib/index.js 的 readProjections 的行为）：
  //   ① `session/projections` RPC —— live 会话的权威值。Web 端看到的形状是
  //      `projectionsBySession[<sessionId>].values.<投影名>`；这个 RPC 只问一个会话，所以答案
  //      是 `{ values: { sessionStats } }`，而 readProjections() 已经把 `values` 剥出来了
  //      （lib/index.js:468-478 → `value?.values ?? null`），因此这里就是 `values.sessionStats`；
  //   ② 会话不在内存里（冷会话，绝大多数情况）时回落读投影缓存文件里的
  //      `record.rows.sessionStats.val`（rows 由 deps.readProjectionRows 给出）。
  // 两边形状不同：RPC 是纯值，缓存行是 `@{ver, seq, val}` 标记 → 走 decodeCachedRow。
  const statsLive = values?.sessionStats;
  const statsCached = decodeCachedRow(rows?.sessionStats);
  const sessionStats = summarizeSessionStats(
    statsLive && typeof statsLive === 'object'
      ? statsLive
      : (statsCached && typeof statsCached === 'object' ? statsCached : null)
  );

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
    })(),
    // [feat 2026-10-17] 新增子对象，不改上面任何一个既有字段（App 已在用）。
    // 读不到就是 null（**不是**编 0），手机端据此显示 —。
    sessionStats
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
    case 'alert':
      // 告警引擎已按严重级筛过：只有 critical 才会走到这里（v1.35 / 3.3）。
      return {
        title: detail.title || '网关告警',
        body: detail.summary || '需要你查看',
        priority: 5,
        tags: ['rotating_light'],
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
 * 这个 RPC 失败是"通道/鉴权没通"，还是"引擎有应答，只是它不认这个请求"？
 *
 * [fix 2026-10-23] 实测踩到：密钥轮换后网关 401，`engine_rpc` 报
 * `Failed to parse RPC response: unauthorized`（真的 down，判断正确）；修好之后
 * 探针用了一个不存在的假会话号，引擎回答 `session "diagnostics-probe" not found`
 * —— 这**证明通道是通的**，却被旧实现判成 FAIL。诊断页最忌讳的就是把健康的组件
 * 标红：用户会去修一个没坏的东西。
 *
 * 所以：传输/鉴权类错误才算 down，其余（域错误、参数错、找不到会话）都算"通"。
 */
export function isTransportFailure(message) {
  const text = String(message || '');
  return /unauthorized|\b401\b|\b403\b|ECONNREFUSED|ECONNRESET|EHOSTUNREACH|ENOTFOUND|EAI_AGAIN|socket hang up|Failed to parse RPC response|timed out|timeout/i
    .test(text);
}

/**
 * Probe the engine's live RPC surface with the cheapest real call.
 *
 * 用 `session/modelCatalog` 而不是早先的 `session/page`：后者必须编一个假会话号
 * （`diagnostics-probe`），而引擎对不存在的会话会回错误 —— 于是"通道通了"和
 * "通道断了"在结果上长得一样。modelCatalog 不需要任何 id，是真正的无副作用探针。
 * 万一它也被拒绝（老引擎没有这个 RPC），只要错误不是传输/鉴权类，仍然算通。
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
    await withTimeout(callDshRpc('session/modelCatalog', { args: {} }), timeoutMs);
    return { ok: true, detail: 'ok', ms: Date.now() - started };
  } catch (err) {
    const message = String(err?.message || 'unreachable');
    if (!isTransportFailure(message)) {
      // 引擎有应答（哪怕是个错）：通道本身是好的，别把健康的组件标红。
      const short = redactDiagnosticDetail(message).slice(0, 60);
      return { ok: true, detail: `ok（引擎有应答：${short}）`, ms: Date.now() - started };
    }
    return { ok: false, detail: redactDiagnosticDetail(message), ms: Date.now() - started };
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
  ['GET', '/api/mobile/sessions/commands'],
  // [feat 2026-10-21] skill catalog (engine RPC: skills/list) —— web 的 `/` 菜单
  // 是「命令 + 技能」两路合并，手机端此前只接了命令那一路。
  ['GET', '/api/mobile/sessions/skills']
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
    const presented = extractDeliverables(records, cwd);
    const row = resolveDeliverable(presented, wanted);
    if (!row) {
      // Exact membership in the presented set, never a string filter. The reason
      // is reported so "I can't open my file" stops looking like a permission
      // problem when it is really an unresolvable relative path.
      const refusal = describeDeliverableRefusal({ presented, cwd });
      sendJson(refusal.status, {
        ok: false,
        code: refusal.status,
        reason: refusal.code,
        error: refusal.error,
        hint: refusal.hint,
        presentedCount: refusal.presentedCount
      });
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

  // [feat 2026-10-21] skill 目录（引擎 RPC：skills/list）。
  //
  // 为什么需要这条：web 端的 `/` 菜单是**两路合并**的结果 —— 命令来自
  // `commands/list`，技能来自 `skills/list`（见 `@deepseek-ai/dsh-client-ui-skill`
  // 的 fetchCatalog：`skills.list({ sessionId })`）。手机端此前只接了命令那一路，
  // 于是打 `/` 只能看到引擎内置命令，ponytail-* / presentations 这类 skill 一个
  // 都不出现（真机反馈）。
  //
  // 只挑手机菜单要用的字段：引擎的 SkillSummary 还带 invocation 策略、provider、
  // resourceBase 等内部信息，没必要下发。
  if (pathname === '/api/mobile/sessions/skills' && req.method === 'GET') {
    const sessionId = String(deps.parsedUrl.query?.sessionId || '').trim();
    if (!sessionId) { sendJson(400, { ok: false, error: 'sessionId is required' }); return true; }
    try {
      // ⚠️ 入参形状与 commands/list **不一样**，别照抄：
      //   commands/list → 参数 agent，wire: 'agentId'，source: lookup
      //                   ⇒ payload = { args: { agentId } }
      //   skills/list   → 参数 request，wire: 'request'，source: json
      //                   ⇒ payload = { args: { request: { sessionId } } }
      // 少包一层 request 时引擎拿到 undefined 直接抛错，路由只会回空表 ——
      // 真机表现就是打 `/` 只有「当前工作区没有可用技能」（2026-10-21 踩过）。
      const raw = await callDshRpc('skills/list', { args: { request: { sessionId } } });
      // 引擎可能回 { skills: [...] }、{ value: { skills: [...] } } 或直接数组，
      // 三种都吃 —— 这一层不该把引擎的包装形态变成客户端的硬依赖。
      const list = Array.isArray(raw) ? raw
        : Array.isArray(raw?.skills) ? raw.skills
          : Array.isArray(raw?.value?.skills) ? raw.value.skills
            : [];
      const skills = list.map((s) => {
        if (!s || typeof s.name !== 'string' || !s.name) return null;
        const description = typeof s.description === 'string' && s.description
          ? s.description
          : (typeof s.whenToUse === 'string' ? s.whenToUse : '');
        return {
          name: s.name,
          description,
          source: typeof s.source === 'string' ? s.source : ''
        };
      }).filter(Boolean);
      sendJson(200, { ok: true, code: 0, skills });
    } catch (err) {
      // 与 commands 一致：不给静态兜底。硬编码的 skill 名字会教用户输引擎不认的
      // 命令；空列表 + 原因，客户端据此显示"没有可用技能"。
      //
      // [fix 2026-10-21] 失败原因**必须进日志**：上一次入参少包了一层 request，
      // 路由静默回空表，只能靠手机上一句"没有可用技能"反推，而日志里什么都没有。
      // 这条 warn 是那次排查空缺的直接修复 —— 引擎侧的错误文本只留在宿主日志，
      // 不下发给客户端（诊断接口的既有纪律：不把原始引擎错误递给手机）。
      deps.logger?.warn?.(`[dsh-mobile-bridge] skills/list failed: ${err?.message || err}`);
      sendJson(200, { ok: true, code: 0, skills: [], degraded: 'engine rpc not available' });
    }
    return true;
  }

  return false;
}
