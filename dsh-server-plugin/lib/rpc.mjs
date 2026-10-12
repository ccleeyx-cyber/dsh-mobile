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
  generatePairCode: 'pair/code',
  pairQrData: 'pair/qrdata'
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

    // [feat 2026-10-12] QR data for the settings page. Mints a fresh one-time
    // pair code (same machinery as the HTTP /pair/qr route) and, when the
    // qrcode package is available, renders it as a PNG data URL the page can
    // show inline. Without the package we return the payload only and the page
    // falls back to displaying the 6-digit code for manual entry.
    case ENDPOINTS.pairQrData: {
      if (typeof deps.mintPairSession !== 'function') {
        throw new Error('配对码生成器未注入');
      }
      const payload = deps.mintPairSession();
      let qrDataUrl = null;
      try {
        const { createRequire } = await import('node:module');
        const require_ = createRequire(import.meta.url);
        const buf = await require_('qrcode').toBuffer(JSON.stringify(payload), {
          type: 'png', width: 360, margin: 2
        });
        qrDataUrl = `data:image/png;base64,${buf.toString('base64')}`;
      } catch {
        // qrcode unavailable — client falls back to manual code entry.
      }
      return { ...payload, qrDataUrl };
    }

    case 'devices/list': {
      // Never return token hashes to the client. Tombstoned (revoked) devices
      // are hidden — [fix 2026-10-12] they used to stay visible after a
      // successful revoke, so the settings page looked like the revoke never
      // happened even though the device was already dead.
      const state = loadDevices();
      return state.devices
        .filter((d) => d.revoked !== true)
        .map(({ tokenHash, ...rest }) => rest);
    }

    case 'devices/revoke': {
      const id = payload?.deviceId;
      if (!id) throw new Error('deviceId is required');
      const ok = revokeDevice(id);
      // Surface failure as an RPC error so the client shows "移除失败" instead
      // of silently refreshing an unchanged list. The old code returned
      // {ok:false} inside value — the client treats value as success data.
      if (!ok) throw new Error('设备不存在或已移除');
      return { ok: true, deviceId: id };
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
