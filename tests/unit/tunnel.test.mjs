/**
 * v1.35 / 1.5 — cloudflared quick tunnel 托管
 *
 * 全 hermetic：下载用注入的 fetchBytes，进程用假 spawn，不打真实网络、
 * 不真的启动 cloudflared。
 *
 * 钉住的行为（每一条都对应一个真实事故模式）：
 *   - 地址解析只认 trycloudflare.com 域名（输出格式随版本变）；
 *   - 哈希不匹配必须拒绝并**不留半成品文件**（否则下次启动误判已安装）；
 *   - 已存在且校验通过的文件不重复下载（每次重启都下载 = 每次重启都几十 MB）；
 *   - 进程退出后地址作废（否则手机拿着死域名无限重连）；
 *   - 重启换地址会触发 onUrl（quick tunnel 地址本来就不稳定）。
 */

import { describe, it, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-tunnel-home-'));
process.env.DSH_HOME = TMP_HOME;

const {
  parseTunnelUrl,
  ensureCloudflared,
  createQuickTunnel,
  tunnelBinDir,
  platformAsset,
  releaseUrl,
  CLOUDFLARED_VERSION
} = await import('../../dsh-server-plugin/lib/tunnel.mjs');

describe('tunnel: quick tunnel 解析与生命周期', () => {
  after(() => {
    try { fs.rmSync(TMP_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
  });

  it('从日志里抠出 trycloudflare 地址', () => {
    const line = 'INF |  https://brave-forest-1234.trycloudflare.com  |';
    assert.equal(parseTunnelUrl(line), 'https://brave-forest-1234.trycloudflare.com');
    assert.equal(parseTunnelUrl('no url here'), null);
    assert.equal(parseTunnelUrl(''), null);
  });

  it('平台映射与下载地址固定到版本', () => {
    assert.equal(platformAsset('win32').asset, 'cloudflared-windows-amd64.exe');
    assert.equal(platformAsset('linux').asset, 'cloudflared-linux-amd64');
    const url = releaseUrl('2026.2.0', 'linux');
    assert.match(url, /releases\/download\/2026\.2\.0\/cloudflared-linux-amd64$/);
    assert.equal(CLOUDFLARED_VERSION, '2026.2.0');
  });

  it('下载后按 sha256 校验并存到插件私有目录', async () => {
    const bytes = Buffer.alloc(4096, 7);
    const expected = crypto.createHash('sha256').update(bytes).digest('hex');
    const dir = path.join(TMP_HOME, 'dl-a');

    const r = await ensureCloudflared({
      dir,
      platform: 'linux',
      expectedSha256: expected,
      fetchBytes: async (url) => {
        assert.match(url, /cloudflared-linux-amd64/);
        return bytes;
      }
    });

    assert.equal(r.downloaded, true);
    assert.equal(r.verifiedBy, 'sha256');
    assert.equal(fs.readFileSync(r.path).length, 4096);
    assert.equal(fs.existsSync(r.path + '.part'), false, '不能留下 .part 半成品');
  });

  it('已存在且校验通过时不重复下载', async () => {
    const bytes = Buffer.alloc(2048, 1);
    const expected = crypto.createHash('sha256').update(bytes).digest('hex');
    const dir = path.join(TMP_HOME, 'dl-b');
    let fetches = 0;
    const fetchBytes = async () => { fetches++; return bytes; };

    await ensureCloudflared({ dir, platform: 'linux', expectedSha256: expected, fetchBytes });
    const second = await ensureCloudflared({ dir, platform: 'linux', expectedSha256: expected, fetchBytes });

    assert.equal(fetches, 1);
    assert.equal(second.downloaded, false);
  });

  it('哈希不匹配拒绝安装，并把坏文件清掉', async () => {
    const dir = path.join(TMP_HOME, 'dl-c');
    const bytes = Buffer.alloc(4096, 2);
    await assert.rejects(
      () => ensureCloudflared({
        dir,
        platform: 'linux',
        expectedSha256: 'f'.repeat(64),
        fetchBytes: async () => bytes
      }),
      /校验失败/
    );
    // 目标文件不能存在，.part 也不能留下
    assert.equal(fs.existsSync(path.join(dir, 'cloudflared')), false);
    assert.equal(fs.existsSync(path.join(dir, 'cloudflared.part')), false);
  });

  it('把网页当成二进制下载会被识破', async () => {
    const dir = path.join(TMP_HOME, 'dl-d');
    const html = Buffer.from('<!DOCTYPE html><html>blocked by proxy</html>' + 'x'.repeat(2000));
    await assert.rejects(
      () => ensureCloudflared({ dir, platform: 'linux', fetchBytes: async () => html }),
      /网页而不是可执行文件/
    );
  });

  it('没有下载实现时给出可操作的错误（离线环境）', async () => {
    await assert.rejects(
      () => ensureCloudflared({ dir: path.join(TMP_HOME, 'dl-e'), platform: 'linux' }),
      /没有下载实现/
    );
  });

  it('tunnelBinDir 落在 mobile-access/bin 下', () => {
    assert.equal(tunnelBinDir(), path.join(TMP_HOME, 'mobile-access', 'bin'));
  });

  it('启动后从输出里拿到地址并回调 onUrl', async () => {
    const urls = [];
    const fake = new EventEmitter();
    fake.stdout = new EventEmitter();
    fake.stderr = new EventEmitter();
    fake.kill = () => { fake.emit('exit', 0, null); };

    const tunnel = createQuickTunnel({
      binary: '/fake/cloudflared',
      spawnFn: () => fake,
      onUrl: (u) => urls.push(u),
      logger: { warn() {} }
    });

    tunnel.start();
    assert.equal(tunnel.status, 'starting');
    fake.stderr.emit('data', Buffer.from('INF Starting tunnel\n'));
    fake.stderr.emit('data', Buffer.from('INF |  https://alpha-beta-77.trycloudflare.com  |\n'));

    assert.equal(tunnel.status, 'ready');
    assert.equal(tunnel.url, 'https://alpha-beta-77.trycloudflare.com');
    assert.deepEqual(urls, ['https://alpha-beta-77.trycloudflare.com']);
  });

  it('进程退出后地址作废并回调 onExit', () => {
    const exits = [];
    const fake = new EventEmitter();
    fake.stdout = new EventEmitter();
    fake.stderr = new EventEmitter();
    fake.kill = () => {};

    const tunnel = createQuickTunnel({
      binary: '/fake/cloudflared',
      spawnFn: () => fake,
      onExit: (e) => exits.push(e),
      logger: { warn() {} }
    });
    tunnel.start();
    fake.stderr.emit('data', Buffer.from('https://one-two-3.trycloudflare.com'));
    assert.equal(tunnel.url, 'https://one-two-3.trycloudflare.com');

    fake.emit('exit', 1, null);
    assert.equal(tunnel.url, '', '死进程的域名必须立刻失效');
    assert.equal(tunnel.status, 'failed');
    assert.equal(exits.length, 1);
    assert.match(exits[0].error, /code=1/);
  });

  it('stop() 后不再标记为失败', () => {
    const fake = new EventEmitter();
    fake.stdout = new EventEmitter();
    fake.stderr = new EventEmitter();
    fake.kill = () => { fake.emit('exit', 0, null); };

    const tunnel = createQuickTunnel({
      binary: '/fake/cloudflared',
      spawnFn: () => fake,
      logger: { warn() {} }
    });
    tunnel.start();
    tunnel.stop();
    assert.equal(tunnel.status, 'stopped');
    assert.equal(tunnel.url, '');
  });

  it('restart() 换地址会再次回调 onUrl', () => {
    const urls = [];
    const spawned = [];
    const makeFake = () => {
      const f = new EventEmitter();
      f.stdout = new EventEmitter();
      f.stderr = new EventEmitter();
      f.kill = () => { f.emit('exit', 0, null); };
      spawned.push(f);
      return f;
    };
    const tunnel = createQuickTunnel({
      binary: '/fake/cloudflared',
      spawnFn: () => makeFake(),
      onUrl: (u) => urls.push(u),
      logger: { warn() {} }
    });
    tunnel.start();
    spawned[0].stderr.emit('data', Buffer.from('https://first-addr.trycloudflare.com'));

    tunnel.restart();
    assert.equal(spawned.length, 2);
    spawned[1].stderr.emit('data', Buffer.from('https://second-addr.trycloudflare.com'));

    assert.deepEqual(urls, [
      'https://first-addr.trycloudflare.com',
      'https://second-addr.trycloudflare.com'
    ]);
  });

  it('spawn 抛错时降级为 failed，不抛出到调用方', () => {
    const tunnel = createQuickTunnel({
      binary: '/fake/cloudflared',
      spawnFn: () => { throw new Error('ENOENT'); },
      logger: { warn() {} }
    });
    assert.doesNotThrow(() => tunnel.start());
    assert.equal(tunnel.status, 'failed');
    assert.match(tunnel.lastError, /ENOENT/);
  });

  it('没有二进制时不启动、不抛错', () => {
    const tunnel = createQuickTunnel({ binary: '', spawnFn: () => { throw new Error('must not spawn'); } });
    tunnel.start();
    assert.equal(tunnel.status, 'failed');
    assert.match(tunnel.lastError, /缺少 cloudflared/);
  });
});
