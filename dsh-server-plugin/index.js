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
              const follower = getSessionFollower(sId);
              sessionMeta.isRunning = (follower && follower.isRunning) || rows.turnBoundary?.val?.openTurnStartSeq != null || activePrompts.has(sId) || activePrompts.has(sId.replace('session-', ''));
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

  const fullId = normalizeSessionId(sessionId);
  followSession(fullId);
  const follower = getSessionFollower(fullId);

  let targetSeq = 0;
  let sessionTitle = sessionId;
  let isSessionRunning = (follower && follower.isRunning) || false;

  for (const cPath of candidates) {
    if (fs.existsSync(cPath)) {
      try {
        const cache = JSON.parse(fs.readFileSync(cPath, 'utf8'));
        const rows = cache.record?.rows || {};
        targetSeq = rows.turnBoundary?.seq || rows.tokenUsage?.seq || 0;
        sessionTitle = rows.title?.val || rows.titleInput?.val?.first?.text || sessionId;
        
        const hasPrompt = activePrompts.has(sessionId) || activePrompts.has(cleanId) || activePrompts.has(`session-${cleanId}`);
        if (hasPrompt) {
          const pTime = activePrompts.get(sessionId) || activePrompts.get(cleanId) || activePrompts.get(`session-${cleanId}`);
          if (Date.now() - pTime > 4000 && rows.turnBoundary?.val?.openTurnStartSeq == null) {
            activePrompts.delete(sessionId);
            activePrompts.delete(cleanId);
            activePrompts.delete(`session-${cleanId}`);
          }
        }
        isSessionRunning = (follower && follower.isRunning) || rows.turnBoundary?.val?.openTurnStartSeq != null || activePrompts.has(sessionId) || activePrompts.has(cleanId) || activePrompts.has(`session-${cleanId}`);
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

  // If the session is actively generating, and the in-flight turn hasn't committed to records yet:
  if (follower && (follower.isRunning || follower.textBuffer || follower.thinkingBuffer)) {
    isSessionRunning = true;
    if (messages.length === 0 || messages[messages.length - 1].role === 'user') {
      messages.push({
        id: `in_flight_${cleanId}_${Date.now()}`,
        role: 'assistant',
        content: follower.textBuffer || '',
        thinking: follower.thinkingBuffer || null,
        tools: follower.tools || [],
        time: Date.now(),
        seq: 999999,
        turn: 999999,
        isStreaming: follower.isRunning
      });
    }
  }

  return {
    sessionId,
    title: sessionTitle,
    isRunning: isSessionRunning,
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

// Permission & Security Configuration
const PERMISSIONS_FILE = path.join(CONFIG.DSH_HOME, 'mobile-access', 'permissions.json');
const PERSONAS_FILE = path.join(CONFIG.DSH_HOME, 'mobile-access', 'personas.json');

const DEFAULT_PERMISSIONS = {
  defaultPolicy: 'ask', // 'ask' | 'auto-read' | 'danger-full-access'
  sandboxMode: 'workspace-write', // 'sandboxed' | 'workspace-write' | 'danger-full-access'
  maxSteps: 30,
  protectGit: true,
  sessionPolicies: {} // sessionId -> policy
};

function getPermissions() {
  try {
    if (fs.existsSync(PERMISSIONS_FILE)) {
      const data = JSON.parse(fs.readFileSync(PERMISSIONS_FILE, 'utf8'));
      return { ...DEFAULT_PERMISSIONS, ...data };
    }
  } catch (e) {
    console.error('Error reading permissions file:', e);
  }
  return { ...DEFAULT_PERMISSIONS };
}

function savePermissions(newPerms) {
  try {
    const dir = path.dirname(PERMISSIONS_FILE);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(PERMISSIONS_FILE, JSON.stringify(newPerms, null, 2), 'utf8');
    return true;
  } catch (e) {
    console.error('Error saving permissions file:', e);
    return false;
  }
}

// Preset and Custom Agent Personas
const DEFAULT_PERSONAS = [
  {
    id: 'fullstack',
    title: '全栈研发架构师 (Fullstack Architect)',
    icon: 'code',
    description: '擅长端到端架构设计、高质量代码重构与工程规范',
    prompt: '你是一名资深全栈研发架构师，精通前端、后端与系统架构。在编写代码时遵循Clean Architecture与工程最佳实践，代码具备健壮性与高可读性。',
    isCustom: false
  },
  {
    id: 'bug_hunter',
    title: '缺陷定位专家 (Bug Hunter)',
    icon: 'bug',
    description: '快速定位复杂报错、逻辑异常及并发竞争条件',
    prompt: '你是一名专家级Bug分析师。专注于排查复杂报错、逻辑缺陷、内存泄漏和并发问题。提供精准的根因分析及最小化安全补丁。',
    isCustom: false
  },
  {
    id: 'devops',
    title: '极客终端运维 (DevOps Ninja)',
    icon: 'terminal',
    description: '熟练编写 Shell / PowerShell / Docker 脚本与 CI/CD 流水线',
    prompt: '你是一名经验丰富的Linux/Windows运维与DevOps专家，精通Shell、PowerShell、Docker与CI/CD自动化，善于编写高效的自动化运维脚本。',
    isCustom: false
  },
  {
    id: 'auditor',
    title: '安全代码审计 (Security Auditor)',
    icon: 'shield',
    description: '代码安全合规检查，防范提权、注入与敏感信息泄露',
    prompt: '你是一名代码安全与漏洞审计专家，专注于识别SQL注入、XSS、提权漏洞、硬编码密钥及OWASP Top 10风险，并给出严格的安全加固建议。',
    isCustom: false
  }
];

function getPersonas() {
  try {
    if (fs.existsSync(PERSONAS_FILE)) {
      const data = JSON.parse(fs.readFileSync(PERSONAS_FILE, 'utf8'));
      if (Array.isArray(data) && data.length > 0) return data;
    }
  } catch (e) {}
  return DEFAULT_PERSONAS;
}

function savePersonas(list) {
  try {
    const dir = path.dirname(PERSONAS_FILE);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(PERSONAS_FILE, JSON.stringify(list, null, 2), 'utf8');
    return true;
  } catch (e) {
    return false;
  }
}

// Audit Logs Ring Buffer (last 100 entries)
const auditLogs = [];
function logAudit(entry) {
  auditLogs.unshift(entry);
  if (auditLogs.length > 100) auditLogs.pop();
}

function isCommandReadOnly(cmdStr, toolName) {
  if (toolName === 'read_file' || toolName === 'view_file' || toolName === 'search_web' || toolName === 'list_dir') return true;
  if (!cmdStr) return false;
  const safePrefixes = ['ls', 'dir', 'cat', 'grep', 'find', 'head', 'tail', 'wc', 'git status', 'git log', 'git diff', 'pwd', 'echo', 'which', 'where'];
  const trimmed = cmdStr.trim().toLowerCase();
  return safePrefixes.some(p => trimmed === p || trimmed.startsWith(p + ' '));
}

// Active Prompts & Turn Tracking
const activePrompts = new Map(); // sessionId -> promptTimestamp

// Active session followers: sessionId -> { isRunning: boolean, thinkingBuffer: string, textBuffer: string, tools: Array, lastUpdated: number }
const activeSessionFollowers = new Map();
let upstreamMuxWs = null;
let activeEventsWs = null;
let currentEventsClientId = null;

function normalizeSessionId(sId) {
  if (!sId) return '';
  return sId.startsWith('session-') ? sId : `session-${sId}`;
}

function getSessionFollower(sId) {
  if (!sId) return null;
  const fullId = normalizeSessionId(sId);
  const cleanId = fullId.replace('session-', '');
  return activeSessionFollowers.get(fullId) || activeSessionFollowers.get(cleanId);
}

function followSession(sId) {
  if (!sId) return;
  const fullId = normalizeSessionId(sId);
  let follower = activeSessionFollowers.get(fullId);
  if (follower && follower.subscribed) {
    return;
  }
  if (!follower) {
    follower = {
      sessionId: fullId,
      streamId: `follow-${fullId}`,
      isRunning: false,
      thinkingBuffer: '',
      textBuffer: '',
      tools: [],
      subscribed: false,
      lastUpdated: Date.now()
    };
    activeSessionFollowers.set(fullId, follower);
  }

  if (upstreamMuxWs && upstreamMuxWs.readyState === WebSocket.OPEN && !follower.subscribed) {
    try {
      upstreamMuxWs.send(JSON.stringify({
        type: 'open',
        streamId: `follow-${fullId}`,
        endpoint: 'session/follow',
        payload: {
          args: {
            request: {
              address: { kind: 'session', sessionId: fullId },
              assistantStream: true
            }
          }
        }
      }));
      follower.subscribed = true;
      console.log(`[DSH Follow] Subscribed to session/follow for ${fullId}`);
    } catch (err) {
      console.error(`[DSH Follow] Failed to send open for ${fullId}:`, err);
    }
  }
}

// Approval Management State
const pendingApprovals = new Map(); // id -> { id, eventId, clientId, sessionId, toolName, reason, callId, createdAt }

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

// Persistent Upstream Multiplexed WebSocket Listener (for session/follow streaming and approvals)
function connectUpstreamMux() {
  const authority = `${CONFIG.DSH_HOST}:${CONFIG.DSH_PORT}`;
  const dshCookie = generateDshCookie(authority);
  const targetUrl = `ws://${authority}/api/remote.mux`;

  console.log(`[DSH Mux] Connecting to upstream mux on ${targetUrl}...`);

  try {
    const ws = new WebSocket(targetUrl, {
      headers: {
        'Host': authority,
        'Cookie': dshCookie
      }
    });

    upstreamMuxWs = ws;
    activeEventsWs = ws;

    ws.on('open', () => {
      console.log('[DSH Mux] Connected to upstream remote.mux. Opening $events stream...');
      ws.send(JSON.stringify({
        type: 'open',
        streamId: 'gw-events-stream',
        endpoint: '$events',
        payload: { args: {} }
      }));

      // Re-follow all tracked active sessions
      for (const [fullId, follower] of activeSessionFollowers.entries()) {
        try {
          ws.send(JSON.stringify({
            type: 'open',
            streamId: `follow-${fullId}`,
            endpoint: 'session/follow',
            payload: {
              args: {
                request: {
                  address: { kind: 'session', sessionId: fullId },
                  assistantStream: true
                }
              }
            }
          }));
          follower.subscribed = true;
          console.log(`[DSH Mux] Re-subscribed to session/follow for ${fullId}`);
        } catch (_) {}
      }
    });

    ws.on('message', (data) => {
      try {
        const frame = JSON.parse(data.toString());

        // 1. Session follow stream frames
        if (frame.type === 'item' && frame.streamId && frame.streamId.startsWith('follow-')) {
          const sId = frame.streamId.replace('follow-', '');
          const cleanId = sId.replace('session-', '');
          let follower = activeSessionFollowers.get(sId) || activeSessionFollowers.get(cleanId);
          if (!follower) {
            follower = {
              sessionId: sId,
              streamId: frame.streamId,
              isRunning: false,
              thinkingBuffer: '',
              textBuffer: '',
              tools: [],
              lastUpdated: Date.now()
            };
            activeSessionFollowers.set(sId, follower);
          }
          follower.lastUpdated = Date.now();

          const val = frame.value;
          if (!val) return;

          // A. Assistant stream frames (real-time reasoning & text deltas)
          if (val.type === 'assistant-stream') {
            const aFrame = val.frame;
            if (!aFrame) return;

            if (aFrame.type === 'start') {
              follower.isRunning = true;
              follower.thinkingBuffer = '';
              follower.textBuffer = '';
              follower.tools = [];
              broadcastToMobileClients({
                type: 'session_status',
                sessionId: sId,
                isRunning: true
              });
            } else if (aFrame.type === 'chunk') {
              const c = aFrame.chunk;
              if (c) {
                if (c.type === 'reasoning-delta' && c.text) {
                  follower.isRunning = true;
                  follower.thinkingBuffer += c.text;
                  broadcastToMobileClients({
                    type: 'thinking',
                    sessionId: sId,
                    delta: c.text,
                    text: c.text
                  });
                } else if (c.type === 'text-delta' && c.text) {
                  follower.isRunning = true;
                  follower.textBuffer += c.text;
                  broadcastToMobileClients({
                    type: 'delta',
                    sessionId: sId,
                    delta: c.text,
                    text: c.text
                  });
                } else if (c.type === 'tool-call-delta') {
                  broadcastToMobileClients({
                    type: 'tool_call',
                    sessionId: sId,
                    tool: c.name || 'tool',
                    delta: c.argumentsDelta || ''
                  });
                }
              }
            } else if (aFrame.type === 'end') {
              // End of stream attempt
            }
            return;
          }

          // B. Committed event frames (turn/start, turn/end, tool/call, tool/result)
          if (val.type === 'event' && val.event) {
            const ev = val.event;
            if (ev.type === 'turn/start') {
              follower.isRunning = true;
              follower.thinkingBuffer = '';
              follower.textBuffer = '';
              follower.tools = [];
              broadcastToMobileClients({
                type: 'session_status',
                sessionId: sId,
                isRunning: true
              });
            } else if (ev.type === 'turn/end') {
              follower.isRunning = false;
              activePrompts.delete(sId);
              activePrompts.delete(cleanId);
              broadcastToMobileClients({
                type: 'done',
                sessionId: sId
              });
              broadcastToMobileClients({
                type: 'session_status',
                sessionId: sId,
                isRunning: false
              });
              // Clear temporary buffers after disk projcache sync
              setTimeout(() => {
                if (!follower.isRunning) {
                  follower.thinkingBuffer = '';
                  follower.textBuffer = '';
                  follower.tools = [];
                }
              }, 6000);
            } else if (ev.type === 'tool/call') {
              const toolObj = {
                id: ev.data?.id || `tool_${Date.now()}`,
                name: ev.data?.name || 'tool',
                input: ev.data?.arguments || '',
                output: '',
                isRunning: true
              };
              follower.tools.push(toolObj);
              broadcastToMobileClients({
                type: 'tool_start',
                sessionId: sId,
                tool: toolObj.name,
                input: toolObj.input
              });
            } else if (ev.type === 'tool/result') {
              if (follower.tools.length > 0) {
                const t = follower.tools[follower.tools.length - 1];
                t.isRunning = false;
                t.output = ev.data?.output || '执行完毕';
              }
              broadcastToMobileClients({
                type: 'tool_result',
                sessionId: sId,
                output: ev.data?.output || '执行完毕'
              });
            }
            return;
          }
          return;
        }

        // 2. Events stream ($events for approval and interaction)
        if (frame.type === 'item' && frame.value) {
          const val = frame.value;

          // Ready frame
          if (val.type === 'ready') {
            currentEventsClientId = val.clientId;
            console.log(`[DSH Events] $events stream ready with clientId: ${currentEventsClientId}`);
          }
          // Approval Request frame
          else if (val.type === 'request' && val.event === 'approval/request') {
            const toolName = val.request?.toolName || 'Unknown Tool';
            const reason = val.request?.reason || '';
            const sessionId = val.agent || 'default';
            console.log(`[DSH Approval] Received approval request: id=${val.id}, agent=${sessionId}, tool=${toolName}, cmd=${reason.slice(0, 80)}`);

            const currentPerms = getPermissions();
            const sessionPolicy = currentPerms.sessionPolicies?.[sessionId] || currentPerms.defaultPolicy || 'ask';

            let shouldAutoApprove = false;
            let autoApproveReason = '';

            if (sessionPolicy === 'danger-full-access' || currentPerms.defaultPolicy === 'danger-full-access') {
              shouldAutoApprove = true;
              autoApproveReason = '全信任模式 (Danger Full Access) 自动放行';
            } else if (sessionPolicy === 'auto-read' || currentPerms.defaultPolicy === 'auto-read') {
              if (isCommandReadOnly(reason, toolName)) {
                shouldAutoApprove = true;
                autoApproveReason = '安全策略: 只读指令自动放行';
              }
            }

            if (shouldAutoApprove) {
              console.log(`[DSH Approval] AUTO-APPROVED: id=${val.id}, session=${sessionId}, reason=${autoApproveReason}`);
              callDshRpc('$events/result', {
                clientId: currentEventsClientId,
                eventId: val.id,
                outcome: {
                  kind: 'result',
                  value: 'allowed-once'
                }
              }).catch(e => console.error('[DSH Approval] Auto-approve RPC error:', e));

              logAudit({
                id: val.id,
                time: Date.now(),
                sessionId,
                toolName,
                command: reason,
                outcome: 'auto-approved',
                reason: autoApproveReason
              });
              return;
            }

            const approval = {
              id: val.id,
              eventId: val.id,
              clientId: currentEventsClientId,
              sessionId: sessionId,
              toolName: toolName,
              reason: reason,
              callId: val.request?.callId || '',
              createdAt: Date.now()
            };

            pendingApprovals.set(val.id, approval);

            logAudit({
              id: val.id,
              time: Date.now(),
              sessionId,
              toolName,
              command: reason,
              outcome: 'pending',
              reason: '等待人工确认'
            });

            broadcastToMobileClients({
              type: 'approval_request',
              approval: approval
            });
          }
          // User questions
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
        console.error('[DSH Mux] Error parsing upstream message:', err);
      }
    });

    ws.on('close', (code, reason) => {
      console.warn(`[DSH Mux] Upstream mux socket closed: ${code}, ${reason?.toString() || ''}. Reconnecting in 3s...`);
      upstreamMuxWs = null;
      activeEventsWs = null;
      for (const follower of activeSessionFollowers.values()) {
        follower.subscribed = false;
      }
      setTimeout(connectUpstreamMux, 3000);
    });

    ws.on('error', (err) => {
      console.error(`[DSH Mux] Upstream mux error: ${err.message}`);
    });
  } catch (err) {
    console.error(`[DSH Mux] Error launching upstream socket: ${err.message}. Retrying in 5s...`);
    setTimeout(connectUpstreamMux, 5000);
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

  logAudit({
    id: eventId,
    time: Date.now(),
    sessionId: approval.sessionId,
    toolName: approval.toolName,
    command: approval.reason,
    outcome: outcome,
    reason: outcome === 'allowed-once' ? '人工手机审批放行' : '人工手机拒绝执行'
  });

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

  // 1. Static Web Dashboard (Visual Admin Interface)
  if (pathname === '/' || pathname === '/dashboard' || pathname === '/admin' || pathname === '/ui') {
    const htmlPath = path.join(__dirname, 'public', 'index.html');
    if (fs.existsSync(htmlPath)) {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      fs.createReadStream(htmlPath).pipe(res);
      return;
    }
  }

  // 2. Direct APK Download
  if (pathname === '/dsh-agent.apk' || pathname === '/download/apk' || pathname.endsWith('.apk')) {
    const filename = pathname.endsWith('.apk') ? path.basename(pathname) : 'dsh-agent.apk';
    const apkPath = path.join(__dirname, 'public', filename);
    const targetApk = fs.existsSync(apkPath) ? apkPath : path.join(__dirname, 'public', 'dsh-agent.apk');
    if (fs.existsSync(targetApk)) {
      const stat = fs.statSync(targetApk);
      res.writeHead(200, {
        'Content-Type': 'application/vnd.android.package-archive',
        'Content-Length': stat.size,
        'Content-Disposition': 'attachment; filename="dsh-agent-v1.2.2.apk"'
      });
      fs.createReadStream(targetApk).pipe(res);
      return;
    }
  }

  // Security gate for /api endpoints
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
      const rawSessionId = body.sessionId || '';
      const fullId = normalizeSessionId(rawSessionId);
      const cleanId = fullId.replace('session-', '');

      // Follow session immediately for live token streaming
      followSession(fullId);
      const follower = getSessionFollower(fullId);
      if (follower) {
        follower.isRunning = true;
        follower.thinkingBuffer = '';
        follower.textBuffer = '';
        follower.tools = [];
        follower.lastUpdated = Date.now();
      }
      activePrompts.set(fullId, Date.now());
      activePrompts.set(cleanId, Date.now());

      broadcastToMobileClients({ type: 'session_status', sessionId: fullId, isRunning: true });

      const result = await callDshRpc('session/prompt', {
        args: {
          request: {
            requestId: crypto.randomUUID(),
            sessionId: fullId,
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
      const rawSessionId = body.sessionId || '';
      const fullId = normalizeSessionId(rawSessionId);
      const cleanId = fullId.replace('session-', '');

      const follower = getSessionFollower(fullId);
      if (follower) {
        follower.isRunning = false;
        follower.thinkingBuffer = '';
        follower.textBuffer = '';
        follower.tools = [];
      }
      activePrompts.delete(fullId);
      activePrompts.delete(cleanId);
      broadcastToMobileClients({ type: 'session_status', sessionId: fullId, isRunning: false });
      broadcastToMobileClients({ type: 'done', sessionId: fullId });

      const result = await callDshRpc('session/cancel', {
        args: {
          request: {
            sessionId: fullId
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

    // 10. GET /api/mobile/permissions
    if (pathname === '/api/mobile/permissions' && req.method === 'GET') {
      const perms = getPermissions();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, permissions: perms }));
      return;
    }

    // 11. POST /api/mobile/permissions
    if (pathname === '/api/mobile/permissions' && req.method === 'POST') {
      const body = await readBody();
      const current = getPermissions();
      const updated = {
        ...current,
        ...body,
        sessionPolicies: {
          ...(current.sessionPolicies || {}),
          ...(body.sessionPolicies || {})
        }
      };
      savePermissions(updated);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, permissions: updated }));
      return;
    }

    // 12. GET /api/mobile/audit-logs
    if (pathname === '/api/mobile/audit-logs' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, auditLogs: auditLogs }));
      return;
    }

    // 13. GET /api/mobile/personas
    if (pathname === '/api/mobile/personas' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, personas: getPersonas() }));
      return;
    }

    // 14. POST /api/mobile/personas
    if (pathname === '/api/mobile/personas' && req.method === 'POST') {
      const body = await readBody();
      if (Array.isArray(body.personas)) {
        savePersonas(body.personas);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ code: 0, personas: body.personas }));
        return;
      }
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Expected personas array in body' }));
      return;
    }

    // 15. GET /api/mobile/workspace/memory
    if (pathname === '/api/mobile/workspace/memory' && req.method === 'GET') {
      const targetPath = parsedUrl.query.path;
      if (!targetPath) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Missing path query parameter' }));
        return;
      }
      const candidates = [
        path.join(targetPath, 'MEMORY.md'),
        path.join(targetPath, 'AGENTS.md'),
        path.join(targetPath, '.cursorrules'),
        path.join(targetPath, 'README.md')
      ];
      let foundPath = candidates[0];
      let content = '';
      for (const c of candidates) {
        if (fs.existsSync(c)) {
          try {
            foundPath = c;
            content = fs.readFileSync(c, 'utf8');
            break;
          } catch (_) {}
        }
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, filePath: foundPath, content }));
      return;
    }

    // 16. POST /api/mobile/workspace/memory
    if (pathname === '/api/mobile/workspace/memory' && req.method === 'POST') {
      const body = await readBody();
      if (!body.path) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Missing path in body' }));
        return;
      }
      const memFile = path.join(body.path, 'MEMORY.md');
      try {
        fs.writeFileSync(memFile, body.content || '', 'utf8');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ code: 0, message: 'Saved successfully', filePath: memFile }));
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: err.message }));
      }
      return;
    }

    // 17. GET /api/mobile/ping
    if (pathname === '/api/mobile/ping' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ code: 0, time: Date.now() }));
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

  // Handle mobile client messages
  clientWs.on('message', async (message) => {
    try {
      const msgStr = message.toString();
      if (msgStr === 'ping') {
        clientWs.send('pong');
        return;
      }

      const json = JSON.parse(msgStr);

      // 1. Follow session request
      if (json.type === 'follow' || json.type === 'select_session') {
        const rawId = json.sessionId || json.id;
        if (rawId) {
          followSession(rawId);
          clientWs.send(JSON.stringify({ type: 'follow_ack', sessionId: rawId }));
        }
        return;
      }

      // 2. Approval response from client
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

      // 3. Chat prompt from client over WebSocket
      if (json.type === 'chat' || json.method === 'session/send') {
        const rawSessionId = json.sessionId || json.params?.sessionId || 'default';
        const content = json.content || json.params?.content || json.params?.message || '';
        const fullId = normalizeSessionId(rawSessionId);
        const cleanId = fullId.replace('session-', '');

        followSession(fullId);
        const follower = getSessionFollower(fullId);
        if (follower) {
          follower.isRunning = true;
          follower.thinkingBuffer = '';
          follower.textBuffer = '';
          follower.tools = [];
          follower.lastUpdated = Date.now();
        }
        activePrompts.set(fullId, Date.now());
        activePrompts.set(cleanId, Date.now());

        broadcastToMobileClients({ type: 'session_status', sessionId: fullId, isRunning: true });

        try {
          await callDshRpc('session/prompt', {
            args: {
              request: {
                requestId: crypto.randomUUID(),
                sessionId: fullId,
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
    } catch (err) {
      console.error(`[DSH Bridge] Error handling client message: ${err.message}`);
    }
  });

  clientWs.on('close', () => {
    console.log(`[DSH Bridge] Mobile client disconnected`);
    mobileClients.delete(clientWs);
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

    // Launch persistent upstream multiplexer (events + session follow streams)
    connectUpstreamMux();
  });
}

if (require.main === module) {
  startServer();
}

module.exports = {
  name: 'dsh-mobile-bridge',
  startServer,
};
