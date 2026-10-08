// Verify the bridge resolves the engine's real HMAC secret.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const home = path.join(os.homedir(), '.dsh');
const re = /^\s*secret\s*:\s*['"]?([^'"\s#]+)/mi;

let found = null;
for (const rel of ['.credentials.yaml', 'credentials.yaml', 'settings.yaml']) {
  const f = path.join(home, rel);
  if (!fs.existsSync(f)) {
    console.log(`${rel.padEnd(20)} -> 不存在`);
    continue;
  }
  const m = fs.readFileSync(f, 'utf8').match(re);
  if (m?.[1]) {
    console.log(`${rel.padEnd(20)} -> 命中 (${m[1].slice(0, 8)}...)`);
    found ??= m[1];
  } else {
    console.log(`${rel.padEnd(20)} -> 无 secret 字段`);
  }
}

console.log('\n最终使用:', found ? `${found.slice(0, 12)}... (长度 ${found.length})` : '未找到');
process.exit(found ? 0 : 1);
