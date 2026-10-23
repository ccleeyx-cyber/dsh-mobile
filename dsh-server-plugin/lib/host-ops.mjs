/**
 * Host-side primitives for the bridge extensions (P0/P1, 2026-10-13):
 * read-only workspace browsing, a strictly whitelisted command panel, git-repo
 * discovery, and deliverable content typing.
 *
 * Design rules that this module exists to enforce:
 *
 *  1. **No shell, ever.** Every command is a server-owned `argv` array handed to
 *     `execFile`. The client sends an *id*; it can never contribute a byte of
 *     argv, a redirection, or a separator. That is what keeps a phone — which
 *     may itself be compromised — from turning this into a remote shell.
 *  2. **Confinement is proved, not filtered.** A requested path is resolved and
 *     then `realpath`ed; the real path must still sit inside the real session
 *     working directory. String-level `..` rejection alone loses to symlinks,
 *     8.3 short names and Windows device paths, so it is only layer one.
 *  3. **Every read is capped.** A phone on a train must never be handed a 2 GB
 *     file or a 400 000-entry directory; each limit below is explicit and the
 *     truncation is reported rather than hidden.
 *  4. **Pure where it counts.** Everything here takes its cwd and its limits as
 *     arguments, so unit tests drive all of it with no engine and no gateway.
 */
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

/* ------------------------------------------------------------------ *
 * 1. Path confinement
 * ------------------------------------------------------------------ */

/** Windows/macOS compare case-insensitively; Linux does not. */
const CASE_INSENSITIVE_FS = process.platform === 'win32' || process.platform === 'darwin';

/**
 * Canonicalise a path for comparison, without requiring it to exist.
 *
 * `fs.realpathSync` throws on a missing path, but a *new* file the agent just
 * created has a real path only after it exists — and we must still be able to
 * authorise it. So: realpath the deepest existing ancestor, then re-append the
 * non-existent tail. Without this, a legitimately listed but not-yet-flushed
 * file would be refused as an escape.
 */
function canonicalize(target) {
  let current = path.resolve(target);
  const tail = [];
  for (let depth = 0; depth < 64; depth += 1) {
    try {
      const real = fs.realpathSync.native
        ? fs.realpathSync.native(current)
        : fs.realpathSync(current);
      return tail.length ? path.join(real, ...tail.reverse()) : real;
    } catch {
      const parent = path.dirname(current);
      if (parent === current) break; // filesystem root
      tail.push(path.basename(current));
      current = parent;
    }
  }
  return path.resolve(target);
}

/** True when `child` is `parent` itself or sits underneath it. */
export function isInside(parent, child) {
  const a = canonicalize(parent);
  const b = canonicalize(child);
  if (a === b) return true;
  const sep = path.sep;
  const prefix = a.endsWith(sep) ? a : a + sep;
  return CASE_INSENSITIVE_FS
    ? b.toLowerCase().startsWith(prefix.toLowerCase())
    : b.startsWith(prefix);
}

/**
 * Resolve one client-supplied relative path against the session working
 * directory, refusing anything that escapes it.
 *
 * @param cwd - the session working directory (absolute, from the projection
 *   cache). A missing cwd is a hard refusal: there is nothing to confine to.
 * @param requested - relative path from the client. Empty means the root.
 * @param options.allowMissing - permit a target that does not exist yet (the
 *   file browser only ever reads, so callers pass false).
 * @returns `{ ok: true, abs, rel }` or `{ ok: false, status, error }`.
 */
