/**
 * v1.35 / 1.1 — 自签证书模块（lib/tls.mjs）
 *
 * 全部 hermetic：DSH_HOME 指向 mkdtemp 目录，不读真实 ~/.dsh，不联网。
 *
 * 为什么要钉死这几条：
 *   - 「复用」写错会让宿主每次重启都换一张证书 → 所有已配对手机的 TOFU 全部
 *     触发变更告警，用户会以为网关被劫持；
 *   - 「SAN 变化重签」写错会让笔记本换 Wi-Fi 后连不上，而且没有任何提示；
 *   - 私钥权限在 Linux 宿主上是真实安全边界（同一台机器上的其它用户）。
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-tls-home-'));
process.env.DSH_HOME = TMP_HOME;

const {
  ensureCertificate,
  certsDir,
  certPaths,
  fingerprintOf,
  localHosts,
  currentFingerprint
} = await import('../../dsh-server-plugin/lib/tls.mjs');

const LAN_A = ['localhost', '127.0.0.1', '192.168.1.50'];
const LAN_B = ['localhost', '127.0.0.1', '10.0.0.9'];

describe('tls: self-signed certificate lifecycle', () => {
  after(() => {
    try { fs.rmSync(TMP_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
  });

  it('issues a parsesable, self-verifying certificate on first call', () => {
    const r = ensureCertificate({ hosts: LAN_A });
    assert.equal(r.regenerated, true);
    assert.equal(r.reason, 'missing');
    assert.match(r.fingerprint, /^sha256\/[0-9a-f]{64}$/);

    const x = new crypto.X509Certificate(r.cert);
    assert.equal(x.verify(x.publicKey), true, 'self-signed cert must verify against its own key');
    // SAN 决定了手机拿 IP 直连时系统是否接受这张证书。
    assert.match(x.subjectAltName, /127\.0\.0\.1/);
    assert.match(x.subjectAltName, /192\.168\.1\.50/);
    // 10 年有效期：换证书要动 App 信任库，不能太勤。
    assert.ok(new Date(x.validTo).getTime() - Date.now() > 3000 * 24 * 3600 * 1000);
  });

  it('reuses the certificate on the second call (stable fingerprint)', () => {
    const a = ensureCertificate({ hosts: LAN_A });
    const b = ensureCertificate({ hosts: LAN_A });
    assert.equal(a.regenerated, false);
    assert.equal(b.regenerated, false);
    assert.equal(b.fingerprint, a.fingerprint);
    assert.equal(currentFingerprint(), a.fingerprint);
    assert.equal(fs.readdirSync(certsDir()).includes('meta.json'), true);
  });

  it('re-signs when the SAN no longer covers the current network', () => {
    const before = ensureCertificate({ hosts: LAN_A });
    const after = ensureCertificate({ hosts: LAN_B });

    assert.equal(after.regenerated, true);
    assert.equal(after.reason, 'san-changed');
    assert.notEqual(after.fingerprint, before.fingerprint);

    const x = new crypto.X509Certificate(after.cert);
    assert.match(x.subjectAltName, /10\.0\.0\.9/);
    assert.doesNotMatch(x.subjectAltName, /192\.168\.1\.50/);

    // 旧证书必须留档：用户要解释「指纹为什么变了」时，能拿旧指纹对比。
    const archived = fs.readdirSync(certPaths().archive);
    assert.ok(archived.some((f) => f.endsWith('-cert.bak')));
    assert.ok(archived.some((f) => f.endsWith('-key.bak')));
  });

  it('re-signs and backs up when the private key disappeared', () => {
    ensureCertificate({ hosts: LAN_B });
    const archiveBefore = fs.readdirSync(certPaths().archive).length;
    fs.rmSync(certPaths().key);

    const r = ensureCertificate({ hosts: LAN_B });
    assert.equal(r.regenerated, true);
    assert.equal(r.reason, 'missing');
    assert.equal(fs.existsSync(certPaths().key), true);
    assert.ok(fs.readdirSync(certPaths().archive).length > archiveBefore);
  });

  it('re-signs when the certificate file is corrupt', () => {
    fs.writeFileSync(certPaths().cert, '-----BEGIN CERTIFICATE-----\nnot base64 at all\n-----END CERTIFICATE-----\n');
    const r = ensureCertificate({ hosts: LAN_B });
    assert.equal(r.regenerated, true);
    assert.equal(r.reason, 'corrupt');
    assert.doesNotThrow(() => new crypto.X509Certificate(r.cert));
  });

  it('forces a re-issue when asked, and clears the old fingerprint', () => {
    const before = ensureCertificate({ hosts: LAN_B });
    const forced = ensureCertificate({ hosts: LAN_B, force: true });
    assert.equal(forced.reason, 'forced');
    assert.notEqual(forced.fingerprint, before.fingerprint);
  });

  it('keeps the private key at 0600 on POSIX hosts', { skip: process.platform === 'win32' }, () => {
    ensureCertificate({ hosts: LAN_B });
    const mode = fs.statSync(certPaths().key).mode & 0o777;
    assert.equal(mode, 0o600);
  });

  it('fingerprintOf is the documented sha256/hex form', () => {
    const der = crypto.randomBytes(32);
    const fp = fingerprintOf(der);
    assert.equal(fp, 'sha256/' + crypto.createHash('sha256').update(der).digest('hex'));
  });

  it('localHosts always contains loopback', () => {
    const hosts = localHosts();
    assert.ok(hosts.includes('localhost'));
    assert.ok(hosts.includes('127.0.0.1'));
  });
});
