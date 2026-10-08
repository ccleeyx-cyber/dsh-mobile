/**
 * Tier 2 Boundary: Malformed JSON & Syntax Fault Tolerance Verification
 * Features: Broken JSON syntax, non-object JSON, empty body, array JSON, deeply nested structures
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';

describe('Tier 2 - Malformed JSON & Fault Tolerance', () => {

  it('TC1: POST with broken JSON syntax does not crash bridge process', async () => {
    const res = await apiRequest('/api/mobile/permissions', {
      method: 'POST',
      rawBody: '{"defaultPolicy": "auto-read", broken_syntax',
      headers: { 'Content-Type': 'application/json' }
    });

    // Bridge wraps JSON.parse in try-catch and returns response without crashing
    assert.ok(res.status === 200 || res.status === 400 || res.status === 500);
  });

  it('TC2: POST with primitive JSON string value ("pure string") handles safely', async () => {
    const res = await apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      rawBody: '"just a string without object keys"',
      headers: { 'Content-Type': 'application/json' }
    });

    assert.ok(res.status === 400 || res.status === 200);
  });

  it('TC3: POST with empty body (0 bytes) on JSON endpoint does not crash bridge', async () => {
    const res = await apiRequest('/api/mobile/permissions', {
      method: 'POST',
      rawBody: '',
      headers: { 'Content-Type': 'application/json' }
    });

    assert.ok(res.status === 200 || res.status === 400);
  });

  it('TC4: POST with JSON Array instead of expected Object is handled safely', async () => {
    const res = await apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      rawBody: '[{"sessionId": "test", "text": "hello"}]',
      headers: { 'Content-Type': 'application/json' }
    });

    assert.ok(res.status === 400 || res.status === 200);
  });

  it('TC5: POST with deeply nested JSON object does not trigger stack overflow', async () => {
    let deeplyNested = { val: 'leaf' };
    for (let i = 0; i < 70; i++) {
      deeplyNested = { child: deeplyNested };
    }

    const res = await apiRequest('/api/mobile/permissions', {
      method: 'POST',
      body: deeplyNested
    });

    assert.ok(res.status === 200 || res.status === 400);
  });
});
