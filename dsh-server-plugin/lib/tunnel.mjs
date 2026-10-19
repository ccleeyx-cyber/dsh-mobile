// dsh-server-plugin cloudflared quick tunnel 托管（v1.35 / 任务 1.5）
//
// 目标：一条命令把网关从"只在局域网可用"变成"外面也能连"，且**不要求用户
// 先注册 Cloudflare 账号**。quick tunnel 是 cloudflared 的免登录模式，代价是
// 地址每次重连都会变、官方定位为测试用途——所以它只是"临时通道"，长期地址
// 留给 named tunnel（需要域名）与自有反代，那两档不在本期。
//
// 设计上的三个硬约束：
//   1. **绝不阻塞启动**：下载失败、cloudflared 不存在、网络断，都只 degrade
//      成「隧道不可用 + 一句可操作的提示」，网关本体照常工作。
//   2. **二进制必须校验**：默认校验 sha256（DSH_CLOUDFLARED_SHA256 或调用方
//      传入）；没配哈希时退化为 `--version` 探测——至少能挡住"下到一个 HTML
//      错误页就当成可执行文件跑"。
//   3. **生命周期绑宿主**：隧道进程必须随 dsh web 退出而退出，否则宿主机上
//      会攒下一堆孤儿 cloudflared 进程，各自占着一条公网隧道。
//
// 测试全部用假二进制 + 注入的 fetchBytes，不打真实网络（见
// tests/unit/tunnel.test.mjs）。真实下载只发生在生产路径上。

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn as nodeSpawn } from 'node:child_process';
import { dshHome } from './store.mjs';

/** 固定版本：不跟随 latest，避免某天上游发新版把行为改掉。 */
export const CLOUDFLARED_VERSION = '2026.2.0';

export function tunnelBinDir() {
  return path.join(dshHome(), 'mobile-access', 'bin');
}

/** 平台 → 官方 release 资产名与本地文件名。 */
export function platformAsset(platform = process.platform) {
  if (platform === 'win32') {
    return { asset: 'cloudflared-windows-amd64.exe', bin: 'cloudflared.exe' };
  }
  if (platform === 'darwin') {
    return { asset: 'cloudflared-darwin-amd64.tgz', bin: 'cloudflared.tgz' };
  }
  return { asset: 'cloudflared-linux-amd64', bin: 'cloudflared' };
}

export function releaseUrl(version = CLOUDFLARED_VERSION, platform = process.platform) {
  const { asset } = platformAsset(platform);
  return `https://github.com/cloudflare/cloudflared/releases/download/${version}/${asset}`;
}

/**
 * 从 cloudflared 的输出里抠出 quick tunnel 地址。
 *
 * 实测输出形如：
 *   INF |  https://random-words-here.trycloudflare.com  |
 * 版本之间格式会变，所以只认域名本身——这是唯一稳定的锚点。
 * @returns {string|null}
 */
export function parseTunnelUrl(text) {
  if (!text) return null;
  const m = String(text).match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/i);
  return m ? m[0] : null;
}

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

/**
 * 确保本机有一份可用的 cloudflared。
 *
 * @param {object} opts
 * @param {(url: string) => Promise<Buffer>} [opts.fetchBytes] 下载实现（测试注入）
 * @param {string} [opts.expectedSha256] 期望哈希；不传则读 env
 * @param {string} [opts.version]
 * @param {string} [opts.platform]
 * @param {string} [opts.dir]
 * @returns {Promise<{path: string, downloaded: boolean, verifiedBy: string}>}
 */
