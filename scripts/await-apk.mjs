/**
 * Watch the GitHub Actions APK build for a given commit and download the result.
 *
 *   node scripts/await-apk.mjs [commit-sha] [--timeout-minutes=25]
 *
 * Reads the PAT from the `origin` remote URL (the credential is never stored in
 * a file). Exits non-zero if the run fails or the timeout elapses.
 */

import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const REPO = 'ccleeyx-cyber/dsh-mobile';
const WORKFLOW = 'build-apk.yml';

const args = process.argv.slice(2);
const shaArg = args.find((a) => /^[0-9a-f]{7,40}$/.test(a)) || null;
const timeoutArg = args.find((a) => a.startsWith('--timeout-minutes='));
const TIMEOUT_MIN = timeoutArg ? Number(timeoutArg.split('=')[1]) : 25;

function token() {
  try {
    const url = execSync('git remote get-url origin', { encoding: 'utf8' });
    const m = url.match(/ghp_[A-Za-z0-9]+/);
    return m ? m[0] : null;
  } catch {
    return null;
  }
}

const PAT = process.env.GITHUB_TOKEN || token();
if (!PAT) {
  console.error('找不到 GitHub 凭据：设置 GITHUB_TOKEN 环境变量。');
  process.exit(1);
}

const headers = {
  Authorization: `Bearer ${PAT}`,
  'User-Agent': 'dsh-mobile-build-watcher',
  Accept: 'application/vnd.github+json'
};

async function api(url) {
  const res = await fetch(`https://api.github.com${url}`, { headers });
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
  const apkArtifact = (artifacts.artifacts || []).find(
    (a) => a.name.includes('apk') && !a.expired
  );
  if (!apkArtifact) {
    console.error('[await-apk] 未找到 APK artifact。');
    process.exit(1);
  }

  const zipPath = path.join(process.cwd(), 'apk-artifact.zip');
  const res = await fetch(apkArtifact.archive_download_url, { headers });
  if (!res.ok) {
    console.error(`[await-apk] 下载失败: ${res.status}`);
    process.exit(1);
  }
  fs.writeFileSync(zipPath, Buffer.from(await res.arrayBuffer()));
  console.log(`[await-apk] 已下载 ${path.basename(zipPath)} (${(fs.statSync(zipPath).size / 1048576).toFixed(1)} MB)`);
  console.log('[await-apk] 用 PowerShell 解压: Expand-Archive -Path apk-artifact.zip -DestinationPath . -Force');
}
