/**
 * dsh-mobile-bridge — shared core
 *
 * Single source of truth for every piece of bridge business logic that used to be
 * duplicated between the Cordis plugin entry (lib/index.js) and the standalone
 * gateway (index.js). Both entries are now thin adapters over this module, so they
 * can no longer drift apart (previously they diverged on: the /api/mobile/personas
 * endpoint, the 30s dead-socket sweep, the APK/pair routes, and — worst — the audit
 * sink, where logAudit() and audit() wrote to two different stores).
 *
 * Behavior baseline is lib/index.js (the variant Cordis actually loads today).
 * Modules whose behavior had drifted are unified onto that baseline; every such
 * change is annotated with [unified].
 *
 * All filesystem access goes through `dshHome`, resolved from DSH_HOME or the
 * OS home directory. The standalone gateway previously hardcoded
 * 'C:\\Users\\Administrator\\.dsh'.  [unified]
 */

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import http from 'node:http';
import url from 'node:url';
import { homedir } from 'node:os';

// core deliberately does NOT import ./store.mjs — store imports core (for the
// audit sink), so importing back would form a cycle. Everything core needs from
// persistence is injected by the entry point instead; see configurePersistence.

let _verifyToken = () => false;

/** Wire in the persistence helpers the entry point owns. */
export function configurePersistence({ verifyToken: vt }) {
  if (typeof vt === 'function') _verifyToken = vt;
}


export const BRIDGE_VERSION = '1.2.9';
export const MAX_BODY_SIZE = 2 * 1024 * 1024; // 2MB defensive payload limit (F4.1)
export const HEARTBEAT_INTERVAL_MS = 30000;

/* ------------------------------------------------------------------ *
 * DSH home / config
 * ------------------------------------------------------------------ */

export function dshHome() {
  return process.env.DSH_HOME || path.join(homedir(), '.dsh');
}

/**
 * Resolve the YAML parser without hard-failing when the host install is elsewhere.
 * [unified] Both entries duplicated this lookup, including a hardcoded fallback path.
 */
export async function loadYaml(requireFn) {
  try {
    return requireFn('yaml');
  } catch {
    try {
      return requireFn(path.join(dshHome(), 'profiles', 'web', 'node_modules', 'yaml'));
    } catch {
      return {
        parse: (str) => JSON.parse(str),
        parseDocument: () => ({ contents: { items: [] }, setIn() {}, toString: () => '' })
      };
    }
  }
}

/* ------------------------------------------------------------------ *
 * base64url + DSH signed cookie
 * ------------------------------------------------------------------ */

export function encodeBase64Url(value) {
  return Buffer.from(value).toString('base64').replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '');
}

export function decodeBase64Url(value) {
  const BASE64URL_PATTERN = /^[A-Za-z0-9_-]*$/;
  if (!BASE64URL_PATTERN.test(value) || value.length % 4 === 1) return void 0;
  const padding = '='.repeat((4 - (value.length % 4)) % 4);
  const decoded = Buffer.from(value.replaceAll('-', '+').replaceAll('_', '/') + padding, 'base64');
  return encodeBase64Url(decoded) === value ? decoded : void 0;
}

/**
 * Mint a DSH auth cookie so the bridge can talk to the engine's own HTTP/RPC
 * surface as if it were an authenticated web client.
 */
export function createCookieFactory({ dshPort, secret }) {
  const cache = { cookie: '', authority: `127.0.0.1:${dshPort}` };

  function generate() {
    const raw = decodeBase64Url(secret);
    const authority = cache.authority;
    const cookieName = 'dsh-auth-' + encodeBase64Url(crypto.createHash('sha256').update(authority).digest());
    const issuedAt = Date.now();
    const payload = { version: 1, authority, issuedAt, expiresAt: issuedAt + 86400 * 1000 };
    const body = encodeBase64Url(Buffer.from(JSON.stringify(payload), 'utf8'));
    const sig = crypto.createHmac('sha256', raw).update(body).digest();
    return `${cookieName}=v1.${body}.${encodeBase64Url(sig)}`;
  }

  return {
    authority: cache.authority,
    current() {
      if (!cache.cookie) cache.cookie = generate();
      return cache.cookie;
    },
    refresh() {
      cache.cookie = generate();
      return cache.cookie;
    }
  };
}

