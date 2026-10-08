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
  loadConfig, saveConfig, verifyToken, ensureDataDir, dshHome, audit, readAudit,
  loadDevices, saveDevices, touchDevice, revokeDevice,
  newPairCode, pairCodeTtlMs, newToken, hashToken,
  loadPermissions, savePermissions, permissionsFile
} from './store.mjs';
import { installRpc, RPC_CHANNEL, ENDPOINTS } from './rpc.mjs';
import {
  BRIDGE_VERSION,
  MAX_BODY_SIZE,
  HEARTBEAT_INTERVAL_MS,
  createApprovalQueue,
  createFollowerRegistry,
  createTurnRegistry,
  createPersonaStore,
  createPathSanitizer,
  createPermissionStore,
  createCookieFactory,
  createRpcCaller,
  isCommandReadOnly,
  coerceToolInput,
  isCarriedContext,
  authenticateRequest,
  readBodyWithLimit,
  parseJsonBody,
  deleteSession,
  configurePersistence,
  configurePermissionsPersistence
} from './core.mjs';

// Inject the persistence helpers core needs; core must not import store.mjs
// because store imports core (audit sink).
configurePersistence({ verifyToken });
configurePermissionsPersistence({
  load: loadPermissions,
  save: savePermissions,
  file: permissionsFile
});

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

/**
 * HMAC secret used to mint the signed cookie that lets the bridge talk to the
 * engine's own HTTP/RPC surface.
 *
 * This used to be a literal in source control, which published the engine's
 * signing key. It must resolve to whatever the engine actually uses, or every
 * RPC call comes back `unauthorized`.
 *
 * Resolution order:
 *   1. DSH_SECRET / DSH_INTERNAL_SECRET environment variable
 *   2. the engine's own credentials file (~/.dsh/.credentials.yaml)
 *   3. the generated secret file the bridge writes on first run
 *
 * NOTE: do not invent a random secret as a silent fallback — the engine will
 * reject every signed cookie. If none of the above yield a value we keep the
 * generated one only as a last resort and log loudly.
 */
