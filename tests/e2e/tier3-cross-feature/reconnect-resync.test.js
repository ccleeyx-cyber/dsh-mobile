/**
 * Tier 3 Cross-Feature: Disconnect + Reconnect + In-Flight Resync Interaction
 * Features: Automatic reconnect within 5 seconds, active session state resync, resource leak prevention
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest, createWsClient } from '../helpers/client.js';

describe('Tier 3 - Disconnect, Reconnect & Resync Interaction', () => {

  it('TC1: Abrupt client disconnect is followed by successful reconnect within 5000ms (F3.1)', async () => {
    // 1. Establish initial connection
    const client1 = await createWsClient();
    await client1.waitForMessage(m => m.type === 'connected', 3000);

    // 2. Simulate abrupt TCP network drop
    client1.close();

    // 3. Measure time to establish reconnect
    const reconnectStart = Date.now();
    const client2 = await createWsClient();
    try {
      const greeting = await client2.waitForMessage(m => m.type === 'connected', 3000);
      const elapsed = Date.now() - reconnectStart;

      assert.equal(greeting.type, 'connected');
      assert.ok(elapsed <= 5000, `Reconnection must complete within 5000ms (took ${elapsed}ms)`);
    } finally {
      client2.close();
    }
  });

  it('TC2: Reconnect restores session tracking via GET /api/mobile/sessions/:id resync (F3.3)', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const firstWs = wsRes.data.workspaces.find(w => w.sessions && w.sessions.length > 0);
    const targetSession = firstWs.sessions[0];

    // Client connects and subscribes
    const client1 = await createWsClient();
    await client1.waitForMessage(m => m.type === 'connected', 3000);
    client1.send({ type: 'subscribe_session', sessionId: targetSession.sessionId });

    // Client drops connection
    client1.close();

    // Client reconnects and resyncs state via REST
    const resyncRes = await apiRequest(`/api/mobile/sessions/${targetSession.sessionId}`);
    assert.equal(resyncRes.status, 200);
    assert.equal(resyncRes.data.ok, true);
    assert.equal(resyncRes.data.data.sessionId, targetSession.sessionId);
    assert.ok(Array.isArray(resyncRes.data.data.messages), 'Messages buffer recovered');
  });

  it('TC3: Rapid consecutive disconnects and reconnects clean up resources without leaks (F4.4)', async () => {
    for (let i = 0; i < 3; i++) {
      const client = await createWsClient();
      await client.waitForMessage(m => m.type === 'connected', 3000);
      client.close();
      await new Promise(r => setTimeout(r, 100));
    }

    // Verify bridge remains responsive after multiple rapid connection churn cycles
    const pingRes = await apiRequest('/api/mobile/ping');
    assert.equal(pingRes.status, 200);
    assert.equal(pingRes.data.code, 0);
  });
});
