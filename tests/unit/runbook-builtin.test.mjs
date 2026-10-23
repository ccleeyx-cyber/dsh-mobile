/**
 * [fix 2026-10-22] Runbook「目录概览」在 Windows 上必然失败。
 *
 * 用户报告：会话信息 → Runbook → 「目录概览」点执行显示「执行失败」。
 * 根因不是权限也不是 cwd：默认模板那条是 `ls -lt`，而网关跑在 Windows 上，
 * `execFile('ls')` 直接 ENOENT（`command-not-found`），手机端拿不到 error 文案
 * 就只能显示「执行失败」。
 *
 * 这里钉住两件事：
 *  1. Windows 上 `ls` 走**内置只读实现**（不开 shell、不 exec 任何进程）；
 *  2. 真的没有替身时，失败原因必须是**一句人话**，而不是让 App 只有「执行失败」。
 */

import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const {
  runBuiltinLs,
  builtinFor,
  runRunbook,
  describeRunFailure
} = await import('../../dsh-server-plugin/lib/runbook.mjs');

let dir = null;

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-ls-'));
  fs.mkdirSync(path.join(dir, 'work'));
  fs.writeFileSync(path.join(dir, 'README.md'), '# hi\n', 'utf8');
  fs.writeFileSync(path.join(dir, '.hidden'), 'x', 'utf8');
});

afterEach(() => {
  try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
});

describe('runbook: Windows 上的 ls 内置替身', () => {
  it('builtinFor 只在 win32 上把 ls 认成内置', () => {
    assert.equal(builtinFor(['ls', '-lt'], 'win32'), 'ls');
    assert.equal(builtinFor(['ls', '-lt'], 'linux'), null);
    // 别的命令照旧走真实执行器，不能被内置逻辑吞掉
    assert.equal(builtinFor(['git', 'status'], 'win32'), null);
  });

  it('默认模板那条 ls -lt 在 win32 上能出结果（不再 ENOENT）', async () => {
    // 关键断言：执行器**一次都不该被调用** —— 走了内置实现。
    let called = 0;
    const result = await runRunbook(dir, { argv: ['ls', '-lt'], outputTail: 20 }, {
      platform: 'win32',
      run: async () => { called += 1; return { ok: false, error: 'command-not-found' }; }
    });
    assert.equal(called, 0, 'win32 上 ls 不该 exec 任何进程');
    assert.equal(result.ok, true);
    assert.equal(result.exitCode, 0);
    assert.equal(result.builtin, 'ls');
    assert.match(result.outputTail, /README\.md/);
  });

  it('非 win32 仍然交给真实执行器', async () => {
    let argvSeen = null;
    const result = await runRunbook(dir, { argv: ['ls', '-lt'], outputTail: 20 }, {
      platform: 'linux',
      run: async (_cwd, spec) => { argvSeen = spec.argv; return { ok: true, exitCode: 0, stdout: 'work\nREADME.md\n' }; }
    });
    assert.deepEqual(argvSeen, ['ls', '-lt']);
    assert.equal(result.ok, true);
    assert.equal(result.builtin, null);
  });

  it('-l 打时间与大小，-a 才显示隐藏项', () => {
    const plain = runBuiltinLs(dir, ['ls']);
    const names = plain.stdout.trim().split('\n');
    assert.deepEqual(names, ['README.md', 'work/']);
    assert.ok(!plain.stdout.includes('.hidden'));

    const withAll = runBuiltinLs(dir, ['ls', '-a']);
    assert.ok(withAll.stdout.includes('.hidden'));

    const long = runBuiltinLs(dir, ['ls', '-l']);
    assert.match(long.stdout, /\d{4}-\d{2}-\d{2} \d{2}:\d{2}/);
    assert.match(long.stdout, /<DIR>/);
  });

  it('不认识的旗标必须报错，不能静默忽略', () => {
    const r = runBuiltinLs(dir, ['ls', '-lhS']);
    assert.equal(r.ok, false);
    assert.match(r.error, /不支持/);
  });

  it('目录不存在时说清楚是哪个目录', () => {
    const r = runBuiltinLs(dir, ['ls', 'no-such-dir']);
    assert.equal(r.ok, false);
    assert.match(r.error, /没有这个目录/);
  });

  it('结果条数有上限（手机端不做整盘搬运）', () => {
    for (let i = 0; i < 20; i++) fs.writeFileSync(path.join(dir, `f-${i}.txt`), 'x', 'utf8');
    const r = runBuiltinLs(dir, ['ls'], { maxEntries: 5 });
    assert.equal(r.truncated, true);
    assert.match(r.stdout, /还有 \d+ 项未显示/);
  });
});

describe('runbook: 失败原因要能读', () => {
  it('command-not-found 翻成人话，并且保留原始 code', async () => {
    const result = await runRunbook(dir, { argv: ['systemctl', 'status'], outputTail: 5 }, {
      platform: 'linux',
      run: async () => ({ ok: false, error: 'command-not-found' })
    });
    assert.equal(result.ok, false);
    assert.equal(result.error, 'command-not-found');
    assert.match(result.message, /找不到命令 systemctl/);
  });

  it('describeRunFailure 不会把未知原因说成成功', () => {
    assert.match(describeRunFailure({ error: 'run-failed' }, { argv: ['x'] }), /没有跑起来/);
    assert.equal(describeRunFailure({ error: 'timeout-ish' }, { argv: ['x'] }), 'timeout-ish');
  });
});
