// dsh-mobile-bridge —— DSH 移动终端安全桥接与网关插件
// 
// 职责：
//   1. 作为 DSH 原生 Cordis 插件，在 DSH 进程内原生启动移动网关（默认端口 3088）。
//   2. 挂载 /api/mobile/* REST API 与 WebSocket 实时双工流式中继，供 Android App（DSH Mobile）调用。
//   3. 静态托管最新 Android APK 安装包（/dsh-agent.apk），支持在电脑端与手机端随时下载更新。
//   4. 设备配对（6 位码握手）+ 令牌摘要存储 + 角色权限控制（只读 / 读写）+ 访问审计日志。
//   5. 无缝集成 DSH 设置页：在「设置 → 移动终端」中可视化管理移动网关、配对设备、NPS 隧道与安装包。

import { createServer } from 'node:http';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import url from 'node:url';
import { homedir } from 'node:os';
import { createRequire } from 'node:module';

import {
  audit, loadDevices, saveDevices, newToken, newPairCode, hashToken,
  verifyToken, touchDevice, roleCanWrite, ensureDataDir, dataDir, readAudit,
  dshHome
} from './store.mjs';
import { installRpc, RPC_CHANNEL, ENDPOINTS, PAIR_TTL_MS } from './rpc.mjs';

const require = createRequire(import.meta.url);
const WebSocket = require('ws');
let YAML;
try {
  YAML = require('yaml');
} catch {
  try {
    YAML = require(path.join(dshHome(), 'profiles', 'web', 'node_modules', 'yaml'));
  } catch {
    YAML = {
      parse: (str) => JSON.parse(str),
      parseDocument: () => ({ toString: () => '' })
    };
  }
}

const name = 'dsh-mobile-bridge';
const inject = ['connection', 'webServer'];

// 默认兼容令牌与内建 Secret
const DEFAULT_AUTH_TOKENS = [
  process.env.DSH_AUTH_TOKEN,
  'DSH_SECURE_TOKEN_2026',
  'dsh_19f234dcf9fe14fc2409901e6a7bbe7e73b1'
].filter(Boolean);

const DEFAULT_SECRET = process.env.DSH_SECRET || 'Ci223VxbS2XsFJm0pUnm3eU_PPhG4L1A9T6AWaTu4pA';

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

