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
  pairQrData: 'pair/qrdata',
  // [feat 2026-10-21] 远程接入的实时状态。
  //
  // 为什么要这个 RPC：provider 是在**电脑端设置页**选的，而隧道是异步建立的
  // （cloudflared 要先拿到域名、再连上边缘才算 ready），用户在那一页必须能当场
  // 看到"成了没有"，而不是跑到手机或命令行去确认。
  remoteAccess: 'remote-access/status'
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

  // [fix 2026-10-15] 改用 `ctx.inject(['webServer'], …)` 挂自己的前缀路由，
  // 不再走 `ctx.connection.rpc.handle()`。
  //
  // 为什么必须换：`rpc.handle()` 在当前引擎版本里对外部插件**不可用**。
  // 它内部是 `handle: (channel, handler) => this.register(owner, channel, handler)`
  // （dsh-client-connection/lib/index.js:576），而 register 的实现是
  // `owner.effect(() => owner.webServer.register(route), …)`（同文件 :656）——
  // 它拿**连接服务自己**的 ctx 去访问 webServer。但 connection 声明的 inject 只有
  // `['credentials']`（:798），根本没有 webServer，于是每次调用都抛
  // `cannot get property "webServer" without inject`（cordis/lib/index.js:675）。
  //
  // 抛错发生在引擎自己的 fiber 上，插件无论怎么声明 inject 都绕不开。
  // 引擎给自家 `/api` 路由用的正是另一条路：`ctx.inject(['webServer'], cb)`
  // （:820）—— 同一个 ctx API，插件现在也用它。
  //
  // 为什么不用插件的静态 inject 声明去拿 webServer：声明 `webServer` 会让整个
  // apply 被推迟到该服务就绪之后，而 connection 依赖 webRuntime、webRuntime 又要
  // 等 webserver 绑定端口之后才 provide —— 互相等待，实测 apply 排不上队。
  // `ctx.inject` 是运行时的、只推迟它自己的回调，不影响插件主体。
  const channel = RPC_CHANNEL;

  const register = (webCtx) => {
    try {
      const fetchHandler = createRpcFetchHandler(handler);
      webCtx.effect(
        () => webCtx.webServer.register({
          kind: 'prefix',
          path: channel,
          handler: async (req, res) => {
            await bridgeRpcRequest(req, res, fetchHandler);
          },
        }),
        `dsh-mobile-bridge: ${channel} rpc channel`,
      );
      console.log(`[dsh-mobile-bridge] RPC 通道已注册：${channel}`);
    } catch (err) {
      console.error('[dsh-mobile-bridge] RPC 通道注册失败：', err?.message ?? String(err));
    }
  };

  try {
    if (typeof ctx?.inject === 'function') {
      const fiber = ctx.inject(['webServer'], register);
      return async () => {
        try { await fiber?.dispose?.(); } catch {}
      };
    }
    console.error('[dsh-mobile-bridge] ctx.inject 不可用，无法注册 RPC 通道。');
  } catch (err) {
    console.error('[dsh-mobile-bridge] ctx.inject 调用失败：', err?.message ?? String(err));
  }
  return async () => {};
}

/**
 * Wire format for the browser↔settings-page RPC channel.
 *
 * Mirrors the engine's own connection protocol
 * (dsh-client-connection/lib/index.js:1212-1231 on the browser side,
 * `clientRequestSchema` on the server side) so the unmodified client.js keeps
 * working: request `{type:'client-request', rpcId, method, payload}`, answer
 * `{type:'server-response', rpcId, result}` where `result` is
 * `{ok:true, value}` or `{ok:false, error:{code,message}}`.
 */
