/**
 * Unit tests for session deletion (the previously-fake sessions/delete endpoint).
 *
 * Runs against a throwaway DSH_HOME, never the real store.
 */

import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { deleteSession } from '../../dsh-server-plugin/lib/core.mjs';

let HOME;

function seedWorkspace({ sessionIds, archived = [] }) {
  const wsPath = path.join(HOME, 'storages', 'workspace.json');
  fs.mkdirSync(path.dirname(wsPath), { recursive: true });
  fs.writeFileSync(wsPath, JSON.stringify({
    global: { archivedSessionIds: archived },
    tables: { workspaces: { 'ws-1': { workspaceId: 'ws-1', title: 'T', sessionIds } } }
  }, null, 2), 'utf8');
  return wsPath;
}

function seedCache(sessionId, { title = '' } = {}) {
  const dir = path.join(HOME, 'storages', 'session_projcache', 'sessions');
  fs.mkdirSync(dir, { recursive: true });
  const clean = sessionId.replace(/^session-/, '');
  const file = path.join(dir, `${clean}.json`);
  fs.writeFileSync(file, JSON.stringify({
    record: { rows: { title: { val: title } }, identity: { createdAt: Date.now() } }
  }), 'utf8');
  return file;
}

function readStore(wsPath) {
  return JSON.parse(fs.readFileSync(wsPath, 'utf8'));
}

describe('core: deleteSession', () => {
  beforeEach(() => {
    HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-del-'));
  });
  afterEach(() => {
    try { fs.rmSync(HOME, { recursive: true, force: true }); } catch { /* ignore */ }
  });

  it('archives, detaches and removes the cache entry', () => {
    const wsPath = seedWorkspace({ sessionIds: ['session-a', 'session-b'] });
    const cache = seedCache('session-a', { title: 'hello' });

    const r = deleteSession({ home: HOME, sessionId: 'session-a', workspaceId: 'ws-1' });
    assert.equal(r.ok, true);
    assert.equal(r.detached, 1);
    assert.equal(r.cacheRemoved, true);

    const ws = readStore(wsPath);
    assert.ok(ws.global.archivedSessionIds.includes('session-a'));
    assert.deepEqual(ws.tables.workspaces['ws-1'].sessionIds, ['session-b']);
    assert.equal(fs.existsSync(cache), false);
  });

  it('is idempotent — deleting twice still succeeds', () => {
    seedWorkspace({ sessionIds: ['session-a'] });
    seedCache('session-a');
    deleteSession({ home: HOME, sessionId: 'session-a' });
    const second = deleteSession({ home: HOME, sessionId: 'session-a' });
    assert.equal(second.ok, true);
    assert.equal(second.detached, 0, 'nothing left to detach');
  });

  it('accepts a bare id without the session- prefix', () => {
    const wsPath = seedWorkspace({ sessionIds: ['session-abc'] });
    seedCache('session-abc');
    const r = deleteSession({ home: HOME, sessionId: 'abc' });
    assert.equal(r.ok, true);
    const ws = readStore(wsPath);
    assert.ok(ws.global.archivedSessionIds.includes('abc'));
    assert.equal(ws.tables.workspaces['ws-1'].sessionIds.length, 0);
  });

  it('rejects an empty or missing sessionId instead of pretending success', () => {
    seedWorkspace({ sessionIds: ['session-a'] });
    for (const bad of ['', '   ', null, undefined]) {
      const r = deleteSession({ home: HOME, sessionId: bad });
      assert.equal(r.ok, false, `expected failure for ${JSON.stringify(bad)}`);
      assert.match(r.error, /sessionId/i);
    }
  });

  it('reports failure when the store cannot be read', () => {
    const r = deleteSession({ home: HOME, sessionId: 'session-x' });
    assert.equal(r.ok, false);
    assert.match(r.error, /Cannot read workspace store/);
  });

  it('does not duplicate an already-archived id', () => {
    const wsPath = seedWorkspace({ sessionIds: ['session-a'], archived: ['session-a'] });
    deleteSession({ home: HOME, sessionId: 'session-a' });
    const ws = readStore(wsPath);
    assert.equal(ws.global.archivedSessionIds.filter((x) => x === 'session-a').length, 1);
  });

  it('leaves other sessions and other workspaces alone', () => {
    const wsPath = seedWorkspace({ sessionIds: ['session-a', 'session-b', 'session-c'] });
    seedCache('session-b');
    deleteSession({ home: HOME, sessionId: 'session-a' });
    const ws = readStore(wsPath);
    assert.deepEqual(ws.tables.workspaces['ws-1'].sessionIds, ['session-b', 'session-c']);
    assert.equal(fs.existsSync(path.join(HOME, 'storages', 'session_projcache', 'sessions', 'b.json')), true);
  });
});
