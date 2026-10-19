// dsh-server-plugin APK 分发源（v1.35 / 工程卫生 W-A）
//
// 背景（1.31.1 事故）：网关按固定路径 `public/dsh-agent.apk` 分发安装包，而这个
// 文件是**手工投放**的。发布流水线只产出 GitHub Release，于是出现过「Release 更新
// 了、网关还是旧包」——用户从网关下载到的自然还是旧版本，且没有任何提示。
//
// 这里把它改成「本地缺包时自动从最新 Release 取回并缓存」：
//   1. 读 `releases/latest/download/latest.json`（版本/大小/sha256/下载地址）；
//   2. 下载到临时文件，**按清单校验 sha256**；
//   3. 校验通过才 rename 成正式文件（半成品永远不会被当成可用包）；
//   4. 之后所有请求都走本地磁盘，不再联网。
//
// 网络现实：本机 Node 的 https 在 release-assets 主机上会被 EOF 断开，所以下载
// 支持注入 —— index.js 传的是「Node 流式下载失败后退到系统 curl」的实现。
// 本模块自身零依赖、可注入，便于 hermetic 测试。

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

/** 默认仓库。可用 DSH_APK_REPO 覆盖（例如自建镜像）。 */
export const DEFAULT_APK_REPO = 'ccleeyx-cyber/dsh-mobile';

export function latestManifestUrl(repo = DEFAULT_APK_REPO) {
  return `https://github.com/${repo}/releases/latest/download/latest.json`;
}

/**
 * 校验并规整清单。缺字段就返回 null —— 宁可 404 并说明，也不要拿一份残缺清单
 * 去下载一个可能不是 APK 的东西。
 */
export function parseManifest(raw) {
  let obj = raw;
  if (typeof raw === 'string') {
    try { obj = JSON.parse(raw); } catch { return null; }
  }
  if (!obj || typeof obj !== 'object') return null;
  const url = String(obj.downloadUrl || '').trim();
  const sha = String(obj.sha256 || '').trim().toLowerCase();
  const size = Number(obj.size);
  if (!/^https:\/\//.test(url)) return null;
  if (!/^[0-9a-f]{64}$/.test(sha)) return null;
  return {
    version: String(obj.version || '').trim(),
    versionCode: Number(obj.versionCode) || 0,
    size: Number.isFinite(size) && size > 0 ? size : null,
    sha256: sha,
    downloadUrl: url
  };
}

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

/**
 * 确保本地有一份可用的 APK。
 *
 * @param {object} opts
 * @param {string} opts.dest 正式文件路径（public/dsh-agent.apk）
 * @param {(url: string) => Promise<string>} [opts.fetchText] 下载 JSON 的实现
 * @param {(url: string, file: string) => Promise<void>} [opts.downloadToFile] 下载二进制
 * @param {string} [opts.repo]
 * @param {boolean} [opts.force] 忽略缓存重新下载
 * @returns {Promise<{ok:true, path:string, downloaded:boolean, manifest:object} | {ok:false, error:string}>}
 */
export async function ensureApk({
  dest,
  fetchText,
  downloadToFile,
  repo = process.env.DSH_APK_REPO || DEFAULT_APK_REPO,
  force = false
} = {}) {
  if (!dest) return { ok: false, error: 'dest 未指定' };

  if (!force && fs.existsSync(dest)) {
    const stat = fs.statSync(dest);
    if (stat.size > 1024 * 1024) {
      return { ok: true, path: dest, downloaded: false, manifest: null };
    }
    // 太小：上次下载中断留下的残骸，删掉重来。
    try { fs.rmSync(dest, { force: true }); } catch { /* ignore */ }
  }

  if (typeof fetchText !== 'function' || typeof downloadToFile !== 'function') {
    return { ok: false, error: 'APK 不在本地，且当前环境不支持自动下载' };
  }

  let manifest;
  try {
    manifest = parseManifest(await fetchText(latestManifestUrl(repo)));
  } catch (err) {
    return { ok: false, error: `获取版本清单失败：${err?.message || err}` };
  }
  if (!manifest) {
    return { ok: false, error: '版本清单缺失或格式不对（downloadUrl / sha256 必需）' };
  }

  fs.mkdirSync(path.dirname(dest), { recursive: true });
  const tmp = `${dest}.part`;
  try {
    await downloadToFile(manifest.downloadUrl, tmp);
    if (!fs.existsSync(tmp)) throw new Error('下载没有产出文件');
    const got = sha256File(tmp);
    if (got !== manifest.sha256) {
      throw new Error(`校验失败：期望 ${manifest.sha256.slice(0, 12)}…，实际 ${got.slice(0, 12)}…`);
    }
    if (manifest.size != null && fs.statSync(tmp).size !== manifest.size) {
      throw new Error('大小与清单不一致');
    }
    fs.renameSync(tmp, dest);
  } catch (err) {
    try { fs.rmSync(tmp, { force: true }); } catch { /* ignore */ }
    return { ok: false, error: `下载安装包失败：${err?.message || err}` };
  }

  return { ok: true, path: dest, downloaded: true, manifest };
}