function createRpcFetchHandler(handler) {
  return async function fetchHandler(request) {
    const endpoint = endpointFromPath(RPC_CHANNEL, new URL(request.url).pathname);
    if (request.method !== 'POST' || endpoint === undefined) {
      return new Response('not found', { status: 404 });
    }
    if ((request.headers.get('content-type') ?? '').split(';', 1)[0]?.trim().toLowerCase() !== 'application/json') {
      return new Response('content type must be application/json', { status: 415 });
    }
    let message;
    try {
      message = await request.json();
    } catch {
      return new Response('body is not JSON', { status: 400 });
    }
    if (message?.type !== 'client-request' || typeof message.rpcId !== 'string') {
      return Response.json({
        type: 'server-response',
        rpcId: typeof message?.rpcId === 'string' ? message.rpcId : 'invalid-request',
        result: { ok: false, error: { code: 'gateway/bad-request', message: 'invalid client-request message', details: { issues: [] } } },
      });
    }
    // The path segment and the envelope's method must agree, exactly as the
    // engine's own channel requires (same file, :689).
    if (message.method !== endpoint) {
      return Response.json({
        type: 'server-response',
        rpcId: message.rpcId,
        result: { ok: false, error: { code: 'gateway/bad-request', message: `method ${JSON.stringify(message.method)} does not match endpoint ${JSON.stringify(endpoint)}`, details: { issues: [] } } },
      });
    }
    try {
      const result = await handler(endpoint, message.payload);
      return Response.json({ type: 'server-response', rpcId: message.rpcId, result });
    } catch (error) {
      return new Response(`handler failure: ${String(error)}`, { status: 500 });
    }
  };
}

/** Node req/res → Fetch Request → write the Response back out. */
async function bridgeRpcRequest(req, res, fetchHandler) {
  const url = `http://127.0.0.1${req.url ?? '/'}`;
  const headers = new Headers();
  for (const [key, value] of Object.entries(req.headers)) {
    if (typeof value === 'string') headers.set(key, value);
  }
  const hasBody = req.method !== 'GET' && req.method !== 'HEAD';
  const request = new Request(url, {
    method: req.method ?? 'GET',
    headers,
    ...(hasBody ? { body: await readAll(req), duplex: 'half' } : {}),
  });
  const response = await fetchHandler(request);
  res.writeHead(response.status, Object.fromEntries(response.headers));
  const body = response.body ? Buffer.from(await response.arrayBuffer()) : undefined;
  res.end(body);
}

/** Collect a request body with a hard ceiling, so a bad actor cannot OOM us. */
function readAll(req, limit = 2 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error('request body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

/** Extract `<endpoint>` from `<channel>/<endpoint>`, rejecting empty/dot segments. */
function endpointFromPath(channel, pathname) {
  if (!pathname.startsWith(`${channel}/`)) return undefined;
  const endpoint = pathname.slice(channel.length + 1);
  if (endpoint.split('/').some((seg) => seg === '' || seg === '.' || seg === '..' || !/^[A-Za-z0-9_$.-]+$/.test(seg))) {
    return undefined;
  }
  return endpoint;
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
        // [refactor 2026-10-21] 远程接入的**模型**（provider + nps 子对象）。
        // 下面三个顶层字段是派生值，只为兼容旧面板/旧客户端；新代码认这一份。
        remoteAccess: cfg.remoteAccess,
        npsHost: cfg.npsHost,
        npsPort: cfg.npsPort,
        useHttps: cfg.useHttps,
        localIp,
        localUrl: `http://${localIp}:${cfg.port}`,
        // npsUrl 只在 provider=nps 时有意义；其余档公网地址由网关运行时决定。
        npsUrl: cfg.remoteAccess?.provider === 'nps'
          ? `${npsScheme}://${cfg.npsHost}:${cfg.npsPort}`
          : null,
        // [cleanup 2026-10-21] 不再回 apkUrl / npsApkUrl：网关不托管安装包，
        // 一切以 GitHub Releases 为准（设置页自己给 Releases 链接）。
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
        npsUrl: `${npsScheme}://${updated.npsHost}:${updated.npsPort}`
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

    // [feat 2026-10-21] 远程接入实时状态（与 HTTP GET /api/mobile/remote-access
    // 同一份实现，由 index.js 注入 —— 隧道进程状态在那边，不能在这里另算一份）。
    case ENDPOINTS.remoteAccess: {
      if (typeof deps.getRemoteAccess !== 'function') {
        throw new Error('远程接入状态未注入');
      }
      return deps.getRemoteAccess();
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