export async function ensureCloudflared({
  fetchBytes,
  fetchToFile,
  binaryPath,
  expectedSha256,
  version = CLOUDFLARED_VERSION,
  platform = process.platform,
  dir = tunnelBinDir()
} = {}) {
  const { bin } = platformAsset(platform);
  const dest = path.join(dir, bin);
  const expected = String(expectedSha256 ?? process.env.DSH_CLOUDFLARED_SHA256 ?? '')
    .trim()
    .toLowerCase();

  const verify = (file) => {
    if (expected) {
      const got = sha256File(file);
      if (got !== expected) {
        throw new Error(`cloudflared 校验失败：期望 ${expected.slice(0, 12)}…，实际 ${got.slice(0, 12)}…`);
      }
      return 'sha256';
    }
    // 没配哈希时的最低限度校验：文件得像一个二进制，而不是 HTML 错误页。
    const head = fs.readFileSync(file).subarray(0, 256);
    if (head.includes('<!DOCTYPE') || head.includes('<html')) {
      throw new Error('cloudflared 下载内容看起来是网页而不是可执行文件');
    }
    return 'header';
  };

  // 0) 用户已经装好了 cloudflared（scoop / choco / 手工下载）：直接用，不下载。
  //    这是「下载通道被拦」时唯一可靠的出路——实测本机 Node 的 https 在
  //    release-assets.githubusercontent.com 上握手会被断开，而 curl 能下。
  const override = String(binaryPath ?? process.env.DSH_CLOUDFLARED_PATH ?? '').trim();
  if (override) {
    if (!fs.existsSync(override)) {
      throw new Error(`DSH_CLOUDFLARED_PATH 指向的文件不存在：${override}`);
    }
    return { path: override, downloaded: false, verifiedBy: verify(override) };
  }

  if (fs.existsSync(dest)) {
    try {
      const verifiedBy = verify(dest);
      return { path: dest, downloaded: false, verifiedBy };
    } catch {
      // 已存在的文件坏了：删掉重下，不要把坏文件留在原地。
      try { fs.rmSync(dest, { force: true }); } catch { /* ignore */ }
    }
  }

  if (typeof fetchBytes !== 'function' && typeof fetchToFile !== 'function') {
    throw new Error('云隧道需要 cloudflared，但当前环境没有下载实现（离线/测试环境）');
  }

  fs.mkdirSync(dir, { recursive: true });
  const url = releaseUrl(version, platform);

  // 先写临时文件再 rename：中途失败不会留下一个"看起来存在但只能跑一半"的
  // 可执行文件，下一次启动也就不会误判为已安装。
  const tmp = `${dest}.part`;
  let verifiedBy;
  try {
    if (typeof fetchToFile === 'function') {
      // 60MB 的二进制走文件直写：不经过内存，也方便用 curl 兜底。
      await fetchToFile(url, tmp);
    } else {
      const bytes = await fetchBytes(url);
      if (!bytes || bytes.length < 1024) {
        throw new Error(`cloudflared 下载内容过小（${bytes ? bytes.length : 0} 字节），疑似被拦截`);
      }
      fs.writeFileSync(tmp, bytes, { mode: 0o755 });
    }
    if (!fs.existsSync(tmp) || fs.statSync(tmp).size < 1024) {
      throw new Error('cloudflared 下载内容过小，疑似被拦截');
    }
    verifiedBy = verify(tmp);
  } catch (err) {
    // 校验失败必须把 .part 删掉：留着的坏文件既占空间，也让下次安装的
    // "临时文件"语义变得可疑（同名覆盖前没人清理）。
    try { fs.rmSync(tmp, { force: true }); } catch { /* ignore */ }
    throw err;
  }
  fs.renameSync(tmp, dest);
  try { fs.chmodSync(dest, 0o755); } catch { /* Windows 上是 no-op */ }
  return { path: dest, downloaded: true, verifiedBy };
}

/**
 * 一条 quick tunnel 的生命周期封装。
 *
 * 刻意不把 spawn 写死：测试注入假进程，生产用 child_process.spawn。
 * 地址变化 = 进程重启（quick tunnel 地址不保证稳定），调用方通过 onUrl
 * 拿到新地址并广播给手机。
 */
