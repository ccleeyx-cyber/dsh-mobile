/**
 * 归档 / 取消归档 / 删除会话：网关必须走引擎的 workspace/* RPC。
 *
 * 背景（2026-11-15 实测定根因）：archiveSession() 与 deleteSession() 以前直接
 * 改 `~/.dsh/storages/workspace.json` 的 `global.archivedSessionIds`，而该文件是
 * 引擎 workspaceRegistry 的存储——引擎在内存里持有同一份状态，任何注册表操作
 * （pin/unpin、归档、工作区建/删/排序、启动 bootstrap）都会按内存态**整体重写**
 * 文件。旁路写入会被静默回滚：活体实验（植入标记 id → 引擎内存无它 → 一次
 * workspace/pinSession+unpinSession → 文件被重写、标记消失）证明手机归档
 * "看着成功、过会儿变回去、电脑端永远看不到"的根因正是这里。
 *
 * 本测试用一个**假引擎**（空闲端口上的 HTTP）接住 RPC，断言：
 *
 *  1. POST /api/mobile/sessions/archive {archive:true} → 网关调
 *     workspace/archiveSession，且带 stopActivity:true（与 delete 的硬语义对齐）。
 *  2. {archive:false} → 网关调 workspace/unarchiveSession（无 stopActivity）。
 *  3. 引擎报错 → 502 原样透出，不伪装成功，也**绝不**退回直写文件的旧路径。
 *  4. 非法 sessionId → 400，一次上游调用都不发。
 *  5. delete 路由：先调 workspace/archiveSession（归档名单交引擎权威），
 *     再做文件层 detach；响应保持 {ok, message:'Deleted', sessionId, detached}。
 *
 * 全程 DSH_HOME 指向临时目录，绝不打真实网关或引擎。
 */

import { describe, it, before, after, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-archive-home-'));
process.env.DSH_HOME = TMP_HOME;

const { apply } = await import('../../dsh-server-plugin/lib/index.js');
const { loadConfig } = await import('../../dsh-server-plugin/lib/store.mjs');
const { detachSession } = await import('../../dsh-server-plugin/lib/core.mjs');
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
/** 每个 method 的响应工厂；返回 null 表示"回一个失败"。 */
let engineHandlers = {};

const engineServer = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const rawBody = Buffer.concat(chunks).toString('utf8');
    let payload = null;
    try { payload = JSON.parse(rawBody); } catch { /* ignore */ }
    const method = String(req.url || '').replace(/^\/api\//, '');
    engineCalls.push({ method, payload, rawBody });

    const handler = engineHandlers[method];
    if (handler === undefined) {
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
    res.end(JSON.stringify({ result: { ok: true, value: out } }));
  });
});

let teardown = null;

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
    { port: PORT },
    { port: PORT, dshPort: ENGINE_PORT, isListening: true }
  );
  teardown = async () => {
    try { await disposer?.(); } catch { /* ignore */ }
    for (const fn of effectFns) { try { await fn(); } catch { /* ignore */ } }
  };
}

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
const OTHER_ID = 'session-99999999-8888-7777-6666-555555555555';

/** 临时 DSH_HOME 下的 workspace store，供 delete 路由的文件层 detach 读。 */
function writeWorkspaceStore(sessionIds) {
  fs.mkdirSync(path.join(TMP_HOME, 'storages'), { recursive: true });
  fs.writeFileSync(
    path.join(TMP_HOME, 'storages', 'workspace.json'),
    JSON.stringify({
      global: { archivedSessionIds: [] },
      tables: { workspaces: { 'ws-1': { workspaceId: 'ws-1', sessionIds } } }
    }, null, 2),
    'utf8'
  );
}

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
    'workspace/archiveSession': () => ({ archivedSessionIds: [SESSION_ID] }),
    'workspace/unarchiveSession': () => ({ archivedSessionIds: [] })
  };
});

