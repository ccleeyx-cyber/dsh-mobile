/**
 * Session title lookup across every place DSH persists a title.
 *
 * ## Why this module exists
 *
 * `getWorkspacesData()` reads a session's title out of its projection-cache
 * record (`rows.title.val`). When that file is not found it falls back to
 * `sessionId`, which is what makes the phone show `session-<uuid>` rows.
 * Measured on this install (2026-10-15, `GET /api/mobile/workspaces
 * ?archived=include` → 212 sessions): 96 resolved a title from the cache and
 * **116 fell back to the session id**, even though every one of them carries a
 * real `session/title` event in its event log.
 *
 * Those 116 split cleanly by *where* the title lives:
 *
 *   * 87 — a projection-cache file that is no longer under
 *     `storages/session_projcache/sessions/` but under the archive manager's
 *     domain `storages/session_projcache_archive_manager_v2/sessions/`, whose
 *     filename is `session_<base64url(sha256(sessionId))>.json` rather than
 *     `<sessionId>.json`.
 *   * 29 — no projection-cache record at all (main dir or archive dir); only
 *     the zstd event log `~/.dsh/sessions/<projectKey>/<sessionId>/session.v*.jsonl.zstd`,
 *     where the engine's `dsh-session-title-first-prompt-llm` plugin appends
 *     `{"type":"session/title","data":{"title":…}}`.
 *
 * So the title was never lost — the bridge only knew about one of three
 * storage locations. This module reads all three, cheapest first, and memoizes
 * the expensive ones because the phone re-polls the workspace list every 3
 * seconds inside the dsh web process.
 */

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';

/** Same charset gate as `assertSessionId` in core.mjs — these names hit the filesystem. */
const SESSION_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

/** A single event log is capped so one pathological session cannot stall a poll. */
const MAX_LOG_BYTES = 64 * 1024 * 1024;

/** Output cap for the streaming decompressor, since the frame header may omit the size. */
const MAX_DECOMPRESSED_BYTES = 192 * 1024 * 1024;

/** Directory listing refresh interval for the `sessions/<projectKey>/<id>` index. */
const PROJECT_INDEX_TTL_MS = 30_000;

/**
 * `user/message` origins that are an actual human turn. Anything else in the log
 * is a harness-injected notice and must not become the session's first prompt.
 */
const HUMAN_ORIGINS = new Set(['user', 'human', 'user-input', 'user_input']);

const MAIN_PROJCACHE_DIR = ['storages', 'session_projcache', 'sessions'];
const ARCHIVE_PROJCACHE_DIRS = [
  ['storages', 'session_projcache_archive_manager_v2', 'sessions']
];

/**
 * Normalize a session id and reject anything that cannot be a path segment.
 *
 * @param {unknown} sessionId
 * @returns {{ id: string, clean: string, spellings: string[] } | null}
 *   `spellings` are the id forms the on-disk layout may use, `session-` prefix
 *   first because that is what the engine writes today.
 */
export function sessionIdSpellings(sessionId) {
  if (typeof sessionId !== 'string') return null;
  const id = sessionId.trim();
  if (!id) return null;
  const clean = id.replace(/^session-/, '');
  if (!SESSION_ID_RE.test(clean)) return null;
  const spellings = id.startsWith('session-') ? [id, clean] : [id, `session-${id}`];
  return { id, clean, spellings };
}

/**
 * Filename the archive manager's projcache domain uses for one session id.
 *
 * Verified against the live install: `session_<base64url(sha256(sessionId))>.json`,
 * where `sessionId` is hashed exactly as the workspace registry spells it
 * (prefixed for sessions created since the `session-` prefix landed, bare for
 * older ones) — hence both spellings are offered.
 *
 * @param {string} spelling - one entry from `sessionIdSpellings().spellings`.
 * @returns {string} e.g. `session_Y2I3NzYwYTAt…json`
 */
export function archiveProjCacheFileName(spelling) {
  const digest = crypto.createHash('sha256').update(spelling, 'utf8').digest();
  const key = digest.toString('base64').replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '');
  return `session_${key}.json`;
}

/**
 * Every projection-cache path worth trying for one session, cheapest first.
 *
 * The main domain keeps its historical two spellings (bare and prefixed); the
 * archive domain is keyed by hash, so it gets one candidate per spelling.
 *
 * @param {string} home - DSH home directory.
 * @param {string} sessionId
 * @returns {string[]} absolute paths; empty when the id is unusable.
 */
export function projectionCacheCandidates(home, sessionId) {
  const sp = sessionIdSpellings(sessionId);
  if (!sp) return [];
  const out = [];
  for (const name of sp.spellings) {
    out.push(path.join(home, ...MAIN_PROJCACHE_DIR, `${name}.json`));
  }
  for (const dir of ARCHIVE_PROJCACHE_DIRS) {
    for (const spelling of sp.spellings) {
      out.push(path.join(home, ...dir, archiveProjCacheFileName(spelling)));
    }
  }
  return out;
}

