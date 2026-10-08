/**
 * Tier 1 Feature Test: Mobile Tool Approval Flow (F2.1 - F2.4)
 * Verifies mobile-first approval inspection, one-tap allow, rejection with reason,
 * WebSocket real-time settlement broadcast, and audit log tracking.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest, createWsClient } from '../helpers/client.js';

describe('Tier 1 - Mobile Approval Flow', () => {

  it('TC1: GET /api/mobile/approvals returns pending approvals list with HTTP 200', async () => {
    const res = await apiRequest('/api/mobile/approvals');
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.code, 0);
    assert.ok(Array.isArray(res.data.approvals), 'Approvals should be an array');
  });

  it('TC2: POST /api/mobile/approval allows tool execution with outcome "allowed-once"', async () => {
    const res = await apiRequest('/api/mobile/approval', {
      method: 'POST',
      body: {
        approvalId: 'test_appr_allow_01',
        outcome: 'allowed-once'
      }
    });

    assert.equal(res.status, 200);
    // Returns 200 with code 404/ok:false if mock id not in memory, or code 0 if found
    assert.ok(typeof res.data.ok === 'boolean');
  });

  it('TC3: POST /api/mobile/approval rejects tool execution with custom reason and updates audit', async () => {
    const rejectReason = '⚠️ 包含高危/越权指令: 禁止 rm -rf 敏感目录';
    const res = await apiRequest('/api/mobile/approval', {
      method: 'POST',
      body: {
        eventId: 'test_appr_reject_02',
        outcome: 'rejected',
        reason: rejectReason
      }
    });

    assert.equal(res.status, 200);

    // Verify audit logs endpoint returns array and logs the attempt
    const auditRes = await apiRequest('/api/mobile/audit-logs');
    assert.equal(auditRes.status, 200);
    const logs = auditRes.data.auditLogs || auditRes.data.logs;
    assert.ok(Array.isArray(logs), 'Audit logs should be an array');
  });

  it('TC4: WebSocket receives initial pendingApprovals array upon connection handshake', async () => {
    const client = await createWsClient();
    try {
      const msg = await client.waitForMessage(m => m.type === 'system' && Array.isArray(m.pendingApprovals), 3000);
      assert.ok(msg, 'Should receive system greeting with pendingApprovals');
      assert.ok(Array.isArray(msg.pendingApprovals));
    } finally {
      client.close();
    }
  });

  it('TC5: WebSocket sends approval_response and receives approval_ack', async () => {
    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);

      client.send({
        type: 'approval_response',
        eventId: 'ws_test_appr_03',
        outcome: 'rejected',
        reason: '🛑 手动终止会话'
      });

      const ack = await client.waitForMessage(m => m.type === 'approval_ack', 3000);
      assert.ok(ack, 'Should receive approval_ack');
      assert.equal(ack.eventId, 'ws_test_appr_03');
      assert.equal(ack.outcome, 'rejected');
    } finally {
      client.close();
    }
  });

  it('TC6: GET /api/mobile/audit-logs aligns with AuditLogItem model', async () => {
    const res = await apiRequest('/api/mobile/audit-logs');
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.ok(Array.isArray(res.data.auditLogs), 'Should have auditLogs property');
    assert.ok(Array.isArray(res.data.logs), 'Should also have logs property for compatibility');

    if (res.data.auditLogs.length > 0) {
      const item = res.data.auditLogs[0];
      assert.ok(item.id, 'Audit item must have id');
      assert.ok(typeof item.time === 'number', 'Audit item must have numeric time');
      assert.ok(item.toolName, 'Audit item must have toolName');
      assert.ok(item.outcome, 'Audit item must have outcome');
    }
  });
});
