// 把 dsh-server-plugin 打成可直接上传到插件市场的 ZIP。
//
// 用法： node scripts/pack-plugin.mjs [--out <path>]
//
// 为什么需要这个脚本：市场的校验规则里最常踩的两条是
//   1. ZIP 里多套一层目录（解压后第一层看不到 package.json）；
//   2. 把 node_modules 打进去了（几十 MB，且平台禁止在服务端跑安装脚本）。
// 手工右键压缩这两个坑都躲不开，所以包结构在这里固定下来。
//
// 只打**运行时需要**的文件（与 package.json 的 `files` 对齐）：lib / client /
// public / cordis.patch.yml / README.md / LICENSE / package.json。测试、脚本、
// 锁文件一律不进包。
//
// ⚠️ 不依赖系统 zip/tar：这台机器上 `tar` 在不同终端里会解析到 GNU tar 或
// bsdtar，而 GNU tar 会把 `-f E:\...` 的盘符当成远端主机（`Cannot connect to E:`）。
// ZIP 由本文件用 zlib.deflateRawSync 直接写，任何平台、任何 PATH 行为都一样。
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pluginDir = path.join(repoRoot, 'dsh-server-plugin');

const INCLUDED = [
  'package.json',
  'cordis.patch.yml',
  'README.md',
  'LICENSE',
  'lib',
  'client',
  'public'
];

function fail(message) {
  console.error(`✗ ${message}`);
  process.exit(1);
}

if (!fs.existsSync(path.join(pluginDir, 'package.json'))) fail(`找不到 ${pluginDir}/package.json`);

const pkg = JSON.parse(fs.readFileSync(path.join(pluginDir, 'package.json'), 'utf8'));

// 上传前把市场会拦的硬伤先拦掉 —— 与其让平台回一句红字，不如在这里就说清楚。
if (!pkg.dsh || !pkg.dsh.bundle || !pkg.dsh.bundle.patch) {
  fail('package.json 缺少 dsh.bundle.patch（市场校验的硬性要求）');
}
const patchPath = path.join(pluginDir, pkg.dsh.bundle.patch);
if (!fs.existsSync(patchPath)) fail(`dsh.bundle.patch 指向的文件不存在：${pkg.dsh.bundle.patch}`);

const entry = pkg.main || pkg.exports?.['.']?.default || pkg.exports?.['.'];
if (typeof entry !== 'string' || !entry.endsWith('.js')) fail('main/exports 必须指向已编译的 .js');
if (!fs.existsSync(path.resolve(pluginDir, entry))) fail(`入口文件不存在：${entry}`);

for (const required of ['README.md', 'LICENSE', ...INCLUDED]) {
  if (!fs.existsSync(path.join(pluginDir, required))) fail(`缺少 ${required}`);
}

/* ---------------------------------------------------------------- *
 * 收集文件（递归，路径统一用 /，不跟随符号链接）
 * ---------------------------------------------------------------- */

function collect(relPath, out) {
  const abs = path.join(pluginDir, relPath);
  const st = fs.lstatSync(abs);
  if (st.isDirectory()) {
    for (const child of fs.readdirSync(abs).sort()) {
      if (child === 'node_modules' || child === '.git') continue;
      collect(path.posix.join(relPath, child), out);
    }
    return;
  }
  if (!st.isFile()) return;
  out.push({ rel: relPath.split(path.sep).join('/'), abs });
}

const files = [];
for (const item of INCLUDED) collect(item, files);
if (files.length === 0) fail('没有收集到任何文件');

/* ---------------------------------------------------------------- *
 * 极简 ZIP 写入（deflate，无 ZIP64 —— 这个包只有几百 KB）
 * ---------------------------------------------------------------- */

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i += 1) {
    let c = i;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[i] = c >>> 0;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i += 1) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** 固定 DOS 时间戳（1980-01-01）：同一份源码打出来的包字节一致，便于比对。 */
const DOS_TIME = 0;
const DOS_DATE = (1 << 5) | 1;

const localChunks = [];
const centralChunks = [];
let offset = 0;