export function resolveConfined(cwd, requested, { allowMissing = false } = {}) {
  if (typeof cwd !== 'string' || !cwd.trim()) {
    return { ok: false, status: 409, error: 'no-workspace' };
  }
  const base = path.resolve(cwd);
  const raw = typeof requested === 'string' ? requested.trim() : '';

  // Layer 1 — reject the shapes that make a later comparison lie.
  // NUL and control bytes can truncate a path inside a syscall; an
  // extended-length / device prefix (`\\?\`, `\\.\`) makes the filesystem open
  // something the string comparison never saw.
  // eslint-disable-next-line no-control-regex
  if (/[\x00-\x1f]/.test(raw)) {
    return { ok: false, status: 400, error: 'control character in path' };
  }
  if (/^\\\\[?.]\\/.test(raw)) {
    return { ok: false, status: 403, error: 'device or extended-length path refused' };
  }
  if (path.isAbsolute(raw) || raw.startsWith('/') || raw.startsWith('\\') || /^[A-Za-z]:/.test(raw)) {
    return { ok: false, status: 403, error: 'absolute path refused; paths are session-relative' };
  }

  const abs = raw ? path.resolve(base, raw) : base;

  // Layer 2 — prove the resolved target (and, when it exists, its real path)
  // is inside the session workspace.
  if (!isInside(base, abs)) {
    return { ok: false, status: 403, error: 'path escapes the session workspace' };
  }

  let stat = null;
  try {
    stat = fs.lstatSync(abs);
  } catch {
    stat = null;
  }
  if (!stat && !allowMissing) {
    return { ok: false, status: 404, error: 'not found' };
  }
  if (stat?.isSymbolicLink()) {
    // A symlink is followed only if its target also lands inside the workspace;
    // otherwise it is exactly the escape route layer 2 is here to stop.
    let target;
    try {
      target = fs.readlinkSync(abs);
    } catch {
      return { ok: false, status: 403, error: 'unreadable symlink refused' };
    }
    const resolved = path.resolve(path.dirname(abs), target);
    if (!isInside(base, resolved)) {
      return { ok: false, status: 403, error: 'symlink target escapes the session workspace' };
    }
  }

  const rel = path.relative(base, abs).split(path.sep).join('/');
  return { ok: true, abs, rel: rel || '' };
}

/* ------------------------------------------------------------------ *
 * 2. Read-only directory listing
 * ------------------------------------------------------------------ */

const DEFAULT_MAX_ENTRIES = 400;

/** Extensions we are willing to inline-render on a phone as text. */
const TEXT_EXTENSIONS = new Set([
  '.txt', '.md', '.markdown', '.json', '.jsonc', '.yaml', '.yml', '.toml', '.ini', '.cfg',
  '.csv', '.tsv', '.log', '.xml', '.html', '.htm', '.css', '.scss', '.less',
  '.js', '.mjs', '.cjs', '.jsx', '.ts', '.tsx', '.dart', '.py', '.rb', '.go', '.rs',
  '.java', '.kt', '.kts', '.c', '.h', '.cc', '.cpp', '.hpp', '.cs', '.php', '.swift',
  '.sh', '.bash', '.zsh', '.ps1', '.psm1', '.bat', '.cmd', '.sql', '.gradle', '.properties',
  '.env', '.gitignore', '.gitattributes', '.editorconfig', '.lock', '.diff', '.patch', '.vue', '.svelte'
]);

/** Content types for the extensions a phone can actually preview inline. */
const CONTENT_TYPES = new Map([
  ['.md', 'text/markdown; charset=utf-8'],
  ['.markdown', 'text/markdown; charset=utf-8'],
  ['.txt', 'text/plain; charset=utf-8'],
  ['.log', 'text/plain; charset=utf-8'],
  ['.csv', 'text/csv; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.jsonc', 'application/json; charset=utf-8'],
  ['.xml', 'application/xml; charset=utf-8'],
  ['.html', 'text/html; charset=utf-8'],
  ['.htm', 'text/html; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.mjs', 'text/javascript; charset=utf-8'],
  ['.pdf', 'application/pdf'],
  ['.png', 'image/png'],
  ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'],
  ['.gif', 'image/gif'],
  ['.webp', 'image/webp'],
  ['.bmp', 'image/bmp'],
  ['.svg', 'image/svg+xml']
]);

/** Best-effort content type from a filename. Never trusted for execution. */
export function contentTypeFor(fileName) {
  const ext = path.extname(String(fileName || '')).toLowerCase();
  return CONTENT_TYPES.get(ext) || null;
}

/** True when a phone can render this file as text rather than only download it. */
export function isTextLike(fileName, sample = null) {
  const ext = path.extname(String(fileName || '')).toLowerCase();
  if (TEXT_EXTENSIONS.has(ext)) return true;
  const base = path.basename(String(fileName || '')).toLowerCase();
  // Extensionless but conventionally textual files (Dockerfile, Makefile, LICENSE…).
  if (!ext && /^(dockerfile|makefile|license|notice|readme|changelog|authors)$/.test(base)) return true;
  if (typeof sample === 'string' && sample.length > 0) {
    // A NUL byte in the first KB is the same heuristic git uses.
    return !sample.includes('\0');
  }
  return false;
}

/**
 * One directory's entries, sorted directories-first then case-insensitively.
 *
 * @param absDir - absolute directory to list (caller already confined it).
 * @param options.maxEntries - hard cap on returned rows.
 * @returns `{ ok, entries, truncated, total }`; `ok:false` carries a plain
 *   reason string, never a raw filesystem error (that would leak host paths).
 */
