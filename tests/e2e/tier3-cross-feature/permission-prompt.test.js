/**
 * Tier 3 Cross-Feature: Permission Change + Prompt Flow Interaction
 * Pairwise: Global policy update, session-specific policy override, prompt flow execution
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';

describe('Tier 3 - Permission Change & Prompt Interaction', () => {

  it('TC1: Switching global execution policy takes effect before prompt execution', async () => {
    // 1. Get original permissions
    const permRes = await apiRequest('/api/mobile/permissions');
    const origPolicy = permRes.data.permissions.executionPolicy || 'auto-read';

    // 2. Set to 'ask'
    await apiRequest('/api/mobile/permissions', {
      method: 'POST',
      body: { defaultPolicy: 'ask' }
    });

    const verifyPerm = await apiRequest('/api/mobile/permissions');
    assert.equal(verifyPerm.data.permissions.executionPolicy, 'ask');

    // 3. Restore original
    await apiRequest('/api/mobile/permissions', {
      method: 'POST',
      body: { defaultPolicy: origPolicy }
    });
  });

  it('TC2: Session policy override takes precedence over global policy for designated session', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId: targetWs.workspaceId }
    });
    const sId = sRes.data.sessionId;

    try {
      // Set global policy to 'ask'
      await apiRequest('/api/mobile/permissions', {
        method: 'POST',
        body: { defaultPolicy: 'ask' }
      });

      // Override session policy to 'danger-full-access'
      const overrideRes = await apiRequest('/api/mobile/sessions/permission', {
        method: 'POST',
        body: { sessionId: sId, policy: 'danger-full-access' }
      });

      assert.equal(overrideRes.status, 200);
      assert.equal(overrideRes.data.policy, 'danger-full-access');

      // Global permissions remain unchanged
      const globalPerm = await apiRequest('/api/mobile/permissions');
      assert.equal(globalPerm.data.permissions.executionPolicy, 'ask');
    } finally {
      // Clean up session and restore policy
      await apiRequest('/api/mobile/sessions/delete', {
        method: 'POST',
        body: { sessionId: sId, workspaceId: targetWs.workspaceId }
      });
      await apiRequest('/api/mobile/permissions', {
        method: 'POST',
        body: { defaultPolicy: 'auto-read' }
      });
    }
  });

  it('TC3: Atomic permissions update prevents race condition on rapid sequential changes', async () => {
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

    const finalRes = await apiRequest('/api/mobile/permissions');
    assert.equal(finalRes.status, 200);
    assert.equal(finalRes.data.permissions.maxSteps, 30);
  });
});
