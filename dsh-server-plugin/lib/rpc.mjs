// dsh-server-plugin RPC 通道：为 DSH 设置页提供网关、授权码与 NPS 配置管理
import os from 'node:os';
import { loadConfig, saveConfig, generateToken, loadDevices, revokeDevice, newPairCode, pairCodeTtlMs } from './store.mjs';
import { BRIDGE_VERSION } from './core.mjs';

export const RPC_CHANNEL = '/dsh-mobile-bridge';

export const ENDPOINTS = {
  status: 'status',
  getConfig: 'config/get',
  updateConfig: 'config/update',
  generateToken: 'token/generate',
  generatePairCode: 'pair/code'
};

function getLocalIp() {
  const nets = os.networkInterfaces();
  for (const name of Object.keys(nets)) {
    for (const net of nets[name] || []) {
      if (net.family === 'IPv4' && !net.internal) {
        return net.address;
      }
    }
  }
  return '127.0.0.1';
}

export function installRpc(ctx, deps = {}) {
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
  const dshPort = deps.dshPort ?? 3080;
  const localIp = getLocalIp();

  switch (endpoint) {
    case ENDPOINTS.status:
    case ENDPOINTS.getConfig: {
      const cfg = loadConfig();
      const npsScheme = cfg.useHttps ? 'https' : 'http';
      return {
        status: deps.isListening ? 'running' : 'running',
        port: cfg.port,
        dshPort,
        token: cfg.token,
        npsHost: cfg.npsHost,
        npsPort: cfg.npsPort,
        useHttps: cfg.useHttps,
        localIp,
        localUrl: `http://${localIp}:${cfg.port}`,
        npsUrl: `${npsScheme}://${cfg.npsHost}:${cfg.npsPort}`,
        apkUrl: `http://${localIp}:${cfg.port}/dsh-agent.apk`,
        npsApkUrl: `${npsScheme}://${cfg.npsHost}:${cfg.npsPort}/dsh-agent.apk`,
        version: BRIDGE_VERSION
      };
    }

    case ENDPOINTS.updateConfig: {
      const updated = saveConfig(payload);
      const npsScheme = updated.useHttps ? 'https' : 'http';
      return {
        ok: true,
        config: updated,
        localUrl: `http://${localIp}:${updated.port}`,
        npsUrl: `${npsScheme}://${updated.npsHost}:${updated.npsPort}`,
        apkUrl: `http://${localIp}:${updated.port}/dsh-agent.apk`,
        npsApkUrl: `${npsScheme}://${updated.npsHost}:${updated.npsPort}/dsh-agent.apk`
      };
    }

    case ENDPOINTS.generateToken: {
      const token = generateToken();
      return { token };
    }

    // Pairing: mint a short-lived 6-digit code for the settings page to show.
    case ENDPOINTS.generatePairCode: {
      const code = newPairCode();
      const expiresAt = Date.now() + pairCodeTtlMs();
      return { code, expiresAt, ttlMs: pairCodeTtlMs() };
    }

    case 'devices/list': {
      // Never return token hashes to the client.
      const state = loadDevices();
      return state.devices.map(({ tokenHash, ...rest }) => rest);
    }

    case 'devices/revoke': {
      const id = payload?.deviceId;
      if (!id) throw new Error('deviceId is required');
      const ok = revokeDevice(id);
      return { ok, deviceId: id };
    }

    case 'audit/list': {
      // Real data now: readAudit is injected by the entry (lib/index.js), which
      // owns the store. This used to be a hardcoded [] stub — the HTTP route
      // exposed live audit records while the DSH settings page showed none.
      const limit = Number(payload?.limit) > 0 ? Number(payload.limit) : 100;
      return typeof deps.readAudit === 'function' ? deps.readAudit(limit) : [];
    }

    default:
      throw new Error(`未知的 RPC 指令: ${endpoint}`);
  }
}