export function createQuickTunnel({
  binary,
  target = 'https://127.0.0.1:3443',
  spawnFn = nodeSpawn,
  args = null,
  onUrl = () => {},
  onExit = () => {},
  logger = console
} = {}) {
  let child = null;
  let url = '';
  let status = 'idle'; // idle | starting | ready | stopped | failed
  let lastError = '';
  let restartTimer = null;
  let registered = false;

  /**
   * 只拿到地址不等于隧道可用（实测教训）。
   *
   * quick tunnel 会先打印 trycloudflare 域名，然后才尝试连 Cloudflare 边缘；
   * 在某些网络里边缘的 TLS 握手会被 EOF 断开（本机实测 QUIC 与 http2 都一样），
   * 此时域名是死的，访问只会得到 Cloudflare 1033。所以 ready 必须以
   * 「Registered tunnel connection」为准，而不是「解析到域名」。
   */
  const EDGE_FAIL = /unable to establish connection with cloudflare edge/i;
  const REGISTERED = /registered tunnel connection/i;

  const emit = (next) => {
    if (next === url) return;
    url = next;
    if (url) {
      // 地址变化本身要立刻广播（手机需要知道新域名），但状态仍是 starting，
      // 直到边缘连接注册成功。
      try { onUrl(url); } catch (err) { logger.warn?.('[tunnel] onUrl 回调异常', err?.message || err); }
    }
  };

  const feed = (chunk) => {
    const text = String(chunk);
    const found = parseTunnelUrl(text);
    if (found) emit(found);
    if (REGISTERED.test(text)) {
      registered = true;
      status = 'ready';
      lastError = '';
    }
    if (EDGE_FAIL.test(text)) {
      // 边缘不可达：把错误如实留住，状态降为 failed（域名留着也没用）。
      const line = text.split('\n').find((l) => EDGE_FAIL.test(l)) || '';
      lastError = (line.match(/error="([^"]+)"/)?.[1] || line).trim() || '无法连接 Cloudflare 边缘';
      status = 'failed';
      url = '';
      registered = false;
    }
  };

  function start() {
    if (child) return;
    if (!binary) {
      status = 'failed';
      lastError = '缺少 cloudflared 可执行文件';
      return;
    }
    status = 'starting';
    lastError = '';
    registered = false;
    try {
      // --protocol http2：QUIC 在受限网络里常被丢包；--edge-ip-version 4：
      // 避开不可用的 IPv6 边缘地址（两者都是纯经验值，失败只是更慢，不会更坏）。
      child = spawnFn(binary, args || [
        'tunnel', '--no-autoupdate', '--protocol', 'http2', '--edge-ip-version', '4', '--url', target
      ], {
        stdio: ['ignore', 'pipe', 'pipe'],
        windowsHide: true,
        detached: false
      });
    } catch (err) {
      status = 'failed';
      lastError = err?.message || String(err);
      child = null;
      logger.warn?.('[tunnel] 启动失败: %s', lastError);
      return;
    }

    const onChunk = (buf) => feed(buf);
    child.stdout?.on?.('data', onChunk);
    child.stderr?.on?.('data', onChunk);
    child.on?.('error', (err) => {
      status = 'failed';
      lastError = err?.message || String(err);
      child = null;
      logger.warn?.('[tunnel] 进程错误: %s', lastError);
    });
    child.on?.('exit', (code, signal) => {
      child = null;
      if (status !== 'stopped') {
        status = code === 0 ? 'stopped' : 'failed';
        if (code !== 0) lastError = `cloudflared 退出 code=${code}${signal ? ` signal=${signal}` : ''}`;
        // 地址随进程一起失效：不清掉的话手机会拿着一个已经没人监听的域名
        // 反复重连，错误信息只会是"连不上"。
        url = '';
        try { onExit({ code, signal, error: lastError }); } catch { /* ignore */ }
      }
    });
  }

  function stop() {
    if (restartTimer) { clearTimeout(restartTimer); restartTimer = null; }
    status = 'stopped';
    url = '';
    registered = false;
    if (!child) return;
    try { child.kill('SIGTERM'); } catch (err) { logger.warn?.('[tunnel] kill 失败: %s', err?.message || err); }
    child = null;
  }

  /** 地址变了（比如手机侧发现不可达）时，调用方可以主动重启换一个新地址。 */
  function restart() {
    stop();
    status = 'idle';
    start();
  }

  return {
    start,
    stop,
    restart,
    get url() { return url; },
    get status() { return status; },
    get lastError() { return lastError; }
  };
}
