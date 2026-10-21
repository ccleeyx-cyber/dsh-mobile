/**
 * One-tap connection diagnostics + subagent/goal/command control [feat 2026-10-12].
 *
 * Contracts under test:
 *   1. The diagnostics route NEVER 500s: an engine that is down, slow or
 *      throwing only makes `engine_rpc` answer ok:false — every other check
 *      still reports, and the answer is always HTTP 200.
 *   2. Nothing sensitive leaks: no token, no absolute path, no raw engine
 *      error text reaches the phone.
 *   3. Subagent interrupt / goal pause-resume-complete / commands listing are
 *      wired to the REAL engine RPCs with their exact wire shapes, and an
 *      engine rejection degrades honestly (502 / empty list) instead of a
 *      fabricated success.
 *
 * Mock/isolation style follows features.test.mjs: handleFeatureRoute driven
 * through a fake dependency bag, no live engine, no real network; disk probe
 * writes only under an mkdtemp dir.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  handleFeatureRoute,
  claimsMobileFeatureRoute,
  redactDiagnosticDetail,
  probeDiskWritable
} from '../../dsh-server-plugin/lib/features.mjs';

function makeFakeRes() {
  const res = new PassThrough();
  const chunks = [];
  res.on('data', (c) => chunks.push(c));
  res.statusCode = null;
  res.headers = null;
  res.writeHead = function writeHead(status, headers) {
    this.statusCode = status;
    this.headers = headers;
    return this;
  };
  return res;
}

function makeDeps(overrides = {}) {
  const calls = { rpc: [], audits: [], status: null, body: null };
  const deps = {
    pathname: '/api/mobile/diagnostics',
    req: { method: 'GET' },
    res: makeFakeRes(),
    parsedUrl: { query: {} },
    jsonBody: {},
    sendJson: (status, body) => { calls.status = status; calls.body = body; },
    // Recording wrapper: even when a test overrides callDshRpc below, every
    // engine call still lands in calls.rpc for wire-shape assertions.
    callDshRpc: async (method, payload) => {
      calls.rpc.push({ method, payload });
      return overrides.callDshRpc
        ? overrides.callDshRpc(method, payload)
        : (overrides.rpcResult ?? {});
    },
    audit: (action, payload) => calls.audits.push({ action, payload }),
    logger: { warn() {}, info() {} },
    bridgeVersion: '1.16.0-test',
    mobileClients: [{ readyState: 1, isAlive: true }],
    eventsStreamReady: () => true,
    deviceCount: () => 2,
    // mkdtempSync isolation: the probe must never write next to the repo.
    dshHomeDir: fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-diag-')),
    // callDshRpc is deliberately excluded from the spread: the recording
    // wrapper above must stay in place even when a test overrides the RPC.
    ...(({ callDshRpc, ...rest }) => rest)(overrides)
  };
  return { deps, calls };
}

function check(calls, name) {
  return (calls.body?.checks ?? []).find((c) => c.name === name);
}

/* ---------------- diagnostics route ---------------- */

test('diagnostics: engine down answers 200 with ok:false, never 500', async () => {
  const { deps, calls } = makeDeps({
    callDshRpc: async () => { throw new Error('connect ECONNREFUSED 127.0.0.1:3080'); },
    eventsStreamReady: () => false
  });
  const handled = await handleFeatureRoute(deps);
  assert.equal(handled, true);
  assert.equal(calls.status, 200, 'engine failure must not become a 500');
  assert.equal(calls.body.ok, false);
  assert.equal(check(calls, 'engine_rpc').ok, false);
  // The rest of the report must still be present and gateway-local checks pass.
  assert.equal(check(calls, 'bridge_version').value, '1.16.0-test');
  assert.equal(check(calls, 'ws_clients').value, 1);
  assert.equal(check(calls, 'engine_events_stream').ok, false);
  assert.equal(check(calls, 'devices').value, 2);
  assert.equal(check(calls, 'disk').ok, true);
  assert.ok(typeof calls.body.generatedAt === 'string');
});

