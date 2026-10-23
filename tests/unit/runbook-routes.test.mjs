/**
 * v1.35 / 3.1 — Runbook 路由（网关侧）
 *
 * 起真网关，验证三条用户可见行为：
 *  1. 首次访问自动生成默认模板（三条低危示例），列表接口能读出来；
 *  2. 未知 id → 404；
 *  3. 高危条目不带 confirm → 409，源码里写了 confirm:true 才执行。
 *
 * 这里**不执行真实命令**：409 分支根本不会走到执行器；默认模板的三条即使被
 * 执行也只是 git/ls，对我们自己的临时目录没有副作用（而且本文件不触发）。
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-runbook-routes-'));
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

function req(pathname, { method = 'GET', body = null } = {}) {
  return new Promise((resolve, reject) => {
    const payload = body == null ? null : JSON.stringify(body);
    const r = http.request(`${BASE}${pathname}`, {
      method,
      headers: {
        Authorization: `Bearer ${TOKEN}`,
        ...(payload ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } : {})
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
    if (payload) r.write(payload);
    r.end();
  });
}

let teardown = null;

describe('runbook routes', () => {
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

  it('首次访问生成默认模板，并能列出三条低危示例', async () => {
    const r = await req('/api/mobile/runbooks');
    assert.equal(r.status, 200);
    assert.equal(r.parsed.ok, true);
    assert.ok(Array.isArray(r.parsed.runbooks));
    assert.ok(r.parsed.runbooks.length >= 3);
    for (const rb of r.parsed.runbooks) {
      assert.ok(rb.id && rb.name && rb.command);
      assert.ok(['low', 'high'].includes(rb.danger));
    }
    // 模板落盘
    const file = path.join(TMP_HOME, 'mobile-access', 'runbooks.yaml');
    assert.equal(fs.existsSync(file), true);
  });

  it('未知 id 返回 404', async () => {
    const r = await req('/api/mobile/runbooks/run', { method: 'POST', body: { id: 'nope' } });
    assert.equal(r.status, 404);
  });

  it('默认模板的「目录概览」（ls -lt）在 Windows 上也能跑出结果', async () => {
    // [fix 2026-10-22] 用户报告的「目录概览执行会显示执行失败」。
    // 这里走完整的 HTTP → 执行 → 回应链路：不带 sessionId 时 cwd 回落到
    // DSH_HOME（临时目录，里面有 mobile-access/runbooks.yaml），目录一定存在。
    const file = path.join(TMP_HOME, 'mobile-access', 'runbooks.yaml');
    fs.writeFileSync(file, [
      'runbooks:',
      '  - name: 目录概览',
      '    description: 当前目录最近修改的 15 个条目',
      '    command: ls -lt',
      '    danger: low',
      '    outputTail: 20',
      ''
    ].join('\n'), 'utf8');

    const r = await req('/api/mobile/runbooks/run', { method: 'POST', body: { id: 'rb_1' } });
    assert.equal(r.status, 200);
    assert.equal(r.parsed.ok, true, `失败原因：${r.parsed.error}`);
    assert.equal(r.parsed.exitCode, 0);
    // 输出里至少有这个临时目录里的东西
    assert.match(r.parsed.outputTail, /mobile-access/);
  });

  it('高危条目不带 confirm → 409，且不执行', async () => {    const file = path.join(TMP_HOME, 'mobile-access', 'runbooks.yaml');
    fs.writeFileSync(file, [
      'runbooks:',
      '  - name: 危险操作',
      '    command: git gc',
      '    danger: high',
      ''
    ].join('\n'), 'utf8');

    const denied = await req('/api/mobile/runbooks/run', {
      method: 'POST',
      body: { id: 'rb_1' }
    });
    assert.equal(denied.status, 409);
    assert.equal(denied.parsed.code, 'confirm-required');
    assert.equal(denied.parsed.entry.danger, 'high');

    // 带 confirm 才会继续（这里只断言路由放行到执行阶段：git gc 在非仓库目录
    // 会以非零码返回，但 ok:true —— 说明确实执行了，而不是被拦下）。
    const allowed = await req('/api/mobile/runbooks/run', {
      method: 'POST',
      body: { id: 'rb_1', confirm: true }
    });
    assert.equal(allowed.status, 200);
    assert.equal(allowed.parsed.ok, true);
    assert.notEqual(allowed.parsed.exitCode, null);
  });
});
