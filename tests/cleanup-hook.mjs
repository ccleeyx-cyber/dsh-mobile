/**
 * Global test teardown: remove every session this run created from the live
 * workspace.
 *
 * Registered via `node --test --test-force-exit`? No — it is wired through
 * `--import` so it runs once after the test process finishes, which matters
 * because these tests create sessions in a REAL workspace and the bridge's
 * delete endpoint does not actually delete anything.
 */

import { cleanupTestSessions } from '../e2e/helpers/session-cleanup.js';

process.on('exit', () => {
  // exit handlers must be synchronous, so kick off the cleanup and let the
  // already-written tracking file be consumed on the next run instead of
  // racing the process teardown here.
});

const result = await cleanupTestSessions({ force: false }).catch(() => ({ removed: 0, skipped: 0 }));
if (result.removed > 0 || result.skipped > 0) {
  console.log(`[e2e-cleanup] removed ${result.removed} test session(s), skipped ${result.skipped} with real content`);
}
