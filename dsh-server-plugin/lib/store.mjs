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
  npsHost: 'n.cnm.asia',
  npsPort: 3088,
  useHttps: false,
  // ntfy 离线推送（v1.14）。默认关闭：推送会把事件摘要发往第三方服务，
  // 必须由用户显式打开并填 topic。
  ntfyEnabled: false,
  ntfyUrl: '',
  ntfyTopic: '',
  ntfyToken: ''
};

export function loadConfig() {
  ensureDataDir();
  const f = configFile();
  if (!fs.existsSync(f)) {
    // Fresh install: mint a random token instead of shipping a known default.
    const fresh = { ...DEFAULT_CONFIG, token: generateToken() };
    try {
      fs.writeFileSync(f, JSON.stringify(fresh, null, 2), 'utf8');
    } catch (_) {}
    return fresh;
  }
  try {
    const raw = JSON.parse(fs.readFileSync(f, 'utf8'));
    const token = (raw.token && String(raw.token).trim())
      || process.env.DSH_AUTH_TOKEN
      || generateToken();
    return {
      token,
      port: Number(raw.port) || DEFAULT_CONFIG.port,
      npsHost: (raw.npsHost && String(raw.npsHost).trim()) || DEFAULT_CONFIG.npsHost,
      npsPort: Number(raw.npsPort) || DEFAULT_CONFIG.npsPort,
      useHttps: Boolean(raw.useHttps),
      ntfyEnabled: raw.ntfyEnabled === true,
      ntfyUrl: typeof raw.ntfyUrl === 'string' ? raw.ntfyUrl.trim() : '',
      ntfyTopic: typeof raw.ntfyTopic === 'string' ? raw.ntfyTopic.trim() : '',
      ntfyToken: typeof raw.ntfyToken === 'string' ? raw.ntfyToken.trim() : ''
    };
  } catch {
    return { ...DEFAULT_CONFIG, token: generateToken() };
  }
}

export function saveConfig(patch = {}) {
  ensureDataDir();
  const current = loadConfig();
  const updated = {
    ...current,
    ...patch
  };
  // Ensure types
  if (patch.token !== undefined) updated.token = String(patch.token).trim() || DEFAULT_CONFIG.token;
  if (patch.port !== undefined) updated.port = Number(patch.port) || DEFAULT_CONFIG.port;
  if (patch.npsHost !== undefined) updated.npsHost = String(patch.npsHost).trim() || DEFAULT_CONFIG.npsHost;
  if (patch.npsPort !== undefined) updated.npsPort = Number(patch.npsPort) || DEFAULT_CONFIG.npsPort;
  if (patch.useHttps !== undefined) updated.useHttps = Boolean(patch.useHttps);
  // 推送配置（v1.14）。空字符串是合法值 —— 用户清空地址/topic 就等于关掉这条
  // 通道，不能像 token 那样回退到默认值。
  if (patch.ntfyEnabled !== undefined) updated.ntfyEnabled = patch.ntfyEnabled === true;
  if (patch.ntfyUrl !== undefined) updated.ntfyUrl = String(patch.ntfyUrl || '').trim();
  if (patch.ntfyTopic !== undefined) updated.ntfyTopic = String(patch.ntfyTopic || '').trim();
  if (patch.ntfyToken !== undefined) updated.ntfyToken = String(patch.ntfyToken || '').trim();

  fs.writeFileSync(configFile(), JSON.stringify(updated, null, 2), 'utf8');
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

export function audit(action, payload = {}) {
  return auditSink.record(action, payload);
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
