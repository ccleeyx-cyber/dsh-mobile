// dsh-server-plugin 自签证书与指纹（v1.35 / 任务 1.1）
//
// 为什么不用 node-forge：本插件的依赖面已经够大（ws / yaml / qrcode），而自签
// 证书只需要「一张 v3 证书 + ECDSA P-256 签名」。X.509 的 DER 结构是固定的，
// 这里手写一个最小编码器（约 100 行）就够用，换来的是**零新依赖**——插件通过
// `dsh plugin add` 安装时不必再拉一个 1MB 的包，也不会被供应链问题牵连。
//
// 生成的证书用于 3443 端口的 HTTPS/WSS（见 lib/index.js）。证书是自签的，手机
// 第一次连接时按 TOFU（首次信任）记住指纹；指纹变化必须由用户显式确认，逻辑在
// App 侧（lib/services/cert_trust.dart，任务 1.4）。
//
// 文件布局（跟随 store.mjs 的 mobile-access 根）：
//   $DSH_HOME/mobile-access/certs/cert.pem      证书
//   $DSH_HOME/mobile-access/certs/key.pem       私钥（0600）
//   $DSH_HOME/mobile-access/certs/meta.json     指纹 / SAN / 签发时间
//   $DSH_HOME/mobile-access/certs/archive/      重签时的旧证书备份

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';
import { dshHome } from './store.mjs';

/** 证书有效期：10 年。自签证书换一次要动 App 的信任库，不宜频繁。 */
const CERT_VALID_DAYS = 3650;
/** 剩余有效期小于这个天数就提前重签（避免用户出门时才发现过期）。 */
const RENEW_AHEAD_DAYS = 7;

export function certsDir() {
  return path.join(dshHome(), 'mobile-access', 'certs');
}

export function certPaths() {
  const dir = certsDir();
  return {
    dir,
    cert: path.join(dir, 'cert.pem'),
    key: path.join(dir, 'key.pem'),
    meta: path.join(dir, 'meta.json'),
    archive: path.join(dir, 'archive')
  };
}

/** `sha256/<64 hex>` —— 与配对二维码里的展示口径一致，便于用户肉眼比对。 */
export function fingerprintOf(der) {
  return 'sha256/' + crypto.createHash('sha256').update(der).digest('hex');
}

/**
 * 本机应当出现在证书 SAN 里的主机名/IP。
 *
 * 局域网直连时手机是拿 IP 连的，所以内网 IPv4 必须进 SAN；`localhost` 供本机
 * curl 自检。IPv6 只给回环，内网 IPv6 地址形态太杂，先不收。
 */
export function localHosts() {
  const hosts = ['localhost', '127.0.0.1', '::1'];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const ni of list || []) {
      if (ni.family === 'IPv4' && !ni.internal) hosts.push(ni.address);
    }
  }
  return [...new Set(hosts)];
}

/* ------------------------------------------------------------------ *
 * 最小 DER 编码器
 * ------------------------------------------------------------------ */

function derLength(n) {
  if (n < 0x80) return Buffer.from([n]);
  const bytes = [];
  let v = n;
  while (v > 0) { bytes.unshift(v & 0xff); v = Math.floor(v / 256); }
  return Buffer.from([0x80 | bytes.length, ...bytes]);
}

function tlv(tag, content) {
  const body = Buffer.isBuffer(content) ? content : Buffer.from(content);
  return Buffer.concat([Buffer.from([tag]), derLength(body.length), body]);
}

const seq = (...items) => tlv(0x30, Buffer.concat(items));

function oid(dotted) {
  const parts = dotted.split('.').map(Number);
  const bytes = [40 * parts[0] + parts[1]];
  for (const p of parts.slice(2)) {
    const enc = [];
    let v = p;
    do { enc.unshift(v & 0x7f); v = Math.floor(v / 128); } while (v > 0);
    for (let i = 0; i < enc.length - 1; i++) enc[i] |= 0x80;
    bytes.push(...enc);
  }
  return tlv(0x06, Buffer.from(bytes));
}

/** 正整数 DER INTEGER（serial 由随机字节构造，高位为 1 时补 0x00）。 */
function integer(content) {
  let buf = Buffer.isBuffer(content) ? content : Buffer.from([content]);
  if (buf.length === 0) buf = Buffer.from([0]);
  if (buf[0] & 0x80) buf = Buffer.concat([Buffer.from([0x00]), buf]);
  return tlv(0x02, buf);
}

const utf8 = (s) => tlv(0x0c, Buffer.from(s, 'utf8'));
const octet = (buf) => tlv(0x04, buf);
const boolTrue = () => tlv(0x01, Buffer.from([0xff]));
const algorithmId = () => seq(oid('1.2.840.10045.4.3.2')); // ecdsa-with-SHA256

