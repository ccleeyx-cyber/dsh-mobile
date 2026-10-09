/**
 * Read versionName / versionCode from an APK's binary AndroidManifest.xml.
 *
 * The AXML string pool stores the attribute names as UTF-16; values live in the
 * typed value chunk as a string-pool index. We locate `versionName`/`versionCode`
 * in the pool, then find the STRING-typed attribute items that reference them.
 */

import fs from 'node:fs';

const file = process.argv[2];
if (!file) {
  console.error('用法: node read-apk-version.mjs <apk>');
  process.exit(1);
}

const buf = fs.readFileSync(file);

// Pull libapp.so + the manifest out of the zip without extra deps.
import { execFileSync } from 'node:child_process';
const manifest = execFileSync('powershell', [
  '-NoProfile', '-Command',
  `Add-Type -AssemblyName System.IO.Compression.FileSystem;` +
  `$z=[System.IO.Compression.ZipFile]::OpenRead('${file.replace(/'/g, "''")}');` +
  `$e=$z.Entries | Where-Object { $_.FullName -eq 'AndroidManifest.xml' };` +
  `$s=$e.Open(); $m=New-Object System.IO.MemoryStream; $s.CopyTo($m); $s.Close();` +
  `$z.Dispose(); [Console]::Out.Write([Convert]::ToBase64String($m.ToArray()))`
], { maxBuffer: 64 * 1024 * 1024, encoding: 'utf8' });

const axml = Buffer.from(manifest.trim(), 'base64');
console.log(`AndroidManifest.xml: ${axml.length} bytes`);
console.log(`magic=0x${axml.readUInt32LE(0).toString(16)} (期望 0x80003)`);

// UTF-16LE string pool scan for the attribute names.
const names = ['versionName', 'versionCode'];
const utf16 = axml.toString('utf16le');
for (const n of names) {
  console.log(`  ${n}: ${utf16.includes(n) ? '存在于清单' : '未找到'}`);
}

// Manifest chunk header: type(2) headerSize(2) size(4)
let off = 8;
while (off < axml.length - 8) {
  const type = axml.readUInt16LE(off);
  const size = axml.readUInt32LE(off + 4);
  if (size <= 0) break;
  if (type === 0x0001) { // STRING_POOL
    const count = axml.readUInt32LE(off + 8);
    const flags = axml.readUInt32LE(off + 16);
    const stringsStart = axml.readUInt32LE(off + 20);
    const isUtf8 = (flags & 0x100) !== 0;
    console.log(`\n字符串池: ${count} 条, UTF8=${isUtf8}`);
    const readIdx = [];
    for (let i = 0; i < count; i++) readIdx.push(axml.readUInt32LE(off + 28 + i * 4));
    const poolStart = off + stringsStart;
    const found = {};
    for (let i = 0; i < readIdx.length; i++) {
      const p = poolStart + readIdx[i];
      if (p >= axml.length) continue;
      let s;
      if (isUtf8) {
        const charLen = axml.readUInt16LE(p + 1);
        const byteLen = axml.readUInt16LE(p + 3);
        s = axml.slice(p + 5, p + 5 + byteLen).toString('utf8');
      } else {
        const strLen = axml.readUInt16LE(p);
        s = axml.slice(p + 2, p + 2 + strLen * 2).toString('utf16le');
      }
      for (const n of names) if (s === n) found[n] = i;
    }
    console.log('属性名索引:', JSON.stringify(found));

    // Scan START_TAG chunks for STRING-typed attributes with those name indices.
    let scan = off + size;
    while (scan < off + size + 0 || scan < axml.length - 8) {
      if (scan + 8 > axml.length) break;
      const t2 = axml.readUInt16LE(scan);
      const s2 = axml.readUInt32LE(scan + 4);
      if (s2 <= 0) { scan += 4; continue; }
      if (t2 === 0x0102) { // START_ELEMENT
        const attrStart = axml.readUInt16LE(scan + 20);
        const attrSize = axml.readUInt16LE(scan + 22);
        const attrCount = axml.readUInt16LE(scan + 24);
        for (let a = 0; a < attrCount; a++) {
          const ap = scan + attrStart + a * attrSize;
          const nameIdx = axml.readUInt32LE(ap + 4);
          const rawIdx = ap + 8 + 4;
          const dataType = axml.readUInt8(rawIdx + 3);
          const data = axml.readInt32LE(rawIdx);
          if (dataType === 0x03 && (nameIdx === found.versionName || nameIdx === found.versionCode)) {
            const p = poolStart + readIdx[data];
            let s;
            if (isUtf8) {
              const byteLen = axml.readUInt16LE(p + 3);
              s = axml.slice(p + 5, p + 5 + byteLen).toString('utf8');
            } else {
              const strLen = axml.readUInt16LE(p);
              s = axml.slice(p + 2, p + 2 + strLen * 2).toString('utf16le');
            }
            console.log(`  ${nameIdx === found.versionName ? 'versionName' : 'versionCode'} = ${s}`);
          }
        }
      }
      scan += s2;
    }
    break;
  }
  off += size;
}
