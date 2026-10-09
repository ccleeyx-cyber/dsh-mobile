/**
 * E2E Test Client Utilities (REST + WebSocket)
 */

import { CONFIG } from './fixtures.js';
import { trackCreatedSession } from './session-cleanup.js';

/**
 * Make an HTTP request to the bridge server
 *
 * Side effect: any successful `sessions/create` is registered with the session
 * cleaner so a run never leaves empty sessions behind in the user's real
 * workspace. (The bridge's delete endpoint is a silent no-op — the DSH engine
 * exposes no session/delete RPC and the bridge swallows the 404.)
 */
export async function apiRequest(endpoint, {
  method = 'GET',
  token = CONFIG.VALID_TOKEN,
  body = null,
  headers = {},
  rawBody = null,
  timeout = CONFIG.TIMEOUT_MS
} = {}) {
  const url = endpoint.startsWith('http') ? endpoint : `${CONFIG.BASE_URL}${endpoint}`;
  
  const reqHeaders = { ...headers };
  if (token !== null && token !== undefined) {
    if (!reqHeaders['Authorization'] && !reqHeaders['authorization'] && !reqHeaders['x-dsh-token']) {
      reqHeaders['Authorization'] = `Bearer ${token}`;
    }
  }

  let reqBody = rawBody;
  if (body !== null && body !== undefined && reqBody === null) {
    if (typeof body === 'object') {
      reqHeaders['Content-Type'] = reqHeaders['Content-Type'] || 'application/json';
      reqBody = JSON.stringify(body);
    } else {
      reqBody = String(body);
    }
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);

  try {
    const res = await fetch(url, {
      method,
      headers: reqHeaders,
      body: reqBody,
      signal: controller.signal
    });

    clearTimeout(timer);

    const rawText = await res.text();
    let data = null;
    try {
      data = JSON.parse(rawText);
    } catch {
      data = rawText;
    }

    // Register created sessions so they can be removed after the run.
    if (res.status === 200 && data && typeof data === 'object') {
      if (endpoint.includes('/sessions/create')) {
        const sid = data.sessionId ?? data.session?.sessionId;
        if (sid) await trackCreatedSession(String(sid), body?.workspaceId ?? null);
      } else if (endpoint.includes('/sessions/prompt')) {
        // A prompt creates the session implicitly when the caller did not supply
        // an id. Trust the RESPONSE id, not the request id: an id the caller
        // supplied almost certainly names a session that already existed, and
        // archiving it would hide the user's real work.
        //
        // This used to be `!sid.startsWith('session-')` on the REQUEST body, a
        // heuristic that is exactly backwards: real engine ids are
        // `session-<uuid>` — 1896 of 2321 (82%) in the live workspace.json — so
        // the filter discarded the very ids the tracker existed to catch and the
        // sessions piled up.
        const newSid = data.sessionId ?? data.session?.sessionId;
        const suppliedSid = typeof body?.sessionId === 'string' ? body.sessionId : null;
        const sid = newSid && String(newSid) !== suppliedSid ? String(newSid) : null;
        if (sid && sid !== 'default') {
          await trackCreatedSession(sid, body?.workspaceId ?? null);
        }
      }
    }

    return {
      status: res.status,
      ok: res.ok,
      headers: res.headers,
      data,
      rawText
    };
  } catch (err) {
    clearTimeout(timer);
    throw err;
  }
}

/**
 * Create a WebSocket client connected to the bridge
 */
export async function createWsClient({
  token = CONFIG.VALID_TOKEN,
  customUrl = null,
  autoConnect = true,
  timeout = 5000
} = {}) {
  let wsUrl = customUrl;
  if (!wsUrl) {
    const query = token !== null && token !== undefined ? `?token=${encodeURIComponent(token)}` : '';
    wsUrl = `${CONFIG.WS_URL}${query}`;
  }

  const messages = [];
  const errors = [];
  let isClosed = false;
  let closeEvent = null;

  const ws = new WebSocket(wsUrl);

  const messageResolvers = [];

  ws.onmessage = (event) => {
    let parsed = event.data;
    try {
      parsed = JSON.parse(event.data);
    } catch {
      // Keep as string
    }
    messages.push(parsed);

    // Check waiting resolvers
    for (let i = messageResolvers.length - 1; i >= 0; i--) {
      const { predicate, resolve } = messageResolvers[i];
      if (predicate(parsed)) {
        messageResolvers.splice(i, 1);
        resolve(parsed);
      }
    }
  };

  ws.onerror = (err) => {
    errors.push(err);
  };

  const closeResolvers = [];
  ws.onclose = (event) => {
    isClosed = true;
    closeEvent = event;
    for (const res of closeResolvers) res(event);
  };

  const client = {
    ws,
    messages,
    errors,
    get isClosed() { return isClosed; },
    get closeEvent() { return closeEvent; },

    async waitForOpen(waitTimeout = timeout) {
      if (ws.readyState === WebSocket.OPEN) return;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`WebSocket open timeout (${waitTimeout}ms)`)), waitTimeout);
        ws.onopen = () => {
          clearTimeout(timer);
          resolve();
        };
        ws.onerror = (err) => {
          clearTimeout(timer);
          reject(new Error(err?.message || 'WebSocket connection error (connection rejected or failed)'));
        };
      });
    },

    send(data) {
      const payload = typeof data === 'object' ? JSON.stringify(data) : String(data);
      ws.send(payload);
    },

    async waitForMessage(predicate, waitTimeout = timeout) {
      // First check already received messages
      for (const msg of messages) {
        if (predicate(msg)) return msg;
      }

      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          const idx = messageResolvers.findIndex(r => r.resolve === resolve);
          if (idx !== -1) messageResolvers.splice(idx, 1);
          reject(new Error(`Timed out waiting for message (${waitTimeout}ms). Received: ${JSON.stringify(messages)}`));
        }, waitTimeout);

        messageResolvers.push({
          predicate,
          resolve: (val) => {
            clearTimeout(timer);
            resolve(val);
          }
        });
      });
    },

    async close(waitTimeout = 3000) {
      if (isClosed || ws.readyState === WebSocket.CLOSED) return closeEvent;
      return new Promise((resolve) => {
        const timer = setTimeout(() => resolve(closeEvent), waitTimeout);
        closeResolvers.push((ev) => {
          clearTimeout(timer);
          resolve(ev);
        });
        try {
          ws.close();
        } catch (_) {
          clearTimeout(timer);
          resolve(closeEvent);
        }
      });
    }
  };

  if (autoConnect) {
    await client.waitForOpen();
  }

  return client;
}
