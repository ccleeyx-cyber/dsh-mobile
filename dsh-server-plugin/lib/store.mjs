// dsh-server-plugin 状态存储与配置管理
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { homedir } from 'node:os';
import { createAuditSink } from './core.mjs';

export function dshHome() {
  return process.env.DSH_HOME || path.join(homedir(), '.dsh');
}

export function dataDir() {
  return path.join(dshHome(), 'mobile-bridge');
}

export function ensureDataDir() {
  const dir = dataDir();
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  return dir;
}

export function permissionsDir() {
  return path.join(dshHome(), 'mobile-access');
}

export function permissionsFile() {
  return path.join(permissionsDir(), 'permissions.json');
}

export function ensurePermissionsDir() {
  const dir = permissionsDir();
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  return dir;
}

const configFile = () => path.join(dataDir(), 'config.json');

/**
 * Fallback config used only on a fresh install.
 *
 * The token is NOT a usable secret — it is a well-known literal that used to be
 * hard-coded here, which meant anyone with the source could authenticate. On a
 * fresh install we therefore generate a random token and persist it, so the
 * bridge is never reachable with a published credential. Operators can change it
 * later from the DSH settings page (or the config file) as usual.
 */
const DEFAULT_CONFIG = {
  token: '',
  port: 3088,
  // [refactor 2026-10-21] 旧的三个 NPS 字段保留**派生只读**语义：真正的模型是
  // `remoteAccess`（见下），顶层这三个只是给旧读者（client.js 面板、旧版 App）
  // 的兼容字段，始终跟着 remoteAccess.nps 同步。
  npsHost: '',
  npsPort: 3088,
  useHttps: false,
  remoteAccess: {
    provider: 'none',
    nps: { host: '', port: 3088, useHttps: false }
  },
  // ntfy 离线推送（v1.14）。默认关闭：推送会把事件摘要发往第三方服务，
  // 必须由用户显式打开并填 topic。
  ntfyEnabled: false,
  ntfyUrl: '',
  ntfyTopic: '',
  ntfyToken: ''
};

/**
 * 「远程接入」的三种 provider。**严格互斥**：同一时刻只有一条公网出口。
 *
 * 为什么互斥而不是并存：`nps` 与 `cloudflared` 解决的是**同一件事**（让手机从
 * 公网到达本机 3088/3443），只是出口不同 —— 一个是用户自己的反向代理（网关
 * 只知道自己挂在哪个地址下），一个是网关自己向外建连（cloudflared quick
 * tunnel，地址每次重连都会变）。两条同时开着只会让"我该填哪个地址"变成新问题。
 */
export const REMOTE_PROVIDERS = Object.freeze(['none', 'nps', 'cloudflared']);

const DEFAULT_REMOTE_ACCESS = Object.freeze({
  provider: 'none',
  nps: Object.freeze({ host: '', port: 3088, useHttps: false }),
  // [feat 2026-10-21] cloudflared 的命名隧道（参考 dsh-pocket）：token 非空就用
  // `tunnel run` + 固定域名；为空则是快速隧道（随机域名、每次重连会变）。
  cloudflared: Object.freeze({ token: '', host: '' })
});

/**
 * 归一化远程接入配置。
 *
 * 两个来源：新的 `remoteAccess`，或**旧的**顶层 `npsHost/npsPort/useHttps`。
 * 旧配置的映射刻意保持零回归 —— 填了 npsHost 就等于 `provider: 'nps'`
 * （现有安装的 config.json 里都有这一项）。
 */
