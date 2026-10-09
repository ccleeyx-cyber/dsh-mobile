/**
 * Tier 3 Cross-Feature: Permission Change + Prompt Flow Interaction
 * Pairwise: Global policy update, session-specific policy override, prompt flow execution
 *
 * ⚠️ DESTRUCTIVE SUITE — it writes to the real ~/.dsh/mobile-access/permissions.json.
 * It is deliberately NOT part of `npm test`; run it via `npm run test:destructive`.
 *
 * Every mutation is captured before it happens and restored to the EXACT prior
 * value afterwards. This file used to be the worst offender in the suite:
 *   - TC2's finally block restored `defaultPolicy: 'auto-read'` as a hardcoded
 *     literal instead of the value it had just read, so a user on `ask` was
 *     silently downgraded to auto-approving reads on every run;
 *   - TC2 also left the session-level `danger-full-access` override behind (the
 *     session delete is itself unreliable, so the entry persisted in
 *     permissions.json);
 *   - TC3 set maxSteps to 30 and asserted it, never restoring.
 * `orig.maxSteps || 30` style fallbacks are banned here: an original value of 0
 * or undefined must come back as 0 or undefined, not as the fallback.
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';

describe('Tier 3 - Permission Change & Prompt Interaction', () => {
  /** Full permission snapshot taken before anything is touched. */
  let original = null;
  /** Session-level overrides this suite created, so after() can drop them. */
  const touchedSessions = [];

  async function readPermissions() {
    const res = await apiRequest('/api/mobile/permissions');
    assert.equal(res.status, 200, 'GET /api/mobile/permissions must succeed');
    return res.data.permissions;
  }

  /**
   * Push a permission patch. Only fields present in `patch` are sent, so an
   * absent field is never clobbered with a fallback value.
   */
  async function applyPatch(patch) {
    const res = await apiRequest('/api/mobile/permissions', { method: 'POST', body: patch });
    assert.equal(res.status, 200, `POST /api/mobile/permissions ${JSON.stringify(patch)} must succeed`);
    return res;
  }

  /** Restore every field this suite may have changed, using the captured values. */
  async function restore() {
    if (!original) return;
    const patch = {};
    for (const key of ['executionPolicy', 'defaultPolicy', 'maxSteps', 'protectGit', 'sandboxMode']) {
      // hasOwnProperty, not `|| dflt`: a legitimate 0/false/'' must be restored
      // as itself.
      if (Object.prototype.hasOwnProperty.call(original, key) && original[key] !== undefined) {
        patch[key] = original[key];
      }
    }
    // The API reads the global policy as `defaultPolicy` on write and reports it
    // as `executionPolicy` on read; send both spellings so the restore lands
    // whichever one this build honours.
    if (patch.executionPolicy && !patch.defaultPolicy) patch.defaultPolicy = patch.executionPolicy;
    if (Object.keys(patch).length) {
      await apiRequest('/api/mobile/permissions', { method: 'POST', body: patch }).catch(() => {});
    }
    // Drop session-level overrides created by this suite.
    for (const { sessionId, policy } of touchedSessions.splice(0)) {
      await apiRequest('/api/mobile/sessions/permission', {
        method: 'POST',
        body: { sessionId, policy }
      }).catch(() => {});
    }
  }

  before(async () => {
    original = await readPermissions();
  });

  after(async () => {
    // Belt and braces: runs even if an individual test's finally was skipped
    // because the test threw before reaching it.
    await restore();
    const now = await readPermissions().catch(() => null);
    if (now && original) {
      assert.equal(
        now.executionPolicy,
        original.executionPolicy,
        `suite left executionPolicy as ${now.executionPolicy}, expected the original ${original.executionPolicy}`
      );
      assert.equal(
        now.maxSteps,
        original.maxSteps,
        `suite left maxSteps as ${now.maxSteps}, expected the original ${original.maxSteps}`
      );
    }
  });

  it('TC1: Switching global execution policy takes effect before prompt execution', async () => {
    // 1. Original is captured in before(); do NOT re-derive it with a `|| dflt`
    //    fallback, which is how the old TC2 ended up downgrading real users.
    const origPolicy = original.executionPolicy;
    assert.ok(origPolicy, 'expected a non-empty executionPolicy in the original snapshot');

    try {
      // 2. Set to 'ask'
      await applyPatch({ defaultPolicy: 'ask' });

      const verifyPerm = await readPermissions();
      assert.equal(verifyPerm.executionPolicy, 'ask');
    } finally {
      // 3. Restore the exact original
      await applyPatch({ defaultPolicy: origPolicy });
      const after = await readPermissions();
      assert.equal(after.executionPolicy, origPolicy, 'TC1 must leave the policy exactly as it found it');
    }
  });

  it('TC2: Session policy override takes precedence over global policy for designated session', async () => {
    const origPolicy = original.executionPolicy;
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId: targetWs.workspaceId }
    });
    const sId = sRes.data.sessionId;

    // Record the session's prior policy BEFORE overriding, so it can be put back
    // even though the session delete below is known to be unreliable.
    const beforeOverride = (sRes.data?.policy) ?? origPolicy;
    touchedSessions.push({ sessionId: sId, policy: beforeOverride });

    try {
      // Set global policy to 'ask'
      await applyPatch({ defaultPolicy: 'ask' });

      // Override session policy to 'danger-full-access'
      const overrideRes = await apiRequest('/api/mobile/sessions/permission', {
        method: 'POST',
        body: { sessionId: sId, policy: 'danger-full-access' }
      });

      assert.equal(overrideRes.status, 200);
      assert.equal(overrideRes.data.policy, 'danger-full-access');

      // Global permissions remain unchanged
      const globalPerm = await readPermissions();
      assert.equal(globalPerm.executionPolicy, 'ask');
    } finally {
      // Put the session override back first — the delete below may silently fail
      // (the bridge's deleteSession reports success without deleting), and a
      // leftover danger-full-access entry would outlive the session.
      await apiRequest('/api/mobile/sessions/permission', {
        method: 'POST',
        body: { sessionId: sId, policy: beforeOverride }
      }).catch(() => {});
      touchedSessions.length = 0;

      await apiRequest('/api/mobile/sessions/delete', {
        method: 'POST',
        body: { sessionId: sId, workspaceId: targetWs.workspaceId }
      }).catch(() => {});

      // Restore the policy we actually read, not a hardcoded literal.
      await applyPatch({ defaultPolicy: origPolicy });
    }
  });

  it('TC3: Atomic permissions update prevents race condition on rapid sequential changes', async () => {
    const origMaxSteps = original.maxSteps;
    const origPolicy = original.executionPolicy;

    try {
      const update1 = apiRequest('/api/mobile/permissions', {
        method: 'POST',
        body: { defaultPolicy: 'auto-read', maxSteps: 25 }
      });
      const update2 = apiRequest('/api/mobile/permissions', {
        method: 'POST',
        body: { defaultPolicy: 'auto-read', maxSteps: 30 }
      });

      const [res1, res2] = await Promise.all([update1, update2]);
      assert.equal(res1.status, 200);
      assert.equal(res2.status, 200);

      const finalRes = await readPermissions();
      // The last write wins; the point of the test is that no torn/interleaved
      // state survives, not that the value is 30 specifically.
      assert.ok(
        finalRes.maxSteps === 30 || finalRes.maxSteps === 25,
        `maxSteps must be one of the two written values, got ${finalRes.maxSteps}`
      );
    } finally {
      // Restore BOTH fields. The old version left maxSteps at 30 forever.
      const patch = { defaultPolicy: origPolicy };
      if (origMaxSteps !== undefined) patch.maxSteps = origMaxSteps;
      await applyPatch(patch);

      const now = await readPermissions();
      assert.equal(now.executionPolicy, origPolicy, 'TC3 must restore the original policy');
      if (origMaxSteps !== undefined) {
        assert.equal(now.maxSteps, origMaxSteps, 'TC3 must restore the original maxSteps');
      }
    }
  });
});