test('diagnostics: engine timeout also degrades to ok:false with 200', async () => {
  const { deps, calls } = makeDeps({
    callDshRpc: async () => { throw new Error('DSH RPC session/page timed out'); }
  });
  await handleFeatureRoute(deps);
  assert.equal(calls.status, 200);
  assert.equal(check(calls, 'engine_rpc').ok, false);
  assert.match(check(calls, 'engine_rpc').detail, /timed out/);
});

test('diagnostics: probe is a real RPC and reports elapsed ms on success', async () => {
  const { deps, calls } = makeDeps({});
  await handleFeatureRoute(deps);
  assert.equal(check(calls, 'engine_rpc').ok, true);
  assert.match(check(calls, 'engine_rpc').value, /^\d+ms$/);
  assert.equal(calls.rpc.length, 1);
  assert.equal(calls.rpc[0].method, 'session/page');
});

test('diagnostics: no token, no absolute path leaks into the answer', async () => {
  const secret = 'SuperSecretToken123';
  const home = 'C:/Users/somebody/.dsh/storages';
  const { deps, calls } = makeDeps({
    callDshRpc: async () => { throw new Error(`request to ${home}/x failed with token ${secret}`); }
  });
  await handleFeatureRoute(deps);
  const text = JSON.stringify(calls.body);
  assert.ok(!text.includes(secret), 'token must never appear in the answer');
  assert.ok(!text.includes('somebody'), 'user name inside a path must be redacted');
});

test('diagnostics: result is audited', async () => {
  const { deps, calls } = makeDeps({});
  await handleFeatureRoute(deps);
  assert.ok(calls.audits.some((a) => a.action === 'diagnostics/run'));
});

/* ---------------- redaction / disk helpers ---------------- */

test('redactDiagnosticDetail: collapses paths, caps length', () => {
  const out = redactDiagnosticDetail('connect failed at C:/Users/somebody/.dsh/storages/x/y.json (ref zzz)');
  assert.ok(!out.includes('somebody'), 'user name inside a path must be redacted');
  assert.ok(out.length <= 120);
  assert.equal(redactDiagnosticDetail(null), '');
});

test('probeDiskWritable: writable dir ok, unwritable dir fails without throwing', () => {
  const good = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-diag-ok-'));
  assert.equal(probeDiskWritable(good).ok, true);
  // A path whose parent is a FILE can never be creatable.
  const fileAsParent = path.join(good, 'plain-file.txt');
  fs.writeFileSync(fileAsParent, 'x');
  const bad = path.join(fileAsParent, 'sub');
  const r = probeDiskWritable(bad);
  assert.equal(r.ok, false);
  assert.ok(!String(r.detail).includes(good), 'detail must not carry the path');
});

/* ---------------- route table ---------------- */

test('new routes are claimed by the feature layer (not the session wildcard)', () => {
  assert.equal(claimsMobileFeatureRoute('GET', '/api/mobile/diagnostics'), true);
  assert.equal(claimsMobileFeatureRoute('GET', '/api/mobile/sessions/subagents'), true);
  assert.equal(claimsMobileFeatureRoute('POST', '/api/mobile/sessions/subagents/interrupt'), true);
  assert.equal(claimsMobileFeatureRoute('GET', '/api/mobile/sessions/commands'), true);
  assert.equal(claimsMobileFeatureRoute('POST', '/api/mobile/goals/pause'), true);
  assert.equal(claimsMobileFeatureRoute('POST', '/api/mobile/goals/resume'), true);
  assert.equal(claimsMobileFeatureRoute('POST', '/api/mobile/goals/complete'), true);
  // Method-sensitive: no GET for a POST-only route.
  assert.equal(claimsMobileFeatureRoute('GET', '/api/mobile/goals/pause'), false);
});

/* ---------------- subagent control ---------------- */

