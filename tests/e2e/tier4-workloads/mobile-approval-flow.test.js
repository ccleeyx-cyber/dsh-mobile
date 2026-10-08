/**
 * Tier 4 Workload 2: Mobile Tool Approval Workflow
 * Simulation of user inspecting pending tool approvals, authorizing or rejecting with reason, and auditing
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest, createWsClient } from '../helpers/client.js';

describe('Tier 4 Workload 2 - Mobile Tool Approval Workflow', () => {

  it('MW-2: End-to-end mobile approval inspection and response workflow', async () => {
    // Step 1: Connect WebSocket
    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);

      // Step 2: Query pending approvals badge count across tabs (F2.2)
      const approvalsRes = await apiRequest('/api/mobile/approvals');
      assert.equal(approvalsRes.status, 200);
      assert.ok(Array.isArray(approvalsRes.data.approvals));

      // Step 3: Handle approval response with optional rejection reason (F2.1)
      const respondRes = await apiRequest('/api/mobile/approval', {
        method: 'POST',
        body: {
          approvalId: 'appr_workload_test_01',
          outcome: 'reject',
          reason: 'Security policy violation: unauthorized directory write'
        }
      });
      assert.equal(respondRes.status, 200);

      // Step 4: Verify audit logs track approval events
      const auditRes = await apiRequest('/api/mobile/audit-logs');
      assert.equal(auditRes.status, 200);
      const logs = auditRes.data.logs || auditRes.data.auditLogs;
      assert.ok(Array.isArray(logs));
    } finally {
      client.close();
    }
  });
});
