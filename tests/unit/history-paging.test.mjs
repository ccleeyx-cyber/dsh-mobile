/**
 * History reverse-paging tests ([feat 2026-10-12] 会话历史无限上翻).
 *
 * Two layers:
 *   1. Pure logic — `convertSessionRecordsToMessages` (the shared record→message
 *      conversion, extracted from getSessionHistory so both callers use one
 *      implementation) and `readHistoryPage` (one reverse page via the
 *      cursor-probe + throughSeq contract documented in features.mjs).
 *   2. Route level — the real bridge booted against a throwaway DSH_HOME
 *      (mkdtempSync isolation, same pattern as core/session-visibility tests)
 *      with NO live engine: /api/mobile/sessions/history/page must answer
 *      200 { hasMore:false } instead of a 500 when every engine RPC fails.
 *
 * Every fixture is synthetic; the live ~/.dsh is never touched.
 */

import { describe, it, before, after, test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';

import {
  convertSessionRecordsToMessages,
  readHistoryPage,
  FEATURE_ROUTES,
  claimsMobileFeatureRoute
} from '../../dsh-server-plugin/lib/features.mjs';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-history-paging-'));
process.env.DSH_HOME = TMP_HOME;

after(() => {
  try { fs.rmSync(TMP_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
});

/* ------------------------------------------------------------------ *
 * 1. convertSessionRecordsToMessages
 * ------------------------------------------------------------------ */

describe('convertSessionRecordsToMessages', () => {
  it('converts user/assistant/tool events into getSessionHistory-shaped messages with seq', () => {
    const records = [
      { event: { type: 'user/message', seq: 10, time: 1000, data: { content: [{ type: 'text', text: '帮我看看' }] } } },
      { event: { type: 'assistant/message', seq: 12, time: 2000, data: { message: { content: [{ type: 'reasoning', text: '思考A' }, { type: 'text', text: '回答A' }] } } } },
      { event: { type: 'tool/call', seq: 13, time: 2500, data: { name: 'read_file', arguments: { path: 'a.txt' }, callId: 'c1' } } },
      { event: { type: 'assistant/message', seq: 14, time: 3000, data: { message: { content: [{ type: 'text', text: '续' }] } } } },
      { event: { type: 'turn/end', seq: 15, time: 3100, data: { reason: 'complete', turn: 3 } } }
    ];
    const { messages } = convertSessionRecordsToMessages(records);
    assert.equal(messages.length, 2);
    assert.equal(messages[0].role, 'user');
    assert.equal(messages[0].content, '帮我看看');
    assert.equal(messages[0].seq, 10);
    assert.equal(messages[1].role, 'assistant');
    assert.equal(messages[1].content, '回答A\n续', 'consecutive assistant segments merge into one message');
    assert.equal(messages[1].thinking, '思考A');
    assert.equal(messages[1].seq, 12, 'the merged assistant message anchors at its FIRST event seq');
    assert.equal(messages[1].tools.length, 1);
    assert.equal(messages[1].tools[0].name, 'read_file');
  });

  it('filters carried context exactly like the live tail', () => {
    const records = [
      { event: { type: 'user/message', seq: 1, data: { content: 'MNEMON RUNTIME MEMORY SNAPSHOT xyz' } } },
      { event: { type: 'user/message', seq: 2, data: { content: '<system_information>fake</system_information>' } } },
      { event: { type: 'user/message', seq: 3, data: { content: '真正的提问' } } }
    ];
    const { messages } = convertSessionRecordsToMessages(records);
    assert.equal(messages.length, 1);
    assert.equal(messages[0].content, '真正的提问');
  });

  it('degrades on garbage input without throwing', () => {
    assert.deepEqual(convertSessionRecordsToMessages(null).messages, []);
    assert.deepEqual(convertSessionRecordsToMessages('nope').messages, []);
    assert.deepEqual(convertSessionRecordsToMessages([{ event: null }, {}]).messages, []);
  });
});

/* ------------------------------------------------------------------ *
 * 2. readHistoryPage
 * ------------------------------------------------------------------ */

/** Fake engine: records 0..N, rejecting the probe past the cursor like the real one. */
function makeFakeEngine(events) {
  const cursor = events.length ? events[events.length - 1].seq : 0;
  const calls = [];
  const callDshRpc = async (method, payload) => {
    assert.equal(method, 'session/page');
    const request = payload.args.request;
    calls.push(request);
    if (request.throughSeq === Number.MAX_SAFE_INTEGER) {
      const err = new Error(`typert gateway: session/page: gateway/bad-request: session page through seq ${request.throughSeq} is past cursor ${cursor}`);
      throw err;
    }
    const upper = request.throughSeq;
    const lower = request.beforeSeq ?? -Infinity;
    const records = events
      .filter((e) => e.seq <= upper && e.seq > lower)
      .slice(-request.maxMessages)
      .map((event) => ({ event }));
    const moreBelow = events.some((e) => e.seq <= upper && e.seq > lower && e.seq <= upper - request.maxMessages);
    return { records, hasMore: records.length > 0 && moreBelow };
  };
  return { callDshRpc, calls, cursor };
}

describe('readHistoryPage', () => {
  it('walks one reverse page with the required throughSeq wire field', async () => {
    const events = [];
    for (let i = 1; i <= 30; i++) {
      events.push({ type: 'user/message', seq: i, data: { content: `msg-${i}` } });
    }
    const engine = makeFakeEngine(events);
    const page = await readHistoryPage({ callDshRpc: engine.callDshRpc, sessionId: 'session-x', beforeSeq: 30, max: 10 });
    // The probe must have carried the required throughSeq.
    assert.equal(engine.calls[0].throughSeq, Number.MAX_SAFE_INTEGER);
    assert.equal(page.messages.length, 10, 'one bounded page');
    assert.equal(page.messages[0].seq, 21, 'the 10 events just below the anchor');
    assert.equal(page.oldestSeq, 21);
    assert.equal(page.hasMore, true);
  });

  it('reports hasMore:false at the beginning of the session', async () => {
    const events = [1, 2, 3].map((i) => ({ type: 'user/message', seq: i, data: { content: `m${i}` } }));
    const engine = makeFakeEngine(events);
    const page = await readHistoryPage({ callDshRpc: engine.callDshRpc, sessionId: 'session-x', beforeSeq: 3, max: 60 });
    assert.equal(page.messages.length, 3);
    assert.equal(page.hasMore, false);
    assert.equal(page.oldestSeq, 1);
  });

  it('degrades to empty + hasMore:false when the engine RPC fails (never throws)', async () => {
    const callDshRpc = async () => { throw new Error('mux down'); };
    const page = await readHistoryPage({ callDshRpc, sessionId: 'session-x', beforeSeq: 100 });
    assert.deepEqual(page, { messages: [], hasMore: false, oldestSeq: null });
  });

  it('answers empty for a bad/unparseable engine rejection (not a past-cursor error)', async () => {
    const callDshRpc = async () => { throw new Error('gateway/input-invalid: whatever'); };
    const page = await readHistoryPage({ callDshRpc, sessionId: 'session-x' });
    assert.deepEqual(page, { messages: [], hasMore: false, oldestSeq: null });
  });

  it('advances the anchor even when the page has no renderable messages', async () => {
    // All events are tool calls: convertSessionRecordsToMessages drops them, but
    // the paging anchor must still move or the client would re-fetch forever.
    const events = [5, 6, 7].map((i) => ({ type: 'tool/call', seq: i, data: { name: 'ls' } }));
    const engine = makeFakeEngine(events);
    const page = await readHistoryPage({ callDshRpc: engine.callDshRpc, sessionId: 'session-x', beforeSeq: 8 });
    assert.equal(page.messages.length, 0);
    assert.equal(page.oldestSeq, 5, 'oldest EVENT seq, so the client cursor still advances');
    assert.equal(page.hasMore, false);
  });

  it('guards its inputs', async () => {
    const engine = makeFakeEngine([]);
    assert.deepEqual(await readHistoryPage({ callDshRpc: engine.callDshRpc, sessionId: '' }), { messages: [], hasMore: false, oldestSeq: null });
    assert.deepEqual(await readHistoryPage({ callDshRpc: null, sessionId: 'x' }), { messages: [], hasMore: false, oldestSeq: null });
  });
});

/* ------------------------------------------------------------------ *
 * 3. Route layer
 * ------------------------------------------------------------------ */

test('the history/page route is claimed by the feature layer, not the sessions/* wildcard', () => {
  assert.ok(
    FEATURE_ROUTES.some(([m, p]) => m === 'GET' && p === '/api/mobile/sessions/history/page'),
    'FEATURE_ROUTES must list GET /api/mobile/sessions/history/page'
  );
  assert.equal(claimsMobileFeatureRoute('GET', '/api/mobile/sessions/history/page'), true);
  // Method-sensitive: a POST to the same path stays with the wildcard/history.
  assert.equal(claimsMobileFeatureRoute('POST', '/api/mobile/sessions/history/page'), false);
});

/* ---- live bridge, no engine: the degradation path, end to end ---- */

let BASE = null;
let TOKEN = null;
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

before(async () => {
  const { apply } = await import('../../dsh-server-plugin/lib/index.js');
  const { loadConfig } = await import('../../dsh-server-plugin/lib/store.mjs');
  TOKEN = loadConfig().token;

  const srv = http.createServer();
  await new Promise((res, rej) => { srv.once('error', rej); srv.listen(0, '127.0.0.1', res); });
  const { port } = srv.address();
  await new Promise((res) => srv.close(res));

  const effectFns = [];
  const mockCtx = {
    logger: () => ({ info() {}, warn() {}, error() {}, log() {} }),
    webServer: { port: 3080 },
    connection: { rpc: { handle: () => async () => {} } },
    effect: (fn) => { effectFns.push(fn); return () => {}; },
    on: (evt, fn) => { if (evt === 'dispose') effectFns.push(fn); }
  };
  const disposer = apply(mockCtx, { port }, { port, dshPort: 1, isListening: true });
  teardown = async () => {
    try { await disposer?.(); } catch { /* ignore */ }
    for (const fn of effectFns) { try { await fn(); } catch { /* ignore */ } }
  };
  BASE = `http://127.0.0.1:${port}`;

  for (let i = 0; i < 50; i++) {
    try { await req('/api/mobile/health'); return; } catch { await new Promise((r) => setTimeout(r, 100)); }
  }
  throw new Error('bridge did not start');
});

after(async () => { await teardown?.(); });

describe('route: GET /api/mobile/sessions/history/page (no live engine)', () => {
  it('answers 200 hasMore:false when the engine RPC is unreachable — never a 500', async () => {
    const res = await req('/api/mobile/sessions/history/page?sessionId=session-fixture-1&beforeSeq=100&max=20');
    assert.equal(res.status, 200, `expected graceful degradation, got ${res.status}`);
    assert.equal(res.data?.ok, true);
    assert.deepEqual(res.data?.messages, []);
    assert.equal(res.data?.hasMore, false);
  });

  it('rejects a missing sessionId with 400', async () => {
    const res = await req('/api/mobile/sessions/history/page');
    assert.equal(res.status, 400);
  });

  it('rejects a path-traversal sessionId with 400', async () => {
    const res = await req('/api/mobile/sessions/history/page?sessionId=..%2f..%2fsecret');
    assert.equal(res.status, 400);
  });

  it('rejects a non-numeric beforeSeq with 400', async () => {
    const res = await req('/api/mobile/sessions/history/page?sessionId=session-fixture-1&beforeSeq=abc');
    assert.equal(res.status, 400);
  });
});
