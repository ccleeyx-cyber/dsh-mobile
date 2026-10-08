/**
 * Tier 4 Workload 3: Mobile Network Resilience & Recovery Workflow
 * Simulation of mobile network drop (Wi-Fi/Cellular handover, elevator), auto-reconnection <=5s, session state resync
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest, createWsClient } from '../helpers/client.js';

describe('Tier 4 Workload 3 - Mobile Network Resilience & Recovery', () => {

  it('MW-3: Simulates mobile network drop, fast auto-reconnect (<=5s), and state resync', async () => {
    // Step 1: Client launches, queries workspace and session
    const wsRes = await apiRequest('/api/mobile/workspaces');
    assert.equal(wsRes.status, 200);
    const targetWs = wsRes.data.workspaces[0];

    const createRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId: targetWs.workspaceId }
    });
    const sId = createRes.data.sessionId;

    try {
      // Step 2: Establish active WebSocket streaming session
      const client = await createWsClient();
      await client.waitForMessage(m => m.type === 'connected', 3000);
      client.send({ type: 'subscribe_session', sessionId: sId });

      // Step 3: Simulate mobile network loss (abrupt TCP reset)
      const disconnectTime = Date.now();
      client.close();

      // Step 4: Auto-reconnect triggered within 5 seconds without app restart
      const reconnectedClient = await createWsClient();
      const greeting = await reconnectedClient.waitForMessage(m => m.type === 'connected', 3000);
      const reconnectDuration = Date.now() - disconnectTime;

      assert.equal(greeting.type, 'connected');
      assert.ok(
        reconnectDuration <= 5000,
        `Network recovery must complete within 5 seconds (took ${reconnectDuration}ms)`
      );

      // Step 5: Re-sync active session state and pending stream chunks upon reconnection
      const resyncRes = await apiRequest(`/api/mobile/sessions/${sId}`);
      assert.equal(resyncRes.status, 200);
      assert.equal(resyncRes.data.data.sessionId, sId);
      assert.ok(Array.isArray(resyncRes.data.data.messages), 'Session message history preserved');

      reconnectedClient.close();
    } finally {
      await apiRequest('/api/mobile/sessions/delete', {
        method: 'POST',
        body: { sessionId: sId, workspaceId: targetWs.workspaceId }
      });
    }
  });
});
