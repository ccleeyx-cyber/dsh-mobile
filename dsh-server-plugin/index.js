/**
 * DSH Mobile Bridge & Secure Gateway v2.0
 * 
 * Features:
 * 1. Mobile security & token authentication.
 * 2. Workspace & Session Management (Listing, History, New Session, Resuming).
 * 3. In-App Model & Server Settings (Switch models, query capabilities).
 * 4. Real-time Tool Execution Approval (Allow Once / Reject) via DSH $events.
 * 5. Full duplex WebSocket & REST APIs for Android / iOS clients.
 */

const http = require('http');
const url = require('url');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const WebSocket = require('ws');
const YAML = require('yaml');

// Config
const CONFIG = {
  BRIDGE_PORT: process.env.BRIDGE_PORT ? parseInt(process.env.BRIDGE_PORT) : 3088,
  DSH_HOST: process.env.DSH_HOST || '127.0.0.1',
  DSH_PORT: process.env.DSH_PORT ? parseInt(process.env.DSH_PORT) : 3080,
  AUTH_TOKENS: [
    process.env.DSH_AUTH_TOKEN,
    'DSH_SECURE_TOKEN_2026',
    'dsh_19f234dcf9fe14fc2409901e6a7bbe7e73b1'
  ].filter(Boolean),
  DSH_INTERNAL_SECRET: process.env.DSH_SECRET || 'Ci223VxbS2XsFJm0pUnm3eU_PPhG4L1A9T6AWaTu4pA',
  DSH_HOME: process.env.DSH_HOME || 'C:\\Users\\Administrator\\.dsh'
};

// Base64URL Helpers
function encodeBase64Url(value) {
  return Buffer.from(value).toString('base64').replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '');
}

function decodeBase64Url(value) {
  const BASE64URL_PATTERN = /^[A-Za-z0-9_-]*$/;
  if (!BASE64URL_PATTERN.test(value) || value.length % 4 === 1) return void 0;
  const padding = '='.repeat((4 - value.length % 4) % 4);
  const decoded = Buffer.from(value.replaceAll('-', '+').replaceAll('_', '/') + padding, 'base64');
  return encodeBase64Url(decoded) === value ? decoded : void 0;
}

// Generate DSH signed cookie for HTTP and WebSocket authentication
function generateDshCookie(authority) {
  const secret = decodeBase64Url(CONFIG.DSH_INTERNAL_SECRET);
  const name = 'dsh-auth-' + encodeBase64Url(crypto.createHash('sha256').update(authority).digest());
  const issuedAt = Date.now();
  const expiresAt = issuedAt + 86400 * 1000;
  const payload = {
    version: 1,
    authority: authority,
    issuedAt,
    expiresAt
  };
  const body = encodeBase64Url(Buffer.from(JSON.stringify(payload), 'utf8'));
  const sig = crypto.createHmac('sha256', secret).update(body).digest();
  return `${name}=v1.${body}.${encodeBase64Url(sig)}`;
}

// Check mobile client token
function authenticate(req) {
  const parsedUrl = url.parse(req.url, true);
  if (parsedUrl.query && parsedUrl.query.token && CONFIG.AUTH_TOKENS.includes(parsedUrl.query.token)) {
    return true;
  }
  const authHeader = req.headers['authorization'];
  if (authHeader && authHeader.startsWith('Bearer ')) {
    const token = authHeader.slice(7).trim();
    if (CONFIG.AUTH_TOKENS.includes(token)) return true;
  }
  if (req.headers['x-dsh-token'] && CONFIG.AUTH_TOKENS.includes(req.headers['x-dsh-token'])) {
    return true;
  }
  return false;
}

// Unary DSH RPC caller
function callDshRpc(method, payload) {
  return new Promise((resolve, reject) => {
    const authority = `${CONFIG.DSH_HOST}:${CONFIG.DSH_PORT}`;
    const cookie = generateDshCookie(authority);
    const rpcId = crypto.randomUUID();

    const postData = JSON.stringify({
      type: 'client-request',
      rpcId: rpcId,
      method: method,
      payload: payload || { args: {} }
    });

    const req = http.request({
      host: CONFIG.DSH_HOST,
      port: CONFIG.DSH_PORT,
      path: `/api/${method}`,
      method: 'POST',
      headers: {
        'Host': authority,
        'Cookie': cookie,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData)
      },
      timeout: 10000
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          if (parsed.result && parsed.result.ok === true) {
            resolve(parsed.result.value);
          } else {
            const err = (parsed.result && parsed.result.error) || { message: 'RPC Error: ' + data };
            reject(new Error(err.message || JSON.stringify(err)));
          }
        } catch (e) {
          reject(new Error(`Failed to parse RPC response: ${data.slice(0, 100)}`));
        }
      });
    });

    req.on('error', reject);
    req.on('timeout', () => {
      req.destroy();
      reject(new Error(`DSH RPC ${method} timed out`));
    });
    req.write(postData);
    req.end();
  });
}

