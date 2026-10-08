/**
 * Tier 1: Models & Settings Management Verification
 * Features: Query server settings, available models list, switch global model, switch session model
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';

describe('Tier 1 - Models & Settings', () => {

  it('TC1: GET /api/mobile/settings returns availableModels and currentModel', async () => {
    const res = await apiRequest('/api/mobile/settings');
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.code, 0);

    const settings = res.data.settings;
    assert.ok(settings, 'Settings object must exist');
    assert.ok(settings.currentModel, 'currentModel must exist');
    assert.ok(Array.isArray(settings.availableModels), 'availableModels must be an array');
    assert.ok(settings.availableModels.length > 0, 'availableModels must not be empty');
  });

  it('TC2: Available models array contains valid model items with id and name', async () => {
    const res = await apiRequest('/api/mobile/settings');
    const models = res.data.settings.availableModels;
    for (const m of models) {
      assert.ok(m.id, 'Model item must have an id');
      assert.ok(m.name, 'Model item must have a name');
    }
  });

  it('TC3: POST /api/mobile/settings/model updates default global model', async () => {
    const getRes = await apiRequest('/api/mobile/settings');
    const models = getRes.data.settings.availableModels;
    const targetModel = models[0].id;

    const res = await apiRequest('/api/mobile/settings/model', {
      method: 'POST',
      body: { model: targetModel }
    });

    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.code, 0);
  });

  it('TC4: POST /api/mobile/sessions/model updates model for specific session', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const firstWs = wsRes.data.workspaces.find(w => w.sessions && w.sessions.length > 0);
    const sId = firstWs.sessions[0].sessionId;

    const getRes = await apiRequest('/api/mobile/settings');
    const targetModel = getRes.data.settings.availableModels[0].id;

    const res = await apiRequest('/api/mobile/sessions/model', {
      method: 'POST',
      body: { sessionId: sId, model: targetModel }
    });

    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.code, 0);
  });

  it('TC5: GET /api/mobile/settings without token returns HTTP 401', async () => {
    const res = await apiRequest('/api/mobile/settings', { token: null });
    assert.equal(res.status, 401);
  });
});
