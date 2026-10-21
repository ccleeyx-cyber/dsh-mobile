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
import { spawn as nodeSpawn, execFileSync } from 'node:child_process';
import { dshHome } from './store.mjs';

/** 固定版本：不跟随 latest，避免某天上游发新版把行为改掉。 */
// [fix 2026-10-21] 2026.2.0 → 2026.9.1：与同机 dsh-pocket 实际在用的版本对齐。
// 旧版在我们这台机器上会额外报 `cfd-features.argotunnel.com` DNS 超时。
export const CLOUDFLARED_VERSION = '2026.9.1';

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
  // [fix 2026-10-21] 必须排除 `api` 子域：cloudflared 申请隧道失败时会打印
  //   failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel"
  // 而原来的正则 `https://[a-z0-9-]+\.trycloudflare\.com` 会把这句里的
  // `https://api.trycloudflare.com` 当成隧道地址发出去 —— 手机拿到的就是 API
  // 端点，访问会得到 {"code":10005,"message":"Method Not Allowed"}。
  // 真机探针的输出里就有这一行（dsh-pocket 的 issue #32 是同一个坑）。
  const m = String(text).match(/https:\/\/(?!api\.)[a-z0-9-]+\.trycloudflare\.com/i);
  return m ? m[0] : null;
}

/**
 * 从 cloudflared 输出里挑出最有诊断价值的一段。
 *
 * 参数错误（`Incorrect Usage` / `flag provided but not defined`）的关键信息在
 * 输出**开头**，尾部整段是 usage 帮助文本，对用户没用；运行期错误（403 / 协议 /
 * 网络）的关键信息在**尾部**。所以按这个规则取，最多 500 字符。
 *
 * 与 dsh-pocket 的同名函数同源：它踩过的坑是"用户只看到 code=1"。
 */
export function firstMeaningfulErrorLine(buf) {
  const lines = String(buf ?? '').trim().split(/\r?\n/);
  const usageIdx = lines.findIndex((l) =>
    /^(?:Incorrect Usage|flag provided but not defined|unknown flag|unknown command)/i.test(l.trim()));
  if (usageIdx >= 0) return lines[usageIdx].trim().slice(0, 500);
  return lines.slice(-4).join('\n').trim().slice(0, 500);
}

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

/**
 * 读本机 cloudflared 的版本号；读不到返回空串（测试用假二进制、或文件损坏）。
 *
 * 存在的意义只有一个：判断**要不要升级**。以前只要文件存在就复用，于是本机
 * 一直跑 2026.2.0，而同机的 dsh-pocket 用 2026.9.1 —— 后者连得上边缘，前者会
 * 额外报 `cfd-features.argotunnel.com` DNS 超时。
 */
export function probeVersion(file) {
  try {
    const out = execFileSync(file, ['--version'], {
      encoding: 'utf8',
      timeout: 5000,
      windowsHide: true
    });
    const m = String(out).match(/version\s+(\d{4}\.\d+\.\d+)/i);
    return m ? m[1] : '';
  } catch {
    return '';
  }
}

/**
 * 在本机寻找**已经存在的** cloudflared（不下载）。
 *
 * 顺序：DSH_CLOUDFLARED_SEARCH_DIRS → 同机其它 DSH 插件的 bin 目录（dsh-pocket
 * 会把自己的二进制放在 `~/.dsh/dsh-pocket/bin`）→ 常见系统目录 → PATH。
 *
 * 为什么值得这么找：52MB 下载在受限网络里会卡死（实测 `.part` 停在 0 字节），
 * 而机器上往往已经有一份能用的 —— 有现成的就不该再下一次。
 */