export function normalizeRemoteAccess(raw, legacy = {}) {
  const rawNps = (raw && typeof raw.nps === 'object' && raw.nps) || {};
  const host = String(
    rawNps.host !== undefined ? rawNps.host : (legacy.npsHost || '')
  ).trim();
  const port = Number(rawNps.port !== undefined ? rawNps.port : legacy.npsPort)
    || DEFAULT_REMOTE_ACCESS.nps.port;
  const useHttps = rawNps.useHttps !== undefined
    ? Boolean(rawNps.useHttps)
    : Boolean(legacy.useHttps);

  let provider = raw && typeof raw.provider === 'string'
    ? raw.provider.trim().toLowerCase()
    : '';
  if (!REMOTE_PROVIDERS.includes(provider)) provider = host ? 'nps' : 'none';
  // 「选了 nps 却没填地址」是无效态：回落 none，由调用方给出"缺 host"的提示。
  // 不能让网关带着一条指向空字符串的"人肉反代"对外宣称可用。
  if (provider === 'nps' && !host) provider = 'none';

  // [feat 2026-10-21] cloudflared 的命名隧道（参考 dsh-pocket）：
  //   token 非空 = 命名隧道（固定域名、重启不变）；token 为空 = 快速隧道。
  const rawCf = (raw && typeof raw.cloudflared === 'object' && raw.cloudflared) || {};
  const cfToken = String(rawCf.token ?? '').trim();
  const cfHost = String(rawCf.host ?? '').trim().replace(/^https?:\/\//i, '').replace(/\/+$/, '');

  return {
    provider,
    nps: { host, port, useHttps },
    cloudflared: { token: cfToken, host: cfHost }
  };
}

/** 远程接入里跟 cloudflared 有关的模式判定（面板与网关都要用同一套）。 */
export function cloudflaredMode(remoteAccess) {
  const cf = (remoteAccess && remoteAccess.cloudflared) || {};
  return String(cf.token || '').trim() ? 'named' : 'quick';
}

/** 把远程接入模型摊平成旧的三个顶层字段（兼容旧读者）。 */
export function legacyNpsFields(remoteAccess) {
  const ra = remoteAccess || DEFAULT_REMOTE_ACCESS;
  return {
    npsHost: ra.nps.host,
    npsPort: ra.nps.port,
    useHttps: ra.nps.useHttps
  };
}

export function loadConfig() {
  ensureDataDir();
  const f = configFile();
  if (!fs.existsSync(f)) {
    // Fresh install: mint a random token instead of shipping a known default.
    const fresh = { ...DEFAULT_CONFIG, token: generateToken() };
    try {
      fs.writeFileSync(f, JSON.stringify(fresh, null, 2), 'utf8');
    } catch (_) {}
    _lastGoodConfig = fresh;
    return fresh;
  }
  try {
    const raw = JSON.parse(fs.readFileSync(f, 'utf8'));
    const token = (raw.token && String(raw.token).trim())
      || process.env.DSH_AUTH_TOKEN
      || generateToken();
    const remoteAccess = normalizeRemoteAccess(raw.remoteAccess, {
      npsHost: raw.npsHost,
      npsPort: raw.npsPort,
      useHttps: raw.useHttps
    });
    const loaded = {
      token,
      port: Number(raw.port) || DEFAULT_CONFIG.port,
      remoteAccess,
      ...legacyNpsFields(remoteAccess),
      ntfyEnabled: raw.ntfyEnabled === true,
      ntfyUrl: typeof raw.ntfyUrl === 'string' ? raw.ntfyUrl.trim() : '',
      ntfyTopic: typeof raw.ntfyTopic === 'string' ? raw.ntfyTopic.trim() : '',
      ntfyToken: typeof raw.ntfyToken === 'string' ? raw.ntfyToken.trim() : ''
    };
    _lastGoodConfig = loaded;
    return loaded;
  } catch {
    // [fix 2026-10-28] 文件存在但读失败（与 renameSync 写盘竞态 / EBUSY / 瞬时
    // ENOENT）时绝不能静默换新随机 token：
    //   * verifyToken 每个请求都 loadConfig，瞬时失败窗口内所有请求 401；
    //   * 更糟的是 saveConfigInternal 第一步也 loadConfig——若此刻保存配置，
    //   新随机 token 被持久化，所有手机凭据**永久失效**。
    // 缓存上次成功读取的配置；冷启动且一次都没成功过时抛错（调用方如实报错，
    // 好过静默发一个谁都不认识的 token）。
    if (_lastGoodConfig) return _lastGoodConfig;
    throw new Error(`config.json 读取失败（文件存在）：${f}`);
  }
}

/** [fix 2026-10-28] 上次成功读取的配置快照（见 loadConfig 的 catch 分支）。 */
let _lastGoodConfig = null;

/** 「配置已保存」钩子（同一时刻只保留一个）。 */
let configSavedHook = null;

/**
 * 注册"配置已保存"钩子；网关用它触发远程接入对账。
 *
 * [fix 2026-10-21] 为什么放在 saveConfig 而不是各个调用点：面板保存走 RPC
 * `config/update` → `saveConfig`，而 `reconcileRemoteAccess()` 只挂在 HTTP
 * `POST /api/mobile/remote-access` 与网关启动两处。于是用户在设置页切到
 * cloudflared 时，配置写进去了（真机 17:39:26），但**隧道从来没被触发** ——
 * 界面一直"隧道未启动"。钩子放进 saveConfig 之后，就不存在"某条保存路径忘了
 * 对账"这种漏网。
 */
export function onConfigSaved(fn) {
  configSavedHook = typeof fn === 'function' ? fn : null;
}

export function saveConfig(patch = {}) {
  const updated = saveConfigInternal(patch);
  try {
    configSavedHook?.(updated);
  } catch { /* 对账失败不能影响保存本身 */ }
  return updated;
}

function saveConfigInternal(patch = {}) {
  ensureDataDir();
  const current = loadConfig();
  const updated = {
    ...current,
    ...patch
  };
  // Ensure types
  if (patch.token !== undefined) updated.token = String(patch.token).trim() || DEFAULT_CONFIG.token;
  if (patch.port !== undefined) updated.port = Number(patch.port) || DEFAULT_CONFIG.port;

  // 远程接入：新形状（remoteAccess）与旧形状（顶层 npsHost/npsPort/useHttps）
  // 都写进**同一个**模型，避免出现"改了 npsHost 但 provider 还是 none"的分裂态。
  const hasLegacy = patch.npsHost !== undefined
    || patch.npsPort !== undefined
    || patch.useHttps !== undefined;
  const remotePatch = (patch.remoteAccess && typeof patch.remoteAccess === 'object')
    ? patch.remoteAccess
    : null;
  if (remotePatch || hasLegacy) {
    const cur = current.remoteAccess || DEFAULT_REMOTE_ACCESS;
    const merged = {
      provider: remotePatch && remotePatch.provider !== undefined
        ? remotePatch.provider
        : cur.provider,
      nps: {
        host: remotePatch && remotePatch.nps && remotePatch.nps.host !== undefined
          ? remotePatch.nps.host
          : (patch.npsHost !== undefined ? patch.npsHost : cur.nps.host),
        port: remotePatch && remotePatch.nps && remotePatch.nps.port !== undefined
          ? remotePatch.nps.port
          : (patch.npsPort !== undefined ? patch.npsPort : cur.nps.port),
        useHttps: remotePatch && remotePatch.nps && remotePatch.nps.useHttps !== undefined
          ? remotePatch.nps.useHttps
          : (patch.useHttps !== undefined ? patch.useHttps : cur.nps.useHttps)
      },
      cloudflared: {
        token: remotePatch && remotePatch.cloudflared && remotePatch.cloudflared.token !== undefined
          ? remotePatch.cloudflared.token
          : (cur.cloudflared?.token ?? ''),
        host: remotePatch && remotePatch.cloudflared && remotePatch.cloudflared.host !== undefined
          ? remotePatch.cloudflared.host
          : (cur.cloudflared?.host ?? '')
      }
    };
    // 旧调用方（client.js 面板没有 provider 概念）填了地址 = 表示要用 NPS。
    if (!remotePatch && patch.npsHost !== undefined
      && String(patch.npsHost).trim() && merged.provider === 'none') {
      merged.provider = 'nps';
    }
    updated.remoteAccess = normalizeRemoteAccess(merged);
    Object.assign(updated, legacyNpsFields(updated.remoteAccess));
  }

  // 推送配置（v1.14）。空字符串是合法值 —— 用户清空地址/topic 就等于关掉这条
  // 通道，不能像 token 那样回退到默认值。
  if (patch.ntfyEnabled !== undefined) updated.ntfyEnabled = patch.ntfyEnabled === true;
  if (patch.ntfyUrl !== undefined) updated.ntfyUrl = String(patch.ntfyUrl || '').trim();
  if (patch.ntfyTopic !== undefined) updated.ntfyTopic = String(patch.ntfyTopic || '').trim();
  if (patch.ntfyToken !== undefined) updated.ntfyToken = String(patch.ntfyToken || '').trim();

  fs.writeFileSync(configFile(), JSON.stringify(updated, null, 2), 'utf8');
  _lastGoodConfig = updated;
  return updated;
}

export function generateToken() {
  return 'dsh_' + crypto.randomBytes(16).toString('hex');
}

/**
 * Constant-time string comparison.
 *
 * `===` returns as soon as the first byte differs, which over a network is a
 * measurable timing oracle. Compare digests of fixed length instead, so the
 * loop's work does not depend on where the candidate first diverges.
 */
function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || !a || !b) return false;
  const ha = crypto.createHash('sha256').update(a, 'utf8').digest();
  const hb = crypto.createHash('sha256').update(b, 'utf8').digest();
  try {
    return crypto.timingSafeEqual(ha, hb);
  } catch (_) {
    return false;
  }
}