function resolveInternalSecret() {
  const fromEnv = process.env.DSH_SECRET || process.env.DSH_INTERNAL_SECRET;
  if (fromEnv && fromEnv.trim()) return fromEnv.trim();

  // The engine stores its auth secret here.
  for (const rel of ['.credentials.yaml', 'credentials.yaml', 'settings.yaml']) {
    try {
      const file = path.join(dshHome(), rel);
      if (!fs.existsSync(file)) continue;
      const m = fs.readFileSync(file, 'utf8')
        .match(/^\s*secret\s*:\s*['"]?([^'"\s#]+)/mi);
      if (m?.[1]) return m[1];
    } catch { /* try the next candidate */ }
  }

  // Fall back to the bridge's own generated secret so cookie minting at least
  // works for this install (requires DSH_SECRET to match on the engine side).
  try {
    const dir = path.join(dshHome(), 'mobile-bridge');
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    const file = path.join(dir, 'internal-secret');
    if (fs.existsSync(file)) {
      const v = fs.readFileSync(file, 'utf8').trim();
      if (v) return v;
    }
    const generated = crypto.randomBytes(32).toString('base64url');
    fs.writeFileSync(file, generated, 'utf8');
    try { fs.chmodSync(file, 0o600); } catch { /* best effort on Windows */ }
    console.warn(
      '[dsh-mobile-bridge] 未找到引擎密钥（~/.dsh/.credentials.yaml）。' +
      '已生成本地密钥；若 RPC 返回 unauthorized，请设置环境变量 DSH_SECRET 为引擎实际密钥。'
    );
    return generated;
  } catch {
    return crypto.randomBytes(32).toString('base64url');
  }
}

export function apply(ctx, config = {}, internals = {}) {
  const logger = ctx.logger?.(name) ?? console;
  const cfg = loadConfig();
  const dshPort = internals.dshPort ?? ctx.webServer?.port ?? config.dshPort ?? 3080;
  const listenPort = internals.port ?? config.port ?? cfg.port ?? 3088;
  const bindHost = config.host ?? '0.0.0.0';
  const dshHomeDir = dshHome();

  ensureDataDir();

  let isDisposed = false; // Lifecycle flag to prevent zombie reconnects (F4.4)

  let lastWorkspaces = [];

  /**
   * Path guard for the workspace-memory API (F4.5).
   * Implemented in core; the registered-workspace source stays here because
   * getWorkspacesData() reads live DSH state owned by this entry.
   */
  const sanitizeWorkspaceFilePath = createPathSanitizer({
    getRegisteredWorkspaces: () => {
      try {
        const live = getWorkspacesData();
        if (Array.isArray(live) && live.length > 0) {
          lastWorkspaces = live;
          return live;
        }
      } catch { /* fall back to the last known snapshot */ }
      return Array.isArray(lastWorkspaces) ? lastWorkspaces : [];
    }
  });

  let pairSession = internals.pairSession ?? null;

  /**
   * Signed-cookie minting and unary RPC live in core so both entry points speak
   * to the engine identically.  [unified]
   */
  const cookieFactory = createCookieFactory({ dshPort, secret: resolveInternalSecret() });
  const refreshCookie = async () => {
    try {
      return cookieFactory.refresh();
    } catch (e) {
      logger.warn('[dsh-mobile-bridge] 刷新 cookie 异常:', e?.message || e);
      return '';
    }
  };

  const callDshRpc = createRpcCaller({ dshPort, cookieFactory });

  const activePrompts = new Map();
  const sessionTurnSeqs = new Map();
  const cancelledTurnSeqs = new Map();
  const lastCancelTimes = new Map();

  const sessionFollowers = new Map();
  const pendingApprovals = new Map();
  let approvalCounter = 1;

  /* -------------------------------------------------------------- *
   * Shared core wiring (see lib/core.mjs).
   *
   * The registries above stay as the live objects this entry has always used;
   * core's helpers wrap the same Maps so the logic itself lives in one place.
   * -------------------------------------------------------------- */
  const coreTurns = createTurnRegistry({
    sessionTurnSeqs,
    cancelledTurnSeqs,
    lastCancelTimes,
    activePrompts
  });
  const coreApprovals = createApprovalQueue({ pendingApprovals });
  const coreFollowers = createFollowerRegistry({
    sessionFollowers,
    // Stream opens are issued by followSession / connectUpstreamMux below.
    onSubscribe: null
  });
  /** Agent personas were only served by the standalone gateway. [unified] */
  const personaStore = createPersonaStore({ home: dshHomeDir });
  /** Single permission store; persists to ~/.dsh/mobile-access/permissions.json. */
  const permStore = createPermissionStore();
  const connectedClients = new Set();
  let currentEventsClientId = null;

  const globalPermissions = permStore.global;
  const sessionPermissions = permStore.sessions;

  function getPermissionsPayload() {
    return permStore.payload();
  }

  function persistAndBroadcastPermissions() {
    const payload = permStore.persist();
    broadcastToMobileClients({
      type: 'permission_updated',
      permissions: payload
    });
    return payload;
  }

  /**
   * Ensure a live stream is open for this session.
   * Buffer creation and the open-frame payload live in core; whether the
   * upstream link is actually connected is decided here.
   */
  function followSession(sId) {
    if (!sId) return;
    const fullId = sId.startsWith('session-') ? sId : `session-${sId}`;
    const follower = coreFollowers.ensure(fullId);
    if (follower.subscribed) return;

    if (upstreamMuxWs && upstreamMuxWs.readyState === WebSocket.OPEN) {
      coreFollowers.follow(fullId, (open) => {
        upstreamMuxWs.send(JSON.stringify(open));
      });
    }
  }

  function getSessionPermission(sessionId) {
    return permStore.forSession(sessionId);
  }

  function setSessionPermission(sessionId, policy) {
    if (sessionId) {
      permStore.setSession(sessionId, policy);
      audit('permission/session', { sessionId, policy });
      persistAndBroadcastPermissions();
    }
  }

  function getSessionFollower(sessionId) {
    return coreFollowers.get(sessionId);
  }

  function getSettingsData() {
    let availableModels = [];
    let currentModel = 'cn:auto';

    // 1. 尝试从 profiles/web/cordis.patch.yml 读取全部配置的大模型
    const patchPath = path.join(dshHomeDir, 'profiles', 'web', 'cordis.patch.yml');
    if (fs.existsSync(patchPath)) {
      try {
        const patchContent = fs.readFileSync(patchPath, 'utf8');
        const patchDoc = YAML.parse(patchContent);
        const seen = new Set();
        for (const entry of (Array.isArray(patchDoc) ? patchDoc : [])) {
          if (entry && (entry.id === 'llm-pi-ai' || entry.name === '@deepseek-ai/dsh-llm-pi-ai')) {
            const providers = entry.config?.providers || {};
            for (const [pKey, pVal] of Object.entries(providers)) {
              if (Array.isArray(pVal?.models)) {
                for (const m of pVal.models) {
                  const mId = m.id || m.name;
                  if (mId && !seen.has(mId)) {
                    seen.add(mId);
                    availableModels.push({
                      id: mId,
                      name: m.name || mId,
                      contextWindow: m.contextWindow || 256000,
                      maxTokens: m.maxTokens || 32000
                    });
                  }
                }
              }
            }
          }
          if (entry && (entry.id === 'agent-default-model' || entry.name === '@deepseek-ai/dsh-agent-default-model')) {
            if (entry.config?.model) {
              currentModel = entry.config.model;
            }
          }
        }
      } catch (err) {
        logger.error('[Settings] Error parsing cordis.patch.yml:', err);
      }
    }

    // 2. 检查 settings.yaml 覆盖
    const settingsYamlPath = path.join(dshHomeDir, 'settings.yaml');
    if (fs.existsSync(settingsYamlPath)) {
      try {
        const content = fs.readFileSync(settingsYamlPath, 'utf8');
        const doc = YAML.parse(content) || {};
        if (doc['agent-default-model'] && doc['agent-default-model'].model) {
          currentModel = doc['agent-default-model'].model;
        }
        if (doc['llm-pi-ai'] && doc['llm-pi-ai'].providers && doc['llm-pi-ai'].providers.wb) {
          const wb = doc['llm-pi-ai'].providers.wb;
          if (Array.isArray(wb.models) && wb.models.length > 0) {
            for (const m of wb.models) {
              const mId = m.id || m.name;
              if (mId && !availableModels.some(x => x.id === mId)) {
                availableModels.push({
                  id: mId,
                  name: m.name || mId,
                  contextWindow: m.contextWindow || 256000,
                  maxTokens: m.maxTokens || 32000
                });
              }
            }
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
      permissions: {
        defaultPolicy: globalPermissions.executionPolicy,
        executionPolicy: globalPermissions.executionPolicy,
        sandboxMode: globalPermissions.sandboxMode,
        maxSteps: globalPermissions.maxSteps,
        protectGit: globalPermissions.protectGit !== false
      }
    };
  }

  function updateDefaultModel(modelId) {
    // 同时更新 cordis.patch.yml 与 settings.yaml
    const patchPath = path.join(dshHomeDir, 'profiles', 'web', 'cordis.patch.yml');
    if (fs.existsSync(patchPath)) {
      try {
        const patchContent = fs.readFileSync(patchPath, 'utf8');
        const patchDoc = YAML.parseDocument(patchContent);
        if (patchDoc.contents && Array.isArray(patchDoc.contents.items)) {
          let found = false;
          for (const item of patchDoc.contents.items) {
            if (item.get && (item.get('id') === 'agent-default-model' || item.get('name') === '@deepseek-ai/dsh-agent-default-model')) {
              let config = item.get('config');
              if (!config) {
                item.set('config', { model: modelId });
              } else {
                config.set('model', modelId);
              }
              found = true;
              break;
            }
          }
          if (!found) {
            patchDoc.contents.items.push(patchDoc.createNode({
              id: 'agent-default-model',
              name: '@deepseek-ai/dsh-agent-default-model',
              config: { model: modelId }
            }));
          }
          fs.writeFileSync(patchPath, patchDoc.toString(), 'utf8');
        }
      } catch (err) {
        logger.error('[updateDefaultModel] Error updating cordis.patch.yml:', err);
      }
    }

    const settingsYamlPath = path.join(dshHomeDir, 'settings.yaml');
    try {
      let content = fs.existsSync(settingsYamlPath) ? fs.readFileSync(settingsYamlPath, 'utf8') : '';
      const doc = content ? YAML.parseDocument(content) : new YAML.Document();
      doc.setIn(['agent-default-model', 'model'], modelId);
      fs.writeFileSync(settingsYamlPath, doc.toString(), 'utf8');
    } catch (e) {
      logger.error('[updateDefaultModel] Error updating settings.yaml:', e);
    }
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
      const archivedSessionIds = new Set(rawWs.global?.archivedSessionIds || []);
      const result = [];

      for (const [wsId, wsInfo] of Object.entries(wsTable)) {
        const sessionIds = wsInfo.sessionIds || [];
        const sessionList = [];

        for (const sId of sessionIds) {
          const cleanId = sId.startsWith('session-') ? sId.replace('session-', '') : sId;
          // 过滤已归档的会话（与 Web 端 SessionTree 保持一致）
          if (archivedSessionIds.has(sId) || archivedSessionIds.has(cleanId) || archivedSessionIds.has(`session-${cleanId}`)) {
            continue;
          }

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
          let isBlankSession = false;

          for (const cPath of candidates) {
            if (fs.existsSync(cPath)) {
              try {
                const cache = JSON.parse(fs.readFileSync(cPath, 'utf8'));
                const rows = cache.record?.rows || {};
                // Web 端 sessionVisible: 排除 blank 会话（未输入任何 prompt 的空会话）
                if (rows.sessionListMetadata?.val?.blank === true && !rows.titleInput?.val?.first?.text) {
                  isBlankSession = true;
                }
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

          // 如果是尚未开始对话的空白会话且没有正在运行，与 Web 端保持一致进行过滤
          if (isBlankSession && !sessionMeta.isRunning) {
            continue;
          }

          if (!sessionMeta.model) {
            sessionMeta.model = getSettingsData().currentModel || 'cn:deepseek-v4.1-flash';
          }
          const pendingForSession = coreApprovals.list().filter(a => {
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
    const fullId = sessionId.startsWith('session-') ? sessionId : `session-${sessionId}`;
    followSession(fullId);
    const follower = getSessionFollower(sessionId) || getSessionFollower(fullId);
    const isRecentlyPrompted = activePrompts.has(sessionId) || activePrompts.has(cleanId) || activePrompts.has(`session-${cleanId}`);

    let lastSeq = 50000;
    if (cacheData && cacheData.record && cacheData.record.rows) {
      const rows = cacheData.record.rows;
      model = rows.modelSelection?.val?.lastUsed?.model || '';
      const lastActivity = rows.sessionListMetadata?.val?.lastPromptAt || cacheData.record?.identity?.createdAt || 0;
      const isRecentActivity = (Date.now() - lastActivity) < 45000;
      const isOpenTurnActive = rows.turnBoundary?.val?.openTurnStartSeq != null && isRecentActivity;
      isRunning = (follower && follower.isRunning) || isRecentlyPrompted || isOpenTurnActive;
      lastSeq = rows.turnBoundary?.val?.lastStepBoundary?.seq ?? 
                rows.sessionListMetadata?.val?.lastSeq ?? 
                rows.titleInput?.val?.lastSeq ?? 50000;
    }

    // 1. 调用 DSH 原生 RPC session/page 获取真实历史事件流
    try {
      const targetSessionId = sessionId.startsWith('session-') ? sessionId : `session-${sessionId}`;
      const pageResult = await callDshRpc('session/page', {
        args: {
          request: {
            address: { kind: 'session', sessionId: targetSessionId },
            throughSeq: lastSeq,
            maxMessages: 100
          }
        }
      });

      if (pageResult && Array.isArray(pageResult.records)) {
        let currentAssistantMsg = null;
        for (const record of pageResult.records) {
          const ev = record.event;
          if (!ev) continue;

          if (ev.type === 'user/message') {
            currentAssistantMsg = null;
            let text = '';
            if (Array.isArray(ev.data?.content)) {
              for (const part of ev.data.content) {
                if (part.type === 'text' && part.text) text += part.text;
              }
            } else if (typeof ev.data?.content === 'string') {
              text = ev.data.content;
            }

            // 过滤系统注入的元信息与内部记忆快照
            // isCarriedContext (core) recognises the full set of injected blocks,
            // including Mnemon plugin-sourced snapshots that the previous inline
            // prefix check missed — those were being shown to the user as if they
            // had typed them.  [unified]
            if (isCarriedContext(text, ev) ||
                text.startsWith('Time sampled while preparing turn') ||
                text.startsWith('Memory recall guidance') ||
                text.includes('<system_information>')) {
              continue;
            }

            if (text.trim()) {
              messages.push({
                id: crypto.randomUUID(),
                role: 'user',
                content: text.trim(),
                time: ev.time || Date.now()
              });
            }
          } else if (ev.type === 'assistant/message') {
            const msgObj = ev.data?.message;
            let reasoning = '';
            let text = '';
            if (Array.isArray(msgObj?.content)) {
              for (const part of msgObj.content) {
                if (part.type === 'reasoning') reasoning += part.text || '';
                if (part.type === 'text') text += part.text || '';
              }
            } else if (typeof msgObj?.content === 'string') {
              text = msgObj.content;
            }

            if (reasoning || text) {
              if (!currentAssistantMsg) {
                currentAssistantMsg = {
                  id: crypto.randomUUID(),
                  role: 'assistant',
                  content: text,
                  thinking: reasoning,
                  tools: [],
                  time: ev.time || Date.now()
                };
                messages.push(currentAssistantMsg);
              } else {
                if (reasoning) {
                  currentAssistantMsg.thinking = (currentAssistantMsg.thinking ? currentAssistantMsg.thinking + '\n' : '') + reasoning;
                }
                if (text) {
                  currentAssistantMsg.content = (currentAssistantMsg.content ? currentAssistantMsg.content + '\n' : '') + text;
                }
              }
            }
          } else if (ev.type === 'tool/call') {
            const callData = ev.data;
            if (currentAssistantMsg && callData?.name) {
              currentAssistantMsg.tools.push({
                name: callData.name,
                input: coerceToolInput(callData.arguments),
                id: callData.callId
              });
            }
          }
        }
      }
    } catch (rpcErr) {
      logger.warn('[getSessionHistory] RPC session/page error:', rpcErr?.message || rpcErr);
    }

    // 2. 兜底解析：若 RPC 无结果但存在 titleInput，填充首轮用户输入
    if (messages.length === 0 && cacheData?.record?.rows) {
      const rows = cacheData.record.rows;
      if (rows.titleInput?.val?.first?.text) {
        messages.push({
          id: crypto.randomUUID(),
          role: 'user',
          content: rows.titleInput.val.first.text,
          time: cacheData.record.identity?.createdAt || Date.now()
        });
      }
    }

    // 3. In-flight turn & pending stream chunks reconciliation (F3.3)
    if (follower && follower.isRunning && (follower.textBuffer || follower.thinkingBuffer || follower.activePromptText)) {
      isRunning = true;

      // Ensure active user prompt is included if not yet present in messages
      if (follower.activePromptText && (messages.length === 0 || messages[messages.length - 1].role !== 'user' || messages[messages.length - 1].content !== follower.activePromptText)) {
        messages.push({
          id: `user_prompt_${cleanId}_${Date.now()}`,
          role: 'user',
          content: follower.activePromptText,
          time: Date.now() - 1000,
          seq: 999998,
          turn: 999998
        });
      }

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
      } else if (messages[messages.length - 1].role === 'assistant') {
        const lastMsg = messages[messages.length - 1];
        if (follower.textBuffer && follower.textBuffer.length > (lastMsg.content?.length || 0)) {
          lastMsg.content = follower.textBuffer;
        }
        if (follower.thinkingBuffer && !lastMsg.thinking) {
          lastMsg.thinking = follower.thinkingBuffer;
        }
        if (follower.tools && follower.tools.length > 0) {
          lastMsg.tools = follower.tools;
        }
        lastMsg.isStreaming = follower.isRunning;
      }
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
    if (isDisposed) return;
    if (upstreamMuxWs) {
      // Detach listeners and keep an error sink so a close that races an
      // in-flight handshake cannot surface as an uncaught exception.
      try { upstreamMuxWs.removeAllListeners(); } catch (_) {}
      try { upstreamMuxWs.on('error', () => {}); } catch (_) {}
      try { upstreamMuxWs.close(); } catch (_) {}
      upstreamMuxWs = null;
    }

    const authority = `127.0.0.1:${dshPort}`;
    const cookie = cookieFactory.current();
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
      // 1. Subscribe to DSH $events stream for approvals and interaction
      upstreamMuxWs.send(JSON.stringify({
        type: 'open',
        streamId: 'gw-events-stream',
        endpoint: '$events',
        payload: { args: {} }
      }));

      // 2. Re-follow tracked active sessions
      for (const follower of sessionFollowers.values()) {
        if (!follower.subscribed) {
          try {
            upstreamMuxWs.send(JSON.stringify({
              type: 'open',
              streamId: follower.streamId || `follow-${follower.sessionId}`,
              endpoint: 'session/follow',
              payload: { args: { request: { address: { kind: 'session', sessionId: follower.sessionId }, assistantStream: true } } }
            }));
            follower.subscribed = true;
          } catch (_) {}
        }
      }
    });

    upstreamMuxWs.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString());
        handleUpstreamMuxMessage(msg);
      } catch (_) {}
    });

    upstreamMuxWs.on('close', () => {
      if (isDisposed) return;
      currentEventsClientId = null;
      for (const follower of sessionFollowers.values()) {
        follower.subscribed = false;
      }
      if (muxReconnectTimer) clearTimeout(muxReconnectTimer);
      muxReconnectTimer = setTimeout(connectUpstreamMux, 3000);
      // Don't hold the event loop open just to retry an upstream link.
      muxReconnectTimer.unref?.();
    });

    upstreamMuxWs.on('error', (err) => {
      logger.warn('dsh-mobile-bridge: MUX 错误 %s', err?.message || err);
    });
  }

  function handleUpstreamMuxMessage(msg) {
    if (!msg) return;

    // 1. Upstream MUX Item Frames (Standard DSH MUX protocol)
    if (msg.type === 'item') {
      const streamId = msg.streamId || '';

      // A. Session follow stream
      if (streamId.startsWith('follow-')) {
        const sId = streamId.replace('follow-', '');
        const cleanId = sId.replace('session-', '');
        let follower = getSessionFollower(sId);
        if (!follower) {
          follower = {
            sessionId: sId,
            streamId,
            isRunning: false,
            thinkingBuffer: '',
            textBuffer: '',
            tools: [],
            subscribed: true,
            lastUpdated: Date.now()
          };
          sessionFollowers.set(cleanId, follower);
          sessionFollowers.set(sId, follower);
        }
        follower.lastUpdated = Date.now();

        const val = msg.value;
        if (!val) return;

        if (val.type === 'assistant-stream' && val.frame) {
          const aFrame = val.frame;
          if (aFrame.type === 'start') {
            follower.isRunning = true;
            follower.thinkingBuffer = '';
            follower.textBuffer = '';
            follower.tools = [];
            broadcastToMobileClients({ type: 'session_status', sessionId: sId, isRunning: true });
          } else if (aFrame.type === 'chunk' && aFrame.chunk) {
            const c = aFrame.chunk;
            follower.isRunning = true;
            if (c.type === 'reasoning-delta' && c.text) {
              follower.thinkingBuffer += c.text;
              broadcastToMobileClients({ type: 'thinking', sessionId: sId, delta: c.text, text: c.text });
            } else if (c.type === 'text-delta' && c.text) {
              follower.textBuffer += c.text;
              broadcastToMobileClients({ type: 'delta', sessionId: sId, delta: c.text, text: c.text });
            } else if (c.type === 'tool-call-delta') {
              broadcastToMobileClients({ type: 'tool_call', sessionId: sId, tool: c.name || 'tool', delta: c.argumentsDelta || '' });
            }
          }
          return;
        }

        if (val.type === 'event' && val.event) {
          const ev = val.event;
          if (ev.type === 'turn/start') {
            follower.isRunning = true;
            follower.thinkingBuffer = '';
            follower.textBuffer = '';
            follower.tools = [];
            broadcastToMobileClients({ type: 'session_status', sessionId: sId, isRunning: true });
          } else if (ev.type === 'turn/end') {
            follower.isRunning = false;
            follower.activePromptText = null;
            activePrompts.delete(sId);
            activePrompts.delete(cleanId);
            broadcastToMobileClients({ type: 'done', sessionId: sId });
            follower.thinkingBuffer = '';
            follower.textBuffer = '';
            follower.tools = [];
            broadcastToMobileClients({ type: 'session_status', sessionId: sId, isRunning: false });
          } else if (ev.type === 'tool/call') {
            const toolObj = {
              id: ev.data?.id || `tool_${Date.now()}`,
              name: ev.data?.name || 'tool',
              input: coerceToolInput(ev.data?.arguments),
              output: '',
              isRunning: true
            };
            follower.tools.push(toolObj);
            broadcastToMobileClients({ type: 'tool_start', sessionId: sId, tool: toolObj.name, input: toolObj.input });
          } else if (ev.type === 'tool/result') {
            if (follower.tools.length > 0) {
              const t = follower.tools[follower.tools.length - 1];
              t.isRunning = false;
              t.output = ev.data?.output || '执行完毕';
            }
            broadcastToMobileClients({ type: 'tool_result', sessionId: sId, output: ev.data?.output || '执行完毕' });
          }
          return;
        }
        return;
      }

      // B. $events stream (approvals and requests)
      if (msg.value) {
        const val = msg.value;
        if (val.type === 'ready') {
          currentEventsClientId = val.clientId || '';
          logger.info(`[dsh-mobile-bridge] $events stream ready with clientId: ${currentEventsClientId}`);
          return;
        }

        if (val.type === 'cancel' || val.event === 'approval/cancel') {
          const eventId = val.eventId || val.id;
          if (eventId) {
            const appr = coreApprovals.get(eventId);
            if (appr) {
              coreApprovals.remove(appr, eventId);
              broadcastToMobileClients({
                type: 'approval_settled',
                eventId: appr.eventId || eventId,
                outcome: 'cancelled',
                reason: '上游任务已终止或取消'
              });
              audit('approval/cancelled', { approvalId: eventId });
            }
          }
          return;
        }

        if ((val.type === 'request' || val.type === 'waterfall') && val.event === 'approval/request') {
          const eventId = val.id || val.eventId || val.request?.id || `appr_${approvalCounter++}`;
          const sessionId = val.agent || val.agentId || 'default';
          const toolName = val.request?.toolName || '工具执行';
          const reason = val.request?.reason || '申请工具执行权限';
          const callId = val.request?.callId || '';
          const input = coerceToolInput(val.request?.input ?? val.request?.arguments ?? val.request?.args ?? val.request?.command);
          const options = val.request?.options || null;

          const sessionPolicy = getSessionPermission(sessionId);
          let shouldAutoApprove = false;
          let autoApproveReason = '';

          if (sessionPolicy === 'danger-full-access' || globalPermissions.executionPolicy === 'danger-full-access') {
            shouldAutoApprove = true;
            autoApproveReason = '全信任模式 (Danger Full Access) 自动放行';
          } else if (sessionPolicy === 'auto-read' || globalPermissions.executionPolicy === 'auto-read') {
            let cmdToCheck = reason;
            if (typeof val.request?.command === 'string') cmdToCheck = val.request.command;
            else if (typeof input === 'string' && input) cmdToCheck = input;
            if (isCommandReadOnly(cmdToCheck, toolName)) {
              shouldAutoApprove = true;
              autoApproveReason = '安全策略: 只读指令自动放行';
            }
          }

          if (shouldAutoApprove) {
            callDshRpc('$events/result', {
              clientId: currentEventsClientId,
              eventId,
              outcome: { kind: 'result', value: 'allowed-once' },
              args: { clientId: currentEventsClientId, eventId, outcome: { kind: 'result', value: 'allowed-once' } }
            }).catch(() => {});
            audit('approval/auto-approved', { id: eventId, time: Date.now(), sessionId, toolName, command: reason, outcome: 'auto-approved', reason: autoApproveReason });
            return;
          }

          const approval = {
            id: eventId,
            eventId,
            clientId: currentEventsClientId,
            sessionId,
            toolName,
            reason,
            callId,
            input,
            options,
            createdAt: Date.now()
          };

          coreApprovals.put(approval);
          audit('approval/requested', approval);
          broadcastToMobileClients({
            type: 'approval_request',
            approval
          });
          return;
        }
      }
    }

    // 2. Legacy event frame fallback ({ type: 'event', event: { ... } })
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
        const eventId = ev.id || ev.eventId || `appr_${approvalCounter++}`;
        const approval = {
          id: eventId,
          eventId,
          clientId: currentEventsClientId,
          sessionId: sId,
          toolName: ev.toolName || ev.action || '系统执行',
          reason: ev.reason || ev.command || '申请工具执行权限',
          callId: ev.callId || '',
          input: ev.input || ev.command || '',
          options: ev.options || null,
          createdAt: Date.now()
        };
        coreApprovals.put(approval);
        broadcastToMobileClients({
          type: 'approval_request',
          approval
        });
        audit('approval/requested', approval);
      } else if (ev.type === 'session_status') {
        const isCancelled = coreTurns.getCancelledSeq(sId) > 0 && (Date.now() - coreTurns.getLastCancelTime(sId) < 1000);
        const follower = getSessionFollower(sId);
        const shouldRun = Boolean(ev.isRunning && !isCancelled && (follower ? follower.isRunning : true));
        broadcastToMobileClients({
          type: 'session_status',
          sessionId: sId,
          isRunning: shouldRun
        });
      }
    }
  }

  async function handleApprovalRespond(eventId, outcome, reason = '') {
    const appr = coreApprovals.get(eventId);
    if (!appr) {
      const normalizedOutcome = (outcome === 'allow' || outcome === 'allowed-once' || outcome === 'approve')
        ? 'allowed-once'
        : 'rejected';
      return {
        ok: false,
        code: 404,
        approvalId: eventId,
        eventId: eventId,
        outcome: normalizedOutcome,
        error: `Approval request with ID ${eventId} not found or expired`
      };
    }

    const normalizedOutcome = (outcome === 'allow' || outcome === 'allowed-once' || outcome === 'approve')
      ? 'allowed-once'
      : 'rejected';

    coreApprovals.remove(appr, eventId);

    audit('approval/respond', {
      approvalId: appr.eventId || eventId,
      outcome: normalizedOutcome,
      reason: reason || (normalizedOutcome === 'allowed-once' ? '人工手机审批放行' : '人工手机拒绝执行')
    });

    try {
      await callDshRpc('$events/result', {
        clientId: appr.clientId || currentEventsClientId,
        eventId: appr.eventId || appr.id,
        outcome: { kind: 'result', value: normalizedOutcome },
        args: {
          clientId: appr.clientId || currentEventsClientId,
          eventId: appr.eventId || appr.id,
          outcome: { kind: 'result', value: normalizedOutcome }
        }
      });
    } catch (e) {
      logger.warn('[dsh-mobile-bridge] Upstream $events/result RPC warning:', e?.message || e);
    }

    broadcastToMobileClients({
      type: 'approval_settled',
      eventId: appr.eventId || appr.id || eventId,
      outcome: normalizedOutcome,
      reason: reason || ''
    });

    return {
      ok: true,
      code: 0,
      approvalId: appr.eventId || eventId,
      eventId: appr.eventId || eventId,
      outcome: normalizedOutcome,
      message: `Approval ${normalizedOutcome} recorded`
    };
  }

  // authenticateRequest now lives in core; call sites pass the parsed URL through.

  const server = createServer(async (req, res) => {
    const parsedUrl = url.parse(req.url, true);
    const pathname = parsedUrl.pathname;

    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, x-dsh-token, x-auth-code');

    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }

    const sendJson = (status, obj) => {
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(obj));
    };

    // 1. 健康探测与鉴权测试 (供手机端 testConnection 测试连通性)
    if (pathname === '/health' || pathname === '/api/mobile/health' || pathname === '/__mobile/health' || pathname === '/api/mobile/ping') {
      let testToken = '';
      const authHeader = req.headers['authorization'];
      if (authHeader && authHeader.startsWith('Bearer ')) {
        testToken = authHeader.slice(7).trim();
      } else if (req.headers['x-dsh-token']) {
        testToken = String(req.headers['x-dsh-token']).trim();
      } else if (req.headers['x-auth-code']) {
        testToken = String(req.headers['x-auth-code']).trim();
      } else if (parsedUrl.query?.token) {
        testToken = String(parsedUrl.query.token).trim();
      }
      const isAuthed = verifyToken(testToken);
      if (!isAuthed) {
        sendJson(401, {
          code: 401,
          ok: false,
          authenticated: false,
          error: '认证失败: 授权码无效或为空 (Unauthorized)',
          name: 'dsh-mobile-bridge',
          port: listenPort,
          version: BRIDGE_VERSION
        });
        return;
      }
      sendJson(200, {
        code: 0,
        ok: true,
        authenticated: true,
        name: 'dsh-mobile-bridge',
        port: listenPort,
        dshPort: dshPort,
        version: BRIDGE_VERSION,
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

    // 3a. 生成配对码（供 DSH 设置页 / 运维调用，短期有效）
    if ((pathname === '/__mobile/pair/code' || pathname === '/api/mobile/pair/code') && req.method === 'POST') {
      // Already authenticated above? No — this route sits before the auth block,
      // so require the shared token explicitly.
      const authOk = authenticateRequest(req, parsedUrl);
      if (!authOk.ok) {
        sendJson(401, { ok: false, error: 'Unauthorized' });
        return;
      }
      const code = newPairCode();
      const expiresAt = Date.now() + pairCodeTtlMs();
      pairSession = { code, expiresAt };
      audit('pair/code-generated', { expiresAt });
      sendJson(200, { ok: true, code, expiresAt, ttlMs: pairCodeTtlMs() });
      return;
    }

    // 3. 手机配对接口
    if (pathname === '/__mobile/pair' && req.method === 'POST') {
      const cl = parseInt(req.headers['content-length'], 10);
      if (!isNaN(cl) && cl > MAX_BODY_SIZE) {
        sendJson(413, { error: 'Payload Too Large: Request body exceeds 2MB limit' });
        req.on('data', () => {});
        req.resume();
        res.on('finish', () => { setTimeout(() => { try { req.destroy(); } catch (_) {} }, 50); });
        return;
      }
      let body = '';
      let bytesRecv = 0;
      let aborted = false;
      req.on('data', chunk => {
        if (aborted) return;
        bytesRecv += chunk.length;
        if (bytesRecv > MAX_BODY_SIZE) {
          aborted = true;
          sendJson(413, { error: 'Payload Too Large: Request body exceeds 2MB limit' });
          req.on('data', () => {});
          req.resume();
          res.on('finish', () => { setTimeout(() => { try { req.destroy(); } catch (_) {} }, 50); });
          return;
        }
        body += chunk;
      });
      req.on('end', () => {
        if (aborted) return;
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
            version: BRIDGE_VERSION
          });
        } catch (e) {
          sendJson(500, { ok: false, error: e?.message || '配对处理失败' });
        }
      });
      return;
    }

    // 4. REST 业务接口鉴权
    const auth = authenticateRequest(req, parsedUrl);
    if (!auth.ok) {
      sendJson(401, { error: 'Unauthorized', message: '缺少有效令牌或设备未配对' });
      return;
    }
    // Keep the device's lastSeenAt fresh so the settings page can show real usage.
    if (auth.device?.id) touchDevice(auth.device.id, req.socket?.remoteAddress || '');

    let jsonBody = {};
    if (req.method === 'POST' || req.method === 'PUT') {
      // Body buffering with the 2MB cap lives in core; on overflow it answers 413
      // and destroys the socket only after the response flushes, so the client
      // sees 413 instead of ECONNRESET.
      let raw;
      try {
        raw = await readBodyWithLimit(req, res, { sendJson });
      } catch (err) {
        if (err?.aborted || res.headersSent) return;
        throw err;
      }
      jsonBody = parseJsonBody(raw);
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
        let rawSessionId = jsonBody.sessionId;
        let promptText = jsonBody.text ?? jsonBody.prompt;
        if (typeof promptText === 'object' && promptText !== null) {
          if (typeof promptText.text === 'string') promptText = promptText.text;
          else if (typeof promptText.content === 'string') promptText = promptText.content;
          else { try { promptText = JSON.stringify(promptText); } catch (_) { promptText = ''; } }
        } else if (promptText != null) {
          promptText = String(promptText);
        } else {
          promptText = '';
        }
        const sessionId = typeof rawSessionId === 'string' ? rawSessionId.trim() : (rawSessionId != null ? String(rawSessionId).trim() : '');
        if (!sessionId) {
          sendJson(400, { error: 'Missing or empty sessionId' });
          return;
        }
        const text = promptText;
        if (!text.trim()) {
          sendJson(400, { error: 'Missing or empty prompt text' });
          return;
        }

        const now = Date.now();
        const recentCancel = coreTurns.getLastCancelTime(sessionId);
        // Turn sequence fencing: if a cancellation was recorded very recently (e.g. within 350ms)
        // for this session due to concurrent prompt/cancel race, treat this prompt as canceled immediately
        if (now - recentCancel < 350) {
          sendJson(200, { ok: true, code: 0, cancelled: true, message: 'Turn was cancelled' });
          return;
        }

        const thisTurnSeq = coreTurns.nextTurnSeq(sessionId);

        activePrompts.set(sessionId, now);
        const follower = getSessionFollower(sessionId);
        if (follower) {
          follower.isRunning = true;
          follower.thinkingBuffer = '';
          follower.textBuffer = '';
          follower.tools = [];
          follower.activePromptText = text || '';
          follower.lastUpdated = now;
        }

        broadcastToMobileClients({ type: 'session_status', sessionId, isRunning: true });

        try {
          const promptRes = await callDshRpc('session/prompt', {
            args: {
              request: {
                requestId: crypto.randomUUID(),
                sessionId: sessionId,
                mode: 'queue',
                content: [{ type: 'text', text: text }]
              }
            }
          });

          // Check if session was cancelled while prompt RPC was awaiting
          const isCancelled = coreTurns.getCancelledSeq(sessionId) >= thisTurnSeq || (Date.now() - coreTurns.getLastCancelTime(sessionId) < 500);
          if (isCancelled) {
            try {
              await callDshRpc('session/cancel', {
                args: { request: { sessionId } }
              });
            } catch (cancelErr) {
              // The UI has already flipped to idle; if the engine cancel fails the
              // turn may still be running upstream. Surface it instead of pretending.
              logger.warn('[dsh-mobile-bridge] 取消补偿失败 %s: %s', sessionId, cancelErr?.message || cancelErr);
              audit('session/cancel-compensate-failed', { sessionId, error: cancelErr?.message });
            }
            activePrompts.delete(sessionId);
            if (follower) {
              follower.isRunning = false;
              follower.activePromptText = null;
            }
            broadcastToMobileClients({ type: 'session_status', sessionId, isRunning: false });
            broadcastToMobileClients({ type: 'done', sessionId });
            sendJson(200, { ok: true, code: 0, cancelled: true, result: promptRes });
            return;
          }

          sendJson(200, { ok: true, code: 0, result: promptRes });
          audit('session/prompt', { sessionId, length: text.length });
          return;
        } catch (err) {
          activePrompts.delete(sessionId);
          if (follower) {
            follower.isRunning = false;
            follower.activePromptText = null;
          }

          const isCancelled = coreTurns.getCancelledSeq(sessionId) >= thisTurnSeq;
          if (!isCancelled) {
            broadcastToMobileClients({ type: 'session_status', sessionId, isRunning: false });
            broadcastToMobileClients({ type: 'error', sessionId, error: err?.message || 'Prompt execution failed' });
            broadcastToMobileClients({ type: 'done', sessionId });
          }

          sendJson(500, { ok: false, error: err?.message || 'Prompt execution failed' });
          return;
        }
      }

      if (pathname === '/api/mobile/sessions/cancel' && req.method === 'POST') {
        const rawSessionId = jsonBody.sessionId;
        if (!rawSessionId || !String(rawSessionId).trim()) {
          sendJson(400, { error: 'Missing or empty sessionId' });
          return;
        }
        const sessionId = String(rawSessionId).trim();

        const now = Date.now();
        coreTurns.recordCancel(sessionId, now);

        activePrompts.delete(sessionId);
        const follower = getSessionFollower(sessionId);
        if (follower) {
          follower.isRunning = false;
          follower.thinkingBuffer = '';
          follower.textBuffer = '';
          follower.tools = [];
          follower.activePromptText = null;
        }

        broadcastToMobileClients({ type: 'session_status', sessionId, isRunning: false });
        broadcastToMobileClients({ type: 'done', sessionId });

        try {
          await callDshRpc('session/cancel', {
            args: {
              request: {
                sessionId: sessionId
              }
            }
          });
        } catch (cancelErr) {
          // Report the real outcome — a 200 "Cancelled" here would leave the turn
          // running upstream while the phone shows it as stopped.
          logger.warn('[dsh-mobile-bridge] session/cancel 失败 %s: %s', sessionId, cancelErr?.message || cancelErr);
          audit('session/cancel-failed', { sessionId, error: cancelErr?.message });
          sendJson(502, {
            ok: false,
            code: 502,
            sessionId,
            error: cancelErr?.message || 'Upstream cancel failed'
          });
          return;
        }

        sendJson(200, { ok: true, code: 0, message: 'Cancelled' });
        return;
      }

      if (pathname === '/api/mobile/sessions/delete' && req.method === 'POST') {
        const { sessionId, workspaceId } = jsonBody;
        // Implemented bridge-side: the engine has no session/delete RPC, so the
        // old callDshRpc('session/delete') + `catch(_){}` returned 200 "Deleted"
        // while removing nothing. [fixed]
        const result = deleteSession({ home: dshHomeDir, sessionId, workspaceId });

        if (!result.ok) {
          audit('session/delete-failed', { sessionId, error: result.error });
          sendJson(500, { ok: false, code: 500, sessionId, error: result.error });
          return;
        }

        // Purge live state so a later reconnect cannot resurrect the session.
        activePrompts.delete(sessionId);
        coreFollowers.map.delete(sessionId);
        coreFollowers.map.delete(sessionId.replace(/^session-/, ''));
        coreApprovals.removeBySession(sessionId);
        if (coreFollowers.get(sessionId)) {
          coreFollowers.get(sessionId).isRunning = false;
        }

        audit('session/delete', { sessionId, workspaceId, detached: result.detached });
        broadcastToMobileClients({ type: 'session_deleted', sessionId });
        sendJson(200, { ok: true, code: 0, message: 'Deleted', sessionId, detached: result.detached });
        return;
      }

      // 4.2 设置与模型
      if (pathname === '/api/mobile/settings' && req.method === 'GET') {
        const sData = getSettingsData();
        sendJson(200, { ok: true, code: 0, settings: sData, ...sData });
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
        const resp = getPermissionsPayload();
        sendJson(200, { ok: true, code: 0, permissions: resp });
        return;
      }

      if (pathname === '/api/mobile/permissions' && req.method === 'POST') {
        const pol = jsonBody.defaultPolicy || jsonBody.executionPolicy;
        if (pol) globalPermissions.executionPolicy = pol;
        if (jsonBody.sandboxMode) globalPermissions.sandboxMode = jsonBody.sandboxMode;
        if (jsonBody.maxSteps) globalPermissions.maxSteps = Number(jsonBody.maxSteps);
        if (typeof jsonBody.protectGit === 'boolean') globalPermissions.protectGit = jsonBody.protectGit;
        if (jsonBody.sessionPolicies && typeof jsonBody.sessionPolicies === 'object') {
          for (const [sId, sPol] of Object.entries(jsonBody.sessionPolicies)) {
            if (typeof sPol === 'string') sessionPermissions.set(sId, sPol);
          }
        }

        const resp = persistAndBroadcastPermissions();
        sendJson(200, { ok: true, code: 0, permissions: resp });
        return;
      }

      if (pathname === '/api/mobile/sessions/permission' && req.method === 'POST') {
        setSessionPermission(jsonBody.sessionId, jsonBody.policy);
        sendJson(200, { ok: true, code: 0, sessionId: jsonBody.sessionId, policy: jsonBody.policy });
        return;
      }

      // 4.4 审批交互
      if (pathname === '/api/mobile/approvals' && req.method === 'GET') {
        sendJson(200, { ok: true, code: 0, approvals: coreApprovals.list() });
        return;
      }

      if (pathname === '/api/mobile/approval' && req.method === 'POST') {
        const eventId = jsonBody.eventId || jsonBody.approvalId || jsonBody.id;
        const outcome = jsonBody.outcome;
        const reason = jsonBody.reason || '';
        if (!eventId || !outcome) {
          sendJson(400, { ok: false, error: 'Missing eventId or outcome' });
          return;
        }
        const resOutcome = await handleApprovalRespond(eventId, outcome, reason);
        sendJson(200, resOutcome);
        return;
      }

      // 4.5 项目说明文档 (MEMORY.md / USER.MD) - Directory Traversal Hardened (F4.5)
      if ((pathname === '/api/mobile/workspace/memory' || pathname === '/api/mobile/memory') && req.method === 'GET') {
        const wsPath = parsedUrl.query?.workspacePath || parsedUrl.query?.path;
        const fileName = parsedUrl.query?.fileName || parsedUrl.query?.file || 'USER.MD';
        const check = sanitizeWorkspaceFilePath(wsPath, fileName);
        if (check.error) {
          sendJson(check.status, { ok: false, error: check.error });
          return;
        }
        let content = '';
        const exists = fs.existsSync(check.targetFile);
        if (exists) content = fs.readFileSync(check.targetFile, 'utf8');
        sendJson(200, { ok: true, code: 0, fileName, content, exists, filePath: check.targetFile });
        return;
      }

      if ((pathname === '/api/mobile/workspace/memory' || pathname === '/api/mobile/memory') && req.method === 'POST') {
        const wsPath = jsonBody.workspacePath || jsonBody.path;
        const fileName = jsonBody.fileName || jsonBody.file;
        const content = jsonBody.content;
        if (!wsPath || !fileName) {
          sendJson(400, { ok: false, error: 'Missing parameters (workspacePath and fileName required)' });
          return;
        }
        const check = sanitizeWorkspaceFilePath(wsPath, fileName);
        if (check.error) {
          sendJson(check.status, { ok: false, error: check.error });
          return;
        }
        const dir = path.dirname(check.targetFile);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(check.targetFile, content || '', 'utf8');
        sendJson(200, { ok: true, code: 0, fileName, message: 'Saved successfully', filePath: check.targetFile });
        audit('memory/update', { action: 'memory/update', event: 'memory/update', workspacePath: wsPath, fileName });
        return;
      }

      if (pathname === '/api/mobile/audit-logs' && req.method === 'GET') {
        const rawLogs = readAudit(100);
        const logs = rawLogs.map(l => ({
          ...l,
          action: l.action || l.toolName,
          event: l.event || l.action || l.toolName
        }));
        sendJson(200, { ok: true, code: 0, auditLogs: logs, logs: logs });
        return;
      }

      // Agent personas.  [unified] This route only existed on the standalone
      // gateway; the Flutter client calls it unconditionally on connect, so the
      // Cordis-hosted bridge used to answer 404 here.
      if (pathname === '/api/mobile/personas' && req.method === 'GET') {
        sendJson(200, { ok: true, code: 0, personas: personaStore.get() });
        return;
      }

      if (pathname === '/api/mobile/personas' && req.method === 'POST') {
        const list = Array.isArray(jsonBody.personas) ? jsonBody.personas : null;
        if (!list) {
          sendJson(400, { ok: false, error: 'personas must be an array' });
          return;
        }
        const okSave = personaStore.save(list);
        audit('personas/update', { count: list.length, saved: okSave });
        sendJson(okSave ? 200 : 500, { ok: okSave, code: okSave ? 0 : 500, personas: okSave ? list : personaStore.get() });
        return;
      }

      sendJson(404, { error: 'Not found', path: pathname });
    } catch (err) {
      if (res.headersSent) return;
      logger.error('[dsh-mobile-bridge] API error:', pathname, err);
      sendJson(500, { error: err?.message || 'Internal server error' });
    }
  });

  const wss = new WebSocket.Server({ noServer: true });

  server.on('upgrade', (req, socket, head) => {
    const parsed = url.parse(req.url, true);
    const pathname = parsed.pathname;

    if (pathname === '/mobile-ws' || pathname === '/api/mobile/ws') {
      const auth = authenticateRequest(req, parsed);
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

  // Heartbeat & dead socket tracking interval (F3.5) — constant lives in core.
  const heartbeatInterval = setInterval(() => {
    for (const ws of connectedClients) {
      if (ws.isAlive === false) {
        audit('ws/dead_prune', { ip: ws._remoteIp });
        connectedClients.delete(ws);
        try {
          ws.terminate();
        } catch (_) {}
        continue;
      }
      ws.isAlive = false;
      try {
        ws.ping();
      } catch (_) {
        connectedClients.delete(ws);
        try { ws.terminate(); } catch (_) {}
      }
    }
  }, HEARTBEAT_INTERVAL_MS);
  heartbeatInterval.unref?.();

  wss.on('connection', (ws, req) => {
    ws.isAlive = true;
    ws._remoteIp = req.socket?.remoteAddress;
    connectedClients.add(ws);
    audit('ws/connect', { ip: ws._remoteIp });

    ws.on('pong', () => {
      ws.isAlive = true;
    });

    ws.send(JSON.stringify({ type: 'connected', version: BRIDGE_VERSION, time: Date.now() }));
    ws.send(JSON.stringify({
      type: 'system',
      event: 'connected',
      message: 'Connected to DeepSeek Harness Agent',
      pendingApprovals: coreApprovals.list()
    }));

    ws.on('message', async (raw) => {
      ws.isAlive = true;
      try {
        const rawStr = String(raw).trim();
        // 1. Raw string ping support (case-insensitive) -> string pong
        if (rawStr.toLowerCase() === 'ping') {
          ws.send('pong');
          return;
        }

        const msg = JSON.parse(raw);

        // 2. JSON ping support ({"type": "ping"} or {"action": "ping"})
        if (msg.type === 'ping' || msg.action === 'ping') {
          ws.send(JSON.stringify({ type: 'pong', time: Date.now() }));
          return;
        }

        if ((msg.type === 'subscribe_session' || msg.type === 'follow' || msg.type === 'select_session') && (msg.sessionId || msg.id)) {
          const sId = msg.sessionId || msg.id;
          ws.sessionId = sId;
          followSession(sId);
          const follower = getSessionFollower(sId);
          if (follower) {
            ws.send(JSON.stringify({
              type: 'session_status',
              sessionId: sId,
              isRunning: follower.isRunning
            }));
          }
          if (msg.type === 'follow' || msg.type === 'select_session') {
            ws.send(JSON.stringify({ type: 'follow_ack', sessionId: sId }));
          }
        } else if (msg.type === 'approval_response') {
          const eventId = msg.eventId || msg.approvalId || msg.id;
          if (eventId && msg.outcome) {
            const res = await handleApprovalRespond(eventId, msg.outcome, msg.reason);
            ws.send(JSON.stringify({ type: 'approval_ack', eventId, outcome: res.outcome, ok: res.ok }));
          }
        }
      } catch (_) {}
    });

    ws.on('close', () => connectedClients.delete(ws));
    ws.on('error', () => connectedClients.delete(ws));
  });

  const apkFilePath = path.join(import.meta.dirname ?? path.dirname(url.fileURLToPath(import.meta.url)), '..', 'public', 'dsh-agent.apk');
  const disposeRpc = installRpc(ctx, {
    dshPort,
    isListening: true
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

  const cleanupGateway = async () => {
    if (isDisposed) return;
    isDisposed = true;
    logger.info('dsh-mobile-bridge: 正在关闭网关服务...');
    if (muxReconnectTimer) { clearTimeout(muxReconnectTimer); muxReconnectTimer = null; }
    if (heartbeatInterval) clearInterval(heartbeatInterval);
    try { upstreamMuxWs?.removeAllListeners(); } catch (_) {}
    // Keep an error sink attached while closing: removing every listener first
    // turns the close-time "WebSocket was closed before the connection was
    // established" into an uncaught exception that can abort the host process.
    try { upstreamMuxWs?.on('error', () => {}); } catch (_) {}
    try { upstreamMuxWs?.close(); } catch (_) {}
    upstreamMuxWs = null;
    for (const ws of connectedClients) {
      try { ws.close(); } catch (_) {}
    }
    connectedClients.clear();
    try { wss.close(); } catch (_) {}
    try { server.closeAllConnections?.(); } catch (_) {}
    await new Promise((resolve) => {
      server.close(() => resolve());
      setTimeout(() => {
        try { server.closeAllConnections?.(); } catch (_) {}
        resolve();
      }, 1000).unref?.();
    });
    await disposeRpc();
    activePrompts.clear();
    sessionFollowers.clear();
    pendingApprovals.clear();
    audit('gateway/stop', {});
  };

  if (typeof ctx.on === 'function') {
    ctx.on('dispose', cleanupGateway);
  }
  ctx.effect(() => () => { cleanupGateway(); }, 'dsh-mobile-bridge: 关闭网关');

  return () => {
    cleanupGateway();
  };
}

export { name, inject };