function utcTime(date) {
  const p = (n) => String(n).padStart(2, '0');
  return tlv(0x17, Buffer.from(
    `${p(date.getUTCFullYear() % 100)}${p(date.getUTCMonth() + 1)}${p(date.getUTCDate())}` +
    `${p(date.getUTCHours())}${p(date.getUTCMinutes())}${p(date.getUTCSeconds())}Z`,
    'ascii'
  ));
}

function ipBytes(host) {
  if (!host.includes(':')) {
    const parts = host.split('.').map(Number);
    if (parts.length === 4 && parts.every((n) => Number.isInteger(n) && n >= 0 && n <= 255)) {
      return Buffer.from(parts);
    }
    return null;
  }
  // 只支持回环 ::1；其余 IPv6 形态先不进 SAN（见 localHosts 的说明）。
  if (host === '::1') return Buffer.concat([Buffer.alloc(15), Buffer.from([1])]);
  return null;
}

function altName(host) {
  const ip = ipBytes(host);
  if (ip) return tlv(0x87, ip); // [7] iPAddress
  if (host === 'localhost') return tlv(0x82, Buffer.from(host, 'ascii')); // [2] dNSName
  return null;
}

function extension(id, critical, value) {
  const parts = [oid(id)];
  if (critical) parts.push(boolTrue());
  parts.push(octet(value));
  return seq(...parts);
}

const x509Name = () => seq(tlv(0x31, seq(oid('2.5.4.3'), utf8('DSH Mobile Gateway'))));

/**
 * 生成一张自签 v3 证书。
 *
 * @param {string[]} hosts - SAN 里的主机名/IP
 * @param {Date} now
 * @returns {{ keyPem: string, certPem: string, fingerprint: string, sans: string[], serialHex: string }}
 */
export function createSelfSignedCertificate(hosts = localHosts(), now = new Date()) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });

  const serial = crypto.randomBytes(16);
  const notBefore = new Date(now.getTime() - 60 * 60 * 1000);
  const notAfter = new Date(now.getTime() + CERT_VALID_DAYS * 24 * 60 * 60 * 1000);

  const spki = publicKey.export({ type: 'spki', format: 'der' });
  const subject = x509Name();

  const sanList = [...new Set(hosts)].map(altName).filter(Boolean);
  const extensions = seq(
    extension('2.5.29.19', true, seq()),                      // basicConstraints: CA=false
    extension('2.5.29.15', true, tlv(0x03, Buffer.from([0x00, 0x80]))), // keyUsage: digitalSignature
    extension('2.5.29.17', false, seq(...sanList))            // subjectAltName
  );

  const tbs = seq(
    tlv(0xa0, integer(2)),                                    // version v3
    integer(serial),
    algorithmId(),
    subject,                                                  // issuer
    seq(utcTime(notBefore), utcTime(notAfter)),               // validity
    subject,                                                  // subject（自签：同名）
    spki,
    tlv(0xa3, extensions)                                     // [3] EXPLICIT Extensions
  );

  const signature = crypto.sign('sha256', tbs, privateKey);
  const certDer = seq(tbs, algorithmId(), tlv(0x03, Buffer.concat([Buffer.from([0]), signature])));

  return {
    keyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
    certPem: toPem(certDer),
    fingerprint: fingerprintOf(certDer),
    sans: hosts,
    serialHex: serial.toString('hex')
  };
}

function toPem(der) {
  const b64 = der.toString('base64').replace(/(.{64})/g, '$1\n').trim();
  return `-----BEGIN CERTIFICATE-----\n${b64}\n-----END CERTIFICATE-----\n`;
}

/* ------------------------------------------------------------------ *
 * 磁盘生命周期
 * ------------------------------------------------------------------ */

function readMeta(metaPath) {
  try {
    const raw = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
    if (raw && typeof raw.fingerprint === 'string' && Array.isArray(raw.sans)) return raw;
  } catch { /* 缺文件 / 坏 JSON 都按不存在处理 */ }
  return null;
}

function sanCovers(certPem, hosts) {
  let alt;
  try {
    alt = new crypto.X509Certificate(certPem).subjectAltName || '';
  } catch {
    return false;
  }
  // 形如 `DNS:localhost, IP Address:127.0.0.1`
  const covered = new Set();
  for (const part of alt.split(',')) {
    const [kind, ...rest] = part.trim().split(':');
    const value = rest.join(':').trim();
    if (kind === 'DNS') covered.add(value);
    if (kind === 'IP Address') covered.add(value === '0:0:0:0:0:0:0:1' ? '::1' : value);
  }
  return hosts.every((h) => covered.has(h));
}

