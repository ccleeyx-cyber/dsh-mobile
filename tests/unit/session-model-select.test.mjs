/**
 * 会话级切模型：网关必须走引擎的 `session/selectModel`。
 *
 * 背景（2026-10-16 实测）：这个路由以前只把 `{provider:'wb', model}` 写进投影缓存
 * 文件，从不告诉引擎。投影缓存是引擎折叠日志的**输出**（字段语义是"最近一次已记录
 * 请求消耗的选择"），手写进去等于断言一件没发生过的事 —— 证据是在 App 里切换后在
 * 引擎侧 26 分钟内没有任何 `model/selection` 事件，请求仍跑旧模型。
 *
 * 这里用一个**假引擎**（空闲端口上的 HTTP）接住 RPC，断言：
 *
 *  1. provider 从引擎的模型目录里解析出来，而不是硬编码 `'wb'`。
 *  2. 目录里没有的模型 → 502 且**不调用** selectModel（旧实现会照样回 200）。
 *  3. 引擎报错 → 502 原样透出，不伪装成功。
 *  4. 参数缺失 / 非法 sessionId → 400，且一次上游调用都不发。
 *
 * 全程 DSH_HOME 指向临时目录，绝不打真实网关或引擎。
 */

import { describe, it, before, after, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-selectmodel-home-'));
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
const ENGINE_PORT = await pickFreePort();
const BASE = `http://127.0.0.1:${PORT}`;

/** 假引擎收到的调用，按顺序。 */
let engineCalls = [];
/** 每个 method 的响应工厂；返回 null 表示"这个 method 不该被调用"。 */
let engineHandlers = {};

const CATALOG = {
  default: { provider: 'wb', model: 'cn:auto' },
  routableProviders: ['wb', 'other'],
  groups: [
    { id: 'wb', name: 'wb', models: [{ id: 'cn:auto', name: 'cn:auto' }, { id: 'cn:glm-5.3', name: 'cn:glm-5.3' }] },
    // 另一个 provider：旧实现硬编码 'wb' 时，切到这个模型会写出一对不匹配的组合。
    { id: 'other', name: 'other', models: [{ id: 'other-model', name: 'other-model' }] }
  ],
  failures: []
};

const engineServer = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    let payload = null;
    const rawBody = Buffer.concat(chunks).toString('utf8');
    try { payload = JSON.parse(rawBody); } catch { /* ignore */ }
    const method = String(req.url || '').replace(/^\/api\//, '');
    engineCalls.push({ method, payload, rawBody });

    const handler = engineHandlers[method];
    if (handler === undefined) {
      // 未登记的方法：回一个空成功值，免得插件的启动探测把测试淹掉。
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ result: { ok: true, value: {} } }));
      return;
    }
    if (handler === null) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ result: { ok: false, error: `unknown method ${method}` } }));
      return;
    }
    const out = typeof handler === 'function' ? handler(payload) : handler;
    if (out instanceof Error) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ result: { ok: false, error: out.message } }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    const responseBody = JSON.stringify({ result: { ok: true, value: out } });
    res.end(responseBody);
  });
});

let teardown = null;

/**
 * 装**一个**插件实例（挂在 beforeEach 里重装会反复抢同一个端口，实测会让
 * 后续用例拿到 ECONNRESET）。
 *
 * 不重装就得处理插件内部的模型目录缓存：`modelCatalogTtlMs: 0` 把它关掉，
 * 否则"目录读取失败"这类用例会命中上一个用例缓存下来的目录。
 */
async function mountPlugin() {
  const effectFns = [];
  const mockCtx = {
    logger: () => ({ info() {}, warn() {}, error() {}, log() {} }),
    webServer: { port: 3080 },
    connection: { rpc: { handle: () => async () => {} } },
    effect: (fn) => { effectFns.push(fn); return () => {}; },
    on: (evt, fn) => { if (evt === 'dispose') effectFns.push(fn); }
  };
  const disposer = apply(
    mockCtx,
    { port: PORT, modelCatalogTtlMs: 0 },
    { port: PORT, dshPort: ENGINE_PORT, isListening: true }
  );
  teardown = async () => {
    try { await disposer?.(); } catch { /* ignore */ }
    for (const fn of effectFns) { try { await fn(); } catch { /* ignore */ } }
  };
}

/** 假引擎收到的某个方法的**真实报文体**（解析后）。断言只依赖这一份真相。 */
function engineCall(method) {
  const hit = engineCalls.find((c) => c.method === method);
  return hit ? JSON.parse(hit.rawBody) : null;
}

function engineCallCount(method) {
  return engineCalls.filter((c) => c.method === method).length;
}

function req(pathname, { method = 'POST', body = null } = {}) {
  return new Promise((resolve, reject) => {
    const raw = body === null ? null : JSON.stringify(body);
    const headers = { Authorization: `Bearer ${TOKEN}` };
    if (raw !== null) {
      headers['Content-Type'] = 'application/json';
      headers['Content-Length'] = Buffer.byteLength(raw);
    }
    const r = http.request(`${BASE}${pathname}`, { method, headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json = null;
        try { json = JSON.parse(text); } catch { /* non-JSON */ }
        resolve({ status: res.statusCode, json, text });
      });
    });
    r.on('error', reject);
    if (raw !== null) r.write(raw);
    r.end();
  });
}

