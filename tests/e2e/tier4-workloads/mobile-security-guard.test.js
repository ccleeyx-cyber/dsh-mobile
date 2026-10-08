/**
 * Tier 4 Workload 4: Mobile Security Policy & Sandbox Management Workflow
 * Simulation of user inspecting and tuning security toggles, sandbox limits, git protection, and session policies
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';

describe('Tier 4 Workload 4 - Mobile Security Policy Management', () => {

  it('MW-4: End-to-end security settings configuration and session override workflow', async () => {
    // Step 1: Open Security center and read current state
    const currentRes = await apiRequest('/api/mobile/permissions');
    assert.equal(currentRes.status, 200);
    const orig = currentRes.data.permissions;

    try {
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
        await apiRequest('/api/mobile/sessions/delete', {
          method: 'POST',
          body: { sessionId: sId, workspaceId: targetWs.workspaceId }
        });
      }
    } finally {
      // Restore initial configuration
      await apiRequest('/api/mobile/permissions', {
        method: 'POST',
        body: {
          defaultPolicy: orig.executionPolicy || 'auto-read',
          sandboxMode: orig.sandboxMode || 'workspace-write',
          maxSteps: orig.maxSteps || 30,
          protectGit: orig.protectGit !== false
        }
      });
    }
  });
});
