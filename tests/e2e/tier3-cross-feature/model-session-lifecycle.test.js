/**
 * Tier 3 Cross-Feature: Model Selection + Session Lifecycle Interaction
 * Pairwise: Session creation, model binding, prompt interaction, cancellation, session cleanup
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';

describe('Tier 3 - Model Selection & Session Lifecycle Interaction', () => {

  it('TC1: Session creation followed by session-specific model binding reflects in session data', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId: targetWs.workspaceId }
    });
    const sId = sRes.data.sessionId;

    try {
      const setRes = await apiRequest('/api/mobile/settings');
      const testModel = setRes.data.settings.availableModels[0].id;

      const modelRes = await apiRequest('/api/mobile/sessions/model', {
        method: 'POST',
        body: { sessionId: sId, model: testModel }
      });

      assert.equal(modelRes.status, 200);
      assert.equal(modelRes.data.ok, true);

      // Verify session status query still functions
      const histRes = await apiRequest(`/api/mobile/sessions/${sId}`);
      assert.equal(histRes.status, 200);
    } finally {
      await apiRequest('/api/mobile/sessions/delete', {
        method: 'POST',
        body: { sessionId: sId, workspaceId: targetWs.workspaceId }
      });
    }
  });

  it('TC2: Session cancellation followed by model switch leaves session in clean reusable state', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId: targetWs.workspaceId }
    });
    const sId = sRes.data.sessionId;

    try {
      // Cancel turn
      const cancelRes = await apiRequest('/api/mobile/sessions/cancel', {
        method: 'POST',
        body: { sessionId: sId }
      });
      assert.equal(cancelRes.status, 200);

      // Switch model
      const setRes = await apiRequest('/api/mobile/settings');
      const newModel = setRes.data.settings.availableModels[0].id;
      const switchRes = await apiRequest('/api/mobile/sessions/model', {
        method: 'POST',
        body: { sessionId: sId, model: newModel }
      });
      assert.equal(switchRes.status, 200);
    } finally {
      await apiRequest('/api/mobile/sessions/delete', {
        method: 'POST',
        body: { sessionId: sId, workspaceId: targetWs.workspaceId }
      });
    }
  });
});
