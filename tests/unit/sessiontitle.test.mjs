/**
 * Unit tests for lib/sessiontitle.mjs
 *
 * Covers the three title stores the bridge has to read (see the module header for
 * the measurement that motivated them) and the two things that silently break
 * the log fold: a session log is a **concatenation of zstd frames**, and only a
 * real `source.kind === 'user'` message is a human first prompt.
 *
 * Runs without a live bridge — `node --test tests/unit/sessiontitle.test.mjs`.
 */

import { describe, it, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';

import {
  sessionIdSpellings,
  archiveProjCacheFileName,
  projectionCacheCandidates,
  foldTitleFromEventLogText,
  isHumanTurn,
  scanZstdFrames,
  decompressEventLog,
  createEventLogTitleReader
} from '../../dsh-server-plugin/lib/sessiontitle.mjs';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-title-'));
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

function write(home, rel, data) {
  const full = path.join(home, ...rel);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, data);
  return full;
}

/** A session log as the engine writes it: one zstd frame per durable append. */
function writeLog(home, project, id, frames) {
  const dir = path.join(home, 'sessions', project, id);
  fs.mkdirSync(dir, { recursive: true });
  const buf = Buffer.concat(frames.map((f) => zlib.zstdCompressSync(Buffer.from(f, 'utf8'))));
  fs.writeFileSync(path.join(dir, 'session.v4.jsonl.zstd'), buf);
  return dir;
}

describe('sessionIdSpellings', () => {
  it('offers the prefixed form first, then the bare one', () => {
    assert.deepEqual(sessionIdSpellings('session-abc').spellings, ['session-abc', 'abc']);
    assert.deepEqual(sessionIdSpellings('abc').spellings, ['abc', 'session-abc']);
  });

  it('rejects anything that is not one safe path segment', () => {
    // These names are joined under a DSH home and then opened; a traversal or
    // separator here would read outside every storage domain.
    assert.equal(sessionIdSpellings('../../etc/passwd'), null);
    assert.equal(sessionIdSpellings('a/b'), null);
    assert.equal(sessionIdSpellings(''), null);
    assert.equal(sessionIdSpellings('   '), null);
    assert.equal(sessionIdSpellings(null), null);
    assert.equal(sessionIdSpellings('x'.repeat(65)), null);
  });
});

describe('archiveProjCacheFileName', () => {
  it('is the sha256 of the full id, base64url, unpadded', () => {
    // Measured against the live install: an archived session's projection cache
    // is `session_<base64url(sha256(sessionId))>.json` in
    // storages/session_projcache_archive_manager_v2/sessions/.
    const name = archiveProjCacheFileName('session-ee96adea-4893-4afe-b9cf-cb3a903b5746');
    assert.equal(name, 'session_7CwFRhZuAhZ1zfdM3_t9hL8XXH2AjZY3M--3dhXFLYI.json');
    assert.match(name, /^session_[A-Za-z0-9_-]{43}\.json$/);
  });

  it('differs per spelling, so both must be tried', () => {
    assert.notEqual(
      archiveProjCacheFileName('session-abc'),
      archiveProjCacheFileName('abc')
    );
  });
});

describe('projectionCacheCandidates', () => {
  it('covers the main domain and the archive domain', () => {
    const cands = projectionCacheCandidates(tmp, 'session-abc');
    assert.equal(cands.length, 4);
    assert.ok(cands.some((p) => p.endsWith(path.join('session_projcache', 'sessions', 'session-abc.json'))));
    assert.ok(cands.some((p) => p.endsWith(path.join('session_projcache', 'sessions', 'abc.json'))));
    assert.equal(cands.filter((p) => p.includes('session_projcache_archive_manager_v2')).length, 2);
  });

  it('returns nothing for an unusable id', () => {
    assert.deepEqual(projectionCacheCandidates(tmp, '../escape'), []);
  });
});

describe('foldTitleFromEventLogText', () => {
  const lines = (...objs) => objs.map((o) => JSON.stringify(o)).join('\n');

  it('keeps the last title, since the engine appends a fallback then a provider title', () => {
    const text = lines(
      { type: 'session/title', data: { title: '首条 prompt 截断…', source: { kind: 'fallback' } } },
      { type: 'session/title', data: { title: '真正的标题', source: { kind: 'provider' } } }
    );
    assert.equal(foldTitleFromEventLogText(text).title, '真正的标题');
  });

  it('takes the first human turn as firstPrompt, not an injected notice', () => {
    const text = lines(
      { type: 'user/message', data: { content: [{ type: 'text', text: 'approval policy changed' }], source: { kind: 'plugin', plugin: 'user-approval' } } },
      { type: 'user/message', data: { content: [{ type: 'text', text: 'system prompt snapshot' }], source: { kind: 'agent-instructions' } } },
      { type: 'user/message', data: { content: [{ type: 'text', text: '我真正问的问题' }], source: { kind: 'user' } } },
      { type: 'user/message', data: { content: [{ type: 'text', text: '第二句' }], source: { kind: 'user' } } }
    );
    assert.equal(foldTitleFromEventLogText(text).firstPrompt, '我真正问的问题');
  });

  it('survives a torn tail line and junk', () => {
    const text = lines({ type: 'session/title', data: { title: '标题' } }) + '\n{"type":"sess';
    assert.equal(foldTitleFromEventLogText(text).title, '标题');
  });

  it('reports no title when the log has none', () => {
    assert.deepEqual(foldTitleFromEventLogText('{"type":"session","id":"x"}'), { title: '', firstPrompt: '' });
  });
});

