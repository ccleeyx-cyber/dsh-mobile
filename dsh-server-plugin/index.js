/**
 * DSH Mobile Bridge — standalone gateway entry.
 *
 * Historically this file was a second, hand-maintained copy of the whole bridge
 * (≈1900 lines) alongside the Cordis plugin entry in lib/index.js. The two copies
 * drifted until they disagreed on real behaviour:
 *
 *   • the standalone copy never filtered `archivedSessionIds` or blank sessions,
 *     so it listed sessions the engine and the Web UI both consider hidden;
 *   • it wrote audit records to its own array, invisible through /api/mobile/audit-logs;
 *   • it was missing the 30s dead-socket sweep and the pairing/APK routes;
 *   • the plugin copy was missing /api/mobile/personas, which the mobile client
 *     calls unconditionally on connect and therefore always received a 404.
 *
 * All shared logic now lives in lib/core.mjs and the plugin entry in lib/index.js.
 * This file is a thin adapter: it starts the same server with the same routes,
 * just without the Cordis lifecycle. The previous implementation is kept beside
 * it as index.js.legacy for reference.
 *
 * Usage:  node index.js
 *         BRIDGE_PORT=3088 DSH_PORT=3080 DSH_AUTH_TOKEN=... node index.js
 */

import { apply } from './lib/index.js';

const port = Number(process.env.BRIDGE_PORT) || 3088;
const dshPort = Number(process.env.DSH_PORT) || 3080;
const host = process.env.BRIDGE_HOST || '0.0.0.0';

const disposers = [];
let shuttingDown = false;

function shutdown(code = 0) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log('[dsh-mobile-bridge] 正在关闭...');
  for (const fn of disposers) {
    try { fn(); } catch { /* best effort */ }
  }
  setTimeout(() => process.exit(code), 200);
}

process.on('SIGINT', () => shutdown(0));
process.on('SIGTERM', () => shutdown(0));

// Minimal stand-in for the Cordis context: the bridge only needs a logger, the
// webServer port, an RPC hook, and a lifecycle registrar.
const ctx = {
  logger: () => ({
    info: (...a) => console.log('[dsh-mobile-bridge]', ...a),
    warn: (...a) => console.warn('[dsh-mobile-bridge]', ...a),
    error: (...a) => console.error('[dsh-mobile-bridge]', ...a),
    log: (...a) => console.log('[dsh-mobile-bridge]', ...a)
  }),
  webServer: { port: dshPort },
  connection: { rpc: { handle: () => async () => {} } },
  effect: (fn) => { disposers.push(fn); return () => {}; },
  on: (event, fn) => { if (event === 'dispose') disposers.push(fn); }
};

console.log(`[dsh-mobile-bridge] 独立网关启动中 http://${host}:${port} → 127.0.0.1:${dshPort}`);

const dispose = apply(ctx, { port, host }, { port, dshPort, isListening: true });
if (typeof dispose === 'function') disposers.push(dispose);