export function listDirectory(absDir, { maxEntries = DEFAULT_MAX_ENTRIES } = {}) {
  let dirents;
  try {
    dirents = fs.readdirSync(absDir, { withFileTypes: true });
  } catch (err) {
    const code = err?.code;
    if (code === 'ENOENT') return { ok: false, reason: 'not-found', entries: [], truncated: false, total: 0 };
    if (code === 'ENOTDIR') return { ok: false, reason: 'not-a-directory', entries: [], truncated: false, total: 0 };
    if (code === 'EACCES' || code === 'EPERM') return { ok: false, reason: 'permission-denied', entries: [], truncated: false, total: 0 };
    return { ok: false, reason: 'unreadable', entries: [], truncated: false, total: 0 };
  }

  const rows = [];
  for (const dirent of dirents) {
    const full = path.join(absDir, dirent.name);
    let kind = 'other';
    let size = null;
    let mtime = null;
    try {
      // `withFileTypes` already told us the cheap answer; a symlink needs one
      // more lookup to be honest about what the entry points at.
      if (dirent.isDirectory()) kind = 'dir';
      else if (dirent.isFile()) kind = 'file';
      else if (dirent.isSymbolicLink()) {
        const st = fs.statSync(full);
        kind = st.isDirectory() ? 'dir' : (st.isFile() ? 'file' : 'other');
      }
      if (kind === 'file') {
        const st = fs.statSync(full);
        size = st.size;
        mtime = Math.floor(st.mtimeMs);
      }
    } catch {
      // A broken symlink or a racing delete: list it as `other` rather than
      // dropping it, so the phone's view matches what `ls` would show.
    }
    rows.push({ name: dirent.name, kind, size, mtime });
  }

  rows.sort((a, b) => {
    if ((a.kind === 'dir') !== (b.kind === 'dir')) return a.kind === 'dir' ? -1 : 1;
    return a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
  });

  const truncated = rows.length > maxEntries;
  return {
    ok: true,
    entries: truncated ? rows.slice(0, maxEntries) : rows,
    truncated,
    total: rows.length
  };
}

const DEFAULT_MAX_READ_BYTES = 256 * 1024;

/**
 * Read a text file, capped.
 *
 * Returns `binary: true` (and no content) when the file is not text, so the
 * phone offers a download instead of rendering mojibake.
 */
