/**
 * Shared guards for suites that mutate the developer's REAL ~/.dsh state.
 *
 * Why this file exists: several E2E suites changed the live global execution
 * policy, the live default model, or a real session's sandbox mode and then
 * either never restored them or "restored" them to a hardcoded literal. The
 * worst case was tier3/permission-prompt.test.js writing
 * `defaultPolicy: 'auto-read'` in its finally block regardless of what it had
 * read, which silently downgraded anyone running `ask` — i.e. running the test
 * suite made the developer's own agent less safe without telling them.
 *
 * Rules these helpers enforce:
 *   1. Snapshot the EXACT prior value before mutating.
 *   2. Restore with `hasOwnProperty`, never `orig.x || fallback` — a legitimate
 *      0 / false / '' must come back as itself.
 *   3. Restore in a finally, and verify afterwards that it landed.
 *   4. Write test scratch files into a temp dir, not the caller's workspace.
 *
 * See ANALYSIS-优化与新增功能.md §1.14b.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { apiRequest } from './client.js';

/** Fields that POST /api/mobile/permissions accepts. */
const PERMISSION_FIELDS = [
  'executionPolicy',
  'defaultPolicy',
  'maxSteps',
  'protectGit',
  'sandboxMode',
  'sensitiveDirs'
];

export async function readPermissions() {
  const res = await apiRequest('/api/mobile/permissions');
  assert.equal(res.status, 200, 'GET /api/mobile/permissions must succeed before a guard can snapshot it');
  return res.data.permissions || {};
}

/**
 * Build a restore patch from a snapshot, copying only fields that were actually
 * present. Never falls back to a default — that is the bug this module exists to
 * prevent.
 */
export function restorePatchFrom(snapshot, fields = PERMISSION_FIELDS) {
  const patch = {};
  for (const key of fields) {
    if (Object.prototype.hasOwnProperty.call(snapshot, key) && snapshot[key] !== undefined) {
      patch[key] = snapshot[key];
    }
  }
  // The API reports the global policy as `executionPolicy` but accepts it as
  // `defaultPolicy`. Send both spellings so the restore lands either way.
  if (patch.executionPolicy !== undefined && patch.defaultPolicy === undefined) {
    patch.defaultPolicy = patch.executionPolicy;
  }
  return patch;
}

/**
 * Run `fn` with the live permission config snapshotted beforehand and restored
 * afterwards, then assert the restore actually took.
 *
 *   await withRestoredPermissions(async () => {
 *     await apiRequest('/api/mobile/permissions', { method: 'POST', body: { defaultPolicy: 'ask' } });
 *     ...
 *   });
 */
export async function withRestoredPermissions(fn) {
  const before = await readPermissions();
  try {
    return await fn(before);
  } finally {
    const patch = restorePatchFrom(before);
    if (Object.keys(patch).length) {
      await apiRequest('/api/mobile/permissions', { method: 'POST', body: patch }).catch(() => {});
      const after = await readPermissions().catch(() => null);
      if (after) {
        assert.equal(
          after.executionPolicy,
          before.executionPolicy,
          `withRestoredPermissions failed to restore executionPolicy: now ${after.executionPolicy}, was ${before.executionPolicy}`
        );
      }
    }
  }
}

/**
 * Same guard for the global default model, which models-and-settings.test.js
 * mutates. The field is reported as `settings.currentModel` and written via
 * POST /api/mobile/settings/model.
 */
export async function readCurrentModel() {
  const res = await apiRequest('/api/mobile/settings');
  assert.equal(res.status, 200, 'GET /api/mobile/settings must succeed before a guard can snapshot it');
  return res.data?.settings?.currentModel ?? null;
}

export async function withRestoredModel(fn) {
  const origModel = await readCurrentModel();
  try {
    return await fn(origModel);
  } finally {
    if (origModel) {
      await apiRequest('/api/mobile/settings/model', {
        method: 'POST',
        body: { model: origModel }
      }).catch(() => {});
    }
  }
}

/**
 * Restore a single session's policy to an exact prior value.
 *
 * Needed separately from withRestoredPermissions because the bridge's
 * sessions/delete is unreliable (it reports `Deleted` without deleting), so a
 * session-level override can outlive the session it was set on.
 */
export async function restoreSessionPolicy(sessionId, policy) {
  if (!sessionId || !policy) return;
  await apiRequest('/api/mobile/sessions/permission', {
    method: 'POST',
    body: { sessionId, policy }
  }).catch(() => {});
}

/**
 * A throwaway directory for scratch files, cleaned up on process exit.
 *
 * The memory tests used to write E2E_MEMORY_TEST.MD / LARGE_MEMORY_TEST.MD /
 * PROJECT_WORKLOAD_MEMORY.MD straight into whatever workspacePath they were
 * pointed at — which in practice was the developer's real workspace root, where
 * they were picked up by glob/grep and by the agent's own file views. They were
 * still sitting there a day later.
 *
 * Usage:
 *   const dir = scratchDir();
 *   await apiRequest(`/api/mobile/memory?workspacePath=${encodeURIComponent(dir)}&fileName=...`)
 */
const scratchDirs = [];
export function scratchDir(prefix = 'dsh-e2e-') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  scratchDirs.push(dir);
  return dir;
}

let cleanupRegistered = false;
export function cleanupScratchDirs() {
  for (const dir of scratchDirs.splice(0)) {
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
  }
}

/**
 * Track a scratch file written INTO a real registered workspace, so it can be
 * removed afterwards.
 *
 * The memory endpoints validate workspacePath against the registered-workspace
 * whitelist (core.mjs createPathSanitizer, layer 2), so pointing them at a temp
 * dir just returns 403 — there is no API to register one either. The tests
 * therefore have to write into a real workspace. That is acceptable only if the
 * file is guaranteed to disappear again, which it previously was not: the three
 * suites below wrote into workspaces[0].path and never deleted, so
 * E2E_MEMORY_TEST.MD, LARGE_MEMORY_TEST.MD (96 KB) and PROJECT_WORKLOAD_MEMORY.MD
 * were still sitting in the developer's real workspace root a day later, where
 * glob/grep and the agent's own file views picked them up.
 *
 *   const abs = trackWorkspaceFile(targetWs.path, 'E2E_MEMORY_TEST.MD');
 *   try { ...write via API... } finally { cleanupWorkspaceFiles(); }
 */
const workspaceFiles = [];
export function trackWorkspaceFile(workspacePath, fileName) {
  const abs = path.join(workspacePath, fileName);
  workspaceFiles.push(abs);
  return abs;
}

export function cleanupWorkspaceFiles() {
  for (const abs of workspaceFiles.splice(0)) {
    // The bridge has no delete-file endpoint, and these tests run on the same
    // host as the workspace they write to, so remove it directly.
    try { fs.rmSync(abs, { force: true }); } catch { /* ignore */ }
  }
}

/**
 * Register exit-time cleanup once per process. `node --test` runs each file in
 * its own process, so this covers the normal path; call the cleanup functions
 * explicitly from an after()/finally when you want deterministic teardown.
 */
export function autoCleanup() {
  if (cleanupRegistered) return;
  cleanupRegistered = true;
  // process.on('exit') handlers must be synchronous — rmSync is, so this works.
  // (tests/cleanup-hook.mjs tried the same thing with an EMPTY handler body and
  // was never even wired up via --import; see ANALYSIS §1.14c.)
  process.on('exit', () => { cleanupScratchDirs(); cleanupWorkspaceFiles(); });
}