// Workspace & Session Data Loader
function getWorkspacesData() {
  const workspaceJsonPath = path.join(CONFIG.DSH_HOME, 'storages', 'workspace.json');
  const projCacheDir = path.join(CONFIG.DSH_HOME, 'storages', 'session_projcache', 'sessions');

  if (!fs.existsSync(workspaceJsonPath)) {
    return [];
  }

  try {
    const rawWs = JSON.parse(fs.readFileSync(workspaceJsonPath, 'utf8'));
    const wsTable = rawWs.tables && rawWs.tables.workspaces ? rawWs.tables.workspaces : {};
    const result = [];

    for (const [wsId, wsInfo] of Object.entries(wsTable)) {
      const sessionIds = wsInfo.sessionIds || [];
      const sessionList = [];

      for (const sId of sessionIds) {
        const cleanId = sId.startsWith('session-') ? sId.replace('session-', '') : sId;
        const candidates = [
          path.join(projCacheDir, `${sId}.json`),
          path.join(projCacheDir, `session-${cleanId}.json`),
          path.join(projCacheDir, `${cleanId}.json`)
        ];

        let sessionMeta = {
          sessionId: sId,
          title: sId,
          firstPrompt: '',
          lastPromptAt: 0,
          model: '',
          lastSeq: 0
        };

        for (const cPath of candidates) {
          if (fs.existsSync(cPath)) {
            try {
              const cache = JSON.parse(fs.readFileSync(cPath, 'utf8'));
              const rows = cache.record?.rows || {};
              sessionMeta.title = rows.title?.val || rows.titleInput?.val?.first?.text || sId;
              sessionMeta.firstPrompt = rows.titleInput?.val?.first?.text || '';
              sessionMeta.lastPromptAt = rows.sessionListMetadata?.val?.lastPromptAt || cache.record?.identity?.createdAt || 0;
              sessionMeta.model = rows.modelSelection?.val?.lastUsed?.model || '';
              sessionMeta.lastSeq = rows.turnBoundary?.seq || rows.tokenUsage?.seq || 0;
              break;
            } catch (err) {}
          }
        }
        sessionList.push(sessionMeta);
      }

      // Sort sessions by lastPromptAt desc
      sessionList.sort((a, b) => (b.lastPromptAt || 0) - (a.lastPromptAt || 0));

      result.push({
        workspaceId: wsId,
        title: wsInfo.title || path.basename(wsInfo.path || ''),
        path: wsInfo.path || '',
        createdAt: wsInfo.createdAt,
        updatedAt: wsInfo.updatedAt,
        sessionCount: sessionList.length,
        sessions: sessionList
      });
    }

    // Sort workspaces by updatedAt desc
    result.sort((a, b) => new Date(b.updatedAt || 0) - new Date(a.updatedAt || 0));
    return result;
  } catch (err) {
    console.error('[Workspaces] Error reading workspace data:', err);
    return [];
  }
}