export function readTextFile(absFile, { maxBytes = DEFAULT_MAX_READ_BYTES } = {}) {
  let stat;
  try {
    stat = fs.statSync(absFile);
  } catch (err) {
    const code = err?.code;
    if (code === 'ENOENT') return { ok: false, reason: 'not-found' };
    if (code === 'EACCES' || code === 'EPERM') return { ok: false, reason: 'permission-denied' };
    return { ok: false, reason: 'unreadable' };
  }
  if (!stat.isFile()) return { ok: false, reason: 'not-a-file' };

  const cap = Math.max(1024, Math.min(Number(maxBytes) || DEFAULT_MAX_READ_BYTES, 1024 * 1024));
  const readSize = Math.min(stat.size, cap);

  let buffer;
  try {
    const fd = fs.openSync(absFile, 'r');
    try {
      buffer = Buffer.alloc(readSize);
      fs.readSync(fd, buffer, 0, readSize, 0);
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return { ok: false, reason: 'unreadable' };
  }

  // Sniff on the first 8 KB only: a NUL byte there means binary, the same rule
  // git uses, and it keeps a legitimately huge log from being scanned twice.
  const sample = buffer.subarray(0, Math.min(buffer.length, 8192)).toString('utf8');
  if (!isTextLike(absFile, sample)) {
    return { ok: true, binary: true, size: stat.size, mtime: Math.floor(stat.mtimeMs) };
  }

  return {
    ok: true,
    binary: false,
    content: buffer.toString('utf8'),
    size: stat.size,
    readBytes: buffer.length,
    truncated: stat.size > buffer.length,
    mtime: Math.floor(stat.mtimeMs)
  };
}

/* ------------------------------------------------------------------ *
 * 2b. Directory picker for "new workspace"
 * ------------------------------------------------------------------ *
 *
 * 与第 2 节的区别是**范围**：`listDirectory` 只服务于会话工作区内的只读浏览
 * （`resolveConfined` 会拒绝任何绝对路径）。"新建工作区"要选的恰恰是**还没成为
 * 工作区**的目录，所以它必须在工作区之外也能看 —— 但绝不能变成"整盘随便读"。
 *
 * 边界由调用方显式给的一组 **roots** 决定：只有落在这几个根里的路径才允许列出，
 * 且只列**子目录名**（不读文件内容、不回大小以外的任何信息）。roots 本身由网关
 * 从"主目录 + 已登记工作区 + 它们所在的盘"算出来，客户端无法扩面。
 */

/** 判断 `target` 是否落在 roots 里任意一个根之内（每个 root 都是一个包含关系）。 */
export function isUnderAnyRoot(roots, target) {
  if (!Array.isArray(roots) || roots.length === 0) return false;
  for (const root of roots) {
    if (typeof root !== 'string' || !root.trim()) continue;
    if (isInside(root, target)) return true;
  }
  return false;
}

/**
 * 只列子目录（给目录选择器用）。
 *
 * 刻意不返回文件：这个接口的用途是"选一个目录当工作区"，把文件也塞进来只会让
 * 手机上多出一堆点不动的行，并且顺带把文件名泄露给设备。
 *
 * @param absDir - 绝对目录（调用方已用它做 roots 校验）。
 * @param options.maxEntries - 返回行数上限。
 * @param options.skipHidden - 跳过 `.` 开头的目录（默认 true）。
 * @returns `{ ok, dirs, truncated, total }` 或 `{ ok:false, reason }`。
 */
export function listSubdirectories(absDir, { maxEntries = 300, skipHidden = true } = {}) {
  let dirents;
  try {
    dirents = fs.readdirSync(absDir, { withFileTypes: true });
  } catch (err) {
    const code = err?.code;
    if (code === 'ENOENT') return { ok: false, reason: 'not-found', dirs: [], truncated: false, total: 0 };
    if (code === 'ENOTDIR') return { ok: false, reason: 'not-a-directory', dirs: [], truncated: false, total: 0 };
    if (code === 'EACCES' || code === 'EPERM') return { ok: false, reason: 'permission-denied', dirs: [], truncated: false, total: 0 };
    return { ok: false, reason: 'unreadable', dirs: [], truncated: false, total: 0 };
  }

  const rows = [];
  for (const dirent of dirents) {
    if (skipHidden && dirent.name.startsWith('.')) continue;
    let isDir = dirent.isDirectory();
    if (!isDir && dirent.isSymbolicLink()) {
      // 指向目录的链接是可以当工作区用的，但真实的类型必须一次 stat 确认。
      try { isDir = fs.statSync(path.join(absDir, dirent.name)).isDirectory(); } catch { isDir = false; }
    }
    if (!isDir) continue;
    rows.push({ name: dirent.name, path: path.join(absDir, dirent.name) });
  }

  rows.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }));
  const cap = Math.max(1, Math.min(Number(maxEntries) || 300, 2000));
  return {
    ok: true,
    dirs: rows.length > cap ? rows.slice(0, cap) : rows,
    truncated: rows.length > cap,
    total: rows.length
  };
}

/** Windows 上仍存在的盘符根（`C:\`、`D:\` …），用于给选择器提供起点。 */
export function existingDriveRoots(platform = process.platform) {
  if (platform !== 'win32') return ['/'];
  const out = [];
  for (let i = 65; i <= 90; i += 1) {
    const drive = `${String.fromCharCode(i)}:\\`;
    try { if (fs.existsSync(drive)) out.push(drive); } catch { /* 忽略不可读盘符 */ }
  }
  return out;
}

/* ------------------------------------------------------------------ *
 * 3. Git repository discovery
 * ------------------------------------------------------------------ */
const DEFAULT_MAX_REPO_CANDIDATES = 12;

/** True when `dir` is the root of a repository (worktrees use a `.git` file). */
function hasGitDir(dir) {
  try {
    return fs.existsSync(path.join(dir, '.git'));
  } catch {
    return false;
  }
}

/**
 * Find the repository a session workspace belongs to, or the ones it contains.
 *
 * Why this exists: a session may run with its cwd at a folder that is *not*
 * itself a repository but whose children are (measured here: `E:\workspace\个人`
 * holds `dsh_mobile`, `GZ`, `tickflow-stock-panel`, …). The old behaviour was a
 * flat `not-a-git-repository` refusal, which left the phone's diff panel
 * permanently empty for exactly those multi-project workspaces.
 *
 * Order of preference: an ancestor repository (the cwd is inside one), then the
 * cwd itself, then immediate children. `primaryRoot` is what the caller should
 * actually run git in.
 *
 * @returns `{ primaryRoot, self, ancestors, children }` — `primaryRoot` is null
 *   when no repository was found at all.
 */
