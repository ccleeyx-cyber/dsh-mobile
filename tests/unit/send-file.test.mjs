/**
 * Tests for the real `sendFile` implementation.
 *
 * Why this file exists: downloads answered HTTP 500 for every deliverable with
 * `ReferenceError: res is not defined`, and no test noticed — because the route
 * tests injected `sendFile` as a two-argument stub that needed no response
 * object at all. A fake that does not resemble the real function cannot catch a
 * bug in the real function. So these tests import the real one and drive it with
 * a fake `res`, asserting the bytes that would actually reach the phone.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';

import { sendFile } from '../../dsh-server-plugin/lib/send-file.mjs';

/**
 * Minimal stand-in for an http.ServerResponse.
 *
 * PassThrough is the base because `stream.pipe(res)` needs a real Writable --
 * a hand-rolled object with write/end but no `on` makes pipe() throw
 * `dest.on is not a function`, which is a defect in the *test double*, not in
 * the code under test.
 */
function makeFakeRes() {
  const res = new PassThrough();
  const chunks = [];
  res.on('data', (c) => chunks.push(c));
  res.statusCode = null;
  res.headers = null;
  res.bytes = () => Buffer.concat(chunks);
  res.writeHead = function writeHead(status, headers) {
    this.statusCode = status;
    this.headers = headers;
    return this;
  };
  return res;
}

function tmpFile(name, content) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sendfile-'));
  const p = path.join(dir, name);
  fs.writeFileSync(p, content);
  return p;
}

test('sendFile: writes 200 with the exact bytes, length and encoded name', async () => {
  const content = Buffer.from('hello deliverable 交付物', 'utf8');
  const file = tmpFile('报表 v1.docx', content);
  const res = makeFakeRes();

  const ok = await sendFile(res, file, '报表 v1.docx');

  assert.equal(ok, true, 'must report success');
  assert.equal(res.statusCode, 200);
  assert.equal(res.headers['Content-Type'], 'application/octet-stream');
  assert.equal(res.headers['Content-Length'], content.length, 'Content-Length must equal the real size');
  // Non-ASCII names must survive RFC 5987 encoding, not be dropped.
  assert.match(res.headers['Content-Disposition'], /^attachment; filename\*=UTF-8''/);
  assert.equal(
    decodeURIComponent(res.headers['Content-Disposition'].split("UTF-8''")[1]),
    '报表 v1.docx'
  );

  // Wait for the pipe to flush before comparing bytes.
  await new Promise((r) => setImmediate(r));
  assert.equal(res.bytes().length, content.length, 'every byte must reach the client');
  assert.equal(res.bytes().toString('utf8'), content.toString('utf8'));
});

test('sendFile: a missing file writes NOTHING and reports false', async () => {
  const res = makeFakeRes();
  const missing = path.join(os.tmpdir(), 'definitely-not-here-' + Date.now() + '.bin');

  const ok = await sendFile(res, missing, 'x.bin');

  assert.equal(ok, false);
  assert.equal(res.statusCode, null, 'must not commit a status code');
  assert.equal(res.bytes().length, 0, 'must not write a body');
});

test('sendFile: a directory is refused, not streamed', async () => {
  const res = makeFakeRes();
  const ok = await sendFile(res, os.tmpdir(), 'tmp');

  assert.equal(ok, false);
  assert.equal(res.statusCode, null);
});

test('sendFile: displayName defaults to the file basename', async () => {
  const file = tmpFile('plain.txt', 'x');
  const res = makeFakeRes();

  await sendFile(res, file);

  assert.equal(
    decodeURIComponent(res.headers['Content-Disposition'].split("UTF-8''")[1]),
    'plain.txt'
  );
});

test('sendFile: a bogus response object fails loudly instead of silently succeeding', async () => {
  const file = tmpFile('b.txt', 'x');

  // `res` must be a real response. Passing something else has to reject rather
  // than quietly resolve: the original defect was in exactly this area -- the
  // function used a `res` it could not see and every call blew up with
  // `ReferenceError: res is not defined`, turning every download into a 500.
  // A silent success here would let that class of bug back in unnoticed.
  await assert.rejects(
    () => sendFile('not-a-response', file, 'b.txt'),
    (err) => {
      assert.ok(err instanceof TypeError, `expected a TypeError, got ${err?.name}`);
      return true;
    }
  );
});
