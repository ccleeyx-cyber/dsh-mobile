// dsh-server-plugin Runbook（v1.35 / 任务 3.1）
//
// 「在外面用手机排障」的真实动作是：看日志尾、看服务状态、重启、回滚。
// 这些都不是自由文本能高效完成的——手机上打一行 `journalctl -u foo --since
// '10 min ago' | tail -50` 要三分钟，而且 `|` 在手机上根本打不出来。
//
// Runbook 把这类动作固化成一个**用户在电脑上写、在手机上一键执行**的清单。
// 安全边界（与 host-ops.mjs 同一条铁律）：
//
//   1. **绝不经过 shell**：命令字符串在这里切成 argv，任何 shell 元字符直接
//      拒绝。`|` `&&` `;` `>` `$(` 反引号都不接受 —— 需要管道的场景应当写进
//      脚本，而不是在 YAML 里拼接。
//   2. **可执行文件必须在白名单里**：默认只放行只读/排障类命令。用户要加
//      `docker` / `systemctl` 得自己改 DSH_RUNBOOK_ALLOW 或配置文件，改这个
//      动作本身就是一次显式授权。
//   3. **高危条目必须二次确认**：danger: high 会强制 confirmRequired，App 侧
//      把 confirm 字段传上来才执行。
//
// 测试全部注入假执行器，不跑真实命令（见 tests/unit/runbook.test.mjs）。

import fs from 'node:fs';

/**
 * 默认白名单：只读、排障、低破坏面。
 * 刻意不含 `rm` / `mv` / `chmod` / `kill` —— 这些应该走 Agent，不走一键按钮。
 */
export const DEFAULT_ALLOWED_BINARIES = Object.freeze([
  'git', 'ls', 'cat', 'tail', 'head', 'grep', 'wc', 'date', 'whoami', 'df', 'du', 'ps', 'pwd', 'echo'
]);

/** 默认模板：三条低危示例，用户可改可删。 */
export const DEFAULT_RUNBOOK_YAML = `# DSH Mobile Runbook
# 每条：name / command / danger(low|high) / confirmRequired / outputTail
# command 不要用管道、重定向或 && —— 需要组合逻辑请写成脚本再在这里调用。
runbooks:
  - name: 最近提交
    description: 当前仓库最近 10 条提交
    command: git log --oneline -n 10
    danger: low
    outputTail: 20

  - name: 工作区改动
    description: git status 简表
    command: git status --short
    danger: low
    outputTail: 40

  - name: 目录概览
    description: 当前目录最近修改的 15 个条目
    command: ls -lt
    danger: low
    outputTail: 20
`;

