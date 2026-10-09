/**
 * Tier 1: Permissions & Execution Policies Verification
 * Features: Query permissions, Update execution policy, Sandbox mode, Git protection, Session override
 *
 * ⚠️ DESTRUCTIVE SUITE — writes to the real ~/.dsh/mobile-access/permissions.json.
 * Not part of `npm test`; run via `npm run test:destructive`.
 *
 * Changes from the original:
 *   - TC2/TC3/TC4 restored outside a try/finally, so any assertion failure left
 *     the live config mutated. Now wrapped in withRestoredPermissions.
 *   - TC2 used `executionPolicy || 'auto-read'`, which downgrades a user on
 *     `ask` to auto-approving reads. The snapshot is now used verbatim.
 *   - TC5 picked `workspaces[0].sessions[0]` — a REAL session in the developer's
 *     own workspace — and set it to `danger-full-access` with no restore at all,
 *     permanently leaving one live session able to run anything without
 *     approval. It now creates a throwaway session and restores the policy.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';
import { withRestoredPermissions, restoreSessionPolicy } from '../helpers/guard.js';

describe('Tier 1 - Permissions & Security Policies', () => {

  it('TC1: GET /api/mobile/permissions returns execution policy configuration', async () => {
    const res = await apiRequest('/api/mobile/permissions');
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.code, 0);

    const perms = res.data.permissions;
    assert.ok(perms, 'Permissions object must exist');
    assert.ok(perms.defaultPolicy || perms.executionPolicy);
    assert.equal(typeof perms.sandboxMode, 'string');
    assert.equal(typeof perms.maxSteps, 'number');
    assert.equal(typeof perms.protectGit, 'boolean');
  });

  it('TC2: POST /api/mobile/permissions updates execution policy atomically', async () => {
    await withRestoredPermissions(async (orig) => {
      const origPolicy = orig.executionPolicy;
      assert.ok(origPolicy, 'snapshot must carry a non-empty executionPolicy');

      const testPolicy = origPolicy === 'auto-read' ? 'ask' : 'auto-read';

      const updateRes = await apiRequest('/api/mobile/permissions', {
        method: 'POST',
        body: { defaultPolicy: testPolicy }
      });

      assert.equal(updateRes.status, 200);
      assert.equal(updateRes.data.ok, true);
      assert.equal(updateRes.data.permissions.executionPolicy, testPolicy);
    });
  });

  it('TC3: POST /api/mobile/permissions toggles protectGit security setting', async () => {
    await withRestoredPermissions(async (orig) => {
      const origProtect = orig.protectGit;
      assert.equal(typeof origProtect, 'boolean', 'snapshot must carry a boolean protectGit');

      const toggled = !origProtect;
      const updateRes = await apiRequest('/api/mobile/permissions', {
        method: 'POST',
        body: { protectGit: toggled }
      });

      assert.equal(updateRes.status, 200);
      assert.equal(updateRes.data.permissions.protectGit, toggled);
    });
  });

  it('TC4: POST /api/mobile/permissions updates maxSteps execution limit', async () => {
    await withRestoredPermissions(async (orig) => {
      const testSteps = 45;
      const updateRes = await apiRequest('/api/mobile/permissions', {
        method: 'POST',
        body: { maxSteps: testSteps }
      });

      assert.equal(updateRes.status, 200);
      assert.equal(updateRes.data.permissions.maxSteps, testSteps);
      // A legitimate original of 0 is restored as 0 by the guard, not as a
      // fallback — that is the whole point of withRestoredPermissions.
      assert.notEqual(orig.maxSteps, testSteps, 'test is vacuous if the original already equals the test value');
    });
  });

  it('TC5: POST /api/mobile/sessions/permission overrides policy for specific session', async () => {
    // Create a throwaway session instead of hijacking the developer's own.
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const firstWs = wsRes.data.workspaces[0];
    assert.ok(firstWs, 'expected at least one workspace');

    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId: firstWs.workspaceId }
    });
    assert.equal(sRes.status, 200, 'creating the throwaway session must succeed');
    const sId = sRes.data.sessionId;
    assert.ok(sId, 'create must return a sessionId');

    // Whatever policy the new session started with is what we put back.
    const priorPolicy = sRes.data.policy ?? 'auto-read';

    try {
      const res = await apiRequest('/api/mobile/sessions/permission', {
        method: 'POST',
        body: { sessionId: sId, policy: 'danger-full-access' }
      });

      assert.equal(res.status, 200);
      assert.equal(res.data.ok, true);
      assert.equal(res.data.sessionId, sId);
      assert.equal(res.data.policy, 'danger-full-access');
    } finally {
      // Restore first: the bridge's sessions/delete reports success without
      // actually deleting (tests/e2e/helpers/session-cleanup.js:9-12), so a
      // leftover danger-full-access entry would otherwise outlive the session.
      await restoreSessionPolicy(sId, priorPolicy);
      await apiRequest('/api/mobile/sessions/delete', {
        method: 'POST',
        body: { sessionId: sId, workspaceId: firstWs.workspaceId }
      }).catch(() => {});
    }
  });

  it('TC6: GET /api/mobile/permissions without token returns HTTP 401', async () => {
    const res = await apiRequest('/api/mobile/permissions', { token: null });
    assert.equal(res.status, 401);
  });
});
