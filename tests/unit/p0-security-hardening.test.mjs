/**
 * Regression tests for the four P0 gateway hardening fixes (2026-10-11).
 *
 * Each test pins a specific hole that the code review found and that had no
 * test at all — which is exactly how they survived:
 *
 *   1. CORS was `Access-Control-Allow-Origin: *` *with* Authorization allowed,
 *      so any web page the user visited could issue authenticated cross-origin
 *      XHRs against the gateway (read sessions, approve commands, answer Agent
 *      prompts).
 *   2. `?token=` was accepted as an auth fallback. URLs land in proxy access
 *      logs, browser history and Android network diagnostics, so the token
 *      leaked to anyone reading a log, while no test ever asserted the header
 *      path alone was sufficient.
 *   3. The server bound 0.0.0.0 by default — on every interface — for a proxy
 *      that carries the engine's full shell/file/approval surface over plain
 *      HTTP.
 *   4. roleCanWrite() gated HTTP via WRITE_PATHS but the WebSocket message
 *      handler had no gate at all, so a readonly paired device could approve a
 *      command or answer a question over the socket.
 *
 * Hermetic: own DSH_HOME via mkdtempSync, loopback only, no engine, no LLM,
 * no real session is ever created.
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

/**
 * `ws` comes from the PLUGIN's node_modules, not the repo root — same reason as
 * event-forwarding.test.mjs: it is the same `ws` the gateway itself uses, and
 * adding a root dependency just to make a test run is the wrong trade.
 */
const require_ = createRequire(
  path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'dsh-server-plugin', 'index.js')
);
const { WebSocket: WsClient } = require_('ws');

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-p0-home-'));
process.env.DSH_HOME = TMP_HOME;

const { apply } = await import('../../dsh-server-plugin/lib/index.js');
const { loadConfig } = await import('../../dsh-server-plugin/lib/store.mjs');
const TOKEN = loadConfig().token;

async function pickFreePort() {
  const srv = http.createServer();
  await new Promise((res, rej) => { srv.once('error', rej); srv.listen(0, '127.0.0.1', res); });
  const { port } = srv.address();
  await new Promise((res) => srv.close(res));
  return port;
}

const PORT = await pickFreePort();
const BASE = `http://127.0.0.1:${PORT}`;

let teardown = null;

function req(pathname, { method = 'GET', body = null, headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const payload = body == null ? null : JSON.stringify(body);
    const r = http.request(`${BASE}${pathname}`, {
      method,
      headers: {
        ...(payload ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } : {}),
        Authorization: `Bearer ${TOKEN}`,
        ...headers
      }
    }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(data); } catch { /* non-JSON */ }
        resolve({ status: res.statusCode, headers: res.headers, data: parsed, raw: data });
      });
    });
    r.on('error', reject);
    if (payload) r.write(payload);
    r.end();
  });
}

/** Raw request builder — lets a test omit Authorization entirely. */
function rawReq(pathname, { method = 'GET', headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const r = http.request(`${BASE}${pathname}`, { method, headers }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, raw: data }));
    });
    r.on('error', reject);
    r.end();
  });
}