const SESSION_ID = 'session-11111111-2222-3333-4444-555555555555';

before(async () => {
  await new Promise((res) => engineServer.listen(ENGINE_PORT, '127.0.0.1', res));
  fs.mkdirSync(path.join(TMP_HOME, 'storages'), { recursive: true });
  await mountPlugin();
});

after(async () => {
  await teardown?.();
  await new Promise((res) => engineServer.close(res));
  try { fs.rmSync(TMP_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
});

beforeEach(() => {
  engineCalls = [];
  engineHandlers = {
    'session/modelCatalog': () => CATALOG,
    // 按引擎的真实契约回 `SessionSelectModelValue = {selected: ModelSelection}`。
    // 额外带一个 `reasoningEffort`：网关自己的兜底值只可能拼出 {provider, model}，
    // 所以这个字段出现在回包里，就证明回包确实来自引擎而不是兜底。
    'session/selectModel': (envelope) => {
      const request = envelope?.payload?.args?.request ?? {};
      return { selected: { provider: request.provider, model: request.model, reasoningEffort: 'medium' } };
    }
  };
});

describe('POST /api/mobile/sessions/model · 走引擎', () => {
  it('provider 从模型目录解析（不是硬编码 wb），并把 selection 透传给引擎', async () => {
    const r = await req('/api/mobile/sessions/model', { body: { sessionId: SESSION_ID, model: 'other-model' } });
    assert.equal(r.status, 200, r.text);
    assert.equal(r.json.ok, true);

    assert.equal(engineCallCount('session/selectModel'), 1, '必须恰好调用一次 session/selectModel');
    const call = engineCall('session/selectModel');
    assert.deepEqual(call.payload.args.request, {
      sessionId: SESSION_ID,
      provider: 'other',
      model: 'other-model'
    });

    // 同一个目录下的 wb 模型也必须解析成 wb（而不是被写死或被上一条污染）
    engineCalls = [];
    const r2 = await req('/api/mobile/sessions/model', { body: { sessionId: SESSION_ID, model: 'cn:glm-5.3' } });
    assert.equal(r2.status, 200, r2.text);
    assert.equal(engineCall('session/selectModel').payload.args.request.provider, 'wb');
  });

  it('回包原样透出引擎接受的 selection（不是网关自己拼的兜底值）', async () => {
    const r = await req('/api/mobile/sessions/model', { body: { sessionId: SESSION_ID, model: 'cn:auto' } });
    assert.equal(r.status, 200);
    assert.equal(engineCallCount('session/selectModel'), 1,
      `应该调一次 selectModel；实收 [${engineCalls.map((c) => c.method).join(', ')}]`);
    assert.deepEqual(r.json.selected, { provider: 'wb', model: 'cn:auto', reasoningEffort: 'medium' },
      `网关回包=${JSON.stringify(r.json)}`);
  });

  it('目录里没有的模型 → 502，且绝不调用 selectModel', async () => {
    const r = await req('/api/mobile/sessions/model', { body: { sessionId: SESSION_ID, model: 'nope-not-real' } });
    assert.equal(r.status, 502, r.text);
    assert.equal(r.json.ok, false);
    assert.match(r.json.error, /找不到 nope-not-real/);
    assert.equal(engineCallCount('session/selectModel'), 0,
      '模型不在目录里时不能"照样成功" —— 旧实现正是如此');
  });

  it('目录 RPC 失败 → 502 且说明是读目录失败', async () => {
    engineHandlers['session/modelCatalog'] = () => new Error('connect ECONNREFUSED');
    const r = await req('/api/mobile/sessions/model', { body: { sessionId: SESSION_ID, model: 'cn:auto' } });
    assert.equal(r.status, 502, r.text);
    assert.match(r.json.error, /读取模型目录失败/);
    assert.equal(engineCallCount('session/selectModel'), 0);
  });

  it('selectModel 失败 → 502 并原样透出引擎的错误，不伪装成功', async () => {
    engineHandlers['session/selectModel'] = () => new Error('session/not-found');
    const r = await req('/api/mobile/sessions/model', { body: { sessionId: SESSION_ID, model: 'cn:auto' } });
    assert.equal(r.status, 502, r.text);
    assert.match(r.json.error, /session\/not-found/);
  });

  it('缺参数 / 非法 sessionId → 400，且一次上游调用都不发', async () => {
    for (const body of [
      { model: 'cn:auto' },
      { sessionId: SESSION_ID },
      { sessionId: '../../../etc/passwd', model: 'cn:auto' }
    ]) {
      const r = await req('/api/mobile/sessions/model', { body });
      assert.equal(r.status, 400, `expected 400 for ${JSON.stringify(body)} got ${r.status} ${r.text}`);
    }
    assert.equal(engineCalls.length, 0, '非法请求不该碰引擎');
  });
});