for (const file of files) {
  const raw = fs.readFileSync(file.abs);
  const deflated = zlib.deflateRawSync(raw, { level: 9 });
  // 压不小就按 STORE 存，避免无意义的膨胀
  const useDeflate = deflated.length < raw.length;
  const body = useDeflate ? deflated : raw;
  const method = useDeflate ? 8 : 0;
  const sum = crc32(raw);
  const nameBuf = Buffer.from(file.rel, 'utf8');

  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0);
  local.writeUInt16LE(20, 4);          // version needed
  local.writeUInt16LE(0x0800, 6);      // flag: 文件名是 UTF-8
  local.writeUInt16LE(method, 8);
  local.writeUInt16LE(DOS_TIME, 10);
  local.writeUInt16LE(DOS_DATE, 12);
  local.writeUInt32LE(sum, 14);
  local.writeUInt32LE(body.length, 18);
  local.writeUInt32LE(raw.length, 22);
  local.writeUInt16LE(nameBuf.length, 26);
  local.writeUInt16LE(0, 28);

  localChunks.push(local, nameBuf, body);

  const central = Buffer.alloc(46);
  central.writeUInt32LE(0x02014b50, 0);
  central.writeUInt16LE(20, 4);        // version made by
  central.writeUInt16LE(20, 6);        // version needed
  central.writeUInt16LE(0x0800, 8);
  central.writeUInt16LE(method, 10);
  central.writeUInt16LE(DOS_TIME, 12);
  central.writeUInt16LE(DOS_DATE, 14);
  central.writeUInt32LE(sum, 16);
  central.writeUInt32LE(body.length, 20);
  central.writeUInt32LE(raw.length, 24);
  central.writeUInt16LE(nameBuf.length, 28);
  central.writeUInt16LE(0, 30);        // extra
  central.writeUInt16LE(0, 32);        // comment
  central.writeUInt16LE(0, 34);        // disk
  central.writeUInt16LE(0, 36);        // internal attrs
  central.writeUInt32LE(0o100644 * 0x10000, 38); // external attrs: regular 0644
  central.writeUInt32LE(offset, 42);
  centralChunks.push(central, nameBuf);

  offset += local.length + nameBuf.length + body.length;
}

const centralBuf = Buffer.concat(centralChunks);
const eocd = Buffer.alloc(22);
eocd.writeUInt32LE(0x06054b50, 0);
eocd.writeUInt16LE(0, 4);
eocd.writeUInt16LE(0, 6);
eocd.writeUInt16LE(files.length, 8);
eocd.writeUInt16LE(files.length, 10);
eocd.writeUInt32LE(centralBuf.length, 12);
eocd.writeUInt32LE(offset, 16);
eocd.writeUInt16LE(0, 20);

const outArgIndex = process.argv.indexOf('--out');
const outPath = path.resolve(
  outArgIndex > 0 && process.argv[outArgIndex + 1]
    ? process.argv[outArgIndex + 1]
    // 默认落在仓库的 work/ 下：一次性产物不进军仓库根，也不进插件目录（打进插件
    // 目录的话下一次打包会把它自己包进去）。work/plugin-package/ 已在 .gitignore。
    : path.join(repoRoot, 'work', 'plugin-package', `${pkg.name}-${pkg.version}.zip`)
);
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, Buffer.concat([...localChunks, centralBuf, eocd]));

/* ---------------------------------------------------------------- *
 * 回读校验：从写出的字节里重新解析中央目录
 * ---------------------------------------------------------------- */

const written = fs.readFileSync(outPath);
const eocdAt = written.length - 22;
if (written.readUInt32LE(eocdAt) !== 0x06054b50) fail('写出的 ZIP 找不到 EOCD，包无效');
const total = written.readUInt16LE(eocdAt + 10);
let cursor = written.readUInt32LE(eocdAt + 16);

const names = [];
for (let i = 0; i < total; i += 1) {
  if (written.readUInt32LE(cursor) !== 0x02014b50) fail(`中央目录第 ${i + 1} 项签名异常`);
  const nameLen = written.readUInt16LE(cursor + 28);
  const extraLen = written.readUInt16LE(cursor + 30);
  const commentLen = written.readUInt16LE(cursor + 32);
  names.push(written.toString('utf8', cursor + 46, cursor + 46 + nameLen));
  cursor += 46 + nameLen + extraLen + commentLen;
}

// 平台会拒绝"打开 ZIP 第一层看不到 package.json"的包。
const tops = new Set(names.map((n) => n.split('/')[0]));
if (!tops.has('package.json')) fail('ZIP 根层没有 package.json（多半是多套了一层目录）');
if (names.some((n) => n.startsWith('node_modules/') || n.includes('/node_modules/'))) {
  fail('ZIP 里混进了 node_modules');
}
if (names.length !== files.length) fail(`条目数不符：写入 ${files.length}，回读 ${names.length}`);

const sizeMb = (written.length / 1024 / 1024).toFixed(2);
console.log(`✓ ${pkg.name}@${pkg.version}`);
console.log(`  ${outPath}`);
console.log(`  ${names.length} 个条目 / ${sizeMb} MB / 根层：${[...tops].sort().join(', ')}`);
