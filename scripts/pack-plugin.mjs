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
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
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

for (const required of ['README.md', 'LICENSE']) {
  if (!fs.existsSync(path.join(pluginDir, required))) fail(`缺少 ${required}`);
}

for (const item of INCLUDED) {
  if (!fs.existsSync(path.join(pluginDir, item))) fail(`要打包的 ${item} 不存在`);
}

const outArgIndex = process.argv.indexOf('--out');
const outPath = path.resolve(
  outArgIndex > 0 && process.argv[outArgIndex + 1]
    ? process.argv[outArgIndex + 1]
    // 默认落在仓库的 work/ 下（一次性产物不进军仓库根，也不进插件目录 ——
    // 打进插件目录的话下一次打包会把它自己包进去）。work/plugin-package/ 已加
    // 进 .gitignore。
    : path.join(repoRoot, 'work', 'plugin-package', `${pkg.name}-${pkg.version}.zip`)
);
fs.mkdirSync(path.dirname(outPath), { recursive: true });
if (fs.existsSync(outPath)) fs.rmSync(outPath);

// tar 的 `-a` 按扩展名选压缩格式：Windows 自带的 bsdtar、macOS、Linux 都能用，
// 不需要额外依赖，也不用管「Windows 上有没有 zip 命令」。
const result = spawnSync('tar', ['-a', '-c', '-f', outPath, '-C', pluginDir, ...INCLUDED], {
  stdio: 'inherit'
});
if (result.status !== 0) fail(`tar 失败（退出码 ${result.status}）`);

// 打完再验一次根层结构：平台会拒绝"打开 ZIP 第一层看不到 package.json"的包。
const list = spawnSync('tar', ['-t', '-f', outPath], { encoding: 'utf8' });
if (list.status !== 0) fail('无法列出刚生成的 ZIP');
const entries = String(list.stdout || '').split('\n').map((line) => line.trim()).filter(Boolean);
const tops = new Set(entries.map((line) => line.split('/')[0]));
if (!tops.has('package.json')) fail('ZIP 根层没有 package.json（多半是多套了一层目录）');
if (entries.some((line) => line.startsWith('node_modules/') || line.includes('/node_modules/'))) {
  fail('ZIP 里混进了 node_modules');
}

const sizeMb = (fs.statSync(outPath).size / 1024 / 1024).toFixed(2);
console.log(`✓ ${pkg.name}@${pkg.version}`);
console.log(`  ${outPath}`);
console.log(`  ${entries.length} 个条目 / ${sizeMb} MB / 根层：${[...tops].sort().join(', ')}`);