// Session History Loader
async function getSessionHistory(sessionId) {
  // First find the lastSeq from cache
  const projCacheDir = path.join(CONFIG.DSH_HOME, 'storages', 'session_projcache', 'sessions');
  const cleanId = sessionId.startsWith('session-') ? sessionId.replace('session-', '') : sessionId;
  const candidates = [
    path.join(projCacheDir, `${sessionId}.json`),
    path.join(projCacheDir, `session-${cleanId}.json`),
    path.join(projCacheDir, `${cleanId}.json`)
  ];

  let targetSeq = 0;
  let sessionTitle = sessionId;

  for (const cPath of candidates) {
    if (fs.existsSync(cPath)) {
      try {
        const cache = JSON.parse(fs.readFileSync(cPath, 'utf8'));
        const rows = cache.record?.rows || {};
        targetSeq = rows.turnBoundary?.seq || rows.tokenUsage?.seq || 0;
        sessionTitle = rows.title?.val || rows.titleInput?.val?.first?.text || sessionId;
        break;
      } catch (_) {}
    }
  }

  async function queryPage(seq) {
    return await callDshRpc('session/page', {
      args: {
        request: {
          address: { kind: 'session', sessionId: sessionId },
          throughSeq: seq > 0 ? seq : 999999,
          maxMessages: 50
        }
      }
    });
  }

  let pageData;
  try {
    pageData = await queryPage(targetSeq);
  } catch (err) {
    // If "through seq X is past cursor Y", retry with cursor Y
    const match = err.message.match(/cursor\s+(\d+)/i);
    if (match && match[1]) {
      const actualCursor = parseInt(match[1]);
      pageData = await queryPage(actualCursor);
    } else {
      throw err;
    }
  }

  // Parse pageData.records into ChatMessage objects
  const records = pageData?.records || [];
  const messages = [];

  for (const r of records) {
    if (r.type === 'event' && r.event) {
      const ev = r.event;
      if (ev.type === 'user/message') {
        const msg = ev.data?.message;
        let textContent = '';
        if (Array.isArray(msg?.content)) {
          textContent = msg.content
            .filter(c => c.type === 'text')
            .map(c => c.text)
            .join('\n');
        } else if (typeof msg?.content === 'string') {
          textContent = msg.content;
        }

        messages.push({
          id: ev.data?.id || `user_${ev.seq}`,
          role: 'user',
          content: textContent,
          time: ev.time,
          seq: ev.seq,
          turn: ev.data?.turn
        });
      } else if (ev.type === 'assistant/message') {
        const msg = ev.data?.message;
        let textContent = '';
        let thinkingContent = '';
        const tools = [];

        if (Array.isArray(msg?.content)) {
          for (const block of msg.content) {
            if (block.type === 'text') {
              textContent += block.text || '';
            } else if (block.type === 'reasoning') {
              thinkingContent += block.text || '';
            } else if (block.type === 'tool-call') {
              tools.push({
                id: block.id,
                name: block.name,
                input: block.arguments || '',
                output: '',
                isRunning: false
              });
            }
          }
        }

        // Check if stream chunks or finish has reasoning
        if (!thinkingContent && Array.isArray(ev.data?.stream)) {
          for (const s of ev.data.stream) {
            if (s.chunk?.block?.type === 'reasoning') {
              thinkingContent += s.chunk.block.text || '';
            }
          }
        }

        messages.push({
          id: ev.data?.id || `assistant_${ev.seq}`,
          role: 'assistant',
          content: textContent,
          thinking: thinkingContent || null,
          tools: tools,
          time: ev.time,
          seq: ev.seq,
          turn: ev.data?.turn
        });
      }
    }
  }

  return {
    sessionId,
    title: sessionTitle,
    messages
  };
}

// Settings Helpers
function getSettingsData() {
  const settingsYamlPath = path.join(CONFIG.DSH_HOME, 'settings.yaml');
  let currentModel = 'cn:deepseek-v4.1-flash';
  let currentProvider = 'wb';
  let availableModels = [];

  if (fs.existsSync(settingsYamlPath)) {
    try {
      const content = fs.readFileSync(settingsYamlPath, 'utf8');
      const doc = YAML.parse(content) || {};

      if (doc['agent-default-model']) {
        currentModel = doc['agent-default-model'].model || currentModel;
        currentProvider = doc['agent-default-model'].provider || currentProvider;
      }

      if (doc['llm-pi-ai']?.providers?.wb?.models) {
        availableModels = doc['llm-pi-ai'].providers.wb.models.map(m => ({
          id: m.id,
          name: m.name || m.id,
          contextWindow: m.contextWindow,
          maxTokens: m.maxTokens
        }));
      }
    } catch (err) {
      console.error('[Settings] Error parsing settings.yaml:', err);
    }
  }

  return {
    currentModel,
    currentProvider,
    availableModels,
    dshHost: `${CONFIG.DSH_HOST}:${CONFIG.DSH_PORT}`,
    bridgePort: CONFIG.BRIDGE_PORT
  };
}

