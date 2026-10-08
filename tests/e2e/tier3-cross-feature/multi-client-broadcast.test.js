/**
 * Tier 3 Cross-Feature: Multi-Client Concurrent Broadcast Verification
 * Pairwise: Multiple active mobile clients, broadcast fanout, client isolation on disconnect
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest, createWsClient } from '../helpers/client.js';

describe('Tier 3 - Multi-Client Concurrent Broadcast', () => {

  it('TC1: Multiple mobile clients connect simultaneously and receive greetings', async () => {
    const client1 = await createWsClient();
    const client2 = await createWsClient();

    try {
      const [g1, g2] = await Promise.all([
        client1.waitForMessage(m => m.type === 'connected', 3000),
        client2.waitForMessage(m => m.type === 'connected', 3000)
      ]);

      assert.equal(g1.type, 'connected');
      assert.equal(g2.type, 'connected');
    } finally {
      client1.close();
      client2.close();
    }
  });

  it('TC2: Session event broadcast reaches all connected mobile clients', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId: targetWs.workspaceId }
    });
    const sId = sRes.data.sessionId;

    const client1 = await createWsClient();
    const client2 = await createWsClient();

    try {
      await Promise.all([
        client1.waitForMessage(m => m.type === 'connected', 3000),
        client2.waitForMessage(m => m.type === 'connected', 3000)
      ]);

      // Both subscribe
      client1.send({ type: 'subscribe_session', sessionId: sId });
      client2.send({ type: 'subscribe_session', sessionId: sId });

      // Trigger session cancellation broadcast
      const cancelPromise = apiRequest('/api/mobile/sessions/cancel', {
        method: 'POST',
        body: { sessionId: sId }
      });

      const wait1 = client1.waitForMessage(
        m => m.type === 'session_status' && m.sessionId === sId,
        3000
      );
      const wait2 = client2.waitForMessage(
        m => m.type === 'session_status' && m.sessionId === sId,
        3000
      );

      const [res, msg1, msg2] = await Promise.all([cancelPromise, wait1, wait2]);

      assert.equal(res.status, 200);
      assert.equal(msg1.sessionId, sId);
      assert.equal(msg2.sessionId, sId);
    } finally {
      client1.close();
      client2.close();
      await apiRequest('/api/mobile/sessions/delete', {
        method: 'POST',
        body: { sessionId: sId, workspaceId: targetWs.workspaceId }
      });
    }
  });

  it('TC3: Client A disconnect does not affect Client B active connection', async () => {
    const client1 = await createWsClient();
    const client2 = await createWsClient();

    try {
      await Promise.all([
        client1.waitForMessage(m => m.type === 'connected', 3000),
        client2.waitForMessage(m => m.type === 'connected', 3000)
      ]);

      // Client 1 closes abruptly
      client1.close();

      // Client 2 sends ping and receives pong
      client2.send({ type: 'ping' });
      const pong = await client2.waitForMessage(m => m.type === 'pong', 2000);
      assert.equal(pong.type, 'pong');
    } finally {
      client2.close();
    }
  });
});
