const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const os = require('os');

/**
 * The engine's HMAC secret. Read from DSH_SECRET, otherwise from the engine's
 * own credentials file — never hard-coded, so this probe stays safe to commit.
 */
function resolveSecret() {
  const fromEnv = process.env.DSH_SECRET || process.env.DSH_INTERNAL_SECRET;
  if (fromEnv?.trim()) return fromEnv.trim();
  const home = process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
  for (const rel of ['.credentials.yaml', 'credentials.yaml']) {
    try {
      const f = path.join(home, rel);
      if (!fs.existsSync(f)) continue;
      const m = fs.readFileSync(f, 'utf8').match(/^\s*secret\s*:\s*['"]?([^'"\s#]+)/mi);
      if (m?.[1]) return m[1];
    } catch { /* try next */ }
  }
  console.error('无法定位引擎密钥：请设置 DSH_SECRET 环境变量。');
  process.exit(1);
}

const DEFAULT_SECRET = resolveSecret();

function encodeBase64Url(value) {
  return Buffer.from(value).toString('base64').replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '');
}

function decodeBase64Url(value) {
  const BASE64URL_PATTERN = /^[A-Za-z0-9_-]*$/;
  if (!BASE64URL_PATTERN.test(value) || value.length % 4 === 1) return void 0;
  const padding = '='.repeat((4 - value.length % 4) % 4);
  const decoded = Buffer.from(value.replaceAll('-', '+').replaceAll('_', '/') + padding, 'base64');
  return encodeBase64Url(decoded) === value ? decoded : void 0;
}

function generateDshCookie(authority) {
  const secret = decodeBase64Url(DEFAULT_SECRET);
  const cookieName = 'dsh-auth-' + encodeBase64Url(crypto.createHash('sha256').update(authority).digest());
  const issuedAt = Date.now();
  const expiresAt = issuedAt + 86400 * 1000;
  const payload = { version: 1, authority, issuedAt, expiresAt };
  const body = encodeBase64Url(Buffer.from(JSON.stringify(payload), 'utf8'));
  const sig = crypto.createHmac('sha256', secret).update(body).digest();
  return `${cookieName}=v1.${body}.${encodeBase64Url(sig)}`;
}

function callDsh(method, payload) {
  return new Promise((resolve, reject) => {
    const authority = '127.0.0.1:3080';
    const cookie = generateDshCookie(authority);
    const postData = JSON.stringify({
      type: 'client-request',
      rpcId: crypto.randomUUID(),
      method: method,
      payload: payload
    });
    const req = http.request({
      host: '127.0.0.1',
      port: 3080,
      path: '/api/' + method,
      method: 'POST',
      headers: {
        'Host': authority,
        'Cookie': cookie,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData)
      }
    }, res => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => {
        try { resolve(JSON.parse(d)); } catch (e) { resolve(d); }
      });
    });
    req.on('error', reject);
    req.write(postData);
    req.end();
  });
}

(async () => {
  console.log('Testing session/cancel format 1 (sessionId at args root):');
  const res1 = await callDsh('session/cancel', { args: { sessionId: 'test-session-1' } });
  console.log('Result 1:', JSON.stringify(res1));

  console.log('Testing session/cancel format 2 (request envelope):');
  const res2 = await callDsh('session/cancel', { args: { request: { sessionId: 'test-session-1' } } });
  console.log('Result 2:', JSON.stringify(res2));

  console.log('Testing session/prompt format 1 (old format in lib/index.js):');
  const res3 = await callDsh('session/prompt', { args: { sessionId: 'test-session-1', prompt: { type: 'user', text: 'hi' } } });
  console.log('Result 3:', JSON.stringify(res3));

  console.log('Testing session/prompt format 2 (request envelope in index.js):');
  const res4 = await callDsh('session/prompt', { args: { request: { requestId: 'req-1', sessionId: 'test-session-1', mode: 'queue', content: [{ type: 'text', text: 'hi' }] } } });
  console.log('Result 4:', JSON.stringify(res4));

  console.log('\nTesting session/prompt & session/cancel on live active session:');
  const wsRes = await callDsh('workspace/list', { args: {} }).catch(() => null);
  // Create test session via DSH RPC
  const sRes = await callDsh('session/create', { args: { request: {} } });
  if (sRes?.result?.ok && sRes.result.value?.sessionId) {
    const sId = sRes.result.value.sessionId;
    const pRes = await callDsh('session/prompt', {
      args: { request: { requestId: crypto.randomUUID(), sessionId: sId, mode: 'queue', content: [{ type: 'text', text: 'Probe check' }] } }
    });
    console.log('Active session prompt:', JSON.stringify(pRes?.result?.value || pRes?.result));

    const cRes = await callDsh('session/cancel', {
      args: { request: { sessionId: sId } }
    });
    console.log('Active session cancel:', JSON.stringify(cRes?.result?.value || cRes?.result));

    await callDsh('session/delete', { args: { sessionId: sId } }).catch(() => {});
  }
})();