function updateDefaultModel(newModelId) {
  const settingsYamlPath = path.join(CONFIG.DSH_HOME, 'settings.yaml');
  if (!fs.existsSync(settingsYamlPath)) {
    throw new Error('settings.yaml does not exist');
  }

  const content = fs.readFileSync(settingsYamlPath, 'utf8');
  const doc = YAML.parseDocument(content);

  doc.setIn(['agent-default-model', 'model'], newModelId);
  fs.writeFileSync(settingsYamlPath, doc.toString(), 'utf8');

  return { ok: true, currentModel: newModelId };
}

// Approval Management State
const pendingApprovals = new Map(); // id -> { id, eventId, clientId, sessionId, toolName, reason, callId, createdAt }
let activeEventsWs = null;
let currentEventsClientId = null;

// Connected Mobile WebSocket Clients
const mobileClients = new Set();

function broadcastToMobileClients(msgObj) {
  const text = JSON.stringify(msgObj);
  for (const client of mobileClients) {
    if (client.readyState === WebSocket.OPEN) {
      try {
        client.send(text);
      } catch (err) {}
    }
  }
}

// Persistent Upstream Events Listener (for tool approvals)
function connectUpstreamEvents() {
  const authority = `${CONFIG.DSH_HOST}:${CONFIG.DSH_PORT}`;
  const dshCookie = generateDshCookie(authority);
  const targetUrl = `ws://${authority}/api/remote.mux`;

  console.log(`[DSH Events] Connecting to upstream $events on ${targetUrl}...`);

  try {
    const ws = new WebSocket(targetUrl, {
      headers: {
        'Host': authority,
        'Cookie': dshCookie
      }
    });

    activeEventsWs = ws;

    ws.on('open', () => {
      console.log('[DSH Events] Connected to upstream WebSocket. Opening $events stream...');
      ws.send(JSON.stringify({
        type: 'open',
        streamId: 'gw-events-stream',
        endpoint: '$events',
        payload: { args: {} }
      }));
    });

    ws.on('message', (data) => {
      try {
        const frame = JSON.parse(data.toString());
        if (frame.type === 'item' && frame.value) {
          const val = frame.value;

          // 1. Ready frame
          if (val.type === 'ready') {
            currentEventsClientId = val.clientId;
            console.log(`[DSH Events] $events stream ready with clientId: ${currentEventsClientId}`);
          }
          // 2. Approval Request frame
          else if (val.type === 'request' && val.event === 'approval/request') {
            console.log(`[DSH Approval] Received approval request: id=${val.id}, agent=${val.agent}, tool=${val.request?.toolName}`);
            const approval = {
              id: val.id,
              eventId: val.id,
              clientId: currentEventsClientId,
              sessionId: val.agent || 'default',
              toolName: val.request?.toolName || 'Unknown Tool',
              reason: val.request?.reason || '',
              callId: val.request?.callId || '',
              createdAt: Date.now()
            };

            pendingApprovals.set(val.id, approval);

            // Broadcast to all mobile clients
            broadcastToMobileClients({
              type: 'approval_request',
              approval: approval
            });
          }
          // 3. User questions or other interactions
          else if (val.type === 'request' && val.event === 'user-questions/request') {
            console.log(`[DSH Events] Received user question request:`, val);
            const question = {
              id: val.id,
              eventId: val.id,
              clientId: currentEventsClientId,
              sessionId: val.agent || 'default',
              toolName: 'user_question',
              reason: val.request?.question || 'User input needed',
              options: val.request?.options || [],
              createdAt: Date.now()
            };
            pendingApprovals.set(val.id, question);
            broadcastToMobileClients({
              type: 'approval_request',
              approval: question
            });
          }
        }
      } catch (err) {
        console.error('[DSH Events] Error parsing upstream message:', err);
      }
    });

    ws.on('close', (code, reason) => {
      console.warn(`[DSH Events] Upstream events socket closed: ${code}, ${reason?.toString() || ''}. Reconnecting in 3s...`);
      activeEventsWs = null;
      setTimeout(connectUpstreamEvents, 3000);
    });

    ws.on('error', (err) => {
      console.error(`[DSH Events] Upstream events error: ${err.message}`);
    });
  } catch (err) {
    console.error(`[DSH Events] Error launching upstream socket: ${err.message}. Retrying in 5s...`);
    setTimeout(connectUpstreamEvents, 5000);
  }
}

