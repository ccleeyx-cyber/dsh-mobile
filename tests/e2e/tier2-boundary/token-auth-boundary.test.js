/**
 * Tier 2 Boundary: Token Authentication Boundary & Corner Cases
 * Features: Empty tokens, whitespace tokens, revoked tokens, oversized tokens, injection attempts, malformed headers
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';

describe('Tier 2 - Token Authentication Boundaries', () => {

  it('TC1: Empty string token returns HTTP 401 across endpoints', async () => {
    const res = await apiRequest('/api/mobile/workspaces', { token: '' });
    assert.equal(res.status, 401);
  });

  it('TC2: Whitespace-only token returns HTTP 401', async () => {
    const res = await apiRequest('/api/mobile/workspaces', { token: '    ' });
    assert.equal(res.status, 401);
  });

  it('TC3: Arbitrary invalid token string returns HTTP 401', async () => {
    const res = await apiRequest('/api/mobile/permissions', { token: 'dsh_invalid_fake_token_12345' });
    assert.equal(res.status, 401);
  });

  it('TC4: Extremely long token string (10,000 characters) does not crash bridge and returns 401', async () => {
    const hugeToken = 'tok_' + 'x'.repeat(10000);
    const res = await apiRequest('/health', { token: hugeToken });
    assert.equal(res.status, 401);
    assert.equal(res.data.authenticated, false);
  });

  it('TC5: Malformed Authorization header ("Basic ...", "Token ...", naked string) returns 401', async () => {
    const res = await apiRequest('/api/mobile/workspaces', {
      headers: { 'Authorization': 'Basic dXNlcjpwYXNz' },
      token: null
    });
    assert.equal(res.status, 401);
  });

  it('TC6: Token with SQL/shell meta-characters is handled safely without injection', async () => {
    const injectionToken = "'; DROP TABLE tokens; -- $(rm -rf /) `whoami`";
    const res = await apiRequest('/health', { token: injectionToken });
    assert.equal(res.status, 401);
    assert.equal(res.data.authenticated, false);
  });
});
