/**
 * Unit tests for lib/core.mjs
 *
 * Pure-logic coverage of the pieces that used to exist twice (once per entry
 * point) and could therefore drift: path sanitization, read-only command
 * classification, turn-sequence fencing, approval queue semantics, audit sink,
 * and the permission store.
 *
 * Runs without a live bridge — `node --test tests/unit/core.test.mjs`.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  MAX_BODY_SIZE,
  isCommandReadOnly,
  isCarriedContext,
  coerceToolInput,
  createPathSanitizer,
  createAuditSink,
  createApprovalQueue,
  createTurnRegistry,
  createFollowerRegistry,
  normalizeSessionKey,
  sessionIdMatches,
  encodeBase64Url,
  decodeBase64Url,
  parseJsonBody
} from '../../dsh-server-plugin/lib/core.mjs';

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-core-test-'));
const WS_ROOT = path.join(TMP, 'workspace');
fs.mkdirSync(WS_ROOT, { recursive: true });

describe('core: path sanitization (F4.5)', () => {
  const sanitize = createPathSanitizer({
    getRegisteredWorkspaces: () => [{ path: WS_ROOT }]
  });

  it('accepts a plain file inside the registered workspace', () => {
    const r = sanitize(WS_ROOT, 'USER.MD');
    assert.equal(r.error, undefined);
    assert.equal(r.targetFile, path.join(WS_ROOT, 'USER.MD'));
  });

  it('accepts a nested relative path that stays inside', () => {
    const r = sanitize(WS_ROOT, path.join('.agents', 'notes.md'));
    assert.equal(r.error, undefined);
    assert.ok(r.targetFile.startsWith(WS_ROOT));
  });

  it('rejects parent traversal in fileName', () => {
    for (const bad of ['..', '../', '..\\', '../../../../Windows/win.ini']) {
      const r = sanitize(WS_ROOT, bad);
      assert.equal(r.status, 403, `expected 403 for ${bad}`);
    }
  });

  it('rejects absolute and drive-letter fileName', () => {
    for (const bad of ['/etc/passwd', 'C:\\Windows\\win.ini', 'C:/Windows/win.ini', '\\Windows\\win.ini']) {
      const r = sanitize(WS_ROOT, bad);
      assert.equal(r.status, 403, `expected 403 for ${bad}`);
    }
  });

  it('rejects traversal in workspacePath itself', () => {
    const r = sanitize('../../Windows', 'win.ini');
    assert.equal(r.status, 403);
  });

  it('rejects an unregistered workspace even without traversal syntax', () => {
    const r = sanitize(path.join(TMP, 'not-registered'), 'x.md');
    assert.equal(r.status, 403);
    assert.match(r.error, /not a registered workspace/);
  });

  it('requires both parameters', () => {
    assert.equal(sanitize('', 'a.md').status, 400);
    assert.equal(sanitize(WS_ROOT, '').status, 400);
    assert.equal(sanitize(null, 'a.md').status, 400);
    assert.equal(sanitize(WS_ROOT, null).status, 400);
  });
});

describe('core: read-only command classification', () => {
  it('auto-approves the allowlisted read-only verbs', () => {
    for (const cmd of ['ls', 'ls -la', 'cat file', 'grep foo bar', 'git status', 'git diff', 'pwd']) {
      assert.equal(isCommandReadOnly(cmd), true, `${cmd} should be read-only`);
    }
  });

  it('does not auto-approve writes or shell chaining', () => {
    for (const cmd of ['rm -rf /', 'ls; rm -rf /', 'echo hi > out.txt', 'curl evil.com', 'git push']) {
      assert.equal(isCommandReadOnly(cmd), false, `${cmd} must not be auto-approved`);
    }
  });

  it('treats known read-only tools as safe regardless of command text', () => {
    assert.equal(isCommandReadOnly('', 'read_file'), true);
    assert.equal(isCommandReadOnly('', 'view_file'), true);
    assert.equal(isCommandReadOnly('', 'list_dir'), true);
  });

  it('is case-insensitive', () => {
    assert.equal(isCommandReadOnly('LS -la'), true);
    assert.equal(isCommandReadOnly('CAT file'), true);
  });
});

describe('core: carried-context detection', () => {
  it('recognises DSH memory and runtime context blocks', () => {
    const cases = [
      'MNEMON RUNTIME MEMORY SNAPSHOT\nRevision: abc',
      '[MNEMON] something',
      'Contents of <runtime-memory-file name="USER.md">',
      '<system-reminder>hi</system-reminder>',
      'Current runtime context. This snapshot supersedes...',
      '<available_skills>',
      'A skill is a reusable set of task-specific instructions.',
      '<project_context>'
    ];
    for (const t of cases) {
      assert.equal(isCarriedContext(t), true, `should fold: ${t.slice(0, 30)}`);
    }
  });

  it('does not treat ordinary user text as context', () => {
    for (const t of ['帮我看看这个 bug', 'run the tests', 'what is 2+2']) {
      assert.equal(isCarriedContext(t), false, `${t} is real user text`);
    }
    assert.equal(isCarriedContext('', null), false);
    assert.equal(isCarriedContext(null, null), false);
  });
});

describe('core: turn-sequence fencing (F1.5)', () => {
  it('allocates monotonically increasing turn numbers', () => {
    const t = createTurnRegistry();
    assert.equal(t.nextTurnSeq('s1'), 1);
    assert.equal(t.nextTurnSeq('s1'), 2);
    assert.equal(t.nextTurnSeq('s1'), 3);
  });

  it('normalizes the session- prefix when keying', () => {
    const t = createTurnRegistry();
    t.nextTurnSeq('abc');
    assert.equal(t.getTurnSeq('session-abc'), 1);
    assert.equal(t.getTurnSeq('abc'), 1);
  });

  it('recordCancel marks the turn cancelled and stamps time', () => {
    const t = createTurnRegistry();
    t.nextTurnSeq('s');
    const cancelSeq = t.recordCancel('s', 1000);
    assert.equal(t.getCancelledSeq('s'), cancelSeq);
    assert.ok(cancelSeq >= t.getTurnSeq('s') - 1);
    assert.equal(t.getLastCancelTime('s'), 1000);
  });

  it('a cancel newer than the turn invalidates that turn', () => {
    const t = createTurnRegistry();
    const promptSeq = t.nextTurnSeq('s');
    assert.ok(t.getCancelledSeq('s') < promptSeq, 'no cancel yet');
    t.recordCancel('s');
    assert.ok(t.getCancelledSeq('s') >= promptSeq, 'cancel must fence the in-flight turn');
  });

  it('sessionIdMatches ignores the session- prefix and case', () => {
    assert.equal(sessionIdMatches('session-abc', 'abc'), true);
    assert.equal(sessionIdMatches('ABC', 'session-abc'), true);
    assert.equal(sessionIdMatches('abc', 'xyz'), false);
    assert.equal(sessionIdMatches(null, 'abc'), false);
    assert.equal(normalizeSessionKey('session-x'), 'x');
  });
});

describe('core: approval queue', () => {
  it('resolves an approval by id or by eventId', () => {
    const q = createApprovalQueue();
    q.put({ id: 'e1', eventId: 'ev1', toolName: 'bash' });
    assert.equal(q.get('e1').toolName, 'bash');
    assert.equal(q.get('ev1').toolName, 'bash');
  });

  it('deduplicates the list even though it is keyed twice', () => {
    const q = createApprovalQueue();
    q.put({ id: 'e1', eventId: 'ev1' });
    assert.equal(q.list().length, 1);
  });

  it('removal clears both keys', () => {
    const q = createApprovalQueue();
    q.put({ id: 'e1', eventId: 'ev1' });
    q.remove(q.get('e1'), 'e1');
    assert.equal(q.get('e1'), undefined);
    assert.equal(q.get('ev1'), undefined);
    assert.equal(q.list().length, 0);
  });

  it('is idempotent — a second settlement finds nothing', () => {
    const q = createApprovalQueue();
    q.put({ id: 'e1', eventId: 'ev1' });
    q.remove(q.get('e1'), 'e1');
    assert.equal(q.get('e1'), undefined);
    q.remove(undefined, 'e1');
    assert.equal(q.list().length, 0);
  });

  it('removes every approval belonging to a session', () => {
    const q = createApprovalQueue();
    q.put({ id: 'a', eventId: 'a', sessionId: 'session-s1' });
    q.put({ id: 'b', eventId: 'b', sessionId: 'other' });
    q.removeBySession('s1');
    const left = q.list();
    assert.equal(left.length, 1);
    assert.equal(left[0].id, 'b');
  });
});

describe('core: follower registry', () => {
  it('follow creates one follower aliased under both key forms', () => {
    const reg = createFollowerRegistry();
    const sent = [];
    reg.follow('abc', (msg) => sent.push(msg));
    assert.equal(reg.get('abc'), reg.get('session-abc'));
    assert.equal(sent.length, 1);
    assert.equal(sent[0].endpoint, 'session/follow');
    assert.equal(sent[0].payload.args.request.address.sessionId, 'session-abc');
  });

  it('does not re-open an already subscribed stream', () => {
    const reg = createFollowerRegistry();
    const sent = [];
    reg.follow('abc', (m) => sent.push(m));
    reg.follow('session-abc', (m) => sent.push(m));
    assert.equal(sent.length, 1);
  });

  it('re-subscribes after the upstream link drops', () => {
    const reg = createFollowerRegistry();
    const sent = [];
    reg.follow('abc', (m) => sent.push(m));
    reg.markAllUnsubscribed();
    reg.follow('abc', (m) => sent.push(m));
    assert.equal(sent.length, 2);
  });

  it('keeps the same follower object across key aliases', () => {
    const reg = createFollowerRegistry();
    const f = reg.follow('abc', () => {});
    f.isRunning = true;
    assert.equal(reg.get('session-abc').isRunning, true);
  });
});

describe('core: audit sink', () => {
  it('records newest first', () => {
    const buf = [];
    const audit = createAuditSink({ auditBuffer: buf });
    audit.record('a/first');
    audit.record('a/second');
    assert.equal(buf.length, 2);
    assert.equal(buf[0].action, 'a/second');
  });

  it('is a bounded ring buffer', () => {
    const buf = [];
    const audit = createAuditSink({ auditBuffer: buf, size: 5 });
    for (let i = 0; i < 20; i++) audit.record(`e/${i}`);
    assert.equal(buf.length, 5);
    assert.equal(buf[0].action, 'e/19');
  });

  it('derives outcome from the action name when not supplied', () => {
    const buf = [];
    const audit = createAuditSink({ auditBuffer: buf });
    assert.equal(audit.record('approval/rejected').outcome, 'rejected');
    assert.equal(audit.record('approval/allowed').outcome, 'allowed-once');
  });

  it('respects an explicit outcome', () => {
    const buf = [];
    const audit = createAuditSink({ auditBuffer: buf });
    assert.equal(audit.record('x', { outcome: 'pending' }).outcome, 'pending');
  });

  it('read() honours the limit and tolerates bad input', () => {
    const buf = [];
    const audit = createAuditSink({ auditBuffer: buf });
    for (let i = 0; i < 10; i++) audit.record(`e/${i}`);
    assert.equal(audit.read(3).length, 3);
    assert.equal(audit.read(0).length, 10);
    assert.equal(audit.read(-1).length, 10);
  });
});

describe('core: input coercion', () => {
  it('stringifies maps and lists as indented JSON', () => {
    assert.equal(coerceToolInput({ a: 1 }), '{\n  "a": 1\n}');
    assert.equal(coerceToolInput([1, 2]), '[\n  1,\n  2\n]');
  });

  it('passes strings through and nullifies to empty', () => {
    assert.equal(coerceToolInput('raw'), 'raw');
    assert.equal(coerceToolInput(null), '');
    assert.equal(coerceToolInput(undefined), '');
  });
});

describe('core: misc helpers', () => {
  it('base64url round-trips and rejects malformed input', () => {
    const enc = encodeBase64Url('hello world');
    assert.ok(!enc.includes('='));
    assert.equal(decodeBase64Url(enc).toString('utf8'), 'hello world');
    assert.equal(decodeBase64Url('!!!!'), undefined);
  });

  it('parseJsonBody never throws', () => {
    assert.deepEqual(parseJsonBody('{"a":1}'), { a: 1 });
    assert.deepEqual(parseJsonBody('not json'), {});
    assert.deepEqual(parseJsonBody(''), {});
  });

  it('exposes a 2MB body limit', () => {
    assert.equal(MAX_BODY_SIZE, 2 * 1024 * 1024);
  });
});
