// Verify the bridge resolves the engine's real HMAC secret.
//
// SECURITY: this script previously printed the first 8 characters of every
// candidate secret and the first 12 of the winner. Any CI job, agent transcript,
// or terminal scrollback that captured its output therefore leaked a usable
// prefix of the live engine signing key — and that key is exactly what lets
// someone forge a dsh-auth-* cookie and reach engine port 3080 directly,
// bypassing this gateway entirely.
//
// It now prints only a non-reversible fingerprint (sha256 prefix) plus the
// length, which is enough to tell two secrets apart and to confirm which file
// won, without disclosing any part of the value. Sanitised 2026-10-08.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';

const home = process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
const re = /^\s*secret\s*:\s*['"]?([^'"\s#]+)/mi;

/** Short, stable, non-reversible identifier for a secret. Never print the value. */
const fingerprint = (s) => crypto.createHash('sha256').update(s).digest('hex').slice(0, 12);

let found = null;
let foundFrom = null;
for (const rel of ['.credentials.yaml', 'credentials.yaml', 'settings.yaml']) {
  const f = path.join(home, rel);
  if (!fs.existsSync(f)) {
    console.log(`${rel.padEnd(20)} -> 不存在`);
    continue;
  }
  const m = fs.readFileSync(f, 'utf8').match(re);
  if (m?.[1]) {
    console.log(`${rel.padEnd(20)} -> 命中 (sha256:${fingerprint(m[1])}…, 长度 ${m[1].length})`);
    if (!found) { found = m[1]; foundFrom = rel; }
  } else {
    console.log(`${rel.padEnd(20)} -> 无 secret 字段`);
  }
}

console.log('\n最终使用:', found
  ? `sha256:${fingerprint(found)}… (长度 ${found.length}, 来源 ${foundFrom})`
  : '未找到');

if (found) {
  // Two known failure modes worth flagging while we are here.
  //
  // 1) The regex above matches ANY key called `secret`, not just the engine's
  //    HMAC key. lib/index.js:99-105 has the same pattern, so a `secret:` field
  //    belonging to some MCP server in settings.yaml can be picked up instead —
  //    after which every RPC silently returns `unauthorized` with no useful log.
  // 2) A 43-character value is the expected shape of the engine key. Anything
  //    much shorter almost certainly means the wrong field was matched.
  if (foundFrom === 'settings.yaml') {
    console.warn('\n⚠️ 命中的是 settings.yaml —— 该文件里任何名为 secret 的键都会被这个正则匹配到，');
    console.warn('   很可能抓到的是某个 MCP server 的凭据而不是引擎 HMAC 密钥。');
    console.warn('   lib/index.js:99-105 用的是同一个正则，存在同样的误匹配风险。');
  }
  if (found.length !== 43) {
    console.warn(`\n⚠️ 长度为 ${found.length}，引擎 HMAC 密钥通常是 43 字符（32 字节 base64url）。`);
    console.warn('   长度不符说明可能匹配到了错误的字段。');
  }
}

process.exit(found ? 0 : 1);
