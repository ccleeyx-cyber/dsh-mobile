/**
 * Tier 1: Prompt Submission & Turn Cancellation Verification
 * Features: Missing field validations, prompt submission, prompt cancellation, session_status broadcast
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest, createWsClient } from '../helpers/client.js';

describe('Tier 1 - Prompt & Cancel', () => {

  it('TC1: POST /api/mobile/sessions/prompt with missing sessionId returns HTTP 400', async () => {
    const res = await apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { text: 'Hello' }
    });
    assert.equal(res.status, 400);
    assert.ok(res.data.error, 'Should contain error message');
  });

  it('TC2: POST /api/mobile/sessions/prompt with missing text returns HTTP 400', async () => {
    const res = await apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: 'test-session-id' }
    });
    assert.equal(res.status, 400);
    assert.ok(res.data.error, 'Should contain error message');
  });

  it('TC3: POST /api/mobile/sessions/cancel with valid session returns HTTP 200 and message: "Cancelled"', async () => {
    // Create temporary session
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId: targetWs.workspaceId }
    });
    const sId = sRes.data.sessionId;

    const res = await apiRequest('/api/mobile/sessions/cancel', {
      method: 'POST',
      body: { sessionId: sId }
    });

    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.message, 'Cancelled');

    // Clean up
    await apiRequest('/api/mobile/sessions/delete', {
      method: 'POST',
      body: { sessionId: sId, workspaceId: targetWs.workspaceId }
    });
  });

  it('TC4: Cancelling turn broadcasts session_status isRunning: false to connected clients (F1.5)', async () => {
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

      // Cancel turn
      const cancelPromise = apiRequest('/api/mobile/sessions/cancel', {
        method: 'POST',
        body: { sessionId: sId }
      });

      const [cancelRes, statusMsg] = await Promise.all([
        cancelPromise,
        client.waitForMessage(
          m => m.type === 'session_status' && m.sessionId === sId && m.isRunning === false,
          3000
        )
      ]);

      assert.equal(cancelRes.status, 200);
      assert.equal(statusMsg.isRunning, false);
      assert.equal(statusMsg.sessionId, sId);
    } finally {
      client.close();
      await apiRequest('/api/mobile/sessions/delete', {
        method: 'POST',
        body: { sessionId: sId, workspaceId: targetWs.workspaceId }
      });
    }
  });

  it('TC5: POST /api/mobile/sessions/cancel on idle session does not crash and returns 200', async () => {
    const res = await apiRequest('/api/mobile/sessions/cancel', {
      method: 'POST',
      body: { sessionId: 'non-active-session-id' }
    });
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.message, 'Cancelled');
  });

  it('TC6: Cancelling an active turn terminates execution, broadcasts isRunning: false and done without orphaned stream state', async () => {
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

      // 1. Submit active prompt
      const promptRes = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: { sessionId: sId, text: 'Active turn test prompt' }
      });
      assert.equal(promptRes.status, 200);
      assert.equal(promptRes.data.ok, true);

      // 2. Wait for isRunning: true
      await client.waitForMessage(
        m => m.type === 'session_status' && m.sessionId === sId && m.isRunning === true,
        3000
      );

      // 3. Cancel active turn
      const cancelRes = await apiRequest('/api/mobile/sessions/cancel', {
        method: 'POST',
        body: { sessionId: sId }
      });
      assert.equal(cancelRes.status, 200);
      assert.equal(cancelRes.data.ok, true);

      // 4. Verify terminal status and done event
      const statusMsg = await client.waitForMessage(
        m => m.type === 'session_status' && m.sessionId === sId && m.isRunning === false,
        3000
      );
      assert.equal(statusMsg.isRunning, false);

      const doneMsg = await client.waitForMessage(
        m => m.type === 'done' && m.sessionId === sId,
        3000
      );
      assert.ok(doneMsg, 'Done event must be received');
    } finally {
      client.close();
      await apiRequest('/api/mobile/sessions/delete', {
        method: 'POST',
        body: { sessionId: sId, workspaceId: targetWs.workspaceId }
      });
    }
  });

  it('TC7: Prompt error path cleans up activePrompts and broadcasts session_status isRunning: false with error and done', async () => {
    const client = await createWsClient();
    const errSessionId = 'non-existent-session-' + Date.now();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);
      client.send({ type: 'subscribe_session', sessionId: errSessionId });

      const promptRes = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: { sessionId: errSessionId, text: 'Error prompt' }
      });
      assert.equal(promptRes.status, 500);

      const statusMsg = await client.waitForMessage(
        m => m.type === 'session_status' && m.sessionId === errSessionId && m.isRunning === false,
        3000
      );
      assert.equal(statusMsg.isRunning, false);

      const errorMsg = await client.waitForMessage(
        m => m.type === 'error' && m.sessionId === errSessionId,
        3000
      );
      assert.ok(errorMsg, 'Error event must be broadcast');

      const doneMsg = await client.waitForMessage(
        m => m.type === 'done' && m.sessionId === errSessionId,
        3000
      );
      assert.ok(doneMsg, 'Done event must be broadcast');
    } finally {
      client.close();
    }
  });

  it('TC8: Rapid concurrent prompt-then-cancel sequence fencing guarantees final isRunning: false', async () => {
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

      // Concurrently launch prompt and cancel
      const promptPromise = apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: { sessionId: sId, text: 'Concurrent rapid prompt' }
      });
      const cancelPromise = apiRequest('/api/mobile/sessions/cancel', {
        method: 'POST',
        body: { sessionId: sId }
      });

      const [pRes, cRes] = await Promise.all([promptPromise, cancelPromise]);
      assert.equal(pRes.status, 200);
      assert.equal(cRes.status, 200);

      // Wait for socket events to settle
      await new Promise(r => setTimeout(r, 500));

      const statusEvents = client.messages
        .filter(m => m.sessionId === sId && m.type === 'session_status')
        .map(m => m.isRunning);

      const finalStatus = statusEvents[statusEvents.length - 1];
      assert.equal(finalStatus, false, 'Final session status under rapid cancel must be isRunning: false');
    } finally {
      client.close();
      await apiRequest('/api/mobile/sessions/delete', {
        method: 'POST',
        body: { sessionId: sId, workspaceId: targetWs.workspaceId }
      });
    }
  });
});
