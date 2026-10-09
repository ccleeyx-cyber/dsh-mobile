/**
 * Archived-session filtering on GET /api/mobile/workspaces (§4 会话归档筛选).
 *
 * Boots the real Cordis entry against a throwaway DSH_HOME, so it never reads or
 * writes the live ~/.dsh. Every fixture here is synthetic.
 *
 * Two things are under test:
 *   1. the three-mode filter (exclude / only / include) and its `archivedMode`
 *      echo, which is what lets the phone tell "filtered" from "gateway too old
 *      to know about this param";
 *   2. B0 — getSettingsData() must not be called per session. It is a synchronous
 *      readFileSync + YAML.parse, and archived mode iterates ~1338 rows on this
 *      box, so a functional assertion cannot catch the regression: the response
 *      is identical either way. The read is therefore counted directly.
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-archived-home-'));
process.env.DSH_HOME = TMP_HOME;

// Count reads of the file getSettingsData() parses. Patched before the plugin is
// imported; the node:fs default export is a mutable object, so this works.
let patchYmlReads = 0;
const realReadFileSync = fs.readFileSync;
fs.readFileSync = function patched(p, ...rest) {
  if (typeof p === 'string' && p.replace(/\\/g, '/').endsWith('profiles/web/cordis.patch.yml')) {
    patchYmlReads++;
  }
  return realReadFileSync.call(fs, p, ...rest);
};

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

let teardown = null;

function req(pathname, { headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const r = http.request(`${BASE}${pathname}`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}`, ...headers }
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
    r.end();
  });
}

// --------------------------------------------------------------- fixtures --

const WS_JSON = path.join(TMP_HOME, 'storages', 'workspace.json');
const CACHE_DIR = path.join(TMP_HOME, 'storages', 'session_projcache', 'sessions');

function writeWorkspace(doc) {
  fs.mkdirSync(path.dirname(WS_JSON), { recursive: true });
  fs.writeFileSync(WS_JSON, JSON.stringify(doc), 'utf8');
}

function writeCache(sessionId, { title = null, firstPrompt = null, blank = false, model = null, lastPromptAt = 1700000000000 } = {}) {
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  const rows = {};
  if (title != null) rows.title = { val: title };
  if (firstPrompt != null) rows.titleInput = { val: { first: { text: firstPrompt } } };
  rows.sessionListMetadata = { val: { blank, lastPromptAt } };
  if (model != null) rows.modelSelection = { val: { lastUsed: { model } } };
  fs.writeFileSync(
    path.join(CACHE_DIR, `${sessionId}.json`),
    JSON.stringify({ record: { identity: { createdAt: lastPromptAt }, rows } }),
    'utf8'
  );
}

/**
 * The small fixture. Seven registered sessions in ws-a covering every way an id
 * can appear in `archivedSessionIds`, plus one blank session that must be dropped
 * in all three modes, and a second workspace with nothing archived.
 *
 *   live-1, live-2            not archived
 *   arch-bare                 archived, list holds the bare id
 *   session-arch-prefixed     archived, list holds the prefixed id
 *   session-archclean         archived, list holds the BARE id → cleanId branch
 *   archpref                  archived, list holds the PREFIXED id → `session-${cleanId}` branch
 *   blank-1                   not archived, blank → filtered everywhere
 */
function smallFixture() {
  writeWorkspace({
    global: {
      initialized: true,
      archivedSessionIds: ['arch-bare', 'session-arch-prefixed', 'archclean', 'session-archpref']
    },
    tables: {
      workspaces: {
        'ws-a': {
          title: '工作区A',
          path: 'E:\\ws\\a',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-02T00:00:00Z',
          sessionIds: ['live-1', 'live-2', 'arch-bare', 'session-arch-prefixed', 'session-archclean', 'archpref', 'blank-1']
        },
        'ws-b': {
          title: '工作区B',
          path: 'E:\\ws\\b',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          sessionIds: ['live-3']
        }
      }
    }
  });

  writeCache('live-1', { title: '未归档一', firstPrompt: 'p1', model: 'cn:m1' });
  writeCache('live-2', { title: '未归档二', firstPrompt: 'p2', model: 'cn:m2' });
  writeCache('live-3', { title: 'B区会话', firstPrompt: 'p3', model: 'cn:m3' });
  writeCache('arch-bare', { title: '已归档·裸id', model: 'cn:m4' });
  writeCache('session-arch-prefixed', { title: '已归档·带前缀', model: 'cn:m5' });
  writeCache('archclean', { title: '已归档·cleanId命中', model: 'cn:m6' });
  writeCache('archpref', { title: '已归档·补前缀命中', model: 'cn:m7' });
  // blank: no titleInput text → sessionVisible-equivalent filter drops it.
  writeCache('blank-1', { blank: true });
}

