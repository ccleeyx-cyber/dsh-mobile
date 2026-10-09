/**
 * Global test teardown: archive every empty session the run created.
 *
 * Wired through `--import ./tests/cleanup-hook.mjs` on the live-E2E scripts in
 * package.json. `node --test` spawns one process per test file and passes
 * --import down to each, so this registers once per file and cleans up that
 * file's own sessions.
 *
 * This file was dead code before 2026-10-08. Four separate defects:
 *   1. No script ever passed `--import`, despite the header comment claiming it
 *      was "wired through --import". Nothing loaded it.
 *   2. Its import path was `../e2e/helpers/session-cleanup.js`. Resolved from
 *      tests/ that is dsh_mobile/e2e/... which does not exist — so had anything
 *      ever imported this file it would have died with ERR_MODULE_NOT_FOUND.
 *      That is conclusive proof it was never loaded. Correct path: ./e2e/...
 *   3. Its `process.on('exit')` handler had an EMPTY body — a comment explaining
 *      why it does nothing, and no code. An HTTP call could never complete in an
 *      'exit' handler anyway, since those must stay synchronous.
 *   4. The `await cleanupTestSessions()` sat at top level, so it ran at IMPORT
 *      time — before a single test had executed. It swept the previous run's
 *      leftovers, then the current run created its own and nothing removed them.
 *
 * Ordering is now: register teardown hooks at import time, do the work in
 * node:test's root after() (deterministic, can await) with beforeExit as the
 * crash safety net.
 */

import { cleanupTestSessions } from './e2e/helpers/session-cleanup.js';

let done = false;

async function run(reason) {
  if (done) return { removed: 0, skipped: 0, failed: 0, reason: 'already-run' };
  done = true;
  try {
    const result = await cleanupTestSessions();
    if (result.removed || result.skipped || result.failed) {
      console.log(
        `[e2e-cleanup:${reason}] archived ${result.removed}, `
        + `skipped ${result.skipped} with real content, failed ${result.failed} (run ${result.runId})`
      );
    }
    return result;
  } catch (err) {
    // Never let teardown fail the suite — but do say so, because a silent
    // teardown failure is exactly how 2300 sessions accumulated.
    console.warn(`[e2e-cleanup:${reason}] failed: ${err?.message}`);
    return { removed: 0, skipped: 0, failed: -1, reason };
  }
}

// beforeExit fires once the event loop drains, which for a test-file process is
// after every test has finished, and it MAY schedule further async work — unlike
// 'exit', whose handlers must stay synchronous. The old version used 'exit' with
// an empty body, where an HTTP call could never have completed regardless.
//
// Deliberately NOT importing node:test to register an after() hook: importing it
// initialises the test runner in whatever process loaded this file, which prints
// a spurious "tests 0 / pass 0" summary and can alter exit behaviour for the
// plain `node` scripts (test:challenger:race, bench:*) that also carry --import.
// The cost is that a --test-force-exit or a hard crash skips teardown; the
// run-id-scoped state file means the next run's sweep picks those sessions up.
process.on('beforeExit', () => { void run('beforeExit'); });

// Exposed so a test can force a sweep mid-run.
export { run as cleanupNow };