export function discoverGitRepos(cwd, { maxCandidates = DEFAULT_MAX_REPO_CANDIDATES } = {}) {
  const base = path.resolve(cwd);
  const out = { primaryRoot: null, self: false, ancestors: [], children: [] };
  if (hasGitDir(base)) {
    out.self = true;
    out.primaryRoot = base;
    return out;
  }

  // Walk up: a cwd of `<repo>/src/lib` still belongs to `<repo>`.
  let cursor = path.dirname(base);
  for (let depth = 0; depth < 32; depth += 1) {
    if (cursor === path.dirname(cursor)) break; // filesystem root
    if (!isInside(cursor, base)) break;
    if (hasGitDir(cursor)) {
      out.ancestors.push(cursor);
      if (!out.primaryRoot) out.primaryRoot = cursor;
    }
    cursor = path.dirname(cursor);
  }

  // Immediate children: the multi-project workspace case.
  let dirents = [];
  try {
    dirents = fs.readdirSync(base, { withFileTypes: true });
  } catch {
    dirents = [];
  }
  for (const dirent of dirents) {
    if (out.children.length >= maxCandidates) break;
    if (!dirent.isDirectory()) continue;
    if (dirent.name === 'node_modules' || dirent.name.startsWith('.')) continue;
    const full = path.join(base, dirent.name);
    if (hasGitDir(full)) out.children.push({ name: dirent.name, path: full });
  }

  if (!out.primaryRoot && out.children.length > 0) out.primaryRoot = out.children[0].path;
  return out;
}

/* ------------------------------------------------------------------ *
 * 4. Whitelisted command panel
 * ------------------------------------------------------------------ */

const DEFAULT_COMMAND_TIMEOUT_MS = 12000;
const DEFAULT_COMMAND_MAX_BYTES = 64 * 1024;

/**
 * The entire command surface the phone may trigger.
 *
 * Every entry is a fixed `argv` array. There is deliberately **no** entry that
 * takes a client-supplied argument — the safest parameter is the one that does
 * not exist. `danger` marks commands that mutate the workspace, so the App can
 * gate them behind an explicit confirmation; git's read-only verbs are safe by
 * construction.
 *
 * `shell: true` is used for exactly two entries, both with a *constant* script
 * that contains no interpolated value. That is the only reason it is allowed.
 */
export const QUICK_COMMANDS = [
  {
    id: 'git-status',
    label: 'Git 状态',
    group: 'git',
    description: '当前分支与工作区改动（porcelain，便于阅读）',
    argv: ['git', 'status', '--porcelain=v1', '--branch'],
    danger: false
  },
  {
    id: 'git-log',
    label: '最近提交',
    group: 'git',
    description: '最近 20 条提交（单行）',
    argv: ['git', 'log', '--oneline', '-n', '20'],
    danger: false
  },
  {
    id: 'git-branch',
    label: '分支列表',
    group: 'git',
    description: '本地分支与当前分支',
    argv: ['git', 'branch', '--list', '--no-color'],
    danger: false
  },
  {
    id: 'git-diff-stat',
    label: '改动统计',
    group: 'git',
    description: '相对 HEAD 的每文件增删行数',
    argv: ['git', 'diff', '--stat', 'HEAD'],
    danger: false
  },
  {
    id: 'git-stash-list',
    label: 'Stash 列表',
    group: 'git',
    description: '当前仓库的 stash 栈',
    argv: ['git', 'stash', 'list'],
    danger: false
  },
  {
    id: 'git-remote',
    label: '远程仓库',
    group: 'git',
    description: '已配置的 remote 与地址',
    argv: ['git', 'remote', '-v'],
    danger: false
  },
  {
    id: 'git-fetch-dry-run',
    label: '预演拉取',
    group: 'git',
    description: '只报告会被拉取的内容，不修改本地分支',
    argv: ['git', 'fetch', '--dry-run', '--all'],
    danger: false
  },
  {
    id: 'dir-tree',
    label: '目录结构',
    group: 'fs',
    description: '工作区顶层两级的目录树（忽略 .git 与 node_modules）',
    argv: ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
    danger: false
  },
  {
    id: 'disk-free',
    label: '磁盘剩余',
    group: 'host',
    description: '各盘符的已用 / 剩余空间',
    // Constant script: nothing from the client reaches it.
    argv: ['pwsh', '-NoProfile', '-NonInteractive', '-Command',
      'Get-PSDrive -PSProvider FileSystem | Select-Object Name,@{n="UsedGB";e={[math]::Round($_.Used/1GB,2)}},@{n="FreeGB";e={[math]::Round($_.Free/1GB,2)}} | Format-Table -AutoSize'],
    danger: false
  },
  {
    id: 'process-top',
    label: '占用最高的进程',
    group: 'host',
    description: '按内存排序的前 15 个进程',
    argv: ['pwsh', '-NoProfile', '-NonInteractive', '-Command',
      'Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 Id,ProcessName,@{n="MemMB";e={[math]::Round($_.WorkingSet64/1MB,1)}} | Format-Table -AutoSize'],
    danger: false
  },
  {
    id: 'listening-ports',
    label: '监听端口',
    group: 'host',
    description: '本机正在监听的 TCP 端口与所属进程',
    argv: ['pwsh', '-NoProfile', '-NonInteractive', '-Command',
      'Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Select-Object LocalAddress,LocalPort,OwningProcess | Sort-Object LocalPort | Format-Table -AutoSize'],
    danger: false
  },
  {
    id: 'git-add-all',
    label: '暂存全部改动',
    group: 'mutate',
    description: 'git add -A（会修改索引，不影响工作区文件内容）',
    argv: ['git', 'add', '-A'],
    danger: true
  }
];

