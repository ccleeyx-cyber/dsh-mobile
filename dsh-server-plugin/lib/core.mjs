/**
 * dsh-mobile-bridge — shared core
 *
 * Single source of truth for every piece of bridge business logic that used to be
 * duplicated between the Cordis plugin entry (lib/index.js) and the standalone
 * gateway (index.js). Both entries are now thin adapters over this module, so they
 * can no longer drift apart (previously they diverged on: the /api/mobile/personas
 * endpoint, the 30s dead-socket sweep, the APK/pair routes, and — worst — the audit
 * sink, where logAudit() and audit() wrote to two different stores).
 *
 * Behavior baseline is lib/index.js (the variant Cordis actually loads today).
 * Modules whose behavior had drifted are unified onto that baseline; every such
 * change is annotated with [unified].
 *
 * All filesystem access goes through `dshHome`, resolved from DSH_HOME or the
 * OS home directory. The standalone gateway previously hardcoded
 * 'C:\\Users\\Administrator\\.dsh'.  [unified]
 */

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import http from 'node:http';
import url from 'node:url';
import { homedir } from 'node:os';

// core deliberately does NOT import ./store.mjs — store imports core (for the
// audit sink), so importing back would form a cycle. Everything core needs from
// persistence is injected by the entry point instead; see configurePersistence.

let _verifyToken = () => false;
/** Injected by the entry: resolves a paired device (or null) from a token. */
let _findDeviceByToken = () => null;

/** Wire in the persistence helpers the entry point owns. */
export function configurePersistence({ verifyToken: vt, findDeviceByToken: fdt }) {
  if (typeof vt === 'function') _verifyToken = vt;
  if (typeof fdt === 'function') _findDeviceByToken = fdt;
}


// 1.15.0：新增 /api/mobile/workspaces/{roots,browse}（新建工作区改成点选）、
// settings 里每条模型带 provider/providerLabel、runbook 在 Windows 用内置 ls。
// 1.15.1：密钥轮换自愈（RPC 401 时重读密钥并重试一次）+ 诊断探针改用无 id 的
// session/modelCatalog，并区分"通道没通"与"引擎有应答"。
// 1.16.0：远程访问安全加固（配对鉴权、撤销即断连、Memory realpath、解释器与
// cloudflared 校验、资源上限、ntfy 目标限制）。
// 1.16.1：手机短暂掉线期间到达的提问先暂存，重连 subscribe 时按引擎投影回放。
// 1.16.2：requestId 幂等、跨端实时提示词、最终正文快照与长回合状态修复。
export const BRIDGE_VERSION = '1.16.5';
export const MAX_BODY_SIZE = 2 * 1024 * 1024; // 2MB defensive payload limit (F4.1)
export const HEARTBEAT_INTERVAL_MS = 30000;
/** 上游 RPC 响应硬上限：异常引擎/插件不能把网关进程堆内存拉爆。 */
export const MAX_RPC_RESPONSE_BYTES = 8 * 1024 * 1024;
/** 手机 WS 单帧上限（4MB）：正常按键/文本远低于此，附件走独立 HTTP 上传。 */
export const MAX_WS_FRAME_BYTES = 4 * 1024 * 1024;
/** 上游 MUX 单帧上限：流式帧 + 大快照都在这条线以下。 */
export const MAX_MUX_FRAME_BYTES = 8 * 1024 * 1024;
/** 每个设备同时进行的 HTTP 请求上限，防止脚本式并发打满宿主。 */
export const MAX_HTTP_INFLIGHT_PER_DEVICE = 12;
/** 单会话流式缓冲上限（字符，约等于 UTF-8 字节的保守上界）。 */
export const MAX_STREAM_BUFFER_CHARS = 4 * 1024 * 1024;

/* ------------------------------------------------------------------ *
 * DSH home / config
 * ------------------------------------------------------------------ */

export function dshHome() {
  return process.env.DSH_HOME || path.join(homedir(), '.dsh');
}

/**
 * Resolve the YAML parser without hard-failing when the host install is elsewhere.
 * [unified] Both entries duplicated this lookup, including a hardcoded fallback path.
 */
export async function loadYaml(requireFn) {
  try {
    return requireFn('yaml');
  } catch {
    try {
      return requireFn(path.join(dshHome(), 'profiles', 'web', 'node_modules', 'yaml'));
    } catch {
      return {
        parse: (str) => JSON.parse(str),
        parseDocument: () => ({ contents: { items: [] }, setIn() {}, toString: () => '' })
      };
    }
  }
}

/* ------------------------------------------------------------------ *
 * base64url + DSH signed cookie
 * ------------------------------------------------------------------ */

export function encodeBase64Url(value) {
  return Buffer.from(value).toString('base64').replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '');
}

export function decodeBase64Url(value) {
  const BASE64URL_PATTERN = /^[A-Za-z0-9_-]*$/;
  if (!BASE64URL_PATTERN.test(value) || value.length % 4 === 1) return void 0;
  const padding = '='.repeat((4 - (value.length % 4)) % 4);
  const decoded = Buffer.from(value.replaceAll('-', '+').replaceAll('_', '/') + padding, 'base64');
  return encodeBase64Url(decoded) === value ? decoded : void 0;
}

/**
 * Mint a DSH auth cookie so the bridge can talk to the engine's own HTTP/RPC
 * surface as if it were an authenticated web client.
 *
 * [fix 2026-10-28] 构造时校验 secret 可解码。此前两条坏路径都静默：
 *   * secret 含 + / = 等非 base64url 字符 → decodeBase64Url 返回 undefined →
 *     createHmac('sha256', undefined) 抛 crypto 原始 TypeError，消息与鉴权无
 *     字面关联，永不触发自愈，每个 RPC 以无线索的异常失败；
 *   * 解码后零字节 → HMAC 空 key 正常签名 → 铸出**格式合法但必 401** 的
 *     cookie，叠加恒-true 重试成"双发+永远 unauthorized+零日志线索"。
 * 现在两种情况都在构造时抛带上下文的错，启动日志立刻可见。
 */
export function createCookieFactory({ dshPort, secret }) {
  const decoded = decodeBase64Url(secret);
  if (decoded === undefined) {
    throw new Error(
      `引擎密钥不是合法的 base64url 字符串（${String(secret).slice(0, 8)}…，` +
      `请检查 DSH_SECRET / ~/.dsh/.credentials.yaml）`);
  }
  if (decoded.length === 0) {
    throw new Error(
      '引擎密钥解码后为空（0 字节）：铸出的 cookie 必然被引擎拒绝，' +
      '请检查 DSH_SECRET / ~/.dsh/.credentials.yaml');
  }
  const cache = { cookie: '', authority: `127.0.0.1:${dshPort}` };

  function generate() {
    const raw = decoded;
    const authority = cache.authority;
    const cookieName = 'dsh-auth-' + encodeBase64Url(crypto.createHash('sha256').update(authority).digest());
    const issuedAt = Date.now();
    const payload = { version: 1, authority, issuedAt, expiresAt: issuedAt + 86400 * 1000 };
    const body = encodeBase64Url(Buffer.from(JSON.stringify(payload), 'utf8'));
    const sig = crypto.createHmac('sha256', raw).update(body).digest();
    return `${cookieName}=v1.${body}.${encodeBase64Url(sig)}`;
  }

  return {
    authority: cache.authority,
    current() {
      if (!cache.cookie) cache.cookie = generate();
      return cache.cookie;
    },
    refresh() {
      cache.cookie = generate();
      return cache.cookie;
    }
  };
}

/* ------------------------------------------------------------------ *
 * unary DSH RPC
 * ------------------------------------------------------------------ */

/**
 * POST /api/<method> on the engine and unwrap { result: { ok, value } }.
 */
export function createRpcCaller({ dshPort, cookieFactory, timeoutMs = 10000 }) {
  return function callDshRpc(method, payload) {
    return new Promise((resolve, reject) => {
      const authority = `127.0.0.1:${dshPort}`;
      const cookie = cookieFactory.current();
      const rpcId = crypto.randomUUID();
      const postData = JSON.stringify({
        type: 'client-request',
        rpcId,
        method,
        payload: payload || { args: {} }
      });

      const req = http.request({
        host: '127.0.0.1',
        port: dshPort,
        path: `/api/${method}`,
        method: 'POST',
        headers: {
          Host: authority,
          Cookie: cookie,
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(postData)
        },
        timeout: timeoutMs
      }, (res) => {
        let data = '';
        let size = 0;
        let tooLarge = false;
        res.on('data', (chunk) => {
          if (tooLarge) return;
          size += chunk.length;
          if (size > MAX_RPC_RESPONSE_BYTES) {
            tooLarge = true;
            try { req.destroy(); } catch { /* already gone */ }
            reject(new Error(`DSH RPC ${method} response exceeds ${MAX_RPC_RESPONSE_BYTES} bytes`));
            return;
          }
          data += chunk;
        });
        res.on('end', () => {
          if (tooLarge) return;
          try {
            const parsed = JSON.parse(data);
            if (parsed.result && parsed.result.ok === true) {
              resolve(parsed.result.value);
            } else {
              const err = (parsed.result && parsed.result.error) || { message: 'RPC Error: ' + data };
              reject(new Error(err.message || JSON.stringify(err)));
            }
          } catch {
            reject(new Error(`Failed to parse RPC response: ${data.slice(0, 100)}`));
          }
        });
      });

      req.on('error', reject);
      req.on('timeout', () => {
        req.destroy();
        reject(new Error(`DSH RPC ${method} timed out`));
      });
      req.write(postData);
      req.end();
    });
  };
}

/* ------------------------------------------------------------------ *
 * 密钥轮换自愈
 * ------------------------------------------------------------------ */

/**
 * 这次 RPC 失败是不是"引擎不认我们的签名"（也就是密钥过期）？
 *
 * 两种真实形状都出现过：
 *   * HTTP 401 直接回文本 `unauthorized` → 解析失败，消息是
 *     `Failed to parse RPC response: unauthorized`（本机 2026-10-23 实测）；
 *   * 引擎回 JSON 里的 `{error:{message:'unauthorized'}}`。
 * [fix 2026-10-28] 去掉了 `\b401\b` 宽匹配：它会把**正文恰好含独立 "401"** 的域
 * 错误也当成鉴权失败——典型是 probeSessionCursor 依赖的 past-cursor 拒绝
 * "session page through seq … is past cursor 401"（cursor 恰为 401 的会话），
 * 现在恒-true 重试语义下会变成每 2.5s 轮询都无谓双发一次。只认 unauthorized
 * 字样；HTTP 状态码语境由调用方（uploadFileToEngine 等直接看 statusCode）补。
 */
