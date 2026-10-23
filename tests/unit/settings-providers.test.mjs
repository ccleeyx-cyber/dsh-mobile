/**
 * [feat 2026-10-22] 模型设置按供应商分组 —— 网关侧。
 *
 * 用户原话：「模型设置没有分组，需要按不同的供应商分组显示」。根因在网关：它原先
 * 把 `cordis.patch.yml` 里每个 provider 的 models 拍平成 **一个数组**，供应商身份在
 * 拍平那一刻就丢了 —— 手机端再聪明也分不出来。
 *
 * 这里起真网关（DSH_HOME 隔离到临时目录），只断言**线上形状**：每条模型带
 * `provider`/`providerLabel`，另有一份带条数的 `providers` 索引。
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-settings-providers-'));
process.env.DSH_HOME = TMP_HOME;
process.env.BRIDGE_TLS_PORT = '0';

// 两个供应商、三家模型：和真机上的形状一致（wb 挂 `cn:*`，qwen 挂 codex/gpt）。
const PROFILE_DIR = path.join(TMP_HOME, 'profiles', 'web');
fs.mkdirSync(PROFILE_DIR, { recursive: true });
fs.writeFileSync(path.join(PROFILE_DIR, 'cordis.patch.yml'), [
  '- id: llm-pi-ai',
  '  name: "@deepseek-ai/dsh-llm-pi-ai"',
  '  config:',
  '    providers:',
  '      wb:',
  '        apiKeyEnv: WB_API_KEY',
  '        models:',
  '          - id: cn:auto',
  '            name: cn:auto',
  '          - id: cn:deepseek-v4-pro',
  '            name: DeepSeek V4 Pro',
  '      qwen:',
  '        displayName: qwen 云端',
  '        apiKeyEnv: QWEN_API_KEY',
  '        models:',
  '          - id: gpt-5.2',
  '            name: GPT-5.2',
  ''
].join('\n'), 'utf8');

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

function req(pathname) {
  return new Promise((resolve, reject) => {
    const r = http.request(`${BASE}${pathname}`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` }
    }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(data); } catch { /* ignore */ }
        resolve({ status: res.statusCode, parsed });
      });
    });
    r.on('error', reject);
    r.end();
  });
}

let teardown = null;

describe('模型列表按供应商分组', () => {
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

  it('每条模型带 provider 与 providerLabel', async () => {
    const r = await req('/api/mobile/settings');
    assert.equal(r.status, 200);
    const models = r.parsed.settings.availableModels;
    assert.ok(Array.isArray(models) && models.length === 3);

    const byId = Object.fromEntries(models.map((m) => [m.id, m]));
    assert.equal(byId['cn:auto'].provider, 'wb');
    assert.equal(byId['cn:deepseek-v4-pro'].provider, 'wb');
    assert.equal(byId['gpt-5.2'].provider, 'qwen');
    // displayName 是给人看的标题；没配就用 key
    assert.equal(byId['gpt-5.2'].providerLabel, 'qwen 云端');
    assert.equal(byId['cn:auto'].providerLabel, 'wb');
  });

  it('providers 索引按首次出现顺序给出供应商与条数', async () => {
    const r = await req('/api/mobile/settings');
    const providers = r.parsed.settings.providers;
    assert.deepEqual(providers, [
      { id: 'wb', label: 'wb', count: 2 },
      { id: 'qwen', label: 'qwen 云端', count: 1 }
    ]);
  });
});