const ZSTD_MAGIC = 0xfd2fb528; // little-endian read of the bytes 28 B5 2F FD

/**
 * Locate complete zstd frames without decompressing their blocks.
 *
 * Ported from the engine's own `scanZstdFrames` in
 * `dsh-session-persistence-jsonl/lib/index.js`, which is the authority on this
 * layout: a session log is a **concatenation of independently decodable
 * frames** (one per durable append), not one stream.
 *
 * @param {Buffer} buffer - the whole log file.
 * @returns {{ frames: Array<{start: number, end: number}>, tornStart: number }}
 */
export function scanZstdFrames(buffer) {
  const frames = [];
  let offset = 0;
  while (offset < buffer.length) {
    const start = offset;
    if (buffer.length - offset < 4) return { frames, tornStart: start };
    if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) {
      throw new Error(`corrupt Zstandard session log: invalid frame magic at byte ${offset}`);
    }
    offset += 4;
    if (offset === buffer.length) return { frames, tornStart: start };
    const descriptor = buffer.readUInt8(offset);
    offset += 1;
    if ((descriptor & 24) !== 0) {
      throw new Error(`corrupt Zstandard session log: reserved frame-header bit at byte ${offset - 1}`);
    }
    const contentSizeFlag = descriptor >>> 6;
    const singleSegment = (descriptor & 32) !== 0;
    const checksum = (descriptor & 4) !== 0;
    const dictionaryFlag = descriptor & 3;
    const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag;
    const contentSizeBytes = contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : 1 << contentSizeFlag;
    const remainingHeaderBytes = (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes;
    if (buffer.length - offset < remainingHeaderBytes) return { frames, tornStart: start };
    offset += remainingHeaderBytes;
    for (;;) {
      if (buffer.length - offset < 3) return { frames, tornStart: start };
      const blockHeader = buffer.readUIntLE(offset, 3);
      offset += 3;
      const lastBlock = (blockHeader & 1) !== 0;
      const blockType = (blockHeader >>> 1) & 3;
      const blockSize = blockHeader >>> 3;
      if (blockType === 3) throw new Error(`corrupt Zstandard session log: reserved block type at byte ${offset - 3}`);
      const payloadBytes = blockType === 1 ? 1 : blockSize;
      if (buffer.length - offset < payloadBytes) return { frames, tornStart: start };
      offset += payloadBytes;
      if (lastBlock) break;
    }
    if (checksum) {
      if (buffer.length - offset < 4) return { frames, tornStart: start };
      offset += 4;
    }
    frames.push({ start, end: offset });
  }
  return { frames };
}

/**
 * Decompress one whole multi-frame zstd session log into text.
 *
 * ⚠️ A session log is NOT one zstd stream. It is a concatenation of
 * independently decodable frames — one per durable append — and neither
 * `zstdDecompressSync()` nor `createZstdDecompress()` will cross a frame
 * boundary: both stop after frame #1. Measured on
 * `~/.dsh/sessions/--E-workspace-~4E2A~4EBA--/session-ee96adea-…/session.v4.jsonl.zstd`
 * (566 920 compressed bytes, 558 frame magics, 2026-10-15): Node's streaming
 * API yields 201 bytes, `zstdDecompressSync` yields 201 bytes, and the
 * reference `zstandard` library's `stream_reader` yields 1 990 205 bytes — and
 * the title event only exists past byte 201. So every frame is walked and
 * decoded on its own, exactly as the engine's own reader does.
 *
 * A torn trailing frame (the writer crashed mid-append) is skipped rather than
 * thrown on: a partially written tail costs the newest events, never the title
 * folded from earlier frames.
 *
 * @param {string} file - path to a `.jsonl.zstd` file.
 * @returns {Promise<string>} decompressed UTF-8 text.
 */
export async function decompressEventLog(file) {
  const raw = fs.readFileSync(file);
  let frames;
  try {
    frames = scanZstdFrames(raw).frames;
  } catch {
    // Unparseable header layout: fall back to whatever the single-frame decoder
    // manages, which is right for any single-frame log.
    if (typeof zlib.zstdDecompressSync !== 'function') throw new Error('zstd unavailable');
    return zlib.zstdDecompressSync(raw).toString('utf8');
  }
  if (frames.length === 0) throw new Error('no complete zstd frame in session log');
  if (frames.length === 1) {
    if (typeof zlib.zstdDecompressSync !== 'function') throw new Error('zstd unavailable');
    return zlib.zstdDecompressSync(raw.subarray(frames[0].start, frames[0].end)).toString('utf8');
  }
  const parts = [];
  let total = 0;
  for (const frame of frames) {
    let plain;
    try {
      plain = zlib.zstdDecompressSync(raw.subarray(frame.start, frame.end));
    } catch {
      continue; // one bad frame must not discard the other 500+
    }
    total += plain.length;
    if (total > MAX_DECOMPRESSED_BYTES) {
      throw new Error(`decompressed event log exceeds ${MAX_DECOMPRESSED_BYTES} bytes`);
    }
    parts.push(plain);
  }
  return Buffer.concat(parts, total).toString('utf8');
}

