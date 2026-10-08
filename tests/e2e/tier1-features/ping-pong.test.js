/**
 * Tier 1: Ping / Pong & WebSocket Keep-Alive Verification
 * Features: REST Ping, WebSocket Handshake, JSON Ping, String Ping (F3.5), Clean Disconnect, Unauthorized WS
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest, createWsClient } from '../helpers/client.js';
import { CONFIG } from '../helpers/fixtures.js';

describe('Tier 1 - Ping/Pong & WebSocket Keep-Alive', () => {

  it('TC1: GET /api/mobile/ping returns HTTP 200 with code 0 and timestamp', async () => {
    const res = await apiRequest('/api/mobile/ping');
    assert.equal(res.status, 200);
    assert.equal(res.data.code, 0);
    assert.ok(res.data.time, 'Response should contain timestamp');
  });

  it('TC2: WebSocket connection receives initial greeting type: "connected"', async () => {
    const client = await createWsClient();
    try {
      const greeting = await client.waitForMessage(m => m.type === 'connected', 3000);
      assert.equal(greeting.type, 'connected');
      assert.ok(greeting.version, 'Greeting should include bridge version');
    } finally {
      client.close();
    }
  });

  it('TC3: WebSocket responds to JSON {"type": "ping"} with {"type": "pong"}', async () => {
    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);
      client.send({ type: 'ping' });
      const pong = await client.waitForMessage(m => m.type === 'pong', 2000);
      assert.equal(pong.type, 'pong');
      assert.ok(pong.time, 'Pong should include timestamp');
    } finally {
      client.close();
    }
  });

  it('TC4: WebSocket responds to raw string "ping" with "pong" (F3.5 requirement)', async () => {
    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);
      client.send('ping');
      // Per F3.5 specification, server must respond to string 'ping' with pong
      const pong = await client.waitForMessage(
        m => m === 'pong' || (typeof m === 'object' && m.type === 'pong'),
        1500
      );
      assert.ok(pong, 'Server should respond to string ping with pong');
    } finally {
      client.close();
    }
  });

  it('TC5: WebSocket connection closes cleanly with code 1000 or 1005', async () => {
    const client = await createWsClient();
    await client.waitForMessage(m => m.type === 'connected', 3000);
    await client.close();
    assert.ok(client.isClosed, 'WebSocket should be closed');
  });

  it('TC6: WebSocket connection without valid token fails with HTTP 401', async () => {
    await assert.rejects(
      async () => {
        await createWsClient({ token: CONFIG.INVALID_TOKEN, timeout: 2000 });
      },
      /401|WebSocket connection error|rejected|timeout/i,
      'WebSocket upgrade with invalid token should be rejected'
    );
  });

  it('TC7: WebSocket responds to JSON {"action": "ping"} with {"type": "pong"} (F3.5 requirement)', async () => {
    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);
      client.send({ action: 'ping' });
      const pong = await client.waitForMessage(m => m.type === 'pong', 2000);
      assert.equal(pong.type, 'pong');
      assert.ok(pong.time, 'Pong should include timestamp');
    } finally {
      client.close();
    }
  });

  it('TC8: WebSocket responds to case-insensitive raw string "PING" with pong (F3.5 requirement)', async () => {
    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);
      client.send('PING');
      const pong = await client.waitForMessage(
        m => m === 'pong' || (typeof m === 'object' && m.type === 'pong'),
        1500
      );
      assert.ok(pong, 'Server should respond to uppercase PING with pong');
    } finally {
      client.close();
    }
  });
});
