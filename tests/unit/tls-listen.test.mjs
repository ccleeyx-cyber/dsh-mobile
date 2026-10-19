/**
 * v1.35 / 1.2 + 1.3 — TLS 监听端口与配对指纹下发
 *
 * 起一个真实网关实例（mkdtemp DSH_HOME + 随机端口），然后断言：
 *   1. HTTPS 上路由/鉴权栈与明文端口完全一致（401 而不是连接失败）；
 *   2. WSS 能在 TLS 端口上完成升级（wss.handleUpgrade 复用）；
 *   3. 明文端口行为零回归（同一个实例两套监听面并存）；
 *   4. /pair/qr 与 /pair/info 都带 certFingerprint，且与证书实际指纹一致；
 *   5. BRIDGE_TLS_PORT=0 时完全不监听 TLS（health 报 tlsPort: null）。
 *
 * 全程不打真实网络、不碰真实 ~/.dsh；两个实例都用 OS 分配的端口。
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import https from 'node:https';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require_ = createRequire(
  path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'dsh-server-plugin', 'index.js')
);
const { WebSocket: WsClient } = require_('ws');

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-tls-listen-'));
process.env.DSH_HOME = TMP_HOME;

const { apply } = await import('../../dsh-server-plugin/lib/index.js');
const { loadConfig } = await import('../../dsh-server-plugin/lib/store.mjs');
const { certPaths } = await import('../../dsh-server-plugin/lib/tls.mjs');

const TOKEN = loadConfig().token;

async function pickFreePort() {
  const srv = http.createServer();
  await new Promise((res, rej) => { srv.once('error', rej); srv.listen(0, '127.0.0.1', res); });
  const { port } = srv.address();
  await new Promise((res) => srv.close(res));
  return port;
}

function request(base, pathname, { headers = {}, rejectUnauthorized = false, method = 'GET' } = {}) {
  const mod = base.startsWith('https:') ? https : http;
  return new Promise((resolve, reject) => {
    const r = mod.request(`${base}${pathname}`, {
      method,
      rejectUnauthorized,
      headers: { Authorization: `Bearer ${TOKEN}`, ...headers }
    }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(data); } catch { /* non-JSON */ }
        resolve({ status: res.statusCode, data, parsed, raw: data });
      });
    });
    r.on('error', reject);
    r.end();
  });
}

async function waitFor(fn, { tries = 60, delay = 100 } = {}) {
  for (let i = 0; i < tries; i++) {
    try { return await fn(); } catch { await new Promise((r) => setTimeout(r, delay)); }
  }
  throw new Error('condition not met in time');
}

/** 一套可回收的网关实例。 */
function bootGateway({ port, tlsPort }) {
  const effectFns = [];
  const ctx = {
    logger: () => ({ info() {}, warn() {}, error() {}, log() {} }),
    webServer: { port: 3080 },
    connection: { rpc: { handle: () => async () => {} } },
    effect: (fn) => { effectFns.push(fn); return () => {}; },
    on: (evt, fn) => { if (evt === 'dispose') effectFns.push(fn); }
  };
  const prevTls = process.env.BRIDGE_TLS_PORT;
  process.env.BRIDGE_TLS_PORT = String(tlsPort);
  const disposer = apply(ctx, { port }, { port, dshPort: 3080, isListening: true });
  if (prevTls === undefined) delete process.env.BRIDGE_TLS_PORT;
  else process.env.BRIDGE_TLS_PORT = prevTls;

  return async () => {
    try { await disposer?.(); } catch { /* ignore */ }
    for (const fn of effectFns) {
      try { await fn(); } catch { /* ignore */ }
    }
    await new Promise((r) => setTimeout(r, 200));
  };
}

