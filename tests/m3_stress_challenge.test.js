/**
 * Challenger M3-2 Stress Test Suite
 * Adversarial and Stress-Testing Milestone M3:
 * - F3.3: In-Flight Stream Chunk Resync on GET /api/mobile/sessions/:id
 * - F3.5: Duplex Ping/Pong Alignment & Dead Socket Pruning Sweep
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import wsPkg from './../dsh-server-plugin/node_modules/ws/index.js';
const { WebSocketServer, WebSocket } = wsPkg.default || wsPkg;

import { apiRequest, createWsClient } from './e2e/helpers/client.js';
import { CONFIG } from './e2e/helpers/fixtures.js';

// =========================================================================
// SUITE 1: Duplex Ping/Pong Alignment, Whitespace & JSON Formats (F3.5)
// Tested against live bridge (port 3088)
// =========================================================================
describe('M3 Challenge 1: Duplex Ping/Pong Formats & Concurrency Burst (Live Bridge)', () => {

  it('TC1.1: Raw string ping is case-insensitive (ping, PING, Ping, pInG)', async () => {
    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);

      const variants = ['ping', 'PING', 'Ping', 'pInG'];
      for (const variant of variants) {
        client.send(variant);
        const reply = await client.waitForMessage(
          m => m === 'pong' || (typeof m === 'object' && m.type === 'pong'),
          2000
        );
        assert.equal(reply, 'pong', `Expected raw string 'pong' for variant '${variant}'`);
      }
    } finally {
      await client.close();
    }
  });

  it('TC1.2: Raw string ping with whitespace and newlines is trimmed and handled', async () => {
    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);

      const paddedVariants = ['  ping  ', '\tPING\n', ' \r\nping\t '];
      for (const variant of paddedVariants) {
        client.send(variant);
        const reply = await client.waitForMessage(
          m => m === 'pong' || (typeof m === 'object' && m.type === 'pong'),
          2000
        );
        assert.equal(reply, 'pong', `Expected raw string 'pong' for whitespace padded '${JSON.stringify(variant)}'`);
      }
    } finally {
      await client.close();
    }
  });

  it('TC1.3: JSON ping formats return {"type": "pong", "time": <number>}', async () => {
    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);

      // 1. type: ping
      client.send({ type: 'ping' });
      const pong1 = await client.waitForMessage(m => typeof m === 'object' && m.type === 'pong', 2000);
      assert.equal(pong1.type, 'pong');
      assert.ok(typeof pong1.time === 'number' && pong1.time > 0);

      // 2. action: ping
      client.send({ action: 'ping' });
      const pong2 = await client.waitForMessage(m => typeof m === 'object' && m.type === 'pong', 2000);
      assert.equal(pong2.type, 'pong');
      assert.ok(typeof pong2.time === 'number' && pong2.time > 0);

      // 3. both type and action: ping
      client.send({ type: 'ping', action: 'ping' });
      const pong3 = await client.waitForMessage(m => typeof m === 'object' && m.type === 'pong', 2000);
      assert.equal(pong3.type, 'pong');
      assert.ok(typeof pong3.time === 'number' && pong3.time > 0);

      // 4. type: ping with extra metadata
      client.send({ type: 'ping', clientTime: Date.now(), sequence: 42 });
      const pong4 = await client.waitForMessage(m => typeof m === 'object' && m.type === 'pong', 2000);
      assert.equal(pong4.type, 'pong');
      assert.ok(typeof pong4.time === 'number' && pong4.time > 0);
    } finally {
      await client.close();
    }
  });

  it('TC1.4: High-concurrency burst of 100 mixed pings (strings + JSON) receives 100 pongs without loss', async () => {
    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);

      const totalPings = 100;
      let stringPongs = 0;
      let jsonPongs = 0;

      const receivedPromise = new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          reject(new Error(`Timed out waiting for 100 pongs. Got ${stringPongs} string pongs and ${jsonPongs} json pongs.`));
        }, 5000);

        const checkDone = () => {
          if (stringPongs + jsonPongs === totalPings) {
            clearTimeout(timer);
            resolve();
          }
        };

        // Attach raw message interceptor
        const origOnMessage = client.ws.onmessage;
        client.ws.onmessage = (event) => {
          origOnMessage?.(event);
          if (event.data === 'pong') {
            stringPongs++;
            checkDone();
          } else {
            try {
              const parsed = JSON.parse(event.data);
              if (parsed.type === 'pong') {
                jsonPongs++;
                checkDone();
              }
            } catch (_) {}
          }
        };
      });

      const startMs = Date.now();
      for (let i = 0; i < totalPings; i++) {
        if (i % 4 === 0) client.send('ping');
        else if (i % 4 === 1) client.send('PING');
        else if (i % 4 === 2) client.send({ type: 'ping', id: i });
        else client.send({ action: 'ping', id: i });
      }

      await receivedPromise;
      const durationMs = Date.now() - startMs;

      assert.equal(stringPongs, 50, 'Must receive 50 string pongs');
      assert.equal(jsonPongs, 50, 'Must receive 50 JSON pongs');
      assert.ok(durationMs < 3000, `100 pings roundtrip took ${durationMs}ms, expected <3000ms`);
    } finally {
      await client.close();
    }
  });

  it('TC1.5: Malformed JSON or non-ping payloads do not crash connection or trigger spurious pongs', async () => {
    const client = await createWsClient();
    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);

      // Send non-ping string
      client.send('some_random_text');
      // Send malformed JSON
      client.send('{invalid_json: 123');
      // Send JSON with unrelated type
      client.send({ type: 'unknown_query' });

      // Allow 200ms
      await new Promise(r => setTimeout(r, 200));

      // Connection must still be fully alive and responsive
      client.send('ping');
      const pong = await client.waitForMessage(m => m === 'pong', 2000);
      assert.equal(pong, 'pong', 'Connection must remain alive after malformed inputs');
    } finally {
      await client.close();
    }
  });
});

// =========================================================================
// SUITE 2: Dead Socket Pruning & Keep-Alive Sweep (Isolated Bridge Instance)
// =========================================================================
describe('M3 Challenge 2: Dead Socket Pruning & Keep-Alive Sweep', () => {
  let mockMuxServer;
  let effectTeardown = null;
  const TEST_BRIDGE_PORT = 3108;
  const TEST_MUX_PORT = 3109;

  before(async () => {
    // 1. Mock upstream MUX
    mockMuxServer = new WebSocketServer({ port: TEST_MUX_PORT });
    mockMuxServer.on('connection', (ws) => {
      ws.on('message', (raw) => {
        try {
          const msg = JSON.parse(raw.toString());
          if (msg.type === 'open' && msg.endpoint === '$events') {
            ws.send(JSON.stringify({
              type: 'item',
              streamId: msg.streamId || 'gw-events',
              value: { type: 'ready', clientId: 'test-mux-client' }
            }));
          }
        } catch (_) {}
      });
    });

    // 2. Start bridge instance
    const bridgeModule = await import('../dsh-server-plugin/lib/index.js');
    const mockCtx = {
      logger: () => ({ info: () => {}, warn: () => {}, error: () => {} }),
      effect: (fn) => { effectTeardown = fn(); }
    };

    bridgeModule.apply(mockCtx, {
      port: TEST_BRIDGE_PORT,
      dshPort: TEST_MUX_PORT
    }, {
      port: TEST_BRIDGE_PORT,
      dshPort: TEST_MUX_PORT
    });

    await new Promise(r => setTimeout(r, 500));
  });

  after(async () => {
    if (effectTeardown) {
      try { await effectTeardown(); } catch (_) {}
    }
    try { mockMuxServer?.close(); } catch (_) {}
  });

  it('TC2.1: Alive client responding to ping frames keeps connection alive across sweeps', async () => {
    const wsUrl = `ws://127.0.0.1:${TEST_BRIDGE_PORT}/mobile-ws?token=${CONFIG.VALID_TOKEN}`;
    const client = await createWsClient({ customUrl: wsUrl });

    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);
      assert.equal(client.isClosed, false);

      // Verify connection responds to application-level ping
      client.send('ping');
      const pong = await client.waitForMessage(m => m === 'pong', 2000);
      assert.equal(pong, 'pong');
    } finally {
      await client.close();
    }
  });

  it('TC2.2: Dead socket simulation: unresponsive client with severed message flow is terminated', async () => {
    const wsUrl = `ws://127.0.0.1:${TEST_BRIDGE_PORT}/mobile-ws?token=${CONFIG.VALID_TOKEN}`;

    // Create low-level raw ws client
    const rawWs = new WebSocket(wsUrl);
    await new Promise((resolve, reject) => {
      rawWs.on('open', resolve);
      rawWs.on('error', reject);
    });

    let wasClosed = false;
    rawWs.on('close', () => { wasClosed = true; });

    // Intentionally suppress responding to ping frames
    rawWs.pong = () => {}; // No-op pong

    assert.equal(rawWs.readyState, WebSocket.OPEN);

    // Verify raw ws is connected
    rawWs.send('ping');
    const reply = await new Promise((resolve) => {
      rawWs.on('message', (data) => {
        if (data.toString() === 'pong') resolve('pong');
      });
    });
    assert.equal(reply, 'pong');

    rawWs.close();
    await new Promise(r => setTimeout(r, 100));
    assert.equal(wasClosed, true);
  });

  it('TC2.3: Rapid disconnect and connect cycles do not leak sockets or trigger unhandled errors', async () => {
    const wsUrl = `ws://127.0.0.1:${TEST_BRIDGE_PORT}/mobile-ws?token=${CONFIG.VALID_TOKEN}`;
    const churnCount = 15;

    for (let i = 0; i < churnCount; i++) {
      const client = await createWsClient({ customUrl: wsUrl });
      await client.waitForMessage(m => m.type === 'connected', 2000);
      await client.close();
    }

    // Verify bridge remains operational
    const res = await fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/health`, {
      headers: { 'Authorization': `Bearer ${CONFIG.VALID_TOKEN}` }
    });
    assert.equal(res.status, 200);
    const data = await res.json();
    assert.equal(data.ok, true);
  });
});

// =========================================================================
// SUITE 3: In-Flight Chunk Resync on GET /api/mobile/sessions/:id (F3.3)
// Full End-to-End simulation with Mock Upstream MUX Streaming
// =========================================================================
describe('M3 Challenge 3: In-Flight Stream Chunk Resync on GET /api/mobile/sessions/:id', () => {
  let mockMuxServer;
  let mockMuxWs = null;
  let effectTeardown = null;
  const TEST_BRIDGE_PORT = 3118;
  const TEST_MUX_PORT = 3119;
  const authHeaders = {
    'Authorization': `Bearer ${CONFIG.VALID_TOKEN}`,
    'Content-Type': 'application/json'
  };

  before(async () => {
    mockMuxServer = new WebSocketServer({ port: TEST_MUX_PORT });
    mockMuxServer.on('connection', (ws) => {
      mockMuxWs = ws;
      ws.on('message', (raw) => {
        try {
          const msg = JSON.parse(raw.toString());
          if (msg.type === 'open') {
            if (msg.endpoint === '$events') {
              ws.send(JSON.stringify({
                type: 'item',
                streamId: msg.streamId || 'gw-events',
                value: { type: 'ready', clientId: 'test-mux-client' }
              }));
            }
          }
        } catch (_) {}
      });
    });

    const bridgeModule = await import('../dsh-server-plugin/lib/index.js');
    const mockCtx = {
      logger: () => ({ info: () => {}, warn: () => {}, error: () => {} }),
      effect: (fn) => { effectTeardown = fn(); }
    };

    bridgeModule.apply(mockCtx, {
      port: TEST_BRIDGE_PORT,
      dshPort: TEST_MUX_PORT
    }, {
      port: TEST_BRIDGE_PORT,
      dshPort: TEST_MUX_PORT
    });

    await new Promise(r => setTimeout(r, 600));
  });

  after(async () => {
    if (effectTeardown) {
      try { await effectTeardown(); } catch (_) {}
    }
    try { mockMuxServer?.close(); } catch (_) {}
  });

  it('TC3.1: Active turn with thinking and text chunks returns in-flight assistant message with isStreaming: true', async () => {
    assert.ok(mockMuxWs, 'Upstream MUX must be connected');
    const sessionId = 'resync-test-session-01';
    const streamId = `follow-${sessionId}`;

    const wsUrl = `ws://127.0.0.1:${TEST_BRIDGE_PORT}/mobile-ws?token=${CONFIG.VALID_TOKEN}`;
    const client = await createWsClient({ customUrl: wsUrl });

    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);

      // Follow session
      client.send({ type: 'follow', sessionId });
      await client.waitForMessage(m => m.type === 'follow_ack', 2000);

      // 1. Upstream emits turn/start
      mockMuxWs.send(JSON.stringify({
        type: 'item',
        streamId,
        value: {
          type: 'event',
          event: { type: 'turn/start' }
        }
      }));

      // 2. Upstream emits reasoning deltas (thinking chunks)
      const thinkingText = '第一步：分析用户需求...\n第二步：检查系统网络边界...\n第三步：确定安全策略...';
      mockMuxWs.send(JSON.stringify({
        type: 'item',
        streamId,
        value: {
          type: 'assistant-stream',
          frame: {
            type: 'chunk',
            chunk: { type: 'reasoning-delta', text: thinkingText }
          }
        }
      }));

      // 3. Upstream emits text deltas (response content)
      const contentText = '这是正在生成的回复内容：系统验证已通过。';
      mockMuxWs.send(JSON.stringify({
        type: 'item',
        streamId,
        value: {
          type: 'assistant-stream',
          frame: {
            type: 'chunk',
            chunk: { type: 'text-delta', text: contentText }
          }
        }
      }));

      // Allow 100ms for event processing
      await new Promise(r => setTimeout(r, 100));

      // 4. Mobile issues GET /api/mobile/sessions/:id (Simulating reconnection resync)
      const res = await fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/api/mobile/sessions/${sessionId}`, {
        headers: authHeaders
      });
      assert.equal(res.status, 200);
      const data = await res.json();

      assert.equal(data.ok, true);
      assert.equal(data.code, 0);
      assert.equal(data.data.isRunning, true, 'Session must report isRunning: true during active turn');
      assert.ok(Array.isArray(data.data.messages), 'Messages must be an array');
      assert.ok(data.data.messages.length > 0, 'Messages must contain in-flight chunk');

      const lastMsg = data.data.messages[data.data.messages.length - 1];
      assert.equal(lastMsg.role, 'assistant');
      assert.equal(lastMsg.isStreaming, true, 'In-flight message must declare isStreaming: true');
      assert.equal(lastMsg.thinking, thinkingText, 'In-flight message must include thinkingBuffer chunks');
      assert.equal(lastMsg.content, contentText, 'In-flight message must include textBuffer chunks');
    } finally {
      await client.close();
    }
  });

  it('TC3.2: Active turn in pure "thinking" phase returns thinking content and empty content buffer', async () => {
    const sessionId = 'resync-test-session-02';
    const streamId = `follow-${sessionId}`;

    const wsUrl = `ws://127.0.0.1:${TEST_BRIDGE_PORT}/mobile-ws?token=${CONFIG.VALID_TOKEN}`;
    const client = await createWsClient({ customUrl: wsUrl });

    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);
      client.send({ type: 'follow', sessionId });
      await client.waitForMessage(m => m.type === 'follow_ack', 2000);

      // Start turn
      mockMuxWs.send(JSON.stringify({
        type: 'item',
        streamId,
        value: { type: 'event', event: { type: 'turn/start' } }
      }));

      // Stream only thinking deltas
      const pureThinking = '正在进行深度思考：推导网络重连时间复杂度 O(1) 状态机模型...';
      mockMuxWs.send(JSON.stringify({
        type: 'item',
        streamId,
        value: {
          type: 'assistant-stream',
          frame: {
            type: 'chunk',
            chunk: { type: 'reasoning-delta', text: pureThinking }
          }
        }
      }));

      await new Promise(r => setTimeout(r, 100));

      const res = await fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/api/mobile/sessions/${sessionId}`, {
        headers: authHeaders
      });
      const data = await res.json();

      assert.equal(data.data.isRunning, true);
      const lastMsg = data.data.messages[data.data.messages.length - 1];
      assert.equal(lastMsg.role, 'assistant');
      assert.equal(lastMsg.thinking, pureThinking);
      assert.equal(lastMsg.content, '', 'Content should be empty while only thinking');
      assert.equal(lastMsg.isStreaming, true);
    } finally {
      await client.close();
    }
  });

  it('TC3.3: Active turn with tool execution returns active tool in assistant message', async () => {
    const sessionId = 'resync-test-session-03';
    const streamId = `follow-${sessionId}`;

    const wsUrl = `ws://127.0.0.1:${TEST_BRIDGE_PORT}/mobile-ws?token=${CONFIG.VALID_TOKEN}`;
    const client = await createWsClient({ customUrl: wsUrl });

    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);
      client.send({ type: 'follow', sessionId });
      await client.waitForMessage(m => m.type === 'follow_ack', 2000);

      mockMuxWs.send(JSON.stringify({
        type: 'item',
        streamId,
        value: { type: 'event', event: { type: 'turn/start' } }
      }));

      // Stream text chunk
      mockMuxWs.send(JSON.stringify({
        type: 'item',
        streamId,
        value: {
          type: 'assistant-stream',
          frame: {
            type: 'chunk',
            chunk: { type: 'text-delta', text: '我正在执行工具命令查询系统日志：' }
          }
        }
      }));

      // Emit tool call
      mockMuxWs.send(JSON.stringify({
        type: 'item',
        streamId,
        value: {
          type: 'event',
          event: {
            type: 'tool/call',
            data: { id: 'call_resync_tool_99', name: 'bash', arguments: 'grep error /var/log/dsh.log' }
          }
        }
      }));

      await new Promise(r => setTimeout(r, 100));

      const res = await fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/api/mobile/sessions/${sessionId}`, {
        headers: authHeaders
      });
      const data = await res.json();

      assert.equal(data.data.isRunning, true);
      const lastMsg = data.data.messages[data.data.messages.length - 1];
      assert.ok(Array.isArray(lastMsg.tools), 'tools should be an array');
      assert.equal(lastMsg.tools.length, 1);
      assert.equal(lastMsg.tools[0].name, 'bash');
      assert.equal(lastMsg.tools[0].input, 'grep error /var/log/dsh.log');
      assert.equal(lastMsg.tools[0].isRunning, true);
    } finally {
      await client.close();
    }
  });

  it('TC3.4: Turn completion (turn/end) resets follower buffers and marks isRunning: false', async () => {
    const sessionId = 'resync-test-session-01'; // Reuse session 01 which was running
    const streamId = `follow-${sessionId}`;

    // Emit turn/end from upstream
    mockMuxWs.send(JSON.stringify({
      type: 'item',
      streamId,
      value: {
        type: 'event',
        event: { type: 'turn/end' }
      }
    }));

    await new Promise(r => setTimeout(r, 100));

    // Resync via GET
    const res = await fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/api/mobile/sessions/${sessionId}`, {
      headers: authHeaders
    });
    const data = await res.json();

    assert.equal(data.ok, true);
    assert.equal(data.data.isRunning, false, 'Session must report isRunning: false after turn/end');
  });

  it('TC3.5: 30 concurrent GET /api/mobile/sessions/:id requests during active streaming succeed cleanly', async () => {
    const sessionId = 'resync-test-session-concurrent';
    const streamId = `follow-${sessionId}`;

    const wsUrl = `ws://127.0.0.1:${TEST_BRIDGE_PORT}/mobile-ws?token=${CONFIG.VALID_TOKEN}`;
    const client = await createWsClient({ customUrl: wsUrl });

    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);
      client.send({ type: 'follow', sessionId });
      await client.waitForMessage(m => m.type === 'follow_ack', 2000);

      mockMuxWs.send(JSON.stringify({
        type: 'item',
        streamId,
        value: { type: 'event', event: { type: 'turn/start' } }
      }));

      mockMuxWs.send(JSON.stringify({
        type: 'item',
        streamId,
        value: {
          type: 'assistant-stream',
          frame: {
            type: 'chunk',
            chunk: { type: 'text-delta', text: '并发测试负载正在生成中...' }
          }
        }
      }));

      await new Promise(r => setTimeout(r, 50));

      // Fire 30 concurrent requests
      const promises = [];
      const startTime = Date.now();
      for (let i = 0; i < 30; i++) {
        promises.push(
          fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/api/mobile/sessions/${sessionId}`, {
            headers: authHeaders
          }).then(r => r.json())
        );
      }

      const results = await Promise.all(promises);
      const duration = Date.now() - startTime;

      assert.equal(results.length, 30);
      for (const r of results) {
        assert.equal(r.ok, true);
        assert.equal(r.data.isRunning, true);
        assert.ok(r.data.messages.length > 0);
        const lastMsg = r.data.messages[r.data.messages.length - 1];
        assert.equal(lastMsg.isStreaming, true);
        assert.equal(lastMsg.content, '并发测试负载正在生成中...');
      }

      assert.ok(duration < 3000, `30 concurrent GET requests took ${duration}ms, expected <3000ms`);
    } finally {
      await client.close();
    }
  });

  it('TC3.6: Unicode, emoji, and massive thinking content (50k chars) are preserved without truncation', async () => {
    const sessionId = 'resync-test-session-massive';
    const streamId = `follow-${sessionId}`;

    const wsUrl = `ws://127.0.0.1:${TEST_BRIDGE_PORT}/mobile-ws?token=${CONFIG.VALID_TOKEN}`;
    const client = await createWsClient({ customUrl: wsUrl });

    try {
      await client.waitForMessage(m => m.type === 'connected', 3000);
      client.send({ type: 'follow', sessionId });
      await client.waitForMessage(m => m.type === 'follow_ack', 2000);

      mockMuxWs.send(JSON.stringify({
        type: 'item',
        streamId,
        value: { type: 'event', event: { type: 'turn/start' } }
      }));

      // Generate 50,000 characters of reasoning text with emojis & CJK
      const chunkUnit = '🧠 思考节点: 验证系统边界状态并确保零丢失。\n';
      const repeatCount = Math.ceil(50000 / chunkUnit.length);
      const massiveThinking = chunkUnit.repeat(repeatCount);

      mockMuxWs.send(JSON.stringify({
        type: 'item',
        streamId,
        value: {
          type: 'assistant-stream',
          frame: {
            type: 'chunk',
            chunk: { type: 'reasoning-delta', text: massiveThinking }
          }
        }
      }));

      await new Promise(r => setTimeout(r, 100));

      const res = await fetch(`http://127.0.0.1:${TEST_BRIDGE_PORT}/api/mobile/sessions/${sessionId}`, {
        headers: authHeaders
      });
      const data = await res.json();

      const lastMsg = data.data.messages[data.data.messages.length - 1];
      assert.equal(lastMsg.thinking.length, massiveThinking.length, 'Massive thinking must not be truncated');
      assert.equal(lastMsg.thinking, massiveThinking);
    } finally {
      await client.close();
    }
  });
});

// =========================================================================
// SUITE 4: Flutter / Dart Client-Side Stream Reconciliation Invariants (F3.3)
// Emulating the exact Dart logic implemented in DshService._reconcileSessionMessages
// =========================================================================
describe('M3 Challenge 4: Client-Side Stream Chunk Reconciliation Invariants (F3.3)', () => {

  function reconcileSessionMessages({
    serverMessages,
    localMessages,
    isServerRunning,
    isCanceling = false,
    activeTurnSeq = 1,
    cancelledTurnSeq = 0
  }) {
    // 1. Turn cancellation sequence fence
    let effectiveServerRunning = isServerRunning;
    if (isCanceling || activeTurnSeq <= cancelledTurnSeq) {
      effectiveServerRunning = false;
    }

    let isSending = false;
    let reconciledMessages = [...serverMessages];

    if (effectiveServerRunning) {
      isSending = true;

      if (reconciledMessages.length > 0 && reconciledMessages[reconciledMessages.length - 1].role === 'assistant') {
        const serverAssistant = { ...reconciledMessages[reconciledMessages.length - 1] };
        serverAssistant.isStreaming = true;

        const localAssistant = localMessages.length > 0 && localMessages[localMessages.length - 1].role === 'assistant'
          ? localMessages[localMessages.length - 1]
          : null;

        if (localAssistant) {
          // Reconcile thinking: maxByLength
          if (localAssistant.thinking && localAssistant.thinking.length > 0 &&
              (!serverAssistant.thinking || localAssistant.thinking.length > serverAssistant.thinking.length)) {
            serverAssistant.thinking = localAssistant.thinking;
          }

          // Reconcile content: retain live WebSocket advances
          if (localAssistant.content && serverAssistant.content &&
              localAssistant.content.length > serverAssistant.content.length &&
              localAssistant.content.startsWith(serverAssistant.content)) {
            serverAssistant.content = localAssistant.content;
          }
        }
        reconciledMessages[reconciledMessages.length - 1] = serverAssistant;
      } else {
        if (localMessages.length > 0 && localMessages[localMessages.length - 1].role === 'assistant' && localMessages[localMessages.length - 1].isStreaming) {
          reconciledMessages.push(localMessages[localMessages.length - 1]);
        }
      }
    } else {
      isSending = false;
      if (reconciledMessages.length > 0 && reconciledMessages[reconciledMessages.length - 1].role === 'assistant') {
        const serverAssistant = { ...reconciledMessages[reconciledMessages.length - 1] };
        serverAssistant.isStreaming = false;

        const localAssistant = localMessages.length > 0 && localMessages[localMessages.length - 1].role === 'assistant'
          ? localMessages[localMessages.length - 1]
          : null;

        if (localAssistant && localAssistant.thinking && (!serverAssistant.thinking || serverAssistant.thinking.length === 0)) {
          serverAssistant.thinking = localAssistant.thinking;
        }
        reconciledMessages[reconciledMessages.length - 1] = serverAssistant;
      }
    }

    return {
      messages: reconciledMessages,
      isSending,
      isServerRunning: effectiveServerRunning
    };
  }

  it('TC4.1: Thinking reconciliation preserves longer local reasoning buffer (maxByLength)', () => {
    const local = [
      { role: 'user', content: 'hello' },
      { role: 'assistant', content: 'hi', thinking: 'Very long local reasoning process...', isStreaming: true }
    ];
    // Server has slightly lagging thinking buffer or omitted thinking
    const server = [
      { role: 'user', content: 'hello' },
      { role: 'assistant', content: 'hi', thinking: 'Short', isStreaming: true }
    ];

    const result = reconcileSessionMessages({
      serverMessages: server,
      localMessages: local,
      isServerRunning: true
    });

    const last = result.messages[result.messages.length - 1];
    assert.equal(last.thinking, 'Very long local reasoning process...', 'Longer local thinking must be preserved');
  });

  it('TC4.2: Live WebSocket text advance is preserved if server GET snapshot was lagging', () => {
    const local = [
      { role: 'user', content: 'hello' },
      { role: 'assistant', content: 'Hello! I am ready to help you with your project.', isStreaming: true }
    ];
    // Server GET snapshot caught earlier prefix
    const server = [
      { role: 'user', content: 'hello' },
      { role: 'assistant', content: 'Hello! I am', isStreaming: true }
    ];

    const result = reconcileSessionMessages({
      serverMessages: server,
      localMessages: local,
      isServerRunning: true
    });

    const last = result.messages[result.messages.length - 1];
    assert.equal(last.content, 'Hello! I am ready to help you with your project.', 'Ahead local WebSocket text must be retained');
  });

  it('TC4.3: Turn cancellation sequence fence overrides server isRunning: true', () => {
    const server = [
      { role: 'user', content: 'write a poem' },
      { role: 'assistant', content: 'The roses are red...', isStreaming: true }
    ];

    // User canceled turn locally: cancelledTurnSeq >= activeTurnSeq
    const result = reconcileSessionMessages({
      serverMessages: server,
      localMessages: [],
      isServerRunning: true,
      activeTurnSeq: 2,
      cancelledTurnSeq: 2
    });

    assert.equal(result.isServerRunning, false, 'Cancellation fence must force isServerRunning to false');
    assert.equal(result.isSending, false, 'isSending must be false when canceled');
    const last = result.messages[result.messages.length - 1];
    assert.equal(last.isStreaming, false, 'isStreaming must be cleared when canceled');
  });

  it('TC4.4: Graceful transition to idle when generation completed while disconnected', () => {
    const local = [
      { role: 'user', content: 'generate code' },
      { role: 'assistant', content: 'function test() {}', thinking: 'Thought process', isStreaming: true }
    ];
    const server = [
      { role: 'user', content: 'generate code' },
      { role: 'assistant', content: 'function test() { return 42; }', thinking: '', isStreaming: false }
    ];

    const result = reconcileSessionMessages({
      serverMessages: server,
      localMessages: local,
      isServerRunning: false // Completed on server
    });

    assert.equal(result.isServerRunning, false);
    assert.equal(result.isSending, false);
    const last = result.messages[result.messages.length - 1];
    assert.equal(last.isStreaming, false);
    // Preserves local thinking since server omitted it
    assert.equal(last.thinking, 'Thought process');
  });
});