/** Read the newest event-log file in one session directory, or null. */
function newestLogFile(dir) {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch {
    return null;
  }
  let best = null;
  for (const name of names) {
    if (!name.endsWith('.jsonl.zstd')) continue;
    const full = path.join(dir, name);
    let st;
    try {
      st = fs.statSync(full);
    } catch {
      continue;
    }
    if (!best || st.mtimeMs > best.mtimeMs) best = { path: full, mtimeMs: st.mtimeMs, size: st.size };
  }
  return best;
}

/**
 * Fold the title (and the first human prompt) out of one decompressed event log.
 *
 * Exported for tests: the log is the only title source for sessions that have
 * no projection-cache record, so the fold must be verifiable on its own.
 *
 * ⚠️ Only a **real** user message counts as the first prompt. The log carries
 * `user/message` events for harness-injected content too — a `source.kind` of
 * `plugin` (user-approval notices), `agent-instructions`, or a system-prompt
 * snapshot — and any of those used to win the race and then show up under the
 * session name in the phone's list. Only `source.kind === 'user'` (or an
 * explicit human origin string) is accepted.
 *
 * @param {string} text - decompressed JSONL.
 * @returns {{ title: string, firstPrompt: string }}
 */
export function foldTitleFromEventLogText(text) {
  let title = '';
  let firstPrompt = '';
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let event;
    try {
      event = JSON.parse(trimmed);
    } catch {
      continue; // a torn tail line is not worth failing the whole fold over
    }
    if (!event || typeof event !== 'object') continue;
    const data = event.data;
    if (!data || typeof data !== 'object') continue;
    if (event.type === 'session/title' && typeof data.title === 'string' && data.title.trim()) {
      // The engine appends a fallback title first and a provider title later;
      // the last one wins, matching `foldSessionTitle` in dsh-session-query.
      title = data.title.trim();
      continue;
    }
    if (firstPrompt || event.type !== 'user/message') continue;
    if (!isHumanTurn(data)) continue;
    const content = Array.isArray(data.content) ? data.content
      : Array.isArray(data.message?.content) ? data.message.content
      : [];
    const part = content.find((p) => p && p.type === 'text' && typeof p.text === 'string');
    if (part) firstPrompt = part.text.trim();
  }
  return { title, firstPrompt };
}

/**
 * Is this `user/message` a human turn rather than injected harness content?
 *
 * `source` is an object in the current format (`{ kind: 'user' }` versus
 * `{ kind: 'plugin', plugin: 'user-approval' }`), but a bare string origin is
 * accepted too so a future/legacy shape degrades to a name check.
 *
 * @param {Record<string, unknown>} data - the event's `data` payload.
 * @returns {boolean}
 */
export function isHumanTurn(data) {
  const source = data.source ?? data.origin;
  if (typeof source === 'string') return HUMAN_ORIGINS.has(source);
  if (source && typeof source === 'object') {
    const kind = (source).kind;
    return typeof kind === 'string' && HUMAN_ORIGINS.has(kind);
  }
  return false;
}

/**
 * Title reader with three levels of memoization.
 *
 * - The `sessions/<projectKey>/<sessionId>` index is rebuilt at most every
 *   {@link PROJECT_INDEX_TTL_MS}, because a poll walks ~200 sessions.
 * - Each decompressed log is cached by path + mtimeMs + size, so an unchanged
 *   session costs one `statSync` on later polls.
 * - Each session id is cached separately by id + mtimeMs + size, so the hot
 *   sync read is one `statSync` even though the folder walk is gone.
 *
 * ## Why `peek` is synchronous
 *
 * `getWorkspacesData()` is synchronous by contract: it feeds
 * `createPathSanitizer({ getRegisteredWorkspaces })`, which core calls from a
 * synchronous request handler. Making the title fold `async` would force the
 * whole workspace list — and the file-path sanitizer with it — into a promise.
 * Instead the reader decompresses in the background and hands back a
 * `readdirSync`+`statSync` answer immediately:
 *
 *   - `peek()` — synchronous, only the cheap filesystem metadata. Returns a
 *     cached title when one is already known, else `{ pending: true }`.
 *   - `warm()` — kicks off (or awaits) the decompression. The next `peek()`
 *     after it settles sees the title.
 *
 * So the very first poll after a restart may still show the id for a handful of
 * sessions and the next 3-second poll shows the real title. There is no way to
 * answer a sync request from a 3 MB decompress without paying that cost inline,
 * and paying it inline is exactly what the mtime memo exists to avoid.
 *
 * @param {object} [opts]
 * @param {(msg: string, err?: unknown) => void} [opts.log] - warn sink.
 * @returns {{
 *   peek: (home: string, sessionId: string) => { title: string, firstPrompt: string } | { pending: true } | null,
 *   warm: (home: string, sessionId: string) => void,
 *   read: (home: string, sessionId: string) => Promise<{ title: string, firstPrompt: string } | null>,
 *   invalidate: (sessionId?: string) => void
 * }}
 */