// Respond to an approval request
async function respondApproval(eventId, outcome) {
  const approval = pendingApprovals.get(eventId);
  if (!approval) {
    throw new Error(`Approval request with ID ${eventId} not found or expired`);
  }

  console.log(`[DSH Approval] Responding to ${eventId} with outcome: ${outcome}`);

  // Call DSH RPC $events/result
  const result = await callDshRpc('$events/result', {
    clientId: approval.clientId,
    eventId: approval.eventId,
    outcome: {
      kind: 'result',
      value: outcome // 'allowed-once' or 'rejected'
    }
  });

  pendingApprovals.delete(eventId);

  // Broadcast settlement to all mobile clients
  broadcastToMobileClients({
    type: 'approval_settled',
    eventId: eventId,
    outcome: outcome
  });

  return result;
}

// Start HTTP Server
const server = http.createServer(async (req, res) => {
  const parsedUrl = url.parse(req.url, true);
  const pathname = parsedUrl.pathname;

  // CORS Headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, x-dsh-token');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // Health check endpoint
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

  // Security gate
  if (!authenticate(req)) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Unauthorized: Invalid token' }));
    return;
  }

  // Helper to read JSON request body
  function readBody() {
    return new Promise((resolve) => {
      let body = '';
      req.on('data', chunk => body += chunk);
      req.on('end', () => {
        try {
          resolve(JSON.parse(body || '{}'));
        } catch (_) {
          resolve({});
        }
      });
    });
  }

  try {
    // 1. GET /api/mobile/workspaces
    if (pathname === '/api/mobile/workspaces' && req.method === 'GET') {
      const data = getWorkspacesData();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, workspaces: data }));
      return;
    }

    // 2. GET /api/mobile/sessions/:id
    if (pathname.startsWith('/api/mobile/sessions/') && req.method === 'GET') {
      const sessionId = pathname.replace('/api/mobile/sessions/', '').trim();
      const history = await getSessionHistory(sessionId);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, data: history }));
      return;
    }

    // 3. POST /api/mobile/sessions/create
    if (pathname === '/api/mobile/sessions/create' && req.method === 'POST') {
      const body = await readBody();
      const result = await callDshRpc('session/create', {
        args: {
          request: {
            workspaceId: body.workspaceId,
            cwd: body.cwd
          }
        }
      });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, session: result }));
      return;
    }

    // 4. POST /api/mobile/sessions/prompt
    if (pathname === '/api/mobile/sessions/prompt' && req.method === 'POST') {
      const body = await readBody();
      const result = await callDshRpc('session/prompt', {
        args: {
          request: {
            requestId: crypto.randomUUID(),
            sessionId: body.sessionId,
            mode: 'queue',
            content: [{ type: 'text', text: body.text || '' }]
          }
        }
      });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, result }));
      return;
    }

    // 5. POST /api/mobile/sessions/cancel
    if (pathname === '/api/mobile/sessions/cancel' && req.method === 'POST') {
      const body = await readBody();
      const result = await callDshRpc('session/cancel', {
        args: {
          request: {
            sessionId: body.sessionId
          }
        }
      });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, result }));
      return;
    }

    // 6. GET /api/mobile/settings
    if (pathname === '/api/mobile/settings' && req.method === 'GET') {
      const settings = getSettingsData();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, settings }));
      return;
    }

    // 7. POST /api/mobile/settings/model
    if (pathname === '/api/mobile/settings/model' && req.method === 'POST') {
      const body = await readBody();
      if (!body.model) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Missing model in body' }));
        return;
      }
      const updated = updateDefaultModel(body.model);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, updated }));
      return;
    }

    // 8. GET /api/mobile/approvals
    if (pathname === '/api/mobile/approvals' && req.method === 'GET') {
      const list = Array.from(pendingApprovals.values());
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, approvals: list }));
      return;
    }

    // 9. POST /api/mobile/approval
    if (pathname === '/api/mobile/approval' && req.method === 'POST') {
      const body = await readBody();
      const eventId = body.eventId || body.id;
      const outcome = body.outcome; // 'allowed-once' or 'rejected'

      if (!eventId || !outcome) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Missing eventId or outcome' }));
        return;
      }

      await respondApproval(eventId, outcome);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, message: `Approval ${outcome} recorded` }));
      return;
    }

    // 404
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Endpoint not found' }));
  } catch (err) {
    console.error(`[HTTP] Error handling ${pathname}:`, err);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: err.message }));
  }
});

// Mobile WebSocket Server
const wss = new WebSocket.Server({ noServer: true });

