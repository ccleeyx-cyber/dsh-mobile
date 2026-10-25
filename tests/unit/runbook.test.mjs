/**
 * v1.35 / 3.1 — Runbook 指令库
 *
 * 全 hermetic：执行器注入���命令，不跑真实系统调用。
 *
 * 钉住的是安全边界，不是功能：
 *  - 管道/重定向/连接符必须拒绝（不做半吊子 shell）；
 *  - 白名单以外的二进制必须拒绝（`rm -rf` 不该是"一键按钮"）；
 *  - danger: high 必须强制确认，YAML 里写 false 也不算数；
 *  - 输出只回尾部 N 行（手机端 payload 有上限）。
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

const {
  tokenizeCommand,
  parseRunbooks,
  tailLines,
  runRunbook,
  DEFAULT_ALLOWED_BINARIES,
  DEFAULT_RUNBOOK_YAML
} = await import('../../dsh-server-plugin/lib/runbook.mjs');

describe('runbook: 命令解析', () => {
  it('简单命令切成 argv', () => {
    const r = tokenizeCommand('git status --short');
    assert.deepEqual(r, { ok: true, argv: ['git', 'status', '--short'] });
  });

  it('引号内的空格保留为一个参数', () => {
    const r = tokenizeCommand('git log --grep "fix: token"');
    assert.equal(r.ok, true);
    assert.deepEqual(r.argv, ['git', 'log', '--grep', 'fix: token']);
  });

  it('管道、重定向、连接符一律拒绝', () => {
    for (const bad of [
      'tail -n 50 app.log | grep ERROR',
      'cat a > b',
      'npm test && echo ok',
      'echo `whoami`',
      'echo $(id)',
      'ls *.log'
    ]) {
      const r = tokenizeCommand(bad);
      assert.equal(r.ok, false, `必须拒绝: ${bad}`);
    }
  });

  it('引号未闭合报错', () => {
    assert.equal(tokenizeCommand('git log --grep "oops').ok, false);
  });

  it('空命令报错', () => {
    assert.equal(tokenizeCommand('   ').ok, false);
  });
});

describe('runbook: 文档校验', () => {
  it('默认模板可以解析出三条低危条目', () => {
    // 用一个极简 YAML 解析替身：只为验证模板与 schema 的组合，不引入 yaml 依赖。
    const doc = {
      runbooks: [
        { name: '最近提交', command: 'git log --oneline -n 10', danger: 'low', outputTail: 20 },
        { name: '工作区改动', command: 'git status --short', danger: 'low', outputTail: 40 },
        { name: '目录概览', command: 'ls -lt', danger: 'low', outputTail: 20 }
      ]
    };
    const r = parseRunbooks(doc, { allowedBinaries: DEFAULT_ALLOWED_BINARIES });
    assert.equal(r.ok, true);
    assert.equal(r.entries.length, 3);
    assert.equal(r.entries[0].argv[0], 'git');
    assert.equal(r.entries[0].outputTail, 20);
    assert.ok(DEFAULT_RUNBOOK_YAML.includes('git status --short'));
  });

  it('白名单外的命令被拒绝', () => {
    const r = parseRunbooks({
      runbooks: [{ name: '删库', command: 'rm -rf /', danger: 'low' }]
    }, { allowedBinaries: DEFAULT_ALLOWED_BINARIES });
    assert.equal(r.ok, false);
    assert.match(r.error, /不在白名单/);
  });

  it('high 强制确认，即使 YAML 写 false', () => {
    const r = parseRunbooks({
      runbooks: [{ name: '重启服务', command: 'git gc', danger: 'high', confirmRequired: false }]
    }, { allowedBinaries: DEFAULT_ALLOWED_BINARIES });
    assert.equal(r.ok, true);
    assert.equal(r.entries[0].danger, 'high');
    assert.equal(r.entries[0].confirmRequired, true);
  });

  it('命令解释器默认禁止，配置了也不许伪装成 low', () => {
    const doc = {
      runbooks: [{
        name: '任意命令',
        // 数组形式绕过了 shell 元字符检查，所以必须单独管住解释器。
        command: ['C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe', '-Command', 'Get-Process'],
        danger: 'low'
      }]
    };
    const denied = parseRunbooks(doc, {
      allowedBinaries: [...DEFAULT_ALLOWED_BINARIES, 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe']
    });
    assert.equal(denied.ok, false);
    assert.match(denied.error, /解释器/);

    const low = parseRunbooks(doc, {
      allowedBinaries: [...DEFAULT_ALLOWED_BINARIES, 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'],
      allowInterpreters: true
    });
    assert.equal(low.ok, false);
    assert.match(low.error, /danger: high/);

    const allowed = parseRunbooks({
      runbooks: [{
        name: '显式授权',
        command: ['pwsh', '-NoProfile', '-Command', 'Get-Date'],
        danger: 'high'
      }]
    }, {
      allowedBinaries: [...DEFAULT_ALLOWED_BINARIES, 'pwsh'],
      allowInterpreters: true
    });
    assert.equal(allowed.ok, true);
    assert.equal(allowed.entries[0].danger, 'high');
    assert.equal(allowed.entries[0].confirmRequired, true);
  });

  it('low 可以显式要求确认', () => {
    const r = parseRunbooks({
      runbooks: [{ name: 'x', command: 'git status', danger: 'low', confirmRequired: true }]
    }, { allowedBinaries: DEFAULT_ALLOWED_BINARIES });
    assert.equal(r.entries[0].confirmRequired, true);
  });

  it('outputTail 被夹到 1..200', () => {
    const r = parseRunbooks({
      runbooks: [
        { name: 'a', command: 'date', outputTail: 0 },
        { name: 'b', command: 'date', outputTail: 9999 }
      ]
    }, { allowedBinaries: DEFAULT_ALLOWED_BINARIES });
    assert.equal(r.entries[0].outputTail >= 1, true);
    assert.equal(r.entries[1].outputTail <= 200, true);
  });

  it('坏条目跳过、好条目保留，并带回错误说明', () => {
    const r = parseRunbooks({
      runbooks: [
        { name: 'good', command: 'git status' },
        { name: '', command: 'git status' },
        { name: 'bad', command: 'tail -f x | grep y' }
      ]
    }, { allowedBinaries: DEFAULT_ALLOWED_BINARIES });
    assert.equal(r.ok, true);
    assert.equal(r.entries.length, 1);
    assert.equal(r.entries[0].name, 'good');
    assert.equal(r.errors.length, 2);
  });

  it('全坏时整体失败', () => {
    const r = parseRunbooks({ runbooks: [{ name: 'x' }] }, { allowedBinaries: DEFAULT_ALLOWED_BINARIES });
    assert.equal(r.ok, false);
  });

  it('缺 runbooks 数组报错', () => {
    assert.equal(parseRunbooks({ nope: [] }).ok, false);
  });
});

describe('runbook: 执行与输出', () => {
  it('尾部截断只保留 N 行', () => {
    const text = Array.from({ length: 100 }, (_, i) => `line-${i}`).join('\n');
    const out = tailLines(text, 5);
    assert.equal(out.split('\n').length, 5);
    assert.equal(out.split('\n').at(-1), 'line-99');
  });

  it('CRLF 归一后再截断', () => {
    assert.equal(tailLines('a\r\nb\r\nc', 2), 'b\nc');
  });

  it('非零退出码仍是 ok:true，手机要看到命令自己的输出', async () => {
    const entry = { argv: ['git', 'status'], outputTail: 10, danger: 'low' };
    const r = await runRunbook('/tmp', entry, {
      run: async () => ({ ok: true, exitCode: 128, stdout: 'fatal: not a git repository\n', stderr: '' })
    });
    assert.equal(r.ok, true);
    assert.equal(r.exitCode, 128);
    assert.match(r.outputTail, /not a git repository/);
  });

  it('执行器环境失败时回结构化错误', async () => {
    const r = await runRunbook('/tmp', { argv: ['git'], outputTail: 5 }, {
      run: async () => ({ ok: false, error: 'command-not-found' })
    });
    assert.equal(r.ok, false);
    assert.equal(r.error, 'command-not-found');
  });

  it('没有执行器时不假装成功', async () => {
    const r = await runRunbook('/tmp', { argv: ['git'], outputTail: 5 });
    assert.equal(r.ok, false);
    assert.equal(r.error, 'no-executor');
  });

  it('缺条目时报 unknown-runbook', async () => {
    const r = await runRunbook('/tmp', null, { run: async () => ({ ok: true, exitCode: 0 }) });
    assert.equal(r.error, 'unknown-runbook');
  });
});