describe('isHumanTurn', () => {
  it('accepts the user kind and a bare human origin string', () => {
    assert.equal(isHumanTurn({ source: { kind: 'user' } }), true);
    assert.equal(isHumanTurn({ origin: 'human' }), true);
  });

  it('rejects plugin notices, instruction snapshots, and unknown shapes', () => {
    assert.equal(isHumanTurn({ source: { kind: 'plugin', plugin: 'user-approval' } }), false);
    assert.equal(isHumanTurn({ source: { kind: 'agent-instructions' } }), false);
    assert.equal(isHumanTurn({}), false);
    assert.equal(isHumanTurn({ source: { kind: 'assistant' } }), false);
  });
});

describe('scanZstdFrames', () => {
  it('walks a concatenated multi-frame log', () => {
    const buf = Buffer.concat([
      zlib.zstdCompressSync(Buffer.from('a', 'utf8')),
      zlib.zstdCompressSync(Buffer.from('bb', 'utf8')),
      zlib.zstdCompressSync(Buffer.from('ccc', 'utf8'))
    ]);
    const { frames } = scanZstdFrames(buf);
    assert.equal(frames.length, 3);
    assert.equal(frames[0].start, 0);
    assert.equal(frames[frames.length - 1].end, buf.length);
  });

  it('reports a torn trailing frame instead of throwing', () => {
    const whole = zlib.zstdCompressSync(Buffer.from('complete', 'utf8'));
    const buf = Buffer.concat([whole, whole.subarray(0, 5)]);
    const { frames, tornStart } = scanZstdFrames(buf);
    assert.equal(frames.length, 1);
    assert.equal(tornStart, whole.length);
  });

  it('rejects a corrupt header rather than guessing', () => {
    assert.throws(() => scanZstdFrames(Buffer.from([1, 2, 3, 4, 5, 6, 7, 8])));
  });
});

describe('decompressEventLog', () => {
  it('joins EVERY frame, not just the first', async () => {
    // Regression: Node's zstd APIs stop after frame #1, so a title stored in a
    // later append was invisible. 201 bytes on a 566 KB real log, versus
    // 1 990 205 bytes decoded frame by frame.
    const home = path.join(tmp, 'multi');
    const frames = [
      '{"type":"session","id":"session-x"}\n',
      '{"type":"user/message","data":{"content":[{"type":"text","text":"问题"}],"source":{"kind":"user"}}}\n',
      '{"type":"session/title","data":{"title":"跨帧标题"}}\n'
    ];
    const file = path.join(writeLog(home, '--p--', 'session-x', frames), 'session.v4.jsonl.zstd');
    const text = await decompressEventLog(file);
    assert.ok(text.includes('跨帧标题'));
    assert.ok(text.includes('问题'));
  });

  it('handles a single-frame log', async () => {
    const home = path.join(tmp, 'single');
    const file = path.join(writeLog(home, '--p--', 'session-y', ['{"type":"session/title","data":{"title":"单帧"}}\n']), 'session.v4.jsonl.zstd');
    assert.ok((await decompressEventLog(file)).includes('单帧'));
  });
});

describe('createEventLogTitleReader', () => {
  it('peeks the filesystem synchronously and warms in the background', async () => {
    const home = path.join(tmp, 'reader');
    writeLog(home, '--E-workspace-TEST--', 'session-z', [
      '{"type":"user/message","data":{"content":[{"type":"text","text":"hi"}],"source":{"kind":"user"}}}\n',
      '{"type":"session/title","data":{"title":"异步标题"}}\n'
    ]);
    const reader = createEventLogTitleReader();

    // First peek: only metadata, so it reports pending rather than blocking.
    assert.deepEqual(reader.peek(home, 'session-z'), { pending: true });

    reader.warm(home, 'session-z');
    // Let the fold settle.
    await new Promise((resolve) => setTimeout(resolve, 50));

    const seen = reader.peek(home, 'session-z');
    assert.equal(seen.title, '异步标题');
    assert.equal(seen.firstPrompt, 'hi');
  });

  it('reads a title with await for callers allowed to block', async () => {
    const home = path.join(tmp, 'reader-await');
    writeLog(home, '--E-workspace-TEST--', 'session-w', ['{"type":"session/title","data":{"title":"直接读"}}\n']);
    const reader = createEventLogTitleReader();
    assert.equal((await reader.read(home, 'session-w')).title, '直接读');
  });

  it('returns null for an id with no log anywhere', () => {
    const reader = createEventLogTitleReader();
    assert.equal(reader.peek(path.join(tmp, 'empty'), 'session-none'), null);
  });

  it('drops one session on invalidate, so a rename is not shadowed by a stale fold', async () => {
    const home = path.join(tmp, 'reader-invalidate');
    writeLog(home, '--E-workspace-TEST--', 'session-v', ['{"type":"session/title","data":{"title":"旧标题"}}\n']);
    const reader = createEventLogTitleReader();
    await reader.read(home, 'session-v');
    assert.equal(reader.peek(home, 'session-v').title, '旧标题');
    reader.invalidate('session-v');
    assert.deepEqual(reader.peek(home, 'session-v'), { pending: true });
  });

  it('logs instead of throwing when the log is unreadable', async () => {
    const home = path.join(tmp, 'reader-bad');
    const dir = path.join(home, 'sessions', '--p--', 'session-u');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'session.v4.jsonl.zstd'), Buffer.from([9, 9, 9, 9, 9, 9, 9, 9, 9]));
    const warnings = [];
    const reader = createEventLogTitleReader({ log: (msg) => warnings.push(msg) });
    assert.equal(await reader.read(home, 'session-u'), null);
    // Either the scanner rejected it and the fallback decoder failed, or the
    // scanner threw outright — both must be reported, never swallowed silently.
    assert.ok(warnings.length > 0, 'expected a warning for the corrupt log');
  });
});