server.on('upgrade', (request, socket, head) => {
  const parsedUrl = url.parse(request.url, true);
  const pathname = parsedUrl.pathname;

  if (pathname !== '/mobile-ws' && pathname !== '/api/remote.mux') {
    socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
    socket.destroy();
    return;
  }

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

wss.on('connection', (clientWs, req) => {
  const clientIp = req.socket.remoteAddress;
  console.log(`[DSH Bridge] Mobile client connected from ${clientIp}`);

  mobileClients.add(clientWs);

  // Send initial state & pending approvals
  clientWs.send(JSON.stringify({
    type: 'system',
    event: 'connected',
    message: 'Connected to DeepSeek Harness Agent',
    pendingApprovals: Array.from(pendingApprovals.values())
  }));

  // Upstream DSH multiplexed stream for this client session
  const authority = `${CONFIG.DSH_HOST}:${CONFIG.DSH_PORT}`;
  const dshCookie = generateDshCookie(authority);
  const dshTargetUrl = `ws://${authority}/api/remote.mux`;
  let upstreamWs = null;

  try {
    upstreamWs = new WebSocket(dshTargetUrl, {
      headers: {
        'Host': authority,
        'Cookie': dshCookie
      }
    });

    upstreamWs.on('message', (data) => {
      if (clientWs.readyState === WebSocket.OPEN) {
        try {
          const raw = data.toString();
          // Forward stream items to mobile
          clientWs.send(raw);
        } catch (_) {
          clientWs.send(data);
        }
      }
    });

    upstreamWs.on('error', (err) => {
      console.error(`[DSH Bridge] Upstream error: ${err.message}`);
    });
  } catch (err) {
    console.error('[DSH Bridge] Failed to connect upstream for client:', err);
  }

  // Handle mobile client messages
  clientWs.on('message', async (message) => {
    try {
      const msgStr = message.toString();
      if (msgStr === 'ping') {
        clientWs.send('pong');
        return;
      }

      const json = JSON.parse(msgStr);

      // 1. Approval response from client
      if (json.type === 'approval_response') {
        const { eventId, outcome } = json;
        if (eventId && outcome) {
          try {
            await respondApproval(eventId, outcome);
            clientWs.send(JSON.stringify({ type: 'approval_ack', eventId, outcome }));
          } catch (err) {
            clientWs.send(JSON.stringify({ type: 'error', message: err.message }));
          }
        }
        return;
      }

      // 2. Chat prompt from client
      if (json.type === 'chat' || json.method === 'session/send') {
        const sessionId = json.sessionId || json.params?.sessionId || 'default';
        const content = json.content || json.params?.content || json.params?.message || '';

        try {
          await callDshRpc('session/prompt', {
            args: {
              request: {
                requestId: crypto.randomUUID(),
                sessionId: sessionId,
                mode: 'queue',
                content: [{ type: 'text', text: content }]
              }
            }
          });
        } catch (err) {
          clientWs.send(JSON.stringify({ type: 'error', message: 'Prompt failed: ' + err.message }));
        }
        return;
      }

      // 3. Raw passthrough if needed
      if (upstreamWs && upstreamWs.readyState === WebSocket.OPEN) {
        upstreamWs.send(msgStr);
      }
    } catch (err) {
      console.error(`[DSH Bridge] Error handling client message: ${err.message}`);
    }
  });

  clientWs.on('close', () => {
    console.log(`[DSH Bridge] Mobile client disconnected`);
    mobileClients.delete(clientWs);
    if (upstreamWs && upstreamWs.readyState === WebSocket.OPEN) {
      upstreamWs.close();
    }
  });
});

function startServer() {
  server.listen(CONFIG.BRIDGE_PORT, '0.0.0.0', () => {
    console.log('======================================================');
    console.log(`🚀 [DSH Mobile Bridge v2.0] 启动成功!`);
    console.log(`📡 监听端口: ${CONFIG.BRIDGE_PORT} (请公网映射此端口)`);
    console.log(`🔗 转发上游: http://${CONFIG.DSH_HOST}:${CONFIG.DSH_PORT}`);
    console.log(`🔑 支持的 Token: ${CONFIG.AUTH_TOKENS.join(', ')}`);
    console.log('======================================================');

    // Launch background upstream $events listener
    connectUpstreamEvents();
  });
}

if (require.main === module) {
  startServer();
}

module.exports = {
  name: 'dsh-mobile-bridge',
  startServer,
};
