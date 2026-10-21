// dsh-mobile-bridge —— DSH 移动终端安全桥接与网关插件
// 
// 职责：
//   1. 作为 DSH 原生 Cordis 插件，在 DSH 进程内原生启动移动网关（默认端口 3088）。
//   2. 挂载 /api/mobile/* REST API 与 WebSocket 实时双工流式中继，供 Android App（DSH Mobile）调用。
//   3. 设备配对（6 位码握手）+ 令牌摘要存储 + 角色权限控制（只读 / 读写）+ 访问审计日志。
//   4. 无缝集成 DSH 设置页：在「设置 → 移动终端」中可视化管理移动网关、配对设备、NPS 隧道。
//
// 安装包分发**不在本插件的职责内**（2026-10-21 移除）：网关不再托管、也不再自动
// 抓取 APK。一切安装包以 GitHub Releases 为唯一来源 —— App 内的更新检查直接读
// `releases/latest/download/latest.json`，设置页与首页只给 Releases 链接。
// 之所以删掉这条通路：网关分发需要本地留一份包并与远端版本对齐，一旦忘记刷新就
// 会长期静默发旧包（1.31.1 事故），而这层缓存本身没有任何业务价值。

import { createServer } from 'node:http';
import http from 'node:http';
import https from 'node:https';
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import url from 'node:url';
import { homedir } from 'node:os';
import os from 'node:os';
import zlib from 'node:zlib';
import { createRequire } from 'node:module';

import {
  loadConfig, saveConfig, verifyToken, findDeviceByToken, ensureDataDir, dshHome, audit, readAudit,
  loadDevices, saveDevices, touchDevice, revokeDevice,
  newPairCode, pairCodeTtlMs, newToken, hashToken, roleCanWrite,
  REMOTE_PROVIDERS,
  loadPermissions, savePermissions, permissionsFile
} from './store.mjs';
import { installRpc, RPC_CHANNEL, ENDPOINTS } from './rpc.mjs';
import { sendFile } from './send-file.mjs';
import {
  handleFeatureRoute,
  buildNtfyRequest,
  deliverNtfy,
  describeNtfyTarget,
  redactNtfyDetail,
  parsePorcelain,
  parseNumstat,
  combineChanges,
  parseUnifiedDiff,
  extractDeliverables,
  resolveDeliverable,
  collectSessionRecords,
  convertSessionRecordsToMessages,
  readHistoryPage,
  probeSessionCursor,
  claimsMobileFeatureRoute
} from './features.mjs';
import {
  handleExtensionRoute,
  claimsExtensionRoute,
  extractToolCallFiles
} from './extensions.mjs';
import { discoverGitRepos, runQuickCommand } from './host-ops.mjs';
import { ensureCertificate, localHosts } from './tls.mjs';
import { ensureCloudflared, createQuickTunnel } from './tunnel.mjs';
import { loadRunbooksFile, runRunbook, allowedBinariesFromEnv } from './runbook.mjs';
import { createAlertEngine } from './alerts.mjs';
import {
  BRIDGE_VERSION,
  MAX_BODY_SIZE,
  HEARTBEAT_INTERVAL_MS,
  checkAuthBackoff,
  noteAuthFailure,
  clearAuthFailures,
  createApprovalQueue,
  createApprovalTokens,
  isSensitiveApprovalPolicy,
  createFollowerRegistry,
  createTurnRegistry,
  createPersonaStore,
  createSnippetStore,
  createPathSanitizer,
  createPermissionStore,
  createCookieFactory,
  createRpcCaller,
  createProjCacheReader,
  isCommandReadOnly,
  classifyCommand,
  coerceToolInput,
  isCarriedContext,
  describeTurnEnd,
  isFailedTurnEnd,
  toFullSessionId,
  extractToken,
  authenticateRequest,
  readBodyWithLimit,
  parseJsonBody,
  deleteSession,
  archiveSession,
  renameSession,
  assertSessionId,
  configurePersistence,
  configurePermissionsPersistence
} from './core.mjs';

import {
  projectionCacheCandidates,
  createEventLogTitleReader
} from './sessiontitle.mjs';
// Inject the persistence helpers core needs; core must not import store.mjs
// because store imports core (audit sink).
configurePersistence({ verifyToken, findDeviceByToken });
configurePermissionsPersistence({
  load: loadPermissions,
  save: savePermissions,
  file: permissionsFile
});

const require = createRequire(import.meta.url);
const WebSocket = require('ws');
let YAML;
try {
  YAML = require('yaml');
} catch {
  try {
    YAML = require(path.join(dshHome(), 'profiles', 'web', 'node_modules', 'yaml'));
  } catch {
    YAML = {
      parse: (str) => JSON.parse(str),
      parseDocument: () => ({ toString: () => '' })
    };
  }
}

const name = 'dsh-mobile-bridge';
// [fix 2026-10-15] 只声明 `connection`，**去掉 `webServer`**。
//
// 为什么必须去掉：本插件不注入 webServer，就无法在本fiber 里访问它。Cordis 的
// ctx 是 Proxy，未声明的服务一访问就抛 `cannot get property "webServer" without
// inject`（cordis/lib/index.js:675）—— 而且这个抛出发生在 apply() 里，于是整个
// apply 中断，installRpc() 从未被调用，浏览器里所有 RPC 落进 SPA fallback 回
// 405，设备列表与配对码一起失效，而 3088 网关因为端口早已 bind 仍在监听。
//
// 而它其实并不需要 webServer：引擎端口取自 internals/config/默认值 3080，
// readWebServerPort() 只是可选增强，取不到就退回 3080，行为完全正确。
//
// 保留 `connection` 是必须的 —— installRpc() 要用它注册 RPC 通道，没有它设置页
// 的 devices/list 与 pair/qrdata 一律 405。
const inject = ['connection'];

/**
 * HMAC secret used to mint the signed cookie that lets the bridge talk to the
 * engine's own HTTP/RPC surface.
 *
 * This used to be a literal in source control, which published the engine's
 * signing key. It must resolve to whatever the engine actually uses, or every
 * RPC call comes back `unauthorized`.
 *
 * Resolution order:
 *   1. DSH_SECRET / DSH_INTERNAL_SECRET environment variable
 *   2. the engine's own credentials file (~/.dsh/.credentials.yaml)
 *   3. the generated secret file the bridge writes on first run
 *
 * NOTE: do not invent a random secret as a silent fallback — the engine will
 * reject every signed cookie. If none of the above yield a value we keep the
 * generated one only as a last resort and log loudly.
 */
