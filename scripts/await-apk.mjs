/**
 * Watch the GitHub Actions APK build for a given commit and download the result.
 *
 *   node scripts/await-apk.mjs [commit-sha] [--timeout-minutes=25] [--out=DIR]
 *
 * Credentials come ONLY from the GITHUB_TOKEN / GH_TOKEN environment variable.
 *
 * This script used to scrape a `ghp_...` PAT out of `git remote get-url origin`.
 * That required the plaintext token to live in .git/config forever, where it
 * shows up in `git remote -v`, in every process command line, and in any CI log
 * that dumps the remote. Removed 2026-10-08. Create a fine-grained PAT with only
 * `actions:read` + `contents:read` and export it:
 *
 *   $env:GITHUB_TOKEN = 'github_pat_...'   # PowerShell
 *   export GITHUB_TOKEN=github_pat_...     # bash
 *
 * Exits non-zero if the run fails or the timeout elapses.
 */

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const WORKFLOW = 'build-apk.yml';

const args = process.argv.slice(2);
const shaArg = args.find((a) => /^[0-9a-f]{7,40}$/.test(a)) || null;
const opt = (name, dflt) => {
  const a = args.find((x) => x.startsWith(`--${name}=`));
  return a ? a.split('=').slice(1).join('=') : dflt;
};
const TIMEOUT_MIN = Number(opt('timeout-minutes', 25));
const OUT_DIR = opt('out', process.cwd());

/** Derive `owner/repo` from the origin remote instead of hardcoding it. */
function repoSlug() {
  const explicit = opt('repo', '');
  if (explicit) return explicit;
  try {
    // execFileSync (not execSync) — no shell, so a URL with special characters
    // cannot be reinterpreted, and the credential helper never sees a shell.
    const url = execFileSync('git', ['remote', 'get-url', 'origin'], { encoding: 'utf8' }).trim();
    const m =
      url.match(/github\.com[:/]([^/\s]+)\/([^/\s]+?)(?:\.git)?$/) ||
      url.match(/^(?:https?|ssh|git):\/\/[^/]*@?github\.com\/([^/]+)\/([^/]+?)(?:\.git)?$/);
    if (m) return `${m[1]}/${m[2]}`;
  } catch {
    /* fall through to the error below */
  }
  console.error('[await-apk] 无法从 origin 解析出 owner/repo，请用 --repo=owner/name 指定。');
  process.exit(1);
}

const REPO = repoSlug();

const PAT = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
if (!PAT) {
  console.error('[await-apk] 找不到 GitHub 凭据。');
  console.error('           本脚本只从环境变量读取，不再从 git remote URL 里抠 PAT。');
  console.error("           PowerShell:  $env:GITHUB_TOKEN = 'github_pat_...'");
  console.error('           需要的最小权限：actions:read + contents:read');
  process.exit(1);
}

const headers = {
  Authorization: `Bearer ${PAT}`,
  'User-Agent': 'dsh-mobile-build-watcher',
  Accept: 'application/vnd.github+json'
};

async function api(url) {
  const res = await fetch(`https://api.github.com${url}`, { headers });
  if (res.status === 401 || res.status === 403) {
    // Say so explicitly — a bad/expired token otherwise looks like "no run found"
    // and the script would spin until the timeout.
    console.error(`[await-apk] GitHub 拒绝凭据 (${res.status})。GITHUB_TOKEN 可能已失效或权限不足。`);
    process.exit(1);
  }
  if (!res.ok) throw new Error(`GitHub API ${res.status}: ${await res.text()}`);
  return res.json();
}

