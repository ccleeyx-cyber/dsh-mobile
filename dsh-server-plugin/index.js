/**
 * DSH Mobile Bridge & Secure Gateway
 * 
 * 作用：
 * 1. 专门为移动端（Android/iOS）提供安全隔离与认证网关。
 * 2. 拦截全网未授权扫描，必须携带预设的 Secret Token 才能访问。
 * 3. 既可以作为独立的 Node.js 网关运行（推荐，最省心），也可以作为 Cordis 插件被 DSH 加载。
 */

const http = require('http');
const url = require('url');
const WebSocket = require('ws');

// 配置项（可通过环境变量或外部传入修改）
const CONFIG = {
  BRIDGE_PORT: process.env.BRIDGE_PORT ? parseInt(process.env.BRIDGE_PORT) : 3088,
  DSH_HOST: process.env.DSH_HOST || '127.0.0.1',
  DSH_PORT: process.env.DSH_PORT ? parseInt(process.env.DSH_PORT) : 3080,
  // 核心安全密钥：请务必在部署时修改为一个复杂随机密码！
  AUTH_TOKEN: process.env.DSH_AUTH_TOKEN || 'DSH_SECURE_TOKEN_2026',
};

// 鉴权检查函数
function authenticate(req) {
  const parsedUrl = url.parse(req.url, true);
  
  // 1. 检查 Query 参数 ?token=...
  if (parsedUrl.query && parsedUrl.query.token === CONFIG.AUTH_TOKEN) {
    return true;
  }
  
  // 2. 检查 Authorization Header: Bearer <token>
  const authHeader = req.headers['authorization'];
  if (authHeader && authHeader.startsWith('Bearer ')) {
    const token = authHeader.slice(7).trim();
    if (token === CONFIG.AUTH_TOKEN) return true;
  }

  // 3. 检查自定义头 x-dsh-token
  if (req.headers['x-dsh-token'] === CONFIG.AUTH_TOKEN) {
    return true;
  }

  return false;
}

// 创建 HTTP 服务（提供健康检查与状态接口）
const server = http.createServer((req, res) => {
  const parsedUrl = url.parse(req.url, true);
  const pathname = parsedUrl.pathname;

  // 跨域 CORS 支持
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, x-dsh-token');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // 健康检查 / 鉴权验证接口（供手机 App 点击“测试连接”使用）
  if (pathname === '/health' || pathname === '/api/mobile/health') {
    const isAuthed = authenticate(req);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      code: isAuthed ? 0 : 401,
      authenticated: isAuthed,
      message: isAuthed ? 'DSH Mobile Bridge is healthy and authenticated' : 'Invalid or missing authentication token',
      dsh_upstream: `http://${CONFIG.DSH_HOST}:${CONFIG.DSH_PORT}`,
      timestamp: Date.now()
    }));
    return;
  }

  // 拦截未授权 HTTP 请求
  if (!authenticate(req)) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Unauthorized: Invalid token' }));
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Endpoint not found' }));
});

// 创建针对手机端的 WebSocket 服务
const wss = new WebSocket.Server({ noServer: true });

// 处理 HTTP 协议升级为 WebSocket（在此处完成握手前鉴权）
server.on('upgrade', (request, socket, head) => {
  const parsedUrl = url.parse(request.url, true);
  const pathname = parsedUrl.pathname;

  // 只放行 /mobile-ws 或代理 /api/remote.mux
  if (pathname !== '/mobile-ws' && pathname !== '/api/remote.mux') {
    socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
    socket.destroy();
    return;
  }

  // 严格鉴权：未携带正确 Token 直接断开连接，绝不暴露内部 DSH 接口
  if (!authenticate(request)) {
    console.warn(`[SECURITY ALERT] Blocked unauthorized connection attempt from ${request.socket.remoteAddress}`);
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }

  wss.handleUpgrade(request, socket, head, (ws) => {
    wss.emit('connection', ws, request);
  });
});