/** Look up one catalog entry by id. Unknown ids return null — never a fallback. */
export function resolveQuickCommand(id) {
  const wanted = typeof id === 'string' ? id.trim() : '';
  if (!wanted) return null;
  return QUICK_COMMANDS.find((c) => c.id === wanted) || null;
}

/** The catalog in wire form: argv never leaves the host. */
export function quickCommandCatalog() {
  return QUICK_COMMANDS.map(({ id, label, group, description, danger }) => ({
    id, label, group, description, danger: danger === true
  }));
}

/**
 * Run one catalog entry.
 *
 * @param cwd - directory to run in (the session workspace).
 * @param spec - an entry from {@link QUICK_COMMANDS}; never client-built.
 * @param options.timeoutMs / options.maxBytes - per-call caps.
 * @returns `{ ok, exitCode, stdout, stderr, truncated, durationMs, timedOut }`.
 *   A non-zero exit is `ok: true` with the real code: the command ran, and the
 *   phone must see git's own message rather than a bridge-invented failure.
 */
export function runQuickCommand(cwd, spec, {
  timeoutMs = DEFAULT_COMMAND_TIMEOUT_MS,
  maxBytes = DEFAULT_COMMAND_MAX_BYTES
} = {}) {
  return new Promise((resolve) => {
    if (!spec || !Array.isArray(spec.argv) || spec.argv.length === 0) {
      resolve({ ok: false, error: 'unknown-command' });
      return;
    }
    const [file, ...args] = spec.argv;
    const cap = Math.max(4096, Math.min(Number(maxBytes) || DEFAULT_COMMAND_MAX_BYTES, 1024 * 1024));
    const limit = Math.max(1000, Math.min(Number(timeoutMs) || DEFAULT_COMMAND_TIMEOUT_MS, 60000));
    const startedAt = Date.now();

    execFile(file, args, {
      cwd,
      timeout: limit,
      // maxBuffer is the hard stop on a runaway command's memory use; we then
      // trim to `cap` for the wire so the phone's payload stays bounded.
      maxBuffer: Math.max(cap * 4, 1024 * 1024),
      windowsHide: true,
      encoding: 'utf8'
    }, (error, stdout, stderr) => {
      const durationMs = Date.now() - startedAt;
      const timedOut = error?.killed === true || error?.signal === 'SIGTERM' || error?.code === 'ETIMEDOUT';
      const out = String(stdout ?? '');
      const errText = String(stderr ?? '');
      const clippedOut = out.length > cap ? out.slice(0, cap) : out;
      const clippedErr = errText.length > cap ? errText.slice(0, cap) : errText;

      if (error && !timedOut && error.code === 'ENOENT') {
        resolve({
          ok: false,
          error: 'command-not-found',
          command: file,
          durationMs,
          stdout: clippedOut,
          stderr: clippedErr
        });
        return;
      }

      resolve({
        ok: true,
        exitCode: typeof error?.code === 'number' ? error.code : (error ? 1 : 0),
        stdout: clippedOut,
        stderr: clippedErr,
        truncated: out.length > cap || errText.length > cap,
        timedOut,
        durationMs
      });
    });
  });
}