function resolveInternalSecret() {
  const fromEnv = process.env.DSH_SECRET || process.env.DSH_INTERNAL_SECRET;
  if (fromEnv && fromEnv.trim()) return fromEnv.trim();

  // The engine stores its auth secret here.
  for (const rel of ['.credentials.yaml', 'credentials.yaml', 'settings.yaml']) {
    try {
      const file = path.join(dshHome(), rel);
      if (!fs.existsSync(file)) continue;
      const m = fs.readFileSync(file, 'utf8')
        .match(/^\s*secret\s*:\s*['"]?([^'"\s#]+)/mi);
      if (m?.[1]) return m[1];
    } catch { /* try the next candidate */ }
  }

  // Fall back to the bridge's own generated secret so cookie minting at least
  // works for this install (requires DSH_SECRET to match on the engine side).
  try {
    const dir = path.join(dshHome(), 'mobile-bridge');
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    const file = path.join(dir, 'internal-secret');
    if (fs.existsSync(file)) {
      const v = fs.readFileSync(file, 'utf8').trim();
      if (v) return v;
    }
    const generated = crypto.randomBytes(32).toString('base64url');
    fs.writeFileSync(file, generated, 'utf8');
    try { fs.chmodSync(file, 0o600); } catch { /* best effort on Windows */ }
    console.warn(
      '[dsh-mobile-bridge] 未找到引擎密钥（~/.dsh/.credentials.yaml）。' +
      '已生成本地密钥；若 RPC 返回 unauthorized，请设置环境变量 DSH_SECRET 为引擎实际密钥。'
    );
    return generated;
  } catch {
    return crypto.randomBytes(32).toString('base64url');
  }
}

/**
 * Upper bound on a mobile socket's send buffer before the gateway drops it.
 *
 * There is no other writer on this connection: it carries deltas, tool results,
 * todo snapshots and question frames. A phone that loses signal — or is merely
 * slower than a fast assistant stream — would otherwise grow the gateway's heap
 * until the whole dsh web process died, taking every session on the box with it.
 * Dropping one stalled client is strictly better than that.
 *
 * Exported so the threshold can be unit-tested directly: `bufferedAmount` on a
 * real socket is a read-only getter, so a test cannot reach this condition by
 * sending bytes and hoping the kernel buffer fills. Without this seam the only
 * possible test would be a vacuous one.
 */
export const MAX_CLIENT_BUFFER_BYTES = 8 * 1024 * 1024;

export function shouldDivertForBackpressure(bufferedAmount) {
  return typeof bufferedAmount === 'number'
    && Number.isFinite(bufferedAmount)
    && bufferedAmount > MAX_CLIENT_BUFFER_BYTES;
}

/**
 * Try to read the engine's webserver port without ever throwing.
 *
 * `ctx.webServer` is not a plain object: Cordis builds ctx as a Proxy that
 * **throws** `cannot get property "webServer" without inject` for any service
 * that was not declared on this fiber — an optional chain cannot swallow that,
 * because the trap raises before `?.` ever sees `undefined`. Reading it from a
 * bare `try` is the only way to degrade instead of aborting `apply()`.
 *
 * Returns undefined when the service is not visible from here, which is the
 * normal case for the standalone gateway entry (index.js) and acceptable for the
 * plugin: the caller falls back to configured/默认 ports.
 */
function readWebServerPort(ctx, logger) {
  try {
    const port = ctx.webServer?.port;
    return typeof port === 'number' && port > 0 ? port : undefined;
  } catch (err) {
    // Not an error condition: this fiber simply cannot see the webserver
    // service. Log once so the reason for the fallback is never a mystery.
    logger.info?.(
      'dsh-mobile-bridge: ctx.webServer 不可见（%s），引擎端口改用配置/默认值。',
      err?.message ?? String(err)
    );
    return undefined;
  }
}

/**
 * TLS 监听端口。
 *
 * 只有环境变量一个开关：`BRIDGE_TLS_PORT=0` 关闭，未设置时默认 3443。
 * 不做成 config.json 字段，是因为设置页还没有对应开关——一个用户看不见、
 * 改不到的值放进去只会增加排查成本。
 */
export function resolveTlsPort(env = process.env) {
  const raw = env.BRIDGE_TLS_PORT;
  if (raw == null || String(raw).trim() === '') return 3443;
  const n = Number(String(raw).trim());
  return Number.isFinite(n) && n >= 0 && n <= 65535 ? n : 3443;
}

export function apply(ctx, config = {}, internals = {}) {
  const logger = ctx.logger?.(name) ?? console;
  const cfg = loadConfig();
  // [fix 2026-10-15] 原来这里是 `ctx.webServer?.port` —— 可选链救不了它，因为
  // Cordis 的 ctx 是一个 Proxy：访问未在 fiber.inject 里声明的服务会**抛错**，而
  // 不是返回 undefined（cordis/lib/index.js:675）。于是这一行抛
  // `cannot get property "webServer" without inject`，apply() 当场中断，
  // installRpc() 从未被调用 → 浏览器里所有 RPC 落进 SPA fallback → HTTP 405，
  // 设备列表和配对码全部失效，而 3088 网关因为在本行之前已经起了端口所以仍在监听。
  //
  // dshPort 只是"网关转发到引擎时用哪个端口"，真正需要的是它对得上引擎实际端口。
  // 引擎默认 3080，config.dshPort 可覆盖，internals.dshPort 供独立网关入口
  // （index.js 那条 `node index.js` 路径）显式传入。ctx.webServer 只是锦上添花，
  // 拿不到就用下面的兜底 —— 为了一个可有可无的值把整个插件的 RPC 通道搭进去不划算。
  const webServerPort = readWebServerPort(ctx, logger);
  const dshPort = internals.dshPort ?? config.dshPort ?? webServerPort ?? 3080;
  const listenPort = internals.port ?? config.port ?? cfg.port ?? 3088;
  // Security default: loopback only.
  //
  // This gateway proxies the DSH engine's full surface (sessions, approvals,
  // permission policy, workspace file reads) over plain HTTP with a single
  // shared token. Binding every interface by default put it on the LAN — and
  // therefore within reach of any other device on that network — without the
  // operator ever asking for that. LAN / tunnel exposure is now explicit:
  // set BRIDGE_HOST=0.0.0.0 (standalone) or `host:` in the Cordis plugin config.
  const bindHost = config.host
    ?? process.env.BRIDGE_HOST
    ?? '127.0.0.1';
  const dshHomeDir = dshHome();

  /** [v1.35 / 3.1] Runbook 数据文件（用户可直接编辑）。 */
  const runbookFile = path.join(dshHomeDir, 'mobile-access', 'runbooks.yaml');

  ensureDataDir();

  /* ------------------------------------------------------------------ *
   * [v1.35 / 1.1] 自签证书（幂等：存在且有效就复用）
   *
   * 放在最前面是因为配对二维码要带指纹（1.3），而二维码路由在 requestHandler
   * 闭包里；提前算好也让 TLS 端口启动不必再读盘。
   *
   * 失败不 fatal：证书签发失败时 tlsPort 不会启动，但明文 3088 与所有既有
   * 功能必须继续可用（降级优于连不上）。
   * ------------------------------------------------------------------ */
  let certFingerprint = '';
  let tlsCert = null;
  try {
    tlsCert = ensureCertificate({ hosts: localHosts() });
    certFingerprint = tlsCert.fingerprint;
    if (tlsCert.regenerated) {
      logger.info('dsh-mobile-bridge: 自签证书已签发/更新（%s）指纹 %s', tlsCert.reason, certFingerprint);
      audit('tls/cert', { reason: tlsCert.reason, fingerprint: certFingerprint });
    }
  } catch (err) {
    logger.warn('dsh-mobile-bridge: 自签证书初始化失败（%s），HTTPS/WSS 不可用', err?.message ?? err);
  }

  /** 0 = 关闭；默认 3443（见 resolveTlsPort）。 */
  const tlsPort = resolveTlsPort();

  /**
   * Origins allowed to make credentialed cross-origin calls.
   *
   * The Android client is a native app and sends no Origin at all, so it is
   * unaffected by this list — this exists purely to stop *browsers* on other
   * sites from reaching the gateway. Default: the DSH web UI on loopback (any
   * port), which is the only browser surface that legitimately talks here.
   * Override with BRIDGE_CORS_ORIGINS as a comma-separated list; `*` is not
   * accepted on purpose — it is the configuration we are removing.
   */
  const CORS_ALLOWED_ORIGINS = new Set(
    (process.env.BRIDGE_CORS_ORIGINS
      ? process.env.BRIDGE_CORS_ORIGINS.split(',')
      : []
    )
      .concat([`http://127.0.0.1:${dshPort}`, `http://localhost:${dshPort}`])
      .map((o) => o.trim().toLowerCase())
      .filter(Boolean)
  );

  let isDisposed = false; // Lifecycle flag to prevent zombie reconnects (F4.4)

  let lastWorkspaces = [];

  /**
   * Path guard for the workspace-memory API (F4.5).
   * Implemented in core; the registered-workspace source stays here because
   * getWorkspacesData() reads live DSH state owned by this entry.
   */
  const sanitizeWorkspaceFilePath = createPathSanitizer({
    getRegisteredWorkspaces: () => {
      try {
        const live = getWorkspacesData();
        if (Array.isArray(live) && live.length > 0) {
          lastWorkspaces = live;
          return live;
        }
      } catch { /* fall back to the last known snapshot */ }
      return Array.isArray(lastWorkspaces) ? lastWorkspaces : [];
    }
  });

  let pairSession = internals.pairSession ?? null;

  /**
   * Projection-cache reader with mtime memoization.
   *
   * getWorkspacesData() reads a JSON cache file per session (~1000 files on
   * this box) on every workspace fetch, and the phone polls that every 3
   * seconds. This plugin runs inside the dsh web process, so all those
   * readFileSync + JSON.parse calls blocked the engine's event loop. With the
   * memo an unchanged file costs one statSync.
   */
  const projCacheReader = createProjCacheReader({ dir: path.join(dshHomeDir, 'storages', 'session_projcache', 'sessions') });

  /**
   * [fix 2026-10-15] 归档域 + 事件日志的标题兜底读法。
   *
   * 之前 readProjectionRecord 只认 `storages/session_projcache/sessions/` 一个
   * 目录，于是 116/212 个会话在手机端显示成 `session-<uuid>`（实测，见
   * sessiontitle.mjs 头部）。现在三个存储位置都读。
   */
  const eventLogTitles = createEventLogTitleReader({
    log: (msg, err) => logger.warn(msg, err?.message || err)
  });

  /**
   * Signed-cookie minting and unary RPC live in core so both entry points speak
   * to the engine identically.  [unified]
   */
  const cookieFactory = createCookieFactory({ dshPort, secret: resolveInternalSecret() });
  const refreshCookie = async () => {
    try {
      return cookieFactory.refresh();
    } catch (e) {
      logger.warn('[dsh-mobile-bridge] 刷新 cookie 异常:', e?.message || e);
      return '';
    }
  };

  const callDshRpc = createRpcCaller({ dshPort, cookieFactory });

  /* ------------------------------------------------------------------ *
   * v1.14 能力：队列/交付物/diff/用量/ntfy 推送
   *
   * 这些是"重度远程操控"所需的读取与动作面。全部只读或幂等，且**不新建
   * 会话**；任何失败都如实回错，不假装成功。
   * ------------------------------------------------------------------ */

  /**
   * One session's projection-cache record, or null.
   *
   * ⚠️ The cache filename is NOT always the bare session id. Measured on this
   * install (2026-10-10): 2133 of 2468 files are named `session-<uuid>.json`
   * and only 335 are named `<uuid>.json`. The previous implementation stripped
   * the `session-` prefix and then read `${clean}.json` unconditionally, so it
   * missed 86.4% of sessions — which is why `readSessionCwd()` returned null
   * for almost everything (and `/api/mobile/workspace/changes` answered
   * `no-workspace`, while relative deliverable paths resolved against the dsh
   * web process's own working directory instead of the session's).
   *
   * Both spellings are tried, bare first so the existing behaviour is kept for
   * the sessions where it already worked.
   */
  function readProjectionRecord(sessionId) {
    // [fix 2026-10-16] 委托给按新鲜度选择的实现。旧循环"命中第一个存在的文件就
    // 停"在迁移共存期（主域陈旧件 + 归档域鲜活件并存）会让 cwd、交付物清单等
    // 全部读到 10-11 冻结的旧投影 —— 相对路径交付物因此解析到错误目录。
    return readFreshestProjection(sessionId);
  }

  /**
   * [fix 2026-10-16] 按新鲜度选投影，而不是按候选顺序选。
   *
   * 背景：archive-manager v1.0.17（10-13 安装）把投影存储迁到了
   * `session_projcache_archive_manager_v2`，但旧主域的文件**不删**——迁移共存期
   * 一个会话在两个域各有一份文件。而 `projectionCacheCandidates()` 的顺序永远
   * 主域在前，所有旧读取循环都是"命中第一个存在的文件就 break"（列表、历史、
   * 交付物扫描三处同病），于是主域里那份 10-11 冻结的陈旧投影把 v2 域里秒级
   * 更新的鲜活投影**永久遮蔽**。实测症状：本机 10-13 后的所有活跃会话在 App
   * 端被陈旧的 `blank=true, titleInput.count=0` 判成空会话而隐藏（包括诊断用的
   * 活会话本身：主域件停在 2026-10-11 20:33，v2 件 18:20 仍在更新、title 正常、
   * count=17）。主域 1908 个文件里 467 个停在同一分钟 —— 那是迁移时刻。
   *
   * 修法：两份都在时取 mtime 新的。不带 mtime 的旧循环语义是"顺序即权威"，
   * 它建立在"一个会话只有一份投影"的前提上；迁移把这个前提打破了。
   *
   * 注意 write 路径（session/model 更新，:1255 起）**保持只写主域**不动 ——
   * 往归档域写会让 archive-manager 与引擎的 domain 记账对不上（那里已有注释
   * 说明）。读新写旧在共存期是安全的：模型选择写进主域件后它就是两份中较新的
   * 一份，本函数自然选中它。
   */
  function readFreshestProjection(sessionId) {
    const candidates = projectionCacheCandidates(dshHomeDir, sessionId);
    let best = null;
    let bestMtime = -1;
    for (const cPath of candidates) {
      let st;
      try {
        st = fs.statSync(cPath);
      } catch {
        continue; // 该域没这份会话，正常
      }
      const record = projCacheReader.readJson(cPath);
      if (record && st.mtimeMs > bestMtime) {
        best = record;
        bestMtime = st.mtimeMs;
      }
    }
    return best;
  }

  /**
   * One session's title, from whichever store actually holds one.
   *
   * Order: projection cache (main domain → archive domain) → event log.
   * `rows.title.val` is authoritative when present; `rows.titleInput.val.first.text`
   * is the auto-title's first-prompt fallback, matching the pre-fix behaviour.
   *
   * @param {string} sessionId
   * @returns {{ title: string, firstPrompt: string }}
   */
  function readSessionTitle(sessionId) {
    const rows = readProjectionRows(sessionId);
    const cachedTitle = rows?.title?.val;
    const cachedPrompt = rows?.titleInput?.val?.first?.text || '';
    if (typeof cachedTitle === 'string' && cachedTitle.trim()) {
      return { title: cachedTitle.trim(), firstPrompt: cachedPrompt };
    }
    // Sync peek only: the decompress runs in the background (see
    // sessiontitle.mjs 的 peek/warm 说明), and the next poll picks the title up.
    const peeked = eventLogTitles.peek(dshHomeDir, sessionId);
    if (peeked && peeked.title) return { title: peeked.title, firstPrompt: peeked.firstPrompt || cachedPrompt };
    return { title: '', firstPrompt: cachedPrompt };
  }

  /** Decoded projection-cache rows for one session (no engine round trip). */
  function readProjectionRows(sessionId) {
    const record = readProjectionRecord(sessionId);
    return record?.record?.rows ?? null;
  }

  /** Session working directory from the projection cache, when recorded. */
  function readSessionCwd(sessionId) {
    const cwd = readProjectionRecord(sessionId)?.record?.identity?.cwd;
    return typeof cwd === 'string' && cwd ? cwd : null;
  }

  /**
   * Read all registered projections for one session, or null.
   *
   * Returns null (never throws) when the session is not live: the caller falls
   * back to the projection cache instead of showing an error card for a cold
   * conversation, which is the common case for a phone opening yesterday's task.
   */
  async function readProjections(sessionId) {
    try {
      const value = await callDshRpc('session/projections', {
        args: { request: { sessionId: toFullSessionId(sessionId) } }
      });
      return value?.values ?? null;
    } catch (err) {
      logger.warn('[dsh-mobile-bridge] session/projections 失败 %s: %s', sessionId, err?.message || err);
      return null;
    }
  }

  /**
   * Session records plus working directory, for deliverable discovery.
   *
   * ⚠️ The request shape matters more than it looks. `session/page`'s
   * `throughSeq` is a REQUIRED wire field (see `collectSessionRecords` in
   * features.mjs for the full evidence trail). The previous version sent only
   * `{ address, maxMessages: 200 }`, which the engine rejected with
   * `gateway/input-invalid` before it ever opened the session; the catch below
   * turned that into `{ records: [] }` and the deliverable list was therefore
   * empty for every session, forever. Verified end-to-end against the live
   * gateway: a session holding a real `deliverables/presented` event still
   * answered `{"deliverables":[]}`.
   */
  async function readSessionRecords(sessionId) {
    const cwd = readSessionCwd(sessionId);
    try {
      const { records, pages, truncated } = await collectSessionRecords({
        callDshRpc,
        sessionId: toFullSessionId(sessionId)
      });
      if (truncated) {
        logger.warn('[dsh-mobile-bridge] 交付物扫描未走完全部历史 %s（%d 页）', sessionId, pages);
      }
      return { records, cwd, truncated };
    } catch (err) {
      logger.warn('[dsh-mobile-bridge] session/page 失败（交付物扫描）%s: %s', sessionId, err?.message || err);
      return { records: [], cwd, truncated: false };
    }
  }

  /**
   * Changed files for a session's workspace, read with git.
   *
   * The engine's own `workspace/changes` event carries only the turn number and
   * keeps its summary/snapshot on the Host, so it cannot be replayed to a phone.
   * Reading the working tree with git gives the same practical answer — what did
   * this task change.
   *
   * ⚠️ [fix 2026-10-13] The first version refused with a flat
   * `not-a-git-repository` whenever the session's cwd was not itself a
   * repository, which left the phone's diff panel **permanently blank** for a
   * very common layout: a multi-project workspace such as
   * `E:\workspace\个人`, whose repositories live in its children
   * (`dsh_mobile`, `GZ`, `tickflow-stock-panel`, …). Two changes fix that:
   *
   *   1. **Repo discovery.** `discoverGitRepos` looks at the cwd, then at its
   *      ancestors, then at its immediate children, so the panel can offer the
   *      repositories it is standing next to instead of an empty screen.
   *   2. **Tool-call fallback.** `extractToolCallFiles` reads the session log for
   *      the files the agent's own `write`/`edit` calls named. That is durable
   *      truth about intent, available with no git at all, and it is the only
   *      source that still works when the change happened in a non-repo folder.
   *
   * Both are reported side by side rather than merged silently: `source` says
   * where the rows came from, so the App can label them honestly.
   */
  async function readWorkspaceChanges(sessionId, wantedPath) {
    const cwd = readSessionCwd(sessionId);
    if (!cwd) return { available: false, reason: 'no-workspace', files: [], source: 'none' };

    const runGit = (args, gitCwd = cwd) => new Promise((resolve) => {
      execFile('git', args, { cwd: gitCwd, maxBuffer: 4 * 1024 * 1024, windowsHide: true }, (error, stdout) => {
        if (error) resolve(null);
        else resolve(String(stdout));
      });
    });

    const inside = await runGit(['rev-parse', '--is-inside-work-tree']);
    const isRepo = inside !== null && inside.trim() === 'true';

    // The tool-call fallback is computed on every path: when git answers it is
    // shown as a supplement (a file the agent wrote may be outside the repo, or
    // gitignored), and when git cannot answer it is the whole answer.
    let fallback = { changed: [], read: [] };
    if (wantedPath || !isRepo) {
      try {
        const { records } = await readSessionRecords(sessionId);
        fallback = extractToolCallFiles(records, cwd);
      } catch (err) {
        logger.warn('[dsh-mobile-bridge] tool/call fallback failed %s: %s', sessionId, err?.message || err);
      }
    }

    if (!isRepo) {
      const repos = discoverGitRepos(cwd);
      return {
        available: false,
        reason: 'not-a-git-repository',
        source: fallback.changed.length ? 'tool-calls' : 'none',
        cwdKnown: true,
        files: fallback.changed.map((row) => ({
          // Workspace-relative on purpose: git rows use the same spelling, and
          // the per-file diff route round-trips `path` verbatim, so mixing an
          // absolute path in here would make one list carry two conventions.
          path: row.display || row.path,
          display: row.display || row.path,
          status: 'M',
          origPath: null,
          added: null,
          deleted: null,
          binary: false,
          fromToolCall: true,
          tool: row.tool,
          seq: row.seq
        })),
        readFiles: fallback.read.map((row) => ({ display: row.display, tool: row.tool, seq: row.seq })),
        repoCandidates: repos.children.map((c) => ({ name: c.name, path: c.name })),
        ancestorRepos: repos.ancestors.length,
        note: repositionNote(fallback.changed.length, repos.children.length)
      };
    }

    if (wantedPath) {
      // Per-file diff: `--no-color` keeps the payload renderable, and the path
      // comes from the already-listed change set (see the route), so no user
      // string reaches the command line unvalidated.
      const diff = await runGit(['diff', '--no-color', '--', wantedPath]);
      const stagedDiff = diff === null ? '' : diff;
      const untracked = await runGit(['diff', '--no-index', '--no-color', '/dev/null', wantedPath]);
      const text = stagedDiff.trim() ? stagedDiff : (untracked ?? '');
      return {
        available: true,
        source: 'git',
        path: wantedPath,
        hunks: parseUnifiedDiff(text),
        empty: !text.trim(),
        binary: /Binary files .* differ/.test(text)
      };
    }

    const porcelain = await runGit(['status', '--porcelain=v1', '-z']);
    const numstat = await runGit(['diff', '--numstat', 'HEAD']);
    const gitFiles = combineChanges(parsePorcelain(porcelain ?? ''), parseNumstat(numstat ?? ''));

    // Union with the tool-call rows, git first (it has real counts), and mark the
    // rows only the log knows about so the App can explain the missing counts.
    const seen = new Set(gitFiles.map((f) => path.resolve(cwd, f.path)));
    const extras = fallback.changed
      .filter((row) => !seen.has(path.resolve(cwd, row.display || row.path)))
      .map((row) => ({
        path: row.display || row.path,
        status: 'M',
        origPath: null,
        added: null,
        deleted: null,
        binary: false,
        fromToolCall: true,
        tool: row.tool,
        seq: row.seq
      }));

    return {
      available: true,
      source: extras.length ? 'git+tool-calls' : 'git',
      cwd,
      files: [...gitFiles, ...extras],
      readFiles: fallback.read.slice(0, 40).map((row) => ({ display: row.display, tool: row.tool, seq: row.seq }))
    };
  }

  /** Honest one-liner for the phone when git has nothing and repos are nearby. */
  function repositionNote(toolCallCount, repoCount) {
    if (repoCount > 0) {
      return `当前工作区不是 git 仓库，但相邻有 ${repoCount} 个仓库；下方文件列表来自本轮 Agent 的文件写入记录`;
    }
    if (toolCallCount > 0) {
      return '当前工作区不是 git 仓库；下方文件列表来自本轮 Agent 的文件写入记录（不含行数）';
    }
    return '当前工作区不是 git 仓库，且本会话没有文件写入记录';
  }

  /**
   * 交付物/文件下载的字节输出见 `./send-file.mjs`。
   *
   * 这里**故意不再**内联实现：它曾作为工厂内的局部函数把 `res` 当自由变量用，
   * 于是每次调用都抛 `ReferenceError: res is not defined`，下载路由对**所有**
   * 交付物返回 500 —— 这就是用户看到的"点不开 / 下载不成功"。抽成模块后单测
   * 能 import 真实实现、用假 `res` 驱动它；在此之前测试只注入两参数假桩，
   * 与真实函数毫无相似之处，所以路由测试全绿而生产必崩。
   */

  /**
   * Resolve one requested path against a session's declared deliverables.
   *
   * [feat 2026-10-13] Extracted for the text-preview route. Membership is an
   * exact match against the same listing the download route already enforces, so
   * preview inherits the identical guarantee: a phone cannot turn either route
   * into an arbitrary file read. Returns the absolute path plus the display
   * label, or null.
   */
  async function resolveDeliverableFile(sessionId, requested) {
    if (typeof requested !== 'string' || !requested.trim()) return null;
    const { records, cwd } = await readSessionRecords(sessionId);
    const row = resolveDeliverable(extractDeliverables(records, cwd), requested);
    if (!row) return null;
    return { path: row.path, display: row.display };
  }

  /**
   * Open a stream Remote on the MUX, take its first `take` items, then cancel.
   *
   * ⚠️ [fix 2026-10-13] The original note here named `job/list`, a remote the
   * engine does not have — which is how the jobs route shipped permanently
   * empty. The live caller is `session/control`, whose first frame is the
   * whole-state baseline (`baseline.jobs[sessionId]`), so `take: 1` is the
   * complete answer for a job list. The stream is cancelled immediately
   * afterwards: leaving one open per phone request would leak a subscription.
   */
  function readStreamOnce(endpoint, args, { take = 1, timeoutMs = 5000 } = {}) {
    return new Promise((resolve) => {
      if (!upstreamMuxWs || upstreamMuxWs.readyState !== WebSocket.OPEN) {
        resolve(null);
        return;
      }
      const streamId = `oneshot-${endpoint.replace(/\W+/g, '-')}-${crypto.randomUUID().slice(0, 8)}`;
      const items = [];
      let settled = false;

      const finish = (value) => {
        if (settled) return;
        settled = true;
        pendingOneshot.delete(streamId);
        clearTimeout(timer);
        try {
          upstreamMuxWs?.send(JSON.stringify({ type: 'cancel', streamId }));
        } catch (_) {}
        resolve(value);
      };

      const timer = setTimeout(() => finish(items.length ? items[items.length - 1] : null), timeoutMs);
      pendingOneshot.set(streamId, {
        push(value) {
          items.push(value);
          if (items.length >= take) finish(items[items.length - 1]);
        },
        fail() { finish(null); }
      });

      try {
        upstreamMuxWs.send(JSON.stringify({
          type: 'open',
          streamId,
          endpoint,
          payload: { args }
        }));
      } catch (_) {
        finish(null);
      }
    });
  }

  /** One-shot stream bookkeeping, keyed by streamId. */
  const pendingOneshot = new Map();

  /**
   * Collect several frames from one stream Remote, then cancel. [feat 2026-10-13]
   *
   * `readStreamOnce` is enough for whole-set streams (its first frame is the
   * truth), but `job/follow` is a *sequence*: an `opened` anchor, coalesced
   * `output` batches, then exactly one terminal `status` — and that ordering is
   * the engine's guarantee that settlement can never race a still-open output
   * channel. Taking only the first frame would therefore show an empty log, and
   * waiting for the stream to close would hang on a live job.
   *
   * Resolution rules, in priority order:
   *   - a frame whose `type` is in `stopOn` (the terminal frame) → resolve now;
   *   - `maxFrames` reached → resolve with what we have;
   *   - no frame for `idleTimeoutMs` (the producer went quiet) → resolve;
   *   - `totalTimeoutMs` elapsed → resolve.
   *
   * The idle timer is the important one: it makes a still-running job return its
   * output so far instead of blocking the phone's HTTP request until the job
   * ends, which could be hours.
   *
   * @returns the frames collected so far as an array (empty on any failure).
   */
  function readStreamFrames(endpoint, args, {
    maxFrames = 60,
    idleTimeoutMs = 2500,
    totalTimeoutMs = 12000,
    stopOn = ['status']
  } = {}) {
    return new Promise((resolve) => {
      if (!upstreamMuxWs || upstreamMuxWs.readyState !== WebSocket.OPEN) {
        resolve([]);
        return;
      }
      const streamId = `collect-${endpoint.replace(/\W+/g, '-')}-${crypto.randomUUID().slice(0, 8)}`;
      const items = [];
      let settled = false;
      let idleTimer = null;

      const finish = () => {
        if (settled) return;
        settled = true;
        pendingOneshot.delete(streamId);
        if (idleTimer) clearTimeout(idleTimer);
        clearTimeout(totalTimer);
        try {
          upstreamMuxWs?.send(JSON.stringify({ type: 'cancel', streamId }));
        } catch (_) {}
        resolve(items);
      };

      const totalTimer = setTimeout(finish, Math.max(500, totalTimeoutMs));
      const armIdle = () => {
        if (idleTimer) clearTimeout(idleTimer);
        idleTimer = setTimeout(finish, Math.max(200, idleTimeoutMs));
      };
      armIdle();

      pendingOneshot.set(streamId, {
        push(value) {
          // Defensive guard: `push` can still fire once after `finish` from a
          // frame already in flight. Without this the array would grow past the
          // cap the caller asked for.
          if (settled) return;
          items.push(value);
          if (value && typeof value === 'object' && stopOn.includes(value.type)) {
            finish();
            return;
          }
          if (items.length >= maxFrames) {
            finish();
            return;
          }
          armIdle();
        },
        fail() { finish(); }
      });

      try {
        upstreamMuxWs.send(JSON.stringify({
          type: 'open',
          streamId,
          endpoint,
          payload: { args }
        }));
      } catch (_) {
        finish();
      }
    });
  }

  /**
   * Deep link the App registers for, used as the ntfy click target.
   *
   * Tapping an ntfy notification must land on the right conversation — the
   * whole point of a push for a remote operator. The App declares
   * `dshmobile://open` and resolves `session` + `kind` into a session open.
   */
  function deepLinkUrl(kind, sessionId) {
    const sid = String(sessionId || '').trim();
    if (!sid) return '';
    return `dshmobile://open?kind=${encodeURIComponent(kind)}&session=${encodeURIComponent(sid)}`;
  }

  /**
   * Real ntfy transport: one bounded POST, no retries.
   *
   * Injected into `deliverNtfy` so the delivery decision (dedupe, audit) stays
   * testable without a network. Resolves `{ ok, status, reason }` and never
   * rejects — a push must not fail the approval or turn it reports on.
   */
  function sendNtfyOverHttp(request) {
    return new Promise((resolve) => {
      let settled = false;
      const done = (value) => { if (!settled) { settled = true; resolve(value); } };
      try {
        const target = new globalThis.URL(request.url);
        const transport = target.protocol === 'https:' ? https : http;
        const body = JSON.stringify(request.body);
        const req = transport.request({
          hostname: target.hostname,
          port: target.port || (target.protocol === 'https:' ? 443 : 80),
          path: `${target.pathname}${target.search}`,
          method: 'POST',
          headers: { ...request.headers, 'Content-Length': Buffer.byteLength(body) },
          timeout: 5000
        }, (res) => {
          res.resume();
          const status = res.statusCode ?? 0;
          done(status >= 200 && status < 300
            ? { ok: true, status }
            : { ok: false, status, reason: `ntfy 返回 HTTP ${status}` });
        });
        req.on('error', (err) => done({ ok: false, status: null, reason: err?.message || 'request-error' }));
        req.on('timeout', () => {
          try { req.destroy(); } catch (_) {}
          done({ ok: false, status: null, reason: 'timeout' });
        });
        req.end(body);
      } catch (err) {
        done({ ok: false, status: null, reason: err?.message || 'request-error' });
      }
    });
  }

  /**
   * ntfy fallback for one event. Fire-and-forget: the caller must not be delayed
   * or failed by a push.
   *
   * ⚠️ Deliberately NOT unconditional. The same approval/question/turn-end is
   * also broadcast to every mobile socket, and a live App raises its own local
   * notification for it — pushing as well gave the user two notifications for
   * one event. `deliverNtfy` only sends when no socket can actually receive
   * (see `countDeliverableClients`), and records WHY in the audit ring either
   * way so "I got no push" is diagnosable.
   */
  function pushNtfy(kind, detail = {}) {
    void deliverNtfy({
      kind,
      detail,
      config: (() => { try { return loadConfig(); } catch { return {}; } })(),
      clients: connectedClients,
      send: sendNtfyOverHttp,
      audit,
      logger
    }).catch((err) => logger.warn('[dsh-mobile-bridge] ntfy 推送异常: %s', err?.message || err));
  }

  /* ------------------------------------------------------------------ *
   * [v1.35 / 3.3] 告警引擎
   *
   * critical 走 ntfy（只有它值得把人吵醒），warning 只进收件箱。
   * 去重与容量都在 alerts.mjs 里，这里只提供落盘路径与推送出口。
   * ------------------------------------------------------------------ */

  const alertEngine = createAlertEngine({
    stateFile: path.join(dshHomeDir, 'mobile-access', 'alerts-state.json'),
    push: (alert) => pushNtfy('alert', {
      title: alert.title,
      summary: alert.message,
      sessionId: alert.sessionId
    }),
    logger
  });

  /**
   * Send a test push; returns whether ntfy accepted it.
   *
   * Deliberately bypasses the app-connected dedupe: the user pressed the button
   * and needs to see whether the channel works end to end, including while the
   * App is in the foreground. It still goes through the same transport and the
   * same redacted audit entry, so a failed test is diagnosable.
   */
  async function pushTest() {
    let cfg = {};
    try { cfg = loadConfig(); } catch { /* reported below */ }
    if (cfg.ntfyEnabled !== true) {
      audit('ntfy/test', { outcome: 'skipped', reason: 'disabled', ...describeNtfyTarget(cfg) });
      return false;
    }
    const request = buildNtfyRequest(cfg, {
      title: 'DSH 推送测试',
      body: '配置已生效：审批/提问/任务完成会推到这里',
      priority: 3,
      tags: ['bell']
    });
    if (!request) {
      audit('ntfy/test', { outcome: 'skipped', reason: 'unconfigured', ...describeNtfyTarget(cfg) });
      return false;
    }
    const res = await sendNtfyOverHttp(request);
    audit('ntfy/test', {
      outcome: res.ok ? 'sent' : 'failed',
      status: typeof res.status === 'number' ? res.status : null,
      reason: res.ok ? '' : redactNtfyDetail(res.reason || 'rejected', cfg),
      ...describeNtfyTarget(cfg)
    });
    return res.ok === true;
  }


  /**
   * 单次上传的字节上限。
   *
   * 为什么是 32MB：JSON 控制指令那条路的上限是 2MB，但附件不是控制指令 ——
   * 手机拍的照片、导出的 PDF/日志都可能到十几 MB。给一个宽但不失控的上限，
   * 并且**超限时立刻断开连接**而不是等收完再拒绝（否则白白浪费一次几 MB 的上行）。
   */
  const MAX_UPLOAD_BYTES = 32 * 1024 * 1024;

  /**
   * 把原始字节转发到引擎的文件上传路由。
   *
   * 引擎侧有这条 HTTP 路由（不是 RPC）：
   *   POST /api/session/uploadFileBinary?sessionId=&name=
   *   Content-Type: application/octet-stream
   *   → { ok: true, value: { receiptId, file } }
   *
   * 拿到的 receiptId 之后要放进 prompt 的 content 里（`{type:'file',receiptId}`），
   * 这样引擎才会把它当成这次提问的附件。
   */
  function uploadFileToEngine({ sessionId, name, data }) {
    return new Promise((resolve, reject) => {
      const authority = `127.0.0.1:${dshPort}`;
      const cookie = cookieFactory.current();
      const qs = new URLSearchParams();
      qs.set('sessionId', sessionId);
      if (name) qs.set('name', name);

      const req = http.request({
        host: '127.0.0.1',
        port: dshPort,
        path: `/api/session/uploadFileBinary?${qs.toString()}`,
        method: 'POST',
        headers: {
          Host: authority,
          Cookie: cookie,
          'Content-Type': 'application/octet-stream',
          'Content-Length': data.length
        },
        // 上传比普通 RPC 慢得多，给足时间，别用 10s 的默认值。
        timeout: 120000
      }, (res) => {
        let body = '';
        res.on('data', (c) => { body += c; });
        res.on('end', () => {
          let parsed;
          try {
            parsed = JSON.parse(body);
          } catch {
            reject(new Error(`引擎上传响应无法解析 (HTTP ${res.statusCode}): ${body.slice(0, 120)}`));
            return;
          }
          if (parsed?.ok === true && parsed.value) {
            resolve(parsed.value);
          } else {
            // 把引擎的业务错误原样带出去，不要吞成一句"上传失败" ——
            // 例如 FILE_TOO_LARGE / UNSUPPORTED_MEDIA_TYPE 都是用户能自己纠正的。
            const err = parsed?.error || {};
            reject(new Error(err.message || `上传被拒绝 (HTTP ${res.statusCode})`));
          }
        });
      });

      req.on('error', reject);
      req.on('timeout', () => {
        req.destroy();
        reject(new Error('上传到引擎超时'));
      });
      req.write(data);
      req.end();
    });
  }

  const activePrompts = new Map();
  const sessionTurnSeqs = new Map();
  const cancelledTurnSeqs = new Map();
  const lastCancelTimes = new Map();

  /** Upload rate buckets: device id / ip → { windowStart, count }. */
  const uploadBuckets = new Map();

  /** 每会话最近一次"丢弃过期 lastTurn"的审计时间（节流，见 getSessionHistory）。 */
  const staleTurnAuditAt = new Map();
  // [fix 2026-10-14] 历史转换中被启发式过滤/空内容丢弃的消息的审计节流表
  //（key: sessionId|why）。手机每 2.5s 轮询一次，不节流会刷爆审计缓冲。
  const droppedUserAuditAt = new Map();

  const sessionFollowers = new Map();
  const pendingApprovals = new Map();
  let approvalCounter = 1;

  /* -------------------------------------------------------------- *
   * user-questions pending requests (0003).
   *
   * `user-questions/request` arrives as a waterfall value on the $events
   * stream. The answer does NOT travel back as a returned value or a
   * `next()` call: neither can survive the JSON hop, so the gateway
   * answers over `$events/result` with the same
   * `{kind:'result', value}` shape the auto-approve path uses.
   *
   * This map is therefore bookkeeping for the PHONE's benefit only — it
   * drives the replay a late-connecting client receives and decides when
   * a prompt stops being offered. The engine owns the actual pending
   * request and resolves it by event id.
   *
   * Each entry records which subscribers it was offered to. With more than
   * one phone paired, one phone disconnecting must NOT clear prompts that
   * are still on screen on the other phone — the old code relinquished
   * every pending question on any subscriber's close.
   * -------------------------------------------------------------- */
  const pendingQuestions = new Map();

  /** Clients that want question frames. A phone with no open session still may. */
  const questionSubscribers = new Set();

  /**
   * How long a question is offered to the phones before the gateway stops
   * tracking it.
   *
   * This is NOT a promise deadline — the answer is delivered to the engine over
   * `$events/result`, exactly like an approval, so there is no local promise to
   * time out. The only thing a stale entry does is show up in the replay a
   * late-connecting phone receives. Expiring it keeps that replay honest.
   *
   * Generous on purpose: a human reading a plan-review prompt deserves minutes.
   */
  const QUESTION_TTL_MS = 30 * 60 * 1000;

  /* -------------------------------------------------------------- *
   * Shared core wiring (see lib/core.mjs).
   *
   * The registries above stay as the live objects this entry has always used;
   * core's helpers wrap the same Maps so the logic itself lives in one place.
   * -------------------------------------------------------------- */
  const coreTurns = createTurnRegistry({
    sessionTurnSeqs,
    cancelledTurnSeqs,
    lastCancelTimes,
    activePrompts
  });
  const coreApprovals = createApprovalQueue({ pendingApprovals });
  const coreFollowers = createFollowerRegistry({
    sessionFollowers,
    // Stream opens are issued by followSession / connectUpstreamMux below.
    onSubscribe: null
  });
  /** Agent personas were only served by the standalone gateway. [unified] */
  const personaStore = createPersonaStore({ home: dshHomeDir });
  /** Prompt snippets (quick replies), persisted beside personas. */
  const snippetStore = createSnippetStore({ home: dshHomeDir });
  /** Single permission store; persists to ~/.dsh/mobile-access/permissions.json. */
  const permStore = createPermissionStore();
  const connectedClients = new Set();
  let currentEventsClientId = null;

  const globalPermissions = permStore.global;
  const sessionPermissions = permStore.sessions;

  function getPermissionsPayload() {
    return permStore.payload();
  }

  function persistAndBroadcastPermissions() {
    const payload = permStore.persist();
    broadcastToMobileClients({
      type: 'permission_updated',
      permissions: payload
    });
    return payload;
  }

  /**
   * Ensure a live stream is open for this session.
   * Buffer creation and the open-frame payload live in core; whether the
   * upstream link is actually connected is decided here.
   */
  function followSession(sId) {
    if (!sId) return;
    const fullId = sId.startsWith('session-') ? sId : `session-${sId}`;
    const follower = coreFollowers.ensure(fullId);
    if (follower.subscribed) return;

    if (upstreamMuxWs && upstreamMuxWs.readyState === WebSocket.OPEN) {
      coreFollowers.follow(fullId, (open) => {
        upstreamMuxWs.send(JSON.stringify(open));
      });
    }
  }

  function getSessionPermission(sessionId) {
    return permStore.forSession(sessionId);
  }

  function setSessionPermission(sessionId, policy) {
    if (sessionId) {
      permStore.setSession(sessionId, policy);
      audit('permission/session', { sessionId, policy });
      persistAndBroadcastPermissions();
    }
  }

  function getSessionFollower(sessionId) {
    return coreFollowers.get(sessionId);
  }

  function getSettingsData() {
    let availableModels = [];
    let currentModel = 'cn:auto';

    // 1. 尝试从 profiles/web/cordis.patch.yml 读取全部配置的大模型
    const patchPath = path.join(dshHomeDir, 'profiles', 'web', 'cordis.patch.yml');
    if (fs.existsSync(patchPath)) {
      try {
        const patchContent = fs.readFileSync(patchPath, 'utf8');
        const patchDoc = YAML.parse(patchContent);
        const seen = new Set();
        for (const entry of (Array.isArray(patchDoc) ? patchDoc : [])) {
          if (entry && (entry.id === 'llm-pi-ai' || entry.name === '@deepseek-ai/dsh-llm-pi-ai')) {
            const providers = entry.config?.providers || {};
            for (const [pKey, pVal] of Object.entries(providers)) {
              if (Array.isArray(pVal?.models)) {
                for (const m of pVal.models) {
                  const mId = m.id || m.name;
                  if (mId && !seen.has(mId)) {
                    seen.add(mId);
                    availableModels.push({
                      id: mId,
                      name: m.name || mId,
                      contextWindow: m.contextWindow || 256000,
                      maxTokens: m.maxTokens || 32000
                    });
                  }
                }
              }
            }
          }
          if (entry && (entry.id === 'agent-default-model' || entry.name === '@deepseek-ai/dsh-agent-default-model')) {
            if (entry.config?.model) {
              currentModel = entry.config.model;
            }
          }
        }
      } catch (err) {
        logger.error('[Settings] Error parsing cordis.patch.yml:', err);
      }
    }

    // 2. 检查 settings.yaml 覆盖
    const settingsYamlPath = path.join(dshHomeDir, 'settings.yaml');
    if (fs.existsSync(settingsYamlPath)) {
      try {
        const content = fs.readFileSync(settingsYamlPath, 'utf8');
        const doc = YAML.parse(content) || {};
        if (doc['agent-default-model'] && doc['agent-default-model'].model) {
          currentModel = doc['agent-default-model'].model;
        }
        if (doc['llm-pi-ai'] && doc['llm-pi-ai'].providers && doc['llm-pi-ai'].providers.wb) {
          const wb = doc['llm-pi-ai'].providers.wb;
          if (Array.isArray(wb.models) && wb.models.length > 0) {
            for (const m of wb.models) {
              const mId = m.id || m.name;
              if (mId && !availableModels.some(x => x.id === mId)) {
                availableModels.push({
                  id: mId,
                  name: m.name || mId,
                  contextWindow: m.contextWindow || 256000,
                  maxTokens: m.maxTokens || 32000
                });
              }
            }
          }
        }
      } catch (err) {
        logger.error('[Settings] Error parsing settings.yaml:', err);
      }
    }

    if (availableModels.length === 0) {
      availableModels = [
        { id: 'cn:auto', name: 'cn:auto', contextWindow: 256000, maxTokens: 32000 },
        { id: 'cn:deepseek-v4.1-flash', name: 'cn:deepseek-v4.1-flash', contextWindow: 1000000, maxTokens: 393216 },
        { id: 'cn:deepseek-v4-pro', name: 'cn:deepseek-v4-pro', contextWindow: 1000000, maxTokens: 393216 },
        { id: 'cn:kimi-k3-1', name: 'cn:kimi-k3-1', contextWindow: 1000000, maxTokens: 1048576 }
      ];
    }

    return {
      currentModel,
      availableModels,
      permissions: {
        defaultPolicy: globalPermissions.executionPolicy,
        executionPolicy: globalPermissions.executionPolicy,
        sandboxMode: globalPermissions.sandboxMode,
        maxSteps: globalPermissions.maxSteps,
        protectGit: globalPermissions.protectGit !== false
      }
    };
  }

  function updateDefaultModel(modelId) {
    // 同时更新 cordis.patch.yml 与 settings.yaml
    const patchPath = path.join(dshHomeDir, 'profiles', 'web', 'cordis.patch.yml');
    if (fs.existsSync(patchPath)) {
      try {
        const patchContent = fs.readFileSync(patchPath, 'utf8');
        const patchDoc = YAML.parseDocument(patchContent);
        if (patchDoc.contents && Array.isArray(patchDoc.contents.items)) {
          let found = false;
          for (const item of patchDoc.contents.items) {
            if (item.get && (item.get('id') === 'agent-default-model' || item.get('name') === '@deepseek-ai/dsh-agent-default-model')) {
              let config = item.get('config');
              if (!config) {
                item.set('config', { model: modelId });
              } else {
                config.set('model', modelId);
              }
              found = true;
              break;
            }
          }
          if (!found) {
            patchDoc.contents.items.push(patchDoc.createNode({
              id: 'agent-default-model',
              name: '@deepseek-ai/dsh-agent-default-model',
              config: { model: modelId }
            }));
          }
          fs.writeFileSync(patchPath, patchDoc.toString(), 'utf8');
        }
      } catch (err) {
        logger.error('[updateDefaultModel] Error updating cordis.patch.yml:', err);
      }
    }

    const settingsYamlPath = path.join(dshHomeDir, 'settings.yaml');
    try {
      let content = fs.existsSync(settingsYamlPath) ? fs.readFileSync(settingsYamlPath, 'utf8') : '';
      const doc = content ? YAML.parseDocument(content) : new YAML.Document();
      doc.setIn(['agent-default-model', 'model'], modelId);
      fs.writeFileSync(settingsYamlPath, doc.toString(), 'utf8');
    } catch (e) {
      logger.error('[updateDefaultModel] Error updating settings.yaml:', e);
    }
    audit('settings/model', { modelId });
  }

  /**
   * 模型目录（引擎的权威来源），带 60 秒缓存。
   *
   * 为什么需要它：会话级选模型要发 `{provider, model}` 给引擎，而 App 只知道
   * model id。旧实现把 provider 硬编码成 `'wb'` —— 本机上 `cn:*` 恰好属于 `wb`，
   * 所以看不出来；一旦选了别的 provider（qwen / deepseek-official / antigravity）
   * 的模型，就会写出一对不匹配的组合。目录里每个 group 的 `id` 就是 provider。
   */
  let modelCatalogCache = { at: 0, value: null };
  // 60 秒是"用户连续试几个模型"的量级；测试可把它设成 0 关掉缓存，
  // 否则同一个插件实例会把第一个用例的目录带进下一个用例。
  const MODEL_CATALOG_TTL_MS = (() => {
    const raw = Number(config?.modelCatalogTtlMs);
    return Number.isFinite(raw) && raw >= 0 ? raw : 60 * 1000;
  })();

  async function loadModelCatalog() {
    const now = Date.now();
    if (modelCatalogCache.value && now - modelCatalogCache.at < MODEL_CATALOG_TTL_MS) {
      return modelCatalogCache.value;
    }
    const catalog = await callDshRpc('session/modelCatalog', { args: {} });
    // 形状不对就不缓存 —— 宁可直接报错，也不要把一份坏数据缓存一分钟。
    if (!catalog || !Array.isArray(catalog.groups)) {
      throw new Error('引擎返回的模型目录形状异常');
    }
    modelCatalogCache = { at: now, value: catalog };
    return catalog;
  }

  /**
   * 把一个 model id 解析成引擎要求的 `{provider, model}`。
   * @returns `{ok:true, provider, model}` 或 `{ok:false, error}`。
   */
  async function resolveModelSelection(modelId) {
    let catalog;
    try {
      catalog = await loadModelCatalog();
    } catch (err) {
      return { ok: false, error: `读取模型目录失败：${err?.message || err}` };
    }
    for (const group of catalog.groups) {
      if (!Array.isArray(group?.models)) continue;
      if (group.models.some((m) => m?.id === modelId)) {
        return { ok: true, provider: group.id, model: modelId };
      }
    }
    // 目录里没有就如实失败。旧实现会照样写下去并回 200，用户以为切成功了。
    return { ok: false, error: `模型目录里找不到 ${modelId}（可能已下线或未配置）` };
  }

  /**
   * @param {object} [opts]
   * @param {'exclude'|'only'|'include'} [opts.archived='exclude']
   *   Which sessions to emit, by archived state. 'exclude' reproduces the
   *   original behaviour exactly and is what every existing caller gets —
   *   including the workspace-memory path guard above, which must keep seeing
   *   the same workspace list it always has.
   *
   * Filtering happens server-side on purpose. This box has 2322 registered
   * sessions of which 1338 are archived, so returning them unconditionally would
   * grow a payload the phone re-fetches on a timer by ~2.4x. The client asks for
   * one mode at a time instead.
   */
  function getWorkspacesData(opts = {}) {
    const mode = (opts && (opts.archived === 'only' || opts.archived === 'include'))
      ? opts.archived
      : 'exclude';

    const workspaceJsonPath = path.join(dshHomeDir, 'storages', 'workspace.json');

    if (!fs.existsSync(workspaceJsonPath)) return [];

    // getSettingsData() is a synchronous readFileSync + YAML.parse of
    // cordis.patch.yml, and it used to be called from inside the per-session loop
    // for every session with an empty model — i.e. up to once per row, re-parsing
    // the same file each time. It is a global setting that cannot vary by session,
    // so resolve it at most once per call, and only if some session needs it.
    let fallbackModel = null;
    const getFallbackModel = () => {
      if (fallbackModel === null) {
        fallbackModel = getSettingsData().currentModel || 'cn:deepseek-v4.1-flash';
      }
      return fallbackModel;
    };

    try {
      const rawWs = JSON.parse(fs.readFileSync(workspaceJsonPath, 'utf8'));
      const wsTable = rawWs.tables && rawWs.tables.workspaces ? rawWs.tables.workspaces : {};
      const archivedSessionIds = new Set(rawWs.global?.archivedSessionIds || []);
      const result = [];

      for (const [wsId, wsInfo] of Object.entries(wsTable)) {
        const sessionIds = wsInfo.sessionIds || [];
        const sessionList = [];
        // Counted in every mode, including 'exclude', so the phone can badge
        // "已归档 N 条" without issuing a second request. Cost is one Set lookup
        // per session — no extra I/O.
        let archivedCount = 0;

        for (const sId of sessionIds) {
          const cleanId = sId.startsWith('session-') ? sId.replace('session-', '') : sId;
          // 归档名单默认隐藏（与 Web 端 sessionVisible 的 !archived.has(s.id) 一致）。
          // 三种写法都要查：原样 id、去掉 session- 前缀、以及补上前缀的形式。
          const isArchived = archivedSessionIds.has(sId)
            || archivedSessionIds.has(cleanId)
            || archivedSessionIds.has(`session-${cleanId}`);
          if (isArchived) archivedCount++;
          if (isArchived && mode === 'exclude') continue;
          if (!isArchived && mode === 'only') continue;

          // [fix 2026-10-16] 候选路径覆盖主域 + 归档域，且两域都有文件时取 mtime
          // 新的那份（readFreshestProjection）。旧的"命中第一个存在的就 break"会让
          // 主域里迁移前冻结的陈旧投影永久遮蔽归档域里的鲜活投影 —— 那正是
          // "10-13 之后的活跃会话在 App 上不显示"的根因（详见函数头注释）。
          const cache = readFreshestProjection(sId);

          let sessionMeta = {
            sessionId: sId,
            title: sId,
            firstPrompt: '',
            lastPromptAt: 0,
            model: '',
            lastSeq: 0,
            // Emitted in every mode so an 'include' response stays self-describing
            // and the client can badge rows without a second lookup.
            archived: isArchived
          };
          let isBlankSession = false;
          let isSubagentSession = false;

          if (cache) {
            const rows = cache.record?.rows || {};
            // Web 端 sessionVisible: 排除 blank 会话（未输入任何 prompt 的空会话）
            if (rows.sessionListMetadata?.val?.blank === true && !rows.titleInput?.val?.first?.text) {
              isBlankSession = true;
            }
            // Web 端 sessionVisible 的**第一条**规则：origin === 'subagent'
            // 一律隐藏（见 dsh-client-ui-workspace/lib/client.js:358）。
            //
            // 判据取自 projcache 的 subagent.identity。权威的 origin 字段在引擎的
            // session header 里，而网关是直接读 workspace.json + projcache 的，
            // 读不到那个字段。已验证该信号与
            // subagentCatalog.inheritedEventCount>0 在 310 条里对齐 309 条，
            // 且不会命中普通会话（2127 条普通会话全无此字段）。
            if (rows.subagent?.val?.identity) {
              isSubagentSession = true;
            }
            sessionMeta.title = rows.title?.val || rows.titleInput?.val?.first?.text || '';
            sessionMeta.firstPrompt = rows.titleInput?.val?.first?.text || '';
            sessionMeta.lastPromptAt = rows.sessionListMetadata?.val?.lastPromptAt || cache.record?.identity?.createdAt || 0;
            sessionMeta.model = rows.modelSelection?.val?.lastUsed?.model || '';
            const follower = getSessionFollower(sId);
            // 先跟引擎的投影对账，再算 isRunning：卡死的 running 会在这里被
            // 纠正（见 reconcileFollowerWithProjection 的注释）。
            reconcileFollowerWithProjection(follower, rows);
            const isRecentlyPrompted = activePrompts.has(sId) || activePrompts.has(cleanId) || activePrompts.has(`session-${cleanId}`);
            const lastActivity = sessionMeta.lastPromptAt || 0;
            const isRecentActivity = (Date.now() - lastActivity) < 45000;
            const isOpenTurnActive = rows.turnBoundary?.val?.openTurnStartSeq != null && isRecentActivity;
            sessionMeta.isRunning = (follower && follower.isRunning) || isRecentlyPrompted || isOpenTurnActive;
          }

          // [fix 2026-10-15] 标题兜底。候选路径全 miss（会话既不在主投影域也不在
          // 归档域，例如只剩 zstd 事件日志的老会话）时，从事件日志的
          // `session/title` 事件折叠出标题。实测这覆盖 29 条，之前全部显示
          // `session-<uuid>`。
          //
          // peek 是同步的：命中记忆化结果就立刻拿到标题；否则 warm() 在后台解压，
          // 下一个 3 秒轮询就能读到。绝不在这里内联解压 3 MB 日志 —— 这个循环
          // 在 dsh web 进程里每 3 秒跑一次。
          if (!sessionMeta.title) {
            const folded = eventLogTitles.peek(dshHomeDir, sId);
            if (folded && folded.title) {
              sessionMeta.title = folded.title;
              if (!sessionMeta.firstPrompt) sessionMeta.firstPrompt = folded.firstPrompt;
            } else if (folded && folded.pending) {
              eventLogTitles.warm(dshHomeDir, sId);
            }
          }
          if (!sessionMeta.title) sessionMeta.title = '新会话';

          // subagent 会话在 Web 端等同于不存在，手机端此前却会列出来。
          // 实测：注册会话 2324 条，其中 subagent 321 条（one-shot 317 / continuable 4），
          // 且这 321 条里 0 条已归档 —— 所以只有「未归档」的数字对不上，
          // 「已归档」两边一致。这与用户观察到的现象完全吻合。
          //
          // 注意这里**不**回收 archivedCount。看起来"隐藏了就不该计数"更整齐，
          // 但那会让 archivedCount 随请求的 mode 变化：archived+subagent 的会话在
          // exclude 模式下于上面的 mode 过滤就被 continue 掉了（不会走到这里），
          // 在 only/include 模式下才会走到 —— 于是同一个徽标在三种模式里给出两个
          // 不同的数。archivedCount 的设计约束是"与请求模式无关"，宁可保留这个
          // 约束：唯一的代价是一个已归档的 subagent 会被计数但不出现在列表里，
          // 而实测这种会话在本机是 0 条。
          if (isSubagentSession) {
            continue;
          }

          // 如果是尚未开始对话的空白会话且没有正在运行，与 Web 端保持一致进行过滤
          if (isBlankSession && !sessionMeta.isRunning) {
            continue;
          }

          if (!sessionMeta.model) {
            sessionMeta.model = getFallbackModel();
          }
          const pendingForSession = coreApprovals.list().filter(a => {
            const aId = a.sessionId || '';
            return aId === sId || aId === cleanId || aId === `session-${cleanId}`;
          });
          sessionMeta.pendingApprovals = pendingForSession.length;
          sessionList.push(sessionMeta);
        }

        sessionList.sort((a, b) => (b.lastPromptAt || 0) - (a.lastPromptAt || 0));
        const wsPendingCount = sessionList.reduce((acc, s) => acc + (s.pendingApprovals || 0), 0);
        const wsHasRunning = sessionList.some(s => s.isRunning);

        result.push({
          workspaceId: wsId,
          title: wsInfo.title || path.basename(wsInfo.path || ''),
          path: wsInfo.path || '',
          createdAt: wsInfo.createdAt,
          updatedAt: wsInfo.updatedAt,
          // Number of sessions in THIS response, i.e. after the mode filter and
          // the blank-session filter. Always === sessions.length.
          sessionCount: sessionList.length,
          // Total archived sessions registered in this workspace, independent of
          // the requested mode, so the client can show "已归档 N 条" while it is
          // looking at the unarchived list.
          archivedCount: archivedCount,
          pendingApprovals: wsPendingCount,
          hasRunning: wsHasRunning,
          sessions: sessionList
        });
      }

      result.sort((a, b) => new Date(b.updatedAt || 0) - new Date(a.updatedAt || 0));
      return result;
    } catch (err) {
      logger.error('[Workspaces] Error reading workspace data:', err);
      return [];
    }
  }

  async function getSessionHistory(sessionId) {
    // [fix 2026-10-11] Path-traversal gate: a crafted id would read arbitrary
    // .json files outside projcache and return their rows content. (The write-side
    // sibling of this hole lived in updateSessionModel, removed 2026-10-16 when
    // session model selection moved to the engine's session/selectModel RPC.)
    const idCheck = assertSessionId(sessionId);
    if (!idCheck.ok) return { messages: [], isRunning: false, model: '', error: idCheck.error };
    const cleanId = sessionId.startsWith('session-') ? sessionId.replace('session-', '') : sessionId;
    // [fix 2026-10-16] 与 getWorkspacesData 同样按新鲜度选投影（含归档域的
    // sha256 文件名）。旧循环"命中即停"会让主域的陈旧件遮蔽归档域的鲜活件，
    // 历史水位（lastSeq）因此停在迁移前 —— 表现为"打开会话只有旧消息"。
    const cacheData = readFreshestProjection(sessionId);

    const messages = [];
    let isRunning = false;
    let model = '';
    const fullId = sessionId.startsWith('session-') ? sessionId : `session-${sessionId}`;
    followSession(fullId);
    const follower = getSessionFollower(sessionId) || getSessionFollower(fullId);
    const isRecentlyPrompted = activePrompts.has(sessionId) || activePrompts.has(cleanId) || activePrompts.has(`session-${cleanId}`);

    let lastSeq = 50000;
    if (cacheData && cacheData.record && cacheData.record.rows) {
      const rows = cacheData.record.rows;
      model = rows.modelSelection?.val?.lastUsed?.model || '';
      const lastActivity = rows.sessionListMetadata?.val?.lastPromptAt || cacheData.record?.identity?.createdAt || 0;
      const isRecentActivity = (Date.now() - lastActivity) < 45000;
      const isOpenTurnActive = rows.turnBoundary?.val?.openTurnStartSeq != null && isRecentActivity;
      // 先跟引擎投影对账，再算 isRunning —— 否则一个丢帧的 running 会跟着
      // 会话历史一起送到手机上，表现为"打开会话永远在转圈"。
      reconcileFollowerWithProjection(follower, rows);
      isRunning = (follower && follower.isRunning) || isRecentlyPrompted || isOpenTurnActive;
      // ⚠️ 分页上界必须是**投影水位线**（所有行 seq 的最大值），不能用
      // lastStepBoundary.seq：turn/end 永远排在最后一个 step 边界之后，用它当
      // 上界会把**最新那轮**的 turn/end 排除在外，于是 lastTurn 退回读到上一轮
      // 的结束原因 —— 手机上就表现为"一直弹出之前那条过期报错"。
      lastSeq = Math.max(
        ...Object.values(rows).map((r) => Number(r?.seq) || 0),
        Number(rows.turnBoundary?.val?.lastStepBoundary?.seq) || 0,
        Number(rows.sessionListMetadata?.val?.lastSeq) || 0,
        Number(rows.titleInput?.val?.lastSeq) || 0,
        0
      ) || 50000;
    }

    // 最近一次回合是怎么结束的。错误只存在于 turn/end.reason 里，手机后连上来
    // （或错误发生在手机不在场时）必须也能看到它，否则"报错了但手机没显示"
    // 就永远修不掉。
    let lastTurn = null;
    // 引擎认定的"最后一个**已闭合**回合"号。
    //
    // ⚠️ 回合打开时 turnBoundary.lastTurn 是**当前正在跑的那个回合号**（实测：
    // 本会话运行中 lastTurn=7，最后闭合的其实是 6）。不减这 1，就会在运行中的
    // 回合里把上一轮**真实**的失败判成"对不上"而丢弃 —— 那等于把报错横幅关掉。
    const engineLastClosedTurn = (() => {
      const tbVal = cacheData?.record?.rows?.turnBoundary?.val;
      if (!tbVal || typeof tbVal.lastTurn !== 'number') return null;
      return tbVal.openTurnStartSeq != null ? tbVal.lastTurn - 1 : tbVal.lastTurn;
    })();

    // 1. 调用 DSH 原生 RPC session/page 获取真实历史事件流
    //
    // ⚠️ [fix 2026-10-14] 分页上界必须用引擎的**权威 cursor**（past-cursor 拒绝
    // 探测，见 probeSessionCursor），不能用投影缓存的水位线。实测事故：引擎
    // 事件日志已到 seq 794，而 projcache 停在 723（自前一天的落盘后再没刷过）
    // ——用 723 当 throughSeq，最新一轮 user/message + assistant/message（seq
    // 724-794）被整轮切掉，手机上表现为"少了一问一答"，HTTP 仍 200。
    // 投影 seq 仍参与两件事：①探测失败时的保守回退；②拼 max 保证不回退。
    try {
      const targetSessionId = sessionId.startsWith('session-') ? sessionId : `session-${sessionId}`;
      const probedCursor = await probeSessionCursor({ callDshRpc, sessionId: targetSessionId });
      // 探测成功（或引擎不拒绝 MAX_SAFE_INTEGER）：用权威 cursor；拿不到时
      // 退化到旧逻辑的投影水位线（lastSeq 默认 50000——由上面的 rows 推导）。
      const throughSeq = probedCursor != null ? probedCursor : lastSeq;
      const pageResult = await callDshRpc('session/page', {
        args: {
          request: {
            address: { kind: 'session', sessionId: targetSessionId },
            throughSeq,
            maxMessages: 100
          }
        }
      });

      if (pageResult && Array.isArray(pageResult.records)) {
        // [feat 2026-10-12] The record→message conversion now lives in
        // features.mjs (convertSessionRecordsToMessages) so the new reverse
        // paging endpoint /api/mobile/sessions/history/page reuses the exact
        // same logic — including the carried-context filter and tool merging —
        // instead of a second drifting copy.
        // [fix 2026-10-14] 传入误杀审计回调（60 秒/会话/why 节流）——历史里的
        // 用户消息被内容启发式吞掉必须留痕，否则"少了一条提问"无从查起。
        messages.push(...convertSessionRecordsToMessages(pageResult.records, {
          auditDropped: (info) => {
            const key = `${sessionId}|${info.why}`;
            const lastAt = droppedUserAuditAt.get(key) || 0;
            if (Date.now() - lastAt > 60000) {
              droppedUserAuditAt.set(key, Date.now());
              audit('history/message-dropped', { sessionId, ...info });
            }
          }
        }).messages);
        // lastTurn is a tail-only concern (see stale-drop below) and stays
        // computed here from the same page.
        for (const record of pageResult.records) {
          if (record?.event?.type === 'turn/end') {
            const end = describeTurnEnd(record.event.data?.reason);
            lastTurn = {
              kind: end.kind,
              text: end.text,
              code: end.code || '',
              failed: isFailedTurnEnd(record.event.data?.reason),
              turn: typeof record.event.data?.turn === 'number' ? record.event.data.turn : null,
              time: record.event.time || Date.now()
            };
          }
        }
      }
    } catch (rpcErr) {
      logger.warn('[getSessionHistory] RPC session/page error:', rpcErr?.message || rpcErr);
    }

    // 丢弃"过期"的 turn/end：如果我们从分页里读到的那条不是引擎认定的最后一个
    // 已闭合回合，就说明它不是最新的一轮（分页边界/投影刷新的任一处滞后都会
    // 造成这种错位）。宁可这一条不报，也不能把上一轮的失败当成"本轮"反复弹给
    // 用户 —— 那正是"每次打开都弹之前那条过期信息"的直接成因。
    if (lastTurn && engineLastClosedTurn != null && lastTurn.turn != null
        && lastTurn.turn !== engineLastClosedTurn) {
      // 只对"丢掉的是一条失败"记审计，且同一会话 60 秒最多一条。
      // 无条件记会怎样：手机每 2.5 秒轮询一次会话，一次一条 —— 200 条的审计
      // 环形缓冲会在几分钟内被这种无意义的重复刷爆，把真正的排查线索挤出去
      // （实测把 10:58 的提问记录冲掉了，那次排查因此丢了现场）。
      if (lastTurn.failed) {
        const lastAudit = staleTurnAuditAt.get(sessionId) || 0;
        if (Date.now() - lastAudit > 60000) {
          staleTurnAuditAt.set(sessionId, Date.now());
          audit('session/last-turn-stale-dropped', {
            sessionId,
            readTurn: lastTurn.turn,
            engineLastClosedTurn,
            kind: lastTurn.kind
          });
        }
      }
      lastTurn = null;
    }

    // 2. 兜底解析：若 RPC 无结果但存在 titleInput，填充首轮用户输入
    if (messages.length === 0 && cacheData?.record?.rows) {
      const rows = cacheData.record.rows;
      if (rows.titleInput?.val?.first?.text) {
        messages.push({
          id: crypto.randomUUID(),
          role: 'user',
          content: rows.titleInput.val.first.text,
          time: cacheData.record.identity?.createdAt || Date.now()
        });
      }
    }

    // 3. In-flight turn & pending stream chunks reconciliation (F3.3)
    if (follower && follower.isRunning && (follower.textBuffer || follower.thinkingBuffer || follower.activePromptText)) {
      isRunning = true;

      // Ensure active user prompt is included if not yet present in messages
      if (follower.activePromptText && (messages.length === 0 || messages[messages.length - 1].role !== 'user' || messages[messages.length - 1].content !== follower.activePromptText)) {
        messages.push({
          id: `user_prompt_${cleanId}_${Date.now()}`,
          role: 'user',
          content: follower.activePromptText,
          time: Date.now() - 1000,
          seq: 999998,
          turn: 999998
        });
      }

      if (messages.length === 0 || messages[messages.length - 1].role === 'user') {
        messages.push({
          id: `in_flight_${cleanId}_${Date.now()}`,
          role: 'assistant',
          content: follower.textBuffer || '',
          thinking: follower.thinkingBuffer || null,
          tools: follower.tools || [],
          time: Date.now(),
          seq: 999999,
          turn: 999999,
          isStreaming: follower.isRunning
        });
      } else if (messages[messages.length - 1].role === 'assistant') {
        const lastMsg = messages[messages.length - 1];
        if (follower.textBuffer && follower.textBuffer.length > (lastMsg.content?.length || 0)) {
          lastMsg.content = follower.textBuffer;
        }
        if (follower.thinkingBuffer && !lastMsg.thinking) {
          lastMsg.thinking = follower.thinkingBuffer;
        }
        if (follower.tools && follower.tools.length > 0) {
          lastMsg.tools = follower.tools;
        }
        lastMsg.isStreaming = follower.isRunning;
      }
    }

    if (!model) model = getSettingsData().currentModel || 'cn:deepseek-v4.1-flash';

    return {
      sessionId,
      isRunning,
      model,
      // 最近一次回合的结束原因（含失败文本）。手机据此显示"上一轮以错误结束"。
      lastTurn,
      messages
    };
  }

    function broadcastToMobileClients(msg) {
    const raw = typeof msg === 'string' ? msg : JSON.stringify(msg);
    // Session-scoped frames only go to sockets that followed that session.
    // Every socket used to receive every session's deltas and tool frames and
    // discarded them client-side — wasted radio for the phone, wasted writes
    // for the gateway. Broad frames (session_status with no id, todo/permission
    // broadcasts, question frames to subscribers) pass through untouched.
    const scopeId = msg && typeof msg === 'object' ? (msg.sessionId || null) : null;
    for (const ws of connectedClients) {
      if (ws.readyState === WebSocket.OPEN) {
        if (scopeId && ws.sessionId &&
            !sessionIdMatchesSafe(ws.sessionId, scopeId)) {
          continue; // this phone is following a different session
        }
        // [P1] Backpressure. A socket that cannot keep up used to accumulate in
        // the send buffer forever, because there is no other writer on this
        // connection: the mobile socket carries deltas, tool results and now
        // question frames. A phone that loses signal — or is simply slower than
        // a fast assistant stream — would grow the gateway's heap until the whole
        // dsh web process dies. Dropping one slow client is strictly better than
        // killing every session on the box. 8 MB is far above any healthy burst:
        // a normal stream drains at network speed long before this.
        const buffered = typeof ws.bufferedAmount === 'number' ? ws.bufferedAmount : 0;
        if (shouldDivertForBackpressure(buffered)) {
          logger.warn('dsh-mobile-bridge: 客户端发送缓冲积压 %d B，断开以保护网关', buffered);
          try { ws.close(1013, 'backpressure'); } catch (_) {}
          connectedClients.delete(ws);
          questionSubscribers.delete(ws);
          continue;
        }
        try { ws.send(raw); } catch (_) {}
      }
    }
  }

  /** Case-insensitive session comparison without importing per call. */
  function sessionIdMatchesSafe(a, b) {
    const na = String(a).replace(/^session-/, '').toLowerCase();
    const nb = String(b).replace(/^session-/, '').toLowerCase();
    return na === nb;
  }

  /**
   * Emit a frame only to the clients that asked for it.
   *
   * Unlike broadcastToMobileClients, this never grows the fan-out for clients
   * that did not opt in. Used for question frames so a second phone that is
   * merely browsing the session list is not handed interactive prompts it will
   * never answer — those requests would otherwise sit blocked until they time
   * out on the engine side.
   */
  function sendToSubscribers(msg, subs) {
    const raw = typeof msg === 'string' ? msg : JSON.stringify(msg);
    for (const ws of subs) {
      if (ws.readyState !== WebSocket.OPEN) {
        subs.delete(ws);
        continue;
      }
      const buffered = typeof ws.bufferedAmount === 'number' ? ws.bufferedAmount : 0;
      if (shouldDivertForBackpressure(buffered)) {
        try { ws.close(1013, 'backpressure'); } catch (_) {}
        connectedClients.delete(ws);
        subs.delete(ws);
        continue;
      }
      try { ws.send(raw); } catch (_) {}
    }
  }

  /**
   * Deliver a phone's answer to the engine.
   *
   * The answer travels over `$events/result` with `outcome.kind === 'result'`,
   * which is the same mechanism the auto-approve path uses and the only one the
   * engine accepts for a remote client. It deliberately does NOT use a local
   * Promise: a `next` continuation cannot survive the JSON hop, so any
   * promise-based design here would look correct in a unit test and hang in
   * production.
   */
  async function handleQuestionAnswer(eventId, answer) {
    const pending = pendingQuestions.get(eventId);
    if (!pending) return { ok: false, error: 'unknown-question' };
    // Delete only AFTER a successful RPC below — an rpc-failed keeps the
    // entry so the phone (or another subscriber) can retry.
    const value = { answers: Array.isArray(answer?.answers) ? answer.answers : [] };
    try {
      // ⚠️ payload **只能有 `args` 这一个字段**，别把 clientId/eventId/outcome
      // 再平铺一份到外层。
      //
      // 这是「手机上点了选项没反应」的真凶（审批回传同一处，见 handleApprovalRespond）。
      // 引擎侧是这样校验的（dsh-api-gateway 的 parseRemoteEventResultPayload）：
      //
      //     if (!isPlainObject(payload)
      //         || Reflect.ownKeys(payload).length !== 1      // ← 恰好 1 个 key
      //         || !Object.hasOwn(payload, 'args')) {
      //       throw new Error('... requires exactly one plain-object args field');
      //     }
      //     return parseRemoteEventResult(payload.args);     // args 内再要 exactKeys
      //
      // 而 args 内部必须恰好是 clientId / eventId / outcome 三个键，value 是
      // lossless JSON。之前多带的那三个平铺字段会让整个形状被拒，报错被 catch
      // 吞成一句 'rpc-failed' —— 手机端只看到"点了没反应"。
      await callDshRpc('$events/result', {
        args: {
          clientId: currentEventsClientId,
          eventId,
          outcome: { kind: 'result', value }
        }
      });
    } catch (err) {
      audit('question/answer-failed', { eventId, sessionId: pending.sessionId, error: err?.message });
      // rpc-failed ≠ the question is gone. The engine still holds the request
      // open, so KEEP the entry: the phone can retry. (The client must not
      // remove its card on this error either — see its question_ack handler.)
      return { ok: false, error: 'rpc-failed', retryable: true };
    }

    sendToSubscribers({ type: 'question_settled', eventId, ok: true }, questionSubscribers);
    pendingQuestions.delete(eventId);
    audit('question/answered', { eventId, sessionId: pending.sessionId, count: value.answers.length });
    return { ok: true, eventId };
  }

  /**
   * Stop offering a question without answering it.
   *
   * Crucially this does NOT send an empty answer. Sending `{answers: []}` would
   * tell the agent the human replied with nothing — a different and false
   * statement. Leaving the request unanswered is what lets the engine's
   * waterfall fall through to the Web UI answerer, which is the honest outcome
   * when nobody claims it.
   *
   * Called on: engine cancel, upstream link loss, TTL expiry. Deliberately NOT
   * called when a subscriber simply disconnects — phones drop their socket all
   * the time (lock screen, backgrounding, Wi-Fi↔LTE), and the agent is blocked
   * waiting on a human exactly then. See the ws close handler.
   */
  function relinquishQuestion(eventId, why) {
    const pending = pendingQuestions.get(eventId);
    if (!pending) return false;
    pendingQuestions.delete(eventId);
    audit('question/relinquished', { eventId, sessionId: pending.sessionId, why });
    return true;
  }

  /** Questions still worth offering, newest last. Expired ones are pruned. */
  function livePendingQuestions() {
    const now = Date.now();
    const out = [];
    for (const q of pendingQuestions.values()) {
      if (now - q.createdAt > QUESTION_TTL_MS) {
        pendingQuestions.delete(q.eventId);
        continue;
      }
      out.push({ eventId: q.eventId, sessionId: q.sessionId, questions: q.questions });
    }
    return out;
  }

  /**
   * Forward the session-scoped events the phone now renders. Returns true when
   * the event was consumed.
   *
   * Both of these ride the SESSION log (`agent.session.append('todo/write')`),
   * so depending on how the engine multiplexes they can arrive on the per-session
   * follow stream OR the shared $events stream. Handling them in one helper
   * called from both is the only way neither path can silently drop them — the
   * follow-stream branch ends in a bare `return`, so a `todo/write` that lands
   * there would otherwise vanish with no error anywhere.
   */
  function forwardSessionEvent(val, fallbackSessionId) {
    if (val.type !== 'event' || !val.event) return false;
    const data = val.data || val.payload || {};
    const sessionId = val.agent || val.agentId || val.sessionId || data.sessionId || fallbackSessionId || 'default';

    if (val.event === 'todo/write') {
      // Whole-list replacement, not a delta. An empty array is meaningful (the
      // list was cleared) and is broadcast; a frame with no `todos` at all is
      // not, because there is nothing to say.
      if (!Array.isArray(data.todos)) return true;
      broadcastToMobileClients({ type: 'todo_list', sessionId, todos: data.todos });
      audit('todo/broadcast', { sessionId, count: data.todos.length });
      return true;
    }

    if (val.event === 'session/attachment') {
      // Metadata only. The bytes stay on the host; the phone fetches them via the
      // authenticated attachment route, so a large inline blob never crosses the
      // MUX hop.
      const attachment = data.attachment || data;
      if (!attachment || typeof attachment !== 'object') return true;
      broadcastToMobileClients({ type: 'attachment', sessionId, attachment });
      return true;
    }

    if (val.event === 'deliverables/presented') {
      // The phone shows a "交付物" row; the bytes are fetched on demand through
      // the authenticated download route (see features.mjs), never inline.
      const files = Array.isArray(data.files) ? data.files : [];
      if (!files.length) return true;
      broadcastToMobileClients({
        type: 'deliverables',
        sessionId,
        files: files.map((f) => ({
          path: typeof f?.path === 'string' ? f.path : '',
          description: typeof f?.description === 'string' ? f.description : ''
        })).filter((f) => f.path)
      });
      audit('deliverables/presented', { sessionId, count: files.length });
      return true;
    }

    if (val.event === 'workspace/changes') {
      // Signal only: the turn number is all the engine puts in the log, so the
      // phone refreshes its change list (git-backed) instead of expecting a
      // payload that does not exist.
      broadcastToMobileClients({ type: 'workspace_changes', sessionId, turn: data.turn ?? null });
      return true;
    }

    return false;
  }

  let upstreamMuxWs = null;
  let muxReconnectTimer = null;

  /**
   * Reconcile our stream state against the engine's own projection.
   *
   * `follower.isRunning` is our belief, derived from frames we happened to see.
   * Frames can be lost (the mux drops, dsh web restarts mid-turn, the phone's
   * socket dies and a tail frame never arrives), and a wrong `true` makes the
   * session spin forever on the phone with no way to recover short of a
   * restart. The projcache is the engine's authoritative view, and each row
   * carries the `seq` it was folded up to — so the rule below is not a timeout
   * guess: it only fires when the projection has provably advanced to (or past)
   * the newest event we saw AND still reports no open turn and no open step.
   *
   * Returns true when it just healed a stale running state.
   */
  function reconcileFollowerWithProjection(follower, rows) {
    if (!follower || !follower.isRunning) return false;
    const tb = rows?.turnBoundary?.val;
    const stats = rows?.sessionStats?.val;
    // No projection data (file missing / not yet flushed) — cannot judge.
    if (!tb || typeof tb !== 'object') return false;
    const projSeq = Math.max(
      Number(rows?.turnBoundary?.seq) || 0,
      Number(rows?.sessionStats?.seq) || 0
    );
    // Cannot prove the projection saw our last event → keep believing the stream.
    if (projSeq <= 0 || projSeq < (follower.lastSeq || 0)) return false;
    const engineOpenTurn = tb.openTurnStartSeq != null;
    const engineOpenStep = stats ? stats.openStep != null : false;
    if (engineOpenTurn || engineOpenStep) return false; // engine agrees it is running
    // Engine says nothing is open, and it has folded our last event → we are stale.
    follower.isRunning = false;
    follower.turnOpen = false;
    follower.activePromptText = null;
    if (follower.sessionId) {
      const clean = follower.sessionId.replace(/^session-/, '');
      activePrompts.delete(follower.sessionId);
      activePrompts.delete(clean);
      activePrompts.delete(`session-${clean}`);
    }
    audit('session/stale-running-healed', {
      sessionId: follower.sessionId,
      projectionSeq: projSeq,
      ourLastSeq: follower.lastSeq || 0
    });
    return true;
  }

  function connectUpstreamMux() {
    if (isDisposed) return;
    if (upstreamMuxWs) {
      // Detach listeners and keep an error sink so a close that races an
      // in-flight handshake cannot surface as an uncaught exception.
      try { upstreamMuxWs.removeAllListeners(); } catch (_) {}
      try { upstreamMuxWs.on('error', () => {}); } catch (_) {}
      try { upstreamMuxWs.close(); } catch (_) {}
      upstreamMuxWs = null;
    }

    const authority = `127.0.0.1:${dshPort}`;
    const cookie = cookieFactory.current();
    const muxUrl = `ws://127.0.0.1:${dshPort}/api/remote.mux`;

    upstreamMuxWs = new WebSocket(muxUrl, {
      headers: {
        'Host': authority,
        'Cookie': cookie,
        'Origin': `http://${authority}`
      }
    });

    upstreamMuxWs.on('open', () => {
      logger.info('dsh-mobile-bridge: 上游 MUX 直连建立');
      // 1. Subscribe to DSH $events stream for approvals and interaction
      upstreamMuxWs.send(JSON.stringify({
        type: 'open',
        streamId: 'gw-events-stream',
        endpoint: '$events',
        payload: { args: {} }
      }));

      // 2. Re-follow tracked active sessions
      for (const follower of sessionFollowers.values()) {
        if (!follower.subscribed) {
          try {
            upstreamMuxWs.send(JSON.stringify({
              type: 'open',
              streamId: follower.streamId || `follow-${follower.sessionId}`,
              endpoint: 'session/follow',
              payload: { args: { request: { address: { kind: 'session', sessionId: follower.sessionId }, assistantStream: true } } }
            }));
            follower.subscribed = true;
          } catch (_) {}
        }
      }
    });

    upstreamMuxWs.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString());
        handleUpstreamMuxMessage(msg).catch((err) => {
        logger.warn('dsh-mobile-bridge: 处理上游帧失败 %s', err?.message || err);
      });
      } catch (_) {}
    });

    upstreamMuxWs.on('close', () => {
      if (isDisposed) return;
      currentEventsClientId = null;
      // Pending one-shot reads die with the link — settle them now so the HTTP
      // request gets an honest failure instead of waiting out its timeout.
      for (const [id, pending] of [...pendingOneshot]) {
        pendingOneshot.delete(id);
        pending.fail();
      }
      // The engine-side link is gone, so any answer we forward would go nowhere.
      // Stop offering these rather than letting a phone answer into the void.
      for (const q of [...pendingQuestions.values()]) {
        relinquishQuestion(q.eventId, 'upstream-link-lost');
      }
      sendToSubscribers({ type: 'questions_invalidated', reason: 'upstream-link-lost' }, questionSubscribers);
      for (const follower of sessionFollowers.values()) {
        follower.subscribed = false;
      }
      if (muxReconnectTimer) clearTimeout(muxReconnectTimer);
      muxReconnectTimer = setTimeout(connectUpstreamMux, 3000);
      // Don't hold the event loop open just to retry an upstream link.
      muxReconnectTimer.unref?.();
      // [v1.35 / 3.3] 引擎连接丢失是 critical：手机在外面收不到任何会话事件，
      // 而界面上只表现为"没动静"。10 分钟去重窗口覆盖正常的重连抖动。
      // 主动关闭（重启 dsh web）不算故障：否则每次重启都会记一条"引擎丢失"，
      // 收件箱里堆满自己重启造成的噪音，真出问题时反而看不出来。
      if (!isDisposed) {
        alertEngine.ingest({
          rule: 'heartbeat_lost',
          message: '与引擎的上游连接断开，正在重试'
        });
      }
    });

    upstreamMuxWs.on('error', (err) => {
      logger.warn('dsh-mobile-bridge: MUX 错误 %s', err?.message || err);
    });
  }

  async function handleUpstreamMuxMessage(msg) {
    if (!msg) return;

    // 0. One-shot stream bookkeeping (job/list today). Handled before anything
    // else so an `item`, `end`, or `error` frame for a one-shot stream can
    // never fall into the session-follow branches below.
    //
    // [fix 2026-10-17] readStreamFrames 生成的 streamId 前缀是 `collect-`（:767），
    // 而这里此前只认 `oneshot-` —— collect- 的 opened/output/status 帧永远找
    // 不到 pendingOneshot 条目被静默丢弃，jobs/follow 只能靠超时返回空。
    // pendingOneshot 是两者共用的注册表，前缀同时匹配即可。
    if (typeof msg.streamId === 'string' &&
        (msg.streamId.startsWith('oneshot-') || msg.streamId.startsWith('collect-'))) {
      const oneshot = pendingOneshot.get(msg.streamId);
      if (!oneshot) return;
      if (msg.type === 'item') oneshot.push(msg.value);
      else if (msg.type === 'end' || msg.type === 'error') oneshot.fail();
      return;
    }

    // 1. Upstream MUX Item Frames (Standard DSH MUX protocol)
    if (msg.type === 'item') {
      const streamId = msg.streamId || '';

      // A. Session follow stream
      if (streamId.startsWith('follow-')) {
        const sId = streamId.replace('follow-', '');
        const cleanId = sId.replace('session-', '');
        let follower = getSessionFollower(sId);
        if (!follower) {
          follower = {
            sessionId: sId,
            streamId,
            isRunning: false,
            // 引擎是否有一个未闭合的回合。**只有 turn/start 与会话日志能把它置 true**
            // —— chunk 不再参与（见下方 chunk 分支），否则一条迟到的增量帧就能
            // 把已经结束的会话永久顶成"运行中"。
            turnOpen: false,
            // 我们见过的最新事件序号；用来和 projcache 的 seq 做无猜测对账。
            lastSeq: 0,
            thinkingBuffer: '',
            textBuffer: '',
            tools: [],
            subscribed: true,
            lastUpdated: Date.now()
          };
          sessionFollowers.set(cleanId, follower);
          sessionFollowers.set(sId, follower);
        }
        follower.lastUpdated = Date.now();

        const val = msg.value;
        if (!val) return;

        if (val.type === 'assistant-stream' && val.frame) {
          const aFrame = val.frame;
          if (aFrame.type === 'start') {
            follower.isRunning = true;
            follower.turnOpen = true;
            follower.thinkingBuffer = '';
            follower.textBuffer = '';
            follower.tools = [];
            broadcastToMobileClients({ type: 'session_status', sessionId: sId, isRunning: true });
          } else if (aFrame.type === 'chunk' && aFrame.chunk) {
            const c = aFrame.chunk;
            // ⚠️ 这里**刻意不**把 isRunning/turnOpen 置 true。
            //
            // assistant-stream 帧与会话事件在 mux 上是两条独立通道，顺序无保证：
            // 实测存在 turn/end 之后仍有尾包 chunk 抵达（流式收尾/工具增量），
            // 旧代码每个 chunk 都 `follower.isRunning = true`，于是会话被永久
            // 顶成"运行中"——手机上表现为永远转圈、永远不回到空闲。
            // 增量照旧转发（内容不能丢），状态由 turn 边界独占裁决。
            if (c.type === 'reasoning-delta' && c.text) {
              follower.thinkingBuffer += c.text;
              broadcastToMobileClients({ type: 'thinking', sessionId: sId, delta: c.text, text: c.text });
            } else if (c.type === 'text-delta' && c.text) {
              follower.textBuffer += c.text;
              broadcastToMobileClients({ type: 'delta', sessionId: sId, delta: c.text, text: c.text });
            } else if (c.type === 'tool-call-delta') {
              broadcastToMobileClients({ type: 'tool_call', sessionId: sId, tool: c.name || 'tool', delta: c.argumentsDelta || '' });
            }
          }
          // 'end' 帧不裁决状态：回合结束的权威信号是会话日志里的 turn/end。
          return;
        }

        if (val.type === 'event' && val.event) {
          const ev = val.event;
          if (typeof ev.seq === 'number' && ev.seq > (follower.lastSeq || 0)) {
            follower.lastSeq = ev.seq;
          }
          if (ev.type === 'turn/start') {
            follower.isRunning = true;
            follower.turnOpen = true;
            follower.thinkingBuffer = '';
            follower.textBuffer = '';
            follower.tools = [];
            broadcastToMobileClients({ type: 'session_status', sessionId: sId, isRunning: true });
          } else if (ev.type === 'turn/end') {
            follower.isRunning = false;
            follower.turnOpen = false;
            follower.activePromptText = null;
            activePrompts.delete(sId);
            activePrompts.delete(cleanId);
            activePrompts.delete(`session-${cleanId}`);
            for (const t of follower.tools) t.isRunning = false;
            const end = describeTurnEnd(ev.data?.reason);
            follower.lastTurn = { kind: end.kind, text: end.text, time: Date.now(), seq: ev.seq };
            if (isFailedTurnEnd(ev.data?.reason)) {
              // 引擎没有 turn/error 事件：失败只记在 turn/end.reason 里，而那是
              // 错误文本的**唯一**载体（Web UI 就是读它渲染错误横幅的）。
              // 旧代码整个丢掉 reason，手机于是只有一个永不停止的转圈。
              broadcastToMobileClients({
                type: 'error',
                sessionId: sId,
                error: end.text || '本轮执行失败',
                errorCode: end.code || 'UNKNOWN',
                turnEnded: true
              });
              // [v1.35 / 3.3] 回合失败进告警收件箱（10 分钟内同会话只记一条）。
              alertEngine.ingest({
                rule: 'turn_error',
                sessionId: sId,
                message: end.text || '本轮执行失败'
              });
            }
            broadcastToMobileClients({ type: 'done', sessionId: sId, reason: end.kind, message: end.text });
            // [fix 2026-10-14] turn/end 时把本轮完整正文快照存进 lastTurnPayload，
            // 供断线重连的手机补拉（手机可能只收到部分 delta 或一个都没收到）。
            // 60 秒 TTL：正常路径（App 收到了完整 delta 或已拉过快照）不需要它，
            // 只为"delta 窗口期断线 + 回合恰好结束"的窄窗口兜底。
            follower.lastTurnPayload = {
              text: follower.textBuffer || '',
              thinking: follower.thinkingBuffer || '',
              seq: ev.seq || null,
              expiresAt: Date.now() + 60000
            };
            follower.thinkingBuffer = '';
            follower.textBuffer = '';
            follower.tools = [];
            broadcastToMobileClients({ type: 'session_status', sessionId: sId, isRunning: false });
            audit('session/turn-end', { sessionId: sId, kind: end.kind });
            // 离线推送：进程被杀/手机锁屏时，这条是唯一能叫醒用户的东西。
            pushNtfy(isFailedTurnEnd(ev.data?.reason) ? 'turn-failed' : 'turn-end', {
              sessionId: sId,
              summary: end.text || '本轮已结束',
              clickUrl: deepLinkUrl('done', sId)
            });
          } else if (ev.type === 'tool/call') {
            const toolObj = {
              id: ev.data?.id || `tool_${Date.now()}`,
              name: ev.data?.name || 'tool',
              input: coerceToolInput(ev.data?.arguments),
              output: '',
              isRunning: true
            };
            follower.tools.push(toolObj);
            broadcastToMobileClients({ type: 'tool_start', sessionId: sId, tool: toolObj.name, input: toolObj.input });
          } else if (ev.type === 'tool/result') {
            if (follower.tools.length > 0) {
              const t = follower.tools[follower.tools.length - 1];
              t.isRunning = false;
              t.output = ev.data?.output || '执行完毕';
            }
            broadcastToMobileClients({ type: 'tool_result', sessionId: sId, output: ev.data?.output || '执行完毕' });
          }
          // todo/write and session/attachment also ride the session log. This
          // branch ends in a bare `return`, so they must be offered here too or
          // they disappear with no trace when the engine multiplexes them onto
          // the follow stream.
          forwardSessionEvent(val, sId);
          return;
        }
        return;
      }

      // B. $events stream (approvals, questions and requests)
      if (msg.value) {
        const val = msg.value;
        if (val.type === 'ready') {
          currentEventsClientId = val.clientId || '';
          logger.info(`[dsh-mobile-bridge] $events stream ready with clientId: ${currentEventsClientId}`);
          return;
        }

        /* ---------------------------------------------------------- *
         * user-questions/request — the agent is blocked waiting for a
         * human. [0003]
         *
         * The answer goes back over `$events/result`, the same channel
         * and the same `{kind:'result', value}` shape the auto-approve
         * path already uses in production. NOT a local Promise: a
         * `next` continuation cannot survive the JSON hop, so a
         * promise-based design would pass a unit test and hang in
         * production.
         *
         * When nobody can answer, the frame is simply left unanswered.
         * That is what lets the engine's waterfall fall through to the
         * Web UI answerer. Sending an empty answer instead would tell
         * the agent the human replied with nothing.
         * ---------------------------------------------------------- */
        if (val.type === 'request' || val.type === 'waterfall') {
          if (val.event === 'user-questions/request') {
            const request = val.request || val.payload || val.data || {};
            const questions = Array.isArray(request.questions) ? request.questions : [];
            const sessionId = val.agent || val.agentId || val.sessionId || request.sessionId
              || (request.agent && request.agent.id) || 'default';
            // The engine resolves the waterfall by event id. A minted one would
            // be rejected on the way back, so an id-less frame is unanswerable
            // rather than merely inconvenient — say so instead of storing it and
            // letting a phone answer into the void.
            const eventId = val.id || val.eventId || request.id || null;

            if (!eventId) {
              logger.warn('[dsh-mobile-bridge] user-questions 帧缺少 id，无法代答，留给 Web UI');
              audit('question/unanswerable', { sessionId, why: 'no-event-id' });
              return;
            }

            if (questionSubscribers.size === 0) {
              logger.info('[dsh-mobile-bridge] user-questions 无手机订阅者，留给 Web UI');
              audit('question/relinquished', { eventId, sessionId, why: 'no-subscriber' });
              return;
            }

            pendingQuestions.set(eventId, {
              eventId,
              sessionId,
              questions,
              createdAt: Date.now(),
              // Which live subscriber sockets this prompt was offered to. A
              // phone that goes away only takes down what it was shown.
              offeredTo: new Set(questionSubscribers)
            });

            sendToSubscribers({
              type: 'question_request',
              eventId,
              sessionId,
              questions
            }, questionSubscribers);
            audit('question/requested', { eventId, sessionId, count: questions.length });
            pushNtfy('question', {
              sessionId,
              question: questions[0]?.question || '',
              clickUrl: deepLinkUrl('question', sessionId)
            });
            return;
          }
        }

        // `todo/write` and `session/attachment` are SESSION events, matched on
        // the event name alone — they are not waterfalls.
        if (forwardSessionEvent(val, null)) return;

        // A cancelled turn invalidates whatever it was waiting on.
        //
        // ⚠️ 必须**按会话（或按 eventId）**清，不能像早先那样把 pendingQuestions
        // 全清。实测过一次现网事故：A 会话的取消帧抵达后，B 会话那条仍然活着的
        // 提问被一起清掉 —— 手机上的卡片随之消失、重连 replay 也空了，而电脑端
        // （直接读引擎状态）**仍然显示着那个选择项**。用户看到的就是
        // "通知来了、点进去什么都没有，电脑上却在等他回答"。
        if (val.type === 'cancel' || val.event === 'approval/cancel' || val.event === 'turn/cancel') {
          const cancelEventId = val.eventId || val.id;
          const cancelSession = val.agent || val.agentId || val.sessionId ||
            val.data?.sessionId || val.request?.sessionId || null;
          let dropped = 0;
          if (cancelEventId && pendingQuestions.has(cancelEventId)) {
            relinquishQuestion(cancelEventId, 'engine-cancel');
            dropped++;
          } else if (cancelSession) {
            for (const q of [...pendingQuestions.values()]) {
              if (sessionIdMatchesSafe(q.sessionId, cancelSession)) {
                relinquishQuestion(q.eventId, 'engine-cancel');
                dropped++;
              }
            }
          }
          // 既没有匹配的 eventId、也没有会话信息时**什么都不清**：引擎的取消帧
          // 不带我们在找的那个 id 是常态，宁可由 TTL 与"作答时被引擎拒绝"来收尾，
          // 也不能拿一个看不见的误删去换——误删之后用户连重试的入口都没有了。
          if (dropped > 0) {
            sendToSubscribers({ type: 'questions_invalidated', reason: 'engine-cancel' }, questionSubscribers);
          }
        }

    if (val.type === 'cancel' || val.event === 'approval/cancel') {
          const eventId = val.eventId || val.id;
          if (eventId) {
            const appr = coreApprovals.get(eventId);
            if (appr) {
              coreApprovals.remove(appr, eventId);
              broadcastToMobileClients({
                type: 'approval_settled',
                eventId: appr.eventId || eventId,
                outcome: 'cancelled',
                reason: '上游任务已终止或取消'
              });
              audit('approval/cancelled', { approvalId: eventId });
            }
          }
          return;
        }

        if ((val.type === 'request' || val.type === 'waterfall') && val.event === 'approval/request') {
          const eventId = val.id || val.eventId || val.request?.id || `appr_${approvalCounter++}`;
          const sessionId = val.agent || val.agentId || val.sessionId || val.request?.sessionId || 'default';
          const toolName = val.request?.toolName || '工具执行';
          const reason = val.request?.reason || '申请工具执行权限';
          const callId = val.request?.callId || '';
          const input = coerceToolInput(val.request?.input ?? val.request?.arguments ?? val.request?.args ?? val.request?.command);
          const options = val.request?.options || null;

          // getSessionPermission() already delegates to permStore.forSession(),
          // which resolves session policy first and falls back to global. It is
          // therefore the EFFECTIVE policy, not merely the session-level one.
          const effectivePolicy = getSessionPermission(sessionId);

          // [P0] Resolve the command that is actually about to run.
          //
          // This used to default to `reason` — the model's own free-text
          // justification — and only fell back to the real command if
          // val.request.command happened to be a string. Anything the model
          // wrote in `reason` was what got classified, so a reason of "ls"
          // auto-approved an arbitrary destructive command under auto-read.
          // `reason` is now never used as a command, and an unresolvable command
          // fails CLOSED (no auto-approval) instead of failing open.
          const cmdToCheck = (() => {
            if (typeof val.request?.command === 'string' && val.request.command.trim()) {
              return val.request.command;
            }
            if (typeof input === 'string' && input.trim()) return input;
            if (input && typeof input === 'object') {
              for (const k of ['command', 'cmd', 'script', 'shell', 'argv', 'args']) {
                const v = input[k];
                if (typeof v === 'string' && v.trim()) return v;
                if (Array.isArray(v) && v.every((x) => typeof x === 'string') && v.length) return v.join(' ');
              }
              // A structured tool input we cannot reduce to a command line is not
              // something a prefix whitelist can judge.
              return null;
            }
            return null;
          })();

          let shouldAutoApprove = false;
          let autoApproveReason = '';

          // [P0] Session precedence, not OR.
          //
          // Both branches used to read
          //   sessionPolicy === 'X' || globalPermissions.executionPolicy === 'X'
          // which re-ORed the global policy back on top of an already-resolved
          // effective policy and destroyed the precedence. With the shipped
          // default (global = 'auto-read'), a session explicitly set to 'ask'
          // still hit the auto-read branch and was auto-approved — the app's
          // per-session "ask" control was a placebo, and setSessionPermission()
          // had no effect on the approval path at all.
          if (effectivePolicy === 'danger-full-access') {
            shouldAutoApprove = true;
            autoApproveReason = '全信任模式 (Danger Full Access) 自动放行';
          } else if (effectivePolicy === 'auto-read') {
            if (cmdToCheck && isCommandReadOnly(cmdToCheck, toolName)) {
              shouldAutoApprove = true;
              autoApproveReason = '安全策略: 只读指令自动放行';
            } else if (!cmdToCheck) {
              audit('approval/auto-approve-skipped', {
                id: eventId, sessionId, toolName,
                why: 'no-resolvable-command',
                policy: effectivePolicy
              });
            }
          }

          if (shouldAutoApprove) {
            // payload 只能有 `args` 一个字段 —— 多带平铺字段会被引擎以
            // "requires exactly one plain-object args field" 拒掉。
            // 失败不能再静默吞（旧实现 .catch(()=>{})，引擎收不到放行结果，
            // 工具调用只能超时）：降级成人工审批卡片，用户还能救。
            try {
              await callDshRpc('$events/result', {
                args: { clientId: currentEventsClientId, eventId, outcome: { kind: 'result', value: 'allowed-once' } }
              });
              // Audit the command that was actually classified, not the model's
              // self-reported reason. Recording `reason` in the `command` field is
              // what made the audit trail unusable for reconstructing what ran.
              audit('approval/auto-approved', {
                id: eventId,
                time: Date.now(),
                sessionId,
                toolName,
                command: cmdToCheck ?? '(unresolved)',
                policy: effectivePolicy,
                outcome: 'auto-approved',
                reason: autoApproveReason
              });
            } catch (e) {
              logger.warn('[dsh-mobile-bridge] 自动放行回传失败，降级为人工审批:', e?.message || e);
              audit('approval/auto-approve-failed', {
                id: eventId,
                sessionId,
                toolName,
                command: cmdToCheck ?? '(unresolved)',
                policy: effectivePolicy,
                error: e?.message,
                outcome: 'downgraded-to-manual'
              });
              const approval = mintApproval({
                id: eventId,
                eventId,
                clientId: currentEventsClientId,
                sessionId,
                toolName,
                reason,
                callId,
                input,
                options
              });
              coreApprovals.put(approval);
              auditApproval(approval);
              broadcastToMobileClients({ type: 'approval_request', approval });
              pushNtfy('approval', {
                sessionId,
                toolName,
                reason,
                clickUrl: deepLinkUrl('approval', sessionId)
              });
            }
            return;
          }

          const approval = mintApproval({
            id: eventId,
            eventId,
            clientId: currentEventsClientId,
            sessionId,
            toolName,
            reason,
            callId,
            input,
            options
          });

          coreApprovals.put(approval);
          auditApproval(approval);
          broadcastToMobileClients({
            type: 'approval_request',
            approval
          });
          pushNtfy('approval', {
            sessionId,
            toolName,
            reason,
            clickUrl: deepLinkUrl('approval', sessionId)
          });
          return;
        }
      }
    }

    // 2. Legacy event frame fallback ({ type: 'event', event: { ... } })
    if (msg.type === 'event' && msg.event) {
      const ev = msg.event;
      const sId = ev.sessionId || (ev.data && ev.data.sessionId);

      if (ev.type === 'token' || ev.type === 'chunk' || ev.type === 'delta') {
        const chunkText = ev.text || ev.content || ev.delta || '';
        const thinkingText = ev.thinking || (ev.data && ev.data.thinking) || '';
        broadcastToMobileClients({
          type: 'delta',
          sessionId: sId,
          delta: chunkText,
          thinking: thinkingText
        });
      } else if (ev.type === 'approval_request' || ev.name === 'approval_request') {
        const eventId = ev.id || ev.eventId || `appr_${approvalCounter++}`;
        const approval = mintApproval({
          id: eventId,
          eventId,
          clientId: currentEventsClientId,
          sessionId: sId,
          toolName: ev.toolName || ev.action || '系统执行',
          reason: ev.reason || ev.command || '申请工具执行权限',
          callId: ev.callId || '',
          input: ev.input || ev.command || '',
          options: ev.options || null
        });
        coreApprovals.put(approval);
        broadcastToMobileClients({
          type: 'approval_request',
          approval
        });
        auditApproval(approval);
      } else if (ev.type === 'session_status') {
        const isCancelled = coreTurns.getCancelledSeq(sId) > 0 && (Date.now() - coreTurns.getLastCancelTime(sId) < 1000);
        const follower = getSessionFollower(sId);
        const shouldRun = Boolean(ev.isRunning && !isCancelled && (follower ? follower.isRunning : true));
        broadcastToMobileClients({
          type: 'session_status',
          sessionId: sId,
          isRunning: shouldRun
        });
      }
    }
  }

  /* ------------------------------------------------------------------ *
   * [v1.35 / 2.1] 单次审批令牌
   *
   * 锁屏通知只能拿到「这条审批」的一枚一次性凭据，而不是设备 token 那种宽权限。
   * 存储与校验逻辑在 core（createApprovalTokens，纯函数、可注入时钟）；这里只负责
   * 铸造时机（入队时）、敏感策略判定、以及把它接到既有 handleApprovalRespond 上。
   * ------------------------------------------------------------------ */

  const approvalTokens = createApprovalTokens();

  function approvalPolicyOf(sessionId) {
    try {
      return getSessionPermission(sessionId)?.executionPolicy
        || globalPermissions.executionPolicy
        || 'ask';
    } catch {
      return 'ask';
    }
  }

  /** 构造待审批记录；非敏感策略附带 approvalToken。 */
  function mintApproval(fields) {
    const approval = { ...fields, createdAt: fields.createdAt || Date.now() };
    const sensitive = isSensitiveApprovalPolicy(approvalPolicyOf(approval.sessionId));
    approval.sensitive = sensitive;
    if (sensitive) {
      // 完全访问策略下命令不再逐条确认：通知栏再给一键放行，一次误触就等于
      // 让 Agent 无确认执行任意命令。这类审批必须回 App 里看命令原文。
      approval.approvalToken = null;
    } else {
      approval.approvalToken = approvalTokens.mint(approval.eventId || approval.id);
    }
    return approval;
  }

  /** 审计里绝不能出现明文令牌（/audit-logs 会把它读出去）。 */
  function auditApproval(approval) {
    const { approvalToken, ...rest } = approval;
    audit('approval/requested', rest);
  }

  /**
   * 通知栏一键裁决。
   *
   * @returns {{status:number, body:object}} 直接可回给 HTTP 的状态与载荷
   */
  async function decideApproval({ approvalId, decision, token, reason }) {
    const wanted = String(approvalId || '').trim();
    const normalized = (decision === 'approve' || decision === 'allow')
      ? 'approve'
      : (decision === 'deny' || decision === 'reject') ? 'deny' : '';
    if (!wanted || !normalized) {
      return { status: 400, body: { ok: false, code: 'bad-request', error: '缺少 approvalId，或 decision 不是 approve/deny' } };
    }

    const appr = coreApprovals.get(wanted);
    if (!appr) {
      return { status: 404, body: { ok: false, code: 'unknown', error: '审批不存在或已处理' } };
    }
    if (appr.sensitive) {
      return { status: 409, body: { ok: false, code: 'sensitive', error: '该审批属于完全访问策略，请打开 App 确认' } };
    }

    const id = appr.eventId || appr.id;
    const verdict = approvalTokens.check(id, token);
    if (!verdict.ok) {
      if (verdict.code === 'consumed') {
        // 幂等：通知被连点两下时，同向重复请求不该报错。
        if (verdict.decision === normalized) {
          return {
            status: 200,
            body: {
              ok: true,
              alreadyApplied: true,
              code: 'consumed',
              outcome: normalized === 'approve' ? 'allowed-once' : 'rejected'
            }
          };
        }
        return { status: 409, body: { ok: false, code: 'conflict', error: '该审批已按相反决定处理过' } };
      }
      if (verdict.code === 'expired') {
        return { status: 410, body: { ok: false, code: 'expired', error: '审批已过期（15 分钟）' } };
      }
      if (verdict.code === 'mismatch') {
        return { status: 403, body: { ok: false, code: 'mismatch', error: '审批令牌不匹配' } };
      }
      return { status: 404, body: { ok: false, code: 'unknown', error: '审批令牌已失效' } };
    }

    const result = await handleApprovalRespond(id, normalized, reason || '通知栏一键处理');
    if (!result.ok) {
      return { status: 502, body: { ok: false, code: 'engine-rejected', error: result.error || '引擎拒绝了这次回传' } };
    }

    approvalTokens.consume(id, normalized);
    approvalTokens.prune();

    // 让 App 内 UI 与电脑端同步（App 的审批 dock 收到这条就自己消失）。
    broadcastToMobileClients({
      type: 'approval_decided',
      approvalId: id,
      eventId: id,
      decision: normalized,
      source: 'notification'
    });

    return { status: 200, body: { ok: true, code: 'applied', outcome: result.outcome } };
  }

  async function handleApprovalRespond(eventId, outcome, reason = '') {
    const appr = coreApprovals.get(eventId);
    if (!appr) {
      const normalizedOutcome = (outcome === 'allow' || outcome === 'allowed-once' || outcome === 'approve')
        ? 'allowed-once'
        : 'rejected';
      return {
        ok: false,
        code: 404,
        approvalId: eventId,
        eventId: eventId,
        outcome: normalizedOutcome,
        error: `Approval request with ID ${eventId} not found or expired`
      };
    }

    const normalizedOutcome = (outcome === 'allow' || outcome === 'allowed-once' || outcome === 'approve')
      ? 'allowed-once'
      : 'rejected';

    // RPC FIRST, dequeue only on success. The old order (remove → RPC →
    // catch-and-warn → ok:true) meant a failed $events/result left the agent
    // blocked at the approval gate forever while the phone showed a green
    // "已放行". Keeping the queue entry on failure gives the user a retry.
    let rpcOk = true;
    let rpcError = '';
    try {
      // 同 handleQuestionAnswer：payload 只能有 `args` 一个字段。
      // 多带平铺字段会被引擎以 "requires exactly one plain-object args field"
      // 拒掉 —— 那正是「手机上点了批准/拒绝没反应」的成因（本函数是审批回传，
      // 与提问回传是同一处错误的两份）。
      await callDshRpc('$events/result', {
        args: {
          clientId: appr.clientId || currentEventsClientId,
          eventId: appr.eventId || appr.id,
          outcome: { kind: 'result', value: normalizedOutcome }
        }
      });
    } catch (e) {
      rpcOk = false;
      rpcError = e?.message || String(e);
      logger.warn('[dsh-mobile-bridge] 审批回传失败，保留队列供重试:', rpcError);
    }

    // [fix 2026-10-11] Only dequeue when the RPC actually succeeded — otherwise
    // the 502 below tells the user "retry", but the card is already gone and a
    // retry 404s at the not-found check above (the contradiction the comment
    // above promised to avoid). Mirrors handleQuestionAnswer's retain-on-failure.
    if (rpcOk) coreApprovals.remove(appr, eventId);

    audit('approval/respond', {
      approvalId: appr.eventId || eventId,
      outcome: normalizedOutcome,
      ok: rpcOk,
      reason: reason || (normalizedOutcome === 'allowed-once' ? '人工手机审批放行' : '人工手机拒绝执行')
    });

    if (!rpcOk) {
      return {
        ok: false,
        code: 502,
        approvalId: appr.eventId || eventId,
        eventId: appr.eventId || eventId,
        outcome: normalizedOutcome,
        error: `回传引擎失败: ${rpcError}`
      };
    }

    broadcastToMobileClients({
      type: 'approval_settled',
      eventId: appr.eventId || appr.id || eventId,
      outcome: normalizedOutcome,
      reason: reason || ''
    });

    return {
      ok: true,
      code: 0,
      approvalId: appr.eventId || eventId,
      eventId: appr.eventId || eventId,
      outcome: normalizedOutcome,
      message: `Approval ${normalizedOutcome} recorded`
    };
  }

  // authenticateRequest now lives in core; call sites pass the parsed URL through.

  /* ------------------------------------------------------------------ *
   * [v1.35 / 1.5] 云隧道（cloudflared quick tunnel）
   *
   * 目标：用户在外面没有公网地址，也能连回这台机器。quick tunnel 免账号，
   * 但地址每次重启都变，所以它被定位成「临时通道」，文案必须说清。
   *
   * 三条安全/可用性约束：
   *   - 隧道只指向 TLS 端口：把明文 3088 暴露到公网等于让 token 裸奔，
   *     因此 TLS 未启用时拒绝启动（明确报错，不静默降级）；
   *   - 二进制下载失败只降级，不影响网关本体；
   *   - 隧道进程随宿主退出（cleanupGateway 里 stop）。
   * ------------------------------------------------------------------ */

  let quickTunnel = null;
  /** 最近一次隧道启动失败的原因（status 如实上报，避免 App 显示成 idle）。 */
  let lastTunnelError = '';

  /** 用系统 curl 下载（另一套 TLS 栈，用来绕过 Node 的握手被断）。 */
  function curlDownload(url, file) {
    return new Promise((resolve, reject) => {
      const bin = process.platform === 'win32' ? 'curl.exe' : 'curl';
      execFile(bin, ['-sSL', '--max-time', '300', '--retry', '1', '-o', file, url], {
        windowsHide: true,
        maxBuffer: 1024 * 1024
      }, (error, _stdout, stderr) => {
        if (error) {
          const detail = String(stderr || error.message || '').trim().slice(0, 200);
          reject(new Error(`curl 下载失败：${detail || '未知错误'}`));
          return;
        }
        resolve();
      });
    });
  }

  /**
   * 下载 60MB 的 cloudflared 到文件。
   *
   * 为什么要 curl 兜底：本机实测 Node 的 https 在
   * `release-assets.githubusercontent.com` 上会被网络中断
   * （Client network socket disconnected before secure TLS connection was
   * established），而同一台机器上的 curl 能完整下载。这不是代码 bug，是两条
   * 网络路径的差异——但用户要的是「隧道能用」，所以退化到系统 curl 是正确取舍。
   */
  async function downloadToFile(url, file) {
    try {
      await new Promise((resolve, reject) => {
        const attempt = (u, redirects = 3) => {
          let parsed;
          try { parsed = new URL(u); } catch (err) { reject(err); return; }
          const transport = parsed.protocol === 'https:' ? https : http;
          const req = transport.get(parsed, { timeout: 60000 }, (res) => {
            const status = res.statusCode ?? 0;
            if ([301, 302, 303, 307, 308].includes(status) && res.headers.location && redirects > 0) {
              res.resume();
              attempt(String(new URL(res.headers.location, parsed)), redirects - 1);
              return;
            }
            if (status !== 200) {
              res.resume();
              reject(new Error(`下载失败 HTTP ${status}`));
              return;
            }
            const out = fs.createWriteStream(file);
            res.pipe(out);
            out.on('finish', () => out.close(() => resolve()));
            out.on('error', reject);
            res.on('error', reject);
          });
          req.on('error', reject);
          req.on('timeout', () => { try { req.destroy(); } catch (_) {} reject(new Error('下载超时')); });
        };
        attempt(url);
      });
    } catch (err) {
      logger.warn('[dsh-mobile-bridge] Node 下载 cloudflared 失败（%s），改用 curl 兜底', err?.message ?? err);
      try { fs.rmSync(file, { force: true }); } catch (_) {}
      await curlDownload(url, file);
    }
  }

  /** 一次性 HTTP(S) 下载（跟随 GitHub 的 302 到 release-assets/objects）。 */
  function fetchUrlBytes(url, redirects = 3) {
    return new Promise((resolve, reject) => {
      let parsed;
      try { parsed = new URL(url); } catch (err) { reject(err); return; }
      const transport = parsed.protocol === 'https:' ? https : http;
      const req = transport.get(parsed, { timeout: 30000 }, (res) => {
        const status = res.statusCode ?? 0;
        if ([301, 302, 303, 307, 308].includes(status) && res.headers.location && redirects > 0) {
          res.resume();
          resolve(fetchUrlBytes(String(new URL(res.headers.location, parsed)), redirects - 1));
          return;
        }
        if (status !== 200) {
          res.resume();
          reject(new Error(`下载失败 HTTP ${status}`));
          return;
        }
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve(Buffer.concat(chunks)));
      });
      req.on('error', reject);
      req.on('timeout', () => { try { req.destroy(); } catch (_) {} reject(new Error('下载超时')); });
    });
  }

  function tunnelPayload() {
    return {
      ok: true,
      status: quickTunnel?.status ?? 'idle',
      url: quickTunnel?.url ?? '',
      target: tlsPort > 0 ? `https://127.0.0.1:${tlsPort}` : null,
      // 上一次启动失败的原因要一直挂着，直到下一次尝试：否则 App 只能看到
      // idle，用户会以为「没点成功」，而不是「点了但下载/启动失败」。
      error: quickTunnel?.lastError ?? lastTunnelError ?? ''
    };
  }

  /** 首个非回环 IPv4（局域网地址；拿不到就退回 127.0.0.1）。 */
  function primaryLanIpv4() {
    for (const list of Object.values(os.networkInterfaces())) {
      for (const ni of list || []) {
        if (ni.family === 'IPv4' && !ni.internal) return ni.address;
      }
    }
    return '127.0.0.1';
  }

  /**
   * 「远程接入」的统一视图（[refactor 2026-10-21]）。
   *
   * 三种 provider **严格互斥**，这里把它们归一成手机端唯一需要的东西：
   * 现在走哪条路、公网地址是什么、能不能用、为什么不能用。
   *
   * 为什么这层逻辑不能放客户端：NPS 的地址来自配置（固定），cloudflared 的地址
   * 来自进程运行时（每次重连都变），两者的就绪判定也不同 —— 前者只能"已配置"，
   * 后者必须等到 `Registered tunnel connection`。放两头必然漂移。
   */
  function remoteAccessPayload() {
    const cfg = loadConfig();
    const ra = cfg.remoteAccess || { provider: 'none', nps: { host: '', port: listenPort, useHttps: false } };
    const provider = ra.provider || 'none';
    const lanIp = primaryLanIpv4();
    const localUrl = `http://${lanIp}:${listenPort}`;
    const base = {
      ok: true,
      provider,
      localUrl,
      tlsPort,
      certFingerprint: certFingerprint || null
    };

    if (provider === 'nps') {
      const scheme = ra.nps.useHttps ? 'https' : 'http';
      return {
        ...base,
        // managed: external —— 出口是用户自己的反代，网关只能"知道自己挂在哪"，
        // 没有能力验证它到底通不通。所以 ready 只代表"配置完整"。
        managed: 'external',
        publicUrl: `${scheme}://${ra.nps.host}:${ra.nps.port}`,
        ready: true,
        reason: ra.nps.useHttps ? '' : 'NPS 走明文：token 会裸露在公网，建议在 NPS 上启用 HTTPS'
      };
    }

    if (provider === 'cloudflared') {
      const status = quickTunnel?.status ?? 'idle';
      const raw = quickTunnel?.url ?? '';
      const publicUrl = raw
        ? (raw.startsWith('http') ? raw : `https://${raw}`)
        : null;
      return {
        ...base,
        // managed: gateway —— 进程由网关自己拉起与回收。
        managed: 'gateway',
        publicUrl,
        ready: status === 'ready',
        status,
        reason: status === 'ready' ? ''
          : (quickTunnel?.lastError || lastTunnelError
            || (status === 'starting' ? '隧道正在建立（等 Cloudflare 边缘注册成功）' : '隧道未启动'))
      };
    }

    return {
      ...base,
      provider: 'none',
      managed: 'none',
      publicUrl: null,
      ready: false,
      reason: '未选择远程通道：只有同一局域网内的手机能连'
    };
  }

  /**
   * 拉起 quick tunnel（幂等）。返回 { ok, error? } 而不是直接写响应 —— 启动路由与
   * provider 对账都要用同一条实现，复制一份必然漂移。
   */
  async function startQuickTunnel() {
    if (quickTunnel && (quickTunnel.status === 'ready' || quickTunnel.status === 'starting')) {
      return { ok: true };
    }
    if (tlsPort <= 0 || !tlsServer) {
      // 明确拒绝而不是"帮你改成明文暴露"：quick tunnel 会把流量放到公网，
      // 明文 HTTP 上的 token 等于公开。
      return { ok: false, code: 'tls-disabled', error: 'TLS 端口未启用，无法开启公网隧道（隧道必须指向 HTTPS）' };
    }
    try {
      lastTunnelError = '';
      const bin = await ensureCloudflared({ fetchToFile: downloadToFile });
      quickTunnel = createQuickTunnel({
        binary: bin.path,
        target: `https://127.0.0.1:${tlsPort}`,
        onUrl: (url) => {
          audit('tunnel/url', { url });
          // 地址变化要立刻广播：手机拿着旧地址重连只会得到"连不上"，
          // 而它没法自己发现新地址。
          broadcastToMobileClients({ type: 'tunnel_url', url, channel: 'remote' });
        },
        onExit: (info) => {
          audit('tunnel/exit', { code: info.code, error: info.error });
          broadcastToMobileClients({ type: 'tunnel_url', url: '', channel: 'remote' });
        },
        logger
      });
      quickTunnel.start();
      audit('tunnel/start', { target: `https://127.0.0.1:${tlsPort}`, binary: bin.path });
      return { ok: true };
    } catch (err) {
      // 下载失败 / 校验失败都在这里：只降级，不影响局域网与明文端口。
      lastTunnelError = err?.message ?? String(err);
      logger.warn('[dsh-mobile-bridge] 云隧道启动失败: %s', lastTunnelError);
      return { ok: false, error: lastTunnelError };
    }
  }

  /**
   * 让运行时状态跟上 provider —— **严格互斥的执行点**。
   *
   * 唯一允许 cloudflared 存活的条件是 `provider === 'cloudflared'`。切到 nps /
   * none 时必须把它停掉，否则两条出口同时对外，用户面对的是一个说不清的地址
   * 集合（这也是本次重构要消灭的那个状态）。
   */
  async function reconcileRemoteAccess() {
    const cfg = loadConfig();
    const provider = cfg.remoteAccess?.provider || 'none';
    if (provider !== 'cloudflared') {
      if (quickTunnel) {
        try { quickTunnel.stop(); } catch (_) { /* best effort */ }
        quickTunnel = null;
        lastTunnelError = '';
        audit('tunnel/stop', { reason: `provider=${provider}` });
        broadcastToMobileClients({ type: 'tunnel_url', url: '', channel: 'remote' });
      }
      return { ok: true };
    }
    return startQuickTunnel();
  }

  // [v1.35 / 1.2] 请求处理器提成具名变量：明文端口与 TLS 端口共用同一份路由与
  // 鉴权栈。此前它内联在 createServer(...) 里，想加第二个监听面就只能复制整张
  // 路由表 —— 那正是本仓库历史上「两份实现漂移」的老毛病。
  const requestHandler = async (req, res) => {
    const parsedUrl = url.parse(req.url, true);
    const pathname = parsedUrl.pathname;

    // CORS was `*` with Authorization explicitly allowed. Combined with the
    // token-query fallback that meant any page the user happened to visit while
    // signed in to nothing could fire authenticated cross-origin XHRs at this
    // gateway — reading sessions, answering questions, approving commands.
    // Only echo an Origin that the operator allow-listed; otherwise no CORS
    // headers at all (the browser then blocks the read).
    const origin = String(req.headers.origin || '');
    const allowOrigin = origin && CORS_ALLOWED_ORIGINS.has(origin.toLowerCase());
    if (allowOrigin) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Vary', 'Origin');
    }
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, x-dsh-token, x-auth-code');

    if (req.method === 'OPTIONS') {
      // Preflight for a disallowed origin must not answer 204-with-headers;
      // 403 is what stops the follow-up request from being made.
      res.writeHead(allowOrigin ? 204 : 403);
      res.end();
      return;
    }

    // [feat 2026-10-12] >4KB 的 JSON 响应在客户端声明支持时用 gzip 压缩：
    // 工作区/会话列表的 JSON 轻松几十 KB，弱网下传输减半以上。只压 sendJson
    // 这条路径 —— SSE/WS/文件流本来就不是 JSON，且流式响应绝不能走同步压缩。
    const sendJson = (status, obj) => {
      const raw = Buffer.from(JSON.stringify(obj), 'utf8');
      const headers = { 'Content-Type': 'application/json; charset=utf-8' };
      const accept = String(req.headers['accept-encoding'] || '');
      if (raw.length > 4096 && /\bgzip\b/i.test(accept)) {
        const gz = zlib.gzipSync(raw);
        headers['Content-Encoding'] = 'gzip';
        headers['Content-Length'] = String(gz.length);
        headers['Vary'] = 'Accept-Encoding';
        res.writeHead(status, headers);
        res.end(gz);
        return;
      }
      headers['Content-Length'] = String(raw.length);
      res.writeHead(status, headers);
      res.end(raw);
    };

    // 1. 健康探测与鉴权测试 (供手机端 testConnection 测试连通性)
    if (pathname === '/health' || pathname === '/api/mobile/health' || pathname === '/__mobile/health' || pathname === '/api/mobile/ping') {
      let testToken = '';
      const authHeader = req.headers['authorization'];
      if (authHeader && authHeader.startsWith('Bearer ')) {
        testToken = authHeader.slice(7).trim();
      } else if (req.headers['x-dsh-token']) {
        testToken = String(req.headers['x-dsh-token']).trim();
      } else if (req.headers['x-auth-code']) {
        testToken = String(req.headers['x-auth-code']).trim();
      }
      // No `?token=` fallback here: a token in a URL lands in proxy access logs,
      // browser history and Android network diagnostics. Headers only.
      const isAuthed = verifyToken(testToken);
      if (!isAuthed) {
        // /health is the cheapest endpoint to hammer, so it gets the same
        // per-IP backoff as the business routes.
        const bo = checkAuthBackoff(req);
        if (bo.blocked) {
          res.setHeader('Retry-After', String(Math.ceil(bo.retryAfterMs / 1000)));
          sendJson(429, {
            code: 429, ok: false, authenticated: false,
            error: '认证失败次数过多，请稍后再试',
            retryAfterMs: bo.retryAfterMs
          });
          return;
        }
        noteAuthFailure(req);
        // [feat 2026-10-12] health 路由有自己独立的 401 分支（早于统一鉴权门），
        // 同样要带上 device_revoked 标记 —— 客户端 testConnection/心跳轮询走的
        // 正是这条路，少了它被踢设备的 App 只会报"token 错误"。
        const revDev = testToken ? findDeviceByToken(testToken) : null;
        if (revDev) {
          sendJson(401, {
            code: 401, ok: false, authenticated: false,
            code2: 'device_revoked', device_revoked: true, deviceId: revDev.id,
            error: '电脑端已移除此设备'
          });
          return;
        }
        sendJson(401, {
          code: 401,
          ok: false,
          authenticated: false,
          error: '认证失败: 授权码无效或为空 (Unauthorized)',
          name: 'dsh-mobile-bridge',
          port: listenPort,
          version: BRIDGE_VERSION
        });
        return;
      }
      clearAuthFailures(req);
      sendJson(200, {
        code: 0,
        ok: true,
        authenticated: true,
        name: 'dsh-mobile-bridge',
        port: listenPort,
        // [v1.35 / 1.2] TLS 端口与证书指纹：手机在「连接与诊断」页能直接看出
        // 这台机器是否开了 HTTPS，以及当前证书是哪一张（指纹变化时对比用）。
        tlsPort: tlsPort > 0 && tlsServer ? tlsPort : null,
        certFingerprint: certFingerprint || null,
        dshPort: dshPort,
        version: BRIDGE_VERSION,
        time: new Date().toISOString()
      });
      return;
    }

    // 2. 扫码配对：二维码 / 兜底 JSON
    //
    // [feat 2026-10-12] 安全模型：二维码内容是**一次性 6 位配对码**（复用现有
    // pairSession 体系），绝不内嵌长期 token —— 屏幕上的二维码会被拍照/截图留存，
    // 嵌入长期 token 等于把凭据印在纸上。手机扫到码后仍要走 /__mobile/pair
    // 换取真正的设备 token，5 次错码作废、10 分钟过期逻辑全部沿用。
    //
    // [fix 2026-10-17] 配对码铸造不再零门槛：这两条路由此前在鉴权门前可无限
    // 自助发码，公网部署下等于"任何能连到网关的人自己发码再自己兑" —— 5 次
    // 错码锁定保护的是猜码，管不住自助发码。新规则（二选一满足即可）：
    //   a) 请求带有效 admin/设备 token（电脑端扫码页本来就持有）；
    //   b) 无 token 时仅当来源是私网（RFC1918/loopback）才放行 —— 局域网
    //      配对是主用法；公网来源一律 403，提示走设置页生成。
    const pairMintAllowed = () => {
      const auth = authenticateRequest(req, parsedUrl);
      if (auth.ok) return { ok: true };
      const ip = req.socket?.remoteAddress || '';
      const isPrivate =
        ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1' ||
        ip.startsWith('::ffff:10.') || ip.startsWith('10.') ||
        ip.startsWith('::ffff:192.168.') || ip.startsWith('192.168.') ||
        /^(::ffff:)?172\.(1[6-9]|2\d|3[01])\./.test(ip);
      return isPrivate
        ? { ok: true }
        : { ok: false, reason: '配对码只对本机/局域网来源开放；远程请先在电脑端 DSH 设置页生成配对码' };
    };
    if ((pathname === '/pair/qr' || pathname === '/api/mobile/pair/qr') && req.method === 'GET') {
      const mint = pairMintAllowed();
      if (!mint.ok) {
        audit('pair/qr-denied', { ip: req.socket?.remoteAddress });
        sendJson(403, { ok: false, error: mint.reason });
        return;
      }
      // 生成一枚新配对码，等价于设置页点了一次"生成配对码"。
      const code = newPairCode();
      const expiresAt = Date.now() + pairCodeTtlMs();
      pairSession = { code, expiresAt };
      audit('pair/qr-generated', { expiresAt, ip: req.socket?.remoteAddress });

      // 本机非内部 IPv4 列表：手机在局域网内需要知道打哪个地址。
      const hosts = [];
      for (const list of Object.values(os.networkInterfaces())) {
        for (const ni of list || []) {
          if (ni.family === 'IPv4' && !ni.internal) hosts.push(ni.address);
        }
      }
      // [fix 2026-10-12] 配置了 nps 公网地址时它优先 —— 扫码的手机多半在外面。
      const cfgForPair = loadConfig();
      const pairPublicHost = (cfgForPair.npsHost || '').trim();
      const pairPublicPort = Number(cfgForPair.npsPort) || listenPort;
      const pairPrimaryHost = pairPublicHost || hosts[0] || '';
      const payload = {
        v: 1,
        hosts: [pairPrimaryHost, ...hosts].filter(Boolean),
        host: pairPrimaryHost,
        port: pairPublicHost ? pairPublicPort : listenPort,
        publicHost: pairPublicHost || null,
        publicPort: pairPublicHost ? pairPublicPort : null,
        lanHosts: hosts,
        pairCode: code,
        // [v1.35 / 1.3] 自签证书指纹：App 首次连接按 TOFU 记住它，之后指纹
        // 变化必须由用户确认（lib/services/cert_trust.dart）。空串表示本机
        // 证书不可用，App 应回落到「跳过校验并提示」而不是拒连。
        certFingerprint,
        name: os.hostname()
      };

      // 依赖纯 JS 的 `qrcode` 包（无原生模块）。装不了时退化为 JSON，
      // 让客户端自己显示 6 位数字配对码（见 GET /pair/info）。
      let png = null;
      try {
        const { createRequire } = await import('node:module');
        const require_ = createRequire(import.meta.url);
        png = await require_('qrcode').toBuffer(JSON.stringify(payload), {
          type: 'png', width: 360, margin: 2
        });
      } catch (e) {
        logger.warn('dsh-mobile-bridge: qrcode 包不可用，回退 JSON:', e?.message || e);
      }

      if (png) {
        res.writeHead(200, {
          'Content-Type': 'image/png',
          'Content-Length': png.length,
          'Cache-Control': 'no-store'
        });
        res.end(png);
      } else {
        sendJson(200, { ...payload, error: 'qrcode-unavailable', hint: '本机缺少 qrcode 包，请改用 GET /pair/info 手动输入配对码' });
      }
      return;
    }

    if ((pathname === '/pair/info' || pathname === '/api/mobile/pair/info') && req.method === 'GET') {
      // [fix 2026-10-17] 与 /pair/qr 同一把闸：公网无 token 来源不发码。
      const mintInfo = pairMintAllowed();
      if (!mintInfo.ok) {
        audit('pair/info-denied', { ip: req.socket?.remoteAddress });
        sendJson(403, { ok: false, error: mintInfo.reason });
        return;
      }
      // 兜底：不依赖 qrcode 包的 JSON 形态，App 显示 6 位数字码供手工输入。
      const code = newPairCode();
      const expiresAt = Date.now() + pairCodeTtlMs();
      pairSession = { code, expiresAt };
      audit('pair/info-generated', { expiresAt, ip: req.socket?.remoteAddress });
      const hosts = [];
      for (const list of Object.values(os.networkInterfaces())) {
        for (const ni of list || []) {
          if (ni.family === 'IPv4' && !ni.internal) hosts.push(ni.address);
        }
      }
      // [fix 2026-10-12] 与 /pair/qr 同步：配置了 nps 公网地址时它优先。
      const cfgForInfo = loadConfig();
      const infoPublicHost = (cfgForInfo.npsHost || '').trim();
      const infoPublicPort = Number(cfgForInfo.npsPort) || listenPort;
      const infoPrimaryHost = infoPublicHost || hosts[0] || '';
      sendJson(200, {
        v: 1,
        hosts: [infoPrimaryHost, ...hosts].filter(Boolean),
        host: infoPrimaryHost,
        port: infoPublicHost ? infoPublicPort : listenPort,
        publicHost: infoPublicHost || null,
        publicPort: infoPublicHost ? infoPublicPort : null,
        lanHosts: hosts,
        pairCode: code,
        // [v1.35 / 1.3] 与 /pair/qr 同一口径（TOFU 用）。
        certFingerprint,
        name: os.hostname(), expiresAt
      });
      return;
    }

    // 3a. 生成配对码（供 DSH 设置页 / 运维调用，短期有效）
    if ((pathname === '/__mobile/pair/code' || pathname === '/api/mobile/pair/code') && req.method === 'POST') {
      // Already authenticated above? No — this route sits before the auth block,
      // so require the shared token explicitly.
      const authOk = authenticateRequest(req, parsedUrl);
      if (!authOk.ok) {
        sendJson(401, { ok: false, error: 'Unauthorized' });
        return;
      }
      const code = newPairCode();
      const expiresAt = Date.now() + pairCodeTtlMs();
      pairSession = { code, expiresAt };
      audit('pair/code-generated', { expiresAt });
      sendJson(200, { ok: true, code, expiresAt, ttlMs: pairCodeTtlMs() });
      return;
    }

    // 3. 手机配对接口
    if (pathname === '/__mobile/pair' && req.method === 'POST') {
      const cl = parseInt(req.headers['content-length'], 10);
      if (!isNaN(cl) && cl > MAX_BODY_SIZE) {
        sendJson(413, { error: 'Payload Too Large: Request body exceeds 2MB limit' });
        req.on('data', () => {});
        req.resume();
        res.on('finish', () => { setTimeout(() => { try { req.destroy(); } catch (_) {} }, 50); });
        return;
      }
      let body = '';
      let bytesRecv = 0;
      let aborted = false;
      req.on('data', chunk => {
        if (aborted) return;
        bytesRecv += chunk.length;
        if (bytesRecv > MAX_BODY_SIZE) {
          aborted = true;
          sendJson(413, { error: 'Payload Too Large: Request body exceeds 2MB limit' });
          req.on('data', () => {});
          req.resume();
          res.on('finish', () => { setTimeout(() => { try { req.destroy(); } catch (_) {} }, 50); });
          return;
        }
        body += chunk;
      });
      req.on('end', () => {
        if (aborted) return;
        try {
          const { code, name: clientName, platform } = JSON.parse(body || '{}');
          if (!pairSession || !pairSession.code || pairSession.expiresAt < Date.now()) {
            sendJson(400, { ok: false, error: '配对码已失效或未生成，请在 DSH 设置页重新生成' });
            return;
          }
          if (String(code).trim() !== String(pairSession.code).trim()) {
            // Brute-force guard: a 6-digit code with a 10-minute TTL and no
            // attempt limit could be exhausted from the same network within
            // the window. 5 misses burn the code; a new one must be minted.
            pairSession.attempts = (pairSession.attempts || 0) + 1;
            if (pairSession.attempts >= 5) {
              pairSession = null;
              audit('pair/bruteforce-burned', { ip: req.socket?.remoteAddress });
              sendJson(400, { ok: false, error: '配对码已因多次错误被作废，请重新生成' });
              return;
            }
            sendJson(400, { ok: false, error: `配对码错误，请核对电脑设置页中的 6 位数字（剩余 ${5 - pairSession.attempts} 次机会）` });
            return;
          }

          pairSession = null;
          const token = newToken();
          const deviceId = 'dev_' + crypto.randomUUID().slice(0, 8);
          const state = loadDevices();
          state.devices.push({
            id: deviceId,
            name: clientName || `移动设备 (${platform || 'Android'})`,
            tokenHash: hashToken(token),
            role: 'readwrite',
            platform: platform || 'android',
            createdAt: Date.now(),
            lastSeenAt: Date.now(),
            lastIp: req.socket?.remoteAddress || '',
            connectCount: 1,
            revoked: false
          });
          saveDevices(state);

          audit('pair/success', { deviceId, name: clientName });
          sendJson(200, {
            ok: true,
            code: 0,
            token,
            deviceId,
            dshPort,
            bridgePort: listenPort,
            version: BRIDGE_VERSION
          });
        } catch (e) {
          sendJson(500, { ok: false, error: e?.message || '配对处理失败' });
        }
      });
      return;
    }

    // 4. REST 业务接口鉴权
    //
    // A single shared token with no rate limit is brute-forceable at whatever
    // rate the network allows, so a failing caller is backed off per IP before
    // the check even runs. checkAuthBackoff first, verifyToken second, note /
    // clear after.
    const backoff = checkAuthBackoff(req);
    if (backoff.blocked) {
      res.setHeader('Retry-After', String(Math.ceil(backoff.retryAfterMs / 1000)));
      sendJson(429, {
        ok: false,
        code: 429,
        error: '认证失败次数过多，请稍后再试',
        retryAfterMs: backoff.retryAfterMs
      });
      audit('auth/backoff-blocked', { path: pathname, retryAfterMs: backoff.retryAfterMs });
      return;
    }

    const auth = authenticateRequest(req, parsedUrl);
    if (!auth.ok) {
      noteAuthFailure(req);
      // [feat 2026-10-12] 若曾以某设备 token 认证、但该设备已被撤销，明确回
      // device_revoked，客户端据此清除本地凭据回到配对页，而不是笼统的"token 错误"。
      const presented = extractToken(req, parsedUrl);
      const prevDev = presented ? findDeviceByToken(presented) : null;
      if (prevDev) {
        sendJson(401, {
          ok: false, code: 401, error: 'Unauthorized',
          code2: 'device_revoked',
          device_revoked: true,
          deviceId: prevDev.id,
          message: '电脑端已移除此设备'
        });
        return;
      }
      sendJson(401, { error: 'Unauthorized', message: '缺少有效令牌或设备未配对' });
      return;
    }
    clearAuthFailures(req);
    // Keep the device's lastSeenAt fresh so the settings page can show real usage.
    if (auth.device?.id && auth.device.id !== 'admin') touchDevice(auth.device.id, req.socket?.remoteAddress || '');

    // Read-only device gate.
    //
    // [fix 2026-10-17] **反转为 deny-by-default**。旧模型是 WRITE_PATHS 白名单
    // 枚举"哪些 POST 是写"，新增路由一旦忘了登记就给 readonly 放行 —— 历史上
    // 已经漏过三轮（workspaces/create / approval-presets/save|delete /
    // push/auto-topic / quick-commands/run / goals/create|edit / sessions/fork
    // 全部在名单外）。新模型：POST/PUT **一律视为写**、拒绝 readonly，除非
    // 路径在显式的 READONLY_ALLOWED_POST 例外表里（只读的 POST 极少）。
    const READONLY_ALLOWED_POST = new Set([
      // 目前确认对只读无害的 POST（逐条审过才加）：
      // （暂无 —— 全部 POST 路由要么改状态、要么消耗宿主资源。要加先在这里登记理由。）
    ]);
    if ((req.method === 'POST' || req.method === 'PUT') && !roleCanWrite(auth.device?.role)) {
      if (!READONLY_ALLOWED_POST.has(pathname)) {
        sendJson(403, { ok: false, code: 403, error: '该设备为只读角色，无权执行写操作' });
        audit('auth/readonly-denied', { path: pathname, device: auth.device?.id, role: auth.device?.role });
        return;
      }
    }

    /* ---- 兼容端点：隧道手动控制（只对 provider=cloudflared 有意义）----
     *
     * 「远程接入」的权威入口是 `GET/POST /api/mobile/remote-access`（在 jsonBody
     * 解析之后注册 —— POST 要用 body）。这里只留两条手动控制，供排障时重连。
     */
    if ((pathname === '/api/mobile/tunnel' || pathname === '/tunnel') && req.method === 'GET') {
      sendJson(200, tunnelPayload());
      return;
    }
    if (pathname === '/api/mobile/tunnel/start' && req.method === 'POST') {
      const provider = loadConfig().remoteAccess?.provider || 'none';
      if (provider !== 'cloudflared') {
        sendJson(409, {
          ok: false,
          code: 'provider-not-managed',
          error: `当前远程通道是 ${provider}，cloudflared 不参与（严格互斥）。改 provider 请用 POST /api/mobile/remote-access`,
          state: remoteAccessPayload()
        });
        return;
      }
      const started = await startQuickTunnel();
      if (started.ok) {
        sendJson(200, tunnelPayload());
      } else if (started.code === 'tls-disabled') {
        // 409 = 当前配置不让做这件事（而不是"做了但失败了"）。
        sendJson(409, { ok: false, code: started.code, error: started.error });
      } else {
        sendJson(500, {
          ok: false,
          status: 'failed',
          error: started.error,
          hint: '可手动安装 cloudflared 后重试，或改用 Tailscale/自有反代'
        });
      }
      return;
    }
    if (pathname === '/api/mobile/tunnel/stop' && req.method === 'POST') {
      // 注意：这里**不改 provider**。停进程只是"暂时断开"，状态会如实显示
      // ready:false；真正关掉远程访问是把 provider 改成 none / nps。
      quickTunnel?.stop();
      audit('tunnel/stop', { reason: 'manual' });
      sendJson(200, tunnelPayload());
      return;
    }

  /* ------------------------------------------------------------------ *
   * 附件上传与读取（v1.10.0）
   * ------------------------------------------------------------------ */
    //
    // 这两条必须在下面的 jsonBody 读取**之前**处理：上传是原始字节流，而那个
    // 读取器有 2MB 上限且按 JSON 解析。

    // ---- 上传 ----
    //
    // 引擎契约见 uploadFileToEngine 的注释。这里只做三件事：限长收字节、
    // 原样转发、把 receiptId 交回给 App。
    if (pathname === '/api/mobile/upload' && req.method === 'POST') {
      const upSessionId = String(parsedUrl.query?.sessionId || '').trim();
      const upName = parsedUrl.query?.name ? String(parsedUrl.query.name) : '';
      if (!upSessionId) {
        sendJson(400, { ok: false, error: 'sessionId is required' });
        return;
      }

      // 频率限制：每来源 60 秒内最多 10 次上传。单次上限 32MB 是大小限制，
      // 不是频率限制 —— 没有这层，一个循环脚本能以 32MB/次的速率刷引擎磁盘。
      const uploadKey = auth.device?.id || req.socket?.remoteAddress || 'anon';
      const nowMs = Date.now();
      let bucket = uploadBuckets.get(uploadKey);
      if (!bucket || nowMs - bucket.windowStart > 60000) {
        bucket = { windowStart: nowMs, count: 0 };
        uploadBuckets.set(uploadKey, bucket);
      }
      bucket.count++;
      if (bucket.count > 10) {
        sendJson(429, { ok: false, error: '上传太频繁，请稍后再试' });
        audit('upload/rate-limited', { device: uploadKey });
        return;
      }

      let buf;
      try {
        buf = await new Promise((resolve, reject) => {
          const chunks = [];
          let size = 0;
          req.on('data', (c) => {
            size += c.length;
            if (size > MAX_UPLOAD_BYTES) {
              // 超限立刻断开，不要等收完整个文件再拒绝：那是实打实的无用上行。
              reject(Object.assign(new Error('upload too large'), { tooLarge: true }));
              try { req.destroy(); } catch (_) {}
              return;
            }
            chunks.push(c);
          });
          req.on('end', () => resolve(Buffer.concat(chunks)));
          req.on('error', reject);
        });
      } catch (e) {
        if (e?.tooLarge) {
          try { sendJson(413, { ok: false, error: `文件超过上限 ${Math.round(MAX_UPLOAD_BYTES / 1048576)}MB` }); } catch (_) {}
        } else {
          try { sendJson(400, { ok: false, error: '上传过程中连接中断' }); } catch (_) {}
        }
        return;
      }

      if (!buf || buf.length === 0) {
        sendJson(400, { ok: false, error: '空文件' });
        return;
      }

      try {
        const value = await uploadFileToEngine({ sessionId: upSessionId, name: upName, data: buf });
        audit('upload/ok', { sessionId: upSessionId, name: upName, size: buf.length });
        sendJson(200, {
          ok: true,
          code: 0,
          receiptId: value.receiptId,
          file: value.file,
          name: upName,
          size: buf.length
        });
      } catch (e) {
        audit('upload/failed', { sessionId: upSessionId, name: upName, size: buf.length, message: e?.message });
        sendJson(502, { ok: false, error: e?.message || '上传到引擎失败' });
      }
      return;
    }

    // ---- 读取 ----
    //
    // App 侧的 AttachmentImageTile 一直在请求 /api/mobile/attachment?id=…，
    // 但这个路由**此前根本不存在** —— 所以即使上传成功，图片也显示不出来（404）。
    // 补上它，图片显示才闭环。
    //
    // 引擎的 session/attachment RPC 需要 sessionId 做授权（它只允许读这个会话
    // 真正引用过的图片），因此 App 必须把 sessionId 一起带上。
      if (pathname === '/api/mobile/attachment' && req.method === 'GET') {
      // [fix 2026-10-17] 频率桶（与 upload 同款）：32MB 附件经 RPC base64 返回，
      // 峰值内存约 3 倍——已认证客户端无限频循环请求可把 dsh web 堆压向 OOM。
      // 60s / 30 次：正常图片列表加载绰绰有余，脚本式循环会被 429。
      {
        const attachKey = `attachment:${auth.device?.id || req.socket?.remoteAddress || 'anon'}`;
        const nowMs = Date.now();
        let bucket = uploadBuckets.get(attachKey);
        if (!bucket || nowMs - bucket.windowStart > 60000) {
          bucket = { windowStart: nowMs, count: 0 };
          uploadBuckets.set(attachKey, bucket);
        }
        bucket.count++;
        if (bucket.count > 30) {
          sendJson(429, { ok: false, error: '请求过于频繁，稍后再试' });
          audit('attachment/rate-limited', { device: attachKey });
          return;
        }
      }
      const attId = String(parsedUrl.query?.id || '').trim();
      const attSession = String(parsedUrl.query?.sessionId || '').trim();
      if (!attId) {
        sendJson(400, { ok: false, error: 'id is required' });
        return;
      }
      if (!attSession) {
        sendJson(400, { ok: false, error: 'sessionId is required' });
        return;
      }
      try {
        const value = await callDshRpc('session/attachment', {
          args: { request: { sessionId: attSession, attachmentId: attId } }
        });
        const mediaType = value?.attachment?.mediaType || 'application/octet-stream';
        const bytes = Buffer.from(String(value?.data || ''), 'base64');
        if (bytes.length === 0) {
          sendJson(404, { ok: false, error: '附件内容为空' });
          return;
        }
        res.writeHead(200, {
          'Content-Type': mediaType,
          'Content-Length': bytes.length,
          'Cache-Control': 'private, max-age=3600'
        });
        res.end(bytes);
      } catch (e) {
        sendJson(404, { ok: false, error: e?.message || '附件读取失败' });
      }
      return;
    }

    let jsonBody = {};
    if (req.method === 'POST' || req.method === 'PUT') {
      // Body buffering with the 2MB cap lives in core; on overflow it answers 413
      // and destroys the socket only after the response flushes, so the client
      // sees 413 instead of ECONNRESET.
      let raw;
      try {
        raw = await readBodyWithLimit(req, res, { sendJson });
      } catch (err) {
        if (err?.aborted || res.headersSent) return;
        // [P0 availability] Do NOT rethrow here.
        //
        // core.mjs's readBodyWithLimit rejects socket errors from
        // `req.on('error', (err) => reject(err))` WITHOUT setting aborted:true,
        // so the guard above does not catch them. This `throw err` sits outside
        // the business try block that starts a few lines below (whose catch is
        // ~350 lines further down), so it escaped the async request handler
        // entirely and surfaced as an unhandledRejection. There is no
        // process.on('unhandledRejection') anywhere in this file, and Node >= 15
        // defaults to --unhandled-rejections=throw, which terminates the
        // process.
        //
        // Because this gateway runs INSIDE the dsh web process, that meant a
        // single dropped mobile upload — a phone losing Wi-Fi mid-POST, a
        // carrier NAT timeout, an abrupt TCP RST — took the whole engine down
        // with it, killing every active session. No attacker required.
        //
        // A truncated or unreadable body is a client error: answer 400 and move
        // on. sendJson is itself guarded because the socket is often already
        // gone by the time we get here.
        try {
          sendJson(400, { error: 'Bad Request', message: '请求体读取失败或连接已中断' });
        } catch { /* socket already gone */ }
        audit('http/body-read-failed', {
          path: pathname,
          method: req.method,
          message: err?.message,
          code: err?.code
        });
        return;
      }
      jsonBody = parseJsonBody(raw);
    }


    try {
      // [refactor 2026-10-21] 「远程接入」统一状态与切换。
      //
      // NPS 与 cloudflared 是**同一职责的两种 provider**（让手机从公网到达本机），
      // 严格互斥：同一时刻只有一条公网出口。客户端只需要读「现在走哪条、地址是
      // 什么、就绪了吗、为什么没就绪」，不需要知道进程怎么起。
      //
      // ⚠️ 这两条必须放在 `jsonBody` 解析**之后**（POST 要用它）。放在前面会命中
      // TDZ：`Cannot access 'jsonBody' before initialization`，请求永不返回。
      if (pathname === '/api/mobile/remote-access' && req.method === 'GET') {
        sendJson(200, remoteAccessPayload());
        return;
      }
      if (pathname === '/api/mobile/remote-access' && req.method === 'POST') {
        const body = jsonBody || {};
        const provider = String(body.provider || '').trim().toLowerCase();
        if (!REMOTE_PROVIDERS.includes(provider)) {
          sendJson(400, {
            ok: false,
            error: `provider 必须是 ${REMOTE_PROVIDERS.join(' / ')}`
          });
          return;
        }
        const patch = { remoteAccess: { provider } };
        if (body.nps && typeof body.nps === 'object') patch.remoteAccess.nps = body.nps;
        if (provider === 'nps') {
          const host = String(
            (body.nps && body.nps.host) || loadConfig().remoteAccess.nps.host || ''
          ).trim();
          if (!host) {
            sendJson(400, { ok: false, error: 'provider=nps 需要提供 nps.host' });
            return;
          }
        }
        const saved = saveConfig(patch);
        audit('remote-access/set', {
          provider: saved.remoteAccess.provider,
          npsHost: saved.remoteAccess.nps.host || undefined
        });
        // 互斥在这里落地：改完配置要立刻对进程生效，否则会出现"界面说走 NPS，
        // cloudflared 还在后台占着一条公网隧道"。
        //
        // ⚠️ **不能 await**：切到 cloudflared 时这一步会去下载 60MB 的二进制
        // （首次），await 等于让"点一下切换"卡几分钟。切换只负责落配置与发起，
        // 是否就绪由 GET 的 ready/reason 如实反映。
        reconcileRemoteAccess().catch((err) => {
          logger.warn('[dsh-mobile-bridge] 远程接入对账失败: %s', err?.message ?? err);
        });
        sendJson(200, remoteAccessPayload());
        return;
      }

      // [v1.35 / 3.3] 告警收件箱
      if (pathname === '/api/mobile/alerts' && req.method === 'GET') {
        sendJson(200, {
          ok: true,
          alerts: alertEngine.list(),
          unread: alertEngine.unreadCount
        });
        return;
      }
      if (pathname === '/api/mobile/alerts/read' && req.method === 'POST') {
        const payload = jsonBody || {};
        const changed = alertEngine.markRead(
          Array.isArray(payload.ids) ? payload.ids.map(String) : [],
          { all: payload.all === true }
        );
        sendJson(200, { ok: true, changed, unread: alertEngine.unreadCount });
        return;
      }

      // [v1.35 / 3.1] Runbook：手机上一键执行电脑上写好的排障命令。
      // 执行走 host-ops 的既有执行器（无 shell、有超时与输出上限），
      // 命令本身在 runbook.mjs 里过白名单与元字符检查。
      if (pathname === '/api/mobile/runbooks' && req.method === 'GET') {
        const loaded = loadRunbooksFile(runbookFile, {
          parseYaml: (text) => YAML.parse(text),
          allowedBinaries: allowedBinariesFromEnv()
        });
        sendJson(200, {
          ok: loaded.ok !== false,
          runbooks: (loaded.entries || []).map((e) => ({
            id: e.id,
            name: e.name,
            description: e.description,
            command: e.command,
            danger: e.danger,
            confirmRequired: e.confirmRequired,
            outputTail: e.outputTail
          })),
          errors: loaded.errors || [],
          error: loaded.error || null
        });
        return;
      }

      if (pathname === '/api/mobile/runbooks/run' && req.method === 'POST') {
        const payload = jsonBody || {};
        const wanted = String(payload.id || '').trim();
        if (!wanted) {
          sendJson(400, { ok: false, error: '缺少 id' });
          return;
        }
        const loaded = loadRunbooksFile(runbookFile, {
          parseYaml: (text) => YAML.parse(text),
          allowedBinaries: allowedBinariesFromEnv()
        });
        if (loaded.ok === false && !(loaded.entries || []).length) {
          sendJson(500, { ok: false, error: loaded.error || 'Runbook 不可用' });
          return;
        }
        const entry = (loaded.entries || []).find((e) => e.id === wanted || e.name === wanted);
        if (!entry) {
          sendJson(404, { ok: false, error: '没有这条 Runbook' });
          return;
        }
        // 高危条目必须显式确认：App 侧弹窗后把 confirm:true 带上来。
        if (entry.confirmRequired && payload.confirm !== true) {
          sendJson(409, {
            ok: false,
            code: 'confirm-required',
            error: '这条命令需要二次确认',
            entry: { id: entry.id, name: entry.name, command: entry.command, danger: entry.danger }
          });
          return;
        }

        const sessionId = String(payload.sessionId || '').trim();
        const cwd = (sessionId && readSessionCwd(sessionId)) || dshHomeDir;
        const result = await runRunbook(cwd, entry, {
          run: runQuickCommand,
          timeoutMs: 20000,
          maxBytes: 256 * 1024
        });
        audit('runbook/run', {
          id: entry.id,
          name: entry.name,
          ok: result.ok,
          exitCode: result.exitCode ?? null
        });
        sendJson(200, {
          ok: result.ok,
          code: result.error || null,
          exitCode: result.exitCode ?? null,
          timedOut: result.timedOut === true,
          durationMs: result.durationMs ?? null,
          outputTail: result.outputTail ?? '',
          truncated: result.truncated === true,
          entry: { id: entry.id, name: entry.name, command: entry.command }
        });
        return;
      }

      // [v1.35 / 2.1] 通知栏一键审批。必须在 jsonBody 解析之后注册。
      // 只读设备由上面的 deny-by-default 闸门挡住（POST 一律拒绝）。
      if (pathname === '/api/mobile/approvals/decide' && req.method === 'POST') {
        const payload = jsonBody || {};
        const out = await decideApproval({
          approvalId: payload.approvalId || payload.eventId || '',
          decision: payload.decision || '',
          token: payload.approvalToken || '',
          reason: payload.reason || ''
        });
        audit('approval/decide', {
          approvalId: String(payload.approvalId || payload.eventId || '').slice(0, 64),
          decision: String(payload.decision || '').slice(0, 16),
          code: out.body.code
        });
        sendJson(out.status, out.body);
        return;
      }

      // 4.0 设备管理（v1.15）：列表 + 撤销
      //
      // [feat 2026-10-12] 撤销要求 write/admin（走 WRITE_PATHS 同款 roleCanWrite
      // 判断 —— revoke 已加入 WRITE_PATHS），列表 read 即可。撤销时向其余在线
      // 客户端广播 device_revoked，让电脑端 UI 即时刷新设备列表。
      if ((pathname === '/api/mobile/devices' || pathname === '/__mobile/devices') && req.method === 'GET') {
        const state = loadDevices();
        // 撤销是打 revoked 标记而非删行（认证路径要反查 token→设备），列表只展示还活着的设备。
        const devices = state.devices.filter((d) => d.revoked !== true).map((d) => ({
          id: d.id,
          name: d.name,
          role: d.role || 'readwrite',
          platform: d.platform || '',
          createdAt: d.createdAt,
          lastSeenAt: d.lastSeenAt,
          lastIp: d.lastIp || '',
          connectCount: d.connectCount || 0
          // tokenHash 故意不下发 —— 客户端永远不该拿到哪怕摘要形式的凭据。
        }));
        sendJson(200, { ok: true, code: 0, devices });
        return;
      }

      if ((pathname === '/api/mobile/devices/revoke' || pathname === '/__mobile/devices/revoke') && req.method === 'POST') {
        const deviceId = String(jsonBody.deviceId || '').trim();
        if (!deviceId) {
          sendJson(400, { ok: false, error: 'deviceId is required' });
          return;
        }
        if (deviceId === auth.device?.id && auth.device?.id !== 'admin') {
          sendJson(400, { ok: false, error: '不能撤销当前正在使用的设备本身' });
          return;
        }
        const ok = revokeDevice(deviceId);
        if (!ok) {
          sendJson(404, { ok: false, error: '设备不存在或已移除', deviceId });
          return;
        }
        audit('device/revoked', { deviceId, by: auth.device?.id || 'admin', ip: req.socket?.remoteAddress });
        broadcastToMobileClients({ type: 'device_revoked', deviceId });
        sendJson(200, { ok: true, code: 0, deviceId, message: '设备已移除' });
        return;
      }

      // 4.1 工作区与会话
      //
      // [feat 2026-10-17] 新增工作区。
      //
      // 工作区在引擎里就是 `~/.dsh/storages/workspace.json` 的一张表：
      //   tables.workspaces[wsId] = { path, title, sessionIds[], createdAt, updatedAt }
      // 所以"新建"= 建目录（不存在时）+ 加一行。读改写而不是整体覆盖，避免把
      // 引擎刚写进去的 sessionIds 冲掉；同一个路径重复创建视为幂等，返回已有条目
      // —— 用户手滑点两次不该得到两个同名工作区。
      if (pathname === '/api/mobile/workspaces/create' && req.method === 'POST') {
        // `jsonBody` 是上面统一解析好的（畸形 JSON 在那里就已经被拒了）。
        const body = jsonBody || {};
        const rawPath = String(body.path || '').trim();
        if (!rawPath) {
          sendJson(400, { ok: false, error: 'path is required' });
          return;
        }
        const resolvedPath = path.resolve(rawPath);
        const title = String(body.title || '').trim() || path.basename(resolvedPath);

        const workspaceJsonPath = path.join(dshHomeDir, 'storages', 'workspace.json');
        let rawWs = { tables: { workspaces: {} }, global: {} };
        if (fs.existsSync(workspaceJsonPath)) {
          try {
            rawWs = JSON.parse(fs.readFileSync(workspaceJsonPath, 'utf8'));
          } catch (e) {
            sendJson(500, { ok: false, error: `workspace.json 解析失败：${e.message}` });
            return;
          }
        }
        if (!rawWs.tables) rawWs.tables = {};
        if (!rawWs.tables.workspaces) rawWs.tables.workspaces = {};
        const table = rawWs.tables.workspaces;

        // 幂等：同一路径已经登记过就直接返回它。
        for (const [id, info] of Object.entries(table)) {
          if (info && typeof info.path === 'string' &&
              path.resolve(info.path).toLowerCase() === resolvedPath.toLowerCase()) {
            sendJson(200, {
              ok: true,
              workspaceId: id,
              path: info.path,
              title: info.title || title,
              existed: true,
            });
            return;
          }
        }

        try {
          fs.mkdirSync(resolvedPath, { recursive: true });
        } catch (e) {
          sendJson(400, { ok: false, error: `目录创建失败：${e.message}` });
          return;
        }

        const now = new Date().toISOString();
        const wsId = crypto.randomUUID();
        table[wsId] = {
          path: resolvedPath,
          title,
          sessionIds: [],
          createdAt: now,
          updatedAt: now,
        };
        try {
          fs.writeFileSync(workspaceJsonPath, JSON.stringify(rawWs, null, 2), 'utf8');
        } catch (e) {
          sendJson(500, { ok: false, error: `workspace.json 写入失败：${e.message}` });
          return;
        }
        audit('workspace/create', { workspaceId: wsId, path: resolvedPath });
        sendJson(200, { ok: true, workspaceId: wsId, path: resolvedPath, title, existed: false });
        return;
      }

      if (pathname === '/api/mobile/workspaces' && req.method === 'GET') {
        // ?archived=exclude|only|include. Anything else — a missing value, a typo,
        // or a repeated param (which url.parse turns into an array) — normalises to
        // 'exclude', i.e. the historical behaviour.
        const rawArchived = parsedUrl.query?.archived;
        const archivedMode = (rawArchived === 'only' || rawArchived === 'include') ? rawArchived : 'exclude';
        const data = getWorkspacesData({ archived: archivedMode });
        // archivedMode is echoed back on purpose: it is how the client distinguishes
        // "the gateway applied my filter" from "the gateway predates this feature and
        // silently ignored the param". Without the echo, an old gateway answering
        // ?archived=only would return the UNarchived list and the app would label
        // those rows as archived — actively wrong rather than visibly unsupported.
        sendJson(200, { ok: true, code: 0, workspaces: data, archivedMode: archivedMode });
        return;
      }

      // ---- 智能体团队 / 子代理列表（[feat 2026-10-17]）----
      //
      // 这两个 GET 以前**根本不存在**：App 侧早就写好了面板（团队 / 子代理两块），
      // 但请求打过来 404，于是永远显示"状态未知"或整块不渲染 —— 用户实测"我这
      // 会话明明有 8 个子智能体，App 里一个都没有"。
      //
      // 数据源是引擎的**投影缓存**，不额外打引擎 RPC：
      //   * 团队  → rows.agentTeam.val（members / tasks）
      //   * 子代理 → rows.subagentCatalog.val.head.values（childId / mode / label）
      // 两者都是引擎自己写下的快照，所以 `source: 'cache'` 要如实回给客户端。
      //
      // ⚠️ 与下面的 `/api/mobile/sessions/` 通配路由抢路径，必须排在它**之前**。
      if (pathname === '/api/mobile/sessions/team' && req.method === 'GET') {
        const sessionId = String(parsedUrl.query?.sessionId || '').trim();
        if (!sessionId) {
          sendJson(400, { ok: false, error: 'sessionId is required' });
          return;
        }
        const rows = readProjectionRows(sessionId);
        if (!rows) {
          // 读不到投影 ≠ 没有团队。503 让客户端说"状态未知"，而不是编一个空团队。
          sendJson(503, { ok: false, error: '投影缓存里没有这个会话（引擎可能没在跑，或会话未落盘）' });
          return;
        }
        const team = rows.agentTeam && rows.agentTeam.val;
        if (!team) {
          // 引擎没启用团队能力：supported=false 让面板说清"不是你没有团队"。
          sendJson(200, { ok: true, supported: false, members: [], tasks: [], source: 'cache' });
          return;
        }
        const title = (rows.title && rows.title.val) || '';
        const rawMembers = Array.isArray(team.members) ? team.members : [];
        const members = [{
          // Lead 就是当前会话本身。引擎的 agentTeam 只存队友，但 App 的模型是
          // "Lead + 队友"—— 这条 Lead 不是编的，它就是这个 sessionId。
          id: sessionId,
          name: title || 'Lead',
          role: 'lead',
          phase: 'active',
          error: '',
        }];
        for (const m of rawMembers) {
          const memberId = String(m.id || m.sessionId || '');
          // [fix 2026-10-17] 成员状态不能直接用 `m.phase`。
          //
          // 引擎的 `agentTeam.members[].phase` 是**出生状态**：队友 spawn 出来之后
          // 一直是 'active'，跑完了也不改。于是手机端永远显示"进行中"，而 Web 端
          // 显示"已完成" —— 两边看的是不同字段（用户实测反馈）。
          //
          // 真正的进度在**子会话自己的投影**里：
          //   * `turnBoundary.openTurnStartSeq != null` → 有未闭合回合 = 还在跑
          //   * `subagentTiming.lastTurnCompleted === true`  → 回合已收口 = 已完成
          let phase = String(m.phase || 'active');
          try {
            const childRows = memberId ? readProjectionRows(memberId) : null;
            if (childRows) {
              const tb = childRows.turnBoundary && childRows.turnBoundary.val;
              const timing = childRows.subagentTiming && childRows.subagentTiming.val;
              if (tb && tb.openTurnStartSeq !== null && tb.openTurnStartSeq !== undefined) {
                phase = 'active';
              } else if (timing && timing.lastTurnCompleted === true) {
                phase = 'done';
              }
            }
          } catch (_) { /* 读不到就保留引擎给的 phase */ }
          members.push({
            id: memberId,
            name: String(m.name || ''),
            role: 'teammate',
            phase,
            error: String(m.error || ''),
          });
        }
        const rawTasks = Array.isArray(team.tasks) ? team.tasks : [];
        const tasks = rawTasks.map((t) => ({
          id: String(t.id || ''),
          revision: Number(t.revision) || 1,
          subject: String(t.subject || ''),
          description: String(t.description || ''),
          status: String(t.status || 'pending'),
          blockedBy: Array.isArray(t.blockedBy) ? t.blockedBy.map(String) : [],
          ownerName: String(t.ownerName || t.owner || ''),
          ready: t.ready === true,
        }));
        sendJson(200, { ok: true, supported: true, source: 'cache', members, tasks });
        return;
      }

      if (pathname === '/api/mobile/sessions/subagents' && req.method === 'GET') {
        const sessionId = String(parsedUrl.query?.sessionId || '').trim();
        if (!sessionId) {
          sendJson(400, { ok: false, error: 'sessionId is required' });
          return;
        }
        const rows = readProjectionRows(sessionId);
        if (!rows) {
          sendJson(503, { ok: false, error: '投影缓存里没有这个会话' });
          return;
        }
        const catalog = rows.subagentCatalog && rows.subagentCatalog.val;
        const children = (catalog && catalog.head && Array.isArray(catalog.head.values))
          ? catalog.head.values
          : [];
        const subagents = children
          .map((c) => {
            const childId = String(c.childId || '');
            if (!childId) return null;
            // activity 只能靠"子会话自己的投影里有没有在跑的回合"来读，读不到就是
            // 'unknown' —— 绝不默认成 'running'（那会让面板显示一排假的绿点）。
            let activity = 'unknown';
            try {
              const childRows = readProjectionRows(childId);
              const boundary = childRows && childRows.turnBoundary && childRows.turnBoundary.val;
              if (boundary && (boundary.running === true || boundary.status === 'running')) {
                activity = 'running';
              } else if (childRows) {
                activity = 'inactive';
              }
            } catch (_) { /* 读不到就保持 unknown */ }
            return {
              id: childId,
              kind: 'child',
              mode: String(c.mode || 'one-shot'),
              label: String(c.label || ''),
              activity,
            };
          })
          .filter(Boolean);
        // 键名是 `entries`：App 侧 `fetchSubagents` 读的就是它（见 dsh_service）。
        sendJson(200, { ok: true, entries: subagents, source: 'cache' });
        return;
      }

      // ---- 跨会话搜索（标题 + 首条 prompt）----
      //
      // ⚠️ 必须排在下面的 startsWith('/api/mobile/sessions/') 通配路由之前：
      // 它也是 GET，晚于通配时 'search' 会被当成 sessionId 送进
      // getSessionHistory，搜索永远返回空历史（这就是"搜索没生效"的根因）。
      if (pathname === '/api/mobile/sessions/search' && req.method === 'GET') {
        const q = String(parsedUrl.query?.q || '').trim();
        if (!q) {
          sendJson(400, { ok: false, error: 'q is required' });
          return;
        }
        const max = Math.min(Number(parsedUrl.query?.limit) || 30, 100);
        const needle = q.toLowerCase();
        const results = [];
        for (const ws of getWorkspacesData({ archived: 'include' })) {
          for (const s of ws.sessions) {
            const title = (s.title || '').toLowerCase();
            const first = (s.firstPrompt || '').toLowerCase();
            if (title.includes(needle) || first.includes(needle)) {
              results.push({
                workspaceId: ws.workspaceId,
                workspaceTitle: ws.title,
                sessionId: s.sessionId,
                title: s.title,
                firstPrompt: s.firstPrompt,
                lastPromptAt: s.lastPromptAt,
                archived: !!s.archived
              });
              if (results.length >= max) break;
            }
          }
          if (results.length >= max) break;
        }
        sendJson(200, { ok: true, code: 0, query: q, results });
        return;
      }

      // ---- v1.14 能力路由（队列/定时/作业/交付物/diff/用量/推送）----
      //
      // ⚠️ 必须排在下面的 startsWith('/api/mobile/sessions/') 通配路由之前。
      //
      // 这个通配分支把 `/api/mobile/sessions/<任意字符串>` 的剩余部分当成
      // sessionId 交给 getSessionHistory()，所以任何注册在该前缀下的 GET 功能
      // 路由都会被它吞掉，而且**吞得不报错**：`GET /api/mobile/sessions/queue`
      // 会返回一份名为 "queue" 的空历史（measured：`{"ok":true,"code":0,
      // "data":{"sessionId":"queue","messages":[]}}`），App 拿不到 `queue` 字段
      // 就当成空数组，于是队列永远显示"没有排队消息"——看起来像正常状态。
      //
      // 上面 `sessions/search` 的注释记过同一个坑（当时是"搜索永远返回空"），
      // 只修了那一条。这里改用**排序**而不是再补一个排除项：功能路由整体前置，
      // 以后往 /api/mobile/sessions/ 下加 GET 路由不会再重蹈覆辙。
      // handleFeatureRoute 未命中时返回 false，落到下面的既有路由与 404。
      if (await handleFeatureRoute({
        pathname,
        req,
        res,
        parsedUrl,
        jsonBody,
        auth,
        sendJson,
        // `sendFile` is deliberately NOT passed: features.mjs imports the real
        // implementation so route tests exercise the actual byte writer. Injecting
        // it here as well created two sources of truth, and the injectable one was
        // stubbed as `async (p, name) => true` -- which is how a 500-on-every-
        // download defect survived a whole release with green tests.
        callDshRpc,
        readStreamOnce,
        // [feat 2026-10-13] sequence collector for `job/follow` (features.mjs),
        // which must consume opened → output → status rather than one frame.
        readStreamFrames,
        readProjections,
        readProjectionRows,
        readSessionRecords,
        readWorkspaceChanges,
        assertSessionId,
        readConfig: loadConfig,
        writeConfig: saveConfig,
        pushTest,
        audit,
        logger,
        // [feat 2026-10-12] diagnostics + subagent/goal/command control deps.
        // All gateway-local state the diagnostics route reads; nothing here can
        // leak a token or a path (features.mjs redacts before answering).
        bridgeVersion: BRIDGE_VERSION,
        mobileClients: connectedClients,
        eventsStreamReady: () => Boolean(currentEventsClientId) && upstreamMuxWs?.readyState === WebSocket.OPEN,
        deviceCount: () => { try { return loadDevices().devices.filter((d) => !d.revoked).length; } catch { return null; } },
        dshHomeDir
      })) {
        return;
      }

      // ---- v1.16 扩展路由（P0/P1，2026-10-13）----
      //
      // 与上面的 features 派发同样的排序约束：必须先于下面的
      // `startsWith('/api/mobile/sessions/')` 通配路由。这里注册了
      // `GET /api/mobile/sessions/checkpoints`，正是会被通配吞掉的形状。
      // handleExtensionRoute 未命中时返回 false，落到既有路由与 404。
      if (await handleExtensionRoute({
        pathname,
        req,
        res,
        parsedUrl,
        jsonBody,
        sendJson,
        audit,
        logger,
        callDshRpc,
        readStreamOnce,
        readStreamFrames,
        readProjections,
        readProjectionRows,
        readSessionCwd,
        readSessionRecords,
        readWorkspaceChanges,
        resolveDeliverableFile,
        readConfig: loadConfig,
        writeConfig: saveConfig,
        assertSessionId
      })) {
        return;
      }

      // The second half of the guard: even if someone moves the feature dispatch
      // back below this branch, a claimed feature route can no longer be stolen
      // by the wildcard (see `claimsMobileFeatureRoute` in features.mjs).
      if (pathname.startsWith('/api/mobile/sessions/') && req.method === 'GET'
          && !claimsMobileFeatureRoute(req.method, pathname)
          && !claimsExtensionRoute(req.method, pathname)) {
        const sessionId = pathname.replace('/api/mobile/sessions/', '').trim();
        const history = await getSessionHistory(sessionId);
        sendJson(200, { ok: true, code: 0, data: history });
        return;
      }

      if (pathname === '/api/mobile/sessions/create' && req.method === 'POST') {
        const requestPayload = {};
        if (jsonBody.workspaceId) requestPayload.workspaceId = jsonBody.workspaceId;
        else if (jsonBody.cwd) requestPayload.cwd = jsonBody.cwd;

        const result = await callDshRpc('session/create', { args: { request: requestPayload } });

        // [fix 2026-10-17] 默认模型兜底注入：客户端在 create 后会自己调
        // sessions/model（主修路径），这里只处理"老客户端 / 客户端没注入"的
        // 情况 —— 带 model 字段时 create 成功后补一次 selectModel RPC。
        // 失败不阻塞建会话：引擎侧兜底仍是全局默认。
        const createModel = String(jsonBody.model || '').trim();
        if (createModel && result?.sessionId) {
          try {
            const resolved = await resolveModelSelection(createModel);
            if (resolved.ok) {
              await callDshRpc('session/selectModel', {
                args: { request: { sessionId: result.sessionId, provider: resolved.provider, model: resolved.model } }
              });
            } else {
              logger.warn('[dsh-mobile-bridge] create 默认模型解析失败 %s: %s', createModel, resolved.error);
            }
          } catch (e) {
            logger.warn('[dsh-mobile-bridge] create 默认模型注入失败: %s', e?.message || e);
          }
        }

        sendJson(200, { ok: true, code: 0, sessionId: result?.sessionId, session: result });
        return;
      }

      if (pathname === '/api/mobile/sessions/prompt' && req.method === 'POST') {
        let rawSessionId = jsonBody.sessionId;
        let promptText = jsonBody.text ?? jsonBody.prompt;
        if (typeof promptText === 'object' && promptText !== null) {
          if (typeof promptText.text === 'string') promptText = promptText.text;
          else if (typeof promptText.content === 'string') promptText = promptText.content;
          else { try { promptText = JSON.stringify(promptText); } catch (_) { promptText = ''; } }
        } else if (promptText != null) {
          promptText = String(promptText);
        } else {
          promptText = '';
        }
        const sessionId = typeof rawSessionId === 'string' ? rawSessionId.trim() : (rawSessionId != null ? String(rawSessionId).trim() : '');
        if (!sessionId) {
          sendJson(400, { error: 'Missing or empty sessionId' });
          return;
        }
        const text = promptText;

        // 附件（v1.10.0）。
        //
        // 引擎的 prompt content 是一个 part 数组，准确形状见
        // PromptContentPart（@deepseek-ai/dsh-api-session-controller 的类型声明）：
        //   { type:'text',  text }
        //   { type:'image', mediaType, data:<base64>, name? }   ← 模型能"看见"的图片
        //   { type:'file',  receiptId }                          ← 上传后换到的凭据
        //
        // 图片走 image part 而不是 file part，是因为只有 image part 会把图片作为
        // 视觉输入交给模型；file part 只是一个文件引用。App 侧已经把图片压到
        // 2MB 以下（JSON 读取器上限），所以可以直接内联 base64。
        const rawAttachments = Array.isArray(jsonBody.attachments) ? jsonBody.attachments : [];
        const attachmentParts = [];
        for (const a of rawAttachments) {
          if (!a || typeof a !== 'object') continue;
          if (a.type === 'image') {
            const mediaType = String(a.mediaType || '');
            const data = String(a.data || '');
            if (!mediaType.startsWith('image/') || !data) continue;
            attachmentParts.push({
              type: 'image',
              mediaType,
              data,
              ...(a.name ? { name: String(a.name) } : {})
            });
          } else if (a.type === 'file') {
            const receiptId = String(a.receiptId || '').trim();
            if (!receiptId) continue;
            attachmentParts.push({ type: 'file', receiptId });
          }
        }

        // 允许"只有附件、没有文字"：引擎的准入规则是"非空白文字**或**一个附件"
        // （commands.js 的 prompt 前置检查），所以这里不能沿用纯文本的必填校验。
        if (!text.trim() && attachmentParts.length === 0) {
          sendJson(400, { error: 'Missing or empty prompt text' });
          return;
        }

        const now = Date.now();
        const recentCancel = coreTurns.getLastCancelTime(sessionId);
        // Turn sequence fencing: if a cancellation was recorded very recently (e.g. within 350ms)
        // for this session due to concurrent prompt/cancel race, treat this prompt as canceled immediately
        if (now - recentCancel < 350) {
          sendJson(200, { ok: true, code: 0, cancelled: true, message: 'Turn was cancelled' });
          return;
        }

        const thisTurnSeq = coreTurns.nextTurnSeq(sessionId);

        // 投递模式（v1.13）：'queue' 排队等这一轮跑完，'steer' 插进正在跑的
        // 回合。引擎自己对空闲会话也接受 'queue'（它会落进 transcript），
        // 所以默认值不变，只有客户端显式要求插话时才换。
        const deliveryMode = jsonBody.mode === 'steer' ? 'steer' : 'queue';

        activePrompts.set(sessionId, now);
        const follower = getSessionFollower(sessionId);
        if (follower) {
          follower.isRunning = true;
          follower.thinkingBuffer = '';
          follower.textBuffer = '';
          follower.tools = [];
          follower.activePromptText = text || '';
          follower.lastUpdated = now;
        }

        broadcastToMobileClients({ type: 'session_status', sessionId, isRunning: true });

        try {
          const promptRes = await callDshRpc('session/prompt', {
            args: {
              request: {
                requestId: crypto.randomUUID(),
                sessionId: sessionId,
                mode: deliveryMode,
                // 文字 part 只在有文字时加入。引擎要求"非空白文字或至少一个附件"，
                // 而 {type:'text',text:''} 这种空白 part 会让准入判定变复杂，
                // 干脆不发。
                content: [
                  ...(text.trim() ? [{ type: 'text', text: text }] : []),
                  ...attachmentParts
                ]
              }
            }
          });

          // Check if session was cancelled while prompt RPC was awaiting
          const isCancelled = coreTurns.getCancelledSeq(sessionId) >= thisTurnSeq || (Date.now() - coreTurns.getLastCancelTime(sessionId) < 500);
          if (isCancelled) {
            try {
              await callDshRpc('session/cancel', {
                args: { request: { sessionId } }
              });
            } catch (cancelErr) {
              // The UI has already flipped to idle; if the engine cancel fails the
              // turn may still be running upstream. Surface it instead of pretending.
              logger.warn('[dsh-mobile-bridge] 取消补偿失败 %s: %s', sessionId, cancelErr?.message || cancelErr);
              audit('session/cancel-compensate-failed', { sessionId, error: cancelErr?.message });
            }
            activePrompts.delete(sessionId);
            if (follower) {
              follower.isRunning = false;
              follower.activePromptText = null;
            }
            broadcastToMobileClients({ type: 'session_status', sessionId, isRunning: false });
            broadcastToMobileClients({ type: 'done', sessionId });
            sendJson(200, { ok: true, code: 0, cancelled: true, result: promptRes });
            return;
          }

          sendJson(200, { ok: true, code: 0, result: promptRes });
          audit('session/prompt', { sessionId, length: text.length });
          return;
        } catch (err) {
          activePrompts.delete(sessionId);
          if (follower) {
            follower.isRunning = false;
            follower.activePromptText = null;
          }

          const isCancelled = coreTurns.getCancelledSeq(sessionId) >= thisTurnSeq;
          if (!isCancelled) {
            broadcastToMobileClients({ type: 'session_status', sessionId, isRunning: false });
            broadcastToMobileClients({ type: 'error', sessionId, error: err?.message || 'Prompt execution failed' });
            broadcastToMobileClients({ type: 'done', sessionId });
          }

          sendJson(500, { ok: false, error: err?.message || 'Prompt execution failed' });
          return;
        }
      }

      if (pathname === '/api/mobile/sessions/cancel' && req.method === 'POST') {
        const rawSessionId = jsonBody.sessionId;
        if (!rawSessionId || !String(rawSessionId).trim()) {
          sendJson(400, { error: 'Missing or empty sessionId' });
          return;
        }
        const sessionId = String(rawSessionId).trim();

        const now = Date.now();
        coreTurns.recordCancel(sessionId, now);

        activePrompts.delete(sessionId);
        const follower = getSessionFollower(sessionId);
        if (follower) {
          follower.isRunning = false;
          follower.thinkingBuffer = '';
          follower.textBuffer = '';
          follower.tools = [];
          follower.activePromptText = null;
        }

        broadcastToMobileClients({ type: 'session_status', sessionId, isRunning: false });
        broadcastToMobileClients({ type: 'done', sessionId });

        try {
          await callDshRpc('session/cancel', {
            args: {
              request: {
                sessionId: sessionId
              }
            }
          });
        } catch (cancelErr) {
          // Report the real outcome — a 200 "Cancelled" here would leave the turn
          // running upstream while the phone shows it as stopped.
          logger.warn('[dsh-mobile-bridge] session/cancel 失败 %s: %s', sessionId, cancelErr?.message || cancelErr);
          audit('session/cancel-failed', { sessionId, error: cancelErr?.message });
          sendJson(502, {
            ok: false,
            code: 502,
            sessionId,
            error: cancelErr?.message || 'Upstream cancel failed'
          });
          return;
        }

        sendJson(200, { ok: true, code: 0, message: 'Cancelled' });
        return;
      }

      if (pathname === '/api/mobile/sessions/delete' && req.method === 'POST') {
        const { sessionId, workspaceId } = jsonBody;
        // Implemented bridge-side: the engine has no session/delete RPC, so the
        // old callDshRpc('session/delete') + `catch(_){}` returned 200 "Deleted"
        // while removing nothing. [fixed]
        const result = deleteSession({ home: dshHomeDir, sessionId, workspaceId });

        if (!result.ok) {
          audit('session/delete-failed', { sessionId, error: result.error });
          sendJson(500, { ok: false, code: 500, sessionId, error: result.error });
          return;
        }

        // Purge live state so a later reconnect cannot resurrect the session.
        activePrompts.delete(sessionId);
        coreFollowers.map.delete(sessionId);
        coreFollowers.map.delete(sessionId.replace(/^session-/, ''));
        coreApprovals.removeBySession(sessionId);
        if (coreFollowers.get(sessionId)) {
          coreFollowers.get(sessionId).isRunning = false;
        }

        audit('session/delete', { sessionId, workspaceId, detached: result.detached });
        broadcastToMobileClients({ type: 'session_deleted', sessionId });
        sendJson(200, { ok: true, code: 0, message: 'Deleted', sessionId, detached: result.detached });
        return;
      }

      // 4.2 设置与模型
      if (pathname === '/api/mobile/settings' && req.method === 'GET') {
        const sData = getSettingsData();
        sendJson(200, { ok: true, code: 0, settings: sData, ...sData });
        return;
      }

      if (pathname === '/api/mobile/settings/model' && req.method === 'POST') {
        updateDefaultModel(jsonBody.model);
        sendJson(200, { ok: true, code: 0, message: 'Updated default model' });
        return;
      }

      if (pathname === '/api/mobile/sessions/model' && req.method === 'POST') {
        // [fix 2026-10-16] 以前这里只把 {provider:'wb', model} 写进投影缓存文件，
        // 从不告诉引擎 —— 而投影缓存是引擎折叠日志的**输出**（字段语义是"最近一次
        // 已记录请求消耗的选择"），手写进去等于断言一件没发生过的事。实测证据：
        // 在 App 里 18:42:50 切换模型后，引擎侧 26 分钟内没有任何 model/selection
        // 事件，请求仍跑旧模型，直到重启才换成新模型。
        //
        // 现在走引擎的正规 RPC（Host 校验后返回 accepted selection，并记录
        // log-only 事件 model/selection）。同族的 session/prompt、session/delete、
        // session/updateQueue 早就在用这条通道。
        const sessionId = String(jsonBody.sessionId || '').trim();
        const modelId = String(jsonBody.model || '').trim();
        if (!sessionId || !modelId) {
          sendJson(400, { ok: false, code: 400, error: 'sessionId 与 model 均为必填' });
          return;
        }
        const idCheck = assertSessionId(sessionId);
        if (!idCheck.ok) {
          audit('session/model', { sessionId, error: idCheck.error });
          sendJson(400, { ok: false, code: 400, error: idCheck.error });
          return;
        }
        const resolved = await resolveModelSelection(modelId);
        if (!resolved.ok) {
          audit('session/model', { sessionId, modelId, error: resolved.error });
          // 502：这是上游（引擎/目录）的问题，不是客户端请求格式的问题。
          sendJson(502, { ok: false, code: 502, error: resolved.error });
          return;
        }
        try {
          const value = await callDshRpc('session/selectModel', {
            args: { request: { sessionId, provider: resolved.provider, model: resolved.model } }
          });
          const selected = value && value.selected ? value.selected : { provider: resolved.provider, model: resolved.model };
          audit('session/model', { sessionId, modelId, provider: resolved.provider, selected: true });
          sendJson(200, { ok: true, code: 0, selected });
        } catch (err) {
          audit('session/model', { sessionId, modelId, error: err?.message || String(err) });
          sendJson(502, { ok: false, code: 502, error: err?.message || 'session/selectModel 调用失败' });
        }
        return;
      }

      // 4.3 权限策略
      if (pathname === '/api/mobile/permissions' && req.method === 'GET') {
        const resp = getPermissionsPayload();
        sendJson(200, { ok: true, code: 0, permissions: resp });
        return;
      }

      if (pathname === '/api/mobile/permissions' && req.method === 'POST') {
        const pol = jsonBody.defaultPolicy || jsonBody.executionPolicy;
        if (pol) globalPermissions.executionPolicy = pol;
        if (jsonBody.sandboxMode) globalPermissions.sandboxMode = jsonBody.sandboxMode;
        if (jsonBody.maxSteps) globalPermissions.maxSteps = Number(jsonBody.maxSteps);
        if (typeof jsonBody.protectGit === 'boolean') globalPermissions.protectGit = jsonBody.protectGit;
        if (jsonBody.sessionPolicies && typeof jsonBody.sessionPolicies === 'object') {
          for (const [sId, sPol] of Object.entries(jsonBody.sessionPolicies)) {
            if (typeof sPol === 'string') sessionPermissions.set(sId, sPol);
          }
        }

        const resp = persistAndBroadcastPermissions();
        sendJson(200, { ok: true, code: 0, permissions: resp });
        return;
      }

      if (pathname === '/api/mobile/sessions/permission' && req.method === 'POST') {
        setSessionPermission(jsonBody.sessionId, jsonBody.policy);
        sendJson(200, { ok: true, code: 0, sessionId: jsonBody.sessionId, policy: jsonBody.policy });
        return;
      }

      // 4.4 审批交互
      if (pathname === '/api/mobile/approvals' && req.method === 'GET') {
        sendJson(200, { ok: true, code: 0, approvals: coreApprovals.list() });
        return;
      }

      if (pathname === '/api/mobile/approval' && req.method === 'POST') {
        const eventId = jsonBody.eventId || jsonBody.approvalId || jsonBody.id;
        const outcome = jsonBody.outcome;
        const reason = jsonBody.reason || '';
        if (!eventId || !outcome) {
          sendJson(400, { ok: false, error: 'Missing eventId or outcome' });
          return;
        }
        const resOutcome = await handleApprovalRespond(eventId, outcome, reason);
        // 按结果回真实状态码（404 已过期 / 502 回传引擎失败），不再恒 200。
        // 旧客户端只看 200 就删卡片，等于把失败谎报成成功；App 侧新代码
        // 同时读状态码与 body.ok，两边任一都能感知失败。
        sendJson(resOutcome.ok === false ? (resOutcome.code || 502) : 200, resOutcome);
        return;
      }

      // 4.5 项目说明文档 (MEMORY.md / USER.MD) - Directory Traversal Hardened (F4.5)
      if ((pathname === '/api/mobile/workspace/memory' || pathname === '/api/mobile/memory') && req.method === 'GET') {
        const wsPath = parsedUrl.query?.workspacePath || parsedUrl.query?.path;
        const fileName = parsedUrl.query?.fileName || parsedUrl.query?.file || 'USER.MD';
        const check = sanitizeWorkspaceFilePath(wsPath, fileName);
        if (check.error) {
          sendJson(check.status, { ok: false, error: check.error });
          return;
        }
        let content = '';
        const exists = fs.existsSync(check.targetFile);
        if (exists) content = fs.readFileSync(check.targetFile, 'utf8');
        sendJson(200, { ok: true, code: 0, fileName, content, exists, filePath: check.targetFile });
        return;
      }

      if ((pathname === '/api/mobile/workspace/memory' || pathname === '/api/mobile/memory') && req.method === 'POST') {
        const wsPath = jsonBody.workspacePath || jsonBody.path;
        const fileName = jsonBody.fileName || jsonBody.file;
        const content = jsonBody.content;
        if (!wsPath || !fileName) {
          sendJson(400, { ok: false, error: 'Missing parameters (workspacePath and fileName required)' });
          return;
        }
        const check = sanitizeWorkspaceFilePath(wsPath, fileName);
        if (check.error) {
          sendJson(check.status, { ok: false, error: check.error });
          return;
        }
        const dir = path.dirname(check.targetFile);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(check.targetFile, content || '', 'utf8');
        sendJson(200, { ok: true, code: 0, fileName, message: 'Saved successfully', filePath: check.targetFile });
        audit('memory/update', { action: 'memory/update', event: 'memory/update', workspacePath: wsPath, fileName });
        return;
      }

      if (pathname === '/api/mobile/audit-logs' && req.method === 'GET') {
        const rawLogs = readAudit(100);
        const logs = rawLogs.map(l => ({
          ...l,
          action: l.action || l.toolName,
          event: l.event || l.action || l.toolName
        }));
        sendJson(200, { ok: true, code: 0, auditLogs: logs, logs: logs });
        return;
      }

      // Agent personas.  [unified] This route only existed on the standalone
      // gateway; the Flutter client calls it unconditionally on connect, so the
      // Cordis-hosted bridge used to answer 404 here.
      if (pathname === '/api/mobile/personas' && req.method === 'GET') {
        sendJson(200, { ok: true, code: 0, personas: personaStore.get() });
        return;
      }

      if (pathname === '/api/mobile/personas' && req.method === 'POST') {
        const list = Array.isArray(jsonBody.personas) ? jsonBody.personas : null;
        if (!list) {
          sendJson(400, { ok: false, error: 'personas must be an array' });
          return;
        }
        const okSave = personaStore.save(list);
        audit('personas/update', { count: list.length, saved: okSave });
        sendJson(okSave ? 200 : 500, { ok: okSave, code: okSave ? 0 : 500, personas: okSave ? list : personaStore.get() });
        return;
      }

      // ---- 网关版本探测 ----
      //
      // [cleanup 2026-10-21] 原先这里兼作「应用内更新检查」：回 apkUrl /
      // apkSize / apkMtime，让 App 从网关下载安装包。该能力已移除 ——
      // 安装包只认 GitHub Releases（App 直接读 `releases/latest/download/
      // latest.json`，见 `models/update_service.dart`），网关既不留包也不转发包。
      // 现在这条路由只剩「这个网关跑的是哪个版本的插件」，用于排障与能力对齐。
      if (pathname === '/api/mobile/version' && req.method === 'GET') {
        sendJson(200, {
          ok: true,
          code: 0,
          bridgeVersion: BRIDGE_VERSION,
          time: Date.now()
        });
        return;
      }

      // ---- v1.14 能力路由已在上面的通配路由**之前**处理 ----
      // （见 `/api/mobile/sessions/queue` 旁注：通配分支会静默吞掉该前缀下的
      //  GET 功能路由。这里保留位置说明，避免将来有人把它挪回来。）

      // ---- 会话归档 / 取消归档 ----
      if (pathname === '/api/mobile/sessions/archive' && req.method === 'POST') {
        const result = archiveSession({
          home: dshHomeDir,
          sessionId: jsonBody.sessionId,
          archive: jsonBody.archive !== false
        });
        if (!result.ok) {
          sendJson(400, { ok: false, code: 400, error: result.error });
          return;
        }
        audit('session/archive', { sessionId: jsonBody.sessionId, archived: result.archived });
        broadcastToMobileClients({
          type: result.archived ? 'session_archived' : 'session_unarchived',
          sessionId: jsonBody.sessionId
        });
        sendJson(200, { ok: true, code: 0, sessionId: result.sessionId, archived: result.archived });
        return;
      }

      // ---- 会话重命名 ----
      if (pathname === '/api/mobile/sessions/rename' && req.method === 'POST') {
        const result = renameSession({
          home: dshHomeDir,
          sessionId: jsonBody.sessionId,
          title: jsonBody.title
        });
        if (!result.ok) {
          sendJson(400, { ok: false, code: 400, error: result.error });
          return;
        }
        // 让缓存立即反映新标题
        for (const cPath of [
          path.join(dshHomeDir, 'storages', 'session_projcache', 'sessions', `${jsonBody.sessionId}.json`)
        ]) {
          projCacheReader.invalidate(cPath);
        }
        // [fix 2026-10-15] rename 只写主投影域。归档域里那份记录（sha256 命名的
        // 那份）现在也会被读到，所以必须一起失效，否则重命名后列表可能仍显示
        // 归档域里的旧标题。事件日志那份同样要失效：引擎会追加新的 session/title
        // 事件，但我们的折叠结果是按 (path, mtime, size) 缓存的，mtime 变了才重读，
        // 这里主动清掉更稳妥。
        for (const cPath of projectionCacheCandidates(dshHomeDir, jsonBody.sessionId)) {
          projCacheReader.invalidate(cPath);
        }
        eventLogTitles.invalidate(result.sessionId);
        audit('session/rename', { sessionId: jsonBody.sessionId });
        broadcastToMobileClients({ type: 'session_renamed', sessionId: result.sessionId, title: result.title });
        sendJson(200, { ok: true, code: 0, sessionId: result.sessionId, title: result.title });
        return;
      }

      // ---- 提示词模板 (snippets) ----
      if (pathname === '/api/mobile/snippets' && req.method === 'GET') {
        sendJson(200, { ok: true, code: 0, snippets: snippetStore.get() });
        return;
      }
      if (pathname === '/api/mobile/snippets' && req.method === 'POST') {
        if (!Array.isArray(jsonBody.snippets)) {
          sendJson(400, { ok: false, error: 'snippets must be an array' });
          return;
        }
        const saved = snippetStore.save(jsonBody.snippets);
        if (saved == null) {
          sendJson(500, { ok: false, code: 500, error: '保存失败（目录不可写？）' });
          return;
        }
        audit('snippets/update', { count: saved.length });
        sendJson(200, { ok: true, code: 0, snippets: saved });
        return;
      }

      sendJson(404, { error: 'Not found', path: pathname });
    } catch (err) {
      if (res.headersSent) return;
      logger.error('[dsh-mobile-bridge] API error:', pathname, err);
      sendJson(500, { error: err?.message || 'Internal server error' });
    }
  };

  const server = createServer(requestHandler);

  const wss = new WebSocket.Server({ noServer: true });

  // [v1.35 / 1.2] upgrade 处理器同样具名，明文与 TLS 两个服务共用。
  const handleUpgrade = (req, socket, head) => {
    const parsed = url.parse(req.url, true);
    const pathname = parsed.pathname;

    if (pathname === '/mobile-ws' || pathname === '/api/mobile/ws') {
      const auth = authenticateRequest(req, parsed);
      if (!auth.ok) {
        // [fix 2026-10-17] upgrade 鉴权失败同样计入爆破退避：此前只回 401 不
        // noteAuthFailure，走 WS 通道爆破 token 可完全绕开 HTTP 侧的限速。
        try { noteAuthFailure(req); } catch (_) {}
        socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
        socket.destroy();
        return;
      }
      // Carry the authenticated role onto the request so the connection handler
      // can stamp it onto the socket. Every write-ish WS frame is gated on it
      // below — HTTP has WRITE_PATHS, the socket had nothing, so a readonly
      // device could approve a command or answer an Agent prompt anyway.
      req._mobileAuth = auth;

      wss.handleUpgrade(req, socket, head, (ws) => {
        wss.emit('connection', ws, req);
      });
      return;
    }

    socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
    socket.destroy();
  };

  server.on('upgrade', handleUpgrade);

  /* ------------------------------------------------------------------ *
   * [v1.35 / 1.2] TLS 监听端口（HTTPS + WSS）
   *
   * 明文 3088 保持原样、可继续使用：过渡期必须让老配置零回归，TLS 是**新增
   * 端口**而不是替换（全局约束 7）。开关只有环境变量 BRIDGE_TLS_PORT
   * （0 = 关闭，默认 3443）—— 不放进 config.json，是因为设置页还没有 TLS
   * 开关，多一个可写入口只会让「为什么没生效」更不可诊断。
   *
   * 端口占用绝不 fatal：宿主上 3443 可能被别的服务占着，而明文端口仍然是
   * 可用的降级路径。失败只 warn + 审计，不阻断 listenPort 的启动。
   * ------------------------------------------------------------------ */
  let tlsServer = null;
  if (tlsPort > 0) {
    if (!tlsCert) {
      logger.warn('dsh-mobile-bridge: 自签证书不可用，TLS 端口未启动（明文端口不受影响）');
    } else {
      try {
        tlsServer = https.createServer({ key: tlsCert.key, cert: tlsCert.cert }, requestHandler);
        tlsServer.on('upgrade', handleUpgrade);
        tlsServer.on('error', (err) => {
          if (err?.code === 'EADDRINUSE') {
            logger.warn('dsh-mobile-bridge: TLS 端口 %d 已被占用，HTTPS/WSS 未启用（明文端口不受影响）', tlsPort);
          } else {
            logger.warn('dsh-mobile-bridge: TLS 端口异常 %s', err?.message ?? err);
          }
        });
        tlsServer.listen(tlsPort, bindHost, () => {
          logger.info('dsh-mobile-bridge: TLS 网关就绪 https://%s:%d（证书指纹 %s）', bindHost, tlsPort, certFingerprint);
          audit('tls/start', { port: tlsPort, fingerprint: certFingerprint });
          // [refactor 2026-10-21] provider=cloudflared 时随网关自动拉起隧道。
          //
          // 通道是**服务端能力**，不该等某台手机来点按钮 —— 而且隧道没开时手机
          // 根本连不上，那个按钮点不到（上一版在这里是死循环）。失败只 degrade：
          // 隧道起不来不影响局域网与明文端口。
          setTimeout(() => {
            reconcileRemoteAccess().catch((err) => {
              logger.warn('[dsh-mobile-bridge] 远程接入对账失败: %s', err?.message ?? err);
            });
          }, 0);
        });
      } catch (err) {
        logger.warn('dsh-mobile-bridge: TLS 端口启动失败（%s），HTTPS/WSS 不可用', err?.message ?? err);
        tlsServer = null;
      }
    }
  }

  // Heartbeat & dead socket tracking interval (F3.5) — constant lives in core.
  const heartbeatInterval = setInterval(() => {
    for (const ws of connectedClients) {
      if (ws.isAlive === false) {
        audit('ws/dead_prune', { ip: ws._remoteIp });
        connectedClients.delete(ws);
        try {
          ws.terminate();
        } catch (_) {}
        continue;
      }
      ws.isAlive = false;
      try {
        ws.ping();
      } catch (_) {
        connectedClients.delete(ws);
        try { ws.terminate(); } catch (_) {}
      }
    }
    pruneStaleFollowers();
  }, HEARTBEAT_INTERVAL_MS);
  heartbeatInterval.unref?.();

  /**
   * Follower records used to live forever: every session a phone ever opened
   * kept its buffers (text/thinking/tools) in the map for the lifetime of the
   * dsh web process. A long-lived gateway following hundreds of sessions grew
   * without bound. Idle followers (no activity for FOLLOWER_TTL_MS and not
   * running) are dropped here; the follow stream re-opens on demand the next
   * time a phone opens that session.
   */
  const FOLLOWER_TTL_MS = 10 * 60 * 1000;
  function pruneStaleFollowers() {
    const now = Date.now();
    for (const f of coreFollowers.all()) {
      if (f.isRunning) continue;
      if (now - (f.lastUpdated || 0) > FOLLOWER_TTL_MS) {
        coreFollowers.map.delete(f.sessionId);
        coreFollowers.map.delete(f.sessionId.replace(/^session-/, ''));
      }
    }
  }

  wss.on('connection', (ws, req) => {
    ws.isAlive = true;
    ws._remoteIp = req.socket?.remoteAddress;
    ws._role = req._mobileAuth?.device?.role || 'readwrite';
    ws._deviceId = req._mobileAuth?.device?.id || 'admin';
    connectedClients.add(ws);
    audit('ws/connect', { ip: ws._remoteIp, role: ws._role });

    ws.on('pong', () => {
      ws.isAlive = true;
    });

    ws.send(JSON.stringify({ type: 'connected', version: BRIDGE_VERSION, time: Date.now() }));
    ws.send(JSON.stringify({
      type: 'system',
      event: 'connected',
      message: 'Connected to DeepSeek Harness Agent',
      pendingApprovals: coreApprovals.list()
    }));

    ws.on('message', async (raw) => {
      ws.isAlive = true;
      try {
        const rawStr = String(raw).trim();
        // 1. Raw string ping support (case-insensitive) -> string pong
        if (rawStr.toLowerCase() === 'ping') {
          ws.send('pong');
          return;
        }

        const msg = JSON.parse(raw);

        // 2. JSON ping support ({"type": "ping"} or {"action": "ping"})
        if (msg.type === 'ping' || msg.action === 'ping') {
          ws.send(JSON.stringify({ type: 'pong', time: Date.now() }));
          return;
        }

        if ((msg.type === 'subscribe_session' || msg.type === 'follow' || msg.type === 'select_session') && (msg.sessionId || msg.id)) {
          const sId = msg.sessionId || msg.id;
          ws.sessionId = sId;
          followSession(sId);
          const follower = getSessionFollower(sId);
          if (follower) {
            ws.send(JSON.stringify({
              type: 'session_status',
              sessionId: sId,
              isRunning: follower.isRunning
            }));
            // [fix 2026-10-14] 断线重连/切回会话时补发累积的流式内容快照。
            // 手机重连后只收到 session_status，而 follower.textBuffer 里已积累
            // 的增量（delta 窗口期断线丢掉的那段）没有任何回放通道——回合已
            // 结束的话 buffer 也已清空，这轮内容在手机上为零，直到下次快照。
            // 这里把当前缓冲整体推一次；App 端按已有内容做前缀合并（多余的
            // 部分会被去重，不足的部分被补齐）。
            if (follower.isRunning && follower.subscribed !== false &&
                ((follower.textBuffer && follower.textBuffer.length) ||
                 (follower.thinkingBuffer && follower.thinkingBuffer.length))) {
              ws.send(JSON.stringify({
                type: 'stream_snapshot',
                sessionId: sId,
                text: follower.textBuffer || '',
                thinking: follower.thinkingBuffer || ''
              }));
            } else if (!follower.isRunning && follower.lastTurnPayload &&
                       follower.lastTurnPayload.expiresAt > Date.now() &&
                       follower.lastTurnPayload.text) {
              // 回合刚结束、手机可能错过了全部/部分 delta：补发本轮正文，
              // 标记 replay 让 App 端按需合并（收过了就是重复，幂等）。
              ws.send(JSON.stringify({
                type: 'stream_snapshot',
                sessionId: sId,
                text: follower.lastTurnPayload.text,
                thinking: follower.lastTurnPayload.thinking || '',
                replay: true
              }));
            }
          }
          if (msg.type === 'follow' || msg.type === 'select_session') {
            ws.send(JSON.stringify({ type: 'follow_ack', sessionId: sId }));
          }
        } else if (msg.type === 'question_answer') {
          // [0003] Answers the engine's user-questions waterfall over
          // $events/result. handleQuestionAnswer is async — it must be awaited,
          // or `res.ok` reads off a Promise and every ack reports undefined.
          // Gated on role: answering a question injects content into the Agent's
          // turn, which is exactly what a readonly viewer must not do.
          if (!roleCanWrite(ws._role)) {
            ws.send(JSON.stringify({ type: 'error', error: '只读设备无法回答提问 (read-only device)', code: 403 }));
            return;
          }
          const res = await handleQuestionAnswer(msg.eventId || msg.id, msg.answer ?? msg.payload);
          ws.send(JSON.stringify({
            type: 'question_ack',
            eventId: res.eventId || (msg.eventId || msg.id),
            ok: res.ok === true,
            error: res.error
          }));
        } else if (msg.type === 'subscribe_questions' || msg.type === 'question_subscribe') {
          // Opt in to interactive prompts. Deliberately explicit: a phone that
          // is only browsing the session list must not receive questions, or a
          // second client would sit on requests it will never answer.
          questionSubscribers.add(ws);
          ws.wantsQuestions = true;
          // This new subscriber is now a valid answerer for every question
          // still on offer — record it so a later disconnect of ANOTHER phone
          // does not take these prompts away from this one.
          for (const q of pendingQuestions.values()) {
            q.offeredTo?.add(ws);
          }
          ws.send(JSON.stringify({
            type: 'question_subscribed',
            ok: true,
            // Replay anything still waiting, so a phone that connects mid-question
            // is not left looking at a session that appears to have stalled.
            pending: livePendingQuestions()
          }));
        } else if (msg.type === 'unsubscribe_questions') {
          questionSubscribers.delete(ws);
          ws.wantsQuestions = false;
          // 与断线同一策略：只是这台设备不再接收，条目留着（见下面 close 的注释）。
          for (const q of pendingQuestions.values()) {
            q.offeredTo?.delete(ws);
          }
        } else if (msg.type === 'approval_response') {
          // Same gate as the HTTP WRITE_PATHS list: approving is the single
          // highest-impact frame on this socket (it authorises shell/file ops).
          if (!roleCanWrite(ws._role)) {
            ws.send(JSON.stringify({ type: 'error', error: '只读设备无法审批 (read-only device)', code: 403 }));
            return;
          }
          const eventId = msg.eventId || msg.approvalId || msg.id;
          if (eventId && msg.outcome) {
            const res = await handleApprovalRespond(eventId, msg.outcome, msg.reason);
            ws.send(JSON.stringify({ type: 'approval_ack', eventId, outcome: res.outcome, ok: res.ok }));
          }
        }
      } catch (err) {
        // 一条畸形帧或处理错误绝不能拖垮整个网关，但也不能无声无息 ——
        // 旧实现 catch(_){} 让"手机发了什么导致逻辑炸了"在线上无迹可循。
        // 记 warn（原始帧截断到 200 字符，防止超大 payload 刷屏），不回错误帧
        //（客户端未必在等 ack，写了反而制造新的异常路径）。
        try {
          logger.warn('[dsh-mobile-bridge] WS 消息处理失败: %s | frame: %s',
            err?.message ?? err, String(raw).slice(0, 200));
        } catch (_) {}
      }
    });

    ws.on('close', () => {
      // 手机上少一次"提问没到"的机会。
      //
      // 旧行为：订阅者一断开就把该提问从待办里删掉。但手机断线极常见（锁屏、
      // 切后台、Wi-Fi↔4G 切换），而提问恰恰是"agent 停在那里等人"的时刻 ——
      // 实测就发生过：提问下发后 1 秒手机 socket 断开，条目被释放，用户 reconnect
      // 回来时 replay 是空的，手机上既没有卡片也没有通知（10:58 那次）。
      //
      // 现在只把这台 socket 从 offeredTo 里摘掉，条目留着：重连的手机在
      // subscribe 时会拿到 pending replay，仍然能作答。真正的收尾交给 TTL
      // （30 分钟）、引擎取消、或已作答。
      //
      // 代价必须讲清楚：如果电脑端（Web UI）抢先答了，条目会滞留到 TTL，
      // 手机此后作答会被引擎以 unknown-question 拒掉 —— 客户端已把这种情况
      // 显示为"该提问已过期（可能已被其它设备回答）"并收走卡片。用"偶尔一张
      // 过期卡片"换"提问根本不到手机上"，这个取舍是划算的。
      if (questionSubscribers.has(ws)) {
        for (const q of pendingQuestions.values()) {
          q.offeredTo?.delete(ws);
        }
      }
      questionSubscribers.delete(ws);
      connectedClients.delete(ws);
    });
    ws.on('error', () => {
      questionSubscribers.delete(ws);
      connectedClients.delete(ws);
    });
  });

  // 诊断锚点（2026-10-15）：apply() 走到这里就证明插件确实被加载了。与下面
  // installRpc 里的注册日志配对，两行合起来能唯一区分"插件没加载"与
  // "加载了但 connection 没注入"——这正是 405 一直查不下去的原因。
  console.log(`[dsh-mobile-bridge] apply() 已执行，连接中… (webServer port=${dshPort})`);
  const disposeRpc = installRpc(ctx, {
    dshPort,
    isListening: true,
    readAudit,
    // [feat 2026-10-21] 设置页要能看到隧道的实时状态：provider 是在那一页选的，
    // 而隧道是异步建立的（先拿域名、再连边缘）。与 HTTP 接口共用同一份实现。
    getRemoteAccess: () => remoteAccessPayload(),
    // [feat 2026-10-12] pair/qrdata RPC needs the same minting machinery the
    // HTTP /pair/qr route uses — the settings page asks for a data-URL QR over
    // the RPC channel instead of hitting the unauthenticated HTTP route, so a
    // logged-in web session never depends on the pre-auth QR endpoint.
    mintPairSession: () => {
      const code = newPairCode();
      const expiresAt = Date.now() + pairCodeTtlMs();
      pairSession = { code, expiresAt };
      audit('pair/qrdata-generated', { expiresAt });
      const hosts = [];
      for (const list of Object.values(os.networkInterfaces())) {
        for (const ni of list || []) {
          if (ni.family === 'IPv4' && !ni.internal) hosts.push(ni.address);
        }
      }
      // [fix 2026-10-12] The phone that scans this QR is usually OUTSIDE the
      // LAN (nps tunnel), so the configured public host leads the candidate
      // list; a phone on the same Wi-Fi falls through to the LAN addresses.
      // The QR carries only the FIRST host — pick by where the user actually
      // connects, per the settings page's own config.
      const cfg = loadConfig();
      const publicHost = (cfg.npsHost || '').trim();
      const publicPort = Number(cfg.npsPort) || Number(listenPort) || listenPort;
      const primaryHost = publicHost || hosts[0] || '';
      return {
        v: 1,
        hosts: [primaryHost, ...hosts].filter(Boolean),
        host: primaryHost,
        port: publicHost ? publicPort : listenPort,
        publicHost: publicHost || null,
        publicPort: publicHost ? publicPort : null,
        lanHosts: hosts,
        pairCode: code,
        // [v1.35 / 1.3] 设置页二维码与 HTTP /pair/qr 必须是同一份载荷口径，
        // 否则两条配对路径的 TOFU 行为会不一致。
        certFingerprint,
        name: os.hostname(),
        expiresAt,
        ttlMs: pairCodeTtlMs()
      };
    }
  });

  server.on('error', (err) => {
    if (err?.code === 'EADDRINUSE') {
      logger.error('dsh-mobile-bridge: 端口 %d 已被占用', listenPort);
    } else {
      logger.error('dsh-mobile-bridge: 网关异常 %s', err?.message ?? err);
    }
  });

  server.listen(listenPort, bindHost, () => {
    logger.info('dsh-mobile-bridge: 移动网关就绪 http://%s:%d → 127.0.0.1:%d', bindHost, listenPort, dshPort);
    audit('gateway/start', { port: listenPort, dshPort });
    void refreshCookie().catch(() => {});
    connectUpstreamMux();
  });

  const cleanupGateway = async () => {
    if (isDisposed) return;
    isDisposed = true;
    logger.info('dsh-mobile-bridge: 正在关闭网关服务...');
    // [v1.35 / 1.5] 隧道进程必须随宿主一起收：留在宿主机上的 cloudflared
    // 会继续占着一条公网隧道，而已经没人知道它的地址了。
    try { quickTunnel?.stop(); } catch (_) {}
    quickTunnel = null;
    if (muxReconnectTimer) { clearTimeout(muxReconnectTimer); muxReconnectTimer = null; }
    if (heartbeatInterval) clearInterval(heartbeatInterval);
    try { upstreamMuxWs?.removeAllListeners(); } catch (_) {}
    // Keep an error sink attached while closing: removing every listener first
    // turns the close-time "WebSocket was closed before the connection was
    // established" into an uncaught exception that can abort the host process.
    try { upstreamMuxWs?.on('error', () => {}); } catch (_) {}
    try { upstreamMuxWs?.close(); } catch (_) {}
    upstreamMuxWs = null;
    for (const ws of connectedClients) {
      try { ws.close(); } catch (_) {}
    }
    connectedClients.clear();
    // Nothing here holds a timer any more (see QUESTION_TTL_MS), but the map
    // must not outlive the gateway so a re-apply starts clean.
    pendingQuestions.clear();
    questionSubscribers.clear();
    try { wss.close(); } catch (_) {}
    try { server.closeAllConnections?.(); } catch (_) {}
    try { tlsServer?.closeAllConnections?.(); } catch (_) {}
    // 明文与 TLS 两个监听面一起收，任何一个漏关都会让宿主进程挂着一个句柄。
    const closeServer = (srv) => new Promise((resolve) => {
      if (!srv) return resolve();
      srv.close(() => resolve());
      setTimeout(() => {
        try { srv.closeAllConnections?.(); } catch (_) {}
        resolve();
      }, 1000).unref?.();
    });
    await Promise.all([closeServer(server), closeServer(tlsServer)]);
    await disposeRpc();
    activePrompts.clear();
    sessionFollowers.clear();
    pendingApprovals.clear();
    audit('gateway/stop', {});
  };

  if (typeof ctx.on === 'function') {
    ctx.on('dispose', cleanupGateway);
  }
  ctx.effect(() => () => { cleanupGateway(); }, 'dsh-mobile-bridge: 关闭网关');

  return () => {
    cleanupGateway();
  };
}

apply.inject = inject;

const plugin = { name, inject, apply };
export default plugin;
export { name, inject };

