/**
 * Attachment routes § 上传图片/文件 (v1.10.0).
 *
 * Three things are covered here, all against a throwaway DSH_HOME:
 *
 *  1. `GET /api/mobile/attachment` — the route the app's AttachmentImageTile has
 *     always requested but which did not exist, so uploaded images could never
 *     render (404). It must exist and must refuse a request without a sessionId,
 *     because the engine authorizes an image read against the session that
 *     actually references it.
 *
 *  2. `POST /api/mobile/upload` — must reject a missing sessionId and an empty
 *     body before spending any upstream work.
 *
 *  3. `/api/mobile/sessions/prompt` — the engine's own admission rule is
 *     "non-whitespace text OR at least one attachment", so the gateway must stop
 *     requiring text once attachments are present. This is asserted through the
 *     error *message*: with no text and no attachment it must be the specific
 *     "Missing or empty prompt text" rejection; with attachments it must get past
 *     that check (and then fail later on the unreachable engine, which is fine
 *     and is exactly what proves the validation was passed).
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-attach-home-'));
process.env.DSH_HOME = TMP_HOME;

// The plugin talks to the engine on dshPort; point it at a port nothing listens
// on so every upstream call fails fast and deterministically instead of touching
// the real dsh web.
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
const DEAD_DSH_PORT = await pickFreePort(); // nothing will ever listen here
const BASE = `http://127.0.0.1:${PORT}`;

let teardown = null;

function req(pathname, { method = 'GET', body = null, contentType = 'application/json', raw = null } = {}) {
  return new Promise((resolve, reject) => {
    const headers = { Authorization: `Bearer ${TOKEN}` };
    if (raw !== null) headers['Content-Type'] = contentType;
    const payload = raw !== null ? raw : (body !== null ? JSON.stringify(body) : null);
    if (payload !== null) headers['Content-Length'] = Buffer.byteLength(payload);

    const r = http.request(`${BASE}${pathname}`, { method, headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const buf = Buffer.concat(chunks);
        let json = null;
        try { json = JSON.parse(buf.toString('utf8')); } catch { /* binary or plain text */ }
        resolve({ status: res.statusCode, json, buf, text: buf.toString('utf8') });
      });
    });
    r.on('error', reject);
    if (payload !== null) r.write(payload);
    r.end();
  });
}

before(async () => {
  fs.mkdirSync(path.join(TMP_HOME, 'storages'), { recursive: true });
  fs.writeFileSync(path.join(TMP_HOME, 'storages', 'workspace.json'), JSON.stringify({
    global: { initialized: true, archivedSessionIds: [] },
    tables: { workspaces: {} }
  }), 'utf8');

  const effectFns = [];
  const mockCtx = {
    logger: () => ({ info() {}, warn() {}, error() {}, log() {} }),
    webServer: { port: 3080 },
    connection: { rpc: { handle: () => async () => {} } },
    effect: (fn) => { effectFns.push(fn); return () => {}; },
    on: (evt, fn) => { if (evt === 'dispose') effectFns.push(fn); }
  };
  const disposer = apply(mockCtx, { port: PORT }, { port: PORT, dshPort: DEAD_DSH_PORT, isListening: true });
  teardown = async () => {
    try { await disposer?.(); } catch { /* ignore */ }
    for (const fn of effectFns) {
      try { await fn(); } catch { /* ignore */ }
    }
  };

  for (let i = 0; i < 50; i++) {
    try { await req('/api/mobile/health'); return; } catch { await new Promise((r) => setTimeout(r, 100)); }
  }
  throw new Error('bridge did not start');
});

after(async () => {
  try { await teardown?.(); } catch { /* ignore */ }
  await new Promise((r) => setTimeout(r, 300));
  try { fs.rmSync(TMP_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
});

describe('GET /api/mobile/attachment', () => {
  it('路由存在且要求传入 id（此前该路由根本不存在 → 图片必然 404）', async () => {
    const { status, json } = await req('/api/mobile/attachment');
    assert.equal(status, 400);
    assert.equal(json?.ok, false);
    assert.match(String(json?.error), /id/);
  });

  it('缺少 sessionId 时必须拒绝 —— 引擎按会话授权图片读取', async () => {
    const { status, json } = await req('/api/mobile/attachment?id=abc');
    assert.equal(status, 400);
    assert.equal(json?.ok, false);
    assert.match(String(json?.error), /sessionId/);
  });

  it('参数齐全但引擎不可达时返回 404 而不是崩溃', async () => {
    const { status, json } = await req('/api/mobile/attachment?id=abc&sessionId=s1');
    assert.equal(status, 404);
    assert.equal(json?.ok, false);
  });
});

describe('POST /api/mobile/upload', () => {
  it('缺少 sessionId 时拒绝', async () => {
    const { status, json } = await req('/api/mobile/upload', {
      method: 'POST', raw: 'hello', contentType: 'application/octet-stream'
    });
    assert.equal(status, 400);
    assert.match(String(json?.error), /sessionId/);
  });

  it('空文件被拒绝', async () => {
    const { status, json } = await req('/api/mobile/upload?sessionId=s1', {
      method: 'POST', raw: '', contentType: 'application/octet-stream'
    });
    assert.equal(status, 400);
    assert.match(String(json?.error), /空文件/);
  });

  it('引擎不可达时返回 502 且带出原因，不吞成笼统失败', async () => {
    const { status, json } = await req('/api/mobile/upload?sessionId=s1&name=a.txt', {
      method: 'POST', raw: 'some bytes', contentType: 'application/octet-stream'
    });
    assert.equal(status, 502);
    assert.equal(json?.ok, false);
    assert.ok(String(json?.error).length > 0);
  });
});

describe('prompt 的附件准入规则', () => {
  it('无文字且无附件 → 明确的必填校验拒绝', async () => {
    const { status, json } = await req('/api/mobile/sessions/prompt', {
      method: 'POST', body: { sessionId: 's1', text: '   ' }
    });
    assert.equal(status, 400);
    assert.match(String(json?.error), /Missing or empty prompt text/);
  });

  it('只有附件、没有文字 → 必须通过必填校验（引擎允许"文字或附件"）', async () => {
    const { status, json } = await req('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: {
        sessionId: 's1',
        text: '',
        attachments: [{ type: 'image', mediaType: 'image/jpeg', data: 'AAAA', name: 'x.jpg' }]
      }
    });
    // 引擎在这个测试里不可达，所以最终会失败 —— 但**绝不能**是那条文本必填的
    // 400。走到后面的失败恰恰证明附件把它带过了校验。
    assert.notEqual(status, 400, `不应是校验性 400，实际：${json?.error ?? ''}`);
    assert.doesNotMatch(String(json?.error ?? ''), /Missing or empty prompt text/);
  });

  it('无文字但带 file receipt → 同样通过必填校验', async () => {
    const { status, json } = await req('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: 's1', text: '', attachments: [{ type: 'file', receiptId: 'r-1' }] }
    });
    assert.notEqual(status, 400, `不应是校验性 400，实际：${json?.error ?? ''}`);
  });

  it('畸形附件被忽略：既无有效附件也无文字 → 仍按必填拒绝', async () => {
    const { status, json } = await req('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: {
        sessionId: 's1',
        text: '',
        // 媒体类型不是 image/*、receiptId 为空 —— 两条都该被丢掉
        attachments: [{ type: 'image', mediaType: 'text/plain', data: 'AAAA' }, { type: 'file', receiptId: '' }]
      }
    });
    assert.equal(status, 400);
    assert.match(String(json?.error), /Missing or empty prompt text/);
  });
});
