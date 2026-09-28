// dsh-server-plugin 状态存储与密钥管理
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

const devicesFile = () => path.join(dataDir(), 'devices.json');
const auditFile = () => path.join(dataDir(), 'audit.log');

export function hashToken(token) {
  return crypto.createHash('sha256').update(token, 'utf8').digest('hex');
}

export function newToken() {
  return 'dsh_mb_' + crypto.randomBytes(24).toString('base64url');
}

export function newPairCode() {
  const n = crypto.randomInt(0, 1_000_000);
  return n.toString().padStart(6, '0');
}

export function loadDevices() {
  ensureDataDir();
  const f = devicesFile();
  if (!fs.existsSync(f)) {
    const init = {
      version: 1,
      devices: [
        {
          id: 'dev_legacy_admin',
          name: '默认管理员设备',
          tokenHash: hashToken('dsh_19f234dcf9fe14fc2409901e6a7bbe7e73b1'),
          role: 'readwrite',
          platform: 'android',
          createdAt: Date.now(),
          lastSeenAt: Date.now(),
          connectCount: 1,
          revoked: false
        }
      ]
    };
    fs.writeFileSync(f, JSON.stringify(init, null, 2), 'utf8');
    return init;
  }
  try {
    return JSON.parse(fs.readFileSync(f, 'utf8'));
  } catch {
    return { version: 1, devices: [] };
  }
}

export function saveDevices(state) {
  ensureDataDir();
  fs.writeFileSync(devicesFile(), JSON.stringify(state, null, 2), 'utf8');
}

export function verifyToken(token) {
  if (!token || typeof token !== 'string') return null;
  const hash = hashToken(token);
  const state = loadDevices();
  const device = state.devices.find((d) => d.tokenHash === hash);
  if (!device || device.revoked) return null;
  return device;
}

export function touchDevice(deviceId, ip = '') {
  try {
    const state = loadDevices();
    const d = state.devices.find((x) => x.id === deviceId);
    if (!d) return;
    d.lastSeenAt = Date.now();
    d.lastIp = ip || d.lastIp || '';
    d.connectCount = (d.connectCount || 0) + 1;
    saveDevices(state);
  } catch {}
}

export function roleCanWrite(device) {
  return device?.role === 'readwrite';
}

export function audit(action, meta = {}) {
  try {
    ensureDataDir();
    const line = JSON.stringify({ at: Date.now(), action, ...meta }) + '\n';
    fs.appendFileSync(auditFile(), line, 'utf8');
  } catch {}
}

export function readAudit(limit = 100) {
  try {
    const f = auditFile();
    if (!fs.existsSync(f)) return [];
    const text = fs.readFileSync(f, 'utf8');
    const lines = text.trim().split('\n').filter(Boolean);
    return lines
      .slice(-limit)
      .reverse()
      .map((l) => {
        try {
          return JSON.parse(l);
        } catch {
          return { at: 0, raw: l };
        }
      });
  } catch {
    return [];
  }
}