/* ------------------------------------------------------------------ *
 * unary DSH RPC
 * ------------------------------------------------------------------ */

/**
 * POST /api/<method> on the engine and unwrap { result: { ok, value } }.
 */
export function createRpcCaller({ dshPort, cookieFactory, timeoutMs = 10000 }) {
  return function callDshRpc(method, payload) {
    return new Promise((resolve, reject) => {
      const authority = `127.0.0.1:${dshPort}`;
      const cookie = cookieFactory.current();
      const rpcId = crypto.randomUUID();
      const postData = JSON.stringify({
        type: 'client-request',
        rpcId,
        method,
        payload: payload || { args: {} }
      });

      const req = http.request({
        host: '127.0.0.1',
        port: dshPort,
        path: `/api/${method}`,
        method: 'POST',
        headers: {
          Host: authority,
          Cookie: cookie,
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(postData)
        },
        timeout: timeoutMs
      }, (res) => {
        let data = '';
        res.on('data', (chunk) => { data += chunk; });
        res.on('end', () => {
          try {
            const parsed = JSON.parse(data);
            if (parsed.result && parsed.result.ok === true) {
              resolve(parsed.result.value);
            } else {
              const err = (parsed.result && parsed.result.error) || { message: 'RPC Error: ' + data };
              reject(new Error(err.message || JSON.stringify(err)));
            }
          } catch {
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
  };
}

/* ------------------------------------------------------------------ *
 * input coercion + workspace path sanitization
 * ------------------------------------------------------------------ */

export function coerceToolInput(input) {
  if (input == null) return '';
  if (typeof input === 'string') return input;
  if (typeof input === 'object') {
    try { return JSON.stringify(input, null, 2); } catch { return String(input); }
  }
  return String(input);
}

/**
 * Guard every workspace-memory read/write.
 *
 * Three layers, in order:
 *   1. reject '..', absolute paths and drive letters outright;
 *   2. require the workspace to be one the bridge actually knows about
 *      (defends against a caller naming an arbitrary host directory);
 *   3. confirm the resolved file still sits inside the workspace root.
 *
 * Returns { targetFile, relativePath } or { error, status }.
 */
export function createPathSanitizer({ getRegisteredWorkspaces }) {
  return function sanitizeWorkspaceFilePath(wsPath, fileName) {
    if (!wsPath || typeof wsPath !== 'string' || !wsPath.trim()) {
      return { error: 'Missing workspacePath', status: 400 };
    }
    if (!fileName || typeof fileName !== 'string' || !fileName.trim()) {
      return { error: 'Missing fileName', status: 400 };
    }
    const trimmedWs = wsPath.trim();
    const trimmedFile = fileName.trim();

    if (trimmedWs.includes('..')) {
      return { error: 'Forbidden: Path traversal detected in workspacePath', status: 403 };
    }
    if (trimmedFile.includes('..') || path.isAbsolute(trimmedFile) ||
        trimmedFile.startsWith('/') || trimmedFile.startsWith('\\') ||
        /^[a-zA-Z]:[\\/]/.test(trimmedFile)) {
      return { error: 'Forbidden: Path traversal detected in fileName', status: 403 };
    }

    const resolvedWs = path.resolve(trimmedWs);

    const registered = (getRegisteredWorkspaces() || []).filter(Boolean);
    const registeredPaths = [];
    for (const ws of registered) {
      const p = typeof ws === 'string' ? ws : (ws?.path || ws?.cwd || ws?.rootPath);
      if (p && typeof p === 'string' && p.trim()) registeredPaths.push(path.resolve(p.trim()));
    }

    if (registeredPaths.length > 0) {
      let within = false;
      for (const regPath of registeredPaths) {
        const rel = path.relative(regPath, resolvedWs);
        if (rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel))) {
          const regNorm = regPath.toLowerCase().replace(/[\\/]+$/, '');
          const wsNorm = resolvedWs.toLowerCase().replace(/[\\/]+$/, '');
          if (wsNorm === regNorm || wsNorm.startsWith(regNorm + '\\') || wsNorm.startsWith(regNorm + '/')) {
            within = true;
            break;
          }
        }
      }
      if (!within) {
        return { error: 'Forbidden: workspacePath is not a registered workspace', status: 403 };
      }
    }

    const resolvedTarget = path.resolve(resolvedWs, trimmedFile);
    const relative = path.relative(resolvedWs, resolvedTarget);
    const wsWithSep = resolvedWs.endsWith(path.sep) ? resolvedWs : resolvedWs + path.sep;
    if (relative.startsWith('..') || path.isAbsolute(relative) || !resolvedTarget.startsWith(wsWithSep)) {
      return { error: 'Forbidden: Resolved path escapes workspace boundaries', status: 403 };
    }
    return { targetFile: resolvedTarget, relativePath: relative };
  };
}

/* ------------------------------------------------------------------ *
 * read-only command classification
 * ------------------------------------------------------------------ */

const READ_ONLY_PREFIXES = [
  'ls', 'dir', 'cat', 'grep', 'find', 'head', 'tail', 'wc',
  'git status', 'git log', 'git diff',
  'pwd', 'echo', 'which', 'where'
];
const READ_ONLY_TOOLS = ['read_file', 'view_file', 'search_web', 'list_dir'];

/**
 * Prefix-whitelist check used by the 'auto-read' execution policy.
 *
 * Deliberately conservative, and stricter than a naive prefix match: an
 * allowlisted verb followed by a shell metacharacter (redirect, pipe, chain, or
 * command substitution) is NOT read-only, because `echo hi > out.txt` and
 * `cat x | sh` both perform writes or execute code despite starting with an
 * allowed verb.  [hardened]
 */
const SHELL_METACHARACTERS = /[;&|><`$(){}[\]!*?~\n\r]/;

export function isCommandReadOnly(cmdStr, toolName) {
  if (READ_ONLY_TOOLS.includes(toolName)) return true;
  if (!cmdStr) return false;
  const trimmed = String(cmdStr).trim().toLowerCase();
  if (!trimmed) return false;
  if (SHELL_METACHARACTERS.test(trimmed)) return false;
  return READ_ONLY_PREFIXES.some((p) => trimmed === p || trimmed.startsWith(p + ' '));
}

/* ------------------------------------------------------------------ *
 * audit
 * ------------------------------------------------------------------ */

const AUDIT_BUFFER_SIZE = 200;

/**
 * Single audit sink for both entries. [unified]
 * Previously the standalone gateway wrote to its own module-level array via
 * logAudit() while the plugin wrote to store.mjs's auditBuffer, so the same
 * event was readable through one entry and invisible through the other.
 */
export function createAuditSink({ auditBuffer = [], size = AUDIT_BUFFER_SIZE } = {}) {
  const sink = {
    record(action, payload = {}) {
      const norm = (typeof payload === 'object' && payload !== null) ? payload : { details: payload };
      const entry = {
        id: norm.id || norm.approvalId || norm.eventId ||
          `audit_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
        time: typeof norm.time === 'number' ? norm.time : Date.now(),
        action: norm.action || action,
        event: norm.event || action,
        sessionId: norm.sessionId || 'system',
        toolName: norm.toolName || action || 'system',
        command: norm.command || norm.reason || action || '',
        outcome: norm.outcome ||
          (String(action).includes('reject') ? 'rejected'
            : String(action).includes('allow') ? 'allowed-once'
              : 'auto-approved'),
        reason: norm.reason || norm.error ||
          (typeof norm === 'object' ? JSON.stringify(norm) : String(norm))
      };
      auditBuffer.unshift(entry);
      if (auditBuffer.length > size) auditBuffer.pop();
      return entry;
    },
    read(limit = 100) {
      const lim = typeof limit === 'number' && limit > 0 ? limit : 100;
      return auditBuffer.slice(0, lim);
    },
    get size() { return auditBuffer.length; }
  };
  return sink;
}

/* ------------------------------------------------------------------ *
 * personas
 * ------------------------------------------------------------------ */

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

export function createPersonaStore({ home = dshHome() } = {}) {
  const file = path.join(home, 'mobile-access', 'personas.json');
  return {
    file,
    defaults: DEFAULT_PERSONAS,
    get() {
      try {
        if (fs.existsSync(file)) {
          const data = JSON.parse(fs.readFileSync(file, 'utf8'));
          if (Array.isArray(data) && data.length > 0) return data;
        }
      } catch { /* fall through to defaults */ }
      return DEFAULT_PERSONAS;
    },
    save(list) {
      try {
        const dir = path.dirname(file);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(file, JSON.stringify(list, null, 2), 'utf8');
        return true;
      } catch {
        return false;
      }
    }
  };
}

/* ------------------------------------------------------------------ *
 * session id helpers
 * ------------------------------------------------------------------ */

/**
 * Canonical map key for a session id: strips the `session-` prefix only.
 * Case is deliberately preserved — this value is used as a Map key and is
 * re-expanded into `session-${key}` when talking to the engine, so lowercasing
 * here could fabricate an id the engine never issued.
 */
export function normalizeSessionKey(sId) {
  if (!sId) return '';
  return sId.startsWith('session-') ? sId.slice('session-'.length) : sId;
}

export function toFullSessionId(sId) {
  if (!sId) return '';
  return sId.startsWith('session-') ? sId : `session-${sId}`;
}

/**
 * Compare two session ids for identity.
 *
 * Matches the Dart client's SessionMeta.matchesSessionId semantics: strip the
 * `session-` prefix and compare case-insensitively.  [unified] The Dart side
 * has always lowercased; the gateway previously compared case-sensitively, so a
 * client sending `ABC` and the engine reporting `abc` would be treated as two
 * different sessions and stream state would be dropped.
 */
export function sessionIdMatches(a, b) {
  if (!a || !b) return false;
  return normalizeSessionKey(a).toLowerCase() === normalizeSessionKey(b).toLowerCase();
}

/**
 * Identify injected context/memory blocks so they can be folded into a
 * collapsed card instead of shown as ordinary user text.
 */
export function isCarriedContext(text, ev) {
  if (!text || typeof text !== 'string') return false;
  if (ev?.data?.source?.plugin === 'dsh-mnemon' || ev?.source?.plugin === 'dsh-mnemon') return true;
  const trimmed = text.trim();
  if (trimmed.startsWith('MNEMON RUNTIME MEMORY SNAPSHOT') || trimmed.startsWith('[MNEMON]')) return true;
  if (trimmed.includes('<runtime-memory-file') || trimmed.includes('</runtime-memory-file>')) return true;
  if (trimmed.includes('<system-reminder>')) return true;
  if (trimmed.startsWith('Current runtime context.') || trimmed.includes('DSH file policy:')) return true;
  if (trimmed.includes('Instructions from:') || trimmed.includes('Contents of ')) return true;
  if (trimmed.includes('<available_skills>') || trimmed.includes('A skill is a reusable set')) return true;
  if (/<(workspace|project|environment|file)_context>/i.test(trimmed)) return true;
  return false;
}

/* ------------------------------------------------------------------ *
 * turn-sequence bookkeeping (prompt/cancel race fencing)
 * ------------------------------------------------------------------ */

/**
 * Turn-sequence bookkeeping for prompt/cancel race fencing.
 *
 * All four collections can be injected so an entry point can keep ownership of
 * the live objects it already exposed (and so teardown can clear them).
 */
export function createTurnRegistry({
  sessionTurnSeqs = new Map(),
  cancelledTurnSeqs = new Map(),
  lastCancelTimes = new Map(),
  activePrompts = new Map()
} = {}) {
  const key = normalizeSessionKey;

  return {
    activePrompts,
    sessionTurnSeqs,
    cancelledTurnSeqs,
    lastCancelTimes,
    getTurnSeq: (sId) => sessionTurnSeqs.get(key(sId)) || 0,
    setTurnSeq(sId, seq) { sessionTurnSeqs.set(key(sId), seq); },
    getCancelledSeq: (sId) => cancelledTurnSeqs.get(key(sId)) || 0,
    setCancelledSeq(sId, seq) { cancelledTurnSeqs.set(key(sId), seq); },
    getLastCancelTime: (sId) => lastCancelTimes.get(key(sId)) || 0,
    setLastCancelTime(sId, t) { lastCancelTimes.set(key(sId), t); },
    /** Allocate the next turn number for a prompt. */
    nextTurnSeq(sId) {
      const seq = (sessionTurnSeqs.get(key(sId)) || 0) + 1;
      sessionTurnSeqs.set(key(sId), seq);
      return seq;
    },
    /** Consume a cancel: bump seq, mark cancelled, stamp time. */
    recordCancel(sId, now = Date.now()) {
      const seq = (sessionTurnSeqs.get(key(sId)) || 0) + 1;
      sessionTurnSeqs.set(key(sId), seq);
      cancelledTurnSeqs.set(key(sId), seq);
      lastCancelTimes.set(key(sId), now);
      return seq;
    },
    isAnyPromptActive(sId) {
      const k = key(sId);
      return activePrompts.has(sId) || activePrompts.has(k) || activePrompts.has(`session-${k}`);
    },
    clear() {
      sessionTurnSeqs.clear();
      cancelledTurnSeqs.clear();
      lastCancelTimes.clear();
      activePrompts.clear();
    }
  };
}

/* ------------------------------------------------------------------ *
 * session followers (live stream buffers per followed session)
 * ------------------------------------------------------------------ */

/**
 * Per-session live-stream buffers.
 *
 * `map` may be injected so an entry keeps ownership of the live follower
 * collection it already exposed (entries are aliased under both the bare and
 * `session-` prefixed keys).
 */
export function createFollowerRegistry({ map = new Map(), onSubscribe } = {}) {
  const followers = map;

  function normalize(sId) { return normalizeSessionKey(sId); }

  function ensure(sessionId) {
    const full = toFullSessionId(sessionId);
    const k = normalize(full);
    let f = followers.get(k) || followers.get(full);
    if (!f) {
      f = {
        sessionId: full,
        streamId: `follow-${full}`,
        isRunning: false,
        thinkingBuffer: '',
        textBuffer: '',
        tools: [],
        subscribed: false,
        lastUpdated: Date.now()
      };
      followers.set(k, f);
      followers.set(full, f);
    }
    return f;
  }

  return {
    map: followers,
    ensure,
    get(sessionId) {
      if (!sessionId) return null;
      const k = normalize(sessionId);
      return followers.get(k) || followers.get(sessionId) || followers.get(`session-${k}`) || null;
    },
    /** Unique follower objects (each is aliased under two keys). */
    all() { return [...new Set(followers.values())]; },
    /** Open an upstream session/follow stream if not already subscribed. */
    follow(sessionId, sendOpen) {
      const f = ensure(sessionId);
      if (f.subscribed) return f;
      const sender = sendOpen || onSubscribe;
      if (sender) {
        try {
          sender({
            type: 'open',
            streamId: f.streamId,
            endpoint: 'session/follow',
            payload: {
              args: {
                request: {
                  address: { kind: 'session', sessionId: f.sessionId },
                  assistantStream: true
                }
              }
            }
          });
          f.subscribed = true;
        } catch { /* upstream not ready; will retry on reconnect */ }
      }
      return f;
    },
    markAllUnsubscribed() {
      for (const f of new Set(followers.values())) f.subscribed = false;
    },
    clear() { followers.clear(); }
  };
}

/* ------------------------------------------------------------------ *
 * pending approvals queue
 * ------------------------------------------------------------------ */

/**
 * Pending approvals queue.
 *
 * `map` may be injected so an entry keeps ownership of the live collection it
 * already exposed. Entries are stored under BOTH id and eventId so either
 * lookup resolves; `list()` de-duplicates.
 */
export function createApprovalQueue({ map = new Map() } = {}) {
  let counter = 1;
  return {
    map,
    nextId() { return `appr_${Date.now()}_${counter++}`; },
    /** Stored under both id and eventId so either lookup resolves. */
    put(approval) {
      map.set(approval.id, approval);
      if (approval.eventId && approval.eventId !== approval.id) map.set(approval.eventId, approval);
      return approval;
    },
    get(eventId) {
      if (map.has(eventId)) return map.get(eventId);
      for (const v of map.values()) {
        if (v.id === eventId || v.eventId === eventId) return v;
      }
      return undefined;
    },
    remove(approval, eventId) {
      if (approval) {
        map.delete(approval.id);
        if (approval.eventId) map.delete(approval.eventId);
      }
      if (eventId) map.delete(eventId);
    },
    removeBySession(sessionId) {
      for (const [key, v] of map.entries()) {
        if (sessionIdMatches(v.sessionId, sessionId)) map.delete(key);
      }
    },
    /** Deduplicated list (id and eventId both point at the same object). */
    list() { return [...new Set(map.values())]; },
    clear() { map.clear(); }
  };
}

/* ------------------------------------------------------------------ *
 * permissions
 * ------------------------------------------------------------------ */

let _loadPermissions = () => ({});
let _savePermissions = () => ({});
let _permissionsFile = () => '';

/**
 * Persistence handles for the permission store. Injected by the entry point so
 * core stays free of the store.mjs import (store imports core for the audit sink).
 */
export function configurePermissionsPersistence({ load, save, file }) {
  if (typeof load === 'function') _loadPermissions = load;
  if (typeof save === 'function') _savePermissions = save;
  if (typeof file === 'function') _permissionsFile = file;
}

export function createPermissionStore() {
  const initial = _loadPermissions();
  const global = {
    executionPolicy: initial.defaultPolicy || initial.executionPolicy || 'auto-read',
    maxSteps: initial.maxSteps ?? 30,
    sandboxMode: initial.sandboxMode || 'workspace-write',
    protectGit: initial.protectGit !== false
  };
  const sessions = new Map(Object.entries(initial.sessionPolicies || {}));

  function payload() {
    const sessionPolicies = {};
    for (const [k, v] of sessions) sessionPolicies[k] = v;
    return {
      defaultPolicy: global.executionPolicy,
      executionPolicy: global.executionPolicy,
      sandboxMode: global.sandboxMode,
      maxSteps: global.maxSteps,
      protectGit: global.protectGit !== false,
      sessionPolicies
    };
  }

  return {
    global,
    sessions,
    get globalPolicy() { return global.executionPolicy; },
    forSession(sessionId) {
      if (!sessionId) return global.executionPolicy;
      return sessions.get(sessionId) || global.executionPolicy;
    },
    apply(patch = {}) {
      const pol = patch.defaultPolicy || patch.executionPolicy;
      if (pol) global.executionPolicy = pol;
      if (patch.sandboxMode) global.sandboxMode = patch.sandboxMode;
      if (patch.maxSteps) global.maxSteps = Number(patch.maxSteps);
      if (typeof patch.protectGit === 'boolean') global.protectGit = patch.protectGit;
      if (patch.sessionPolicies && typeof patch.sessionPolicies === 'object') {
        for (const [sId, sPol] of Object.entries(patch.sessionPolicies)) {
          if (typeof sPol === 'string') sessions.set(sId, sPol);
        }
      }
      return payload();
    },
    setSession(sessionId, policy) {
      if (!sessionId) return payload();
      sessions.set(sessionId, policy);
      return payload();
    },
    payload,
    persist() {
      const p = payload();
      _savePermissions(p);
      return p;
    },
    permissionsFile: _permissionsFile
  };
}

/* ------------------------------------------------------------------ *
 * auth
 * ------------------------------------------------------------------ */

export function extractToken(req, parsed) {
  const authHeader = req.headers['authorization'];
  if (authHeader && authHeader.startsWith('Bearer ')) return authHeader.slice(7).trim();
  if (req.headers['x-dsh-token']) return String(req.headers['x-dsh-token']).trim();
  if (req.headers['x-auth-code']) return String(req.headers['x-auth-code']).trim();
  if (parsed?.query?.token) return String(parsed.query.token).trim();
  return '';
}

export function authenticateRequest(req, parsed) {
  const token = extractToken(req, parsed);
  if (!token) {
    return { ok: false, code: 401, error: '缺少认证授权码 (Authorization Token Required)' };
  }
  if (_verifyToken(token)) {
    return { ok: true, device: { id: 'admin', name: '移动终端', role: 'readwrite' } };
  }
  return { ok: false, code: 401, error: '授权码错误，请在 DSH 设置中查看正确授权码' };
}

/* ------------------------------------------------------------------ *
 * body reading with 2MB cap
 * ------------------------------------------------------------------ */

/**
 * Buffer a request body, rejecting anything over MAX_BODY_SIZE.
 *
 * On overflow we answer 413 and destroy the socket only after the response has
 * flushed (res.on('finish') + short delay). Destroying immediately caused
 * clients to observe ECONNRESET instead of the 413 they were meant to get.
 */
export function readBodyWithLimit(req, res, { limit = MAX_BODY_SIZE, sendJson }) {
  return new Promise((resolve, reject) => {
    let raw = '';
    let bytes = 0;
    let aborted = false;

    const overflow = () => {
      aborted = true;
      sendJson(413, { error: `Payload Too Large: Request body exceeds ${Math.floor(limit / 1024 / 1024)}MB limit` });
      req.on('data', () => {});
      req.resume();
      res.on('finish', () => {
        setTimeout(() => { try { req.destroy(); } catch { /* already gone */ } }, 50);
      });
      reject(Object.assign(new Error('PAYLOAD_TOO_LARGE'), { aborted: true }));
    };

    const declared = parseInt(req.headers['content-length'], 10);
    if (!isNaN(declared) && declared > limit) {
      overflow();
      return;
    }

    req.on('data', (chunk) => {
      if (aborted) return;
      bytes += chunk.length;
      if (bytes > limit) return overflow();
      raw += chunk;
    });
    req.on('end', () => { if (!aborted) resolve(raw); });
    req.on('error', (err) => { if (!aborted) reject(err); });
  });
}

export function parseJsonBody(raw) {
  try { return JSON.parse(raw || '{}'); } catch { return {}; }
}

/* ------------------------------------------------------------------ *
 * session removal
 * ------------------------------------------------------------------ */

/**
 * Delete a session.
 *
 * The DSH engine exposes NO session/delete RPC — verified: session/delete,
 * session/remove, session/destroy, session/archive and variants all return 404.
 * The previous bridge code called it anyway, swallowed the 404 with
 * `catch (_) {}`, and answered HTTP 200 "Deleted", so the client's delete button
 * silently did nothing and the E2E suite accumulated >1000 empty sessions.
 *
 * The only mutation the engine accepts and persists is `global.archivedSessionIds`
 * (its own UI uses exactly that). So we: detach the id from its workspace, append
 * it to the archive set, and drop the projection cache file.
 *
 * Returns { ok, archived, detached, cacheRemoved, error } — callers must surface
 * failures instead of claiming success.
 */
export function deleteSession({ home = dshHome(), sessionId, workspaceId = null }) {
  if (!sessionId || typeof sessionId !== 'string' || !sessionId.trim()) {
    return { ok: false, error: 'Missing or empty sessionId' };
  }
  const id = sessionId.trim();
  const clean = id.replace(/^session-/, '');

  const wsPath = path.join(home, 'storages', 'workspace.json');
  const cacheDir = path.join(home, 'storages', 'session_projcache', 'sessions');

  let ws;
  try {
    ws = JSON.parse(fs.readFileSync(wsPath, 'utf8'));
  } catch (err) {
    return { ok: false, error: `Cannot read workspace store: ${err?.message}` };
  }

  // 1. Archive — the one change the engine round-trips instead of overwriting.
  if (!ws.global) ws.global = {};
  const archived = Array.isArray(ws.global.archivedSessionIds) ? ws.global.archivedSessionIds : [];
  if (!archived.includes(id)) archived.push(id);
  ws.global.archivedSessionIds = archived;

  // 2. Detach from the workspace id list (also honouring the session- prefix variants).
  let detached = 0;
  const table = ws?.tables?.workspaces;
  if (table) {
    for (const [wsKey, info] of Object.entries(table)) {
      if (!Array.isArray(info.sessionIds)) continue;
      if (workspaceId && wsKey !== workspaceId && info.workspaceId !== workspaceId) continue;
      const before = info.sessionIds.length;
      info.sessionIds = info.sessionIds.filter((s) => s !== id && s !== clean && s !== `session-${clean}`);
      detached += before - info.sessionIds.length;
    }
  }

  // 3. Persist atomically.
  try {
    const tmp = `${wsPath}.bridge-delete.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(ws, null, 2), 'utf8');
    fs.renameSync(tmp, wsPath);
  } catch (err) {
    return { ok: false, error: `Cannot write workspace store: ${err?.message}`, archived: true };
  }

  // 4. Drop the projection cache.
  let cacheRemoved = false;
  for (const name of [`${clean}.json`, `${id}.json`, `session-${clean}.json`]) {
    const p = path.join(cacheDir, name);
    try {
      if (fs.existsSync(p)) { fs.unlinkSync(p); cacheRemoved = true; }
    } catch { /* the archive entry already hides it */ }
  }

  return { ok: true, sessionId: id, archived: true, detached, cacheRemoved };
}

export { fs, path, url };