export function isUnauthorizedRpcError(err) {
  const msg = String(err?.message || err || '');
  return /unauthorized/i.test(msg);
}

/**
 * 给 unary RPC 包一层"鉴权失败就刷新 cookie 并重试一次"。
 *
 * ## 为什么需要
 *
 * 2026-10-23 实测事故：dsh web 进程 00:26 启动，网关在 `apply()` 里把
 * `~/.dsh/.credentials.yaml` 的 secret 读进 cookieFactory；10:19 那个文件被重写
 * （密钥轮换），从此网关每一次 RPC 都是 401 —— 手机端表现为**会话里只剩第一句
 * 话**（历史走不到 `session/page`，只能掉到投影缓存的 titleInput 兜底），事件流
 * 也断着。唯一的解药是重启 dsh web，而用户不可能靠重启修每一次轮换。
 *
 * ## 边界（[fix 2026-10-28] 语义已变，如实施述）
 *
 *   * 只重试**一次**：同一个请求不会被重放成一段循环；
 *   * 2026-10-27 之后 `reloadCredentials()`（网关侧 `reloadInternalSecret`）
 *     **恒返回 true**并无条件 `cookieFactory.refresh()`——因为签名 cookie 自带
 *     24 小时有效期，跑满一天后**密钥没变也会 401**（实测 03:58 启动、次日
 *     08:55 全量失败），旧"密钥没变就不重试"防线恰好在过期场景放行失败。
 *     因此本函数现在对 unauthorized 一律刷一次重试一次；真·鉴权失败（DSH_SECRET
 *     配错）时第二次仍 401 并如实抛出——代价是每个失败请求 2×引擎负载 +
 *     一次同步读密钥文件，靠 createRetryingRpcCaller 内的连续失败熔断兜住
 *     （见 `unauthorizedFailStreak`）；
 *   * 其他错误一律不碰 —— 网络抖动、方法不存在、参数错都不该触发重载。
 *
 * @param deps.makeClient - () => (method, payload) => Promise，每次用当前密钥新造一个客户端
 * @param deps.reloadCredentials - () => boolean，重读密钥并刷新 cookie；返回是否值得重试
 * @param deps.onReloaded - 可选回调（打日志 / 审计）
 */
export function createRetryingRpcCaller({ makeClient, reloadCredentials, onReloaded }) {
  if (typeof makeClient !== 'function') throw new TypeError('makeClient is required');
  let client = makeClient();

  // [fix 2026-10-28] 连续 unauthorized 失败熔断：密钥真的配错（DSH_SECRET 指错）
  // 时，恒-true 重试语义会让进程内每个请求都"读盘+双发"（同步 readFileSync 还
  // 阻塞事件循环）。连续 N 次重试后仍 unauthorized 就停跳，直到有一次非
  // unauthorized 成功（说明密钥修好了）才复位。密钥轮换/cookie 过期的偶发
  // 401 不受影响（成功即复位）。
  let unauthorizedFailStreak = 0;
  const FAIL_STREAK_LIMIT = 5;

  return {
    async call(method, payload) {
      try {
        const result = await client(method, payload);
        unauthorizedFailStreak = 0;
        return result;
      } catch (err) {
        if (typeof reloadCredentials !== 'function' || !isUnauthorizedRpcError(err)) throw err;
        if (unauthorizedFailStreak >= FAIL_STREAK_LIMIT) {
          // 熔断打开：大概率密钥本身错，读盘+双发没有意义，如实抛出。
          throw err;
        }
        unauthorizedFailStreak++;
        try {
          reloadCredentials();
        } catch (reloadErr) {
          throw err;
        }
        try { onReloaded?.(); } catch { /* 回调不该影响这次调用 */ }
        client = makeClient();
        return client(method, payload);
      }
    }
  };
}

/* ------------------------------------------------------------------ *
 * input coercion + workspace path sanitization
 * ------------------------------------------------------------------ */

export function coerceToolInput(input) {
  if (input == null) return '';
  if (typeof input === 'string') return input;
  if (typeof input === 'object') {
    try { return JSON.stringify(input, null, 2); } catch { return String(input); }
  }
  return String(input);
}

/**
 * Guard every workspace-memory read/write.
 *
 * Three layers, in order:
 *   1. reject '..', absolute paths and drive letters outright;
 *   2. require the workspace to be one the bridge actually knows about
 *      (defends against a caller naming an arbitrary host directory);
 *   3. confirm the resolved file still sits inside the workspace root.
 *
 * Returns { targetFile, relativePath } or { error, status }.
 */
/**
 * ntfy 目标准入：默认只允许公网 HTTPS。
 *
 * 这条通道会带着用户配置的 Bearer Token 发 POST，如果允许任意 URL，已认证
 * 手机就能把它变成 SSRF 探针（访问云元数据、内网管理面）。自建 http/私网
 * ntfy 是合法需求，但必须由宿主机管理员显式设置 DSH_NTFY_ALLOW_PRIVATE=1。
 */
export function validateNtfyUrl(raw, {
  allowPrivate = process.env.DSH_NTFY_ALLOW_PRIVATE === '1'
} = {}) {
  const text = String(raw ?? '').trim();
  if (!text) return { ok: false, url: '', reason: 'empty' };
  let u;
  try {
    u = new URL(text);
  } catch {
    return { ok: false, url: '', reason: 'invalid-url' };
  }
  if (u.username || u.password) {
    return { ok: false, url: '', reason: 'credentials-not-allowed' };
  }
  if (u.protocol !== 'https:' && !(allowPrivate && u.protocol === 'http:')) {
    return { ok: false, url: '', reason: allowPrivate ? 'http-only-with-allow-private' : 'https-required' };
  }
  let host = u.hostname.toLowerCase().replace(/^\[|\]$/g, '');
  const privateHost =
    host === 'localhost' || host.endsWith('.local') ||
    /^127\./.test(host) || /^10\./.test(host) || /^192\.168\./.test(host) ||
    /^169\.254\./.test(host) || /^172\.(1[6-9]|2\d|3[01])\./.test(host) ||
    host === '::1' || /^f[cd][0-9a-f]{2}:/.test(host) || /^fe80:/.test(host);
  if (privateHost && !allowPrivate) {
    return { ok: false, url: '', reason: 'private-host-requires-admin-opt-in' };
  }
  u.pathname = `${u.pathname.replace(/\/+$/, '')}/`;
  return { ok: true, url: u.toString(), reason: '' };
}

/**
 * Resolve the real path of the deepest existing ancestor, then append the
 * not-yet-existing tail. `realpathSync` throws on missing files, but the
 * memory routes legitimately address files that do not exist yet.
 */
function canonicalizeLoose(target) {
  let current = path.resolve(target);
  const tail = [];
  for (let depth = 0; depth < 64; depth += 1) {
    try {
      const real = fs.realpathSync.native
        ? fs.realpathSync.native(current)
        : fs.realpathSync(current);
      return tail.length ? path.join(real, ...tail.reverse()) : real;
    } catch {
      const parent = path.dirname(current);
      if (parent === current) break;
      tail.push(path.basename(current));
      current = parent;
    }
  }
  return path.resolve(target);
}

export function createPathSanitizer({ getRegisteredWorkspaces }) {
  return function sanitizeWorkspaceFilePath(wsPath, fileName) {
    if (!wsPath || typeof wsPath !== 'string' || !wsPath.trim()) {
      return { error: 'Missing workspacePath', status: 400 };
    }
    if (!fileName || typeof fileName !== 'string' || !fileName.trim()) {
      return { error: 'Missing fileName', status: 400 };
    }
    const trimmedWs = wsPath.trim();
    const trimmedFile = fileName.trim();

    if (trimmedWs.includes('..')) {
      return { error: 'Forbidden: Path traversal detected in workspacePath', status: 403 };
    }
    // [P1] Layer 1 previously applied the absolute-path, leading-separator and
    // drive-letter checks to fileName ONLY, leaving workspacePath with just the
    // `..` substring test. workspacePath is legitimately absolute, so those
    // checks cannot be copied across verbatim — but NUL bytes, ASCII control
    // characters and Windows extended-length / device prefixes can be, and all
    // three are ways to make the string comparison in layer 2 disagree with what
    // the filesystem actually opens.
    // eslint-disable-next-line no-control-regex
    if (/[\x00-\x1f]/.test(trimmedWs)) {
      return { error: 'Forbidden: control character in workspacePath', status: 403 };
    }
    if (/^\\\\[?.]\\/.test(trimmedWs)) {
      return { error: 'Forbidden: extended-length or device path in workspacePath', status: 403 };
    }
    if (trimmedFile.includes('..') || path.isAbsolute(trimmedFile) ||
        trimmedFile.startsWith('/') || trimmedFile.startsWith('\\') ||
        /^[a-zA-Z]:[\\/]/.test(trimmedFile)) {
      return { error: 'Forbidden: Path traversal detected in fileName', status: 403 };
    }
    // eslint-disable-next-line no-control-regex
    if (/[\x00-\x1f]/.test(trimmedFile)) {
      return { error: 'Forbidden: control character in fileName', status: 403 };
    }

    // [security-fix 2026-10-25] 比较真实路径，而不是字符串。
    //
    // 只做 path.resolve 时，工作区里的 junction/symlink（Windows 上很常见）
    // 可以指向任意目录：`docs/credentials.txt` 的字符串仍在工作区内，实际
    // 打开的却是工作区外。目录链接不需要管理员权限（junction），所以这不是
    // 理论风险。对目标文件同样 canonicalize；不存在的尾部拼在最近现存祖先的
    // 真实路径之后，保证新建文件也受同一约束。
    const resolvedWs = canonicalizeLoose(trimmedWs);

    const registered = (getRegisteredWorkspaces() || []).filter(Boolean);
    const registeredPaths = [];
    for (const ws of registered) {
      const p = typeof ws === 'string' ? ws : (ws?.path || ws?.cwd || ws?.rootPath);
      if (p && typeof p === 'string' && p.trim()) registeredPaths.push(canonicalizeLoose(p.trim()));
    }

    // [P0] Fail CLOSED when the workspace registry is empty.
    //
    // This used to read `if (registeredPaths.length > 0) { ...validate... }`, so
    // an empty registry skipped layer 2 entirely and left nothing but the layer-1
    // string checks above. getRegisteredWorkspaces() reads the engine's workspace
    // table over RPC, and it legitimately returns [] during startup, after an
    // engine reconnect, or on any RPC failure — so a memory read or write issued
    // in that window was effectively unrestricted and could name any absolute
    // path on the host. A sanitizer that disables itself when its input is
    // missing is worse than no sanitizer, because it looks like there is one.
    if (registeredPaths.length === 0) {
      return {
        error: 'Forbidden: no registered workspaces available to validate against',
        status: 403
      };
    }

    let within = false;
    for (const regPath of registeredPaths) {
      const rel = path.relative(regPath, resolvedWs);
      if (rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel))) {
        const regNorm = regPath.toLowerCase().replace(/[\\/]+$/, '');
        const wsNorm = resolvedWs.toLowerCase().replace(/[\\/]+$/, '');
        if (wsNorm === regNorm || wsNorm.startsWith(regNorm + '\\') || wsNorm.startsWith(regNorm + '/')) {
          within = true;
          break;
        }
      }
    }
    if (!within) {
      return { error: 'Forbidden: workspacePath is not a registered workspace', status: 403 };
    }

    const resolvedTarget = canonicalizeLoose(path.resolve(resolvedWs, trimmedFile));
    const relative = path.relative(resolvedWs, resolvedTarget);
    const wsWithSep = resolvedWs.endsWith(path.sep) ? resolvedWs : resolvedWs + path.sep;
    const targetInside = relative === '' || (
      !relative.startsWith('..') && !path.isAbsolute(relative) &&
      (resolvedTarget === resolvedWs || resolvedTarget.startsWith(wsWithSep))
    );
    if (!targetInside) {
      return { error: 'Forbidden: Resolved path escapes workspace boundaries', status: 403 };
    }
    return { targetFile: resolvedTarget, relativePath: relative };
  };
}

