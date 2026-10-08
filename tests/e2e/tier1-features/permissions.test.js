/**
 * Tier 1: Permissions & Execution Policies Verification
 * Features: Query permissions, Update execution policy, Sandbox mode, Git protection, Session override
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';

describe('Tier 1 - Permissions & Security Policies', () => {

  it('TC1: GET /api/mobile/permissions returns execution policy configuration', async () => {
    const res = await apiRequest('/api/mobile/permissions');
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.code, 0);

    const perms = res.data.permissions;
    assert.ok(perms, 'Permissions object must exist');
    assert.ok(perms.defaultPolicy || perms.executionPolicy);
    assert.equal(typeof perms.sandboxMode, 'string');
    assert.equal(typeof perms.maxSteps, 'number');
    assert.equal(typeof perms.protectGit, 'boolean');
  });

  it('TC2: POST /api/mobile/permissions updates execution policy atomically', async () => {
    // Read original
    const getRes = await apiRequest('/api/mobile/permissions');
    const origPolicy = getRes.data.permissions.executionPolicy || 'auto-read';

    const testPolicy = origPolicy === 'auto-read' ? 'ask' : 'auto-read';

    // Update to new policy
    const updateRes = await apiRequest('/api/mobile/permissions', {
      method: 'POST',
      body: { defaultPolicy: testPolicy }
    });

    assert.equal(updateRes.status, 200);
    assert.equal(updateRes.data.ok, true);
    assert.equal(updateRes.data.permissions.executionPolicy, testPolicy);

    // Restore original policy
    await apiRequest('/api/mobile/permissions', {
      method: 'POST',
      body: { defaultPolicy: origPolicy }
    });
  });

  it('TC3: POST /api/mobile/permissions toggles protectGit security setting', async () => {
    const getRes = await apiRequest('/api/mobile/permissions');
    const origProtect = getRes.data.permissions.protectGit;

    const toggled = !origProtect;
    const updateRes = await apiRequest('/api/mobile/permissions', {
      method: 'POST',
      body: { protectGit: toggled }
    });

    assert.equal(updateRes.status, 200);
    assert.equal(updateRes.data.permissions.protectGit, toggled);

    // Restore original
    await apiRequest('/api/mobile/permissions', {
      method: 'POST',
      body: { protectGit: origProtect }
    });
  });

  it('TC4: POST /api/mobile/permissions updates maxSteps execution limit', async () => {
    const getRes = await apiRequest('/api/mobile/permissions');
    const origSteps = getRes.data.permissions.maxSteps;

    const testSteps = 45;
    const updateRes = await apiRequest('/api/mobile/permissions', {
      method: 'POST',
      body: { maxSteps: testSteps }
    });

    assert.equal(updateRes.status, 200);
    assert.equal(updateRes.data.permissions.maxSteps, testSteps);

    // Restore original
    await apiRequest('/api/mobile/permissions', {
      method: 'POST',
      body: { maxSteps: origSteps }
    });
  });

  it('TC5: POST /api/mobile/sessions/permission overrides policy for specific session', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const firstWs = wsRes.data.workspaces.find(w => w.sessions && w.sessions.length > 0);
    const sId = firstWs.sessions[0].sessionId;

    const res = await apiRequest('/api/mobile/sessions/permission', {
      method: 'POST',
      body: { sessionId: sId, policy: 'danger-full-access' }
    });

    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.sessionId, sId);
    assert.equal(res.data.policy, 'danger-full-access');
  });

  it('TC6: GET /api/mobile/permissions without token returns HTTP 401', async () => {
    const res = await apiRequest('/api/mobile/permissions', { token: null });
    assert.equal(res.status, 401);
  });
});
