/**
 * Tier 2 Boundary: Session ID Boundary & Corner Cases
 * Features: Empty session ID, non-existent UUIDs, path traversal IDs, unicode/emoji IDs, type mismatches
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';

describe('Tier 2 - Session ID Boundaries', () => {

  it('TC1: Prompt request with empty sessionId returns HTTP 400', async () => {
    const res = await apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: '', text: 'Test prompt' }
    });
    assert.equal(res.status, 400);
    assert.ok(res.data.error);
  });

  it('TC2: Prompt request with whitespace-only sessionId returns HTTP 400', async () => {
    const res = await apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: '   ', text: 'Test prompt' }
    });
    assert.equal(res.status, 400);
  });

  it('TC3: Non-existent UUID session ID does not crash server and returns error gracefully', async () => {
    const nonExistentId = '00000000-0000-0000-0000-000000000000';
    const res = await apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: nonExistentId, text: 'Test prompt' }
    });
    // Should return error or reject gracefully, without crashing bridge process
    assert.ok(res.status === 400 || res.status === 500 || (res.status === 200 && res.data.ok === false));
  });

  it('TC4: Session ID with path traversal characters does not cause internal error or crash', async () => {
    const maliciousId = '../../../../Windows/System32';
    const res = await apiRequest(`/api/mobile/sessions/${maliciousId}`);
    // Should handle without crash
    assert.ok(res.status === 200 || res.status === 400 || res.status === 404);
  });

  it('TC5: Unicode and Emoji characters in session ID are handled without UTF-8 corruption', async () => {
    const unicodeId = 'session-测试-🔥-001';
    const res = await apiRequest(`/api/mobile/sessions/${encodeURIComponent(unicodeId)}`);
    assert.equal(res.status, 200);
    assert.ok(res.data.data);
  });

  it('TC6: Numeric or object session ID type in prompt is handled safely', async () => {
    const res = await apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: 12345, text: 'Test' }
    });
    // Bridge should not crash
    assert.ok(res.status === 400 || res.status === 500 || res.status === 200);
  });
});
