/**
 * Session visibility parity with the dsh web sidebar (§ 会话列表与 Web 不一致).
 *
 * The web sidebar decides visibility in
 *   node_modules/@deepseek-ai/dsh-client-ui-workspace/lib/client.js:357-366
 *
 *     function sessionVisible(session, current, archived, archivedFilter) {
 *       if (session.origin === "subagent") return false;   // ← 无条件隐藏
 *       if (session.blank && session.id !== current) return false;
 *       switch (archivedFilter) { default/only/show ... }
 *     }
 *
 * The gateway only ever implemented the archived half, so the phone listed every
 * subagent session the web sidebar hides. Measured on the live box: 2324
 * registered sessions, 321 of them subagent (one-shot 317 / continuable 4), and
 * 0 of those 321 archived — which is exactly why the 「未归档」 counts disagreed
 * while the 「已归档」 counts matched.
 *
 * The authoritative `origin` field lives in the engine's session header, which
 * this gateway cannot read: it builds the list from workspace.json plus
 * session_projcache. The predicate used instead is the projcache's
 * `subagent.identity`, which was validated against
 * `subagentCatalog.inheritedEventCount > 0` and agreed on 309 of 310 rows.
 *
 * Boots the real Cordis entry against a throwaway DSH_HOME. Every fixture here is
 * synthetic; the live ~/.dsh is never touched.
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-visibility-home-'));
process.env.DSH_HOME = TMP_HOME;

const { apply } = await import('../../dsh-server-plugin/lib/index.js');
const { loadConfig } = await import('../../dsh-server-plugin/lib/store.mjs');
const TOKEN = loadConfig().token;

async function pickFreePort() {
  const srv = http.createServer();
  await new Promise((res, rej) => { srv.once('error', rej); srv.listen(0, '127.0.0.1', res); });
  const { port } = srv.address();
  await new Promise((res) => srv.close(res));
  return port;
}

const PORT = await pickFreePort();
const BASE = `http://127.0.0.1:${PORT}`;

let teardown = null;

function req(pathname) {
  return new Promise((resolve, reject) => {
    const r = http.request(`${BASE}${pathname}`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${TOKEN}` }
    }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(data); } catch { /* non-JSON */ }
        resolve({ status: res.statusCode, data: parsed });
      });
    });
    r.on('error', reject);
    r.end();
  });
}

// --------------------------------------------------------------- fixtures --

const WS_JSON = path.join(TMP_HOME, 'storages', 'workspace.json');
const CACHE_DIR = path.join(TMP_HOME, 'storages', 'session_projcache', 'sessions');

/**
 * @param {object} [opts]
 * @param {boolean} [opts.subagent]     write rows.subagent.val.identity (this
 *                                      session IS a subagent run)
 * @param {number}  [opts.inherited]    write subagentCatalog.inheritedEventCount
 *                                      only — the fork case, which must remain
 *                                      visible
 */
function writeCache(sessionId, {
  title = null, firstPrompt = null, blank = false, model = null,
  lastPromptAt = 1700000000000, subagent = false, inherited = 0
} = {}) {
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  const rows = {};
  if (title != null) rows.title = { val: title };
  if (firstPrompt != null) rows.titleInput = { val: { first: { text: firstPrompt } } };
  rows.sessionListMetadata = { val: { blank, lastPromptAt } };
  if (model != null) rows.modelSelection = { val: { lastUsed: { model } } };
  // Present on every real cache file (with 0 for ordinary sessions), so it is
  // written unconditionally to keep the fixture honest.
  rows.subagentCatalog = { val: { inheritedEventCount: inherited } };
  if (subagent) {
    rows.subagent = { val: { identity: { mode: 'one-shot', label: 'fixture subagent', seq: 1 } } };
  }
  fs.writeFileSync(
    path.join(CACHE_DIR, `${sessionId}.json`),
    JSON.stringify({ record: { identity: { createdAt: lastPromptAt }, rows } }),
    'utf8'
  );
}

/**
 * ws-a, six registered sessions:
 *
 *   live-1, live-2   ordinary, unarchived        → visible
 *   arch-1           ordinary, archived          → visible only in 'only'
 *   fork-1           inherited>0, NOT a subagent → visible (guard: no over-filter)
 *   sub-1            subagent, unarchived        → hidden in every mode
 *   sub-arch         subagent AND archived       → hidden in every mode
 */
