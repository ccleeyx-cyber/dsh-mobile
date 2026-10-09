/**
 * Smoke test for the refactored Cordis entry (lib/index.js + lib/core.mjs).
 *
 * Boots a throwaway instance on a spare port with a mock Cordis context, then
 * exercises the routes the refactor touched: personas (previously 404 here),
 * the auth matrix, 404 handling, and the 2MB body cap.
 *
 * Uses its own DSH_HOME so it never touches the live ~/.dsh state.
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-smoke-home-'));
process.env.DSH_HOME = TMP_HOME;

const { apply } = await import('../../dsh-server-plugin/lib/index.js');
// store.mjs mints a random token on a fresh DSH_HOME — read the real one back
// instead of assuming a published default (there is no default any more).
const { loadConfig } = await import('../../dsh-server-plugin/lib/store.mjs');
const DEFAULT_TEST_TOKEN = loadConfig().token;
// Single source of truth for the version the bridge reports. This used to be a
// hardcoded /^1\.2\.\d+$/ regex, which silently turned into a time bomb: the
// moment core.mjs was bumped to match pubspec.yaml (1.3.0) the ONLY hermetic CI
// gate went red. Now the assertion checks consistency, not a literal.
const { BRIDGE_VERSION } = await import('../../dsh-server-plugin/lib/core.mjs');

/**
 * Grab an OS-assigned free port instead of hardcoding one.
 *
 * PORT used to be the constant 3199. Because `node --test` parallelises by file,
 * a constant port is exactly what forced `--test-concurrency=1` across all six
 * test scripts in package.json. There is a small TOCTOU window between closing
 * the probe socket and the bridge binding, but it is orders of magnitude better
 * than two suites racing for the same fixed port.
 */
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
        Authorization: `Bearer ${DEFAULT_TEST_TOKEN}`,
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

describe('smoke: refactored Cordis entry', () => {
  before(async () => {
    const effectFns = [];
    // The plugin registers its shutdown routine through ctx.effect(fn, label).
    // Capture it so after() can actually run it — otherwise the test server keeps
    // the event loop alive and the runner never exits.
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

    // Wait for listen
    for (let i = 0; i < 50; i++) {
      try {
        await req('/api/mobile/health');
        return;
      } catch {
        await new Promise((r) => setTimeout(r, 100));
      }
    }
    throw new Error('bridge did not start');
  });

  after(async () => {
    try { await teardown?.(); } catch { /* ignore */ }
    // Give sockets/timers a tick to release before the runner checks for handles.
    await new Promise((r) => setTimeout(r, 300));
    try { fs.rmSync(TMP_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
  });

  it('health responds and reports a single consistent version', async () => {
    const r = await req('/api/mobile/health');
    assert.equal(r.status, 200);
    assert.equal(r.data.ok, true);
    assert.equal(r.data.authenticated, true);
    // Consistency, not a literal: whatever core.mjs exports must be what the
    // route reports. Survives a version bump without going red.
    assert.equal(r.data.version, BRIDGE_VERSION);
    assert.match(r.data.version, /^\d+\.\d+\.\d+/, 'version must be semver-shaped');
  });

  it('rejects a missing token with 401', async () => {
    const r = await new Promise((resolve, reject) => {
      const rq = http.request(`${BASE}/api/mobile/workspaces`, { method: 'GET' }, (res) => {
        res.resume();
        res.on('end', () => resolve({ status: res.statusCode }));
      });
      rq.on('error', reject);
      rq.end();
    });
    assert.equal(r.status, 401);
  });

  it('serves /api/mobile/personas (the route that used to 404 here)', async () => {
    const r = await req('/api/mobile/personas');
    assert.equal(r.status, 200);
    assert.ok(Array.isArray(r.data.personas), 'personas must be an array');
    assert.ok(r.data.personas.length > 0, 'expected preset personas');
    for (const p of r.data.personas) {
      assert.ok(p.id && p.title, 'each persona needs id and title');
    }
  });

  it('persists persona updates and reads them back', async () => {
    const save = await req('/api/mobile/personas', {
      method: 'POST',
      body: { personas: [{ id: 'x', title: 'T', icon: 'code', description: 'd', prompt: 'p', isCustom: true }] }
    });
    assert.equal(save.status, 200);
    assert.equal(save.data.ok, true);

    const read = await req('/api/mobile/personas');
    assert.equal(read.data.personas.length, 1);
    assert.equal(read.data.personas[0].id, 'x');
  });

  it('rejects a non-array personas payload with 400', async () => {
    const r = await req('/api/mobile/personas', { method: 'POST', body: { personas: 'nope' } });
    assert.equal(r.status, 400);
  });

  it('unknown route still 404s with a JSON error', async () => {
    const r = await req('/api/mobile/definitely-not-a-route');
    assert.equal(r.status, 404);
    assert.ok(r.data.error);
  });

  it('returns 413 for a body over the 2MB cap', async () => {
    const big = 'A'.repeat(3 * 1024 * 1024);
    const r = await req('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: 's', text: big }
    });
    assert.equal(r.status, 413);
    assert.match(r.data.error, /too large/i);
  });

  it('accepts a body just under the cap without a 413', async () => {
    // 1.9MB — must reach the handler (which then fails upstream, not on size)
    const r = await req('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: '   ', text: 'A'.repeat(1024 * 1024) }
    });
    assert.notEqual(r.status, 413);
  });

  it('rejects a whitespace-only sessionId with 400', async () => {
    const r = await req('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: '   ', text: 'hi' }
    });
    assert.equal(r.status, 400);
  });
});
