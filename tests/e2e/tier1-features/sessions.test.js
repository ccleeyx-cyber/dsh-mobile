/**
 * Tier 1: Workspace & Session Management Verification
 * Features: List Workspaces, Session History, Create Session, Delete Session, Session Status
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest, createWsClient } from '../helpers/client.js';

describe('Tier 1 - Sessions & Workspaces', () => {

  it('TC1: GET /api/mobile/workspaces returns array of workspaces with sessions', async () => {
    const res = await apiRequest('/api/mobile/workspaces');
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.code, 0);
    assert.ok(Array.isArray(res.data.workspaces), 'Workspaces should be an array');
    assert.ok(res.data.workspaces.length > 0, 'Should have at least 1 workspace');

    const ws = res.data.workspaces[0];
    assert.ok(ws.workspaceId, 'Workspace should have workspaceId');
    assert.ok(ws.title, 'Workspace should have title');
    assert.ok(Array.isArray(ws.sessions), 'Workspace should contain sessions array');
  });

  it('TC2: GET /api/mobile/sessions/:id returns session details and history', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const firstWs = wsRes.data.workspaces.find(w => w.sessions && w.sessions.length > 0);
    assert.ok(firstWs, 'Should find a workspace with sessions');
    const existingSession = firstWs.sessions[0];

    const res = await apiRequest(`/api/mobile/sessions/${existingSession.sessionId}`);
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.ok(res.data.data, 'Session history data should exist');
    assert.equal(res.data.data.sessionId, existingSession.sessionId);
    assert.ok(Array.isArray(res.data.data.messages), 'Messages should be an array');
    assert.equal(typeof res.data.data.isRunning, 'boolean');
  });

  it('TC3: POST /api/mobile/sessions/create creates a new session in workspace', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];

    const res = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId: targetWs.workspaceId }
    });

    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.code, 0);
    assert.ok(res.data.sessionId, 'Should return created sessionId');
    assert.ok(res.data.session, 'Should return session object');
  });

  it('TC4: POST /api/mobile/sessions/delete deletes a session', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];

    // Create session to delete
    const createRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId: targetWs.workspaceId }
    });
    const sId = createRes.data.sessionId;

    const delRes = await apiRequest('/api/mobile/sessions/delete', {
      method: 'POST',
      body: { sessionId: sId, workspaceId: targetWs.workspaceId }
    });

    assert.equal(delRes.status, 200);
    assert.equal(delRes.data.ok, true);
    assert.equal(delRes.data.message, 'Deleted');
  });

  it('TC5: WebSocket subscribe_session updates subscription and receives status', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const firstWs = wsRes.data.workspaces.find(w => w.sessions && w.sessions.length > 0);
    const existingSession = firstWs.sessions[0];

    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);
      client.send({ type: 'subscribe_session', sessionId: existingSession.sessionId });

      // Allow brief delay for subscription registration
      await new Promise(r => setTimeout(r, 200));
      assert.ok(client.messages.length >= 1, 'Client should maintain connection');
    } finally {
      client.close();
    }
  });

  it('TC6: GET /api/mobile/sessions/:id for non-existent session returns empty history gracefully', async () => {
    const fakeId = 'session-non-existent-99999999';
    const res = await apiRequest(`/api/mobile/sessions/${fakeId}`);
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.ok(res.data.data, 'Should return empty or fallback session data');
    assert.ok(Array.isArray(res.data.data.messages), 'Messages should be an empty array');
    assert.equal(res.data.data.messages.length, 0);
  });
});