export function createEventLogTitleReader({ log } = {}) {
  const logCache = new Map(); // absPath -> { mtimeMs, size, value }
  const idCache = new Map(); // sessionId -> { mtimeMs, size, value }
  let projectDirs = null;
  let projectDirsAt = 0;

  function warn(msg, err) {
    if (typeof log === 'function') log(msg, err);
  }

  function getProjectDirs(home) {
    const now = Date.now();
    if (projectDirs && now - projectDirsAt < PROJECT_INDEX_TTL_MS) return projectDirs;
    const root = path.join(home, 'sessions');
    try {
      projectDirs = fs
        .readdirSync(root, { withFileTypes: true })
        .filter((e) => e.isDirectory())
        .map((e) => e.name);
    } catch {
      projectDirs = [];
    }
    projectDirsAt = now;
    return projectDirs;
  }

  function locateLogFile(home, sp) {
    for (const project of getProjectDirs(home)) {
      for (const spelling of sp.spellings) {
        const file = newestLogFile(path.join(home, 'sessions', project, spelling));
        if (file) return file;
      }
    }
    return null;
  }

  function decompressInBackground(file) {
    const hit = logCache.get(file.path);
    if (hit && hit.mtimeMs === file.mtimeMs && hit.size === file.size) return hit.promise;
    let promise;
    if (file.size > MAX_LOG_BYTES) {
      warn(`[dsh-mobile-bridge] 事件日志过大，跳过标题折叠: ${file.path} (${file.size} bytes)`);
      promise = Promise.resolve(null);
    } else {
      promise = decompressEventLog(file.path)
        .then((text) => {
          const folded = foldTitleFromEventLogText(text);
          return folded.title ? folded : null;
        })
        .catch((err) => {
          warn('[dsh-mobile-bridge] 事件日志标题解析失败:', err);
          return null;
        });
    }
    logCache.set(file.path, { mtimeMs: file.mtimeMs, size: file.size, promise });
    return promise;
  }

  return {
    /** Synchronous cheap answer; see the class note on why no inline decompress. */
    peek(home, sessionId) {
      const sp = sessionIdSpellings(sessionId);
      if (!sp) return null;
      const file = locateLogFile(home, sp);
      if (!file) return null;
      const hit = idCache.get(sp.id);
      if (hit && hit.mtimeMs === file.mtimeMs && hit.size === file.size) {
        return hit.value ? { title: hit.value.title, firstPrompt: hit.value.firstPrompt } : null;
      }
      return { pending: true };
    },

    /** Start (or join) the background decompress for one session. */
    warm(home, sessionId) {
      const sp = sessionIdSpellings(sessionId);
      if (!sp) return;
      const file = locateLogFile(home, sp);
      if (!file) return;
      const hit = idCache.get(sp.id);
      if (hit && hit.mtimeMs === file.mtimeMs && hit.size === file.size) return;
      decompressInBackground(file)
        .then((value) => {
          idCache.set(sp.id, { mtimeMs: file.mtimeMs, size: file.size, value });
        })
        .catch(() => { /* already warned inside decompressInBackground */ });
    },

    /** Full async answer, for callers that are allowed to await. */
    async read(home, sessionId) {
      const sp = sessionIdSpellings(sessionId);
      if (!sp) return null;
      const file = locateLogFile(home, sp);
      if (!file) return null;
      const hit = idCache.get(sp.id);
      if (hit && hit.mtimeMs === file.mtimeMs && hit.size === file.size) return hit.value;
      const value = await decompressInBackground(file);
      idCache.set(sp.id, { mtimeMs: file.mtimeMs, size: file.size, value });
      return value;
    },

    /**
     * Drop memoized state. `sessionId` drops just that session (called after a
     * rename writes a new title); with no argument it drops everything, which is
     * the correct response to a `session/rename` since the engine rewrites the
     * log too and the id→mtime binding can move for other sessions as well.
     */
    invalidate(sessionId) {
      if (sessionId === undefined) {
        logCache.clear();
        idCache.clear();
        projectDirs = null;
        projectDirsAt = 0;
        return;
      }
      const sp = sessionIdSpellings(sessionId);
      idCache.delete(sp ? sp.id : sessionId);
    }
  };
}
