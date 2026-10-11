/**
 * Unit tests for device revocation (v1.15, [feat 2026-10-12]).
 *
 * Boots a throwaway bridge like smoke-bridge.test.mjs (isolated DSH_HOME,
 * mock Cordis ctx, free port) and covers:
 *   1. Pairing a device, then revoking it → subsequent requests with that
 *      device's token get 401 with `device_revoked: true` in the body.
 *   2. GET /api/mobile/devices lists devices and never leaks tokenHash.
 *   3. Device list requires auth (read role); revoke requires write role —
 *      a readonly device gets 403.
 *   4. Revoking broadcasts {type:'device_revoked', deviceId} to other online
 *      WS clients.
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import WebSocket from '../../dsh-server-plugin/node_modules/ws/index.js';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-revoke-home-'));
process.env.DSH_HOME = TMP_HOME;

const { apply } = await import('../../dsh-server-plugin/lib/index.js');
const { loadConfig, loadDevices } = await import('../../dsh-server-plugin/lib/store.mjs');
const ADMIN_TOKEN = loadConfig().token;

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
        ...headers
      }
    }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(data); } catch { /* non-JSON */ }
        resolve({ status: res.statusCode, data: parsed, raw: data });
      });
    });
    r.on('error', reject);
    if (payload) r.write(payload);
    r.end();
  });
}

const adminReq = (p, opts = {}) => req(p, { ...opts, headers: { Authorization: `Bearer ${ADMIN_TOKEN}`, ...(opts.headers || {}) } });

/** Pair a device through the real /__mobile/pair flow, return {token, deviceId}. */
async function pairDevice(name) {
  // Mint a pairing code with the admin token, then exchange it.
  const codeRes = await adminReq('/__mobile/pair/code', { method: 'POST' });
  assert.equal(codeRes.status, 200);
  const pairRes = await req('/__mobile/pair', {
    method: 'POST',
    body: { code: codeRes.data.code, name, platform: 'android' }
  });
  assert.equal(pairRes.status, 200, `pair failed: ${pairRes.raw}`);
  assert.equal(pairRes.data.ok, true);
  return { token: pairRes.data.token, deviceId: pairRes.data.deviceId };
}

/** Add a readonly device row directly (roles are only minted as readwrite today). */
function addReadonlyDevice() {
  const token = 'dsh_' + crypto.randomBytes(16).toString('hex');
  const state = loadDevices();
  const hash = crypto.createHash('sha256').update(token).digest('hex');
  state.devices.push({
    id: 'dev_ro_' + crypto.randomUUID().slice(0, 6),
    name: 'readonly-phone', tokenHash: hash, role: 'readonly',
    platform: 'android', createdAt: Date.now(), lastSeenAt: Date.now(),
    lastIp: '127.0.0.1', connectCount: 0, revoked: false
  });
  fs.writeFileSync(path.join(TMP_HOME, 'mobile-bridge', 'devices.json'), JSON.stringify(state), 'utf8');
  return { token, id: state.devices[state.devices.length - 1].id };
}

describe('device revocation', () => {
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
      try { await adminReq('/api/mobile/health'); return; } catch { await new Promise((r) => setTimeout(r, 100)); }
    }
    throw new Error('bridge did not start');
  });

  after(async () => {
    try { await teardown?.(); } catch { /* ignore */ }
    await new Promise((r) => setTimeout(r, 300));
    try { fs.rmSync(TMP_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
  });

  it('GET /api/mobile/devices lists devices without token hashes (admin)', async () => {
    const { deviceId } = await pairDevice('列表测试机');
    const r = await adminReq('/api/mobile/devices');
    assert.equal(r.status, 200);
    assert.ok(Array.isArray(r.data.devices));
    const found = r.data.devices.find((d) => d.id === deviceId);
    assert.ok(found, 'paired device must be listed');
    assert.equal(found.tokenHash, undefined, 'tokenHash must never be exposed');
    assert.ok(!('token' in found), 'plaintext token must never be exposed');
  });

  it('GET /api/mobile/devices rejects unauthenticated callers', async () => {
    const r = await req('/api/mobile/devices');
    assert.equal(r.status, 401);
  });

  it('revoke requires write role: readonly device gets 403', async () => {
    const ro = addReadonlyDevice();
    const r = await req('/api/mobile/devices/revoke', {
      method: 'POST',
      body: { deviceId: 'dev_whatever' },
      headers: { Authorization: `Bearer ${ro.token}` }
    });
    assert.equal(r.status, 403);
  });

  it('revoked device gets 401 with device_revoked on its next request', async () => {
    const { token, deviceId } = await pairDevice('待撤销机');
    // First: with a valid token it works.
    const before = await req('/api/mobile/health', { headers: { Authorization: `Bearer ${token}` } });
    assert.equal(before.status, 200);

    const rev = await adminReq('/api/mobile/devices/revoke', {
      method: 'POST',
      body: { deviceId }
    });
    assert.equal(rev.status, 200);
    assert.equal(rev.data.ok, true);

    const after = await req('/api/mobile/health', { headers: { Authorization: `Bearer ${token}` } });
    assert.equal(after.status, 401);
    assert.equal(after.data.device_revoked, true, 'body must carry device_revoked');
    assert.equal(after.data.deviceId, deviceId);
  });

  it('revoking broadcasts device_revoked to other online clients', async () => {
    const wsUrl = `ws://127.0.0.1:${PORT}/mobile-ws`;
    const ws = new WebSocket(wsUrl, { headers: { Authorization: `Bearer ${ADMIN_TOKEN}` } });
    await new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });

    const { deviceId } = await pairDevice('广播测试机');
    const framePromise = new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('no broadcast within 5s')), 5000);
      ws.on('message', (raw) => {
        try {
          const msg = JSON.parse(raw.toString());
          if (msg.type === 'device_revoked' && msg.deviceId === deviceId) {
            clearTimeout(t);
            resolve(msg);
          }
        } catch { /* ignore non-JSON frames */ }
      });
    });

    const rev = await adminReq('/api/mobile/devices/revoke', { method: 'POST', body: { deviceId } });
    assert.equal(rev.status, 200);

    const frame = await framePromise;
    assert.equal(frame.deviceId, deviceId);
    ws.close();
  });

  it('revoke of an unknown device 404s', async () => {
    const r = await adminReq('/api/mobile/devices/revoke', {
      method: 'POST',
      body: { deviceId: 'dev_nonexistent' }
    });
    assert.equal(r.status, 404);
  });

  it('revoke without deviceId 400s', async () => {
    const r = await adminReq('/api/mobile/devices/revoke', { method: 'POST', body: {} });
    assert.equal(r.status, 400);
  });
});
