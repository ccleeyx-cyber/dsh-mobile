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
import path from 'node:path';

/**
 * 默认白名单：只读、排障、低破坏面。
 * 刻意不含 `rm` / `mv` / `chmod` / `kill` —— 这些应该走 Agent，不走一键按钮。
 */
export const DEFAULT_ALLOWED_BINARIES = Object.freeze([
  'git', 'ls', 'cat', 'tail', 'head', 'grep', 'wc', 'date', 'whoami', 'df', 'du', 'ps', 'pwd', 'echo'
]);

/**
 * 默认模板：三条低危示例，用户可改可删。
 *
 * ⚠️ 模板里故意保留 `ls -lt`（POSIX 写法）而不是为 Windows 换成别的命令：
 * 见下面的 `runBuiltin`。模板是**跨平台共用**的一份文本，用户在两台机器之间
 * 同步同一份 runbooks.yaml 时不该看到命令被平台改写。
 */
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

/* ------------------------------------------------------------------ *
 * 内置替身（Windows）：白名单里的 POSIX 命令在 Windows 上压根不存在
 * ------------------------------------------------------------------ */

/**
 * 哪些命令需要内置替身。
 *
 * 背景（真机实测）：默认模板第三条「目录概览」是 `ls -lt`，而网关跑在 Windows
 * 上，`execFile('ls')` 直接 ENOENT —— runRunbook 如实回 `command-not-found`，
 * 手机端只显示「执行失败」。用户没有任何办法从屏幕上看出"这台机器没有 ls"，
 * 于是这条**出厂自带**的条目在 Windows 上是一条永远失败的按钮。
 *
 * 三种修法里选了第三种：
 *   1. 模板按平台改写 —— 用户已有的 runbooks.yaml 不会跟着变，等于没修；
 *   2. 让用户改用 `dir` —— 但 `dir` 是 cmd 内建，必须开 shell，违反本模块铁律；
 *   3. **网关里用 fs 实现一份只读的 ls** —— 不开 shell、不动用户文件、已有 YAML
 *      原样生效。这里就是第 3 种。
 *
 * 只做只读动作：不删、不改、不跟随符号链接去写。输出有上限。
 */
const BUILTIN_BINARIES = Object.freeze({
  ls: { label: 'ls', help: 'ls [-l] [-t] [-r] [-a] [目录]' }
});

/** 内置 ls 的输出上限：手机端只需要一屏概览，不是把整盘目录搬过去。 */
const BUILTIN_LS_MAX_ENTRIES = 300;

function pad2(n) {
  return String(n).padStart(2, '0');
}

