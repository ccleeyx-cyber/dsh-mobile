/**
 * Tier 4 Workload 4: Mobile Security Policy & Sandbox Management Workflow
 * Simulation of user inspecting and tuning security toggles, sandbox limits, git protection, and session policies
 *
 * ⚠️ DESTRUCTIVE SUITE — rewrites the live global permission config and sets a
 * session to danger-full-access. Not part of `npm test`; run via
 * `npm run test:destructive`.
 *
 * The restore block used to read:
 *     defaultPolicy: orig.executionPolicy || 'auto-read',
 *     sandboxMode:   orig.sandboxMode     || 'workspace-write',
 *     maxSteps:      orig.maxSteps        || 30,
 *     protectGit:    orig.protectGit      !== false
 * Every one of those is a silent corruption path. An original maxSteps of 0 came
 * back as 30; a missing sandboxMode came back as 'workspace-write'; and
 * `protectGit !== false` turns undefined into true, i.e. a test run could turn
 * git protection ON for a user who had never configured it. Restore now goes
 * through withRestoredPermissions, which copies the snapshot verbatim and
 * asserts afterwards that it landed.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';
import { withRestoredPermissions, restoreSessionPolicy } from '../helpers/guard.js';

describe('Tier 4 Workload 4 - Mobile Security Policy Management', () => {

  it('MW-4: End-to-end security settings configuration and session override workflow', async () => {
    await withRestoredPermissions(async (orig) => {
      // Step 1: the snapshot is taken by the guard before this callback runs.
      assert.equal(typeof orig, 'object');

      // Step 2: Atomic update of global execution policies
      const updateRes = await apiRequest('/api/mobile/permissions', {
        method: 'POST',
        body: {
          defaultPolicy: 'auto-read',
          sandboxMode: 'workspace-write',
          maxSteps: 40,
          protectGit: true
        }
      });
      assert.equal(updateRes.status, 200);
      assert.equal(updateRes.data.permissions.executionPolicy, 'auto-read');
      assert.equal(updateRes.data.permissions.sandboxMode, 'workspace-write');
      assert.equal(updateRes.data.permissions.maxSteps, 40);
      assert.equal(updateRes.data.permissions.protectGit, true);

      // Step 3: Create session and configure session-specific security override
      const wsRes = await apiRequest('/api/mobile/workspaces');
      const targetWs = wsRes.data.workspaces[0];
      const sRes = await apiRequest('/api/mobile/sessions/create', {
        method: 'POST',
        body: { workspaceId: targetWs.workspaceId }
      });
      const sId = sRes.data.sessionId;
      const priorSessionPolicy = sRes.data.policy ?? 'auto-read';

      try {
        const sessionOverrideRes = await apiRequest('/api/mobile/sessions/permission', {
          method: 'POST',
          body: {
            sessionId: sId,
            policy: 'danger-full-access'
          }
        });
        assert.equal(sessionOverrideRes.status, 200);
        assert.equal(sessionOverrideRes.data.policy, 'danger-full-access');

        // Step 4: Verify global configuration remains intact after session override
        const verifyGlobalRes = await apiRequest('/api/mobile/permissions');
        assert.equal(verifyGlobalRes.status, 200);
        assert.equal(verifyGlobalRes.data.permissions.executionPolicy, 'auto-read');
        assert.equal(verifyGlobalRes.data.permissions.protectGit, true);
      } finally {
        // Restore the session policy BEFORE deleting, because the bridge's
        // sessions/delete reports success without actually deleting
        // (tests/e2e/helpers/session-cleanup.js:9-12). A leftover
        // danger-full-access entry would otherwise outlive the session.
        await restoreSessionPolicy(sId, priorSessionPolicy);
        await apiRequest('/api/mobile/sessions/delete', {
          method: 'POST',
          body: { sessionId: sId, workspaceId: targetWs.workspaceId }
        }).catch(() => {});
      }
    });
  });
});
