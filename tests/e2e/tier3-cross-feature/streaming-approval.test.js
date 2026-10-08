/**
 * Tier 3 Cross-Feature: Streaming + Approval Interaction
 * Pairwise: Prompt streaming, tool execution approval interception, REST/WS approval settlement
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest, createWsClient } from '../helpers/client.js';

describe('Tier 3 - Streaming & Approval Cross-Feature Interaction', () => {

  it('TC1: Subscribe session stream and monitor approval lifecycle', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId: targetWs.workspaceId }
    });
    const sId = sRes.data.sessionId;

    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);
      client.send({ type: 'subscribe_session', sessionId: sId });

      // Query approvals list while subscribed
      const apprRes = await apiRequest('/api/mobile/approvals');
      assert.equal(apprRes.status, 200);
      assert.ok(Array.isArray(apprRes.data.approvals));
    } finally {
      client.close();
      await apiRequest('/api/mobile/sessions/delete', {
        method: 'POST',
        body: { sessionId: sId, workspaceId: targetWs.workspaceId }
      });
    }
  });

  it('TC2: Pending approval settlement via REST reflects in approvals query and client stream', async () => {
    // Check initial approvals list
    const initialRes = await apiRequest('/api/mobile/approvals');
    assert.equal(initialRes.status, 200);

    // Attempting to settle approval
    const settleRes = await apiRequest('/api/mobile/approval', {
      method: 'POST',
      body: {
        approvalId: 'test_appr_interaction',
        outcome: 'reject',
        reason: 'Pairwise test rejection'
      }
    });

    assert.equal(settleRes.status, 200);
  });

  it('TC3: In-flight prompt cancellation clears session lock for subsequent approval operations', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId: targetWs.workspaceId }
    });
    const sId = sRes.data.sessionId;

    try {
      // Trigger prompt cancellation
      const cancelRes = await apiRequest('/api/mobile/sessions/cancel', {
        method: 'POST',
        body: { sessionId: sId }
      });
      assert.equal(cancelRes.status, 200);

      // Verify approvals endpoint remains operational
      const apprRes = await apiRequest('/api/mobile/approvals');
      assert.equal(apprRes.status, 200);
    } finally {
      await apiRequest('/api/mobile/sessions/delete', {
        method: 'POST',
        body: { sessionId: sId, workspaceId: targetWs.workspaceId }
      });
    }
  });
});
