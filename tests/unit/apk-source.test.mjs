/**
 * v1.35 / W-A — APK 分发单真源
 *
 * 全 hermetic：下载函数注入，不联网。
 * 钉住的是「宁可 404 也不发坏包」这条线：
 *  - 清单缺 downloadUrl / sha256 → 拒绝；
 *  - 哈希不符 / 大小不符 → 删掉半成品，不写正式文件；
 *  - 已有本地包 → 不联网（否则每次请求都打一次 GitHub）；
 *  - 残骸（小于 1MB）→ 清掉重下。
 */

import { describe, it, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

const {
  parseManifest,
  ensureApk,
  latestManifestUrl,
  DEFAULT_APK_REPO
} = await import('../../dsh-server-plugin/lib/apk-source.mjs');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-apk-source-'));
after(() => {
  try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* ignore */ }
});

const APK_BYTES = Buffer.alloc(2 * 1024 * 1024, 7); // >1MB，模拟真实包
const APK_SHA = crypto.createHash('sha256').update(APK_BYTES).digest('hex');

function manifest(overrides = {}) {
  return {
    version: '1.35.1',
    versionCode: 79,
    size: APK_BYTES.length,
    sha256: APK_SHA,
    downloadUrl: 'https://example.invalid/app-arm64-v8a-release.apk',
    ...overrides
  };
}

describe('apk-source: 清单校验', () => {
  it('完整清单被规整', () => {
    const m = parseManifest(JSON.stringify(manifest()));
    assert.equal(m.version, '1.35.1');
    assert.equal(m.size, APK_BYTES.length);
  });

  it('缺 sha256 / downloadUrl 一律拒绝', () => {
    assert.equal(parseManifest(manifest({ sha256: '' })), null);
    assert.equal(parseManifest(manifest({ sha256: 'abc' })), null);
    assert.equal(parseManifest(manifest({ downloadUrl: '' })), null);
    assert.equal(parseManifest(manifest({ downloadUrl: 'http://insecure/x.apk' })), null);
  });

  it('坏 JSON 返回 null 而不是抛', () => {
    assert.equal(parseManifest('{not json'), null);
    assert.equal(parseManifest(null), null);
  });

  it('默认仓库与清单地址', () => {
    assert.equal(DEFAULT_APK_REPO, 'ccleeyx-cyber/dsh-mobile');
    assert.match(latestManifestUrl(), /releases\/latest\/download\/latest\.json$/);
  });
});

describe('apk-source: 取回与校验', () => {
  it('清单正确、下载成功 → 落盘并返回 downloaded', async () => {
    const dest = path.join(TMP, 'ok', 'dsh-agent.apk');
    const r = await ensureApk({
      dest,
      fetchText: async () => JSON.stringify(manifest()),
      downloadToFile: async (_url, file) => { fs.writeFileSync(file, APK_BYTES); }
    });
    assert.equal(r.ok, true);
    assert.equal(r.downloaded, true);
    assert.equal(fs.statSync(dest).size, APK_BYTES.length);
    assert.equal(fs.existsSync(dest + '.part'), false);
  });

  it('哈希不符 → 拒绝且不留半成品', async () => {
    const dest = path.join(TMP, 'bad-hash', 'dsh-agent.apk');
    const r = await ensureApk({
      dest,
      fetchText: async () => JSON.stringify(manifest({ sha256: 'f'.repeat(64) })),
      downloadToFile: async (_url, file) => { fs.writeFileSync(file, APK_BYTES); }
    });
    assert.equal(r.ok, false);
    assert.match(r.error, /校验失败/);
    assert.equal(fs.existsSync(dest), false);
    assert.equal(fs.existsSync(dest + '.part'), false);
  });

  it('大小不符 → 拒绝', async () => {
    const dest = path.join(TMP, 'bad-size', 'dsh-agent.apk');
    const r = await ensureApk({
      dest,
      fetchText: async () => JSON.stringify(manifest({ size: APK_BYTES.length + 1 })),
      downloadToFile: async (_url, file) => { fs.writeFileSync(file, APK_BYTES); }
    });
    assert.equal(r.ok, false);
    assert.match(r.error, /大小/);
    assert.equal(fs.existsSync(dest), false);
  });

  it('已有可用本地包 → 不联网', async () => {
    const dest = path.join(TMP, 'cached', 'dsh-agent.apk');
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, APK_BYTES);
    let fetched = 0;
    const r = await ensureApk({
      dest,
      fetchText: async () => { fetched++; return JSON.stringify(manifest()); },
      downloadToFile: async () => { fetched++; }
    });
    assert.equal(r.ok, true);
    assert.equal(r.downloaded, false);
    assert.equal(fetched, 0, '缓存命中不该产生任何网络调用');
  });

  it('小于 1MB 的残骸会被清掉重下', async () => {
    const dest = path.join(TMP, 'stale', 'dsh-agent.apk');
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, Buffer.from('partial'));
    const r = await ensureApk({
      dest,
      fetchText: async () => JSON.stringify(manifest()),
      downloadToFile: async (_url, file) => { fs.writeFileSync(file, APK_BYTES); }
    });
    assert.equal(r.ok, true);
    assert.equal(r.downloaded, true);
    assert.equal(fs.statSync(dest).size, APK_BYTES.length);
  });

  it('清单获取失败 → 可读错误', async () => {
    const r = await ensureApk({
      dest: path.join(TMP, 'netfail', 'dsh-agent.apk'),
      fetchText: async () => { throw new Error('ECONNRESET'); },
      downloadToFile: async () => {}
    });
    assert.equal(r.ok, false);
    assert.match(r.error, /ECONNRESET/);
  });

  it('没有下载实现时明确说明，而不是假装成功', async () => {
    const r = await ensureApk({ dest: path.join(TMP, 'noimpl', 'dsh-agent.apk') });
    assert.equal(r.ok, false);
    assert.match(r.error, /不支持自动下载/);
  });
});