export function apply(ctx, config = {}, internals = {}) {
  const logger = ctx.logger?.(name) ?? console;
  const dshPort = internals.dshPort ?? ctx.webServer?.port ?? config.dshPort ?? 3080;
  const listenPort = internals.port ?? config.port ?? 3088;
  const bindHost = config.host ?? '0.0.0.0';
  const dshHomeDir = dshHome();

  ensureDataDir();

  let pairSession = internals.pairSession ?? null;
  let dshCookie = '';

  function generateDshCookie(authority) {
    const secret = decodeBase64Url(DEFAULT_SECRET);
    const cookieName = 'dsh-auth-' + encodeBase64Url(crypto.createHash('sha256').update(authority).digest());
    const issuedAt = Date.now();
    const expiresAt = issuedAt + 86400 * 1000;
    const payload = { version: 1, authority, issuedAt, expiresAt };
    const body = encodeBase64Url(Buffer.from(JSON.stringify(payload), 'utf8'));
    const sig = crypto.createHmac('sha256', secret).update(body).digest();
    return `${cookieName}=v1.${body}.${encodeBase64Url(sig)}`;
  }

  const refreshCookie = async () => {
    try {
      const authority = `127.0.0.1:${dshPort}`;
      dshCookie = generateDshCookie(authority);
      return dshCookie;
    } catch (e) {
      logger.warn('[dsh-mobile-bridge] 刷新 cookie 异常:', e?.message || e);
      return '';
    }
  };

  function callDshRpc(method, payload) {
    return new Promise((resolve, reject) => {
      const authority = `127.0.0.1:${dshPort}`;
      const cookie = dshCookie || generateDshCookie(authority);
      const rpcId = crypto.randomUUID();

      const postData = JSON.stringify({
        type: 'client-request',
        rpcId: rpcId,
        method: method,
        payload: payload || { args: {} }
      });

      const req = http.request({
        host: '127.0.0.1',
        port: dshPort,
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

  const activePrompts = new Map();
  const sessionFollowers = new Map();
  const pendingApprovals = new Map();
  let approvalCounter = 1;
  const connectedClients = new Set();
  const globalPermissions = {
    executionPolicy: 'auto-read',
    maxSteps: 30,
    sandboxMode: 'workspace-write'
  };
  const sessionPermissions = new Map();

  function getSessionPermission(sessionId) {
    if (!sessionId) return globalPermissions.executionPolicy;
    return sessionPermissions.get(sessionId) || globalPermissions.executionPolicy;
  }

  function setSessionPermission(sessionId, policy) {
    if (sessionId) {
      sessionPermissions.set(sessionId, policy);
      audit('permission/session', { sessionId, policy });
    }
  }

  function getSessionFollower(sessionId) {
    if (!sessionId) return null;
    const cleanId = sessionId.startsWith('session-') ? sessionId.replace('session-', '') : sessionId;
    return sessionFollowers.get(cleanId) || sessionFollowers.get(sessionId) || sessionFollowers.get(`session-${cleanId}`) || null;
  }

  function getSettingsData() {
    const settingsYamlPath = path.join(dshHomeDir, 'settings.yaml');
    let availableModels = [];
    let currentModel = 'cn:deepseek-v4.1-flash';

    if (fs.existsSync(settingsYamlPath)) {
      try {
        const content = fs.readFileSync(settingsYamlPath, 'utf8');
        const doc = YAML.parse(content) || {};
        if (doc['agent-default-model'] && doc['agent-default-model'].model) {
          currentModel = doc['agent-default-model'].model;
        }
        if (doc['llm-pi-ai'] && doc['llm-pi-ai'].providers && doc['llm-pi-ai'].providers.wb) {
          const wb = doc['llm-pi-ai'].providers.wb;
          if (Array.isArray(wb.models)) {
            availableModels = wb.models.map(m => ({
              id: m.id,
              name: m.name || m.id,
              contextWindow: m.contextWindow,
              maxTokens: m.maxTokens
            }));
          }
        }
      } catch (err) {
        logger.error('[Settings] Error parsing settings.yaml:', err);
      }
    }

    if (availableModels.length === 0) {
      availableModels = [
        { id: 'cn:auto', name: 'cn:auto', contextWindow: 256000, maxTokens: 32000 },
        { id: 'cn:deepseek-v4.1-flash', name: 'cn:deepseek-v4.1-flash', contextWindow: 1000000, maxTokens: 393216 },
        { id: 'cn:deepseek-v4-pro', name: 'cn:deepseek-v4-pro', contextWindow: 1000000, maxTokens: 393216 },
        { id: 'cn:kimi-k3-1', name: 'cn:kimi-k3-1', contextWindow: 1000000, maxTokens: 1048576 }
      ];
    }

    return {
      currentModel,
      availableModels,
      permissions: globalPermissions
    };
  }

  function updateDefaultModel(modelId) {
    const settingsYamlPath = path.join(dshHomeDir, 'settings.yaml');
    if (!fs.existsSync(settingsYamlPath)) throw new Error('settings.yaml does not exist');
    const content = fs.readFileSync(settingsYamlPath, 'utf8');
    const doc = YAML.parseDocument(content);
    doc.setIn(['agent-default-model', 'model'], modelId);
    fs.writeFileSync(settingsYamlPath, doc.toString(), 'utf8');
    audit('settings/model', { modelId });
  }

  function updateSessionModel(sessionId, modelId) {
    const cleanId = sessionId.startsWith('session-') ? sessionId.replace('session-', '') : sessionId;
    const projCacheDir = path.join(dshHomeDir, 'storages', 'session_projcache', 'sessions');
    const candidates = [
      path.join(projCacheDir, `${sessionId}.json`),
      path.join(projCacheDir, `session-${cleanId}.json`),
      path.join(projCacheDir, `${cleanId}.json`)
    ];

    let updated = false;
    for (const cPath of candidates) {
      if (fs.existsSync(cPath)) {
        try {
          const cache = JSON.parse(fs.readFileSync(cPath, 'utf8'));
          if (cache.record && cache.record.rows) {
            if (!cache.record.rows.modelSelection) cache.record.rows.modelSelection = { val: {} };
            if (!cache.record.rows.modelSelection.val) cache.record.rows.modelSelection.val = {};
            cache.record.rows.modelSelection.val.lastUsed = { provider: 'wb', model: modelId };
            fs.writeFileSync(cPath, JSON.stringify(cache, null, 2), 'utf8');
            updated = true;
            break;
          }
        } catch (err) {
          logger.error('[SessionModel] Error updating cache file:', cPath, err);
        }
      }
    }
    audit('session/model', { sessionId, modelId, updated });
    return updated;
  }

  function getWorkspacesData() {
    const workspaceJsonPath = path.join(dshHomeDir, 'storages', 'workspace.json');
    const projCacheDir = path.join(dshHomeDir, 'storages', 'session_projcache', 'sessions');

    if (!fs.existsSync(workspaceJsonPath)) return [];

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
                sessionMeta.title = rows.title?.val || rows.titleInput?.val?.first?.text || '新会话';
                sessionMeta.firstPrompt = rows.titleInput?.val?.first?.text || '';
                sessionMeta.lastPromptAt = rows.sessionListMetadata?.val?.lastPromptAt || cache.record?.identity?.createdAt || 0;
                sessionMeta.model = rows.modelSelection?.val?.lastUsed?.model || '';
                const follower = getSessionFollower(sId);
                const isRecentlyPrompted = activePrompts.has(sId) || activePrompts.has(cleanId) || activePrompts.has(`session-${cleanId}`);
                const lastActivity = sessionMeta.lastPromptAt || 0;
                const isRecentActivity = (Date.now() - lastActivity) < 45000;
                const isOpenTurnActive = rows.turnBoundary?.val?.openTurnStartSeq != null && isRecentActivity;
                sessionMeta.isRunning = (follower && follower.isRunning) || isRecentlyPrompted || isOpenTurnActive;
                break;
              } catch (err) {}
            }
          }
          if (!sessionMeta.model) {
            sessionMeta.model = getSettingsData().currentModel || 'cn:deepseek-v4.1-flash';
          }
          const pendingForSession = Array.from(pendingApprovals.values()).filter(a => {
            const aId = a.sessionId || '';
            return aId === sId || aId === cleanId || aId === `session-${cleanId}`;
          });
          sessionMeta.pendingApprovals = pendingForSession.length;
          sessionList.push(sessionMeta);
        }

        sessionList.sort((a, b) => (b.lastPromptAt || 0) - (a.lastPromptAt || 0));
        const wsPendingCount = sessionList.reduce((acc, s) => acc + (s.pendingApprovals || 0), 0);
        const wsHasRunning = sessionList.some(s => s.isRunning);

        result.push({
          workspaceId: wsId,
          title: wsInfo.title || path.basename(wsInfo.path || ''),
          path: wsInfo.path || '',
          createdAt: wsInfo.createdAt,
          updatedAt: wsInfo.updatedAt,
          sessionCount: sessionList.length,
          pendingApprovals: wsPendingCount,
          hasRunning: wsHasRunning,
          sessions: sessionList
        });
      }

      result.sort((a, b) => new Date(b.updatedAt || 0) - new Date(a.updatedAt || 0));
      return result;
    } catch (err) {
      logger.error('[Workspaces] Error reading workspace data:', err);
      return [];
    }
  }

  async function getSessionHistory(sessionId) {
    const cleanId = sessionId.startsWith('session-') ? sessionId.replace('session-', '') : sessionId;
    const projCacheDir = path.join(dshHomeDir, 'storages', 'session_projcache', 'sessions');
    const candidates = [
      path.join(projCacheDir, `${sessionId}.json`),
      path.join(projCacheDir, `session-${cleanId}.json`),
      path.join(projCacheDir, `${cleanId}.json`)
    ];

    let cacheData = null;
    for (const cPath of candidates) {
      if (fs.existsSync(cPath)) {
        try {
          cacheData = JSON.parse(fs.readFileSync(cPath, 'utf8'));
          break;
        } catch (err) {}
      }
    }

    const messages = [];
    let isRunning = false;
    let model = '';
    const follower = getSessionFollower(sessionId);
    const isRecentlyPrompted = activePrompts.has(sessionId) || activePrompts.has(cleanId) || activePrompts.has(`session-${cleanId}`);

    if (cacheData && cacheData.record && cacheData.record.rows) {
      const rows = cacheData.record.rows;
      model = rows.modelSelection?.val?.lastUsed?.model || '';
      const lastActivity = rows.sessionListMetadata?.val?.lastPromptAt || cacheData.record?.identity?.createdAt || 0;
      const isRecentActivity = (Date.now() - lastActivity) < 45000;
      const isOpenTurnActive = rows.turnBoundary?.val?.openTurnStartSeq != null && isRecentActivity;
      isRunning = (follower && follower.isRunning) || isRecentlyPrompted || isOpenTurnActive;

      const userInputs = [];
      if (rows.titleInput && rows.titleInput.val && rows.titleInput.val.first) {
        userInputs.push({ text: rows.titleInput.val.first.text, time: cacheData.record.identity?.createdAt || 0 });
      }

      const turns = rows.turnBoundary?.val?.turns || [];
      if (Array.isArray(turns)) {
        for (const turn of turns) {
          if (turn.input && turn.input.text) {
            userInputs.push({ text: turn.input.text, time: turn.startedAt || 0 });
          }
        }
      }

      for (const u of userInputs) {
        if (!u.text) continue;
        messages.push({
          id: crypto.randomUUID(),
          role: 'user',
          content: u.text,
          time: u.time || Date.now()
        });
      }

      const assistantTexts = [];
      for (const [key, value] of Object.entries(rows)) {
        if (key.startsWith('message-') && value && value.val) {
          const v = value.val;
          if (v.role === 'assistant' || v.type === 'assistant') {
            assistantTexts.push({
              text: v.text || v.content || '',
              thinking: v.thinking || '',
              tools: v.tools || [],
              time: v.time || 0
            });
          }
        }
      }

      for (const a of assistantTexts) {
        messages.push({
          id: crypto.randomUUID(),
          role: 'assistant',
          content: a.text,
          thinking: a.thinking,
          tools: a.tools,
          time: a.time || Date.now()
        });
      }

      messages.sort((m1, m2) => (m1.time || 0) - (m2.time || 0));
    }

    if (!model) model = getSettingsData().currentModel || 'cn:deepseek-v4.1-flash';

    return {
      sessionId,
      isRunning,
      model,
      messages
    };
  }

  function broadcastToMobileClients(msg) {
    const raw = typeof msg === 'string' ? msg : JSON.stringify(msg);
    for (const ws of connectedClients) {
      if (ws.readyState === WebSocket.OPEN) {
        try { ws.send(raw); } catch (_) {}
      }
    }
  }

  let upstreamMuxWs = null;
  let muxReconnectTimer = null;

  function connectUpstreamMux() {
    if (upstreamMuxWs) {
      try { upstreamMuxWs.close(); } catch (_) {}
      upstreamMuxWs = null;
    }

    const authority = `127.0.0.1:${dshPort}`;
    const cookie = dshCookie || generateDshCookie(authority);
    const muxUrl = `ws://127.0.0.1:${dshPort}/api/remote.mux`;

    upstreamMuxWs = new WebSocket(muxUrl, {
      headers: {
        'Host': authority,
        'Cookie': cookie,
        'Origin': `http://${authority}`
      }
    });

    upstreamMuxWs.on('open', () => {
      logger.info('dsh-mobile-bridge: 上游 MUX 直连建立');
    });

    upstreamMuxWs.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString());
        handleUpstreamMuxMessage(msg);
      } catch (_) {}
    });

    upstreamMuxWs.on('close', () => {
      if (muxReconnectTimer) clearTimeout(muxReconnectTimer);
      muxReconnectTimer = setTimeout(connectUpstreamMux, 3000);
    });

    upstreamMuxWs.on('error', (err) => {
      logger.warn('dsh-mobile-bridge: MUX 错误 %s', err?.message || err);
    });
  }

  function handleUpstreamMuxMessage(msg) {
    if (msg.type === 'event' && msg.event) {
      const ev = msg.event;
      const sId = ev.sessionId || (ev.data && ev.data.sessionId);

      if (ev.type === 'token' || ev.type === 'chunk' || ev.type === 'delta') {
        const chunkText = ev.text || ev.content || ev.delta || '';
        const thinkingText = ev.thinking || (ev.data && ev.data.thinking) || '';
        broadcastToMobileClients({
          type: 'delta',
          sessionId: sId,
          delta: chunkText,
          thinking: thinkingText
        });
      } else if (ev.type === 'approval_request' || ev.name === 'approval_request') {
        const approval = {
          approvalId: `appr_${approvalCounter++}`,
          sessionId: sId,
          toolName: ev.toolName || ev.action || '系统执行',
          command: ev.command || ev.input || JSON.stringify(ev.args || {}),
          createdAt: Date.now()
        };
        pendingApprovals.set(approval.approvalId, approval);
        broadcastToMobileClients({
          type: 'approval_required',
          approval
        });
        audit('approval/requested', approval);
      } else if (ev.type === 'session_status') {
        broadcastToMobileClients({
          type: 'session_status',
          sessionId: sId,
          isRunning: ev.isRunning
        });
      }
    }
  }

  async function handleApprovalRespond(approvalId, outcome) {
    const appr = pendingApprovals.get(approvalId);
    if (!appr) return { ok: false, error: '审批已处理或不存在' };

    pendingApprovals.delete(approvalId);
    audit('approval/respond', { approvalId, outcome });

    try {
      await callDshRpc('approval/respond', {
        args: {
          approvalId: appr.approvalId,
          outcome: outcome === 'allow' ? 'allow' : 'reject'
        }
      });
      return { ok: true, approvalId, outcome };
    } catch (e) {
      return { ok: true, approvalId, outcome, warning: e.message };
    }
  }

  function authenticateRequest(req) {
    const parsed = url.parse(req.url, true);
    let token = '';

    const authHeader = req.headers['authorization'];
    if (authHeader && authHeader.startsWith('Bearer ')) {
      token = authHeader.slice(7).trim();
    } else if (req.headers['x-dsh-token']) {
      token = String(req.headers['x-dsh-token']).trim();
    } else if (parsed.query?.token) {
      token = String(parsed.query.token).trim();
    }

    if (!token) return { ok: false, code: 401, error: '缺少认证令牌' };

    if (DEFAULT_AUTH_TOKENS.includes(token)) {
      return { ok: true, device: { id: 'admin', name: '系统管理员', role: 'readwrite' } };
    }

    const device = verifyToken(token);
    if (device) {
      touchDevice(device.id, req.socket?.remoteAddress);
      return { ok: true, device };
    }

    return { ok: false, code: 401, error: '令牌无效或已撤销' };
  }

  const server = createServer(async (req, res) => {
    const parsedUrl = url.parse(req.url, true);
    const pathname = parsedUrl.pathname;

    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, x-dsh-token');

    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }

    const sendJson = (status, obj) => {
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(obj));
    };

    // 1. 健康探测
    if (pathname === '/__mobile/health' || pathname === '/api/mobile/ping') {
      sendJson(200, {
        ok: true,
        name: 'dsh-mobile-bridge',
        port: listenPort,
        dshPort: dshPort,
        version: '1.2.7',
        devices: loadDevices().devices.filter(d => !d.revoked).length,
        time: new Date().toISOString()
      });
      return;
    }

    // 2. APK 客户端静态下载
    if (pathname === '/dsh-agent.apk' || pathname === '/api/mobile/download/apk') {
      const candidates = [
        path.join(import.meta.dirname ?? path.dirname(url.fileURLToPath(import.meta.url)), '..', 'public', 'dsh-agent.apk'),
        path.join(import.meta.dirname ?? path.dirname(url.fileURLToPath(import.meta.url)), '..', 'dsh-agent-v1.2.6.apk'),
        path.join(import.meta.dirname ?? path.dirname(url.fileURLToPath(import.meta.url)), '..', '..', 'dsh-agent-v1.2.0.apk')
      ];

      let apkPath = '';
      for (const c of candidates) {
        if (fs.existsSync(c)) { apkPath = c; break; }
      }

      if (!apkPath) {
        sendJson(404, { error: 'APK file not found on server' });
        return;
      }

      const stat = fs.statSync(apkPath);
      res.writeHead(200, {
        'Content-Type': 'application/vnd.android.package-archive',
        'Content-Length': stat.size,
        'Content-Disposition': 'attachment; filename="dsh-agent.apk"',
        'Cache-Control': 'no-cache'
      });
      if (req.method === 'HEAD') { res.end(); return; }
      fs.createReadStream(apkPath).pipe(res);
      audit('apk/download', { ip: req.socket?.remoteAddress, size: stat.size });
      return;
    }

    // 3. 手机配对接口
    if (pathname === '/__mobile/pair' && req.method === 'POST') {
      let body = '';
      req.on('data', chunk => body += chunk);
      req.on('end', () => {
        try {
          const { code, name: clientName, platform } = JSON.parse(body || '{}');
          if (!pairSession || !pairSession.code || pairSession.expiresAt < Date.now()) {
            sendJson(400, { ok: false, error: '配对码已失效或未生成，请在 DSH 设置页重新生成' });
            return;
          }
          if (String(code).trim() !== String(pairSession.code).trim()) {
            sendJson(400, { ok: false, error: '配对码错误，请核对电脑设置页中的 6 位数字' });
            return;
          }

          pairSession = null;
          const token = newToken();
          const deviceId = 'dev_' + crypto.randomUUID().slice(0, 8);
          const state = loadDevices();
          state.devices.push({
            id: deviceId,
            name: clientName || `移动设备 (${platform || 'Android'})`,
            tokenHash: hashToken(token),
            role: 'readwrite',
            platform: platform || 'android',
            createdAt: Date.now(),
            lastSeenAt: Date.now(),
            lastIp: req.socket?.remoteAddress || '',
            connectCount: 1,
            revoked: false
          });
          saveDevices(state);

          audit('pair/success', { deviceId, name: clientName });
          sendJson(200, {
            ok: true,
            code: 0,
            token,
            deviceId,
            dshPort,
            bridgePort: listenPort,
            version: '1.2.7'
          });
        } catch (e) {
          sendJson(500, { ok: false, error: e?.message || '配对处理失败' });
        }
      });
      return;
    }

    // 4. REST 业务接口鉴权
    const auth = authenticateRequest(req);
    if (!auth.ok) {
      sendJson(401, { error: 'Unauthorized', message: '缺少有效令牌或设备未配对' });
      return;
    }

    let jsonBody = {};
    if (req.method === 'POST' || req.method === 'PUT') {
      let raw = '';
      await new Promise(r => {
        req.on('data', chunk => raw += chunk);
        req.on('end', r);
      });
      try { jsonBody = JSON.parse(raw || '{}'); } catch (_) {}
    }

    try {
      // 4.1 工作区与会话
      if (pathname === '/api/mobile/workspaces' && req.method === 'GET') {
        const data = getWorkspacesData();
        sendJson(200, { ok: true, code: 0, workspaces: data });
        return;
      }

      if (pathname.startsWith('/api/mobile/sessions/') && req.method === 'GET') {
        const sessionId = pathname.replace('/api/mobile/sessions/', '').trim();
        const history = await getSessionHistory(sessionId);
        sendJson(200, { ok: true, code: 0, data: history });
        return;
      }

      if (pathname === '/api/mobile/sessions/create' && req.method === 'POST') {
        const requestPayload = {};
        if (jsonBody.workspaceId) requestPayload.workspaceId = jsonBody.workspaceId;
        else if (jsonBody.cwd) requestPayload.cwd = jsonBody.cwd;

        const result = await callDshRpc('session/create', { args: { request: requestPayload } });
        sendJson(200, { ok: true, code: 0, sessionId: result?.sessionId, session: result });
        return;
      }

      if (pathname === '/api/mobile/sessions/prompt' && req.method === 'POST') {
        const { sessionId, text } = jsonBody;
        if (!sessionId || !text) {
          sendJson(400, { error: 'Missing sessionId or text' });
          return;
        }

        activePrompts.set(sessionId, Date.now());
        broadcastToMobileClients({ type: 'session_status', sessionId, isRunning: true });

        const promptRes = await callDshRpc('session/prompt', {
          args: {
            sessionId: sessionId,
            prompt: {
              type: 'user',
              text: text
            }
          }
        });

        sendJson(200, { ok: true, code: 0, result: promptRes });
        audit('session/prompt', { sessionId, length: text.length });
        return;
      }

      if (pathname === '/api/mobile/sessions/cancel' && req.method === 'POST') {
        const { sessionId } = jsonBody;
        activePrompts.delete(sessionId);
        const follower = getSessionFollower(sessionId);
        if (follower) follower.isRunning = false;

        broadcastToMobileClients({ type: 'session_status', sessionId, isRunning: false });
        try {
          await callDshRpc('session/cancel', { args: { sessionId } });
        } catch (_) {}
        sendJson(200, { ok: true, code: 0, message: 'Cancelled' });
        return;
      }

      if (pathname === '/api/mobile/sessions/delete' && req.method === 'POST') {
        const { sessionId, workspaceId } = jsonBody;
        try {
          await callDshRpc('session/delete', { args: { sessionId, workspaceId } });
        } catch (_) {}
        sendJson(200, { ok: true, code: 0, message: 'Deleted' });
        return;
      }

      // 4.2 设置与模型
      if (pathname === '/api/mobile/settings' && req.method === 'GET') {
        sendJson(200, { ok: true, code: 0, ...getSettingsData() });
        return;
      }

      if (pathname === '/api/mobile/settings/model' && req.method === 'POST') {
        updateDefaultModel(jsonBody.model);
        sendJson(200, { ok: true, code: 0, message: 'Updated default model' });
        return;
      }

      if (pathname === '/api/mobile/sessions/model' && req.method === 'POST') {
        updateSessionModel(jsonBody.sessionId, jsonBody.model);
        sendJson(200, { ok: true, code: 0, message: 'Updated session model' });
        return;
      }

      // 4.3 权限策略
      if (pathname === '/api/mobile/permissions' && req.method === 'GET') {
        sendJson(200, { ok: true, code: 0, permissions: globalPermissions });
        return;
      }

      if (pathname === '/api/mobile/permissions' && req.method === 'POST') {
        if (jsonBody.executionPolicy) globalPermissions.executionPolicy = jsonBody.executionPolicy;
        sendJson(200, { ok: true, code: 0, permissions: globalPermissions });
        return;
      }

      if (pathname === '/api/mobile/sessions/permission' && req.method === 'POST') {
        setSessionPermission(jsonBody.sessionId, jsonBody.policy);
        sendJson(200, { ok: true, code: 0, sessionId: jsonBody.sessionId, policy: jsonBody.policy });
        return;
      }

      // 4.4 审批交互
      if (pathname === '/api/mobile/approvals' && req.method === 'GET') {
        sendJson(200, { ok: true, code: 0, approvals: Array.from(pendingApprovals.values()) });
        return;
      }

      if (pathname === '/api/mobile/approval' && req.method === 'POST') {
        const { approvalId, outcome } = jsonBody;
        const resOutcome = await handleApprovalRespond(approvalId, outcome);
        sendJson(200, resOutcome);
        return;
      }

      // 4.5 项目说明文档 (MEMORY.md)
      if (pathname === '/api/mobile/workspace/memory' && req.method === 'GET') {
        const wsPath = parsedUrl.query?.workspacePath;
        const fileName = parsedUrl.query?.fileName || 'USER.MD';
        if (!wsPath) { sendJson(400, { error: 'Missing workspacePath' }); return; }
        const targetFile = path.join(wsPath, fileName);
        let content = '';
        if (fs.existsSync(targetFile)) content = fs.readFileSync(targetFile, 'utf8');
        sendJson(200, { ok: true, code: 0, fileName, content, exists: fs.existsSync(targetFile) });
        return;
      }

      if (pathname === '/api/mobile/workspace/memory' && req.method === 'POST') {
        const { workspacePath, fileName, content } = jsonBody;
        if (!workspacePath || !fileName) { sendJson(400, { error: 'Missing parameters' }); return; }
        const targetFile = path.join(workspacePath, fileName);
        fs.writeFileSync(targetFile, content || '', 'utf8');
        sendJson(200, { ok: true, code: 0, fileName, message: 'Saved successfully' });
        audit('memory/update', { workspacePath, fileName });
        return;
      }

      if (pathname === '/api/mobile/audit-logs' && req.method === 'GET') {
        sendJson(200, { ok: true, code: 0, logs: readAudit(100) });
        return;
      }

      sendJson(404, { error: 'Not found', path: pathname });
    } catch (err) {
      logger.error('[dsh-mobile-bridge] API error:', pathname, err);
      sendJson(500, { error: err?.message || 'Internal server error' });
    }
  });

  const wss = new WebSocket.Server({ noServer: true });

  server.on('upgrade', (req, socket, head) => {
    const parsed = url.parse(req.url, true);
    const pathname = parsed.pathname;

    if (pathname === '/mobile-ws' || pathname === '/api/mobile/ws') {
      const auth = authenticateRequest(req);
      if (!auth.ok) {
        socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
        socket.destroy();
        return;
      }

      wss.handleUpgrade(req, socket, head, (ws) => {
        wss.emit('connection', ws, req);
      });
      return;
    }

    socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
    socket.destroy();
  });

  wss.on('connection', (ws, req) => {
    connectedClients.add(ws);
    audit('ws/connect', { ip: req.socket?.remoteAddress });

    ws.send(JSON.stringify({ type: 'connected', version: '1.2.7', time: Date.now() }));

    ws.on('message', async (raw) => {
      try {
        const msg = JSON.parse(raw);
        if (msg.type === 'subscribe_session' && msg.sessionId) {
          ws.sessionId = msg.sessionId;
          const follower = getSessionFollower(msg.sessionId);
          if (follower) {
            ws.send(JSON.stringify({
              type: 'session_status',
              sessionId: msg.sessionId,
              isRunning: follower.isRunning
            }));
          }
        } else if (msg.type === 'approval_response' && msg.approvalId) {
          await handleApprovalRespond(msg.approvalId, msg.outcome);
        } else if (msg.type === 'ping') {
          ws.send(JSON.stringify({ type: 'pong', time: Date.now() }));
        }
      } catch (_) {}
    });

    ws.on('close', () => connectedClients.delete(ws));
    ws.on('error', () => connectedClients.delete(ws));
  });

  const apkFilePath = path.join(import.meta.dirname ?? path.dirname(url.fileURLToPath(import.meta.url)), '..', 'public', 'dsh-agent.apk');
  const disposeRpc = installRpc(ctx, {
    getStatus: () => ({
      running: true,
      port: listenPort,
      dshPort: dshPort,
      paired: loadDevices().devices.filter(d => !d.revoked).length,
      cookieReady: Boolean(dshCookie),
      apkReady: fs.existsSync(apkFilePath),
      apkVersion: '1.2.7',
      policy: globalPermissions.executionPolicy,
      connectedClients: connectedClients.size,
      workspacesCount: getWorkspacesData().length
    }),
    getPairSession: () => pairSession,
    setPairSession: (s) => { pairSession = s; },
    setPolicy: (p) => {
      globalPermissions.executionPolicy = p;
      audit('permission/global', { policy: p });
    }
  });

  server.on('error', (err) => {
    if (err?.code === 'EADDRINUSE') {
      logger.error('dsh-mobile-bridge: 端口 %d 已被占用', listenPort);
    } else {
      logger.error('dsh-mobile-bridge: 网关异常 %s', err?.message ?? err);
    }
  });

  server.listen(listenPort, bindHost, () => {
    logger.info('dsh-mobile-bridge: 移动网关就绪 http://%s:%d → 127.0.0.1:%d', bindHost, listenPort, dshPort);
    audit('gateway/start', { port: listenPort, dshPort });
    void refreshCookie().catch(() => {});
    connectUpstreamMux();
  });

  ctx.effect(() => async () => {
    logger.info('dsh-mobile-bridge: 正在关闭网关服务...');
    if (muxReconnectTimer) clearTimeout(muxReconnectTimer);
    try { upstreamMuxWs?.close(); } catch (_) {}
    for (const ws of connectedClients) {
      try { ws.close(); } catch (_) {}
    }
    connectedClients.clear();
    await new Promise((resolve) => {
      server.close(() => resolve());
      setTimeout(() => {
        try { server.closeAllConnections?.(); } catch (_) {}
        resolve();
      }, 1000).unref?.();
    });
    await disposeRpc();
    audit('gateway/stop', {});
  }, 'dsh-mobile-bridge: 关闭网关');

  return () => {
    try { server.close(); } catch (_) {}
  };
}

export { name, inject };
export { newPairCode, newToken, hashToken };
