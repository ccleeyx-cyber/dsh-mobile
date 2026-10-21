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
    const url = releaseUrl('2026.9.1', 'linux');
    assert.match(url, /releases\/download\/2026\.9\.1\/cloudflared-linux-amd64$/);
    // [fix 2026-10-21] 钉住的版本必须与同机实际在用的对齐：本机原来跑 2026.2.0
    // 而 dsh-pocket 用 2026.9.1，旧版会额外报 cfd-features DNS 超时。
    assert.equal(CLOUDFLARED_VERSION, '2026.9.1');
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

  // [fix 2026-10-21] 「文件存在」不等于「版本够新」。本机原来一直复用 2026.2.0
  // （2 月构建），而同机 dsh-pocket 用 2026.9.1 —— 后者连得上边缘，前者会额外报
  // `cfd-features.argotunnel.com` DNS 超时。这条用例把升级路径钉住。
  it('本机二进制版本旧也继续用（升级不能阻塞隧道），版本一致更不该重下', async () => {
    const oldBytes = Buffer.alloc(2048, 3);
    const newBytes = Buffer.alloc(4096, 4);
    const dir = path.join(TMP_HOME, 'dl-version');
    let fetches = 0;
    const fetchBytes = async () => { fetches++; return newBytes; };

    // 先放一份"旧版"。注意文件名必须是**本地二进制名**（`cloudflared`），
    // 不是 release asset 名（`cloudflared-linux-amd64`）—— 早先这条用例写错了
    // 文件名，于是 dest 根本不存在，它"通过"是因为一直在测下载路径。
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, platformAsset('linux').bin), oldBytes);

    const upgraded = await ensureCloudflared({
      dir,
      platform: 'linux',
      version: '2026.9.1',
      probeVersionFn: () => '2026.2.0',
      fetchBytes,
      findSystemFn: () => ''
    });
    // [fix 2026-10-21] 这里原来断言的是"版本不符必须重下"。那个策略在真机上
    // 把唯一能用的二进制删了、下载卡死 → 隧道再也起不来。现在的规则是：
    // 旧版**继续用**（实测 2026.2.0 能正常注册），升级不阻塞隧道。
    assert.equal(fetches, 0, '版本旧不能删掉能用的二进制');
    assert.equal(upgraded.downloaded, false);
    assert.equal(upgraded.from, 'cache-old');
    assert.equal(upgraded.version, '2026.2.0');

    // 版本一致时也是复用
    const reused = await ensureCloudflared({
      dir,
      platform: 'linux',
      version: '2026.9.1',
      probeVersionFn: () => '2026.9.1',
      fetchBytes,
      findSystemFn: () => ''
    });
    assert.equal(fetches, 0, '版本一致不该重复下载');
    assert.equal(reused.downloaded, false);
    assert.equal(reused.from, 'cache');
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
      // findSystemFn 注入空实现：否则会真的扫到本机已有的 cloudflared，
      // 于是"下载"这一步根本不发生，这条用例就白写了。
      () => ensureCloudflared({ dir, platform: 'linux', fetchBytes: async () => html, findSystemFn: () => '' }),
      /网页而不是可执行文件/
    );
  });

  it('没有下载实现时给出可操作的错误（离线环境）', async () => {
    await assert.rejects(
      () => ensureCloudflared({
        dir: path.join(TMP_HOME, 'dl-e'),
        platform: 'linux',
        findSystemFn: () => ''
      }),
      /没有下载实现/
    );
  });

  // [fix 2026-10-21] 这次"点了没反应"的直接修法：机器上已经有可用的
  // cloudflared（例如 dsh-pocket 下好的那份）就不该再去下载 50MB。
  it('系统里已有 cloudflared 时直接复用，不下载', async () => {
    const dir = path.join(TMP_HOME, 'dl-sys');
    fs.mkdirSync(dir, { recursive: true });
    const sysBin = path.join(TMP_HOME, 'sys-cloudflared');
    fs.writeFileSync(sysBin, Buffer.alloc(4096, 9));
    let fetches = 0;
    const out = await ensureCloudflared({
      dir,
      platform: 'linux',
      findSystemFn: () => sysBin,
      probeVersionFn: () => '2026.9.1',
      fetchBytes: async () => { fetches++; return Buffer.alloc(4096, 2); }
    });
    assert.equal(fetches, 0, '有现成的就不该下载');
    assert.equal(out.path, sysBin);
    assert.equal(out.from, 'system');
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

    // 只拿到域名不算 ready：quick tunnel 先打印域名、再去连边缘，域名可能死。
    assert.equal(tunnel.status, 'starting');
    assert.equal(tunnel.url, 'https://alpha-beta-77.trycloudflare.com');
    assert.deepEqual(urls, ['https://alpha-beta-77.trycloudflare.com']);

    fake.stderr.emit('data', Buffer.from('INF Registered tunnel connection connIndex=0\n'));
    assert.equal(tunnel.status, 'ready');
  });

  it('边缘握手失败要如实降级为 failed 并保留原因', () => {
    const fake = new EventEmitter();
    fake.stdout = new EventEmitter();
    fake.stderr = new EventEmitter();
    fake.kill = () => {};

    const tunnel = createQuickTunnel({
      binary: '/fake/cloudflared',
      spawnFn: () => fake,
      logger: { warn() {} }
    });
    tunnel.start();
    fake.stderr.emit('data', Buffer.from('https://dead-addr.trycloudflare.com'));
    fake.stderr.emit('data', Buffer.from(
      'ERR Unable to establish connection with Cloudflare edge error="TLS handshake with edge error: EOF" connIndex=0\n'
    ));

    assert.equal(tunnel.status, 'failed');
    assert.equal(tunnel.url, '', '连不上边缘的域名不能继续广播');
    assert.match(tunnel.lastError, /TLS handshake with edge error/);
  });

  // [fix 2026-10-21] 边缘连不上时 cloudflared 不报错，只会以 2→4→8→16→32s 的
  // 退避**无限重试**。真机症状：域名已经拿到、TCP 7844 探测还显示"可达"（本机
  // Clash TUN 会把 connect 伪造成成功），但注册永远不成功 —— 界面于是永远
  // "未就绪"。三次重试还不行就必须给出结论，而不是让用户猜。
  it('边缘反复重试要判失败并给出可操作的原因（不能永远 starting）', () => {
    const fake = new EventEmitter();
    fake.stdout = new EventEmitter();
    fake.stderr = new EventEmitter();
    fake.kill = () => {};

    const tunnel = createQuickTunnel({
      binary: '/fake/cloudflared',
      spawnFn: () => fake,
      logger: { warn() {} }
    });
    tunnel.start();
    fake.stderr.emit('data', Buffer.from('INF | https://dead-addr.trycloudflare.com |'));
    fake.stderr.emit('data', Buffer.from('INF Retrying connection in up to 2s connIndex=0 event=0 ip=198.41.192.57\n'));
    fake.stderr.emit('data', Buffer.from('INF Retrying connection in up to 4s connIndex=0 event=0 ip=198.41.192.67\n'));

    // 两次还在重试：宽容期，保持 starting（网络抖动不该立刻判死）。
    assert.equal(tunnel.status, 'starting');
    assert.equal(tunnel.url, 'https://dead-addr.trycloudflare.com');

    fake.stderr.emit('data', Buffer.from('INF Retrying connection in up to 8s connIndex=0 event=0 ip=198.41.192.47\n'));

    assert.equal(tunnel.status, 'failed');
    assert.equal(tunnel.url, '', '注册不成功的域名不能继续广播');
    assert.match(tunnel.lastError, /Cloudflare 隧道边缘/);
    assert.match(tunnel.lastError, /NPS/, '要给出替代方案，否则用户只能看到"未就绪"');
  });

  // [fix 2026-10-21] 与 dsh-pocket 对齐的两条：
  //   * 强制 http2（QUIC 走 UDP 7844，国内网络常被屏蔽 → 1033）；
  //   * 目标用**明文 loopback** —— 公网那段由 Cloudflare 终结 TLS，本机这段是
  //     回环，明文没有暴露面。之前"必须先有 TLS 端口"是多余前提。
  it('默认启动参数：http2 + 明文 loopback 目标（不再依赖本机 TLS）', () => {
    const spawned = [];
    const fake = new EventEmitter();
    fake.stdout = new EventEmitter();
    fake.stderr = new EventEmitter();
    fake.kill = () => {};
    createQuickTunnel({
      binary: '/fake/cloudflared',
      target: 'http://127.0.0.1:3088',
      spawnFn: (_bin, args) => { spawned.push(args); return fake; },
      logger: { warn() {} }
    }).start();
    assert.equal(spawned.length, 1);
    const args = spawned[0];
    assert.ok(args.includes('--protocol') && args.includes('http2'));
    assert.ok(args.includes('--url'), 'quick tunnel 必须带 --url');
    assert.equal(args[args.indexOf('--url') + 1], 'http://127.0.0.1:3088');
    assert.equal(args[0], '--no-autoupdate', '--no-autoupdate 必须在全局位置（子命令之前）');
  });

  it('cloudflared 输出里的 api.trycloudflare.com 不能被当成隧道地址', () => {
    // 申请失败时 cloudflared 打印：
    //   failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel"
    // 旧正则会把 api 子域当隧道地址发出去，手机打它会得到 10005 Method Not Allowed。
    assert.equal(parseTunnelUrl('Post "https://api.trycloudflare.com/tunnel": timeout'), null);
    assert.equal(parseTunnelUrl('https://api.trycloudflare.com'), null);
    assert.equal(parseTunnelUrl('INF | https://a-b-c.trycloudflare.com |'),
      'https://a-b-c.trycloudflare.com');
  });

  it('建立超时要判失败并点名代理/TUN（不能永远 starting）', async () => {
    const fake = new EventEmitter();
    fake.stdout = new EventEmitter();
    fake.stderr = new EventEmitter();
    fake.kill = () => {};
    const tunnel = createQuickTunnel({
      binary: '/fake/cloudflared',
      spawnFn: () => fake,
      timeoutMs: 30,
      logger: { warn() {} }
    });
    tunnel.start();
    // 什么输出都没有：进程活着但一声不响
    await new Promise((r) => setTimeout(r, 80));
    assert.equal(tunnel.status, 'failed');
    assert.match(tunnel.lastError, /超时/);
    assert.match(tunnel.lastError, /Clash|代理/, '要指出最常见的元凶，否则用户无从下手');
  });

  it('命名隧道：token 走 tunnel run，就绪后用配置域名当地址', () => {
    const spawned = [];
    const fake = new EventEmitter();
    fake.stdout = new EventEmitter();
    fake.stderr = new EventEmitter();
    fake.kill = () => {};
    const urls = [];
    const tunnel = createQuickTunnel({
      binary: '/fake/cloudflared',
      token: 'eyJfake-token',
      host: 'dsh.example.com',
      spawnFn: (_bin, args) => { spawned.push(args); return fake; },
      onUrl: (u) => urls.push(u),
      logger: { warn() {} }
    });
    tunnel.start();
    const args = spawned[0];
    assert.ok(args.includes('run'), '命名隧道用 tunnel run 子命令');
    assert.ok(!args.includes('--url'), '命名隧道不能带 --url');
    assert.ok(args.includes('http2'));

    // 命名隧道的地址不由 cloudflared 打印，注册成功后才由配置域名补上
    fake.stderr.emit('data', Buffer.from('INF Registered tunnel connection connIndex=0\n'));
    assert.equal(tunnel.status, 'ready');
    assert.equal(tunnel.url, 'https://dsh.example.com');
    assert.deepEqual(urls, ['https://dsh.example.com']);
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
