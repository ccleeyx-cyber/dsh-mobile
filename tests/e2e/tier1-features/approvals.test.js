/**
 * Tier 1: Approvals Management Verification
 * Features: List pending approvals, authorize tool execution, reject with reason, WS approval response, unauthenticated rejection
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest, createWsClient } from '../helpers/client.js';

describe('Tier 1 - Approvals Management', () => {

  it('TC1: GET /api/mobile/approvals returns approvals list with HTTP 200', async () => {
    const res = await apiRequest('/api/mobile/approvals');
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.code, 0);
    assert.ok(Array.isArray(res.data.approvals), 'Approvals should be an array');
  });

  it('TC2: POST /api/mobile/approval with unknown approvalId returns error gracefully without crashing', async () => {
    const res = await apiRequest('/api/mobile/approval', {
      method: 'POST',
      body: {
        approvalId: 'non-existent-appr-999',
        outcome: 'allow'
      }
    });

    assert.equal(res.status, 200);
    assert.equal(res.data.ok, false);
    assert.ok(res.data.error, 'Should return error indicating approval not found');
  });

  it('TC3: POST /api/mobile/approval accepts outcome: "reject" and optional reason string', async () => {
    const res = await apiRequest('/api/mobile/approval', {
      method: 'POST',
      body: {
        approvalId: 'non-existent-appr-888',
        outcome: 'reject',
        reason: 'User refused destructive file modification'
      }
    });

    assert.equal(res.status, 200);
    // Since approvalId does not exist, it returns ok: false without crashing
    assert.equal(res.data.ok, false);
  });

  it('TC4: WebSocket sends approval_response and receives acknowledgement or processes cleanly', async () => {
    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);
      // Send approval_response over WebSocket
      client.send({
        type: 'approval_response',
        approvalId: 'test_appr_001',
        outcome: 'allow'
      });

      // Allow brief time for server processing
      await new Promise(r => setTimeout(r, 200));
      assert.ok(client.errors.length === 0, 'WebSocket should remain healthy');
    } finally {
      client.close();
    }
  });

  it('TC5: GET /api/mobile/approvals without authorization returns HTTP 401', async () => {
    const res = await apiRequest('/api/mobile/approvals', { token: null });
    assert.equal(res.status, 401);
  });
});
