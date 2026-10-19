/**
 * v1.35 / 2.1 — decide 路由接线（网关侧）
 *
 * 只验路由本身：参数校验、未知审批、鉴权。令牌语义在 approval-token.test.mjs
 * 里已经逐条钉过；这里不重复造一个假引擎去走完整链路。
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-decide-routes-'));
process.env.DSH_HOME = TMP_HOME;
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

function post(pathname, body, { token = TOKEN } = {}) {
  const payload = JSON.stringify(body ?? {});
  return new Promise((resolve, reject) => {
    const r = http.request(`${BASE}${pathname}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload),
        ...(token ? { Authorization: `Bearer ${token}` } : {})
      }
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
    r.write(payload);
    r.end();
  });
}

let teardown = null;

describe('approvals/decide routes', () => {
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
      try {
        const r = await post('/api/mobile/approvals/decide', {});
        if (r.status) return;
      } catch { await new Promise((r) => setTimeout(r, 100)); }
    }
    throw new Error('bridge did not start');
  });

  after(async () => {
    try { await teardown?.(); } catch { /* ignore */ }
    await new Promise((r) => setTimeout(r, 200));
    try { fs.rmSync(TMP_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
  });

  it('缺少 decision 时 400，且不泄露任何内部信息', async () => {
    const r = await post('/api/mobile/approvals/decide', { approvalId: 'appr_x' });
    assert.equal(r.status, 400);
    assert.equal(r.parsed.code, 'bad-request');
  });

  it('未知审批 404 unknown', async () => {
    const r = await post('/api/mobile/approvals/decide', {
      approvalId: 'appr_does_not_exist',
      decision: 'approve',
      approvalToken: 'fake'
    });
    assert.equal(r.status, 404);
    assert.equal(r.parsed.code, 'unknown');
  });

  it('无 token 的请求 401（不能匿名批准）', async () => {
    const r = await post('/api/mobile/approvals/decide', {
      approvalId: 'x', decision: 'approve'
    }, { token: null });
    assert.equal(r.status, 401);
  });

  it('决定值必须是 approve/deny，其它值一律 400', async () => {
    for (const bad of ['', 'yes', 'APPROVE!', 'allowed-once']) {
      const r = await post('/api/mobile/approvals/decide', { approvalId: 'appr_x', decision: bad });
      if (bad === '') assert.equal(r.status, 400);
      else assert.equal(r.status, 400, `decision=${bad} 不该被接受`);
    }
  });
});
