/**
 * Tier 4 Workload 1: Mobile Full Lifecycle Journey
 * Simulation of a complete mobile app session from launch to session disposal
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest, createWsClient } from '../helpers/client.js';

describe('Tier 4 Workload 1 - Mobile Full Lifecycle Journey', () => {

  it('MW-1: Simulates full mobile user journey across health, workspaces, session, and WS', async () => {
    // Step 1: Health check & configuration validation on app launch
    const health = await apiRequest('/health');
    assert.equal(health.status, 200);
    assert.equal(health.data.authenticated, true);

    // Step 2: Establish duplex WebSocket connection
    const client = await createWsClient();
    try {
      const greeting = await client.waitForMessage(m => m.type === 'connected', 3000);
      assert.equal(greeting.type, 'connected');

      // Step 3: Fetch workspaces list
      const wsRes = await apiRequest('/api/mobile/workspaces');
      assert.equal(wsRes.status, 200);
      assert.ok(wsRes.data.workspaces.length > 0);
      const targetWs = wsRes.data.workspaces[0];

      // Step 4: Create new session in workspace
      const createRes = await apiRequest('/api/mobile/sessions/create', {
        method: 'POST',
        body: { workspaceId: targetWs.workspaceId }
      });
      assert.equal(createRes.status, 200);
      const sId = createRes.data.sessionId;
      assert.ok(sId);

      // Step 5: Switch session model
      const settingsRes = await apiRequest('/api/mobile/settings');
      const chosenModel = settingsRes.data.settings.availableModels[0].id;
      const modelSwitchRes = await apiRequest('/api/mobile/sessions/model', {
        method: 'POST',
        body: { sessionId: sId, model: chosenModel }
      });
      assert.equal(modelSwitchRes.status, 200);

      // Step 6: Subscribe to session over WebSocket
      client.send({ type: 'subscribe_session', sessionId: sId });

      // Step 7: Send ping to keep socket alive
      client.send({ type: 'ping' });
      const pong = await client.waitForMessage(m => m.type === 'pong', 2000);
      assert.equal(pong.type, 'pong');

      // Step 8: Cancel session turn cleanly
      const cancelRes = await apiRequest('/api/mobile/sessions/cancel', {
        method: 'POST',
        body: { sessionId: sId }
      });
      assert.equal(cancelRes.status, 200);

      // Step 9: Verify session history
      const historyRes = await apiRequest(`/api/mobile/sessions/${sId}`);
      assert.equal(historyRes.status, 200);
      assert.equal(historyRes.data.data.sessionId, sId);

      // Step 10: Delete session
      const deleteRes = await apiRequest('/api/mobile/sessions/delete', {
        method: 'POST',
        body: { sessionId: sId, workspaceId: targetWs.workspaceId }
      });
      assert.equal(deleteRes.status, 200);
    } finally {
      client.close();
    }
  });
});
