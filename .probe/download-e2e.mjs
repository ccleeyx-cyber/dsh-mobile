/**
 * End-to-end proving ground for the download route, without touching dsh web.
 *
 * Why: the unit tests historically only imported pure helpers, so nothing ever
 * executed a route handler's body over a real socket. That is how
 * `ReferenceError: res is not defined` survived every download for a whole
 * release. This mounts the REAL dispatcher on a REAL http server with a fake
 * engine and a real file, then downloads it.
 *
 * Read-only: it binds an ephemeral port on 127.0.0.1, creates one temp file,
 * and talks to no engine. Run: node .probe/download-e2e.mjs
 */
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { handleFeatureRoute } from '../dsh-server-plugin/lib/features.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dl-e2e-'));
const file = path.join(dir, '验收报告.docx');
const content = Buffer.from('PK\u0003\u0004 fake docx payload 交付物', 'utf8');
fs.writeFileSync(file, content);

const records = [
  { event: { type: 'deliverables/presented', seq: 7, data: { turn: 3, files: [{ path: file, description: '本轮产出' }] } } }
];

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://127.0.0.1');
  const pathname = u.pathname;
  // The dispatcher reads `parsedUrl.query.sessionId`, i.e. a plain bag -- not a
  // WHATWG URL (which exposes `searchParams`). Handing it a URL silently yields
  // `sessionId undefined`, which looks like a broken route rather than a broken
  // probe.
  const parsedUrl = { pathname, query: Object.fromEntries(u.searchParams) };
  const sendJson = (status, body) => {
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(body));
  };
  const handled = await handleFeatureRoute({
    pathname,
    req,
    res,
    parsedUrl,
    jsonBody: {},
    auth: { device: { id: 'probe', role: 'readwrite' } },
    sendJson,
    callDshRpc: async () => ({}),
    readStreamOnce: async () => null,
    readProjections: async () => null,
    readProjectionRows: () => null,
    readSessionRecords: async () => ({ records, cwd: dir, truncated: false }),
    readWorkspaceChanges: async () => ({ available: false, reason: 'not-a-git-repository', files: [] }),
    readConfig: () => ({}),
    writeConfig: (p) => p,
    pushTest: async () => true,
    audit: () => {},
    logger: { warn() {}, info() {} }
  });
  if (!handled) sendJson(404, { error: 'not handled' });
});

await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;
const base = `http://127.0.0.1:${port}/api/mobile`;

// 1. the list must surface the declared file
const listRes = await fetch(`${base}/deliverables?sessionId=session-probe`);
const list = await listRes.json();
console.log('LIST     status=%d count=%d path=%s', listRes.status, list.deliverables.length, list.deliverables[0]?.path === file ? 'match' : 'MISMATCH');

// 2. the download must return the real bytes (this is what used to be a 500)
const dlRes = await fetch(`${base}/deliverables/download?sessionId=session-probe&path=${encodeURIComponent(file)}`);
const bytes = Buffer.from(await dlRes.arrayBuffer());
console.log('DOWNLOAD status=%d content-length=%s bytes=%d type=%s',
  dlRes.status, dlRes.headers.get('content-length'), bytes.length, dlRes.headers.get('content-type'));
console.log('BYTES    identical=%s', bytes.equals(content));
console.log('DISPOSITION %s', dlRes.headers.get('content-disposition'));

// 3. a path that was never presented must still be refused
const badRes = await fetch(`${base}/deliverables/download?sessionId=session-probe&path=${encodeURIComponent('/etc/shadow')}`);
console.log('REFUSED  status=%d body=%s', badRes.status, (await badRes.text()).slice(0, 90));

server.close();
fs.rmSync(dir, { recursive: true, force: true });
