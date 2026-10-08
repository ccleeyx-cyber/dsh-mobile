/**
 * Challenger M2-1 Stress Test Suite
 * Stress-testing Milestone M2: Approval & Permission Control Stream
 *
 * Scope:
 * 1. Concurrent approval responses & race conditions (HTTP & WS)
 * 2. Duplicate approval response idempotency for settled events
 * 3. Invalid eventIds, boundary strings, SQLi/XSS, extreme payloads
 * 4. Outcome normalization & fail-closed security invariants
 * 5. Clean approval_settled broadcast fanout across multiple clients
 * 6. Pending queue consistency through arrival, settlement, and cancellation
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import wsPkg from './../dsh-server-plugin/node_modules/ws/index.js';
const { WebSocketServer } = wsPkg.default || wsPkg;

import { apiRequest, createWsClient } from './e2e/helpers/client.js';
import { CONFIG } from './e2e/helpers/fixtures.js';

// =========================================================================
// SUITE 1: Invalid eventIds and Malformed Payloads Stress
// =========================================================================
describe('M2 Stress 1: Invalid eventIds & Boundary Payloads', () => {

  it('TC1.1: Missing or null eventId returns HTTP 400', async () => {
    // Empty string
    const resEmpty = await apiRequest('/api/mobile/approval', {
      method: 'POST',
      body: { eventId: '', outcome: 'allowed-once' }
    });
    assert.equal(resEmpty.status, 400);
    assert.equal(resEmpty.data.ok, false);

    // Null eventId
    const resNull = await apiRequest('/api/mobile/approval', {
      method: 'POST',
      body: { eventId: null, outcome: 'allowed-once' }
    });
    assert.equal(resNull.status, 400);
    assert.equal(resNull.data.ok, false);

    // Completely omitted eventId
    const resOmitted = await apiRequest('/api/mobile/approval', {
      method: 'POST',
      body: { outcome: 'allowed-once' }
    });
    assert.equal(resOmitted.status, 400);
    assert.equal(resOmitted.data.ok, false);
  });

  it('TC1.2: Missing or null outcome returns HTTP 400', async () => {
    const resEmptyOutcome = await apiRequest('/api/mobile/approval', {
      method: 'POST',
      body: { eventId: 'test_appr_01', outcome: '' }
    });
    assert.equal(resEmptyOutcome.status, 400);
    assert.equal(resEmptyOutcome.data.ok, false);

    const resNullOutcome = await apiRequest('/api/mobile/approval', {
      method: 'POST',
      body: { eventId: 'test_appr_01', outcome: null }
    });
    assert.equal(resNullOutcome.status, 400);
    assert.equal(resNullOutcome.data.ok, false);
  });

  it('TC1.3: Non-existent eventId returns HTTP 200 with ok: false & code: 404 without crashing', async () => {
    const res = await apiRequest('/api/mobile/approval', {
      method: 'POST',
      body: {
        eventId: 'non_existent_appr_xyz_999',
        outcome: 'allowed-once'
      }
    });
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, false);
    assert.equal(res.data.code, 404);
    assert.ok(res.data.error.includes('not found or expired'));
  });

  it('TC1.4: Extreme string sizes and boundary inputs for eventId do not crash the gateway', async () => {
    const boundaryInputs = [
      'A'.repeat(10000), // 10k characters
      "'; DROP TABLE pending_approvals; --", // SQL injection style
      '../../../../../../etc/passwd', // Path traversal style
      '<script>alert("xss")</script>', // XSS style
      '审批_安全_测试_🆔_🚀🔥_2026', // Unicode & Emoji
      '   \t\r\n   ', // Whitespace
      '{"nested": true, "eventId": "inner"}' // JSON-like string
    ];

    for (const testId of boundaryInputs) {
      const res = await apiRequest('/api/mobile/approval', {
        method: 'POST',
        body: {
          eventId: testId,
          outcome: 'rejected',
          reason: 'Stress testing boundary eventId'
        }
      });
      assert.equal(res.status, 200, `Expected HTTP 200 for eventId length ${testId.length}`);
      assert.equal(res.data.ok, false);
      assert.equal(res.data.code, 404);
    }
  });

  it('TC1.5: WebSocket handling of invalid / non-existent eventId returns approval_ack with ok: false', async () => {
    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);

      client.send({
        type: 'approval_response',
        eventId: 'ws_stress_nonexistent_888',
        outcome: 'allowed-once'
      });

      const ack = await client.waitForMessage(m => m.type === 'approval_ack', 3000);
      assert.ok(ack, 'Must receive approval_ack');
      assert.equal(ack.eventId, 'ws_stress_nonexistent_888');
      assert.equal(ack.ok, false);
      assert.equal(ack.outcome, 'allowed-once');

      // Verify WebSocket connection remains active
      client.send({ type: 'ping' });
      const pong = await client.waitForMessage(m => m.type === 'pong', 3000);
      assert.ok(pong, 'WebSocket should remain fully responsive after error handling');
    } finally {
      client.close();
    }
  });
});

// =========================================================================
// SUITE 2: Outcome Normalization and Fail-Closed Invariants
// =========================================================================
describe('M2 Stress 2: Outcome Normalization & Fail-Closed Guard', () => {

  it('TC2.1: Normalizes outcome aliases (allow, allowed-once, approve -> allowed-once; reject, rejected -> rejected)', async () => {
    const testCases = [
      { input: 'allow', expected: 'allowed-once' },
      { input: 'allowed-once', expected: 'allowed-once' },
      { input: 'approve', expected: 'allowed-once' },
      { input: 'reject', expected: 'rejected' },
      { input: 'rejected', expected: 'rejected' },
      { input: 'unrecognized_wildcard_bypass', expected: 'rejected' } // Fail-closed default!
    ];

    for (const tc of testCases) {
      const res = await apiRequest('/api/mobile/approval', {
        method: 'POST',
        body: {
          eventId: `test_norm_${tc.input}`,
          outcome: tc.input
        }
      });

      assert.equal(res.status, 200);
      assert.equal(res.data.outcome, tc.expected, `Outcome '${tc.input}' must normalize to '${tc.expected}'`);
    }
  });
});

// =========================================================================
// SUITE 3: High-Concurrency Burst & Dual-Transport Race Stress
// =========================================================================
describe('M2 Stress 3: High-Concurrency Burst & Dual-Transport Race', () => {

  it('TC3.1: 50 concurrent HTTP POST approval responses execute cleanly in parallel', async () => {
    const count = 50;
    const promises = [];

    const startTime = Date.now();
    for (let i = 0; i < count; i++) {
      promises.push(
        apiRequest('/api/mobile/approval', {
          method: 'POST',
          body: {
            eventId: `burst_appr_${i}_${Date.now()}`,
            outcome: i % 2 === 0 ? 'allow' : 'reject',
            reason: `Burst test concurrent call ${i}`
          }
        })
      );
    }

    const results = await Promise.all(promises);
    const duration = Date.now() - startTime;

    assert.equal(results.length, count);
    for (const res of results) {
      assert.equal(res.status, 200);
      assert.equal(res.data.ok, false);
      assert.equal(res.data.code, 404);
    }
    assert.ok(duration < 5000, `50 concurrent requests took ${duration}ms, expected <5000ms`);
  });

  it('TC3.2: 50 concurrent requests targeting the EXACT SAME eventId handle duplicate settlement gracefully', async () => {
    const targetEventId = `same_target_${Date.now()}`;
    const count = 50;
    const promises = [];

    for (let i = 0; i < count; i++) {
      promises.push(
        apiRequest('/api/mobile/approval', {
          method: 'POST',
          body: {
            eventId: targetEventId,
            outcome: 'allowed-once',
            reason: `Race condition test duplicate call ${i}`
          }
        })
      );
    }

    const results = await Promise.all(promises);
    assert.equal(results.length, count);
    for (const res of results) {
      assert.equal(res.status, 200);
      assert.equal(res.data.ok, false);
      assert.equal(res.data.code, 404);
      assert.equal(res.data.eventId, targetEventId);
    }
  });

  it('TC3.3: Dual-transport race (simulating Flutter respondApproval: WS and HTTP fired concurrently)', async () => {
    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);

      const targetId = `dual_transport_race_${Date.now()}`;

      // 1. Dispatch WS approval_response
      client.send({
        type: 'approval_response',
        eventId: targetId,
        outcome: 'allowed-once'
      });

      // 2. Concurrently dispatch HTTP POST
      const httpPromise = apiRequest('/api/mobile/approval', {
        method: 'POST',
        body: {
          eventId: targetId,
          outcome: 'allowed-once'
        }
      });

      const [ack, httpRes] = await Promise.all([
        client.waitForMessage(m => m.type === 'approval_ack' && m.eventId === targetId, 3000),
        httpPromise
      ]);

      assert.ok(ack, 'WebSocket ACK must be received');
      assert.equal(ack.eventId, targetId);
      assert.equal(httpRes.status, 200);
      // Both transport handlers completed safely without crash or deadlock
    } finally {
      client.close();
    }
  });
});

// =========================================================================
// SUITE 4: Full End-to-End Approval Lifecycle, Broadcast Fanout & Pending Queue
// (Component test running isolated bridge with Mock Upstream MUX)
// =========================================================================
describe('M2 Stress 4: Full Lifecycle, Broadcast Fanout & Queue Consistency', () => {
  let mockMuxServer;
  let mockMuxWsClient = null;
  let effectTeardown = null;
  const TEST_BRIDGE_PORT = 3098;
  const TEST_MUX_PORT = 3099;
  const authHeaders = {
    'Authorization': `Bearer ${CONFIG.VALID_TOKEN}`,
    'Content-Type': 'application/json'
  };

  before(async () => {
    // 1. Start Mock Upstream MUX Server on TEST_MUX_PORT
    mockMuxServer = new WebSocketServer({ port: TEST_MUX_PORT });
    mockMuxServer.on('connection', (ws) => {
      mockMuxWsClient = ws;
      ws.on('message', (raw) => {
        try {
          const msg = JSON.parse(raw.toString());
          if (msg.type === 'open' && msg.endpoint === '$events') {
            // Send ready frame with clientId
            ws.send(JSON.stringify({
              type: 'item',
              streamId: msg.streamId || 'gw-events-stream',
              value: { type: 'ready', clientId: 'mock-upstream-client-01' }
            }));
          }
        } catch (_) {}
      });
    });

    // 2. Import and start bridge plugin instance
    const bridgeModule = await import('../dsh-server-plugin/lib/index.js');
    const mockCtx = {
      logger: () => ({
        info: () => {},
        warn: () => {},
        error: () => {}
      }),
      effect: (fn) => {
        effectTeardown = fn();
      }
    };

    bridgeModule.apply(mockCtx, {
      port: TEST_BRIDGE_PORT,
      dshPort: TEST_MUX_PORT
    }, {
      port: TEST_BRIDGE_PORT,
      dshPort: TEST_MUX_PORT
    });

    // Allow time for upstream connection establishment
    await new Promise((r) => setTimeout(r, 600));
  });

  after(async () => {
    if (effectTeardown) {
      try { await effectTeardown(); } catch (_) {}
    }
    try { mockMuxServer?.close(); } catch (_) {}
    // No forced process.exit() here: it would terminate the whole runner when this
    // file is executed together with others (npm test), and mask the exit code.
    // The teardowns above release the lingering bridge/MUX handles instead.
  });

  it('TC4.1: Upstream approval/request frame populates queue and broadcasts approval_request', async () => {
    assert.ok(mockMuxWsClient, 'Mock MUX should have accepted upstream bridge connection');

    const wsUrl = `ws://127.0.0.1:${TEST_BRIDGE_PORT}/mobile-ws?token=${CONFIG.VALID_TOKEN}`;
    const c1 = await createWsClient({ customUrl: wsUrl });
    const c2 = await createWsClient({ customUrl: wsUrl });

    try {
      await Promise.all([
        c1.waitForMessage(m => m.type === 'connected', 3000),
        c2.waitForMessage(m => m.type === 'connected', 3000)
      ]);

      // Verify initial pending queue is empty
      const initQueueRes = await fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/api/mobile/approvals`, { headers: authHeaders });
      const initQueue = await initQueueRes.json();
      assert.equal(initQueue.ok, true);
      assert.equal(initQueue.approvals.length, 0);

      // Inject upstream approval/request via Mock MUX
      const testApprovalId = 'appr_lifecycle_stress_101';
      mockMuxWsClient.send(JSON.stringify({
        type: 'item',
        streamId: 'gw-events-stream',
        value: {
          type: 'request',
          event: 'approval/request',
          id: testApprovalId,
          agent: 'session-test-01',
          request: {
            toolName: 'bash',
            reason: 'Execute rm -rf /tmp/test-dir',
            input: 'rm -rf /tmp/test-dir',
            callId: 'call_9901'
          }
        }
      }));

      // Both mobile clients must receive approval_request broadcast
      const [msg1, msg2] = await Promise.all([
        c1.waitForMessage(m => m.type === 'approval_request' && m.approval?.id === testApprovalId, 3000),
        c2.waitForMessage(m => m.type === 'approval_request' && m.approval?.id === testApprovalId, 3000)
      ]);

      assert.ok(msg1, 'Client 1 should receive approval_request');
      assert.ok(msg2, 'Client 2 should receive approval_request');
      assert.equal(msg1.approval.toolName, 'bash');
      assert.equal(msg1.approval.reason, 'Execute rm -rf /tmp/test-dir');

      // Verify pending queue via REST reports 1 item
      const queueRes = await fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/api/mobile/approvals`, { headers: authHeaders });
      const queue = await queueRes.json();
      assert.equal(queue.ok, true);
      assert.equal(queue.approvals.length, 1);
      assert.equal(queue.approvals[0].id, testApprovalId);
    } finally {
      c1.close();
      c2.close();
    }
  });

  it('TC4.2: Concurrent settlement broadcasts approval_settled to all clients and purges queue cleanly', async () => {
    const testApprovalId = 'appr_lifecycle_stress_101';
    const wsUrl = `ws://127.0.0.1:${TEST_BRIDGE_PORT}/mobile-ws?token=${CONFIG.VALID_TOKEN}`;

    // Connect 3 mobile clients
    const clients = await Promise.all([
      createWsClient({ customUrl: wsUrl }),
      createWsClient({ customUrl: wsUrl }),
      createWsClient({ customUrl: wsUrl })
    ]);

    try {
      await Promise.all(clients.map(c => c.waitForMessage(m => m.type === 'connected', 3000)));

      // Prepare listeners for approval_settled broadcast on ALL 3 clients
      const settledPromises = clients.map(c =>
        c.waitForMessage(m => m.type === 'approval_settled' && m.eventId === testApprovalId, 3000)
      );

      // Fire 20 concurrent duplicate settlement requests (HTTP POSTs) simultaneously
      const burstPromises = [];
      for (let i = 0; i < 20; i++) {
        burstPromises.push(
          fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/api/mobile/approval`, {
            method: 'POST',
            headers: authHeaders,
            body: JSON.stringify({
              eventId: testApprovalId,
              outcome: 'allowed-once',
              reason: `Concurrent settler ${i}`
            })
          }).then(r => r.json())
        );
      }

      const results = await Promise.all(burstPromises);

      // Exactly ONE settlement must succeed (ok: true, code: 0)
      const successfulSettlements = results.filter(r => r.ok === true && r.code === 0);
      const duplicateRejections = results.filter(r => r.ok === false && r.code === 404);

      assert.equal(successfulSettlements.length, 1, 'Exactly one concurrent settlement must succeed');
      assert.equal(duplicateRejections.length, 19, 'Remaining 19 duplicate settlements must return 404');

      // Verify ALL connected mobile clients received approval_settled broadcast
      const settledMsgs = await Promise.all(settledPromises);
      for (const sMsg of settledMsgs) {
        assert.ok(sMsg, 'Client must receive approval_settled');
        assert.equal(sMsg.type, 'approval_settled');
        assert.equal(sMsg.eventId, testApprovalId);
        assert.equal(sMsg.outcome, 'allowed-once');
      }

      // Verify pending queue is purged cleanly (0 items)
      const afterRes = await fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/api/mobile/approvals`, { headers: authHeaders });
      const afterQueue = await afterRes.json();
      assert.equal(afterQueue.ok, true);
      assert.equal(afterQueue.approvals.length, 0, 'Pending queue must be 0 after settlement');
    } finally {
      clients.forEach(c => c.close());
    }
  });

  it('TC4.3: Duplicate settlement after queue purge is idempotent, returns 404 and does not re-broadcast', async () => {
    const testApprovalId = 'appr_lifecycle_stress_101';
    const wsUrl = `ws://127.0.0.1:${TEST_BRIDGE_PORT}/mobile-ws?token=${CONFIG.VALID_TOKEN}`;
    const client = await createWsClient({ customUrl: wsUrl });

    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);

      // Send duplicate request after event already settled
      const res = await fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/api/mobile/approval`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({
          eventId: testApprovalId,
          outcome: 'allowed-once',
          reason: 'Post-settlement duplicate response'
        })
      });
      const data = await res.json();

      assert.equal(res.status, 200);
      assert.equal(data.ok, false);
      assert.equal(data.code, 404);
      assert.ok(data.error.includes('not found or expired'));

      // Verify NO spurious approval_settled broadcast is sent
      const spuriousMsg = await client.waitForMessage(m => m.type === 'approval_settled', 300).catch(() => null);
      assert.equal(spuriousMsg, null, 'Must NOT broadcast approval_settled for duplicate response on settled event');

      // Pending queue remains 0
      const queueRes = await fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/api/mobile/approvals`, { headers: authHeaders });
      const queue = await queueRes.json();
      assert.equal(queue.approvals.length, 0);
    } finally {
      client.close();
    }
  });

  it('TC4.4: Upstream cancel frame purges pending queue and broadcasts approval_settled with outcome: cancelled', async () => {
    const cancelApprovalId = 'appr_lifecycle_cancel_202';
    const wsUrl = `ws://127.0.0.1:${TEST_BRIDGE_PORT}/mobile-ws?token=${CONFIG.VALID_TOKEN}`;
    const client = await createWsClient({ customUrl: wsUrl });

    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);

      // 1. Upstream creates approval request
      mockMuxWsClient.send(JSON.stringify({
        type: 'item',
        streamId: 'gw-events-stream',
        value: {
          type: 'request',
          event: 'approval/request',
          id: cancelApprovalId,
          agent: 'session-cancel-01',
          request: {
            toolName: 'git_commit',
            reason: 'Commit changes to repo',
            input: 'git commit -m "update"'
          }
        }
      }));

      // Wait for approval_request broadcast
      await client.waitForMessage(m => m.type === 'approval_request' && m.approval?.id === cancelApprovalId, 3000);

      // Verify queue has 1 item
      const queueBeforeRes = await fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/api/mobile/approvals`, { headers: authHeaders });
      const queueBefore = await queueBeforeRes.json();
      assert.equal(queueBefore.approvals.length, 1);

      // 2. Upstream sends cancel frame
      mockMuxWsClient.send(JSON.stringify({
        type: 'item',
        streamId: 'gw-events-stream',
        value: {
          type: 'cancel',
          eventId: cancelApprovalId
        }
      }));

      // Client must receive approval_settled with outcome: cancelled
      const cancelSettledMsg = await client.waitForMessage(
        m => m.type === 'approval_settled' && m.eventId === cancelApprovalId,
        3000
      );

      assert.ok(cancelSettledMsg, 'Must receive cancellation broadcast');
      assert.equal(cancelSettledMsg.outcome, 'cancelled');

      // Verify queue is purged
      const queueAfterRes = await fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/api/mobile/approvals`, { headers: authHeaders });
      const queueAfter = await queueAfterRes.json();
      assert.equal(queueAfter.approvals.length, 0, 'Queue must be purged after upstream cancel');
    } finally {
      client.close();
    }
  });
});