/* ------------------------------------------------------------------ *
 * read-only command classification
 * ------------------------------------------------------------------ */

// [P0] `find` and `echo` removed.
//   - `find <path> -delete` and `find . -exec rm {} \;` are destructive, and
//     neither `-delete` nor `-exec` contains a shell metacharacter, so the
//     SHELL_METACHARACTERS guard below did not stop them. `find` is not a read
//     verb in the sense this whitelist needs.
//   - `echo` reads nothing; its only dangerous form is redirection, which the
//     metacharacter guard already blocks. Keeping it in a READ-ONLY whitelist
//     widened the auto-approve surface for no benefit.
// `cat`/`head`/`tail` stay, but are now subject to SENSITIVE_PATH_PATTERNS below.
const READ_ONLY_PREFIXES = [
  'ls', 'dir', 'cat', 'grep', 'head', 'tail', 'wc',
  'git status', 'git log', 'git diff',
  'pwd', 'which', 'where'
];
const READ_ONLY_TOOLS = ['read_file', 'view_file', 'search_web', 'list_dir'];

/**
 * [P0] Paths that must never be auto-approved, whatever the verb.
 *
 * The shipped default policy is `auto-read`, and under it
 * `cat C:\Users\<user>\.dsh\.credentials.yaml` passed every existing check: it
 * starts with an allowlisted verb and contains no shell metacharacters. The file
 * holds the engine's HMAC signing key, so auto-approving that read handed an
 * attacker everything needed to forge a dsh-auth-* cookie and talk to engine
 * port 3080 directly — the gateway's own auth layer is not in that path at all,
 * and the tool output was then broadcast to every connected client.
 *
 * Matching is on the lowercased command text, and covers both separator styles
 * plus the bare directory names, so `.dsh/.credentials.yaml`,
 * `.dsh\.credentials.yaml` and a plain `.credentials.yaml` all match.
 */
const SENSITIVE_PATH_PATTERNS = [
  /\.dsh[\\/]/,
  /\.credentials\.ya?ml/,
  /credentials\.ya?ml/,
  /mobile-bridge[\\/]config\.json/,
  /[\\/]id_rsa\b/, /[\\/]id_ed25519\b/, /[\\/]id_dsa\b/,
  /\.ssh[\\/]/,
  /\.aws[\\/]credentials/,
  /\.kube[\\/]config/,
  /\.netrc\b/,
  /[\\/]shadow\b/,
  /\bsam\b.*\bsystem\b/i,
  /key\.properties/,
  /\.jks\b/, /\.keystore\b/, /\.p12\b/, /\.pfx\b/,
  /dpapi/, /credhist/,
  /\.env\b/
];

/**
 * Prefix-whitelist check used by the 'auto-read' execution policy.
 *
 * Deliberately conservative, and stricter than a naive prefix match: an
 * allowlisted verb followed by a shell metacharacter (redirect, pipe, chain, or
 * command substitution) is NOT read-only, because `echo hi > out.txt` and
 * `cat x | sh` both perform writes or execute code despite starting with an
 * allowed verb.  [hardened]
 */
const SHELL_METACHARACTERS = /[;&|><`$(){}[\]!*?~\n\r]/;

/** True when the command text mentions a path that must never be auto-approved. */
function touchesSensitivePath(lowered) {
  return SENSITIVE_PATH_PATTERNS.some((re) => re.test(lowered));
}

/**
 * [P0] Flags that turn an otherwise read-only verb into a writer.
 *
 * `git log --output=/tmp/x` passes a prefix whitelist for `git log` and contains
 * no shell metacharacter, yet it creates a file. Same shape for find's -delete /
 * -exec family and printf-style output flags. The verb whitelist alone cannot
 * see these.
 */
const DANGEROUS_FLAGS = /(^|\s)(--output|--out-file|-o|-delete|-exec|-execdir|-ok|-okdir|-fprint|-fprintf|-fls|--delete|--force|-f|--recursive|-r\s.*--delete)(\s|$|=)/;

/**
 * [P0] Verbs that must never be auto-approved, whatever the tool name claims.
 *
 * toolName comes from the request, i.e. from the model, so it is not a trust
 * anchor. The old first line of isCommandReadOnly was
 * `if (READ_ONLY_TOOLS.includes(toolName)) return true;` — a request naming a
 * tool `read_file` was auto-approved no matter what command accompanied it, so
 * `read_file` + `rm -rf /` sailed through (`-` is not a shell metacharacter).
 * This denylist is the backstop for that class.
 */
const DANGEROUS_VERBS = /^(rm|del|erase|rmdir|rd|mv|move|ren|rename|cp|copy|xcopy|robocopy|chmod|chown|chgrp|takeown|icacls|kill|taskkill|format|mkfs|dd|shred|curl|wget|nc|ncat|netcat|ssh|scp|sftp|telnet|reg|setx|shutdown|restart-computer|new-item|set-content|add-content|out-file|export-csv|invoke-expression|iex|start-process|npm|npx|pnpm|yarn|pip|python|python3|node|deno|bash|sh|zsh|cmd|powershell|pwsh)(\s|$)/;

/**
 * [P0] Mutating subcommands of verbs that are otherwise partly whitelisted.
 *
 * `git status`, `git log` and `git diff` are on READ_ONLY_PREFIXES, so a bare
 * `git` entry in DANGEROUS_VERBS would have blocked all three — measured, that
 * was a false positive on the single most common read-only command family in
 * this repo. The mutating subcommands are matched explicitly instead.
 */
const DANGEROUS_SUBCOMMANDS = [
  /^git\s+(push|reset|clean|checkout|commit|rebase|merge|cherry-pick|revert|apply|am|tag|remote|config|gc|prune|reflog\s+expire|filter-branch|filter-repo|update-ref|rm|mv|stash|restore|switch|worktree|submodule)\b/,
  /^docker\s+(rm|rmi|run|exec|push|kill|stop|system\s+prune|volume\s+rm)\b/,
  /^kubectl\s+(delete|apply|exec|scale|rollout|patch|replace|drain)\b/,
  /^flutter\s+(clean|publish|deploy)\b/,
  /^gradlew?\s+.*\b(publish|clean|install)\b/
];

function hasDangerousSubcommand(lowered) {
  return DANGEROUS_SUBCOMMANDS.some((re) => re.test(lowered));
}

export function isCommandReadOnly(cmdStr, toolName) {
  const loweredCmd = cmdStr ? String(cmdStr).trim().toLowerCase() : '';

  // No command line to classify — the tool name is all there is. This is the
  // only case where the tool name is allowed to decide anything.
  if (!loweredCmd) return READ_ONLY_TOOLS.includes(toolName);

  if (SHELL_METACHARACTERS.test(loweredCmd)) return false;
  if (touchesSensitivePath(loweredCmd)) return false;
  if (DANGEROUS_FLAGS.test(loweredCmd)) return false;
  if (DANGEROUS_VERBS.test(loweredCmd)) return false;
  if (hasDangerousSubcommand(loweredCmd)) return false;

  // A command must qualify on its own merits. Being labelled read_file no longer
  // rescues one that is not on the whitelist — but a bare path (what read_file
  // actually receives, e.g. `E:\workspace\个人\NOTES.md`) is still allowed so
  // that tightening this does not turn every file read into an approval prompt.
  if (READ_ONLY_PREFIXES.some((p) => loweredCmd === p || loweredCmd.startsWith(p + ' '))) return true;
  if (READ_ONLY_TOOLS.includes(toolName) && !/\s/.test(loweredCmd.trim())) return true;
  return false;
}

/**
 * Exported so the approval path can explain a denial in the audit log instead of
 * silently falling back to an interactive prompt with no reason recorded.
 */
export function classifyCommand(cmdStr, toolName) {
  const loweredCmd = cmdStr ? String(cmdStr).trim().toLowerCase() : '';
  if (!loweredCmd) {
    return READ_ONLY_TOOLS.includes(toolName)
      ? { readOnly: true, why: 'read-only-tool' }
      : { readOnly: false, why: 'no-command' };
  }
  if (SHELL_METACHARACTERS.test(loweredCmd)) return { readOnly: false, why: 'shell-metacharacter' };
  if (touchesSensitivePath(loweredCmd)) return { readOnly: false, why: 'sensitive-path' };
  if (DANGEROUS_FLAGS.test(loweredCmd)) return { readOnly: false, why: 'dangerous-flag' };
  if (DANGEROUS_VERBS.test(loweredCmd)) return { readOnly: false, why: 'dangerous-verb' };
  if (hasDangerousSubcommand(loweredCmd)) return { readOnly: false, why: 'dangerous-subcommand' };
  const hit = READ_ONLY_PREFIXES.find((p) => loweredCmd === p || loweredCmd.startsWith(p + ' '));
  if (hit) return { readOnly: true, why: `prefix:${hit}` };
  if (READ_ONLY_TOOLS.includes(toolName) && !/\s/.test(loweredCmd.trim())) {
    return { readOnly: true, why: 'read-only-tool:bare-path' };
  }
  return { readOnly: false, why: 'not-allowlisted' };
}

/** Exposed for tests. */
export { SENSITIVE_PATH_PATTERNS, READ_ONLY_PREFIXES, READ_ONLY_TOOLS, DANGEROUS_FLAGS, DANGEROUS_VERBS, DANGEROUS_SUBCOMMANDS };


/* ------------------------------------------------------------------ *
 * audit
 * ------------------------------------------------------------------ */

const AUDIT_BUFFER_SIZE = 200;

/**
 * Single audit sink for both entries. [unified]
 * Previously the standalone gateway wrote to its own module-level array via
 * logAudit() while the plugin wrote to store.mjs's auditBuffer, so the same
 * event was readable through one entry and invisible through the other.
 */
export function createAuditSink({ auditBuffer = [], size = AUDIT_BUFFER_SIZE } = {}) {
  const sink = {
    record(action, payload = {}) {
      const norm = (typeof payload === 'object' && payload !== null) ? payload : { details: payload };
      const entry = {
        id: norm.id || norm.approvalId || norm.eventId ||
          `audit_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
        time: typeof norm.time === 'number' ? norm.time : Date.now(),
        action: norm.action || action,
        event: norm.event || action,
        sessionId: norm.sessionId || 'system',
        toolName: norm.toolName || action || 'system',
        command: norm.command || norm.reason || action || '',
        outcome: norm.outcome ||
          (String(action).includes('reject') ? 'rejected'
            : String(action).includes('allow') ? 'allowed-once'
              : 'auto-approved'),
        reason: norm.reason || norm.error ||
          (typeof norm === 'object' ? JSON.stringify(norm) : String(norm))
      };
      auditBuffer.unshift(entry);
      if (auditBuffer.length > size) auditBuffer.pop();
      return entry;
    },
    read(limit = 100) {
      const lim = typeof limit === 'number' && limit > 0 ? limit : 100;
      return auditBuffer.slice(0, lim);
    },
    get size() { return auditBuffer.length; }
  };
  return sink;
}