describe('POST /api/mobile/sessions/archive', () => {
  it('归档走引擎 RPC workspace/archiveSession，带 stopActivity:true', async () => {
    const r = await req('/api/mobile/sessions/archive', { body: { sessionId: SESSION_ID, archive: true } });
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.equal(r.json.archived, true);
    assert.equal(r.json.sessionId, SESSION_ID);

    assert.equal(engineCallCount('workspace/archiveSession'), 1);
    const call = engineCall('workspace/archiveSession');
    assert.equal(call.method, 'workspace/archiveSession');
    // 请求体必须是 args.request.{sessionId, stopActivity} —— 引擎的 descriptor
    // 要求 request 字段，漏了会 arguments-invalid。
    assert.equal(call.payload?.args?.request?.sessionId, SESSION_ID);
    assert.equal(call.payload?.args?.request?.stopActivity, true);
  });

  it('取消归档走 workspace/unarchiveSession，不带 stopActivity', async () => {
    const r = await req('/api/mobile/sessions/archive', { body: { sessionId: SESSION_ID, archive: false } });
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.equal(r.json.archived, false);

    assert.equal(engineCallCount('workspace/unarchiveSession'), 1);
    const call = engineCall('workspace/unarchiveSession');
    assert.equal(call.payload?.args?.request?.sessionId, SESSION_ID);
    assert.equal(call.payload?.args?.request?.stopActivity, undefined);
    assert.equal(engineCallCount('workspace/archiveSession'), 0);
  });

  it('缺省 archive 字段按归档处理（archive !== false）', async () => {
    const r = await req('/api/mobile/sessions/archive', { body: { sessionId: SESSION_ID } });
    assert.equal(r.status, 200);
    assert.equal(r.json.archived, true);
    assert.equal(engineCallCount('workspace/archiveSession'), 1);
  });

  it('引擎报错 → 502 透传，不伪装成功', async () => {
    engineHandlers['workspace/archiveSession'] = () => new Error('boom: session active');
    const r = await req('/api/mobile/sessions/archive', { body: { sessionId: SESSION_ID, archive: true } });
    assert.equal(r.status, 502);
    assert.equal(r.json.ok, false);
    assert.ok(String(r.json.error).includes('boom'));
  });

  it('非法 sessionId → 400，零次上游调用', async () => {
    const r = await req('/api/mobile/sessions/archive', { body: { sessionId: '../escape/attempt' } });
    assert.equal(r.status, 400);
    assert.equal(r.json.ok, false);
    assert.equal(engineCalls.length, 0);
  });

  it('引擎方法不存在 → 502，而不是回退直写文件', async () => {
    engineHandlers['workspace/archiveSession'] = null;
    const r = await req('/api/mobile/sessions/archive', { body: { sessionId: SESSION_ID, archive: true } });
    assert.equal(r.status, 502);
    // 关键回归锁：失败后绝不能把 sessionId 偷偷写进 workspace.json ——
    // 那正是"手机归档看似生效、过会儿被引擎回滚"的旧故障模式。
    const wsPath = path.join(TMP_HOME, 'storages', 'workspace.json');
    if (fs.existsSync(wsPath)) {
      const ws = JSON.parse(fs.readFileSync(wsPath, 'utf8'));
      assert.equal(
        (ws.global?.archivedSessionIds || []).includes(SESSION_ID),
        false,
        '引擎失败后网关不得直写归档名单（旧路径复活即本 bug 复活）'
      );
    }
  });
});

describe('POST /api/mobile/sessions/delete', () => {
  it('先引擎归档（stopActivity:true），再文件层 detach，响应保持原形状', async () => {
    writeWorkspaceStore([SESSION_ID, OTHER_ID]);
    const r = await req('/api/mobile/sessions/delete', { body: { sessionId: SESSION_ID } });
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.equal(r.json.message, 'Deleted');
    assert.equal(r.json.sessionId, SESSION_ID);
    assert.equal(r.json.detached, 1);

    assert.equal(engineCallCount('workspace/archiveSession'), 1);
    const call = engineCall('workspace/archiveSession');
    assert.equal(call.payload?.args?.request?.sessionId, SESSION_ID);
    assert.equal(call.payload?.args?.request?.stopActivity, true);

    // 文件层：会话从工作区表里消失，另一个不受影响。
    const ws = JSON.parse(fs.readFileSync(path.join(TMP_HOME, 'storages', 'workspace.json'), 'utf8'));
    const rows = ws.tables.workspaces['ws-1'].sessionIds;
    assert.ok(!rows.includes(SESSION_ID));
    assert.ok(rows.includes(OTHER_ID));
  });

  it('引擎归档失败 → 502，不做任何文件层动作', async () => {
    writeWorkspaceStore([SESSION_ID]);
    engineHandlers['workspace/archiveSession'] = () => new Error('engine down');
    const r = await req('/api/mobile/sessions/delete', { body: { sessionId: SESSION_ID } });
    assert.equal(r.status, 502);
    assert.equal(r.json.ok, false);

    const ws = JSON.parse(fs.readFileSync(path.join(TMP_HOME, 'storages', 'workspace.json'), 'utf8'));
    assert.ok(ws.tables.workspaces['ws-1'].sessionIds.includes(SESSION_ID));
  });

  it('非法 sessionId → 400，零次上游调用', async () => {
    const r = await req('/api/mobile/sessions/delete', { body: { sessionId: 'x y z' } });
    assert.equal(r.status, 400);
    assert.equal(r.json.ok, false);
    assert.equal(engineCalls.length, 0);
  });
});

describe('core.mjs 文件层函数的语义锁（无引擎场景仍可用）', () => {
  it('detachSession 只 detach，不碰归档名单', () => {
    writeWorkspaceStore([SESSION_ID, OTHER_ID]);
    const result = detachSession({ home: TMP_HOME, sessionId: SESSION_ID });
    assert.equal(result.ok, true);
    assert.equal(result.detached, 1);

    const ws = JSON.parse(fs.readFileSync(path.join(TMP_HOME, 'storages', 'workspace.json'), 'utf8'));
    const rows = ws.tables.workspaces['ws-1'].sessionIds;
    assert.ok(!rows.includes(SESSION_ID));
    // 归档名单必须原样不动：那是引擎的权威域。
    assert.deepEqual(ws.global.archivedSessionIds, []);
  });
});
