/**
 * [feat 2026-10-22] 新建工作区「点选」—— 网关侧的目录选择器。
 *
 * 用户原话：「新建工作区目前是手写，这个要改成点选」。这一组测试钉住的是
 * **边界**而不是画界面：
 *
 *  1. 只回**子目录**，不回文件（选目录这件事用不到文件名，回了就是白泄露）；
 *  2. 隐藏目录不进列表（`.git` / `.ssh` 这类不该出现在手机上）；
 *  3. 相对路径、设备路径（`\\?\`）直接拒绝 —— 它们是绕过范围校验的经典形状；
 *  4. 已登记的目录要能如实标出来（`registered`），否则用户会重复建同一个工作区。
 *
 * 全部 hermetic：DSH_HOME 用 mkdtempSync 隔离，只读自己的临时目录。
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-ws-browse-'));
const PROJECTS = path.join(TMP_HOME, 'proj');
const ONE = path.join(PROJECTS, 'one');
const TWO = path.join(PROJECTS, 'two');
const HIDDEN = path.join(PROJECTS, '.hidden');

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

const browse = (dir) => req(`/api/mobile/workspaces/browse?path=${encodeURIComponent(dir)}`);

let teardown = null;

describe('新建工作区：目录选择器', () => {
  before(async () => {
    // 一棵最小的目录树 + 一份登记过的工作区。
    for (const dir of [ONE, TWO, HIDDEN]) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(ONE, 'README.md'), '# one\n', 'utf8');
    fs.mkdirSync(path.join(TMP_HOME, 'storages'), { recursive: true });
    fs.writeFileSync(path.join(TMP_HOME, 'storages', 'workspace.json'), JSON.stringify({
      tables: {
        workspaces: {
          'ws-one': { path: ONE, title: '一号工程', sessionIds: [], createdAt: '2026-10-01T00:00:00.000Z' }
        }
      },
      global: {}
    }, null, 2), 'utf8');

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

  it('roots 至少给出「已登记工作区父目录 + 主目录」两类起点', async () => {
    const r = await req('/api/mobile/workspaces/roots');
    assert.equal(r.status, 200);
    assert.equal(r.parsed.ok, true);
    assert.ok(Array.isArray(r.parsed.roots) && r.parsed.roots.length > 0);

    const paths = r.parsed.roots.map((x) => x.path);
    const kinds = r.parsed.roots.map((x) => x.kind);
    // 父目录（proj）：用户最常做的事是"在同一层再建一个"
    assert.ok(paths.includes(PROJECTS), `roots 应包含 ${PROJECTS}`);
    assert.ok(kinds.includes('home'), 'roots 应包含主目录');
    // 已登记的工作区本身也在里面
    assert.ok(paths.includes(ONE), 'roots 应包含已登记工作区');
    assert.equal(r.parsed.defaultPath, r.parsed.roots[0].path);
  });

  it('列目录只回子目录，且跳过隐藏目录', async () => {
    const r = await browse(PROJECTS);
    assert.equal(r.status, 200);
    assert.equal(r.parsed.ok, true);
    const names = r.parsed.entries.map((e) => e.name).sort();
    assert.deepEqual(names, ['one', 'two'], `实际: ${names.join(',')}`);
    // 文件不该出现（README.md 在 one/ 里）
    assert.ok(!names.includes('README.md'));
    // 每个条目带绝对路径，客户端不需要自己拼
    for (const e of r.parsed.entries) assert.ok(path.isAbsolute(e.path));
  });

  it('已登记的目录会被如实标出来', async () => {
    const inside = await browse(ONE);
    assert.equal(inside.parsed.ok, true);
    assert.deepEqual(inside.parsed.registered, { workspaceId: 'ws-one', title: '一号工程' });
    // 未登记的同级目录不能也报 registered
    const sibling = await browse(TWO);
    assert.equal(sibling.parsed.registered, null);
  });

  it('相对路径 / 设备路径一律拒绝', async () => {
    const relative = await browse('proj');
    assert.equal(relative.status, 400);
    assert.equal(relative.parsed.ok, false);

    const device = await browse('\\\\?\\C:\\Windows');
    assert.equal(device.status, 400);
    assert.equal(device.parsed.ok, false);
  });

  it('不存在的目录给一句人话，而不是空列表', async () => {
    const r = await browse(path.join(PROJECTS, 'no-such-dir'));
    assert.equal(r.parsed.ok, false);
    assert.match(r.parsed.error, /不存在/);
  });
});
