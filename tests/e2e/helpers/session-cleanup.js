/**
 * Test session bookkeeping — keeps the E2E suite out of the user's real workspace.
 *
 * Why this file exists
 * --------------------
 * These tests run against a LIVE bridge (127.0.0.1:3088) attached to a REAL DSH
 * instance and create sessions in the user's REAL workspace.
 *
 * A test run therefore accumulated >2300 sessions in E:\workspace\个人, of which
 * ~1350 were archived. Measured 2026-10-08 from ~/.dsh/storages/workspace.json.
 *
 * The three reasons the old recycling chain failed
 * ------------------------------------------------
 * 1. helpers/client.js filtered out any id starting with `session-` before
 *    tracking it. Real engine ids ARE `session-<uuid>` — 1896 of 2321 (82%) — so
 *    the tracker discarded exactly the sessions it existed to catch.
 * 2. `trackCreatedSession` archived IMMEDIATELY, before the test had prompted
 *    the session. The `has-content` guard below could therefore never fire, so a
 *    session the test went on to fill with real work got hidden anyway.
 * 3. `cleanupTestSessions` ended with `writeState([])`, discarding the whole
 *    table including entries it had just SKIPPED. A leak became permanent the
 *    moment it was observed once.
 *
 * How removal works now
 * ---------------------
 * Cleanup goes through the bridge's own `POST /api/mobile/sessions/delete`,
 * which archives, detaches from the workspace index and clears the projection
 * cache in one step.
 *
 * That replaces the old approach of read-modify-writing
 * ~/.dsh/storages/workspace.json directly from the test process. The engine
 * holds that table in memory and rewrites the file whenever it likes, so an
 * external read-modify-write could land between the engine's read and its write
 * and silently lose whatever the engine had just persisted — i.e. the cleanup
 * helper itself was a data-loss risk against the developer's real session list.
 * Direct file mutation is still available for the case where no bridge is
 * reachable, but only behind DSH_E2E_DIRECT_FS_CLEANUP=1.
 *
 * Archiving is DEFERRED to the end of the run so the has-content check is
 * meaningful. A crashed run leaves its state file behind and the next run's
 * sweep picks it up (each run now writes its own run-id-scoped file).
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const TMP = os.tmpdir();
const STATE_PREFIX = 'dsh-mobile-e2e-created-sessions';
/** Legacy shared file from before run-ids existed; swept once, then removed. */
const LEGACY_STATE_FILE = path.join(TMP, `${STATE_PREFIX}.json`);

/**
 * One state file per run. A single shared file meant two concurrent runs
 * clobbered each other's session lists, so whichever finished last archived the
 * other's sessions or lost track of its own.
 */
const RUN_ID = process.env.DSH_E2E_RUN_ID
  || `${process.pid}-${Date.now().toString(36)}`;
const STATE_FILE = path.join(TMP, `${STATE_PREFIX}-${RUN_ID}.json`);

function dshHome() {
  return process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
}

function cacheFileFor(cacheDir, sessionId) {
  const clean = String(sessionId).replace(/^session-/, '');
  for (const name of [`${clean}.json`, `session-${clean}.json`]) {
    const p = path.join(cacheDir, name);
    if (fs.existsSync(p)) return p;
  }
  return null;
}

function readTitle(cacheFile) {
  try {
    const cache = JSON.parse(fs.readFileSync(cacheFile, 'utf8'));
    const rows = cache?.record?.rows || {};
    return String(rows.title?.val || rows.titleInput?.val?.first?.text || '').trim();
  } catch {
    return '';
  }
}

/** True when the session already holds real content and must never be hidden. */
function hasRealContent(sessionId) {
  const cacheDir = path.join(dshHome(), 'storages', 'session_projcache', 'sessions');
  const cacheFile = cacheFileFor(cacheDir, sessionId);
  return Boolean(cacheFile && readTitle(cacheFile));
}

function readStateFile(file) {
  try {
    if (!fs.existsSync(file)) return [];
    const arr = JSON.parse(fs.readFileSync(file, 'utf8'));
    return Array.isArray(arr) ? arr : [];
  } catch {
    return [];
  }
}

function readState() {
  return readStateFile(STATE_FILE);
}

function writeState(list) {
  try { fs.writeFileSync(STATE_FILE, JSON.stringify(list), 'utf8'); } catch { /* ignore */ }
}

/** Every state file from every run, so a crashed run is still swept later. */
function allStateFiles() {
  const files = [];
  try {
    for (const name of fs.readdirSync(TMP)) {
      if (name.startsWith(`${STATE_PREFIX}-`) && name.endsWith('.json')) {
        files.push(path.join(TMP, name));
      }
    }
  } catch { /* ignore */ }
  if (fs.existsSync(LEGACY_STATE_FILE)) files.push(LEGACY_STATE_FILE);
  return files;
}