const SHELL_META = /[|&;<>`$(){}[\]*?!~]/;

/**
 * 把命令字符串切成 argv，并拒绝 shell 元字符。
 *
 * 只支持空格分隔与单/双引号包裹（引用内部允许空格）。这不是一个 shell：
 * 不做变量展开、不做通配、不做管道。
 */
export function tokenizeCommand(raw) {
  const text = String(raw ?? '').trim();
  if (!text) return { ok: false, error: 'command 为空' };
  if (SHELL_META.test(text)) {
    return { ok: false, error: 'command 含 shell 元字符（管道/重定向/连接符），请写成脚本' };
  }

  const argv = [];
  let cur = '';
  let quote = '';
  for (const ch of text) {
    if (quote) {
      if (ch === quote) quote = '';
      else cur += ch;
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; continue; }
    if (/\s/.test(ch)) {
      if (cur) { argv.push(cur); cur = ''; }
      continue;
    }
    cur += ch;
  }
  if (quote) return { ok: false, error: 'command 引号未闭合' };
  if (cur) argv.push(cur);
  if (argv.length === 0) return { ok: false, error: 'command 为空' };
  return { ok: true, argv };
}

function normalizeEntry(raw, index, allowed) {
  const where = `第 ${index + 1} 条`;
  if (!raw || typeof raw !== 'object') return { ok: false, error: `${where} 不是对象` };

  const name = String(raw.name ?? '').trim();
  if (!name) return { ok: false, error: `${where} 缺少 name` };

  const parsed = Array.isArray(raw.command)
    ? { ok: true, argv: raw.command.map(String) }
    : tokenizeCommand(raw.command);
  if (!parsed.ok) return { ok: false, error: `${name}：${parsed.error}` };
  if (parsed.argv.length === 0) return { ok: false, error: `${name}：command 为空` };

  const binary = parsed.argv[0];
  if (allowed && !allowed.includes(binary)) {
    return { ok: false, error: `${name}：命令 ${binary} 不在白名单（DSH_RUNBOOK_ALLOW 可扩展）` };
  }

  const danger = String(raw.danger ?? 'low').toLowerCase() === 'high' ? 'high' : 'low';
  const tail = Number(raw.outputTail);
  return {
    ok: true,
    entry: {
      id: String(raw.id ?? `rb_${index + 1}`),
      name,
      description: String(raw.description ?? '').trim(),
      argv: parsed.argv,
      command: parsed.argv.join(' '),
      danger,
      // 高危一律强制确认：不信任 YAML 里写的 false。
      confirmRequired: danger === 'high' ? true : raw.confirmRequired === true,
      outputTail: Number.isFinite(tail) ? Math.max(1, Math.min(200, Math.trunc(tail))) : 30
    }
  };
}

/**
 * 解析 Runbook 文档（`{ runbooks: [...] }` 或直接数组）。
 * @returns {{ok: true, entries: object[]} | {ok: false, error: string}}
 */
export function parseRunbooks(doc, { allowedBinaries = null } = {}) {
  const list = Array.isArray(doc) ? doc : (doc && Array.isArray(doc.runbooks) ? doc.runbooks : null);
  if (!list) return { ok: false, error: '缺少 runbooks 数组' };

  const entries = [];
  const errors = [];
  list.forEach((raw, i) => {
    const r = normalizeEntry(raw, i, allowedBinaries);
    if (r.ok) entries.push(r.entry);
    else errors.push(r.error);
  });
  if (entries.length === 0 && errors.length > 0) {
    return { ok: false, error: errors.join('；') };
  }
  return { ok: true, entries, errors };
}

/** 取文本末尾 n 行（超长输出只回摘要，避免手机端 payload 爆炸）。 */
export function tailLines(text, n = 30) {
  const lines = String(text ?? '').replace(/\r\n/g, '\n').split('\n');
  const keep = Math.max(1, Math.min(200, Number(n) || 30));
  const slice = lines.slice(-keep);
  return slice.join('\n');
}

/**
 * 执行一条 Runbook。执行器可注入（测试用），生产传 host-ops 的 runQuickCommand。
 *
 * 注意：`ok` 表示"没有环境级失败"；非零退出码仍然是 ok:true + 真实 exitCode ——
 * 手机端必须看到命令自己的输出，而不是桥接层编的"失败"。
 */
export async function runRunbook(cwd, entry, {
  run,
  timeoutMs = 20000,
  maxBytes = 256 * 1024
} = {}) {
  if (!entry) return { ok: false, error: 'unknown-runbook' };
  if (typeof run !== 'function') return { ok: false, error: 'no-executor' };

  const startedAt = Date.now();
  const result = await run(cwd, { argv: entry.argv }, { timeoutMs, maxBytes });
  const durationMs = Date.now() - startedAt;

  if (!result || result.ok !== true) {
    return {
      ok: false,
      error: result?.error || 'run-failed',
      exitCode: result?.exitCode ?? null,
      durationMs
    };
  }
  return {
    ok: true,
    exitCode: result.exitCode ?? 0,
    timedOut: result.timedOut === true,
    durationMs,
    outputTail: tailLines(result.stdout || result.stderr || '', entry.outputTail || 30),
    truncated: result.truncated === true
  };
}

/**
 * 读 Runbook 文件；不存在时写一份默认模板。
 *
 * `parseYaml` 由调用方注入（index.js 里已经有 yaml 依赖与兜底），本模块不直接
 * 依赖第三方包 —— 和 tunnel/tls 一样，保持零新增依赖。
 *
 * 每次请求都重新读（按 mtime 记忆化由调用方做）：用户改完 YAML 应当立刻生效，
 * 而不是"改了没反应、重启才看到"。
 */
export function loadRunbooksFile(file, { parseYaml, allowedBinaries = null } = {}) {
  try {
    if (!fs.existsSync(file)) {
      fs.mkdirSync(file.replace(/[\\/][^\\/]+$/, ''), { recursive: true });
      fs.writeFileSync(file, DEFAULT_RUNBOOK_YAML, 'utf8');
    }
    const text = fs.readFileSync(file, 'utf8');
    const doc = parseYaml(text);
    return parseRunbooks(doc, { allowedBinaries });
  } catch (err) {
    return { ok: false, error: `Runbook 读取失败：${err?.message || err}` };
  }
}

/** 白名单扩展：DSH_RUNBOOK_ALLOW="docker,systemctl"。 */
export function allowedBinariesFromEnv(env = process.env) {
  const extra = String(env.DSH_RUNBOOK_ALLOW || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  return [...new Set([...DEFAULT_ALLOWED_BINARIES, ...extra])];
}