function daysUntil(dateStr) {
  const t = Date.parse(dateStr);
  if (!Number.isFinite(t)) return -1;
  return (t - Date.now()) / (24 * 60 * 60 * 1000);
}

function backupExisting(paths) {
  try {
    fs.mkdirSync(paths.archive, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    for (const [name, file] of [['cert', paths.cert], ['key', paths.key], ['meta', paths.meta]]) {
      if (fs.existsSync(file)) {
        fs.copyFileSync(file, path.join(paths.archive, `${stamp}-${name}.bak`));
      }
    }
  } catch { /* 备份失败不阻塞重签：旧文件仍在原处 */ }
}

/**
 * 确保证书存在、未临期、SAN 覆盖当前网络。
 *
 * 返回 `{ key, cert, fingerprint, regenerated, reason }`。`regenerated` 为 true
 * 表示这次调用重签了证书——**指纹会变**，App 侧应按 TOFU 变更流程要求用户确认。
 *
 * 为什么需要 hosts 参数：笔记本换 Wi-Fi / 热点后内网 IP 会变，而手机正是拿
 * 新 IP 直连的。SAN 不覆盖就会被系统拒连（用户只会看到「连不上」）。重签是
 * 预期行为，代价是用户要确认一次指纹变更。
 */
export function ensureCertificate({ hosts = localHosts(), force = false } = {}) {
  const paths = certPaths();
  fs.mkdirSync(paths.dir, { recursive: true });
  fs.mkdirSync(paths.archive, { recursive: true });

  const haveFiles = fs.existsSync(paths.cert) && fs.existsSync(paths.key);
  const meta = readMeta(paths.meta);

  if (haveFiles && !force) {
    try {
      const certPem = fs.readFileSync(paths.cert, 'utf8');
      const parsed = new crypto.X509Certificate(certPem);
      const remaining = daysUntil(parsed.validTo);
      const derived = fingerprintOf(parsed.raw);
      const metaOk = !meta || meta.fingerprint === derived;
      if (remaining > RENEW_AHEAD_DAYS && metaOk && sanCovers(certPem, hosts)) {
        return {
          key: fs.readFileSync(paths.key, 'utf8'),
          cert: certPem,
          fingerprint: derived,
          regenerated: false,
          reason: 'reused'
        };
      }
      // 落到这里说明要重签：临期 / 指纹与 meta 不符 / SAN 不覆盖当前网络。
      backupExisting(paths);
      const reason = remaining <= RENEW_AHEAD_DAYS ? 'expiring' : (!metaOk ? 'meta-mismatch' : 'san-changed');
      const fresh = createSelfSignedCertificate(hosts);
      writeAll(paths, fresh);
      return { key: fresh.keyPem, cert: fresh.certPem, fingerprint: fresh.fingerprint, regenerated: true, reason };
    } catch {
      // 证书文件损坏：备份后重签（不能沿用一张解析不了的证书）。
      backupExisting(paths);
      const fresh = createSelfSignedCertificate(hosts);
      writeAll(paths, fresh);
      return { key: fresh.keyPem, cert: fresh.certPem, fingerprint: fresh.fingerprint, regenerated: true, reason: 'corrupt' };
    }
  }

  // 走到这里说明 cert/key 至少缺一个。只要还有任何一件旧文件在，就先备份 ——
  // 用户事后想找回"上次那张证书是哪张"时，指纹对得上才有意义。
  if ((haveFiles && force) || fs.existsSync(paths.cert) || fs.existsSync(paths.key)) {
    backupExisting(paths);
  }
  const fresh = createSelfSignedCertificate(hosts);
  writeAll(paths, fresh);
  return { key: fresh.keyPem, cert: fresh.certPem, fingerprint: fresh.fingerprint, regenerated: true, reason: force ? 'forced' : 'missing' };
}

function writeAll(paths, cert) {
  fs.writeFileSync(paths.key, cert.keyPem, { encoding: 'utf8', mode: 0o600 });
  fs.writeFileSync(paths.cert, cert.certPem, 'utf8');
  fs.writeFileSync(paths.meta, JSON.stringify({
    fingerprint: cert.fingerprint,
    sans: cert.sans,
    createdAt: new Date().toISOString(),
    serial: cert.serialHex
  }, null, 2), 'utf8');
  // Windows 上 chmod 是 no-op，但 POSIX 宿主（Linux 部署）必须收紧权限。
  try { fs.chmodSync(paths.key, 0o600); } catch { /* best effort */ }
}

/** 只读指纹（不触发签发）：配对二维码、健康检查用。 */
export function currentFingerprint() {
  try {
    const certPem = fs.readFileSync(certPaths().cert, 'utf8');
    return fingerprintOf(new crypto.X509Certificate(certPem).raw);
  } catch {
    return '';
  }
}