/**
 * Last-resort path: archive by editing workspace.json directly.
 *
 * Deliberately opt-in (DSH_E2E_DIRECT_FS_CLEANUP=1) because it races the live
 * engine's in-memory copy of the same table. See the header comment.
 */
function archiveSessionDirectly(sessionId) {
  const id = String(sessionId);
  const clean = id.replace(/^session-/, '');
  const wsPath = path.join(dshHome(), 'storages', 'workspace.json');
  try {
    const ws = JSON.parse(fs.readFileSync(wsPath, 'utf8'));
    if (!ws.global) ws.global = {};
    const list = Array.isArray(ws.global.archivedSessionIds) ? ws.global.archivedSessionIds : [];
    if (!list.includes(id)) list.push(id);
    ws.global.archivedSessionIds = list;

    const table = ws?.tables?.workspaces;
    if (table) {
      for (const info of Object.values(table)) {
        if (!Array.isArray(info.sessionIds)) continue;
        info.sessionIds = info.sessionIds.filter((s) => s !== id && s !== clean);
      }
    }

    const tmp = `${wsPath}.e2e-cleanup.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(ws, null, 2), 'utf8');
    fs.renameSync(tmp, wsPath);
    return { archived: true, via: 'fs' };
  } catch (err) {
    return { archived: false, reason: err?.message, via: 'fs' };
  }
}

/** Preferred path: let the bridge do it, so the engine's own write path is used. */
async function archiveSessionViaApi(entry) {
  // Imported lazily so this module stays usable from a sync context and so a
  // missing fixtures file cannot break bookkeeping.
  const { CONFIG } = await import('./fixtures.js');
  const base = (CONFIG.BASE_URL || 'http://127.0.0.1:3088').replace(/\/$/, '');
  const res = await fetch(`${base}/api/mobile/sessions/delete`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${CONFIG.VALID_TOKEN}`
    },
    body: JSON.stringify({ sessionId: entry.sessionId, workspaceId: entry.workspaceId ?? undefined })
  });
  if (!res.ok) {
    return { archived: false, reason: `HTTP ${res.status}`, via: 'api' };
  }
  return { archived: true, via: 'api' };
}

/**
 * Register a session this run created.
 *
 * Records only — it does NOT archive. Archiving happens in cleanupTestSessions
 * once the test is finished with the session, so the has-content guard can tell
 * an empty test session from one the test went on to fill with real work.
 */
export function trackCreatedSession(sessionId, workspaceId) {
  if (!sessionId) return;
  try {
    const list = readState();
    // De-duplicate: the same id can be tracked from both /sessions/create and a
    // later /sessions/prompt.
    if (list.some((e) => e.sessionId === String(sessionId))) return;
    list.push({ sessionId: String(sessionId), workspaceId: workspaceId || null, at: Date.now(), runId: RUN_ID });
    writeState(list);
  } catch { /* bookkeeping must never fail a test */ }
}

/** Session ids this run has created (diagnostics only). */
export function createdSessions() {
  return readState();
}

/**
 * Sweep every session any run tracked and archive the ones that are still empty.
 *
 * Safe to call at any time. Entries that are SKIPPED (because they hold real
 * content) stay in their state file instead of being discarded — the old
 * `writeState([])` turned a one-off skip into a permanent leak.
 */
export async function cleanupTestSessions({ force = false, files = allStateFiles() } = {}) {
  let removed = 0;
  let skipped = 0;
  let failed = 0;
  const directFs = process.env.DSH_E2E_DIRECT_FS_CLEANUP === '1';

  for (const file of files) {
    const tracked = readStateFile(file);
    if (tracked.length === 0) {
      try { if (file !== STATE_FILE) fs.rmSync(file, { force: true }); } catch { /* ignore */ }
      continue;
    }

    const keep = [];
    for (const entry of tracked) {
      // `force` is honoured now; it used to be accepted and then ignored.
      if (!force && hasRealContent(entry.sessionId)) {
        skipped++;
        keep.push(entry);
        continue;
      }
      let r;
      try {
        r = directFs
          ? archiveSessionDirectly(entry.sessionId)
          : await archiveSessionViaApi(entry);
      } catch (err) {
        r = { archived: false, reason: err?.message, via: 'api' };
      }
      if (r.archived) {
        removed++;
      } else if (directFs || r.reason === 'HTTP 404') {
        // No usable bridge — fall back once, then give up on this entry.
        const fb = archiveSessionDirectly(entry.sessionId);
        if (fb.archived) removed++; else { failed++; keep.push(entry); }
      } else {
        failed++;
        keep.push(entry);
      }
    }

    // Rewrite with only what could not be cleaned, so a later run retries it.
    try {
      if (keep.length) fs.writeFileSync(file, JSON.stringify(keep), 'utf8');
      else fs.rmSync(file, { force: true });
    } catch { /* ignore */ }
  }

  return { removed, skipped, failed, runId: RUN_ID };
}
