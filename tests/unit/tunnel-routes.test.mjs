/**
 * v1.35 / 1.5 + 2026-10-21 重构 — 远程接入路由（网关侧薄层）
 *
 * 钉住四条最容易写错的规则：
 *   1. 「远程接入」严格互斥：provider 只有 none / nps / cloudflared，状态接口必须
 *      归一给出 provider + 公网地址 + 是否就绪 + 原因；
 *   2. TLS 关闭时绝不允许把明文网关暴露到公网 —— 但前提是 provider 真的是
 *      cloudflared（否则先被互斥规则挡掉）；
 *   3. 切走 provider 后，旧的 /tunnel/start 必须拒绝，避免"界面说走 NPS，
 *      cloudflared 还在后台占着一条公网隧道"；
 *   4. provider=nps 没有 host 是无效配置，必须 400 而不是写进去。
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

function req(pathname, { method = 'GET', body } = {}) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? null : JSON.stringify(body);
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

describe('remote access routes', () => {
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

  it('tunnel 状态接口仍然如实报告 idle（兼容旧客户端）', async () => {
    const r = await req('/api/mobile/tunnel');
    assert.equal(r.status, 200);
    assert.equal(r.parsed.ok, true);
    assert.equal(r.parsed.status, 'idle');
    assert.equal(r.parsed.target, null);
  });

  it('默认 none：明确说"只有局域网"，不给一个假地址', async () => {
    const r = await req('/api/mobile/remote-access');
    assert.equal(r.status, 200);
    assert.equal(r.parsed.provider, 'none');
    assert.equal(r.parsed.managed, 'none');
    assert.equal(r.parsed.publicUrl, null);
    assert.equal(r.parsed.ready, false);
    assert.match(r.parsed.reason, /局域网/);
    // 局域网地址与 TLS 指纹是客户端需要的既有信息，不能因为没配远程就消失
    assert.match(r.parsed.localUrl, /^http:\/\//);
    assert.equal(r.parsed.tlsPort, 0);
  });

  it('provider=nps 缺 host 直接 400，不落盘', async () => {
    const r = await req('/api/mobile/remote-access', {
      method: 'POST',
      body: { provider: 'nps', nps: { host: '   ' } }
    });
    assert.equal(r.status, 400);
    assert.match(r.parsed.error, /nps\.host/);
    assert.equal(loadConfig().remoteAccess.provider, 'none');
  });

  it('切到 nps：地址由配置拼出，managed=external（网关无法验证外部反代）', async () => {
    const r = await req('/api/mobile/remote-access', {
      method: 'POST',
      body: { provider: 'nps', nps: { host: 'n.example.com', port: 3443, useHttps: true } }
    });
    assert.equal(r.status, 200);
    assert.equal(r.parsed.provider, 'nps');
    assert.equal(r.parsed.managed, 'external');
    assert.equal(r.parsed.publicUrl, 'https://n.example.com:3443');
    assert.equal(r.parsed.ready, true);
    assert.equal(r.parsed.reason, '');
  });

  it('切走之后，旧 /tunnel/start 必须被互斥规则拒绝', async () => {
    const r = await req('/api/mobile/tunnel/start', { method: 'POST' });
    assert.equal(r.status, 409);
    assert.equal(r.parsed.code, 'provider-not-managed');
    assert.match(r.parsed.error, /严格互斥/);
    // 状态仍在响应里，客户端能直接拿它刷新界面
    assert.equal(r.parsed.state.provider, 'nps');
  });

  it('切到 cloudflared：managed=gateway，TLS 关着时如实说未就绪', async () => {
    const r = await req('/api/mobile/remote-access', {
      method: 'POST',
      body: { provider: 'cloudflared' }
    });
    assert.equal(r.status, 200);
    assert.equal(r.parsed.provider, 'cloudflared');
    assert.equal(r.parsed.managed, 'gateway');
    assert.equal(r.parsed.ready, false);
    assert.ok(r.parsed.reason.length > 0, '未就绪必须给原因');
    // 切过来之后 NPS 的地址不该再被当成当前出口
    assert.equal(r.parsed.publicUrl, null);
  });

  it('provider=cloudflared 且 TLS 关闭：隧道不再被 TLS 挡住（回环明文即可）', async () => {
    // [fix 2026-10-21] 以前这里断言的是「TLS 未启用 → 409」。那条前提是错的：
    // 公网那一段由 Cloudflare 终结 TLS，本机那一段是回环 127.0.0.1，明文没有
    // 暴露面。把两件互不相干的事绑在一起，只会让 TLS 没起来时隧道也开不了。
    const r = await req('/api/mobile/remote-access');
    assert.equal(r.status, 200);
    assert.equal(r.parsed.provider, 'cloudflared');
    assert.equal(r.parsed.mode, 'quick', '没配 token 就是快速隧道');
    assert.equal(r.parsed.tlsPort, 0, '本用例刻意关掉 TLS');
    assert.doesNotMatch(r.parsed.reason, /TLS/, 'TLS 不再是隧道的前置条件');
  });

  it('cloudflared 命名隧道：配了 token 就切到 named 模式', async () => {
    const r = await req('/api/mobile/remote-access', {
      method: 'POST',
      body: { provider: 'cloudflared', cloudflared: { token: 'eyJfake', host: 'dsh.example.com' } }
    });
    assert.equal(r.status, 200);
    assert.equal(r.parsed.mode, 'named');
    // 命名隧道的地址由配置域名决定，未就绪时不能提前宣称
    assert.equal(r.parsed.ready, false);
    assert.equal(r.parsed.publicUrl, null);
  });

  it('非法 provider 直接 400', async () => {
    const r = await req('/api/mobile/remote-access', {
      method: 'POST',
      body: { provider: 'tailscale' }
    });
    assert.equal(r.status, 400);
    assert.match(r.parsed.error, /none \/ nps \/ cloudflared/);
  });

  /* ---- [fix 2026-10-21] 配对载荷必须服从 provider ---- */

  it('provider=nps：二维码用公网地址，scheme/端口跟着配置走', async () => {
    await req('/api/mobile/remote-access', {
      method: 'POST',
      body: { provider: 'nps', nps: { host: 'n.example.com', port: 3443, useHttps: true } }
    });
    const r = await req('/pair/info');
    assert.equal(r.status, 200);
    assert.equal(r.parsed.host, 'n.example.com');
    assert.equal(r.parsed.scheme, 'https', '公网是 https 时必须下发 scheme，否则 App 用 http 配对必然失败');
    assert.equal(r.parsed.port, 3443);
    assert.equal(r.parsed.reach, 'public');
    assert.equal(r.parsed.publicHost, 'n.example.com');
  });

  it('provider=none：二维码绝不能再带公网域名（真机 bug：配过 NPS 就会一直带）', async () => {
    // 先把 NPS 地址填上（模拟"曾经用过 NPS"），再切到仅局域网。
    await req('/api/mobile/remote-access', {
      method: 'POST',
      body: { provider: 'nps', nps: { host: 'n.example.com', port: 3443, useHttps: true } }
    });
    await req('/api/mobile/remote-access', { method: 'POST', body: { provider: 'none' } });

    const r = await req('/pair/info');
    assert.equal(r.status, 200);
    assert.notEqual(r.parsed.host, 'n.example.com',
      '仅局域网时 npsHost 只是"留着以后切回去用"，不能当成对外地址');
    assert.equal(r.parsed.reach, 'lan');
    assert.equal(r.parsed.publicHost, null);
    assert.equal(r.parsed.publicPort, null);
    assert.equal(r.parsed.scheme, 'http');
    // 局域网回退端口必须是网关自己的监听端口，而不是反代映射出来的端口
    assert.equal(typeof r.parsed.lanPort, 'number');
  });
});
