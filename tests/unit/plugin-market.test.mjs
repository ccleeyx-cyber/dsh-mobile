/**
 * 插件上架前的自检（对应 https://deepseek.stream/guide 的硬性校验项）。
 *
 * 为什么要有这个文件：市场那边报错只会给一句红字，而且是在**上传之后**。
 * 下面每一条都是它会拦的东西，在本地跑一次就知道能不能过：
 *
 *   1. package.json 存在且 name/version 合规；
 *   2. `main`/`exports` 指向**真实存在的编译后 .js**（不能是 .ts）；
 *   3. `dsh.bundle.patch` 声明了，且指向的文件真的在包里、内容是 YAML 列表；
 *   4. README.md / LICENSE 存在（README 是市场详情页的正文来源）；
 *   5. 版本号与运行时上报的 BRIDGE_VERSION 一致 —— 诊断页显示的版本如果和
 *      包版本对不上，用户和你自己都会看错"到底装的是哪一版"。
 *
 * 全部只读仓库文件，不需要网络、不需要装依赖。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const pluginDir = path.join(repoRoot, 'dsh-server-plugin');
const pkg = JSON.parse(fs.readFileSync(path.join(pluginDir, 'package.json'), 'utf8'));

/** 市场给的 6 个用途分类（工具与调用 / 模型适配 / Prompt 增强 / Agent 工作流 / 界面与主题 / 开发与调试）。 */
const MARKET_CATEGORIES = new Set(['tools', 'model', 'prompt', 'workflow', 'ui', 'dev']);

test('插件包：name / version 符合市场与 npm 的要求', () => {
  assert.match(
    pkg.name,
    /^(@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9-]*$/,
    'name 必须全小写、只含字母数字与中划线（可带 scope）'
  );
  assert.match(pkg.version, /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/, 'version 必须是严格 SemVer');
  assert.ok(String(pkg.description || '').trim().length >= 10, 'description 不能为空（市场列表会显示它）');
});

test('插件包：入口是真实存在的纯 JavaScript', () => {
  const entry = pkg.main || pkg.exports?.['.']?.default || pkg.exports?.['.'];
  assert.equal(typeof entry, 'string', 'main/exports 必须给出入口');
  assert.ok(entry.endsWith('.js'), `入口必须是 .js（不能是 .ts 源码）：${entry}`);
  assert.ok(fs.existsSync(path.join(pluginDir, entry)), `入口文件不存在：${entry}`);
  // 编译产物不该再引用 .ts
  const src = fs.readFileSync(path.join(pluginDir, entry), 'utf8');
  assert.ok(!/from\s+['"][^'"]+\.ts['"]/.test(src), '入口不应 import .ts');
});

test('插件包：dsh.bundle.patch 真的存在且是 YAML 列表', () => {
  assert.ok(pkg.dsh, 'package.json 必须有 dsh 段');
  const patchRel = pkg.dsh?.bundle?.patch;
  assert.equal(typeof patchRel, 'string', 'dsh.bundle.patch 缺失 —— 这是市场识别客户端插件的核心凭据');

  const patchAbs = path.join(pluginDir, patchRel);
  assert.ok(fs.existsSync(patchAbs), `dsh.bundle.patch 指向的文件不存在：${patchRel}`);

  // 不引依赖做完整 YAML 解析：这里只钉住"是列表而不是空文件/对象"。
  const meaningful = fs
    .readFileSync(patchAbs, 'utf8')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith('#'));
  assert.ok(meaningful.length > 0, 'bundle patch 不能是空文件');
  assert.ok(meaningful[0].startsWith('- '), `bundle patch 必须是 YAML 列表（首行是 "- ..."），实际首行：${meaningful[0]}`);
  assert.ok(
    meaningful.join('\n').includes(pkg.name),
    'bundle patch 里必须出现插件包名（Cordis 按包名解析模块）'
  );
});

test('插件包：市场元数据齐全', () => {
  assert.equal(typeof pkg.dsh?.name, 'string', 'dsh.name 是市场列表的标题');
  assert.ok(String(pkg.dsh.name).trim().length > 0);
  assert.ok(
    MARKET_CATEGORIES.has(pkg.dsh?.category),
    `dsh.category 必须是市场分类之一：${[...MARKET_CATEGORIES].join(', ')}，实际：${pkg.dsh?.category}`
  );
  assert.equal(pkg.license, 'MIT', 'license 必须写清楚（npm 与市场都会展示）');
  assert.ok(String(pkg.author || '').trim().length > 0, 'author 不能为空');
  assert.ok(fs.existsSync(path.join(pluginDir, 'LICENSE')), '根目录必须有 LICENSE');
  assert.ok(
    fs.readFileSync(path.join(pluginDir, 'LICENSE'), 'utf8').trim().length > 0,
    'LICENSE 不能是空文件'
  );
  assert.ok(fs.existsSync(path.join(pluginDir, 'README.md')), '根目录必须有 README.md');
});

test('插件包：files 覆盖运行时产物（npm 发布不会漏文件）', () => {
  assert.ok(Array.isArray(pkg.files), 'files 必须是数组');
  for (const required of ['lib', 'LICENSE', 'README.md', pkg.dsh.bundle.patch.replace(/^\.\//, '')]) {
    assert.ok(pkg.files.includes(required), `files 里缺 ${required}`);
  }
});

test('插件包：声明 Node 版本下限（会话标题解码用内置 zstd）', () => {
  assert.equal(typeof pkg.engines?.node, 'string', 'engines.node 必须声明');
  const major = Number(String(pkg.engines.node).match(/(\d+)/)?.[1] || 0);
  assert.ok(major >= 22, `Node 下限至少要 22（zstd 需要 22.15+），实际 ${pkg.engines.node}`);
});

test('插件包：包版本与运行时上报的 BRIDGE_VERSION 一致', () => {
  const core = fs.readFileSync(path.join(pluginDir, 'lib', 'core.mjs'), 'utf8');
  const m = core.match(/export const BRIDGE_VERSION = '([^']+)'/);
  assert.ok(m, 'lib/core.mjs 里找不到 BRIDGE_VERSION');
  assert.equal(
    m[1],
    pkg.version,
    'package.json 的 version 与 BRIDGE_VERSION 不一致 —— 诊断页会显示错误的"当前版本"'
  );
});
