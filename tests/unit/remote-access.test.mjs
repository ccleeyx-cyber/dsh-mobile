/**
 * 「远程接入」配置模型（[refactor 2026-10-21]）。
 *
 * 钉住的是**互斥**与**旧配置零回归**这两件事：
 *   - provider 只有三种，且 nps 缺 host 时不能停在"看起来配置好了"的状态；
 *   - 现有安装的 config.json 里只有顶层 npsHost/npsPort/useHttps，必须被映射成
 *     provider='nps'，不能让老用户升级后突然变成"没配远程访问"；
 *   - 新模型写回时，顶层三个字段要跟着同步，否则旧读者（client.js 面板、旧版
 *     App）看到的是过期值。
 */

import { describe, it, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-remote-access-'));
process.env.DSH_HOME = TMP_HOME;

const store = await import('../../dsh-server-plugin/lib/store.mjs');

function configPath() {
  return path.join(TMP_HOME, 'mobile-bridge', 'config.json');
}

function writeConfig(raw) {
  fs.mkdirSync(path.dirname(configPath()), { recursive: true });
  fs.writeFileSync(configPath(), JSON.stringify(raw, null, 2), 'utf8');
}

describe('remote access model', () => {
  beforeEach(() => {
    try { fs.rmSync(configPath(), { force: true }); } catch { /* ignore */ }
  });

  after(() => {
    try { fs.rmSync(TMP_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
  });

  it('fresh install 默认 none（不再假装装了某个人的 NPS 域名）', () => {
    const cfg = store.loadConfig();
    assert.equal(cfg.remoteAccess.provider, 'none');
    assert.equal(cfg.remoteAccess.nps.host, '');
    assert.equal(cfg.npsHost, '');
  });

  it('旧配置（只有顶层 npsHost）映射为 provider=nps，零回归', () => {
    writeConfig({ token: 't', port: 3088, npsHost: 'n.example.com', npsPort: 3443, useHttps: true });
    const cfg = store.loadConfig();
    assert.equal(cfg.remoteAccess.provider, 'nps');
    assert.deepEqual(cfg.remoteAccess.nps, { host: 'n.example.com', port: 3443, useHttps: true });
    // 兼容字段仍然可读，且与模型一致
    assert.equal(cfg.npsHost, 'n.example.com');
    assert.equal(cfg.npsPort, 3443);
    assert.equal(cfg.useHttps, true);
  });

  it('选 cloudflared 时清空出口地址，但保留 NPS 字段备切换', () => {
    writeConfig({ token: 't', port: 3088, npsHost: 'n.example.com', npsPort: 3443 });
    const saved = store.saveConfig({ remoteAccess: { provider: 'cloudflared' } });
    assert.equal(saved.remoteAccess.provider, 'cloudflared');
    assert.equal(saved.remoteAccess.nps.host, 'n.example.com', '切回 nps 时不用重填');
    assert.equal(saved.npsHost, 'n.example.com');
    // 落盘后重读仍然一致
    assert.equal(store.loadConfig().remoteAccess.provider, 'cloudflared');
  });

  it('provider=nps 但缺 host 时回落 none（不能停在无效态）', () => {
    writeConfig({ token: 't', port: 3088 });
    const saved = store.saveConfig({ remoteAccess: { provider: 'nps' } });
    assert.equal(saved.remoteAccess.provider, 'none');
  });

  it('旧调用方只写 npsHost 时自动切到 provider=nps', () => {
    writeConfig({ token: 't', port: 3088, remoteAccess: { provider: 'none', nps: { host: '', port: 3088, useHttps: false } } });
    const saved = store.saveConfig({ npsHost: 'n2.example.com', npsPort: 4000 });
    assert.equal(saved.remoteAccess.provider, 'nps');
    assert.equal(saved.remoteAccess.nps.host, 'n2.example.com');
    assert.equal(saved.npsPort, 4000);
  });

  it('显式选 none 会被保留（不会被旧字段"顺手"改回 nps）', () => {
    writeConfig({ token: 't', port: 3088, npsHost: 'n.example.com' });
    const saved = store.saveConfig({ remoteAccess: { provider: 'none' } });
    assert.equal(saved.remoteAccess.provider, 'none');
  });

  // [fix 2026-10-21] audit 以前只写内存环形缓冲，磁盘那份是更早实现的死文件
  // （真机最后一行是 09-28）。于是隧道为什么失败、谁在什么时候切了 provider，
  // 重启后一个字都不剩 —— 排查只能靠猜。这条用例钉住"必须落盘"。
  it('audit 必须落盘（失败现场不能只活在内存里）', () => {
    store.audit('tunnel/exit', { error: 'edge blocked: 7844' });
    const f = path.join(TMP_HOME, 'mobile-bridge', 'audit.log');
    assert.ok(fs.existsSync(f), 'audit.log 必须被创建');
    const lines = fs.readFileSync(f, 'utf8').trim().split('\n').filter(Boolean);
    const last = JSON.parse(lines[lines.length - 1]);
    assert.equal(last.action, 'tunnel/exit');
    assert.match(String(last.reason ?? ''), /edge blocked/);
    assert.equal(typeof last.time, 'number');
  });
});