describe('P0 security regressions: CORS, token transport, bind host, WS role gate', () => {
  before(async () => {
    const effectFns = [];
    const mockCtx = {
      logger: () => ({ info() {}, warn() {}, error() {}, log() {} }),
      webServer: { port: 3080 },
      connection: { rpc: { handle: () => async () => {} } },
      effect: (fn) => { effectFns.push(fn); return () => {}; },
      on: (evt, fn) => { if (evt === 'dispose') effectFns.push(fn); }
    };
    const disposer = apply(mockCtx, { port: PORT }, { port: PORT, dshPort: 3080, isListening: true });
    teardown = async () => {
      try { await disposer?.(); } catch { /* ignore */ }
      for (const fn of effectFns) {
        try { await fn(); } catch { /* ignore */ }
      }
    };
    for (let i = 0; i < 50; i++) {
      try { await req('/api/mobile/health'); return; } catch {
        await new Promise((r) => setTimeout(r, 100));
      }
    }
    throw new Error('bridge did not start');
  });

  after(async () => { await teardown?.(); });

  // ---- 1. CORS ---------------------------------------------------------

  it('does not echo a wildcard Origin', async () => {
    const res = await req('/api/mobile/health', { headers: { Origin: 'https://evil.example' } });
    assert.notEqual(res.headers['access-control-allow-origin'], '*');
    assert.equal(res.headers['access-control-allow-origin'], undefined);
  });

  it('echoes the loopback DSH origin, which is the only legitimate browser caller', async () => {
    const res = await req('/api/mobile/health', { headers: { Origin: 'http://127.0.0.1:3080' } });
    assert.equal(res.headers['access-control-allow-origin'], 'http://127.0.0.1:3080');
    assert.equal(res.headers.vary, 'Origin');
  });

  it('refuses the preflight for a disallowed origin instead of answering 204', async () => {
    const res = await rawReq('/api/mobile/workspaces', {
      method: 'OPTIONS',
      headers: {
        Origin: 'https://evil.example',
        'Access-Control-Request-Method': 'POST',
        'Access-Control-Request-Headers': 'authorization'
      }
    });
    assert.equal(res.status, 403);
  });

  it('still answers the native-client case: no Origin header means no CORS headers and a normal 200', async () => {
    const res = await rawReq('/api/mobile/health', {
      headers: { Authorization: `Bearer ${TOKEN}` }
    });
    assert.equal(res.status, 200);
    assert.equal(res.headers['access-control-allow-origin'], undefined);
  });

  // ---- 2. token transport ----------------------------------------------

  it('rejects a token supplied only via ?token= (it used to authenticate)', async () => {
    const res = await rawReq(`/api/mobile/workspaces?token=${encodeURIComponent(TOKEN)}`);
    assert.equal(res.status, 401);
  });

  it('rejects ?token= even on the health probe', async () => {
    const res = await rawReq(`/api/mobile/health?token=${encodeURIComponent(TOKEN)}`);
    assert.equal(res.status, 401);
  });

  it('still accepts the token in a header, so the native client is unaffected', async () => {
    const res = await rawReq('/api/mobile/health', {
      headers: { 'x-dsh-token': TOKEN }
    });
    assert.equal(res.status, 200);
  });

  // ---- 3. bind host ----------------------------------------------------

  it('defaults to loopback and only binds an explicit interface when asked', async () => {
    const { readFileSync } = await import('node:fs');
    const src = readFileSync(
      path.join(import.meta.dirname, '..', '..', 'dsh-server-plugin', 'lib', 'index.js'),
      'utf8'
    );
    assert.match(src, /const bindHost = config\.host[\s\S]{0,200}?\?\?\s*process\.env\.BRIDGE_HOST[\s\S]{0,40}?\?\?\s*'127\.0\.0\.1'/);
    // The standalone entry must not reintroduce a 0.0.0.0 default.
    const entry = readFileSync(
      path.join(import.meta.dirname, '..', '..', 'dsh-server-plugin', 'index.js'),
      'utf8'
    );
    assert.match(entry, /process\.env\.BRIDGE_HOST \|\| '127\.0\.0\.1'/);
    assert.doesNotMatch(entry, /BRIDGE_HOST \|\| '0\.0\.0\.0'/);
  });

  // ---- 5. brute-force backoff ------------------------------------------

  it('backs a failing caller off on /health after repeated bad tokens', async () => {
    const { _resetAuthBackoff } = await import('../../dsh-server-plugin/lib/core.mjs');
    _resetAuthBackoff();

    const statuses = [];
    for (let i = 0; i < 8; i++) {
      const r = await rawReq('/api/mobile/health', {
        headers: { 'x-dsh-token': `wrong-${i}` }
      });
      statuses.push(r.status);
    }
    // The first failures are plain 401s; once past the threshold the gateway
    // must refuse with 429 rather than keep verifying guesses for free.
    assert.equal(statuses[0], 401, 'first bad token is a plain 401');
    assert.ok(statuses.includes(429),
      `expected a 429 backoff after 8 failures, got ${statuses.join(',')}`);

    _resetAuthBackoff();
  });

  it('stays permissive again once the backoff is cleared (no permanent self-lockout)', async () => {
    const { _resetAuthBackoff } = await import('../../dsh-server-plugin/lib/core.mjs');
    _resetAuthBackoff();
    const ok = await rawReq('/api/mobile/health', {
      headers: { Authorization: `Bearer ${TOKEN}` }
    });
    assert.equal(ok.status, 200);
  });

  // ---- 4. WS role gate -------------------------------------------------

  it('gates the write-ish WS frames on roleCanWrite, matching the HTTP WRITE_PATHS gate', async () => {
    const { readFileSync } = await import('node:fs');
    const src = readFileSync(
      path.join(import.meta.dirname, '..', '..', 'dsh-server-plugin', 'lib', 'index.js'),
      'utf8'
    );
    // role must be stamped onto the socket at upgrade time ...
    assert.match(src, /req\._mobileAuth\s*=\s*auth/);
    assert.match(src, /ws\._role\s*=\s*req\._mobileAuth\?\.device\?\.role/);
    // ... and consulted before the two highest-impact frames are acted on.
    const answerIdx = src.indexOf("msg.type === 'question_answer'");
    const approvalIdx = src.indexOf("msg.type === 'approval_response'");
    assert.ok(answerIdx > -1 && approvalIdx > -1, 'both WS frames must still exist');
    for (const idx of [answerIdx, approvalIdx]) {
      const window = src.slice(idx, idx + 900);
      assert.match(window, /roleCanWrite\(ws\._role\)/,
        'a write-ish WS frame must consult roleCanWrite before acting');
    }
  });

  it('refuses an approval_response sent by a readonly device', async () => {
    // Pairing a device is how the readonly role exists at all, so mint one
    // directly against the store rather than over the network.
    const { newToken, hashToken, loadDevices, saveDevices } =
      await import('../../dsh-server-plugin/lib/store.mjs');
    const roToken = newToken();
    const devs = loadDevices();
    devs.devices = [...(devs.devices ?? []), {
      id: 'ro-test',
      name: 'readonly-test',
      role: 'readonly',
      tokenHash: hashToken(roToken),
      pairedAt: Date.now(),
      lastSeenAt: Date.now()
    }];
    saveDevices(devs);

    const ws = await openWs(roToken);
    try {
      const reply = await wsRoundTrip(ws, {
        type: 'approval_response',
        eventId: 'evt-does-not-exist',
        outcome: 'approved'
      });
      assert.ok(reply, 'expected a frame back');
      assert.match(String(reply.error ?? reply.type ?? ''), /只读|read-only/i,
        'a readonly device must be refused, not silently acked');
    } finally {
      try { ws.close(); } catch { /* ignore */ }
    }
  });

  it('still lets a readwrite device send the same frame (the gate is not over-broad)', async () => {
    const ws = await openWs(TOKEN);
    try {
      // Unknown event id → the handler answers a question_ack/error shape rather
      // than a 403 read-only refusal. We only assert we were NOT refused by role.
      const reply = await wsRoundTrip(ws, {
        type: 'approval_response',
        eventId: 'evt-does-not-exist',
        outcome: 'approved'
      });
      assert.ok(reply, 'expected a frame back');
      assert.doesNotMatch(String(reply.error ?? ''), /只读|read-only/i,
        'a readwrite device must not hit the readonly gate');
    } finally {
      try { ws.close(); } catch { /* ignore */ }
    }
  });
});

// --- minimal WebSocket client (no dependency; the bridge speaks JSON frames) ---

async function openWs(token) {
  const ws = new WsClient(`ws://127.0.0.1:${PORT}/mobile-ws`, {
    headers: { Authorization: `Bearer ${token}` }
  });
  await new Promise((res, rej) => {
    ws.once('open', res);
    ws.once('error', rej);
  });
  ws._inbox = [];
  ws.on('message', (d) => {
    try { ws._inbox.push(JSON.parse(String(d))); } catch { /* non-JSON (pong) */ }
  });
  return ws;
}

function wsRoundTrip(ws, payload, timeoutMs = 4000) {
  return new Promise((resolve) => {
    const before = ws._inbox.length;
    ws.send(JSON.stringify(payload));
    const started = Date.now();
    const poll = setInterval(() => {
      if (ws._inbox.length > before) {
        clearInterval(poll);
        resolve(ws._inbox[ws._inbox.length - 1]);
      } else if (Date.now() - started > timeoutMs) {
        clearInterval(poll);
        resolve(null);
      }
    }, 25);
  });
}