export function findSystemCloudflared({ env = process.env, extraDirs = [] } = {}) {
  const names = process.platform === 'win32'
    ? ['cloudflared.exe', 'cloudflared']
    : ['cloudflared'];
  const home = env.USERPROFILE || env.HOME || '';
  const dirs = [
    ...extraDirs,
    ...String(env.DSH_CLOUDFLARED_SEARCH_DIRS || '').split(path.delimiter).filter(Boolean),
    path.join(home, '.dsh', 'dsh-pocket', 'bin'),
    '/usr/local/bin', '/opt/homebrew/bin', '/usr/bin', '/snap/bin'
  ];
  const seen = new Set();
  for (const dir of dirs) {
    if (!dir || seen.has(dir)) continue;
    seen.add(dir);
    for (const name of names) {
      const p = path.join(dir, name);
      try {
        if (fs.existsSync(p) && fs.statSync(p).isFile() && fs.statSync(p).size > 1024) return p;
      } catch { /* ignore */ }
    }
  }
  // PATH 兜底（用户用 scoop/choco/brew 装过）
  for (const dir of String(env.PATH || env.Path || '').split(path.delimiter)) {
    if (!dir) continue;
    for (const name of names) {
      const p = path.join(dir, name);
      try {
        if (fs.existsSync(p) && fs.statSync(p).size > 1024) return p;
      } catch { /* ignore */ }
    }
  }
  return '';
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
  dir = tunnelBinDir(),
  logger = console,
  /** 版本探测实现（测试注入；默认 execFileSync 跑 `--version`）。 */
  probeVersionFn = probeVersion,
  /** 系统二进制查找实现（测试注入：默认会真的去扫 ~/.dsh/dsh-pocket 等目录）。 */
  findSystemFn = findSystemCloudflared
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
    return { path: override, downloaded: false, verifiedBy: verify(override), from: 'override' };
  }

  if (fs.existsSync(dest)) {
    // [fix 2026-10-21 · 重要] 版本不一致**不要**删掉能用的二进制。
    //
    // 这里原来写的是"版本不符 → 删除 + 重新下载"。真机后果：唯一能用的
    // 2026.2.0 被删掉，52MB 下载卡成 0 字节的 `.part`，隧道再也起不来，而界面
    // 只显示"隧道未启动"（下载阶段没有状态）。实测 2026.2.0 能正常注册 ——
    // 版本旧 ≠ 不能用，升级必须是机会性的，不能当前置条件。
    try {
      const verifiedBy = verify(dest);
      const onDisk = probeVersionFn(dest);
      if (!onDisk || onDisk === version) {
        return { path: dest, downloaded: false, verifiedBy, version: onDisk || version, from: 'cache' };
      }
      logger.warn?.(`[tunnel] 本机 cloudflared 是 ${onDisk}（目标 ${version}），先用它，升级不阻塞隧道`);
      return { path: dest, downloaded: false, verifiedBy, version: onDisk, from: 'cache-old' };
    } catch {
      // 文件存在但跑不起来（损坏/半个文件）：删掉重下。
      try { fs.rmSync(dest, { force: true }); } catch { /* ignore */ }
    }
  }

  // [fix 2026-10-21] 自己目录里没有时，**先找系统上已有的 cloudflared**。
  //
  // 这条是救命的：本机已有 dsh-pocket 下好的 2026.9.1，而 52MB 下载在这台机器
  // 上会卡死（.part 停在 0 字节）。有现成的就用现成的，永远比"再下一份"可靠。
  const system = findSystemFn();
  if (system) {
    logger.info?.(`[tunnel] 复用系统中已有的 cloudflared：${system}`);
    try {
      return {
        path: system,
        downloaded: false,
        verifiedBy: verify(system),
        version: probeVersionFn(system),
        from: 'system'
      };
    } catch (err) {
      logger.warn?.(`[tunnel] 系统中的 cloudflared 不可用（${err?.message || err}），转去下载`);
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
  // [fix 2026-10-21] 上一次失败留下的 .part 必须先清掉：真机上那次卡死留下的
  // 就是一个 0 字节的 .part，它既让人误以为"正在下载"，也让重试行为不可预测。
  try { fs.rmSync(tmp, { force: true }); } catch { /* ignore */ }

  // 下载必须有硬超时：真机上 52MB 的下载会静默卡住（.part 停在 0 字节），
  // 而调用方是 fire-and-forget 的 —— 没有超时就会永远停在"没反应"。
  //
  // 注意超时定时器**必须清掉**：Promise.race 的败者不会自动取消，留下的
  // setTimeout 会把进程（和测试）多挂 180 秒。
  const withTimeout = (p, ms, label) => new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`${label}超时（${Math.round(ms / 1000)}s）—— 网络到 GitHub 的下载被阻断，可改用 DSH_CLOUDFLARED_PATH 指向已有二进制`)),
      ms
    );
    Promise.resolve(p).then(
      (v) => { clearTimeout(timer); resolve(v); },
      (e) => { clearTimeout(timer); reject(e); }
    );
  });

  let verifiedBy;
  try {
    if (typeof fetchToFile === 'function') {
      // 60MB 的二进制走文件直写：不经过内存，也方便用 curl 兜底。
      await withTimeout(fetchToFile(url, tmp), 180000, 'cloudflared 下载');
    } else {
      const bytes = await withTimeout(fetchBytes(url), 180000, 'cloudflared 下载');
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
  target = 'http://127.0.0.1:3088',
  spawnFn = nodeSpawn,
  args = null,
  onUrl = () => {},
  onExit = () => {},
  // [feat 2026-10-21] 命名隧道（参考 dsh-pocket 的双路径做法）：
  // 用户自带 Cloudflare Tunnel Token + 固定域名时，地址**重启不变**，比 quick
  // tunnel 的随机域名可靠得多。给了 token 就走 `tunnel run`，否则走 `--url`。
  token = '',
  host = '',
  /** 建立总超时（对齐 dsh-pocket 的 30s）。超时即判失败并给出代理提示。 */
  timeoutMs = 30000,
  logger = console
} = {}) {
  let child = null;
  let url = '';
  let status = 'idle'; // idle | starting | ready | stopped | failed
  let lastError = '';
  let restartTimer = null;
  let registered = false;
  /// 「Retrying connection」出现次数（见 EDGE_RETRY 的说明）。注册成功后不再计数。
  let edgeRetries = 0;
  /// 本次启动的时刻（ms），用于界面上"已用时"。
  let startedAt = 0;
  /// 建立超时定时器。
  let startTimer = null;
  /// 命名隧道模式（token 非空）。
  const named = String(token || '').trim().length > 0;

  /**
   * 只拿到地址不等于隧道可用（实测教训）。
   *
   * quick tunnel 会先打印 trycloudflare 域名，然后才尝试连 Cloudflare 边缘；
   * 在某些网络里边缘的 TLS 握手会被 EOF 断开（本机实测 QUIC 与 http2 都一样），
   * 此时域名是死的，访问只会得到 Cloudflare 1033。所以 ready 必须以
   * 「Registered tunnel connection」为准，而不是「解析到域名」。
   */
  const EDGE_FAIL = /unable to establish connection with cloudflare edge/i;
  // [fix 2026-10-21] 边缘连不上时 cloudflared **不报错**，只是以 2→4→8→16→32s 的
  // 退避无限重试（真机实测：域名已拿到、TCP 7844 探测还显示"可达"——因为本机
  // Clash TUN 会把 connect 伪造成成功——但五次重试全失败）。
  //
  // 只认 EDGE_FAIL 的后果是状态永远停在 starting：用户看到的是"一直未就绪"，
  // 而真正的原因是这台机器到 Cloudflare 隧道边缘的出站被阻断。
  const EDGE_RETRY = /retrying connection/i;
  const EDGE_RETRY_LIMIT = 3;
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
    if (!named) {
      const found = parseTunnelUrl(text);
      if (found) emit(found);
    }
    if (REGISTERED.test(text)) {
      registered = true;
      status = 'ready';
      lastError = '';
      clearStartTimeout();
      // 命名隧道的地址不由 cloudflared 打印（它只知道 token），必须用配置里的域名。
      if (named && !url && host) emit(`https://${host}`);
    }
    if (EDGE_FAIL.test(text)) {
      // 边缘不可达：把错误如实留住，状态降为 failed（域名留着也没用）。
      lastError = firstMeaningfulErrorLine(text) || '无法连接 Cloudflare 边缘';
      status = 'failed';
      url = '';
      registered = false;
      clearStartTimeout();
    }
    if (EDGE_RETRY.test(text) && !registered) {
      edgeRetries += 1;
      if (edgeRetries >= EDGE_RETRY_LIMIT) {
        // 结论化：无限重试对用户没有信息量，三次就给它一个能照着做的判断。
        status = 'failed';
        lastError = '连不上 Cloudflare 隧道边缘（多次重试）：到 198.41.192.0/19:7844 的出站被阻断。'
          + '可改用自己的反向代理（NPS），或在网络/代理里放行该网段。';
        url = '';
        clearStartTimeout();
        // 既然已经判失败，就不能留一个在后台按 32s 退避永远重试的进程 ——
        // 那既费电又让"失败"和"还在试"两种状态同时存在。
        try { child?.kill(); } catch { /* 已经退出 */ }
      }
    }
  };

  function clearStartTimeout() {
    if (startTimer) { clearTimeout(startTimer); startTimer = null; }
  }

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
    edgeRetries = 0;
    startedAt = Date.now();
    try {
      // --protocol http2：QUIC 走 UDP 7844，国内网络/企业网常把它屏蔽（报
      //   error 1033）；HTTP/2 走 TCP 443 更稳。这条与 dsh-pocket 的做法一致。
      //
      // [fix 2026-10-21] 目标改**明文 loopback**（http://127.0.0.1:<port>）：
      //   公网那一段由 Cloudflare 终结 TLS，本机这一段是回环，明文没有暴露面。
      //   之前要求"必须先有 TLS 端口"是多余前提 —— 它让隧道在这一步就 409，
      //   而 TLS 自签证书与隧道根本无关。
      child = spawnFn(binary, args || (named
        ? ['--no-autoupdate', 'tunnel', 'run', '--protocol', 'http2']
        : ['--no-autoupdate', 'tunnel', '--url', target, '--protocol', 'http2']
      ), {
        stdio: ['ignore', 'pipe', 'pipe'],
        windowsHide: true,
        detached: false,
        env: named ? { ...process.env, TUNNEL_TOKEN: String(token) } : undefined
      });
    } catch (err) {
      status = 'failed';
      lastError = err?.message || String(err);
      child = null;
      logger.warn?.('[tunnel] 启动失败: %s', lastError);
      return;
    }

    // 总超时（对齐 dsh-pocket 的 30s）：没能建立就判失败，并点名最常见的元凶。
    // 没有它的话，边缘被阻断时会永远停在 starting —— 界面只能显示"未就绪"。
    startTimer = setTimeout(() => {
      if (status === 'ready' || status === 'failed') return;
      status = 'failed';
      lastError = registered
        ? '隧道建立超时（30s）'
        : '隧道建立超时（30s）：没能连上 Cloudflare。若开着代理/VPN（Clash 等 TUN 模式）'
          + '会掐断隧道连接，退出后重试；或改用自己的反向代理（NPS）。';
      url = '';
      try { child?.kill(); } catch { /* 已经退出 */ }
    }, timeoutMs);
    if (typeof startTimer?.unref === 'function') startTimer.unref();

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
        // [fix 2026-10-21] 不能覆盖已经有结论的错误。
        //
        // 超时判失败会先写好一句人能照着做的话（"若开着代理/VPN…"），然后才
        // kill 进程；紧接着 exit 事件把 lastError 改成「退出 code=1」，那句诊断
        // 就没了 —— 用户看到的又是一句没法行动的错误。
        const alreadyDiagnosed = status === 'failed' && lastError;
        status = code === 0 ? 'stopped' : 'failed';
        if (code !== 0 && !alreadyDiagnosed) {
          lastError = `cloudflared 退出 code=${code}${signal ? ` signal=${signal}` : ''}`;
        }
        // 地址随进程一起失效：不清掉的话手机会拿着一个已经没人监听的域名
        // 反复重连，错误信息只会是"连不上"。
        url = '';
        try { onExit({ code, signal, error: lastError }); } catch { /* ignore */ }
      }
    });
  }

  function stop() {
    if (restartTimer) { clearTimeout(restartTimer); restartTimer = null; }
    clearStartTimeout();
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
    get lastError() { return lastError; },
    /** 边缘重试次数（给"正在连接边缘（第 N 次）"这种进度用）。 */
    get attempts() { return edgeRetries; },
    /** 启动时刻（ms）。界面据此显示"已用时 12s"，比干等一个"未就绪"有用。 */
    get startedAt() { return startedAt; },
    /**
     * 人话阶段：客户端不该自己从 status 猜进度。
     *
     * starting 里其实有三个截然不同的阶段 —— 申请域名 / 拿到域名等边缘 / 边缘
     * 注册中。之前只回 `status: 'starting'`，界面上只能显示"未就绪"，用户根本
     * 不知道卡在哪一步。
     */
    get stage() {
      if (status === 'ready') return 'ready';
      if (status === 'failed') return 'failed';
      if (status === 'stopped') return 'stopped';
      if (status === 'idle') return 'idle';
      if (!url) return 'requesting';       // 还没拿到域名 = 正在向 Cloudflare 申请
      return edgeRetries > 0 ? 'connecting' : 'requested';
    }
  };
}