export function verifyToken(inputToken) {
  if (!inputToken || typeof inputToken !== 'string') return false;
  const trimmed = inputToken.trim();
  if (!trimmed) return false;
  const cfg = loadConfig();
  if (safeEqual(trimmed, cfg.token)) return true;
  if (process.env.DSH_AUTH_TOKEN && safeEqual(trimmed, process.env.DSH_AUTH_TOKEN)) return true;
  // Paired-device tokens. Previously the token minted at pairing was never
  // checked here, so a freshly paired phone got 401 on its next request and
  // revokeDevice() had no effect on auth at all. Hash (never the plaintext)
  // is compared, and revoked devices are refused.
  const dev = findDeviceByToken(trimmed);
  if (dev && dev.revoked !== true) return true;
  return false;
}

/**
 * Resolve a paired device by its token, or null. Constant-time-ish comparison:
 * we hash the candidate once and compare hex digests, so a token never sits in
 * a string-comparison timing oracle and the plaintext is never stored.
 */
export function findDeviceByToken(inputToken) {
  if (!inputToken || typeof inputToken !== 'string') return null;
  const hash = hashToken(inputToken.trim());
  const state = loadDevices();
  for (const dev of state.devices) {
    if (dev?.tokenHash === hash) return dev;
  }
  return null;
}