test('subagent list: passes through the engine catalog', async () => {
  const { deps, calls } = makeDeps({
    pathname: '/api/mobile/sessions/subagents',
    parsedUrl: { query: { sessionId: 'session-1' } },
    callDshRpc: async (method) => {
      assert.equal(method, 'subagents/list');
      return {
        parentAvailable: true,
        entries: [
          { kind: 'child', id: 'session-c1', activity: 'running', hasChildren: false, mode: 'continuable', label: 'worker' },
          { kind: 'child', id: 'session-c2', activity: 'inactive', hasChildren: false, mode: 'one-shot' },
          { kind: 'diagnostic', id: 'session-c3', reason: 'corrupt' }
        ]
      };
    }
  });
  await handleFeatureRoute(deps);
  assert.equal(calls.status, 200);
  assert.equal(calls.body.entries.length, 3);
  assert.equal(calls.body.entries[0].mode, 'continuable');
  assert.equal(calls.body.entries[1].mode, 'one-shot');
  assert.equal(calls.body.entries[2].kind, 'diagnostic');
});

test('subagent interrupt: exact engine wire shape + audit', async () => {
  const { deps, calls } = makeDeps({
    pathname: '/api/mobile/sessions/subagents/interrupt',
    req: { method: 'POST' },
    jsonBody: { parentSessionId: 'session-p', childSessionId: 'session-c' },
    callDshRpc: async () => ({ accepted: true })
  });
  await handleFeatureRoute(deps);
  assert.equal(calls.rpc[0].method, 'subagents/interruptByParent');
  assert.deepEqual(calls.rpc[0].payload.args, { childSessionId: 'session-c', parentSessionId: 'session-p', mode: 'continuable' });
  assert.ok(calls.audits.some((a) => a.action === 'subagent/interrupt'));
});

test('subagent interrupt: engine rejection answers 502, never a fabricated success', async () => {
  const { deps, calls } = makeDeps({
    pathname: '/api/mobile/sessions/subagents/interrupt',
    req: { method: 'POST' },
    jsonBody: { parentSessionId: 'p', childSessionId: 'c' },
    callDshRpc: async () => { throw new Error('subagent/parent-unavailable'); }
  });
  await handleFeatureRoute(deps);
  assert.equal(calls.status, 502);
  assert.equal(calls.body.ok, false);
});

test('subagent interrupt: missing ids are a 400 with no RPC', async () => {
  const { deps, calls } = makeDeps({
    pathname: '/api/mobile/sessions/subagents/interrupt',
    req: { method: 'POST' },
    jsonBody: { parentSessionId: 'p' }
  });
  await handleFeatureRoute(deps);
  assert.equal(calls.status, 400);
  assert.equal(calls.rpc.length, 0);
});

/* ---------------- goal control ---------------- */

test('goal pause/resume/complete: mapped to the real engine RPC with ref + audit', async () => {
  for (const [pathName, rpc, action] of [
    ['/api/mobile/goals/pause', 'goals/pause', 'pause'],
    ['/api/mobile/goals/resume', 'goals/resume', 'resume'],
    ['/api/mobile/goals/complete', 'goals/complete', 'complete']
  ]) {
    const { deps, calls } = makeDeps({
      pathname: pathName,
      req: { method: 'POST' },
      jsonBody: { sessionId: 'session-1', goalId: 'g1', revision: 1 },
      callDshRpc: async () => ({ phase: 'paused', revision: 2 })
    });
    await handleFeatureRoute(deps);
    assert.equal(calls.rpc[0].method, rpc);
    assert.deepEqual(calls.rpc[0].payload.args, { agentId: 'session-1', ref: { id: 'g1', revision: 1 } });
    assert.equal(calls.status, 200);
    assert.ok(calls.audits.some((a) => a.action === `goal/${action}`), 'every goal action must be audited');
  }
});

test('goal control: missing ref fields are a 400, not an RPC', async () => {
  const { deps, calls } = makeDeps({
    pathname: '/api/mobile/goals/pause',
    req: { method: 'POST' },
    jsonBody: { sessionId: 'session-1' }
  });
  await handleFeatureRoute(deps);
  assert.equal(calls.status, 400);
  assert.equal(calls.rpc.length, 0);
});

test('goal control: engine rejection answers 502 with the stable error + audit', async () => {
  const { deps, calls } = makeDeps({
    pathname: '/api/mobile/goals/complete',
    req: { method: 'POST' },
    jsonBody: { sessionId: 's', goalId: 'g', revision: 3 },
    callDshRpc: async () => { throw new Error('GOAL_INVALID_TRANSITION'); }
  });
  await handleFeatureRoute(deps);
  assert.equal(calls.status, 502);
  assert.equal(calls.body.error, 'engine rpc not available');
  assert.ok(calls.audits.some((a) => a.action === 'goal/complete-failed'));
});