/** `YYYY-MM-DD HH:mm` —— 与 `ls -lt` 的时间列可读性相当，且不依赖 locale。 */
function formatStamp(ms) {
  const d = new Date(Number(ms) || 0);
  if (Number.isNaN(d.getTime())) return '????-??-?? ??:??';
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/**
 * 解析 `ls` 的参数。
 *
 * 刻意只认 `-l/-t/-r/-a`：**不认识的旗标必须报错**，而不是被静默忽略。静默
 * 忽略会让 `ls -lhS` 看起来成功了、实际只按名字排 —— 用户以为看到了按大小排序
 * 的结果，那是谎报。
 */
function parseLsArgs(argv) {
  const rest = argv.slice(1);
  const flags = { long: false, byTime: false, reverse: false, all: false };
  let target = '';
  for (const arg of rest) {
    if (arg.startsWith('-') && arg !== '-') {
      for (const ch of arg.slice(1)) {
        if (ch === 'l') flags.long = true;
        else if (ch === 't') flags.byTime = true;
        else if (ch === 'r') flags.reverse = true;
        else if (ch === 'a') flags.all = true;
        else if (ch === '1') { /* 单列输出，内置本来就单列 */ }
        else return { ok: false, error: `ls 不支持的旗标 -${ch}（内置替身支持 -l -t -r -a）` };
      }
      continue;
    }
    if (target) return { ok: false, error: 'ls 只支持一个目录参数' };
    target = arg;
  }
  return { ok: true, flags, target };
}

/**
 * Windows 上 `ls` 的内置实现（只读）。
 *
 * @param cwd - 相对目录参数的基准（会话工作区）。
 * @param argv - 已经过 tokenizeCommand 的 argv，argv[0] === 'ls'。
 * @returns 与 runQuickCommand 同形状的结果对象，另带 `builtin: 'ls'`。
 */
export function runBuiltinLs(cwd, argv, { maxEntries = BUILTIN_LS_MAX_ENTRIES } = {}) {
  const startedAt = Date.now();
  const parsed = parseLsArgs(Array.isArray(argv) ? argv : []);
  if (!parsed.ok) return { ok: false, error: parsed.error, builtin: 'ls', durationMs: Date.now() - startedAt };

  const target = parsed.target ? path.resolve(String(cwd || '.'), parsed.target) : path.resolve(String(cwd || '.'));
  let stat;
  try {
    stat = fs.statSync(target);
  } catch (err) {
    return {
      ok: false,
      error: err?.code === 'ENOENT' ? `没有这个目录：${target}` : `读不了这个目录：${err?.message || err}`,
      builtin: 'ls',
      durationMs: Date.now() - startedAt
    };
  }
  if (!stat.isDirectory()) {
    // `ls <文件>` 就是打出这个文件名 —— 和真 ls 一致，不要报错。
    return {
      ok: true,
      exitCode: 0,
      stdout: parsed.flags.long
        ? `${formatStamp(stat.mtimeMs)} ${String(stat.size).padStart(10)} ${path.basename(target)}\n`
        : `${path.basename(target)}\n`,
      stderr: '',
      truncated: false,
      timedOut: false,
      builtin: 'ls',
      durationMs: Date.now() - startedAt
    };
  }

  let dirents;
  try {
    dirents = fs.readdirSync(target, { withFileTypes: true });
  } catch (err) {
    const code = err?.code;
    const reason = code === 'EACCES' || code === 'EPERM' ? '没有权限读这个目录' : `读不了这个目录：${err?.message || err}`;
    return { ok: false, error: reason, builtin: 'ls', durationMs: Date.now() - startedAt };
  }

  const rows = [];
  for (const dirent of dirents) {
    const name = dirent.name;
    if (!parsed.flags.all && name.startsWith('.')) continue;
    const full = path.join(target, name);
    let kind = 'file';
    let size = 0;
    let mtimeMs = 0;
    try {
      const st = fs.lstatSync(full);
      // 符号链接不跟随：概览里它是什么就写什么，跟随会让人以为链接指向的内容
      // 就在这个目录里。
      kind = st.isSymbolicLink() ? 'link' : (st.isDirectory() ? 'dir' : 'file');
      size = st.size;
      mtimeMs = st.mtimeMs;
    } catch {
      kind = 'unknown';
    }
    rows.push({ name, kind, size, mtimeMs });
  }

  rows.sort((a, b) => {
    if (parsed.flags.byTime && a.mtimeMs !== b.mtimeMs) return b.mtimeMs - a.mtimeMs;
    return a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
  });
  if (parsed.flags.reverse) rows.reverse();

  const shown = rows.slice(0, Math.max(1, Math.min(Number(maxEntries) || BUILTIN_LS_MAX_ENTRIES, 2000)));
  const lines = shown.map((r) => {
    const suffix = r.kind === 'dir' ? '/' : (r.kind === 'link' ? '@' : '');
    if (!parsed.flags.long) return `${r.name}${suffix}`;
    const kindCol = r.kind === 'dir' ? '   <DIR>' : (r.kind === 'link' ? '   <LNK>' : String(r.size).padStart(10));
    return `${formatStamp(r.mtimeMs)} ${kindCol}  ${r.name}${suffix}`;
  });
  if (rows.length > shown.length) {
    lines.push(`…（还有 ${rows.length - shown.length} 项未显示）`);
  }

  return {
    ok: true,
    exitCode: 0,
    stdout: lines.length ? `${lines.join('\n')}\n` : '',
    stderr: '',
    truncated: rows.length > shown.length,
    timedOut: false,
    builtin: 'ls',
    durationMs: Date.now() - startedAt
  };
}

/** 这台平台上哪些白名单命令需要内置替身（目前只有 Windows 上的 ls）。 */
export function builtinFor(argv, platform = process.platform) {
  if (!Array.isArray(argv) || argv.length === 0) return null;
  const binary = String(argv[0] || '').toLowerCase();
  if (platform === 'win32' && binary === 'ls') return 'ls';
  return null;
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
 *
 * 平台自适应：Windows 上 POSIX 命令不存在（`ls` → ENOENT），此时改用内置只读
 * 替身，`builtin: 'ls'` 会回给调用方，手机端据此说明"这是网关内置实现"。
 * [platform] 只为测试注入，生产走 `process.platform`。
 */
export async function runRunbook(cwd, entry, {
  run,
  timeoutMs = 20000,
  maxBytes = 256 * 1024,
  platform = process.platform
} = {}) {
  if (!entry) return { ok: false, error: 'unknown-runbook' };
  if (typeof run !== 'function') return { ok: false, error: 'no-executor' };

  const startedAt = Date.now();
  const builtin = builtinFor(entry.argv, platform);
  const result = builtin === 'ls'
    ? runBuiltinLs(cwd, entry.argv, { maxEntries: 300 })
    : await run(cwd, { argv: entry.argv }, { timeoutMs, maxBytes });
  const durationMs = Date.now() - startedAt;

  if (!result || result.ok !== true) {
    return {
      ok: false,
      // 失败原因要能被人读懂：`command-not-found` 单独给出人话，否则手机端只有
      // 一句「执行失败」，用户不知道是命令不存在还是目录不对。
      error: result?.error || 'run-failed',
      message: describeRunFailure(result, entry),
      builtin: result?.builtin || null,
      exitCode: result?.exitCode ?? null,
      durationMs
    };
  }
  return {
    ok: true,
    exitCode: result.exitCode ?? 0,
    timedOut: result.timedOut === true,
    durationMs,
    builtin: result.builtin || null,
    outputTail: tailLines(result.stdout || result.stderr || '', entry.outputTail || 30),
    truncated: result.truncated === true
  };
}

/** 把执行失败翻译成一句能给用户看的话（保留原始 code，不替换它）。 */
export function describeRunFailure(result, entry) {
  const code = String(result?.error || 'run-failed');
  const binary = Array.isArray(entry?.argv) ? String(entry.argv[0] || '') : '';
  if (code === 'command-not-found') {
    return process.platform === 'win32'
      ? `电脑上找不到命令 ${binary}（Windows 没有它；可以把 command 换成网关内置支持的写法，例如 ls）`
      : `电脑上找不到命令 ${binary}`;
  }
  if (code === 'run-failed') return '命令没有跑起来（执行器没有返回结果）';
  return code;
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