/**
 * Real role check. Roles: 'readwrite' (default at pairing) and 'readonly'.
 * A readonly device can view sessions/approvals/permissions but cannot prompt,
 * cancel, upload, delete or mutate settings. Previously this returned true
 * unconditionally, so the role field on devices.json was decoration.
 */
export function roleCanWrite(role) {
  return !role || role === 'readwrite';
}

const DEFAULT_PERMISSIONS = {
  defaultPolicy: 'auto-read',
  executionPolicy: 'auto-read',
  sandboxMode: 'workspace-write',
  maxSteps: 30,
  protectGit: true,
  sessionPolicies: {}
};

const AUDIT_BUFFER_SIZE = 200;
const auditBuffer = [];

/**
 * The record/read logic lives in core so both entry points share one audit
 * implementation; store owns the buffer and the on-disk permission state.
 */
const auditSink = createAuditSink({ auditBuffer, size: AUDIT_BUFFER_SIZE });

/** 磁盘审计文件上限；超过就轮转到 audit.log.1（只留一份旧档）。 */
const AUDIT_FILE_MAX = 2 * 1024 * 1024;

/**
 * [fix 2026-10-21] 审计**落盘**。
 *
 * 之前 `audit()` 只写内存环形缓冲，磁盘上那份 `audit.log` 是更早实现留下的死
 * 文件（真机最后一行是 09-28）。后果：隧道为什么失败、谁在什么时候切了 provider，
 * **重启后一个字都不剩** —— 排查只能靠猜，这正是近期反复绕圈的原因。
 *
 * 旧文件是 `{\"at\":..,\"action\":..}` 形状，这里写的是 core 的 entry 形状；两者
 * 混在一个文件里无所谓 —— 读的人（我）只关心时间与 action。
 */
function appendAuditToDisk(entry) {
  try {
    const f = path.join(dataDir(), 'audit.log');
    try {
      if (fs.statSync(f).size > AUDIT_FILE_MAX) fs.renameSync(f, `${f}.1`);
    } catch { /* 还不存在 */ }
    fs.appendFileSync(f, `${JSON.stringify(entry)}\n`, 'utf8');
  } catch { /* 审计不可用不影响业务 */ }
}

export function audit(action, payload = {}) {
  const entry = auditSink.record(action, payload);
  appendAuditToDisk(entry);
  return entry;
}

export function readAudit(limit = 100) {
  return auditSink.read(limit);
}