/* ---------------- commands ---------------- */

test('commands: real engine listing passed through with names and hints', async () => {
  const { deps, calls } = makeDeps({
    pathname: '/api/mobile/sessions/commands',
    parsedUrl: { query: { sessionId: 'session-1' } },
    callDshRpc: async (method) => {
      assert.equal(method, 'commands/list');
      return [
        { name: 'compact', description: '压缩上下文' },
        { name: 'goal', description: '设置目标', input: { hint: 'objective' } }
      ];
    }
  });
  await handleFeatureRoute(deps);
  assert.equal(calls.status, 200);
  assert.deepEqual(calls.body.commands, [
    { name: 'compact', description: '压缩上下文', hint: null },
    { name: 'goal', description: '设置目标', hint: 'objective' }
  ]);
});

test('commands: engine failure degrades to an empty list with a reason, not fake rows', async () => {
  const { deps, calls } = makeDeps({
    pathname: '/api/mobile/sessions/commands',
    parsedUrl: { query: { sessionId: 'session-1' } },
    callDshRpc: async () => { throw new Error('gateway/invocation-unavailable'); }
  });
  await handleFeatureRoute(deps);
  assert.equal(calls.status, 200);
  assert.deepEqual(calls.body.commands, []);
  assert.equal(calls.body.degraded, 'engine rpc not available');
});

// [feat 2026-10-21] skill 目录：web 的 `/` 菜单 = 命令 + 技能两路合并，
// 手机端此前只接了命令那一路，打 `/` 看不到任何 skill。
test('skills: real engine catalog passed through, whenToUse fills an empty description', async () => {
  const { deps, calls } = makeDeps({
    pathname: '/api/mobile/sessions/skills',
    parsedUrl: { query: { sessionId: 'session-1' } },
    callDshRpc: async (method) => {
      assert.equal(method, 'skills/list');
      return {
        skills: [
          { name: 'ponytail-help', description: 'Quick-reference card', source: 'filesystem' },
          { name: 'skill-creator', description: '', whenToUse: '当用户要新建技能时', source: 'builtin' },
          { name: '', description: 'no name — must be dropped' }
        ]
      };
    }
  });
  await handleFeatureRoute(deps);
  assert.equal(calls.status, 200);
  assert.deepEqual(calls.body.skills, [
    { name: 'ponytail-help', description: 'Quick-reference card', source: 'filesystem' },
    { name: 'skill-creator', description: '当用户要新建技能时', source: 'builtin' }
  ]);
});

test('skills: tolerates the engine wrapping the catalog in value{}', async () => {
  const { deps, calls } = makeDeps({
    pathname: '/api/mobile/sessions/skills',
    parsedUrl: { query: { sessionId: 'session-1' } },
    callDshRpc: async () => ({ value: { skills: [{ name: 'a', description: 'd' }] } })
  });
  await handleFeatureRoute(deps);
  assert.equal(calls.status, 200);
  assert.deepEqual(calls.body.skills, [{ name: 'a', description: 'd', source: '' }]);
});

test('skills: engine rejection degrades to an empty list with a reason, never a fake catalog', async () => {
  const { deps, calls } = makeDeps({
    pathname: '/api/mobile/sessions/skills',
    parsedUrl: { query: { sessionId: 'session-1' } },
    callDshRpc: async () => { throw new Error('engine down'); }
  });
  await handleFeatureRoute(deps);
  assert.equal(calls.status, 200);
  assert.deepEqual(calls.body.skills, []);
  assert.equal(calls.body.degraded, 'engine rpc not available');
});

test('skills: missing sessionId is a 400, not an empty catalog', async () => {
  const { deps, calls } = makeDeps({
    pathname: '/api/mobile/sessions/skills',
    parsedUrl: { query: {} }
  });
  await handleFeatureRoute(deps);
  assert.equal(calls.status, 400);
});
