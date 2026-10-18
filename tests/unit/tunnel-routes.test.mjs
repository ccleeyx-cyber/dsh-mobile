/**
 * v1.35 / 1.5 — 云隧道路由（网关侧薄层）
 *
 * 只钉两条最容易写错的规则：
 *   1. TLS 关闭时 POST /tunnel/start 必须 409 —— 绝不允许把明文网关暴露到公网；
 *   2. GET /tunnel 必须如实报告状态（idle + target），让 App 能区分"没开"和
 *      "开失败了"。
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-tunnel-routes-'));
process.env.DSH_HOME = TMP_HOME;
// 本条用例刻意关闭 TLS：验证"没有 HTTPS 就不许开隧道"这条硬约束。
process.env.BRIDGE_TLS_PORT = '0';

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

function req(pathname, { method = 'GET' } = {}) {
  return new Promise((resolve, reject) => {
    const r = http.request(`${BASE}${pathname}`, {
      method,
      headers: { Authorization: `Bearer ${TOKEN}` }
    }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(data); } catch { /* ignore */ }
        resolve({ status: res.statusCode, parsed, raw: data });
      });
    });
    r.on('error', reject);
    r.end();
  });
}

let teardown = null;

describe('tunnel routes', () => {
  before(async () => {
    const effectFns = [];
    const ctx = {
      logger: () => ({ info() {}, warn() {}, error() {}, log() {} }),
      webServer: { port: 3080 },
      connection: { rpc: { handle: () => async () => {} } },
      effect: (fn) => { effectFns.push(fn); return () => {}; },
      on: (evt, fn) => { if (evt === 'dispose') effectFns.push(fn); }
    };
    const disposer = apply(ctx, { port: PORT }, { port: PORT, dshPort: 3080, isListening: true });
    teardown = async () => {
      try { await disposer?.(); } catch { /* ignore */ }
      for (const fn of effectFns) { try { await fn(); } catch { /* ignore */ } }
    };
    for (let i = 0; i < 50; i++) {
      try { await req('/api/mobile/health'); return; } catch { await new Promise((r) => setTimeout(r, 100)); }
    }
    throw new Error('bridge did not start');
  });

  after(async () => {
    try { await teardown?.(); } catch { /* ignore */ }
    await new Promise((r) => setTimeout(r, 200));
    try { fs.rmSync(TMP_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
  });

  it('reports idle status with no TLS target', async () => {
    const r = await req('/api/mobile/tunnel');
    assert.equal(r.status, 200);
    assert.equal(r.parsed.ok, true);
    assert.equal(r.parsed.status, 'idle');
    assert.equal(r.parsed.target, null);
  });

  it('refuses to start without TLS instead of exposing plaintext', async () => {
    const r = await req('/api/mobile/tunnel/start', { method: 'POST' });
    assert.equal(r.status, 409);
    assert.match(r.parsed.error, /TLS/);
  });
});
