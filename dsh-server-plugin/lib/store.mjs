// dsh-server-plugin 状态存储与配置管理
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { homedir } from 'node:os';

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

const DEFAULT_CONFIG = {
  token: 'DSH_SECURE_TOKEN_2026',
  port: 3088,
  npsHost: 'n.cnm.asia',
  npsPort: 3088,
  useHttps: false
};

const LEGACY_TOKENS = [
  'DSH_SECURE_TOKEN_2026',
  'dsh_19f234dcf9fe14fc2409901e6a7bbe7e73b1'
];

export function loadConfig() {
  ensureDataDir();
  const f = configFile();
  if (!fs.existsSync(f)) {
    try {
      fs.writeFileSync(f, JSON.stringify(DEFAULT_CONFIG, null, 2), 'utf8');
    } catch (_) {}
    return { ...DEFAULT_CONFIG };
  }
  try {
    const raw = JSON.parse(fs.readFileSync(f, 'utf8'));
    return {
      token: (raw.token && String(raw.token).trim()) || DEFAULT_CONFIG.token,
      port: Number(raw.port) || DEFAULT_CONFIG.port,
      npsHost: (raw.npsHost && String(raw.npsHost).trim()) || DEFAULT_CONFIG.npsHost,
      npsPort: Number(raw.npsPort) || DEFAULT_CONFIG.npsPort,
      useHttps: Boolean(raw.useHttps)
    };
  } catch {
    return { ...DEFAULT_CONFIG };
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

  fs.writeFileSync(configFile(), JSON.stringify(updated, null, 2), 'utf8');
  return updated;
}

export function generateToken() {
  return 'dsh_' + crypto.randomBytes(16).toString('hex');
}

export function verifyToken(inputToken) {
  if (!inputToken || typeof inputToken !== 'string') return false;
  const trimmed = inputToken.trim();
  if (!trimmed) return false;
  const cfg = loadConfig();
  if (trimmed === cfg.token) return true;
  if (process.env.DSH_AUTH_TOKEN && trimmed === process.env.DSH_AUTH_TOKEN) return true;
  return false;
}

export function roleCanWrite() {
  return true;
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

export function audit(action, payload = {}) {
  const norm = typeof payload === 'object' && payload !== null ? payload : { details: payload };
  const entry = {
    id: norm.id || norm.approvalId || norm.eventId || `audit_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
    time: typeof norm.time === 'number' ? norm.time : Date.now(),
    action: norm.action || action,
    event: norm.event || action,
    sessionId: norm.sessionId || 'system',
    toolName: norm.toolName || action || 'system',
    command: norm.command || norm.reason || action || '',
    outcome: norm.outcome || (String(action).includes('reject') ? 'rejected' : String(action).includes('allow') ? 'allowed-once' : 'auto-approved'),
    reason: norm.reason || norm.error || (typeof norm === 'object' ? JSON.stringify(norm) : String(norm))
  };
  auditBuffer.unshift(entry);
  if (auditBuffer.length > AUDIT_BUFFER_SIZE) auditBuffer.pop();
  return entry;
}

export function readAudit(limit = 100) {
  const lim = typeof limit === 'number' && limit > 0 ? limit : 100;
  return auditBuffer.slice(0, lim);
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
export function loadDevices() { return { version: 1, devices: [] }; }
export function saveDevices() {}
export function touchDevice() {}
export function newPairCode() { return '000000'; }
export function newToken() { return generateToken(); }
export function hashToken(t) { return crypto.createHash('sha256').update(t || '').digest('hex'); }
