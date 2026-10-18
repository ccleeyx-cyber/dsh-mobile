/**
 * 生成客户端的更新清单 `latest.json`（App 里「检查更新」读的那份）。
 *
 * ## 为什么必须有这个脚本
 *
 * v1.33.0 之前，发布流程只上传 APK，**从来没有人产出 latest.json** —— 于是
 * `https://…/releases/latest/download/latest.json` 永远是 404，客户端点「检查
 * 更新」只能回退成「检查不可用」。这不是网络问题，是发布侧少了一个文件。
 *
 * 清单字段与 `dsh_mobile/lib/models/client_update.dart` 的 `UpdateManifest`
 * 一一对应（schemaVersion / version / versionCode / packageName / downloadUrl /
 * size / sha256 / releaseNotes）。任何一项对不上，客户端会**整份拒绝**（而不是
 * 尽力解析），所以在构建期就把它们算齐，比让用户看到"清单不可信"好。
 *
 * 版本号 / versionCode / packageName 全部从 `scripts/app-version.mjs` 解析，
 * 不在这里抄第二份 —— 真源只有 pubspec.yaml 与 build.gradle。
 *
 * 用法：
 *   node scripts/latest-manifest.mjs \
 *     --apk dist/app-arm64-v8a-release.apk \
 *     --repository ccleeyx-cyber/dsh-mobile \
 *     --notes notes.md \
 *     --out dist/latest.json
 *
 * 不传 --out 时打到标准输出（本地核对用）。
 */

import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';

import { readAppVersion, readPackageName } from './app-version.mjs';

function parseArgs(argv) {
  const out = { apk: '', repository: '', notes: '', out: '' };
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i];
    const value = argv[i + 1];
    if (key === '--apk') (out.apk = value), i++;
    else if (key === '--repository') (out.repository = value), i++;
    else if (key === '--notes') (out.notes = value), i++;
    else if (key === '--out') (out.out = value), i++;
  }
  return out;
}

function sha256Hex(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  if (!args.apk || !fs.existsSync(args.apk)) {
    console.error(`[latest-manifest] 找不到 APK：${args.apk || '(未提供 --apk)'}`);
    process.exit(1);
  }
  if (!/^[^/]+\/[^/]+$/.test(args.repository)) {
    // downloadUrl 会直接拉一个要装到手机上的 APK，仓库写成空的等于发一份坏清单。
    console.error(`[latest-manifest] --repository 需要形如 owner/repo，收到：${args.repository}`);
    process.exit(1);
  }

  const { version, build, tag } = readAppVersion();
  const packageName = readPackageName();
  const size = fs.statSync(args.apk).size;
  const sha256 = sha256Hex(args.apk);

  const notes = args.notes && fs.existsSync(args.notes)
    ? fs.readFileSync(args.notes, 'utf8').trim().slice(0, 4000)
    : '';

  const manifest = {
    schemaVersion: 1,
    version,
    versionCode: Number.parseInt(build, 10),
    packageName,
    downloadUrl: `https://github.com/${args.repository}/releases/download/${tag}/${path.basename(args.apk)}`,
    size,
    sha256,
    ...(notes ? { releaseNotes: notes } : {}),
  };

  if (!Number.isInteger(manifest.versionCode) || manifest.versionCode <= 0) {
    console.error(`[latest-manifest] versionCode 解析失败：${build}`);
    process.exit(1);
  }
  if (!/^[0-9a-f]{64}$/.test(manifest.sha256)) {
    console.error('[latest-manifest] sha256 不是 64 位小写 hex');
    process.exit(1);
  }
  if (!manifest.downloadUrl.startsWith('https://')) {
    console.error('[latest-manifest] downloadUrl 必须是 https（客户端只接受 https）');
    process.exit(1);
  }

  const json = `${JSON.stringify(manifest, null, 2)}\n`;
  if (args.out) {
    fs.writeFileSync(args.out, json);
    console.log(
      `[latest-manifest] ${args.out} ← v${version}+${build} ${path.basename(args.apk)} ` +
        `(${size} bytes, sha256 ${sha256.slice(0, 12)}…)`,
    );
  } else {
    process.stdout.write(json);
  }
}

main();