/* ------------------------------------------------------------------ *
 * personas
 * ------------------------------------------------------------------ */

const DEFAULT_PERSONAS = [
  {
    id: 'fullstack',
    title: '全栈研发架构师 (Fullstack Architect)',
    icon: 'code',
    description: '擅长端到端架构设计、高质量代码重构与工程规范',
    prompt: '你是一名资深全栈研发架构师，精通前端、后端与系统架构。在编写代码时遵循Clean Architecture与工程最佳实践，代码具备健壮性与高可读性。',
    isCustom: false
  },
  {
    id: 'bug_hunter',
    title: '缺陷定位专家 (Bug Hunter)',
    icon: 'bug',
    description: '快速定位复杂报错、逻辑异常及并发竞争条件',
    prompt: '你是一名专家级Bug分析师。专注于排查复杂报错、逻辑缺陷、内存泄漏和并发问题。提供精准的根因分析及最小化安全补丁。',
    isCustom: false
  },
  {
    id: 'devops',
    title: '极客终端运维 (DevOps Ninja)',
    icon: 'terminal',
    description: '熟练编写 Shell / PowerShell / Docker 脚本与 CI/CD 流水线',
    prompt: '你是一名经验丰富的Linux/Windows运维与DevOps专家，精通Shell、PowerShell、Docker与CI/CD自动化，善于编写高效的自动化运维脚本。',
    isCustom: false
  },
  {
    id: 'auditor',
    title: '安全代码审计 (Security Auditor)',
    icon: 'shield',
    description: '代码安全合规检查，防范提权、注入与敏感信息泄露',
    prompt: '你是一名代码安全与漏洞审计专家，专注于识别SQL注入、XSS、提权漏洞、硬编码密钥及OWASP Top 10风险，并给出严格的安全加固建议。',
    isCustom: false
  }
];

export function createPersonaStore({ home = dshHome() } = {}) {
  const file = path.join(home, 'mobile-access', 'personas.json');
  return {
    file,
    defaults: DEFAULT_PERSONAS,
    get() {
      try {
        if (fs.existsSync(file)) {
          const data = JSON.parse(fs.readFileSync(file, 'utf8'));
          if (Array.isArray(data) && data.length > 0) return data;
        }
      } catch { /* fall through to defaults */ }
      return DEFAULT_PERSONAS;
    },
    save(list) {
      try {
        const dir = path.dirname(file);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(file, JSON.stringify(list, null, 2), 'utf8');
        return true;
      } catch {
        return false;
      }
    }
  };
}

/* ------------------------------------------------------------------ *
 * projection-cache reader with mtime memoization
 *
 * getWorkspacesData() used to readFileSync + JSON.parse every session cache
 * file on every request — up to ~1000 files every 3 seconds from the phone's
 * workspace poll, all synchronous, all inside the dsh web process (the plugin
 * shares the engine's event loop). This cache keys by resolved path + mtimeMs,
 * so an unchanged file costs one statSync instead of a full read+parse.
 * ------------------------------------------------------------------ */

export function createProjCacheReader({ dir }) {
  const cache = new Map(); // absPath -> { mtimeMs, value }

  return {
    /** Parsed JSON, or null when missing/unreadable/unmodified-empty. */
    readJson(p) {
      let st;
      try {
        st = fs.statSync(p);
      } catch {
        cache.delete(p);
        return null;
      }
      const hit = cache.get(p);
      if (hit && hit.mtimeMs === st.mtimeMs) return hit.value;
      let value = null;
      try {
        value = JSON.parse(fs.readFileSync(p, 'utf8'));
      } catch {
        value = null;
      }
      cache.set(p, { mtimeMs: st.mtimeMs, value });
      return value;
    },
    /** Drop one entry (call after unlink/replace so the next read misses). */
    invalidate(p) { cache.delete(p); },
    clear() { cache.clear(); }
  };
}

/* ------------------------------------------------------------------ *
 * prompt snippets (quick replies / templates)
 * ------------------------------------------------------------------ */

