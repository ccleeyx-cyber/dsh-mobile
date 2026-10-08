/**
 * Tier 1: Health & Authentication Verification
 * Features: Health Check, Multi-header Token Authentication, Unauthenticated Rejection
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';
import { CONFIG } from '../helpers/fixtures.js';

describe('Tier 1 - Health & Authentication', () => {

  it('TC1: Unauthenticated GET /health returns HTTP 401 with code 401 and authenticated: false', async () => {
    const res = await apiRequest('/health', { token: null });
    assert.equal(res.status, 401, 'Health endpoint returns HTTP 401 for unauthenticated probes');
    assert.equal(res.data.ok, false);
    assert.equal(res.data.authenticated, false);
    assert.equal(res.data.code, 401);
    assert.equal(typeof res.data.name, 'string');
    assert.equal(res.data.port, 3088);
  });

  it('TC2: Authenticated GET /health with Authorization Bearer header returns code 0 and ok: true', async () => {
    const res = await apiRequest('/health', {
      headers: { 'Authorization': `Bearer ${CONFIG.VALID_TOKEN}` }
    });
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.authenticated, true);
    assert.equal(res.data.code, 0);
    assert.equal(res.data.port, 3088);
    assert.equal(typeof res.data.dshPort, 'number');
    assert.ok(res.data.time, 'Should contain ISO timestamp');
  });

  it('TC3: Authenticated GET /health with x-dsh-token header returns ok: true', async () => {
    const res = await apiRequest('/health', {
      token: null,
      headers: { 'x-dsh-token': CONFIG.VALID_TOKEN }
    });
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.authenticated, true);
    assert.equal(res.data.code, 0);
  });

  it('TC4: Authenticated GET /health with x-auth-code header returns ok: true', async () => {
    const res = await apiRequest('/health', {
      token: null,
      headers: { 'x-auth-code': CONFIG.VALID_TOKEN }
    });
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.authenticated, true);
    assert.equal(res.data.code, 0);
  });

  it('TC5: Authenticated GET /health with query parameter ?token= returns ok: true', async () => {
    const res = await apiRequest(`/health?token=${encodeURIComponent(CONFIG.VALID_TOKEN)}`, {
      token: null
    });
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.authenticated, true);
    assert.equal(res.data.code, 0);
  });

  it('TC6: GET /api/mobile/health returns valid health probe payload', async () => {
    const res = await apiRequest('/api/mobile/health');
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.authenticated, true);
  });

  it('TC7: GET /__mobile/health returns valid health probe payload', async () => {
    const res = await apiRequest('/__mobile/health');
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.authenticated, true);
  });
});