async function findRun() {
  const data = await api(`/repos/${REPO}/actions/workflows/${WORKFLOW}/runs?per_page=10`);
  const runs = data.workflow_runs || [];
  if (shaArg) return runs.find((r) => r.head_sha?.startsWith(shaArg)) || null;
  return runs[0] || null;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const deadline = Date.now() + TIMEOUT_MIN * 60_000;
let lastStatus = '';

console.log(`[await-apk] 监控 ${REPO} / ${WORKFLOW}，超时 ${TIMEOUT_MIN} 分钟`);

for (;;) {
  let run;
  try {
    run = await findRun();
  } catch (e) {
    console.error(`[await-apk] 查询失败: ${e.message}`);
    process.exit(1);
  }

  if (!run) {
    console.log('[await-apk] 尚未找到构建任务，继续等待...');
  } else {
    const line = `${run.head_sha.slice(0, 7)} | ${run.status} | ${run.conclusion ?? '-'}`;
    if (line !== lastStatus) {
      console.log(`[await-apk] ${line}`);
      lastStatus = line;
    }

    if (run.status === 'completed') {
      if (run.conclusion !== 'success') {
        console.error(`[await-apk] 构建失败: ${run.conclusion}`);
        console.error(`[await-apk] ${run.html_url}`);
        process.exit(1);
      }
      console.log('[await-apk] 构建成功，下载 APK...');
      await download(run);
      process.exit(0);
    }
  }

  if (Date.now() > deadline) {
    console.error('[await-apk] 等待超时。');
    process.exit(1);
  }
  await sleep(15000);
}

async function download(run) {
  const artifacts = await api(`/repos/${REPO}/actions/runs/${run.id}/artifacts`);
  const apkArtifact = (artifacts.artifacts || []).find((a) => a.name.includes('apk') && !a.expired);
  if (!apkArtifact) {
    console.error('[await-apk] 未找到 APK artifact。');
    process.exit(1);
  }

  fs.mkdirSync(OUT_DIR, { recursive: true });
  const zipPath = path.join(OUT_DIR, 'apk-artifact.zip');
  const res = await fetch(apkArtifact.archive_download_url, { headers });
  if (!res.ok) {
    console.error(`[await-apk] 下载失败: ${res.status}`);
    process.exit(1);
  }
  fs.writeFileSync(zipPath, Buffer.from(await res.arrayBuffer()));
  const mb = (fs.statSync(zipPath).size / 1048576).toFixed(1);
  console.log(`[await-apk] 已下载 ${zipPath} (${mb} MB)`);

  // Extract with the bsdtar that ships with Windows 10+/macOS/Linux instead of
  // telling the caller to run Expand-Archive by hand. Falls back gracefully.
  try {
    execFileSync('tar', ['-xf', zipPath, '-C', OUT_DIR], { stdio: 'inherit' });
    fs.rmSync(zipPath, { force: true });
    const apks = fs
      .readdirSync(OUT_DIR)
      .filter((f) => f.endsWith('.apk'))
      .map((f) => ({ f, p: path.join(OUT_DIR, f), s: fs.statSync(path.join(OUT_DIR, f)).size }))
      .sort((a, b) => b.s - a.s);
    if (!apks.length) {
      console.error('[await-apk] 解压后没有找到 .apk。');
      process.exit(1);
    }
    for (const a of apks) {
      console.log(`[await-apk]   ${a.f}  ${(a.s / 1048576).toFixed(1)} MB`);
    }
    console.log('');
    console.log('[await-apk] ⚠️ 安装前请先确认签名：CI 目前没有配置 release keystore，');
    console.log('[await-apk]    flutter build apk --release 会回退到 debug 签名，导致每次构建');
    console.log('[await-apk]    签名都不同、手机无法覆盖安装（必须先卸载，连带清空已保存的');
    console.log('[await-apk]    主机地址与令牌）。校验方法：');
    console.log('[await-apk]    keytool -printcert -jarfile <apk>   ← 看 Owner 是否为 CN=Android Debug');
    console.log('[await-apk]    修复方案见 ANALYSIS-优化与新增功能.md §1.1');
  } catch (e) {
    console.log(`[await-apk] 自动解压失败（${e.message}），压缩包保留在 ${zipPath}`);
    console.log('[await-apk] 手动解压: Expand-Archive -Path apk-artifact.zip -DestinationPath . -Force');
  }
}