export function loadPermissions() {
  ensurePermissionsDir();
  const f = permissionsFile();
  if (!fs.existsSync(f)) {
    try {
      savePermissions(DEFAULT_PERMISSIONS);
    } catch (_) {}
    return { ...DEFAULT_PERMISSIONS };
  }
  try {
    const raw = JSON.parse(fs.readFileSync(f, 'utf8'));
    const defaultPolicy = raw.defaultPolicy || raw.executionPolicy || DEFAULT_PERMISSIONS.defaultPolicy;
    const sessionPolicies = {};
    if (raw.sessionPolicies && typeof raw.sessionPolicies === 'object') {
      for (const [k, v] of Object.entries(raw.sessionPolicies)) {
        if (typeof v === 'string') sessionPolicies[k] = v;
      }
    }
    return {
      defaultPolicy,
      executionPolicy: defaultPolicy,
      sandboxMode: raw.sandboxMode || DEFAULT_PERMISSIONS.sandboxMode,
      maxSteps: typeof raw.maxSteps === 'number' ? raw.maxSteps : DEFAULT_PERMISSIONS.maxSteps,
      protectGit: raw.protectGit !== false,
      sessionPolicies
    };
  } catch (_) {
    return { ...DEFAULT_PERMISSIONS };
  }
}

export function savePermissions(perms = {}) {
  ensurePermissionsDir();
  const current = loadPermissions();
  const defaultPol = perms.defaultPolicy || perms.executionPolicy || current.defaultPolicy;
  const mergedSessionPolicies = {
    ...current.sessionPolicies,
    ...(perms.sessionPolicies || {})
  };
  const updated = {
    defaultPolicy: defaultPol,
    executionPolicy: defaultPol,
    sandboxMode: perms.sandboxMode || current.sandboxMode,
    maxSteps: typeof perms.maxSteps === 'number' ? perms.maxSteps : current.maxSteps,
    protectGit: perms.protectGit !== undefined ? Boolean(perms.protectGit) : current.protectGit,
    sessionPolicies: mergedSessionPolicies
  };

  const targetFile = permissionsFile();
  const tmpFile = path.join(permissionsDir(), `permissions.json.${process.pid}.${Date.now()}.tmp`);
  try {
    fs.writeFileSync(tmpFile, JSON.stringify(updated, null, 2), 'utf8');
    try {
      fs.renameSync(tmpFile, targetFile);
    } catch (_) {
      fs.copyFileSync(tmpFile, targetFile);
      try { fs.unlinkSync(tmpFile); } catch (_) {}
    }
  } catch (err) {
    console.error('[Store] savePermissions error:', err);
  }
  return updated;
}
/* ------------------------------------------------------------------ *
 * paired devices
 *
 * These used to be stubs — loadDevices() always returned an empty list,
 * saveDevices() threw the data away, and newPairCode() always returned '000000'.
 * Pairing therefore issued a token that was never persisted, so every paired
 * device stopped working after a restart, and the 6-digit code was guessable.
 * ------------------------------------------------------------------ */

function devicesFile() {
  return path.join(dataDir(), 'devices.json');
}

const PAIR_CODE_TTL_MS = 10 * 60 * 1000; // 10 minutes
const MAX_DEVICES = 20;

export function loadDevices() {
  ensureDataDir();
  const f = devicesFile();
  if (!fs.existsSync(f)) return { version: 1, devices: [] };
  try {
    const raw = JSON.parse(fs.readFileSync(f, 'utf8'));
    if (!raw || typeof raw !== 'object') return { version: 1, devices: [] };
    return {
      version: raw.version ?? 1,
      devices: Array.isArray(raw.devices) ? raw.devices : []
    };
  } catch {
    return { version: 1, devices: [] };
  }
}