describe('tls-listen: HTTPS/WSS 与明文并存', () => {
  let closeA = null;
  let PLAIN = 0;
  let TLS = 0;

  before(async () => {
    PLAIN = await pickFreePort();
    TLS = await pickFreePort();
    closeA = bootGateway({ port: PLAIN, tlsPort: TLS });
    await waitFor(() => request(`http://127.0.0.1:${PLAIN}`, '/api/mobile/health'));
  });

  after(async () => {
    try { await closeA?.(); } catch { /* ignore */ }
    // 注意：不要在这里删 TMP_HOME —— 文件里还有第二个实例（BRIDGE_TLS_PORT=0）
    // 要用同一个 DSH_HOME。删掉会让它的 apply() 重新铸一个 token，而本文件开头
    // 读到的 TOKEN 就失效了（这个坑第一次就是这么踩到的）。清理在文件级 after。
  });

  it('serves the same auth-guarded routes over HTTPS', async () => {
    const ok = await request(`https://127.0.0.1:${TLS}`, '/api/mobile/health');
    assert.equal(ok.status, 200);
    assert.equal(ok.parsed.ok, true);
    assert.equal(ok.parsed.authenticated, true);
    assert.equal(ok.parsed.tlsPort, TLS);

    // 无 token：必须是 401，而不是 TLS/连接层失败 —— 说明路由栈真的复用了。
    const denied = await new Promise((resolve, reject) => {
      const r = https.request(
        `https://127.0.0.1:${TLS}/api/mobile/health`,
        { rejectUnauthorized: false },
        (res) => { res.resume(); res.on('end', () => resolve(res.statusCode)); }
      );
      r.on('error', reject);
      r.end();
    });
    assert.equal(denied, 401);
  });

  it('reports the real certificate fingerprint in /health and pairing', async () => {
    const health = await request(`https://127.0.0.1:${TLS}`, '/api/mobile/health');
    const certPem = fs.readFileSync(certPaths().cert, 'utf8');
    const real = 'sha256/' + crypto.createHash('sha256')
      .update(new crypto.X509Certificate(certPem).raw)
      .digest('hex');
    assert.equal(health.parsed.certFingerprint, real);

    const info = await request(`https://127.0.0.1:${TLS}`, '/pair/info');
    assert.equal(info.status, 200);
    assert.equal(info.parsed.certFingerprint, real, '/pair/info 必须与 /health 同口径');
  });

  it('completes a WSS upgrade on the TLS port', async () => {
    const frames = [];
    const ws = new WsClient(`wss://127.0.0.1:${TLS}/mobile-ws`, {
      rejectUnauthorized: false,
      headers: { Authorization: `Bearer ${TOKEN}` }
    });
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('wss connect timeout')), 5000);
      ws.on('message', (raw) => {
        try { frames.push(JSON.parse(String(raw))); } catch { /* ignore */ }
        if (frames.some((f) => f.type === 'connected')) { clearTimeout(timer); resolve(); }
      });
      ws.on('error', (err) => { clearTimeout(timer); reject(err); });
    });
    ws.close();
    assert.ok(frames.some((f) => f.type === 'connected'));
  });

  it('keeps the plain-HTTP listener behaving exactly as before', async () => {
    const r = await request(`http://127.0.0.1:${PLAIN}`, '/api/mobile/health');
    assert.equal(r.status, 200);
    assert.equal(r.parsed.port, PLAIN);
    // 明文端口不应伪装成 TLS 端点
    assert.equal(r.parsed.tlsPort, TLS, 'tlsPort 只报"这台机器开了 TLS 端口"，与请求走哪个端口无关');
  });

  it('also embeds the fingerprint in the QR payload shape', async () => {
    // /pair/qr 返回 PNG 或 JSON；JSON 分支能直接断言字段，PNG 分支只能验 200。
    const r = await request(`https://127.0.0.1:${TLS}`, '/pair/qr');
    assert.equal(r.status, 200);
    if (r.parsed) {
      assert.match(r.parsed.certFingerprint, /^sha256\/[0-9a-f]{64}$/);
      assert.equal(r.parsed.pairCode.length >= 4, true);
    }
  });
});

describe('tls-listen: BRIDGE_TLS_PORT=0 完全关闭', () => {
  let closeB = null;
  let PLAIN2 = 0;

  before(async () => {
    PLAIN2 = await pickFreePort();
    closeB = bootGateway({ port: PLAIN2, tlsPort: 0 });
    await waitFor(() => request(`http://127.0.0.1:${PLAIN2}`, '/api/mobile/health'));
  });

  after(async () => {
    try { await closeB?.(); } catch { /* ignore */ }
  });

  it('does not listen on TLS and says so honestly', async () => {
    const r = await request(`http://127.0.0.1:${PLAIN2}`, '/api/mobile/health');
    assert.equal(r.status, 200, `health failed: ${r.raw}`);
    assert.equal(r.parsed.tlsPort, null);
  });
});

// 文件级清理：两个实例都关掉之后再删临时 DSH_HOME。
after(() => {
  try { fs.rmSync(TMP_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
});