function fixture() {
  fs.mkdirSync(path.dirname(WS_JSON), { recursive: true });
  fs.writeFileSync(WS_JSON, JSON.stringify({
    global: { initialized: true, archivedSessionIds: ['arch-1', 'sub-arch'] },
    tables: {
      workspaces: {
        'ws-a': {
          title: '工作区A',
          path: 'E:\\ws\\a',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-02T00:00:00Z',
          sessionIds: ['live-1', 'live-2', 'arch-1', 'fork-1', 'sub-1', 'sub-arch']
        }
      }
    }
  }), 'utf8');

  writeCache('live-1', { title: '未归档一', firstPrompt: 'p1', model: 'cn:m1' });
  writeCache('live-2', { title: '未归档二', firstPrompt: 'p2', model: 'cn:m2' });
  writeCache('arch-1', { title: '已归档一', model: 'cn:m3' });
  // A fork inherits the parent's events but is an independent conversation, and
  // the web sidebar shows it. Filtering on inheritedEventCount alone would hide
  // it — this row is the guard against that over-filter.
  writeCache('fork-1', { title: '派生会话', firstPrompt: 'p4', model: 'cn:m4', inherited: 900 });
  writeCache('sub-1', { title: '子任务·未归档', firstPrompt: 'p5', model: 'cn:m5', subagent: true, inherited: 12 });
  writeCache('sub-arch', { title: '子任务·已归档', model: 'cn:m6', subagent: true, inherited: 34 });
}

function wsA(data) {
  const ws = (data?.workspaces || []).find((w) => w.workspaceId === 'ws-a');
  assert.ok(ws, 'ws-a must be present in the response');
  return ws;
}

const idsOf = (ws) => ws.sessions.map((s) => s.sessionId).sort();

before(async () => {
  fixture();

  const effectFns = [];
  const mockCtx = {
    logger: () => ({ info() {}, warn() {}, error() {}, log() {} }),
    webServer: { port: 3080 },
    connection: { rpc: { handle: () => async () => {} } },
    effect: (fn) => { effectFns.push(fn); return () => {}; },
    on: (evt, fn) => { if (evt === 'dispose') effectFns.push(fn); }
  };
  const disposer = apply(mockCtx, { port: PORT }, { port: PORT, dshPort: 3080, isListening: true });
  teardown = async () => {
    try { await disposer?.(); } catch { /* ignore */ }
    for (const fn of effectFns) {
      try { await fn(); } catch { /* ignore */ }
    }
  };

  for (let i = 0; i < 50; i++) {
    try { await req('/api/mobile/health'); return; } catch { await new Promise((r) => setTimeout(r, 100)); }
  }
  throw new Error('bridge did not start');
});

after(async () => {
  try { await teardown?.(); } catch { /* ignore */ }
  await new Promise((r) => setTimeout(r, 300));
  try { fs.rmSync(TMP_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
});

// ------------------------------------------------------------------ tests --

describe('subagent sessions are hidden in every mode (web sessionVisible parity)', () => {
  it('exclude mode drops subagents but keeps the fork', async () => {
    const { status, data } = await req('/api/mobile/workspaces');
    assert.equal(status, 200);
    assert.deepEqual(idsOf(wsA(data)), ['fork-1', 'live-1', 'live-2']);
  });

  it('only mode drops an ARCHIVED subagent — the exact case web hides too', async () => {
    // sub-arch is in archivedSessionIds, so without the origin rule it would be
    // the single row of this response.
    const { data } = await req('/api/mobile/workspaces?archived=only');
    assert.deepEqual(idsOf(wsA(data)), ['arch-1']);
  });

  it('include mode drops subagents but returns both archived and unarchived', async () => {
    const { data } = await req('/api/mobile/workspaces?archived=include');
    assert.deepEqual(idsOf(wsA(data)), ['arch-1', 'fork-1', 'live-1', 'live-2']);
  });

  it('sessionCount equals the number of returned rows in every mode', async () => {
    for (const [q, expected] of [['', 3], ['?archived=only', 1], ['?archived=include', 4]]) {
      const { data } = await req(`/api/mobile/workspaces${q}`);
      const ws = wsA(data);
      assert.equal(ws.sessionCount, ws.sessions.length, `mode ${q || 'exclude'}`);
      assert.equal(ws.sessionCount, expected, `mode ${q || 'exclude'}`);
    }
  });

  it('archivedCount stays mode-independent and counts an archived subagent', async () => {
    // The badge answers "how many archived sessions does this workspace have" and
    // its documented contract is to be independent of the requested mode. sub-arch
    // is archived, so it is counted even though it is never listed.
    //
    // That is a deliberate trade-off, not an oversight: reclaiming it would mean
    // decrementing only on the paths that reach the subagent check, and in exclude
    // mode an archived session is skipped by the mode filter before that point —
    // so the same badge would report two different numbers across the three modes.
    //
    // It cannot happen on the live box: measured 0 archived sessions out of 321
    // subagents. Reclaiming it would also require reading the projcache of every
    // archived session on the default (exclude) path, which is exactly the N+1
    // this endpoint was already fixed to avoid.
    for (const q of ['', '?archived=only', '?archived=include']) {
      const { data } = await req(`/api/mobile/workspaces${q}`);
      assert.equal(wsA(data).archivedCount, 2, `mode ${q || 'exclude'}`);
    }
  });

  it('a fork with inherited events is NOT treated as a subagent', async () => {
    // Guards the over-filter: inheritedEventCount>0 also appears on ordinary
    // forks, which the web sidebar shows. Only subagent.identity may hide a row.
    const { data } = await req('/api/mobile/workspaces?archived=include');
    assert.ok(idsOf(wsA(data)).includes('fork-1'));
  });
});
