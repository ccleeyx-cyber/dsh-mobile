// dsh-mobile-bridge —— DSH 移动终端安全桥接与网关插件
// 
// 职责：
//   1. 作为 DSH 原生 Cordis 插件，在 DSH 进程内原生启动移动网关（默认端口 3088）。
//   2. 挂载 /api/mobile/* REST API 与 WebSocket 实时双工流式中继，供 Android App（DSH Mobile）调用。
//   3. 静态托管最新 Android APK 安装包（/dsh-agent.apk），支持在电脑端与手机端随时下载更新。
//   4. 设备配对（6 位码握手）+ 令牌摘要存储 + 角色权限控制（只读 / 读写）+ 访问审计日志。
//   5. 无缝集成 DSH 设置页：在「设置 → 移动终端」中可视化管理移动网关、配对设备、NPS 隧道与安装包。

import { createServer } from 'node:http';
import http from 'node:http';
import https from 'node:https';
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import url from 'node:url';
import { homedir } from 'node:os';
import { createRequire } from 'node:module';

import {
  loadConfig, saveConfig, verifyToken, findDeviceByToken, ensureDataDir, dshHome, audit, readAudit,
  loadDevices, saveDevices, touchDevice, revokeDevice,
  newPairCode, pairCodeTtlMs, newToken, hashToken, roleCanWrite,
  loadPermissions, savePermissions, permissionsFile
} from './store.mjs';
import { installRpc, RPC_CHANNEL, ENDPOINTS } from './rpc.mjs';
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
  collectSessionRecords,
  projectionCacheFileNames,
  claimsMobileFeatureRoute
} from './features.mjs';
import {
  BRIDGE_VERSION,
  MAX_BODY_SIZE,
  HEARTBEAT_INTERVAL_MS,
  createApprovalQueue,
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
const inject = ['connection', 'webServer'];

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

export function apply(ctx, config = {}, internals = {}) {
  const logger = ctx.logger?.(name) ?? console;
  const cfg = loadConfig();
  const dshPort = internals.dshPort ?? ctx.webServer?.port ?? config.dshPort ?? 3080;
  const listenPort = internals.port ?? config.port ?? cfg.port ?? 3088;
  const bindHost = config.host ?? '0.0.0.0';
  const dshHomeDir = dshHome();

  ensureDataDir();

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
    const names = projectionCacheFileNames(sessionId);
    if (names.length === 0) return null;
    const dir = path.join(dshHomeDir, 'storages', 'session_projcache', 'sessions');
    for (const name of names) {
      const record = projCacheReader.readJson(path.join(dir, name));
      if (record) return record;
    }
    return null;
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
   * this task change — for any git repository, and degrades honestly (empty list
   * + `reason`) when the workspace is not a repository.
   */
  async function readWorkspaceChanges(sessionId, wantedPath) {
    const cwd = readSessionCwd(sessionId);
    if (!cwd) return { available: false, reason: 'no-workspace', files: [] };

    const runGit = (args) => new Promise((resolve) => {
      execFile('git', args, { cwd, maxBuffer: 4 * 1024 * 1024, windowsHide: true }, (error, stdout) => {
        if (error) resolve(null);
        else resolve(String(stdout));
      });
    });

    const inside = await runGit(['rev-parse', '--is-inside-work-tree']);
    if (inside === null || inside.trim() !== 'true') {
      return { available: false, reason: 'not-a-git-repository', files: [] };
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
        path: wantedPath,
        hunks: parseUnifiedDiff(text),
        empty: !text.trim(),
        binary: /Binary files .* differ/.test(text)
      };
    }

    const porcelain = await runGit(['status', '--porcelain=v1', '-z']);
    const numstat = await runGit(['diff', '--numstat', 'HEAD']);
    const files = combineChanges(parsePorcelain(porcelain ?? ''), parseNumstat(numstat ?? ''));
    return { available: true, cwd, files };
  }

  /**
   * Stream one file to the client with a download disposition.
   *
   * Returns true once the bytes are on the wire, false when nothing could be
   * sent (missing path, not a regular file, or a read error). On false this
   * writes NOTHING — deliberately: a partially-written 200 would be worse than
   * an error the client can see. The caller owns the error response; a caller
   * that ignores the return value leaves the socket open with no answer (the
   * phone then waits out its full request timeout).
   */
  function sendFile(absPath, displayName) {
    return new Promise((resolve) => {
      let stat;
      try {
        stat = fs.statSync(absPath);
      } catch {
        resolve(false);
        return;
      }
      if (!stat.isFile()) {
        resolve(false);
        return;
      }
      const safeName = encodeURIComponent(path.basename(displayName || absPath));
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'Content-Length': stat.size,
        'Content-Disposition': `attachment; filename*=UTF-8''${safeName}`
      });
      const stream = fs.createReadStream(absPath);
      stream.on('error', () => { try { res.destroy(); } catch (_) {} resolve(false); });
      stream.on('end', () => resolve(true));
      stream.pipe(res);
    });
  }

  /**
   * Open a stream Remote on the MUX, take its first `take` items, then cancel.
   *
   * `job/list` is a stream method (the unary carrier rejects it outright), and
   * its frames are whole-set replacements, so the first frame is already the
   * complete answer. The stream is cancelled immediately afterwards — leaving
   * one open per phone request would leak a subscription per poll.
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

  function updateSessionModel(sessionId, modelId) {
    const cleanId = sessionId.startsWith('session-') ? sessionId.replace('session-', '') : sessionId;
    const projCacheDir = path.join(dshHomeDir, 'storages', 'session_projcache', 'sessions');
    const candidates = [
      path.join(projCacheDir, `${sessionId}.json`),
      path.join(projCacheDir, `session-${cleanId}.json`),
      path.join(projCacheDir, `${cleanId}.json`)
    ];

    let updated = false;
    for (const cPath of candidates) {
      const cache = projCacheReader.readJson(cPath);
      if (cache && cache.record && cache.record.rows) {
        try {
          if (!cache.record.rows.modelSelection) cache.record.rows.modelSelection = { val: {} };
          if (!cache.record.rows.modelSelection.val) cache.record.rows.modelSelection.val = {};
          cache.record.rows.modelSelection.val.lastUsed = { provider: 'wb', model: modelId };
          fs.writeFileSync(cPath, JSON.stringify(cache, null, 2), 'utf8');
          projCacheReader.invalidate(cPath); // we just changed the mtime/content
          updated = true;
          break;
        } catch (err) {
          logger.error('[SessionModel] Error updating cache file:', cPath, err);
        }
      }
    }
    audit('session/model', { sessionId, modelId, updated });
    return updated;
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
    const projCacheDir = path.join(dshHomeDir, 'storages', 'session_projcache', 'sessions');

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

          const candidates = [
            path.join(projCacheDir, `${sId}.json`),
            path.join(projCacheDir, `session-${cleanId}.json`),
            path.join(projCacheDir, `${cleanId}.json`)
          ];

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

          for (const cPath of candidates) {
            // mtime-memoized read: an unchanged cache file costs one statSync
            // instead of readFileSync + JSON.parse (this loop runs ~1000 times
            // per workspace poll, every 3 seconds, inside the engine process).
            const cache = projCacheReader.readJson(cPath);
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
              sessionMeta.title = rows.title?.val || rows.titleInput?.val?.first?.text || '新会话';
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
              break;
            }
          }

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
    const cleanId = sessionId.startsWith('session-') ? sessionId.replace('session-', '') : sessionId;
    const projCacheDir = path.join(dshHomeDir, 'storages', 'session_projcache', 'sessions');
    const candidates = [
      path.join(projCacheDir, `${sessionId}.json`),
      path.join(projCacheDir, `session-${cleanId}.json`),
      path.join(projCacheDir, `${cleanId}.json`)
    ];

    let cacheData = null;
    for (const cPath of candidates) {
      cacheData = projCacheReader.readJson(cPath);
      if (cacheData) break;
    }

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
    try {
      const targetSessionId = sessionId.startsWith('session-') ? sessionId : `session-${sessionId}`;
      const pageResult = await callDshRpc('session/page', {
        args: {
          request: {
            address: { kind: 'session', sessionId: targetSessionId },
            throughSeq: lastSeq,
            maxMessages: 100
          }
        }
      });

      if (pageResult && Array.isArray(pageResult.records)) {
        let currentAssistantMsg = null;
        for (const record of pageResult.records) {
          const ev = record.event;
          if (!ev) continue;

          if (ev.type === 'user/message') {
            currentAssistantMsg = null;
            let text = '';
            if (Array.isArray(ev.data?.content)) {
              for (const part of ev.data.content) {
                if (part.type === 'text' && part.text) text += part.text;
              }
            } else if (typeof ev.data?.content === 'string') {
              text = ev.data.content;
            }

            // 过滤系统注入的元信息与内部记忆快照
            // isCarriedContext (core) recognises the full set of injected blocks,
            // including Mnemon plugin-sourced snapshots that the previous inline
            // prefix check missed — those were being shown to the user as if they
            // had typed them.  [unified]
            if (isCarriedContext(text, ev) ||
                text.startsWith('Time sampled while preparing turn') ||
                text.startsWith('Memory recall guidance') ||
                text.includes('<system_information>')) {
              continue;
            }

            if (text.trim()) {
              messages.push({
                id: crypto.randomUUID(),
                role: 'user',
                content: text.trim(),
                time: ev.time || Date.now()
              });
            }
          } else if (ev.type === 'assistant/message') {
            const msgObj = ev.data?.message;
            let reasoning = '';
            let text = '';
            if (Array.isArray(msgObj?.content)) {
              for (const part of msgObj.content) {
                if (part.type === 'reasoning') reasoning += part.text || '';
                if (part.type === 'text') text += part.text || '';
              }
            } else if (typeof msgObj?.content === 'string') {
              text = msgObj.content;
            }

            if (reasoning || text) {
              if (!currentAssistantMsg) {
                currentAssistantMsg = {
                  id: crypto.randomUUID(),
                  role: 'assistant',
                  content: text,
                  thinking: reasoning,
                  tools: [],
                  time: ev.time || Date.now()
                };
                messages.push(currentAssistantMsg);
              } else {
                if (reasoning) {
                  currentAssistantMsg.thinking = (currentAssistantMsg.thinking ? currentAssistantMsg.thinking + '\n' : '') + reasoning;
                }
                if (text) {
                  currentAssistantMsg.content = (currentAssistantMsg.content ? currentAssistantMsg.content + '\n' : '') + text;
                }
              }
            }
          } else if (ev.type === 'tool/call') {
            const callData = ev.data;
            if (currentAssistantMsg && callData?.name) {
              currentAssistantMsg.tools.push({
                name: callData.name,
                input: coerceToolInput(callData.arguments),
                id: callData.callId
              });
            }
          } else if (ev.type === 'turn/end') {
            // 记录最近一次回合的结束原因（后面以 lastTurn 交给手机）。
            const end = describeTurnEnd(ev.data?.reason);
            lastTurn = {
              kind: end.kind,
              text: end.text,
              code: end.code || '',
              failed: isFailedTurnEnd(ev.data?.reason),
              turn: typeof ev.data?.turn === 'number' ? ev.data.turn : null,
              time: ev.time || Date.now()
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
    if (typeof msg.streamId === 'string' && msg.streamId.startsWith('oneshot-')) {
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
            }
            broadcastToMobileClients({ type: 'done', sessionId: sId, reason: end.kind, message: end.text });
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
              const approval = {
                id: eventId,
                eventId,
                clientId: currentEventsClientId,
                sessionId,
                toolName,
                reason,
                callId,
                input,
                options,
                createdAt: Date.now()
              };
              coreApprovals.put(approval);
              audit('approval/requested', approval);
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

          const approval = {
            id: eventId,
            eventId,
            clientId: currentEventsClientId,
            sessionId,
            toolName,
            reason,
            callId,
            input,
            options,
            createdAt: Date.now()
          };

          coreApprovals.put(approval);
          audit('approval/requested', approval);
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
        const approval = {
          id: eventId,
          eventId,
          clientId: currentEventsClientId,
          sessionId: sId,
          toolName: ev.toolName || ev.action || '系统执行',
          reason: ev.reason || ev.command || '申请工具执行权限',
          callId: ev.callId || '',
          input: ev.input || ev.command || '',
          options: ev.options || null,
          createdAt: Date.now()
        };
        coreApprovals.put(approval);
        broadcastToMobileClients({
          type: 'approval_request',
          approval
        });
        audit('approval/requested', approval);
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

    coreApprovals.remove(appr, eventId);

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

  const server = createServer(async (req, res) => {
    const parsedUrl = url.parse(req.url, true);
    const pathname = parsedUrl.pathname;

    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, x-dsh-token, x-auth-code');

    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }

    const sendJson = (status, obj) => {
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(obj));
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
      } else if (parsedUrl.query?.token) {
        testToken = String(parsedUrl.query.token).trim();
      }
      const isAuthed = verifyToken(testToken);
      if (!isAuthed) {
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
      sendJson(200, {
        code: 0,
        ok: true,
        authenticated: true,
        name: 'dsh-mobile-bridge',
        port: listenPort,
        dshPort: dshPort,
        version: BRIDGE_VERSION,
        time: new Date().toISOString()
      });
      return;
    }

    // 2. APK 客户端静态下载
    if (pathname === '/dsh-agent.apk' || pathname === '/api/mobile/download/apk') {
      const candidates = [
        path.join(import.meta.dirname ?? path.dirname(url.fileURLToPath(import.meta.url)), '..', 'public', 'dsh-agent.apk'),
        path.join(import.meta.dirname ?? path.dirname(url.fileURLToPath(import.meta.url)), '..', 'dsh-agent-v1.2.6.apk'),
        path.join(import.meta.dirname ?? path.dirname(url.fileURLToPath(import.meta.url)), '..', '..', 'dsh-agent-v1.2.0.apk')
      ];

      let apkPath = '';
      for (const c of candidates) {
        if (fs.existsSync(c)) { apkPath = c; break; }
      }

      if (!apkPath) {
        sendJson(404, { error: 'APK file not found on server' });
        return;
      }

      const stat = fs.statSync(apkPath);
      res.writeHead(200, {
        'Content-Type': 'application/vnd.android.package-archive',
        'Content-Length': stat.size,
        'Content-Disposition': 'attachment; filename="dsh-agent.apk"',
        'Cache-Control': 'no-cache'
      });
      if (req.method === 'HEAD') { res.end(); return; }
      fs.createReadStream(apkPath).pipe(res);
      audit('apk/download', { ip: req.socket?.remoteAddress, size: stat.size });
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
    const auth = authenticateRequest(req, parsedUrl);
    if (!auth.ok) {
      sendJson(401, { error: 'Unauthorized', message: '缺少有效令牌或设备未配对' });
      return;
    }
    // Keep the device's lastSeenAt fresh so the settings page can show real usage.
    if (auth.device?.id && auth.device.id !== 'admin') touchDevice(auth.device.id, req.socket?.remoteAddress || '');

    // Read-only device gate. roleCanWrite() used to be `return true`, so the
    // role recorded at pairing was decoration. Writes are denied here, once,
    // instead of being sprinkled through every mutating route.
    const WRITE_PATHS = [
      '/api/mobile/upload',
      '/api/mobile/sessions/prompt',
      '/api/mobile/sessions/cancel',
      '/api/mobile/sessions/delete',
      '/api/mobile/sessions/create',
      '/api/mobile/sessions/model',
      '/api/mobile/sessions/archive',
      '/api/mobile/sessions/rename',
      '/api/mobile/sessions/permission',
      '/api/mobile/settings/model',
      '/api/mobile/permissions',
      '/api/mobile/approval',
      '/api/mobile/workspace/memory',
      '/api/mobile/memory',
      '/api/mobile/personas',
      '/api/mobile/snippets',
      // v1.14：队列插话、定时任务删除、作业终止、推送配置
      '/api/mobile/sessions/queue',
      '/api/mobile/schedules/delete',
      '/api/mobile/jobs/kill',
      '/api/mobile/push/config',
      '/api/mobile/push/test'
    ];
    if (req.method === 'POST' || req.method === 'PUT') {
      const isWrite = WRITE_PATHS.some((p) => pathname === p) ||
        (pathname === '/api/mobile/workspace/memory' && req.method === 'POST');
      if (isWrite && !roleCanWrite(auth.device?.role)) {
        sendJson(403, { ok: false, code: 403, error: '该设备为只读角色，无权执行写操作' });
        audit('auth/readonly-denied', { path: pathname, device: auth.device?.id, role: auth.device?.role });
        return;
      }
    }

    // 5. 附件上传与读取（v1.10.0）
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
      // 4.1 工作区与会话
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
        sendFile,
        callDshRpc,
        readStreamOnce,
        readProjections,
        readProjectionRows,
        readSessionRecords,
        readWorkspaceChanges,
        readConfig: loadConfig,
        writeConfig: saveConfig,
        pushTest,
        audit,
        logger
      })) {
        return;
      }

      // The second half of the guard: even if someone moves the feature dispatch
      // back below this branch, a claimed feature route can no longer be stolen
      // by the wildcard (see `claimsMobileFeatureRoute` in features.mjs).
      if (pathname.startsWith('/api/mobile/sessions/') && req.method === 'GET'
          && !claimsMobileFeatureRoute(req.method, pathname)) {
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
        updateSessionModel(jsonBody.sessionId, jsonBody.model);
        sendJson(200, { ok: true, code: 0, message: 'Updated session model' });
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

      // ---- 应用内更新检查 ----
      //
      // App 拿自己的 version/build 与这里比对；latestVersion 取 DSH_LATEST_APP_VERSION
      // 环境变量（运维发布新 APK 时顺手改），没配则回落到 BRIDGE_VERSION，
      // 并附 APK 直链与最近一次请求时的 Content-Length（有 APK 时）。
      if (pathname === '/api/mobile/version' && req.method === 'GET') {
        const apkCandidates = [
          path.join(import.meta.dirname ?? path.dirname(url.fileURLToPath(import.meta.url)), '..', 'public', 'dsh-agent.apk')
        ];
        let apkSize = 0;
        let apkMtime = null;
        for (const c of apkCandidates) {
          try {
            const st = fs.statSync(c);
            apkSize = st.size;
            apkMtime = st.mtimeMs;
            break;
          } catch { /* not shipped */ }
        }
        sendJson(200, {
          ok: true,
          code: 0,
          bridgeVersion: BRIDGE_VERSION,
          latestVersion: process.env.DSH_LATEST_APP_VERSION || null,
          apkUrl: '/dsh-agent.apk',
          apkSize,
          apkMtime,
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
  });

  const wss = new WebSocket.Server({ noServer: true });

  server.on('upgrade', (req, socket, head) => {
    const parsed = url.parse(req.url, true);
    const pathname = parsed.pathname;

    if (pathname === '/mobile-ws' || pathname === '/api/mobile/ws') {
      const auth = authenticateRequest(req, parsed);
      if (!auth.ok) {
        socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
        socket.destroy();
        return;
      }

      wss.handleUpgrade(req, socket, head, (ws) => {
        wss.emit('connection', ws, req);
      });
      return;
    }

    socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
    socket.destroy();
  });

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
    connectedClients.add(ws);
    audit('ws/connect', { ip: ws._remoteIp });

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
          }
          if (msg.type === 'follow' || msg.type === 'select_session') {
            ws.send(JSON.stringify({ type: 'follow_ack', sessionId: sId }));
          }
        } else if (msg.type === 'question_answer') {
          // [0003] Answers the engine's user-questions waterfall over
          // $events/result. handleQuestionAnswer is async — it must be awaited,
          // or `res.ok` reads off a Promise and every ack reports undefined.
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

  const apkFilePath = path.join(import.meta.dirname ?? path.dirname(url.fileURLToPath(import.meta.url)), '..', 'public', 'dsh-agent.apk');
  const disposeRpc = installRpc(ctx, {
    dshPort,
    isListening: true,
    readAudit
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
    await new Promise((resolve) => {
      server.close(() => resolve());
      setTimeout(() => {
        try { server.closeAllConnections?.(); } catch (_) {}
        resolve();
      }, 1000).unref?.();
    });
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

export { name, inject };