export function createSnippetStore({ home = dshHome() } = {}) {
  const file = path.join(home, 'mobile-access', 'snippets.json');
  const MAX_SNIPPETS = 50;

  function readAll() {
    try {
      if (fs.existsSync(file)) {
        const data = JSON.parse(fs.readFileSync(file, 'utf8'));
        if (Array.isArray(data)) {
          return data.filter((s) => s && typeof s === 'object' && typeof s.text === 'string' && s.text.trim());
        }
      }
    } catch { /* fall through */ }
    return [];
  }

  return {
    get: readAll,
    save(list) {
      const clean = (Array.isArray(list) ? list : [])
        .filter((s) => s && typeof s === 'object' && typeof s.text === 'string' && s.text.trim())
        .slice(0, MAX_SNIPPETS)
        .map((s) => ({
          id: typeof s.id === 'string' && s.id ? s.id : `snip_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
          label: typeof s.label === 'string' ? s.label.slice(0, 40) : s.text.slice(0, 20),
          text: s.text.slice(0, 4000)
        }));
      try {
        const dir = path.dirname(file);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(file, JSON.stringify(clean, null, 2), 'utf8');
        return clean;
      } catch {
        return null; // signal failure; caller turns null into a 500
      }
    }
  };
}

/* ------------------------------------------------------------------ *
 * turn/end reason translation
 * ------------------------------------------------------------------ */

/**
 * Human-readable text for a `turn/end` reason.
 *
 * ⚠️ The engine has NO `turn/error` event. A failed turn is recorded as
 * `turn/end` with `data.reason = { kind: 'error', error: { message, code } }`
 * (see dsh-session's TurnEndReasonMap), and that field is the ONLY carrier of
 * the failure message — the engine's own Web UI renders its error banner
 * straight from it (dsh-client-ui-chat matches `reason.kind === 'error'`).
 * Anything that drops `reason` therefore loses the error entirely: the phone
 * shows a spinner that never stops and never says why.
 *
 * `interrupted` is the engine's marker for a crash-orphaned turn that was
 * closed after the fact, i.e. exactly the "dsh web died mid-turn" case.
 */
export function describeTurnEnd(reason) {
  const r = (reason && typeof reason === 'object') ? reason : {};
  const kind = typeof r.kind === 'string' ? r.kind : 'unknown';
  switch (kind) {
    case 'error': {
      const message = r.error?.message || r.error?.reason || '执行出错';
      const code = r.error?.code ? String(r.error.code) : '';
      return { kind, text: code ? `${message} (${code})` : String(message), code };
    }
    case 'aborted':
      return { kind, text: '本轮已被中断', code: '' };
    case 'max-tokens':
      return { kind, text: '已达到最大输出长度', code: '' };
    case 'blocked':
      return { kind, text: '本轮被阻止（权限或策略）', code: '' };
    case 'interrupted':
      return { kind, text: '本轮因引擎中断而结束（可能是 dsh web 重启）', code: '' };
    case 'completed':
    case 'forked':
      return { kind, text: '', code: '' };
    default:
      return { kind, text: '', code: '' };
  }
}

/** True when a turn-end reason means the turn did NOT finish normally. */
export function isFailedTurnEnd(reason) {
  const kind = reason?.kind;
  return kind === 'error' || kind === 'interrupted' || kind === 'blocked';
}

/* ------------------------------------------------------------------ *
 * session id helpers
 * ------------------------------------------------------------------ */

/**
 * Canonical map key for a session id: strips the `session-` prefix only.
 * Case is deliberately preserved — this value is used as a Map key and is
 * re-expanded into `session-${key}` when talking to the engine, so lowercasing
 * here could fabricate an id the engine never issued.
 */
export function normalizeSessionKey(sId) {
  if (!sId) return '';
  return sId.startsWith('session-') ? sId.slice('session-'.length) : sId;
}

export function toFullSessionId(sId) {
  if (!sId) return '';
  return sId.startsWith('session-') ? sId : `session-${sId}`;
}

/**
 * Compare two session ids for identity.
 *
 * Matches the Dart client's SessionMeta.matchesSessionId semantics: strip the
 * `session-` prefix and compare case-insensitively.  [unified] The Dart side
 * has always lowercased; the gateway previously compared case-sensitively, so a
 * client sending `ABC` and the engine reporting `abc` would be treated as two
 * different sessions and stream state would be dropped.
 */
export function sessionIdMatches(a, b) {
  if (!a || !b) return false;
  return normalizeSessionKey(a).toLowerCase() === normalizeSessionKey(b).toLowerCase();
}

/**
 * Identify injected context/memory blocks so they can be folded into a
 * collapsed card instead of shown as ordinary user text.
 */
export function isCarriedContext(text, ev) {
  if (!text || typeof text !== 'string') return false;
  if (ev?.data?.source?.plugin === 'dsh-mnemon' || ev?.source?.plugin === 'dsh-mnemon') return true;
  const trimmed = text.trim();
  if (trimmed.startsWith('MNEMON RUNTIME MEMORY SNAPSHOT') || trimmed.startsWith('[MNEMON]')) return true;
  if (trimmed.includes('<runtime-memory-file') || trimmed.includes('</runtime-memory-file>')) return true;
  if (trimmed.includes('<system-reminder>')) return true;
  if (trimmed.startsWith('Current runtime context.') || trimmed.includes('DSH file policy:')) return true;
  if (trimmed.includes('Instructions from:') || trimmed.includes('Contents of ')) return true;
  if (trimmed.includes('<available_skills>') || trimmed.includes('A skill is a reusable set')) return true;
  if (/<(workspace|project|environment|file)_context>/i.test(trimmed)) return true;
  return false;
}

/* ------------------------------------------------------------------ *
 * Engine-injected notices (a `user/message` nobody typed)
 * ------------------------------------------------------------------ */

/**
 * `user/message` 的 source/origin 里，**什么样才算真人回合**。
 *
 * 名单只有这一份：`sessiontitle.mjs` 的 `isHumanTurn` 与这里的
 * `classifyHarnessNotice` 都读它。引擎在事件上记 `data.source`
 * （对象，例如 `{ kind: 'user' }` / `{ kind: 'plugin', plugin: 'user-approval' }`）
 * 或老格式的 `data.origin`（字符串），其它值一律是 harness 注入的。
 */
export const HUMAN_ORIGINS = new Set(['user', 'human', 'user-input', 'user_input']);

/** 子代理结算通知的开头：`Background subagent <childId> …`。 */
const SUBAGENT_SETTLEMENT_RE = /^Background subagent (\S+)/;

/** 结算通知里收尾正文的分隔标记。 */
const CLOSING_MARKER = 'Its closing message:';

/**
 * 结算通知的收尾种类（`dsh-subagent` 的 `settlementSummary` 的 switch 分支）。
 * 加新分支时这里要跟着加 —— 认不出来会退化成 `unknown`，不会误判成别的种类。
 */
const SETTLEMENT_VARIANTS = [
  ['completed', 'finished and will do no further work'],
  ['aborted', 'was stopped before it finished'],
  ['max-tokens', 'ran out of room before it finished']
];

/**
 * 读出一条 `user/message` 的来源标记。
 *
 * @param {Record<string, unknown>} ev - 会话事件。
 * @returns {{ present: boolean, human: boolean, kind: string }}
 */
export function readUserMessageSource(ev) {
  const data = ev?.data;
  if (!data || typeof data !== 'object') return { present: false, human: false, kind: '' };
  const source = data.source ?? data.origin;
  if (typeof source === 'string') {
    return { present: true, human: HUMAN_ORIGINS.has(source), kind: source };
  }
  if (source && typeof source === 'object') {
    const kind = typeof source.kind === 'string' ? source.kind : '';
    const plugin = typeof source.plugin === 'string' ? source.plugin : '';
    return { present: true, human: HUMAN_ORIGINS.has(kind), kind: plugin ? `plugin:${plugin}` : kind };
  }
  return { present: false, human: false, kind: '' };
}

/**
 * 这条 `user/message` 是不是**引擎注入的通知**？是就返回给手机渲染要用的语义。
 *
 * ## 为什么需要它（2026-10-17，用户报"我什么时候发过这种消息"）
 *
 * 子代理结束时 `dsh-subagent` 会把
 * `Background subagent <childId> finished and will do no further work unless you
 * send it more. Its closing message: <整段收尾>` 作为一条 **`user/message`** 写进
 * 会话事件日志 —— 它就是这么唤醒父 agent 的。`role` 真的是 `user`，于是手机把它
 * 渲染成一个蓝色右对齐气泡，和用户亲手打的字长得一模一样，里面还塞着子代理的整段
 * 收尾（实测一次能占满两屏）。
 *
 * ## 判定优先级（高 → 低），每条都有测试
 *
 * 1. 来源字段**明确写了是人类** → 永远不是通知。这是硬闸：人类正文里恰好出现这些
 *    字样时绝不能被误伤 —— `isCarriedContext` 那套纯内容启发式就吃过这个亏
 *    （见 `convertSessionRecordsToMessages` 里的误杀审计）。
 * 2. 来源字段存在但不是人类 → 是通知，`kind` 取 `plugin:<name>` 或 `source.kind`。
 * 3. 来源字段缺失（老日志 / 部分历史记录）→ **只认锚定在开头的已知文案**。锚定是
 *    刻意的：正文中间提到 `Background subagent` 的人类消息不该被吞掉。
 *
 * `role` 保持 `user` 不变（老 App 照旧渲染），通知信息走附加字段，新 App 才认识。
 *
 * @param {string} text - `user/message` 的正文。
 * @param {Record<string, unknown>} ev - 会话事件（用来读 source）。
 * @returns {null | { kind: string, variant: string|null, childId: string|null, body: string|null }}
 */
export function classifyHarnessNotice(text, ev) {
  const value = String(text ?? '').trim();
  if (!value) return null;

  const source = readUserMessageSource(ev);
  if (source.human) return null;

  const settlement = SUBAGENT_SETTLEMENT_RE.exec(value);
  if (settlement) {
    return {
      kind: 'subagent-settlement',
      variant: settlementVariant(value),
      childId: settlement[1],
      body: closingBody(value)
    };
  }

  // 没有结构化来源就不猜：只有锚定文案能证明这是注入。
  if (!source.present) return null;
  return { kind: source.kind || 'injected', variant: null, childId: null, body: closingBody(value) };
}

function settlementVariant(value) {
  for (const [variant, phrase] of SETTLEMENT_VARIANTS) {
    if (value.includes(phrase)) return variant;
  }
  return 'unknown';
}

function closingBody(value) {
  const idx = value.indexOf(CLOSING_MARKER);
  if (idx === -1) return null;
  const body = value.slice(idx + CLOSING_MARKER.length).trim();
  return body || null;
}

/* ------------------------------------------------------------------ *
 * turn-sequence bookkeeping (prompt/cancel race fencing)
 * ------------------------------------------------------------------ */

/**
 * Turn-sequence bookkeeping for prompt/cancel race fencing.
 *
 * All four collections can be injected so an entry point can keep ownership of
 * the live objects it already exposed (and so teardown can clear them).
 */
export function createTurnRegistry({
  sessionTurnSeqs = new Map(),
  cancelledTurnSeqs = new Map(),
  lastCancelTimes = new Map(),
  activePrompts = new Map()
} = {}) {
  const key = normalizeSessionKey;

  return {
    activePrompts,
    sessionTurnSeqs,
    cancelledTurnSeqs,
    lastCancelTimes,
    getTurnSeq: (sId) => sessionTurnSeqs.get(key(sId)) || 0,
    setTurnSeq(sId, seq) { sessionTurnSeqs.set(key(sId), seq); },
    getCancelledSeq: (sId) => cancelledTurnSeqs.get(key(sId)) || 0,
    setCancelledSeq(sId, seq) { cancelledTurnSeqs.set(key(sId), seq); },
    getLastCancelTime: (sId) => lastCancelTimes.get(key(sId)) || 0,
    setLastCancelTime(sId, t) { lastCancelTimes.set(key(sId), t); },
    /** Allocate the next turn number for a prompt. */
    nextTurnSeq(sId) {
      const seq = (sessionTurnSeqs.get(key(sId)) || 0) + 1;
      sessionTurnSeqs.set(key(sId), seq);
      return seq;
    },
    /** Consume a cancel: bump seq, mark cancelled, stamp time. */
    recordCancel(sId, now = Date.now()) {
      const seq = (sessionTurnSeqs.get(key(sId)) || 0) + 1;
      sessionTurnSeqs.set(key(sId), seq);
      cancelledTurnSeqs.set(key(sId), seq);
      lastCancelTimes.set(key(sId), now);
      return seq;
    },
    isAnyPromptActive(sId) {
      const k = key(sId);
      return activePrompts.has(sId) || activePrompts.has(k) || activePrompts.has(`session-${k}`);
    },
    clear() {
      sessionTurnSeqs.clear();
      cancelledTurnSeqs.clear();
      lastCancelTimes.clear();
      activePrompts.clear();
    }
  };
}

/* ------------------------------------------------------------------ *
 * session followers (live stream buffers per followed session)
 * ------------------------------------------------------------------ */

/**
 * Per-session live-stream buffers.
 *
 * `map` may be injected so an entry keeps ownership of the live follower
 * collection it already exposed (entries are aliased under both the bare and
 * `session-` prefixed keys).
 */
export function createFollowerRegistry({ map = new Map(), onSubscribe } = {}) {
  const followers = map;

  function normalize(sId) { return normalizeSessionKey(sId); }

  function ensure(sessionId) {
    const full = toFullSessionId(sessionId);
    const k = normalize(full);
    let f = followers.get(k) || followers.get(full);
    if (!f) {
      f = {
        sessionId: full,
        streamId: `follow-${full}`,
        isRunning: false,
        thinkingBuffer: '',
        textBuffer: '',
        tools: [],
        subscribed: false,
        lastUpdated: Date.now()
      };
      followers.set(k, f);
      followers.set(full, f);
    }
    return f;
  }

  return {
    map: followers,
    ensure,
    get(sessionId) {
      if (!sessionId) return null;
      const k = normalize(sessionId);
      return followers.get(k) || followers.get(sessionId) || followers.get(`session-${k}`) || null;
    },
    /** Unique follower objects (each is aliased under two keys). */
    all() { return [...new Set(followers.values())]; },
    /** Open an upstream session/follow stream if not already subscribed. */
    follow(sessionId, sendOpen) {
      const f = ensure(sessionId);
      if (f.subscribed) return f;
      const sender = sendOpen || onSubscribe;
      if (sender) {
        try {
          sender({
            type: 'open',
            streamId: f.streamId,
            endpoint: 'session/follow',
            payload: {
              args: {
                request: {
                  address: { kind: 'session', sessionId: f.sessionId },
                  assistantStream: true
                }
              }
            }
          });
          f.subscribed = true;
        } catch { /* upstream not ready; will retry on reconnect */ }
      }
      return f;
    },
    markAllUnsubscribed() {
      for (const f of new Set(followers.values())) f.subscribed = false;
    },
    clear() { followers.clear(); }
  };
}

/* ------------------------------------------------------------------ *
 * pending approvals queue
 * ------------------------------------------------------------------ */

/**
 * 单次审批令牌的生命周期（v1.35 / 2.1）。
 *
 * 为什么要有它：锁屏通知上的「批准」按钮需要一条能在**没有会话上下文**的情况
 * 下发出、又只对某一条审批有效的凭据。设备 token 太宽（能批准任何一条、直到
 * 被撤销），一次性令牌把爆炸半径限制在「这一条 + 15 分钟」。
 *
 * 设计约束：
 *  - 明文令牌只在铸造时返回一次，存储层只留 SHA-256（进程内 Map，不落盘）；
 *  - 消费后同向重复请求返回 consumed（幂等），反向请求是冲突 —— 因为一个通知
 *    可能被连点两下，但「先批后拒」不该悄悄生效；
 *  - 过期与消费是两件事：过期后连幂等都不成立。
 *
 * 抽成纯工厂是为了可单测（注入 now），不依赖网关闭包。
 */
export const APPROVAL_TOKEN_TTL_MS = 15 * 60 * 1000;

export function createApprovalTokens({ ttlMs = APPROVAL_TOKEN_TTL_MS, now = () => Date.now() } = {}) {
  const secrets = new Map();
  const digest = (value) => crypto.createHash('sha256').update(String(value)).digest('hex');

  return {
    /** 铸一枚一次性令牌，返回明文（调用方负责只发给授权客户端）。 */
    mint(id) {
      const token = crypto.randomBytes(24).toString('base64url');
      secrets.set(id, {
        hash: digest(token),
        expiresAt: now() + ttlMs,
        consumedAt: 0,
        decision: ''
      });
      return token;
    },

    /**
     * 校验（不消费）。
     * @returns {{ok: boolean, code: 'ok'|'unknown'|'expired'|'mismatch'|'consumed', decision?: string}}
     */
    check(id, token) {
      const s = secrets.get(id);
      if (!s) return { ok: false, code: 'unknown' };
      if (now() > s.expiresAt) return { ok: false, code: 'expired' };
      if (s.hash !== digest(token ?? '')) return { ok: false, code: 'mismatch' };
      if (s.consumedAt) return { ok: false, code: 'consumed', decision: s.decision };
      return { ok: true, code: 'ok' };
    },

    /** 标记消费（'approve' | 'deny'）。不存在返回 false。 */
    consume(id, decision) {
      const s = secrets.get(id);
      if (!s) return false;
      s.consumedAt = now();
      s.decision = decision;
      return true;
    },

    /** 清掉过期超过一分钟的条目，避免长跑进程中 map 无限增长。 */
    prune() {
      const t = now();
      for (const [key, s] of secrets) {
        if (s.expiresAt + 60_000 < t) secrets.delete(key);
      }
    },

    get size() { return secrets.size; }
  };
}

/**
 * 哪些审批允许「通知栏一键批准」。
 *
 * `danger-full-access` 下命令不再逐条确认，如果通知栏还能一键放行，一次误触
 * 就等于让 Agent 在完全访问策略里执行任意命令。所以这类审批**不铸令牌**，
 * 必须回 App 内看清命令原文再确认。
 */
export function isSensitiveApprovalPolicy(policy) {
  return String(policy || '').trim() === 'danger-full-access';
}

/**
 * Pending approvals queue.
 *
 * `map` may be injected so an entry keeps ownership of the live collection it
 * already exposed. Entries are stored under BOTH id and eventId so either
 * lookup resolves; `list()` de-duplicates.
 */
export function createApprovalQueue({ map = new Map() } = {}) {
  let counter = 1;
  return {
    map,
    nextId() { return `appr_${Date.now()}_${counter++}`; },
    /** Stored under both id and eventId so either lookup resolves. */
    put(approval) {
      map.set(approval.id, approval);
      if (approval.eventId && approval.eventId !== approval.id) map.set(approval.eventId, approval);
      return approval;
    },
    get(eventId) {
      if (map.has(eventId)) return map.get(eventId);
      for (const v of map.values()) {
        if (v.id === eventId || v.eventId === eventId) return v;
      }
      return undefined;
    },
    remove(approval, eventId) {
      if (approval) {
        map.delete(approval.id);
        if (approval.eventId) map.delete(approval.eventId);
      }
      if (eventId) map.delete(eventId);
    },
    removeBySession(sessionId) {
      for (const [key, v] of map.entries()) {
        if (sessionIdMatches(v.sessionId, sessionId)) map.delete(key);
      }
    },
    /** Deduplicated list (id and eventId both point at the same object). */
    list() { return [...new Set(map.values())]; },
    clear() { map.clear(); }
  };
}

/* ------------------------------------------------------------------ *
 * permissions
 * ------------------------------------------------------------------ */

let _loadPermissions = () => ({});
let _savePermissions = () => ({});
let _permissionsFile = () => '';

/**
 * Persistence handles for the permission store. Injected by the entry point so
 * core stays free of the store.mjs import (store imports core for the audit sink).
 */
export function configurePermissionsPersistence({ load, save, file }) {
  if (typeof load === 'function') _loadPermissions = load;
  if (typeof save === 'function') _savePermissions = save;
  if (typeof file === 'function') _permissionsFile = file;
}

export function createPermissionStore() {
  const initial = _loadPermissions();
  const global = {
    executionPolicy: initial.defaultPolicy || initial.executionPolicy || 'auto-read',
    maxSteps: initial.maxSteps ?? 30,
    sandboxMode: initial.sandboxMode || 'workspace-write',
    protectGit: initial.protectGit !== false
  };
  const sessions = new Map(Object.entries(initial.sessionPolicies || {}));

  function payload() {
    const sessionPolicies = {};
    for (const [k, v] of sessions) sessionPolicies[k] = v;
    return {
      defaultPolicy: global.executionPolicy,
      executionPolicy: global.executionPolicy,
      sandboxMode: global.sandboxMode,
      maxSteps: global.maxSteps,
      protectGit: global.protectGit !== false,
      sessionPolicies
    };
  }

  return {
    global,
    sessions,
    get globalPolicy() { return global.executionPolicy; },
    forSession(sessionId) {
      if (!sessionId) return global.executionPolicy;
      // [fix 2026-10-17] 归一化后再查：全文件其余处（normalizeSessionKey /
      // sessionIdMatchesSafe）都做 session- 前缀归一，唯独这里用原始串精确
      // 匹配 —— 写入键与引擎事件拼写不一致（有无前缀）时会话策略静默回落
      // global，审批 effectivePolicy 随之改变。setSession 同步归一。
      const key = normalizeSessionKey(String(sessionId));
      const direct = sessions.get(key) || sessions.get(toFullSessionId(key));
      return direct || global.executionPolicy;
    },
    apply(patch = {}) {
      const pol = patch.defaultPolicy || patch.executionPolicy;
      if (pol) global.executionPolicy = pol;
      if (patch.sandboxMode) global.sandboxMode = patch.sandboxMode;
      if (patch.maxSteps) global.maxSteps = Number(patch.maxSteps);
      if (typeof patch.protectGit === 'boolean') global.protectGit = patch.protectGit;
      if (patch.sessionPolicies && typeof patch.sessionPolicies === 'object') {
        for (const [sId, sPol] of Object.entries(patch.sessionPolicies)) {
          if (typeof sPol === 'string') sessions.set(sId, sPol);
        }
      }
      return payload();
    },
    setSession(sessionId, policy) {
      if (!sessionId) return payload();
      // 与 forSession 同键：写入统一归一，杜绝两种拼写并存。
      sessions.set(normalizeSessionKey(String(sessionId)), policy);
      return payload();
    },
    payload,
    persist() {
      const p = payload();
      _savePermissions(p);
      return p;
    },
    permissionsFile: _permissionsFile
  };
}

/* ------------------------------------------------------------------ *
 * auth
 * ------------------------------------------------------------------ */

/**
 * Failed-auth backoff, keyed by client IP.
 *
 * There was no rate limit anywhere on the auth check, so a single shared token
 * could be guessed at whatever rate the network allowed — on a LAN, freely.
 * This is an escalating lockout, not a hard ban: a real phone that fat-fingers
 * its token (or a stale token after a config change) gets a short pause, while
 * a sustained brute force is slowed to a crawl and then refused outright for a
 * cooling window.
 *
 * Keyed by IP, so one misconfigured client cannot lock everyone else out.
 */
const AUTH_FAIL_STATE = new Map();

const AUTH_FAIL_WINDOW_MS = 15 * 60 * 1000; // forget an IP after this much quiet
const AUTH_FAIL_THRESHOLD = 5;             // failures tolerated in a burst
const AUTH_FAIL_MAX_DELAY_MS = 15 * 60 * 1000;
const AUTH_FAIL_BLOCK_MS = 15 * 60 * 1000; // hard refusal window

/**
 * [fix 2026-10-17] XFF 是否可信。
 *
 * 只有显式配置了 `BRIDGE_TRUST_PROXY=1`（部署在可信反代之后）才信任
 * x-forwarded-for。默认**不信**：authFailKey 此前无条件取 XFF 首值做退避键，
 * 直连场景下攻击者每请求换一个伪造 XFF 就得到一个全新的空计数桶 ——
 * 退避永不触发，token 爆破完全不受限速（旧注释的威胁方向写反了：
 * 伪造 XFF 买到的是"无退避"，不是"自己的退避"）。
 */
function xffTrusted() {
  return process.env.BRIDGE_TRUST_PROXY === '1' || process.env.BRIDGE_TRUST_PROXY === 'true';
}

function authFailKey(req) {
  if (xffTrusted()) {
    const fwd = req.headers?.['x-forwarded-for'];
    const first = typeof fwd === 'string' ? fwd.split(',')[0].trim() : '';
    if (first) return first;
  }
  return req.socket?.remoteAddress || 'unknown';
}

/** @returns {{blocked: boolean, retryAfterMs: number}} */
export function checkAuthBackoff(req) {
  const key = authFailKey(req);
  const entry = AUTH_FAIL_STATE.get(key);
  if (!entry) return { blocked: false, retryAfterMs: 0 };

  const now = Date.now();
  if (entry.blockedUntil && entry.blockedUntil > now) {
    return { blocked: true, retryAfterMs: entry.blockedUntil - now };
  }
  if (entry.lastFailAt && now - entry.lastFailAt > AUTH_FAIL_WINDOW_MS) {
    AUTH_FAIL_STATE.delete(key);
  }
  return { blocked: false, retryAfterMs: 0 };
}

/** Record a failed auth attempt and escalate. */
export function noteAuthFailure(req) {
  const key = authFailKey(req);
  const now = Date.now();
  let entry = AUTH_FAIL_STATE.get(key);
  if (!entry || (entry.lastFailAt && now - entry.lastFailAt > AUTH_FAIL_WINDOW_MS)) {
    entry = { count: 0, firstFailAt: now, lastFailAt: now, blockedUntil: 0 };
  }
  entry.count += 1;
  entry.lastFailAt = now;

  if (entry.count > AUTH_FAIL_THRESHOLD) {
    entry.blockedUntil = now + AUTH_FAIL_BLOCK_MS;
    entry.count = AUTH_FAIL_THRESHOLD; // do not let it grow unbounded
  }
  AUTH_FAIL_STATE.set(key, entry);
}

/** A successful auth clears the caller's backoff. */
export function clearAuthFailures(req) {
  AUTH_FAIL_STATE.delete(authFailKey(req));
}

/**
 * 定期清掉过期条目。此前只有"同一个 IP 再次失败"才会重置自己的记录，
 * 公网扫描器换 IP 就能让 Map 永久增长。
 */
export function pruneAuthFailures(now = Date.now()) {
  let removed = 0;
  for (const [key, entry] of AUTH_FAIL_STATE) {
    const last = entry.lastFailAt || 0;
    const blocked = entry.blockedUntil || 0;
    if (now - last > AUTH_FAIL_WINDOW_MS && blocked <= now) {
      AUTH_FAIL_STATE.delete(key);
      removed++;
    }
  }
  return removed;
}

/** Test seam — the backoff map is module state. */
export function _resetAuthBackoff() {
  AUTH_FAIL_STATE.clear();
}

export function extractToken(req, parsed) {
  const authHeader = req.headers['authorization'];
  if (authHeader && authHeader.startsWith('Bearer ')) return authHeader.slice(7).trim();
  if (req.headers['x-dsh-token']) return String(req.headers['x-dsh-token']).trim();
  if (req.headers['x-auth-code']) return String(req.headers['x-auth-code']).trim();
  // `?token=` used to be accepted here. URLs end up in proxy access logs,
  // browser history, Android network diagnostics and Referer chains, so the
  // token leaked without anyone observing a failed request. Headers only.
  // (parsed is still accepted for call-site compatibility.)
  return '';
}

export function authenticateRequest(req, parsed) {
  const token = extractToken(req, parsed);
  if (!token) {
    return { ok: false, code: 401, error: '缺少认证授权码 (Authorization Token Required)' };
  }
  if (_verifyToken(token)) {
    // Global/env token → admin. Paired-device token → the real device record,
    // so touchDevice() actually updates lastSeenAt and the settings page shows
    // live usage instead of a hardcoded "admin" that never matched anything.
    const dev = _findDeviceByToken(token);
    if (dev) {
      return { ok: true, device: { id: dev.id, name: dev.name || '移动设备', role: dev.role || 'readwrite' } };
    }
    return { ok: true, device: { id: 'admin', name: '移动终端', role: 'readwrite' } };
  }
  return { ok: false, code: 401, error: '授权码错误，请在 DSH 设置中查看正确授权码' };
}

/* ------------------------------------------------------------------ *
 * body reading with 2MB cap
 * ------------------------------------------------------------------ */

/**
 * Buffer a request body, rejecting anything over MAX_BODY_SIZE.
 *
 * On overflow we answer 413 and destroy the socket only after the response has
 * flushed (res.on('finish') + short delay). Destroying immediately caused
 * clients to observe ECONNRESET instead of the 413 they were meant to get.
 */
export function readBodyWithLimit(req, res, { limit = MAX_BODY_SIZE, sendJson }) {
  return new Promise((resolve, reject) => {
    let raw = '';
    let bytes = 0;
    let aborted = false;

    const overflow = () => {
      aborted = true;
      sendJson(413, { error: `Payload Too Large: Request body exceeds ${Math.floor(limit / 1024 / 1024)}MB limit` });
      req.on('data', () => {});
      req.resume();
      res.on('finish', () => {
        setTimeout(() => { try { req.destroy(); } catch { /* already gone */ } }, 50);
      });
      reject(Object.assign(new Error('PAYLOAD_TOO_LARGE'), { aborted: true }));
    };

    const declared = parseInt(req.headers['content-length'], 10);
    if (!isNaN(declared) && declared > limit) {
      overflow();
      return;
    }

    req.on('data', (chunk) => {
      if (aborted) return;
      bytes += chunk.length;
      if (bytes > limit) return overflow();
      raw += chunk;
    });
    req.on('end', () => { if (!aborted) resolve(raw); });
    req.on('error', (err) => { if (!aborted) reject(err); });
  });
}

export function parseJsonBody(raw) {
  try { return JSON.parse(raw || '{}'); } catch { return {}; }
}

/* ------------------------------------------------------------------ *
 * session removal
 * ------------------------------------------------------------------ */

/**
 * Delete a session.
 *
 * The DSH engine exposes NO session/delete RPC — verified: session/delete,
 * session/remove, session/destroy, session/archive and variants all return 404.
 * The previous bridge code called it anyway, swallowed the 404 with
 * `catch (_) {}`, and answered HTTP 200 "Deleted", so the client's delete button
 * silently did nothing and the E2E suite accumulated >1000 empty sessions.
 *
 * The only mutation the engine accepts and persists is `global.archivedSessionIds`
 * (its own UI uses exactly that). So we: detach the id from its workspace, append
 * it to the archive set, and drop the projection cache file.
 *
 * Returns { ok, archived, detached, cacheRemoved, error } — callers must surface
 * failures instead of claiming success.
 */
/* ------------------------------------------------------------------ *
 * Deliverables: extraction + membership
 *
 * These live here rather than in features.mjs because BOTH features.mjs and
 * extensions.mjs must answer "which files did this session present?", and
 * features.mjs already imports extensions.mjs — so extensions cannot import
 * features without creating a cycle. features.mjs re-exports both names, so
 * existing importers and tests keep working unchanged.
 * ------------------------------------------------------------------ */

/**
 * Collect every `deliverables/presented` declaration from session records.
 *
 * Newest declaration wins per path: a file presented in two turns is one row,
 * attributed to the later turn. Paths are resolved to absolute form for the
 * download route, while `display` keeps the relative label the phone shows.
 *
 * @param records - `session/page` records (`{ event }` entries).
 * @param cwd - the session's working directory, used to resolve relatives.
 * @returns deliverable rows, newest first.
 */
export function extractDeliverables(records, cwd) {
  if (!Array.isArray(records)) return [];
  const byPath = new Map();
  for (const record of records) {
    const ev = record?.event;
    if (!ev || ev.type !== 'deliverables/presented') continue;
    const files = Array.isArray(ev.data?.files) ? ev.data.files : [];
    for (const file of files) {
      const raw = typeof file?.path === 'string' ? file.path.trim() : '';
      if (!raw) continue;
      const absolute = path.isAbsolute(raw) ? raw : path.resolve(cwd || '.', raw);
      byPath.set(absolute, {
        path: absolute,
        display: raw,
        description: typeof file.description === 'string' ? file.description : '',
        turn: ev.data?.turn ?? null,
        seq: typeof ev.seq === 'number' ? ev.seq : null,
        time: typeof ev.time === 'number' ? ev.time : null
      });
    }
  }
  return [...byPath.values()].sort((a, b) => (b.seq ?? 0) - (a.seq ?? 0));
}

/**
 * Resolve a download request against the declared deliverables.
 *
 * Only paths the session actually presented may be downloaded — the phone
 * cannot turn this route into an arbitrary file read, and a path traversal in
 * the query is rejected by exact membership rather than by string filtering.
 *
 * @param deliverables - rows from {@link extractDeliverables}.
 * @param requested - the path the client asked for.
 * @returns the matching row, or null.
 */
export function resolveDeliverable(deliverables, requested) {
  if (!requested || typeof requested !== 'string') return null;
  const wanted = path.resolve(requested);
  for (const row of deliverables) {
    if (path.resolve(row.path) === wanted) return row;
  }
  return null;
}

/**
 * Explain WHY a deliverable request was refused, in a way the phone can act on.
 *
 * The audit called this out and it was still true: a path that could not be
 * RESOLVED (the session recorded no cwd, so a relative declaration resolved
 * against the gateway process's own working directory) produced the exact same
 * 403 as a path that was never presented. That is "解析问题伪装成了权限问题" — the
 * user goes looking for a permission problem that does not exist.
 *
 * Two things are deliberately NOT done here:
 *   * `status` stays 403. The sets differ in cause, not in authority: none of
 *     these is allowed through, and the App shows `error` verbatim.
 *   * `presented` paths are never echoed back. The caller already has the listing
 *     from the deliverables route; repeating it here would turn a refusal into a
 *     file-enumeration surface for any path the client invents.
 *
 * Lives in core.mjs because both features.mjs and extensions.mjs refuse
 * deliverables, and features.mjs already imports extensions.mjs — importing one
 * from the other would be a cycle.
 *
 * @param deps - `{ presented, cwd }`. `presented` is the declared listing (used
 *   for its length only); `cwd` is the session workspace, or null when unknown.
 * @returns `{ status, code, error, hint, presentedCount }`.
 */
export function describeDeliverableRefusal({ presented = [], cwd = null } = {}) {
  const count = Array.isArray(presented) ? presented.length : 0;
  if (!cwd) {
    return {
      status: 403,
      code: 'deliverable-cwd-unknown',
      error: '该会话没有记录工作目录，无法解析交付物的相对路径',
      hint: '这是会话元数据缺失（多为很旧的会话），不是权限问题。改用清单里的绝对路径重试。',
      presentedCount: count
    };
  }
  if (count === 0) {
    return {
      status: 403,
      code: 'deliverable-none-presented',
      error: '该会话还没有声明过任何交付物',
      hint: 'agent 需要用 present 声明文件后，它才会出现在清单里。',
      presentedCount: 0
    };
  }
  return {
    status: 403,
    code: 'deliverable-not-in-set',
    error: '该文件不在本会话的交付物清单中',
    hint: `本会话已声明 ${count} 项交付物，请从清单中选择（路径需与声明时完全一致）。`,
    presentedCount: count
  };
}

/**
 * [P0] Session ids reach the filesystem, so they have to be shape-checked first.
 *
 * deleteSession() built `${clean}.json` / `${id}.json` out of the raw caller
 * input and passed it to path.join(cacheDir, name) followed by fs.unlinkSync.
 * Nothing filtered the id, so `sessionId: "../../../../storages/workspace"`
 * resolved outside the cache directory and deleted an arbitrary .json file —
 * including the workspace table itself and the gateway's own
 * mobile-bridge/config.json. The endpoint is authenticated, but the token is an
 * 8-character shared secret, so this is a privilege escalation from "can talk to
 * the gateway" to "can delete host files".
 *
 * Real ids are `session-<uuid>` or a bare uuid; 1-64 of [A-Za-z0-9_-] covers both
 * with room to spare and admits no separator, dot, or drive character.
 */
const SESSION_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

export function assertSessionId(sessionId) {
  if (typeof sessionId !== 'string') return { ok: false, error: 'sessionId must be a string' };
  const id = sessionId.trim();
  if (!id) return { ok: false, error: 'Missing or empty sessionId' };
  const bare = id.replace(/^session-/, '');
  if (!SESSION_ID_RE.test(bare)) {
    return { ok: false, error: 'Invalid sessionId: only [A-Za-z0-9_-] up to 64 characters are allowed' };
  }
  return { ok: true, id, bare };
}

/**
 * 一条待答提问是否已经过了「还能答」的时限。
 *
 * ## 为什么单独抽出来
 *
 * 2026-10-29 现网事故：问题 08:32:34 到达时手机恰好离线（审计记
 * `question/deferred`，`offeredTo` 为空），用户 09:05 才点选 —— 中间那条
 * **「无人认领 5 分钟就丢」** 的规则已经把条目删了，于是作答被判
 * `unknown-question`：**手机上看着"提交成功"，电脑端（Web）却还在等他选**。
 *
 * 判据必须是「时间」与「引擎是否还认这个提问」两件事，**不能**掺进
 * 「有没有 socket 认领」——`offeredTo` 为空只说明此刻没有手机连着，不代表
 * 这张卡没显示在谁屏幕上；把两者混在一起，就会删掉用户正要点的东西。
 *
 * 「引擎是否还认」由调用方用 `userQuestions` 投影另行核对（有 callId 时），
 * 这里只给出时间上限。
 *
 * @param {{createdAt?: number}} question 待答条目（`createdAt` 为毫秒时间戳）
 * @param {number} now 当前毫秒时间戳
 * @param {number} ttlMs 硬上限（默认 30 分钟）
 * @returns {boolean} true = 应丢弃
 */
export function pendingQuestionExpired(question, now, ttlMs = 30 * 60 * 1000) {
  const createdAt = Number(question?.createdAt);
  if (!Number.isFinite(createdAt)) return false; // 时间戳缺失：宁可留着，也不误删
  return Number(now) - createdAt > ttlMs;
}

/**
 * Upper bound on global.archivedSessionIds.
 *
 * Archiving is how this bridge deletes, and the list was appended to forever —
 * 1350 entries had accumulated by 2026-10-08. workspace.json is parsed
 * synchronously inside getWorkspacesData(), which is already called per request,
 * so an unbounded list is a slow leak that taxes every single API call.
 *
 * Eviction drops the OLDEST ids and is audited. The trade-off is explicit: an
 * evicted id can make a very old deleted session visible again, which is
 * strictly better than a store file that grows without limit. 20000 is far above
 * any realistic accumulation rate, so this should only ever fire on a runaway
 * loop — which is exactly when you want it to.
 */
const MAX_ARCHIVED_SESSION_IDS = Number(process.env.DSH_MAX_ARCHIVED_SESSIONS || 20000);

export function deleteSession({ home = dshHome(), sessionId, workspaceId = null }) {
  const checked = assertSessionId(sessionId);
  if (!checked.ok) return { ok: false, error: checked.error };
  const id = checked.id;
  const clean = checked.bare;

  const wsPath = path.join(home, 'storages', 'workspace.json');
  const cacheDir = path.join(home, 'storages', 'session_projcache', 'sessions');

  let ws;
  try {
    ws = JSON.parse(fs.readFileSync(wsPath, 'utf8'));
  } catch (err) {
    return { ok: false, error: `Cannot read workspace store: ${err?.message}` };
  }

  // 1. Archive — the one change the engine round-trips instead of overwriting.
  if (!ws.global) ws.global = {};
  const archived = Array.isArray(ws.global.archivedSessionIds) ? ws.global.archivedSessionIds : [];
  if (!archived.includes(id)) archived.push(id);
  let evicted = 0;
  while (archived.length > MAX_ARCHIVED_SESSION_IDS) {
    archived.shift();
    evicted++;
  }
  // No audit() call here: core.mjs deliberately does not import store.mjs (store
  // imports core for the audit sink, so the reverse edge would be a cycle). The
  // eviction count is returned instead and the caller audits it.
  ws.global.archivedSessionIds = archived;

  // 2. Detach from the workspace id list (also honouring the session- prefix variants).
  let detached = 0;
  const table = ws?.tables?.workspaces;
  if (table) {
    for (const [wsKey, info] of Object.entries(table)) {
      if (!Array.isArray(info.sessionIds)) continue;
      if (workspaceId && wsKey !== workspaceId && info.workspaceId !== workspaceId) continue;
      const before = info.sessionIds.length;
      info.sessionIds = info.sessionIds.filter((s) => s !== id && s !== clean && s !== `session-${clean}`);
      detached += before - info.sessionIds.length;
    }
  }

  // 3. Persist atomically.
  try {
    const tmp = `${wsPath}.bridge-delete.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(ws, null, 2), 'utf8');
    fs.renameSync(tmp, wsPath);
  } catch (err) {
    return { ok: false, error: `Cannot write workspace store: ${err?.message}`, archived: true };
  }

  // 4. Drop the projection cache.
  let cacheRemoved = false;
  for (const name of [`${clean}.json`, `${id}.json`, `session-${clean}.json`]) {
    const p = path.join(cacheDir, name);
    try {
      if (fs.existsSync(p)) { fs.unlinkSync(p); cacheRemoved = true; }
    } catch { /* the archive entry already hides it */ }
  }

  return { ok: true, sessionId: id, archived: true, detached, cacheRemoved, evicted };
}

/**
 * Archive / un-archive a session WITHOUT detaching it from its workspace.
 *
 * The engine's own UI toggles exactly this field (`global.archivedSessionIds`),
 * so writing it here is the same mutation the Web UI performs — unlike
 * deleteSession, the session stays registered and merely changes visibility.
 * Returns { ok, archived, error }.
 */
export function archiveSession({ home = dshHome(), sessionId, archive = true }) {
  const checked = assertSessionId(sessionId);
  if (!checked.ok) return { ok: false, error: checked.error };
  const id = checked.id;
  const clean = checked.bare;

  const wsPath = path.join(home, 'storages', 'workspace.json');
  let ws;
  try {
    ws = JSON.parse(fs.readFileSync(wsPath, 'utf8'));
  } catch (err) {
    return { ok: false, error: `Cannot read workspace store: ${err?.message}` };
  }
  if (!ws.global) ws.global = {};
  const archived = Array.isArray(ws.global.archivedSessionIds) ? ws.global.archivedSessionIds : [];

  let nowArchived;
  if (archive) {
    for (const variant of [id, clean]) {
      if (!archived.includes(variant)) archived.push(variant);
    }
    nowArchived = true;
  } else {
    const before = archived.length;
    const kept = archived.filter((s) => s !== id && s !== clean && s !== `session-${clean}`);
    ws.global.archivedSessionIds = kept;
    nowArchived = false;
    if (kept.length === before && !archived.includes(id) && !archived.includes(clean)) {
      // Wasn't archived to begin with — still a success, nothing to write.
      return { ok: true, sessionId: id, archived: false, changed: false };
    }
  }
  if (nowArchived) ws.global.archivedSessionIds = archived;

  try {
    const tmp = `${wsPath}.bridge-archive.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(ws, null, 2), 'utf8');
    fs.renameSync(tmp, wsPath);
  } catch (err) {
    return { ok: false, error: `Cannot write workspace store: ${err?.message}` };
  }
  return { ok: true, sessionId: id, archived: nowArchived, changed: true };
}

/**
 * Rename a session by editing its projection cache title row. The engine keeps
 * session titles in `record.rows.title.val` inside the projcache file (verified
 * against getWorkspacesData's read of the same field). Returns { ok, error }.
 */
export function renameSession({ home = dshHome(), sessionId, title }) {
  const checked = assertSessionId(sessionId);
  if (!checked.ok) return { ok: false, error: checked.error };
  const id = checked.id;
  const clean = checked.bare;
  const newTitle = typeof title === 'string' ? title.trim() : '';
  if (!newTitle) return { ok: false, error: 'title must be a non-empty string' };
  if (newTitle.length > 200) return { ok: false, error: 'title too long (max 200)' };

  const cacheDir = path.join(home, 'storages', 'session_projcache', 'sessions');
  for (const name of [`${id}.json`, `session-${clean}.json`, `${clean}.json`]) {
    const p = path.join(cacheDir, name);
    let cache;
    try {
      cache = JSON.parse(fs.readFileSync(p, 'utf8'));
    } catch { continue; }
    if (!cache?.record?.rows) continue;
    try {
      if (!cache.record.rows.title) cache.record.rows.title = { val: '' };
      cache.record.rows.title.val = newTitle;
      // Keep the legacy firstPrompt-derived fallback in sync so any consumer
      // reading titleInput doesn't resurrect the old auto-title.
      if (cache.record.rows.titleInput?.val?.first) {
        cache.record.rows.titleInput.val.first.text = newTitle;
      }
      const tmp = `${p}.bridge-rename.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(cache, null, 2), 'utf8');
      fs.renameSync(tmp, p);
      return { ok: true, sessionId: id, title: newTitle };
    } catch (err) {
      return { ok: false, error: `Cannot write session cache: ${err?.message}` };
    }
  }
  return { ok: false, error: 'session cache not found' };
}

export { fs, path, url };


