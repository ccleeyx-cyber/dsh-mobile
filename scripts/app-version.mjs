/**
 * 版本真源解析：`dsh_mobile/pubspec.yaml` 是唯一真源，这里把它变成构建可用的值。
 *
 * 产出三样东西，全部**派生**、不需要任何人手工同步：
 *   * version     —— pubspec `version: x.y.z+n` 的 `x.y.z`
 *   * build       —— 同一个 `+n`（Android versionCode 的来源，必须递增）
 *   * packageName —— `dsh_mobile/android/app/build.gradle` 的 applicationId
 *                    （App 侧的 `APP_PACKAGE_NAME`，用来校验 latest.json 不是给别的应用准备的）
 *
 * 用法：
 *   node scripts/app-version.mjs                    # 人类可读
 *   node scripts/app-version.mjs --json             # 单行 JSON（脚本消费）
 *   node scripts/app-version.mjs --defines          # 三个 --dart-define=… 一行，喂给 flutter
 *   node scripts/app-version.mjs --github-output    # 追加 version/build/tag/package_name 到 $GITHUB_OUTPUT
 *
 * 也可以在别处 import（避免第二份解析逻辑）：
 *   import { readAppVersion } from './scripts/app-version.mjs';
 *
 * 为什么 packageName 也要解析而不是写死：它的唯一用途是"这个清单是不是给我这个包
 * 的"，如果它自己变成一处手抄的副本，校验就退化成了形式主义。解析不到就**报错退出**，
 * 绝不吐一个空串出去 —— 空串注入进去会让所有清单都被判成"包名不符"。
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** 仓库根（本文件在 <root>/scripts/ 下）。 */
export const REPO_ROOT = path.resolve(HERE, '..');

/**
 * 从 pubspec.yaml 读 `version: x.y.z+n`。
 *
 * `+n` 是**必需**的，缺了直接报错：没有它就没有 versionCode，既没法判断"能不能
 * 覆盖安装"，也没法让客户端比对出"有新版"。宁可在构建期响亮地失败。
 */
export function readAppVersion(rootDir = REPO_ROOT) {
  const pubspecPath = path.join(rootDir, 'dsh_mobile', 'pubspec.yaml');
  const text = fs.readFileSync(pubspecPath, 'utf8');
  const m = text.match(/^version:[ \t]*(\d+\.\d+\.\d+)\+(\d+)[ \t]*$/m);
  if (!m) {
    throw new Error(
      `${pubspecPath} 里找不到可用的 version 行（需要形如 "version: 1.21.0+55"）。\n` +
        '  +n 不是装饰：Android versionCode 由它推导，缺了无法判断能否覆盖安装。',
    );
  }
  const [, version, build] = m;
  return { version, build, tag: `v${version}` };
}

/** 从 android/app/build.gradle（或 .kts）读 applicationId。 */
export function readPackageName(rootDir = REPO_ROOT) {
  const candidates = [
    path.join(rootDir, 'dsh_mobile', 'android', 'app', 'build.gradle'),
    path.join(rootDir, 'dsh_mobile', 'android', 'app', 'build.gradle.kts'),
  ];
  for (const file of candidates) {
    if (!fs.existsSync(file)) continue;
    const text = fs.readFileSync(file, 'utf8');
    // 只认 defaultConfig 里的赋值（`applicationIdSuffix` 之类不会命中这个模式）。
    const m = text.match(/\bapplicationId\s*[=(]\s*["']([^"']+)["']/);
    if (m) return m[1];
  }
  throw new Error(
    '无法从 dsh_mobile/android/app/build.gradle(.kts) 解析 applicationId。\n' +
      '  不要退化成空串：空 packageName 会让客户端把所有更新清单都判成"包名不符"。',
  );
}

/** 三个 `--dart-define=` 参数，可直接拼在 flutter 命令后面。 */
export function dartDefines(rootDir = REPO_ROOT) {
  const { version, build } = readAppVersion(rootDir);
  const packageName = readPackageName(rootDir);
  return [
    `--dart-define=APP_VERSION=${version}`,
    `--dart-define=APP_BUILD=${build}`,
    `--dart-define=APP_PACKAGE_NAME=${packageName}`,
  ];
}

function main() {
  const args = process.argv.slice(2);
  const has = (flag) => args.includes(flag);

  let info;
  try {
    info = { ...readAppVersion(), packageName: readPackageName() };
  } catch (e) {
    console.error(`[app-version] ${e.message}`);
    process.exit(1);
  }
  const defines = [
    `--dart-define=APP_VERSION=${info.version}`,
    `--dart-define=APP_BUILD=${info.build}`,
    `--dart-define=APP_PACKAGE_NAME=${info.packageName}`,
  ];

  if (has('--json')) {
    console.log(JSON.stringify(info));
    return;
  }

  if (has('--defines')) {
    console.log(defines.join(' \\\n  '));
    return;
  }

  if (has('--github-output')) {
    // GitHub runner 会把输出文件路径放进 $GITHUB_OUTPUT；本地跑就打到标准输出，
    // 不假装自己是 CI（静默写不了文件才是真的难查）。
    const out = process.env.GITHUB_OUTPUT;
    const lines = [
      `version=${info.version}`,
      `build=${info.build}`,
      `tag=${info.tag}`,
      `package_name=${info.packageName}`,
    ];
    if (out) {
      fs.appendFileSync(out, lines.join('\n') + '\n');
      console.log(`[app-version] 已写入 GITHUB_OUTPUT: ${lines.join(' ')}`);
    } else {
      console.log(lines.join('\n'));
    }
    return;
  }

  console.log(`版本真源: dsh_mobile/pubspec.yaml`);
  console.log(`  version     = ${info.version}`);
  console.log(`  build       = ${info.build}   (Android versionCode，必须递增)`);
  console.log(`  tag         = ${info.tag}`);
  console.log(`  packageName = ${info.packageName}   (来自 android/app/build.gradle)`);
  console.log('');
  console.log('注入构建（本地与 CI 同一条路）:');
  console.log(`  flutter build apk --release ${defines.join(' ')}`);
}

// 只在直接执行时跑 CLI；被 import 时什么都不做。
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
