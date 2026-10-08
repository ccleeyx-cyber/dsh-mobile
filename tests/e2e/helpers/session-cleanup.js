/**
 * Test session bookkeeping — keeps the E2E suite out of the user's real workspace.
 *
 * Why this file exists
 * --------------------
 * These tests run against a LIVE bridge (127.0.0.1:3088) attached to a REAL DSH
 * instance and create sessions in the user's REAL workspace.
 *
 * `POST /api/mobile/sessions/delete` does not delete anything: the DSH engine
 * exposes no session/delete RPC (every candidate method returns 404) and the
 * bridge swallows that failure while still answering HTTP 200 "Deleted". A test
 * run therefore silently accumulated >1000 empty sessions in E:\workspace\个人.
 *
 * How removal actually works
 * --------------------------
 * Editing workspace.json does not stick — the engine holds the table in memory
 * and rewrites the file within seconds. The one mutation the engine *does* accept
 * and persist is `global.archivedSessionIds`, which is what its own UI uses to
 * hide sessions. So cleanup = append to that list.
 *
 * Sessions are retired as soon as the test releases them, not at the end of the
 * run, so an interrupted run still leaves the workspace clean.
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const STATE_FILE = path.join(os.tmpdir(), 'dsh-mobile-e2e-created-sessions.json');

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

function readState() {
  try {
    if (!fs.existsSync(STATE_FILE)) return [];
    const arr = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    return Array.isArray(arr) ? arr : [];
  } catch {
    return [];
  }
}

function writeState(list) {
  try { fs.writeFileSync(STATE_FILE, JSON.stringify(list), 'utf8'); } catch { /* ignore */ }
}

/**
 * Archive a session created by a test.
 *
 * Only sessions that are still empty are archived — if a test managed to give one
 * real content it is left alone so real work is never hidden.
 */
function archiveSession(sessionId) {
  const id = String(sessionId);
  const clean = id.replace(/^session-/, '');
  const cacheDir = path.join(dshHome(), 'storages', 'session_projcache', 'sessions');
  const cacheFile = cacheFileFor(cacheDir, id);
  if (cacheFile && readTitle(cacheFile)) return { archived: false, reason: 'has-content' };

  const wsPath = path.join(dshHome(), 'storages', 'workspace.json');
  try {
    const ws = JSON.parse(fs.readFileSync(wsPath, 'utf8'));
    if (!ws.global) ws.global = {};
    const list = Array.isArray(ws.global.archivedSessionIds) ? ws.global.archivedSessionIds : [];
    if (!list.includes(id)) list.push(id);
    ws.global.archivedSessionIds = list;

    // Detach from the workspace's id list as well, so the count stays honest even
    // before the engine reloads the archive set.
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
    return { archived: true };
  } catch (err) {
    return { archived: false, reason: err?.message };
  }
}

/** Register a session, then archive it immediately so nothing accumulates. */
export function trackCreatedSession(sessionId, workspaceId) {
  if (!sessionId) return;
  try {
    const list = readState();
    list.push({ sessionId, workspaceId: workspaceId || null, at: Date.now() });
    writeState(list);
  } catch { /* bookkeeping must never fail a test */ }
  archiveSession(sessionId);
}

/** Session ids this run has created (diagnostics only). */
export function createdSessions() {
  return readState();
}

/**
 * Sweep anything a crashed run left behind: archive every tracked id that is
 * still empty. Safe to call at any time.
 */
export function cleanupTestSessions({ force = false } = {}) {
  const tracked = readState();
  if (tracked.length === 0) return { removed: 0, skipped: 0 };
  let removed = 0;
  let skipped = 0;
  for (const { sessionId } of tracked) {
    const r = archiveSession(sessionId);
    if (r.archived) removed++; else skipped++;
  }
  writeState([]);
  return { removed, skipped };
}
