// dsh-server-plugin RPC 通道：为 DSH 设置页提供管理能力
import { audit, loadDevices, saveDevices, newToken, newPairCode, hashToken, readAudit } from './store.mjs';

export const RPC_CHANNEL = '/dsh-mobile-bridge';
export const PAIR_TTL_MS = 5 * 60_000; // 5分钟有效

export const ENDPOINTS = {
  status: 'status',
  beginPair: 'pair/begin',
  devices: 'devices/list',
  revoke: 'devices/revoke',
  setRole: 'devices/role',
  audit: 'audit/list',
  rotate: 'devices/rotate',
};

export function installRpc(ctx, deps) {
  const handler = async (endpoint, payload = {}) => {
    try {
      return { ok: true, value: await dispatch(endpoint, payload, deps) };
    } catch (err) {
      return { ok: false, error: { code: 'mobile-bridge', message: err?.message ?? String(err), details: {} } };
    }
  };

  const disposer = ctx.connection?.rpc?.handle?.(RPC_CHANNEL, handler);
  return async () => {
    try { await disposer?.(); } catch {}
  };
}

async function dispatch(endpoint, payload, deps) {
  switch (endpoint) {
    case ENDPOINTS.status:
      return deps.getStatus();

    case ENDPOINTS.beginPair: {
      const code = newPairCode();
      const session = { code, expiresAt: Date.now() + PAIR_TTL_MS, createdAt: Date.now() };
      deps.setPairSession(session);
      audit('pair/begin', { expiresAt: session.expiresAt });
      return { code, expiresAt: session.expiresAt };
    }

    case ENDPOINTS.devices:
      return loadDevices().devices.map(publicDevice);

    case ENDPOINTS.revoke: {
      const state = loadDevices();
      const device = state.devices.find((d) => d.id === payload.id);
      if (!device) throw new Error('设备不存在');
      device.revoked = true;
      device.revokedAt = Date.now();
      saveDevices(state);
      audit('revoke', { deviceId: device.id, name: device.name });
      return { revoked: true };
    }

    case ENDPOINTS.setRole: {
      const role = payload.role === 'readwrite' ? 'readwrite' : 'readonly';
      const state = loadDevices();
      const device = state.devices.find((d) => d.id === payload.id);
      if (!device) throw new Error('设备不存在');
      device.role = role;
      saveDevices(state);
      audit('set-role', { deviceId: device.id, role });
      return { role };
    }

    case ENDPOINTS.rotate: {
      const state = loadDevices();
      const device = state.devices.find((d) => d.id === payload.id);
      if (!device) throw new Error('设备不存在');
      const token = newToken();
      device.tokenHash = hashToken(token);
      device.rotatedAt = Date.now();
      saveDevices(state);
      audit('rotate', { deviceId: device.id });
      return { token };
    }

    case ENDPOINTS.audit:
      return readAudit(payload.limit ?? 200);

    default:
      throw new Error(`未知端点: ${endpoint}`);
  }
}

function publicDevice(d) {
  return {
    id: d.id,
    name: d.name,
    role: d.role,
    platform: d.platform ?? 'android',
    createdAt: d.createdAt,
    lastSeenAt: d.lastSeenAt ?? null,
    lastIp: d.lastIp ?? '',
    connectCount: d.connectCount ?? 0,
    revoked: d.revoked === true,
  };
}