// 监听手机客户端连接
wss.on('connection', (clientWs, req) => {
  const clientIp = req.socket.remoteAddress;
  console.log(`[DSH Bridge] Mobile client connected from ${clientIp}`);

  // 连接内部的 DSH 实例（默认 localhost:3080/api/remote.mux）
  const dshTargetUrl = `ws://${CONFIG.DSH_HOST}:${CONFIG.DSH_PORT}/api/remote.mux`;
  let upstreamWs = null;

  try {
    upstreamWs = new WebSocket(dshTargetUrl);
  } catch (err) {
    console.error(`[DSH Bridge] Failed to connect to DSH upstream: ${err.message}`);
    clientWs.send(JSON.stringify({
      type: 'error',
      message: 'Failed to connect to local DSH server. Is DSH running on port ' + CONFIG.DSH_PORT + '?'
    }));
    return;
  }

  upstreamWs.on('open', () => {
    console.log(`[DSH Bridge] Successfully bridged to upstream DSH on port ${CONFIG.DSH_PORT}`);
    clientWs.send(JSON.stringify({
      type: 'system',
      event: 'connected',
      message: 'Connected to DeepSeek Harness Agent'
    }));
  });

  // 转发上游 DSH 数据到手机端（并在此进行事件结构标准化）
  upstreamWs.on('message', (data) => {
    if (clientWs.readyState === WebSocket.OPEN) {
      try {
        const text = data.toString();
        // 直接透传或增强
        clientWs.send(text);
      } catch (err) {
        clientWs.send(data);
      }
    }
  });

  upstreamWs.on('error', (err) => {
    console.error(`[DSH Bridge] Upstream error: ${err.message}`);
    if (clientWs.readyState === WebSocket.OPEN) {
      clientWs.send(JSON.stringify({
        type: 'error',
        message: `Upstream DSH Error: ${err.message}`
      }));
    }
  });

  upstreamWs.on('close', () => {
    console.log(`[DSH Bridge] Upstream DSH closed connection`);
    if (clientWs.readyState === WebSocket.OPEN) {
      clientWs.close();
    }
  });

  // 手机端发来消息，转发给 DSH 内部
  clientWs.on('message', (message) => {
    try {
      const msgStr = message.toString();
      // 如果手机发送心跳 ping，立即回复 pong
      if (msgStr === 'ping') {
        clientWs.send('pong');
        return;
      }

      if (upstreamWs && upstreamWs.readyState === WebSocket.OPEN) {
        upstreamWs.send(msgStr);
      } else {
        clientWs.send(JSON.stringify({
          type: 'error',
          message: 'Upstream DSH is not ready'
        }));
      }
    } catch (err) {
      console.error(`[DSH Bridge] Error forwarding client message: ${err.message}`);
    }
  });

  clientWs.on('close', () => {
    console.log(`[DSH Bridge] Mobile client disconnected`);
    if (upstreamWs && upstreamWs.readyState === WebSocket.OPEN) {
      upstreamWs.close();
    }
  });
});

// 导出为 Cordis 插件格式（如果需要通过 cordis.yml 挂载）
function apply(ctx, config) {
  if (config) {
    if (config.token) CONFIG.AUTH_TOKEN = config.token;
    if (config.port) CONFIG.BRIDGE_PORT = config.port;
  }
  startServer();
}

function startServer() {
  server.listen(CONFIG.BRIDGE_PORT, '0.0.0.0', () => {
    console.log('======================================================');
    console.log(`🚀 [DSH Mobile Bridge] 启动成功!`);
    console.log(`📡 监听端口: ${CONFIG.BRIDGE_PORT} (请公网映射此端口)`);
    console.log(`🔗 转发上游: http://${CONFIG.DSH_HOST}:${CONFIG.DSH_PORT}`);
    console.log(`🔑 认证 Token: ${CONFIG.AUTH_TOKEN}`);
    console.log(`📱 手机连接路径: ws://<公网IP>:${CONFIG.BRIDGE_PORT}/mobile-ws?token=${CONFIG.AUTH_TOKEN}`);
    console.log('======================================================');
  });
}

// 如果通过 `node index.js` 直接运行
if (require.main === module) {
  startServer();
}

module.exports = {
  name: 'dsh-mobile-bridge',
  apply,
  startServer,
};
