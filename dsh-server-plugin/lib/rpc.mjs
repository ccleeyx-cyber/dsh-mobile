// dsh-server-plugin RPC 通道：为 DSH 设置页提供网关、授权码与 NPS 配置管理
import os from 'node:os';
import { loadConfig, saveConfig, generateToken } from './store.mjs';

export const RPC_CHANNEL = '/dsh-mobile-bridge';

export const ENDPOINTS = {
  status: 'status',
  getConfig: 'config/get',
  updateConfig: 'config/update',
  generateToken: 'token/generate'
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
        version: '1.2.8'
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

    // 兼容老前端请求
    case 'devices/list':
    case 'audit/list':
      return [];

    default:
      throw new Error(`未知的 RPC 指令: ${endpoint}`);
  }
}