const WS_A_ARCHIVED_IDS = ['arch-bare', 'session-arch-prefixed', 'session-archclean', 'archpref'];

function wsA(data) {
  const ws = (data?.workspaces || []).find((w) => w.workspaceId === 'ws-a');
  assert.ok(ws, 'ws-a must be present in the response');
  return ws;
}

function ids(ws) {
  return ws.sessions.map((s) => s.sessionId).sort();
}

// Root-level hooks on purpose. The instance is booted once and shared by both
// describes; putting `after` inside the first one would rmSync TMP_HOME before
// the second describe had run, and every bulk-fixture test would fail on a
// missing directory rather than on anything meaningful.
before(async () => {
  smallFixture();

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
    try { await req('/api/mobile/health'); return; } catch { await new Promise((r) => setTimeout(r, 100)); }
  }
  throw new Error('bridge did not start');
});

after(async () => {
  fs.readFileSync = realReadFileSync;
  try { await teardown?.(); } catch { /* ignore */ }
  await new Promise((r) => setTimeout(r, 300));
  try { fs.rmSync(TMP_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
});

describe('GET /api/mobile/workspaces?archived=…', () => {
  it('无参数时保持历史行为：只返回未归档会话', async () => {
    const r = await req('/api/mobile/workspaces');
    assert.equal(r.status, 200);
    assert.equal(r.data.ok, true);
    assert.equal(r.data.archivedMode, 'exclude');
    assert.deepEqual(ids(wsA(r.data)), ['live-1', 'live-2']);
  });

  it('archived=exclude 与无参数完全等价', async () => {
    const r = await req('/api/mobile/workspaces?archived=exclude');
    assert.equal(r.data.archivedMode, 'exclude');
    assert.deepEqual(ids(wsA(r.data)), ['live-1', 'live-2']);
  });

  it('archived=only 只返回已归档会话', async () => {
    const r = await req('/api/mobile/workspaces?archived=only');
    assert.equal(r.data.archivedMode, 'only');
    assert.deepEqual(ids(wsA(r.data)), [...WS_A_ARCHIVED_IDS].sort());
  });

  it('archived=include 两者都返回，且每行的 archived 标志正确', async () => {
    const r = await req('/api/mobile/workspaces?archived=include');
    assert.equal(r.data.archivedMode, 'include');
    const a = wsA(r.data);
    // blank-1 is dropped in every mode, so 6 of the 7 registered sessions.
    assert.equal(a.sessions.length, 6);

    for (const s of a.sessions) {
      const expected = WS_A_ARCHIVED_IDS.includes(s.sessionId);
      assert.equal(s.archived, expected, `${s.sessionId} 的 archived 标志应为 ${expected}`);
    }
    assert.equal(a.sessions.filter((s) => s.archived).length, 4);
    assert.equal(a.sessions.filter((s) => !s.archived).length, 2);
  });

  it('archived 标志在 exclude/only 模式下也存在（响应是自描述的）', async () => {
    const only = await req('/api/mobile/workspaces?archived=only');
    assert.ok(wsA(only.data).sessions.every((s) => s.archived === true));

    const excl = await req('/api/mobile/workspaces?archived=exclude');
    assert.ok(wsA(excl.data).sessions.every((s) => s.archived === false));
  });

  it('四种 id 写法都能被识别为已归档', async () => {
    const r = await req('/api/mobile/workspaces?archived=only');
    const got = ids(wsA(r.data));
    // arch-bare            → 名单里是裸 id，sessionIds 里也是裸 id
    // session-arch-prefixed→ 名单里带前缀，sessionIds 里也带前缀
    // session-archclean    → 名单里是裸 id，靠 cleanId 分支命中
    // archpref             → 名单里带前缀，靠 `session-${cleanId}` 分支命中
    assert.deepEqual(got, ['arch-bare', 'archpref', 'session-arch-prefixed', 'session-archclean']);
  });

  it('空白会话在三种模式下都被过滤', async () => {
    for (const mode of ['exclude', 'only', 'include']) {
      const r = await req(`/api/mobile/workspaces?archived=${mode}`);
      const all = (r.data.workspaces || []).flatMap((w) => w.sessions.map((s) => s.sessionId));
      assert.ok(!all.includes('blank-1'), `blank-1 不应出现在 ${mode} 模式`);
    }
  });

  it('archivedCount 与请求模式无关，恒为该工作区的归档总数', async () => {
    for (const mode of ['exclude', 'only', 'include']) {
      const r = await req(`/api/mobile/workspaces?archived=${mode}`);
      assert.equal(wsA(r.data).archivedCount, 4, `${mode} 模式下 archivedCount 应恒为 4`);
    }
    // ws-b 没有归档会话。
    const r = await req('/api/mobile/workspaces');
    const b = r.data.workspaces.find((w) => w.workspaceId === 'ws-b');
    assert.equal(b.archivedCount, 0);
    assert.deepEqual(b.sessions.map((s) => s.sessionId), ['live-3']);
  });

  it('sessionCount 恒等于本次响应里的 sessions 长度', async () => {
    for (const mode of ['exclude', 'only', 'include']) {
      const r = await req(`/api/mobile/workspaces?archived=${mode}`);
      for (const w of r.data.workspaces) {
        assert.equal(w.sessionCount, w.sessions.length, `${mode}/${w.workspaceId}`);
      }
    }
  });

  it('归档会话的标题取自 projcache，而不是退化成裸 id', async () => {
    const r = await req('/api/mobile/workspaces?archived=only');
    const byId = Object.fromEntries(wsA(r.data).sessions.map((s) => [s.sessionId, s]));
    assert.equal(byId['arch-bare'].title, '已归档·裸id');
    assert.equal(byId['session-archclean'].title, '已归档·cleanId命中');
    assert.equal(byId['archpref'].model, 'cn:m7');
  });

  it('非法的 archived 值归一化为 exclude，并如实回显', async () => {
    for (const bad of ['bogus', 'ONLY', '1', 'true', '']) {
      const r = await req(`/api/mobile/workspaces?archived=${encodeURIComponent(bad)}`);
      assert.equal(r.status, 200);
      assert.equal(r.data.archivedMode, 'exclude', `archived=${bad} 应归一化为 exclude`);
      assert.deepEqual(ids(wsA(r.data)), ['live-1', 'live-2']);
    }
  });

  it('重复参数被 url.parse 解析成数组，安全归一化为 exclude', async () => {
    const r = await req('/api/mobile/workspaces?archived=only&archived=include');
    assert.equal(r.status, 200);
    assert.equal(r.data.archivedMode, 'exclude');
  });

  it('archivedMode 始终出现在响应里（客户端据此判定网关是否支持）', async () => {
    for (const qs of ['', '?archived=only', '?archived=include', '?archived=nope']) {
      const r = await req(`/api/mobile/workspaces${qs}`);
      assert.ok(typeof r.data.archivedMode === 'string', `${qs} 缺少 archivedMode 回显`);
      assert.ok(['exclude', 'only', 'include'].includes(r.data.archivedMode));
    }
  });

  it('新参数不能绕过鉴权', async () => {
    for (const qs of ['?archived=only', '?archived=include']) {
      const r = await new Promise((resolve, reject) => {
        const rq = http.request(`${BASE}/api/mobile/workspaces${qs}`, { method: 'GET' }, (res) => {
          res.resume();
          res.on('end', () => resolve({ status: res.statusCode }));
        });
        rq.on('error', reject);
        rq.end();
      });
      assert.equal(r.status, 401, `未带 token 请求 ${qs} 必须 401`);
    }
  });

  it('错误 token 同样 401', async () => {
    const r = await req('/api/mobile/workspaces?archived=only', { headers: { Authorization: 'Bearer wrong-token' } });
    assert.equal(r.status, 401);
  });

  it('workspace.json 不存在时三种模式都返回空数组而不是 500', async () => {
    const saved = fs.readFileSync(WS_JSON, 'utf8');
    fs.rmSync(WS_JSON);
    try {
      for (const mode of ['exclude', 'only', 'include']) {
        const r = await req(`/api/mobile/workspaces?archived=${mode}`);
        assert.equal(r.status, 200, `${mode} 模式应 200`);
        assert.deepEqual(r.data.workspaces, []);
        assert.equal(r.data.archivedMode, mode);
      }
    } finally {
      fs.writeFileSync(WS_JSON, saved, 'utf8');
    }
  });

  it('archivedSessionIds 里的孤儿 id（不属于任何工作区）不会凭空造出会话', async () => {
    const saved = fs.readFileSync(WS_JSON, 'utf8');
    const doc = JSON.parse(saved);
    // 本机实测就有 12 个这种孤儿 id（名单 1350，命中 sessionIds 的只有 1338）。
    doc.global.archivedSessionIds.push('ghost-1', 'session-ghost-2');
    writeWorkspace(doc);
    try {
      const r = await req('/api/mobile/workspaces?archived=only');
      const all = r.data.workspaces.flatMap((w) => w.sessions.map((s) => s.sessionId));
      assert.ok(!all.includes('ghost-1'));
      assert.ok(!all.includes('session-ghost-2'));
      assert.equal(wsA(r.data).archivedCount, 4, '孤儿 id 不该被计入任何工作区');
    } finally {
      fs.writeFileSync(WS_JSON, saved, 'utf8');
    }
  });
});

describe('B0：getSettingsData() 不再按会话逐条调用', () => {
  before(async () => {
    // 复用上一个 describe 启动的同一个实例（node:test 按文件顺序跑）。
    // 这里换成一个大 fixture：1500 个已归档会话，全部没有 modelSelection，
    // 于是每一个都会走 model 回退分支 —— 正是修复前会触发 1500 次
    // readFileSync + YAML.parse 的场景。
    const N = 1500;
    const sessionIds = [];
    const archived = [];
    for (let i = 0; i < N; i++) {
      const id = `bulk-${i}`;
      sessionIds.push(id);
      archived.push(id);
      writeCache(id, { title: `批量会话 ${i}` }); // 故意不写 model
    }
    writeWorkspace({
      global: { initialized: true, archivedSessionIds: archived },
      tables: {
        workspaces: {
          'ws-a': { title: '工作区A', path: 'E:\\ws\\a', updatedAt: '2026-01-02T00:00:00Z', sessionIds }
        }
      }
    });

    // cordis.patch.yml 存在才会被 readFileSync；不存在时 getSettingsData 走
    // existsSync 短路，计数恒为 0，测不出东西。
    const patchPath = path.join(TMP_HOME, 'profiles', 'web', 'cordis.patch.yml');
    fs.mkdirSync(path.dirname(patchPath), { recursive: true });
    if (!fs.existsSync(patchPath)) {
      fs.writeFileSync(patchPath, '[]\n', 'utf8');
    }
  });

  it('1500 个缺 model 的会话，cordis.patch.yml 只被读取一次', async () => {
    patchYmlReads = 0;
    const r = await req('/api/mobile/workspaces?archived=only');
    assert.equal(r.status, 200);
    assert.equal(wsA(r.data).sessions.length, 1500, '大 fixture 应全部返回');
    assert.equal(patchYmlReads, 1,
      `getSettingsData() 应按调用记忆化一次，实际读了 ${patchYmlReads} 次（修复前会是 1500 次）`);
  });

  it('回退模型确实被填上了（记忆化没有把值弄丢）', async () => {
    const r = await req('/api/mobile/workspaces?archived=only');
    const sessions = wsA(r.data).sessions;
    assert.ok(sessions.length > 0);
    for (const s of sessions.slice(0, 20)) {
      assert.ok(typeof s.model === 'string' && s.model.length > 0, `${s.sessionId} 的 model 不应为空`);
    }
  });

  it('同一批数据再请求一次，读取次数仍然只增加一次', async () => {
    patchYmlReads = 0;
    await req('/api/mobile/workspaces?archived=only');
    const afterFirst = patchYmlReads;
    await req('/api/mobile/workspaces?archived=only');
    const afterSecond = patchYmlReads;
    assert.equal(afterFirst, 1);
    assert.equal(afterSecond, 2, '每次请求各记忆化一次，而不是每会话一次');
  });
});