export function saveDevices(state) {
  ensureDataDir();
  const payload = {
    version: 1,
    devices: Array.isArray(state?.devices) ? state.devices.slice(-MAX_DEVICES) : []
  };
  const f = devicesFile();
  const tmp = `${f}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(tmp, JSON.stringify(payload, null, 2), 'utf8');
    try {
      fs.renameSync(tmp, f);
    } catch {
      fs.copyFileSync(tmp, f);
      try { fs.unlinkSync(tmp); } catch { /* best effort */ }
    }
  } catch (err) {
    console.error('[Store] saveDevices error:', err);
    return false;
  }
  return true;
}

/* ------------------------------------------------------------------ *
 * custom approval presets (P0-2, 2026-10-13)
 *
 * The four built-in presets ("严格 / 均衡 / 自主 / 完全信任") live in the App as a
 * Dart enum and are deliberately NOT stored here: their whole value is the
 * reviewed prose that ships with the binary, and a stale copy on the host could
 * disagree with the app about what a preset means. Only *user-authored*
 * presets are persisted, so the host holds no opinion about the built-ins.
 *
 * Persisted at `~/.dsh/mobile-access/approval-presets.json`, next to
 * permissions.json — a preset only ever becomes a live setting by being applied
 * through the existing permissions route, so keeping them together makes the
 * "what can change my policy" surface one directory.
 * ------------------------------------------------------------------ */

const PRESETS_FILE_NAME = 'approval-presets.json';
const MAX_CUSTOM_PRESETS = 20;

/** Ids the App owns. A custom preset must never shadow one. */
export const RESERVED_PRESET_IDS = ['strict', 'balanced', 'autonomous', 'trusted'];

function presetsFile() {
  return path.join(permissionsDir(), PRESETS_FILE_NAME);
}

export function loadPresets() {
  ensurePermissionsDir();
  const f = presetsFile();
  if (!fs.existsSync(f)) return { version: 1, presets: [] };
  try {
    const raw = JSON.parse(fs.readFileSync(f, 'utf8'));
    if (!raw || typeof raw !== 'object') return { version: 1, presets: [] };
    return {
      version: raw.version ?? 1,
      presets: Array.isArray(raw.presets) ? raw.presets : []
    };
  } catch {
    return { version: 1, presets: [] };
  }
}

export function savePresets(state) {
  ensurePermissionsDir();
  const presets = Array.isArray(state?.presets) ? state.presets.slice(0, MAX_CUSTOM_PRESETS) : [];
  const payload = { version: 1, presets };
  const target = presetsFile();
  const tmp = path.join(permissionsDir(), `${PRESETS_FILE_NAME}.${process.pid}.${Date.now()}.tmp`);
  try {
    fs.writeFileSync(tmp, JSON.stringify(payload, null, 2), 'utf8');
    try {
      fs.renameSync(tmp, target);
    } catch {
      fs.copyFileSync(tmp, target);
      try { fs.unlinkSync(tmp); } catch { /* best effort */ }
    }
  } catch (err) {
    console.error('[Store] savePresets error:', err);
    return false;
  }
  return true;
}

export function maxCustomPresets() {
  return MAX_CUSTOM_PRESETS;
}

/**
 * Record that a device just talked to the bridge.
 *
 * [fix 2026-10-17] 30s 节流：客户端 2.5s 一次轮询会把这里变成"每 2.5s 整文件
 * 重写 devices.json"——写盘放大 + 并发 read-modify-write 互相覆盖丢更新。
 * lastSeenAt 差 30 秒对设置页的"最近活跃"毫无影响。
 */
const TOUCH_THROTTLE_MS = 30 * 1000;
const _touchState = new Map(); // deviceId -> last written ms

export function touchDevice(deviceId, ip = '') {
  const now = Date.now();
  const last = _touchState.get(deviceId);
  if (last != null && now - last < TOUCH_THROTTLE_MS) return true;
  _touchState.set(deviceId, now);
  const state = loadDevices();
  const dev = state.devices.find((d) => d.id === deviceId);
  if (!dev) return false;
  dev.lastSeenAt = now;
  if (ip) dev.lastIp = ip;
  return saveDevices(state);
}

export function revokeDevice(deviceId) {
  const state = loadDevices();
  // [feat 2026-10-12] 标记 revoked 而不是删除整行：撤销后的下一次请求要能
  // 返回带 device_revoked 标记的 401（客户端据此清凭据回配对页），而那需要
  // token → 设备的映射还在。verifyToken 已拒绝 revoked 设备，安全性不变。
  const dev = state.devices.find((d) => d.id === deviceId);
  if (!dev) return false;
  if (dev.revoked === true) return false;
  dev.revoked = true;
  dev.revokedAt = Date.now();
  return saveDevices(state);
}

/**
 * Generate a 6-digit pairing code.
 * Uses crypto randomness (the old '000000' was a fixed, publicly known value)
 * and expires it, so a stale code cannot be replayed later.
 */
export function newPairCode() {
  return String(crypto.randomInt(0, 1000000)).padStart(6, '0');
}

export function pairCodeTtlMs() {
  return PAIR_CODE_TTL_MS;
}

export function newToken() { return generateToken(); }
export function hashToken(t) { return crypto.createHash('sha256').update(t || '').digest('hex'); }
