# v1.13.0 独立对抗性审计（task-4）

审计者：`implementation-auditor`（与实现者 `lead` 无共同上下文，独立取证）
审计对象：提交 `8f303c8`（v1.13.0 / bridge 1.14.0），含 `ac96294` 全部改动面
基准：**一个天天用手机远程操控 DSH 的人，在真实会话、真实数据上会不会用它**
方法：只读。活网关 `http://127.0.0.1:3088`（bridge 1.14.0）+ `x-dsh-token` 只读探测；对 `C:\Users\Administrator\.dsh` 下 1936 个会话日志做 zstd 多帧解压取证；引擎 RPC 描述符比对。**未改任何源码，未建会话，未重启 dsh web。**

## 0. 前提更正（已从本审计删除的错误前提）

任务描述里"活实例是旧插件、新路由不存在"一条**作废，本报告不采用**。实测前提：

| 事实 | 证据 |
|---|---|
| 新路由已在活实例注册 | `GET /api/mobile/version` → `{"bridgeVersion":"1.14.0"}`；`GET /api/mobile/schedules` 无参 → `400 {"error":"sessionId is required"}` |
| 网关只有一条可达入口 | 3080/3081 带 token 均 401（dsh 本体 + pocket 代理）；**3088 返回 200**。审计全程打 3088 |
| 会话日志是 zstd 多帧 | 单帧 `zlib.zstdDecompressSync` 只解出 201B（仅 session 头）；**按帧解压**才得到 315KB / 63 行真事件 |

> ⚠️ 方法学更正：我第一轮 grep 明文 + 单帧解压，得到"全库 0 条 `deliverables/presented`"，那是**工具假象**。按帧解压后实际有 **42 个会话带交付物声明、46 条事件、128 次 present 调用**。凡"搜不到 ⇒ 不存在"的推断已全部剔除。

## 1. 逐项判定

| # | 能力 | 判定 | 一句话依据 |
|---|---|---|---|
| 3 | 交付物下载预览 | **只是看起来完成了（致命）** | 4 个确有 `deliverables/presented` 且文件在盘上的真实会话，`/api/mobile/deliverables` **全部返回 `[]`**，下载路由 **全部 403**。用户原话"交付物点不开"已被我独立复现为必然结果 |
| 1 | 运行中排队/插话 | **只是看起来完成了（致命）** | `GET /api/mobile/sessions/queue` 被更早的 `/api/mobile/sessions/*` 通配 GET 路由吞掉，实测返回**会话历史**（`data.sessionId == "queue"`），不是队列 → 队列永远空 |
| 4 | diff 审阅 | **只是看起来完成了** | `E:\workspace\个人`（**当前 100% 会话的 cwd**）不是 git 仓库，实测 `not-a-git-repository`；即使命中 git，工作树只反映"至今全部改动"，不是"本轮改了什么" |
| 8 | 用量看板 | **真正可用**（有小瑕疵） | `/api/mobile/session/stats` 返回真实 provider 计量：`totalTokens 206794 / pressureTokens 36500 / contextWindow 1000000`。数据源是 `session/projections`，**唯一的活链路** |
| 6 | 多网关配置 | **能用但难用→真正可用** | `setActiveProfile` 确实接上了（`config_page.dart:388-412`），不再是"切了下拉框没连上"；未在真机验证 |
| 5 | 图片分享接通 | **能用但难用** | 原生复制 + 下采样是对的；但解码失败时回退路径把**原始字节标成 `image/jpeg`**（`MainActivity.kt:90-94` + `chat_view.dart:227-233`），静默污染 |
| 7 | 后台任务/定时任务可视化 | **能用但难用** | 作业流式读取实现正确（`mode: "stream"` 已核实），但本机 1936 会话**从未观察到一个后台作业**，无真实数据可证；定时任务是纯只读列表 |
| 2 | ntfy 离线推送 | **只是看起来完成了** | 配置界面 + 触发点 + 深链接都写了，但**用户手机上一分钱证据都没有**；且配置里 `enabled:false, url:"", topic:""`，闭环未接通 |

## 2. 致命项

### F1. 交付物：列表恒空 → 下载路由恒 403（用户已踩）

**现象**：`GET /api/mobile/deliverables?sessionId=…` 对任何真实会话都返回 `{"deliverables":[]}`；`GET /api/mobile/deliverables/download` 对任何路径都返回 `403 {"error":"该文件不在本会话的交付物清单中"}`。

**实测证据（活网关 3088，只读）**：

| 会话 | 会话内声明的交付物（从日志按帧解压取证） | 文件在盘 | 列表接口 | 下载接口 |
|---|---|---|---|---|
| `session-b014a73e…`（seq 4061/4431） | `E:\workspace\个人\dsh_mobile\DSH-Mobile-v1.13.0-新功能与验收清单.docx` | ✅ 5900B | `[]` | 403 |
| `session-e9457532…`（seq 746/752，**绝佳样本：声明就在最后 6 个事件**） | `…\t1_order_audit.md`、`t2_consume_audit.md` | ✅ | `[]` | 403 |
| `session-fdbc3c8c…`（seq 376/14087） | `…\ANALYSIS-优化与新增功能.md` | ✅ | `[]` | 403 |
| `session-84728691…` | `C:\Users\Administrator\.ssh\id_gz_deploy.pub` | ✅ | `[]` | 403 |

越权对照（安全边界是好的）：未声明的 `pubspec.yaml` 同样 403 —— 安全过滤生效，但**合法路径也一起被拒了**。

**代码证据**：
- 扫描窗口：`dsh-server-plugin/lib/index.js:287-293` — `session/page` 传 `maxMessages: 200`。注释自称"声明很少、页面载的是最新事件，正好是手机关心的窗口"（`index.js:278-283`）。**这是把"通常"当"必然"**。真实会话事件量：1936 个会话 maxSeq 中位数远超 200；带交付物的 42 个会话，声明位置 seq = 225 / 237 / 376 / 409 / 4263 / 4061 / 788 / 925 …。即便 `session-e9457532` 的声明就在末尾（746/752），列表依然空 —— 说明 200 条的窗口与"事件"的换算还有量级差距（`session-e9457532` 共 752 事件，其中 `assistant/message 598 + tool/call 595 + hook/* 1190`，200 条根本盖不到第 746 条）。
- cwd 解析失败会放大问题：`index.js:251-257` `readSessionCwd` 读 projcache 的 `identity.cwd`；未命中 → `null` → `extractDeliverables` 用 `path.resolve('.', 相对路径)` 落到**网关进程的 cwd**（`features.mjs:113`），绝对路径也对不上 → 403。

**影响的实际场景**：用户在手机上让 agent 做了一份 docx/xlsx，agent 用 `present` 声明了；用户在"任务 → 交付物"里点它，永远只有两种结局：**列表是空的看不到它**，或者（旧列表残留时）点下去弹"下载失败 (HTTP 403)"。8 项新功能里"交付物"正是手机相对于桌面的**唯一硬需求**（手机上打不开本机文件），它 100% 不通。

**做到什么程度才算到位**：
1. 交付物发现不能依赖 `session/page` 的单页窗口。要么**全量翻页**（按 `beforeSeq`/`throughSeq` 向历史走，直到会话起点或找到足够条数），要么直接读会话日志文件（网关与引擎同机，`~/.dsh/sessions/<cwd-key>/<sid>/session.v4.jsonl.*` 一直是可读的，且**必须按帧解压**），或者读 `session_query`（引擎自带 `dsh-session-query-sqlite`，支持按事件类型检索）。
2. 下载路由的成员校验键必须是 **`(sessionId, 事件里声明的原样 path)`**，而不是"重新解析后的绝对路径"。当前把两件事耦合在一起：解析失败 = 成员校验失败 = 403，于是**解析问题伪装成了权限问题**，错误信息把用户指向完全错误的方向。
3. 验收标准应是端到端一条：**"在一个真实长会话上点开 docx，Android 用 WPS 打开"。**

### F2. 队列：GET 路由被通配路由吞掉，队列恒空（且无任何报错）

**现象**：`GET /api/mobile/sessions/queue?sessionId=session-03ba0334…` 实测返回
```
HTTP 200 {"ok":true,"code":0,"data":{"sessionId":"queue","isRunning":false,"model":"cn:deepseek-v4.1-flash","lastTurn":null,"messages":[]}}
```
—— 这是 `getSessionHistory("queue")` 的响应体，**不是队列**。

**代码证据**：
- `dsh-server-plugin/lib/index.js:2737-2742` — 通配 GET 路由 `pathname.startsWith('/api/mobile/sessions/')` 且**无排除清单**，`sessions/queue` 命中即 `return`。
- 处理队列的 `handleFeatureRoute`（`features.mjs:495-501`）挂载在 `index.js:3158`，**晚 421 行**。
- 同一文件里注释（`index.js:2700-2704`）已经写明这类坑："必须排在下面的 startsWith('/api/mobile/sessions/') 通配路由之前……搜索永远返回空历史" —— 上一轮的作者知道这个坑，**却在同一区块下方又踩了一次**。

**App 侧为何静默**：`dsh_service.dart:2176-2184` 只认 `data['queue']`；拿不到就当空数组，不置 `_queueError`。所以任务页永远显示"会话空闲，没有排队消息。"（`task_center_view.dart:182-183`），**看起来像正常状态**。

**影响的实际场景**：用户在一次长跑里连发 3 条指令排队，切到"任务"页想确认"我排了哪几条、要不要撤掉第 2 条"—— 看到的永远是"没有排队消息"。更糟的是**发送后没有任何确认**：`deliverWhileRunning`（`dsh_service.dart:2265-2267`）成功后调 `fetchQueue()`，而 `fetchQueue` 永远是空的 → 用户不知道消息进了队列还是丢了。队列 dock 的编辑/删除/插话三个动作（`chat_view.dart` 队列 dock）因此**没有任何入口能触达**。

**次生结论**：`队列编辑/删除/插话` 在**代码层**是正确的（`session/updateQueue` 的 RPC 与参数 schema 已逐字核对，见 §4 已核实表），但**不可达**。这正是"为完成任务而完成"的典型形态：把 RPC 接对了，却没让用户摸到它。

**做到什么程度才算到位**：
1. 通配路由加排除（`/api/mobile/sessions/queue` 必须在 `startsWith` 之前，或把 queue 挪到 `/api/mobile/queue`）。
2. 队列读取失败/响应形状不符时**必须报错**，不能落进"空 = 正常"。
3. 端到端验收：**"跑一轮的同时发 2 条，任务页显示 2 行；删掉第 1 行，刷新后只剩 1 行"**。

### F3. diff 审阅：对当前 100% 的会话都返回"不是 git 仓库"

**现象**：`/api/mobile/workspace/changes` 对所有真实会话要么 `no-workspace`、要么 `not-a-git-repository`。

**实测证据**：把 1936 个会话日志头部的 `cwd` 全部聚出来，**只有 5 个不同 cwd**：

| cwd | 会话数 | `git rev-parse --is-inside-work-tree` |
|---|---|---|
| `E:\workspace\个人` | 1371 | **false** |
| `E:\workspace\SZ` | 548 | false |
| `E:\workspace\GZ` | 13 | false |
| `C:\Users\Administrator` | 3 | false |
| `E:\MyWorkspace\edu-manage` | 1 | false |

我把 `E:\workspace\个人` 下每个会话逐个问活网关，得到 `not-a-git-repository`（`session-af874873` 为显式证据）。**git 仓库是它的子目录 `E:\workspace\个人\dsh_mobile`**（`git rev-parse --show-toplevel` = `E:/workspace/个人/dsh_mobile`）。也就是说：**只有当用户把会话建在某个 git 仓库根目录里时，这个功能才有数据**；用户现在的工作方式（在 `E:\workspace\个人` 下开会话）在新功能里看到的是一句"这个工作区不是 git 仓库"。

**代码证据**：`index.js:311-348` `readWorkspaceChanges`；`features.mjs:200-233` `combineChanges`；前端文案 `task_center_view.dart:574-579`。

**更根本的语义错位（即便命中 git 也不对）**：`git status --porcelain` 给的是**工作树当前全部未提交改动**，不是**本轮 agent 改了什么**。用户问的是后者："这轮它动了哪些文件、改了哪几行？"——现在若仓库里积压了 30 个文件的历史未提交改动，这 30 个会全部列出来，无法区分哪 3 个是本轮的。v1.13 的提交信息承认了引擎侧限制（"`workspace/changes` 事件只带轮号、摘要留在 Host"），但**换数据源后没有把语义补回来**。

顺带纠正一处技术表述：`git diff --numstat HEAD` 只覆盖**已跟踪**文件的改动；未跟踪新文件靠 `status` 兜底但 `added/deleted` 为 `null`（`features.mjs:216-218`），UI 显示"—"——不是 bug，但意味着"本轮新增的 5 个文件"在 diff 卡片里**永远看不到增删行数**。

**做到什么程度才算到位**：
1. `cwd` 不在仓库时**向父目录回溯**或允许用户指定仓库根；再不行至少给出"请把会话建在 `<repo>` 内"的可操作指引，而不是一句静态说明。
2. 语义必须是"本轮改动"。可行路径：用 `workspace/changes` 事件的**轮号**去日志里取该轮 `tool/call` 的 fs 写入路径集合（我在 1936 个会话里确认 `tool/call`＋`tool/result` 是**有**的，路径可提取），再与工作树求交 —— 这样才回答"本轮动了什么"。
3. 验收：**"改一个文件，diff 卡片只出现那一个文件，点开只显示那一次修改的 hunk。"**

## 3. 严重项

### S1. 投影缓存查找的目录名不匹配 → `readSessionCwd` / `readProjectionRows` 约 45% 概率直接落空

**代码证据**：`index.js:244` 与 `index.js:252` 都做 `String(sessionId).replace(/^session-/, '')`，再拼 `storages/session_projcache/sessions/<uuid>.json`。

**实测**：`C:\Users\Administrator\.dsh\storages\session_projcache\sessions` 共 2468 个文件，**2133 个（86%）文件名本身就带 `session-` 前缀**（`session-<uuid>.json`），且**同名的去前缀孪生文件不存在**。近 24h 写入的 1928 个里，**1923 个是带前缀的**。

逐会话验证（735 个会话抽样）：

| 网关的查找（去前缀） | 命中率 |
|---|---|
| 命中 | 335 / 735 = **45.6%** |
| **落空（真实文件是带前缀的）** | 400 / 735 = **54.4%** |

**已实测的后果**：`session-03ba0334…` 的 projcache 文件是 `session-03ba0334….json`（存在），去前缀后是 `03ba0334….json`（不存在）→ `readSessionCwd` 返回 `null` → `workspace/changes` 直接报 `no-workspace`（实测），而该会话明明有 `cwd = E:\workspace\个人`。

**连带影响**：交付物相对路径解析（`features.mjs:113`）在命中不到 cwd 时会 resolve 到网关进程的工作目录，把正确的相对路径变成错误绝对路径 —— 这条**放大 F1**。

**注意**：`session/stats` **不受影响**，因为它先打 `session/projections`（活投影），命中就用活数据（`features.mjs:280-288`）；`session/stats` 实测 `source:"live"`。所以**用量看板能用，恰恰不是因为它做对了，而是因为它有活数据兜底**。

**做到什么程度才算到位**：不要猜文件名。要么两种命名都试（带前缀优先），要么按 `storages` 域的 API 读（该 store 是标准 JSON 域，有正式读写接口），要么干脆不依赖 projcache 取 cwd —— cwd 在**会话日志第一行**就有（`{"type":"session",…,"cwd":"E:\\workspace\\个人"}`，我逐会话都读到了）。

### S2. ntfy 推送：闭环缺环且无任何送达/去重机制

**已做到的**：配置路由 `GET/POST /api/mobile/push/config`（实测 `{"enabled":false,"url":"","topic":"","hasToken":false}`）、测试按钮 `pushTest`、4 个触发点（`index.js:1828` turn-end、`1927` question、`2107`/`2136` approval）、深链接 `dshmobile://open?…`（`index.js:438-442`）+ Manifest intent-filter + `MainActivity.captureDeepLink` + `main.dart:72-76` 消费。这些都是**真代码**。

**闭环缺的五环**：
1. **配置是关着的**：活实例实测 `enabled:false`。用户不填 ntfy 地址/topic，整条链路一次都不会触发 —— 而 v1.13 的交付里**没有一个字告诉用户"还要去装 ntfy App 并订阅一个 topic"**（`custom_settings_view.dart:313-317` 只说了"事件摘要会经该服务中转"）。
2. **无去重**：触发点**无条件下发**（`index.js:448-487`），而同一事件同时也在 `broadcastToMobileClients` 里推给了 App。App 在前台/后台活着时，用户会**同时**收到 App 本地通知和 ntfy 通知（两条）。
3. **无送达可观测**：`pushNtfy` 是 fire-and-forget，只看 HTTP 状态码记一条 `logger.warn`（`index.js:477-479`），**不进 audit**。用户说"没收到推送"时，你无法区分"没发出去""ntfy 拒了""用户没订阅"。
4. **深链接只在 ntfy 点击路径上通了，但"App 被杀"这条路未验**：`main.dart:83-85` 的冷启动消费依赖插件就绪，`DeepLinkReceiver.consumePending` 与 `onNewIntent` 两条时序我只做了静态核对。
5. **诚实性缺口**：提交信息写"ntfy push on approval / question / turn end"，读起来像已完成能力；实际状态是"接口写完、默认关闭、用户手机零验证"。

**做到什么程度才算到位**：写入一行 audit（`push/sent` + HTTP 状态 + 目标 host）；按"App 是否前台"决定是否跳过 ntfy；在设置页把"手机侧要做什么"写成三步（装 App → 订阅 topic → 点测试并确认收到）；并且**必须有一次真机端到端证据**才能称"完成"。

### S3. 后台任务/定时任务可视化：结构正确但**零真实数据**，且无降级可见性

**已核实的正确性**（这部分我推翻自己最初的怀疑）：`job/list` 在引擎描述符里确实是 `mode: "stream"`（`dsh-api-remotes/lib/client.js:442603` 区块），一元 RPC 会被拒 → 作者改用 MUX oneshot 是**对的**；`JobListFrame` 的字段名 `{id, kind, label, status, progress, detail, startedAt, finishedAt}` 与网关映射（`features.mjs:561-570`）**逐字一致**；`oneshot-` 前缀在 MUX 消息分发最前面被拦截（`index.js:1750-1756`），不会污染 `follow-` 分支；连接断开时会把所有 pending oneshot 置失败（`index.js:1722-1725`）。

**问题**：
- 1936 个会话日志里我**没有观察到任何后台作业活的实例**；活实例 `/api/mobile/jobs` 实测恒 `{"jobs":[]}`，**没有返回 `degraded`**（说明流是通的）。所以"作业列表能显示"这件事**无真实数据可证**，只有结构证明。
- `degraded:'jobs-unavailable'`（`features.mjs:558`）是**空列表 + 无提示**：App 侧 `fetchJobs` 完全忽略 `degraded` 字段（`dsh_service.dart:2468-2477` 只看 `jobs`）→ 手机永远显示"没有后台作业。长时间命令与子代理会在这里出现。"（`task_center_view.dart:311-312`）——**又一次把"读不到"伪装成"没有"**。
- 定时任务：`schedule/list` 是纯列表，**不能新建**。用户想在手机上让 agent 定时办事，只能先在对话里让 agent 自己建。活实例恒空。

**做到什么程度才算到位**：`degraded` 必须透到 UI（"作业列表当前不可用"≠"没有作业"）；定时任务至少要能从手机创建/暂停，否则"可视化"只是半个能力。

## 4. 次要项与已核实正确的部分（避免我变成"一律否定"）

**已核实正确（可反驳我的反例）**：

| 项 | 证据 |
|---|---|
| `session/updateQueue` 是真实 RPC，参数 schema 与网关逐字一致 | 描述符 `dsh-api-session-controller#session/updateQueue`，参数 `{sessionId, itemId, action:{edit(content[{type:'text',text}]) \| remove \| steer}}`（client.js:11171-11188），网关 `features.mjs:510-512` 完全匹配 |
| `session/prompt` 接受 `mode: queue \| steer` | client.js:11112；网关 `index.js` 的 `deliveryMode` 取值只有这两个 |
| 队列投递**数据源**假设成立 | `inbox.next-turn` 投影确有该形状（client.js:10114-10122 出现 4 次）；实日志里 `agent/inbox/spliced` 的 `data.target` 就是 `"next-turn"`，`inserted[].id` 存在 —— `selectQueueRows` 读 `row.id`/`row.content` 是对的 |
| `job/list` 必须走流（作者的判断正确） | 描述符 `mode: "stream"` |
| 多网关一键切换**真的接上了** | `config_page.dart:388-412` 调 `StorageService.setActiveProfile(id)`（`storage_service.dart:220`）再 `connect(cfg)`；提交信息自陈"setActiveProfile 从来没被调用过"，修复可信 |
| 用量看板数据真实 | 实测 `totalTokens 206794 / 192958901 / 8523961`，`source:"live"` |
| 深链接 Manifest/FileProvider 声明存在 | `AndroidManifest.xml:84-93` provider + `file_paths.xml` 只暴露 `cache/deliverables`、`cache/shared`（范围最小化，做得对） |

**次要项**：

- **N1｜交付物预览其实是"下载+外发"，不是预览。** `task_center_view.dart:530-550` 走 `http.get` 拿全量字节 → 原生写盘 → 拉系统应用。手机上一份 50MB 的 xlsx 会**全量进内存**（`res.bodyBytes`）+ **写一份副本**。没有"查看"路径，也没有大小提示。建议：先 `HEAD`/Content-Length 提示大小，超阈值改走 `download` 直链交给系统下载器。
- **N2｜`_openDeliverable` 的错误文案会把用户引向错误方向**：列表恒空时用户拿不到入口；若从残留列表点到，文案是"下载失败 (HTTP 403)"，用户会以为是自己没权限，实际是扫描窗口问题（F1）。
- **N3｜图片分享的 HEIC 回退路径静默污染**：`MainActivity.kt:90-94` 解码失败时把**原始字节**（可能是 HEIC）写进 `shared-*.jpg`；`chat_view.dart:227-233` 无条件把 `mediaType` 设成 `image/jpeg`。引擎的图片 part schema 只校验 `mediaType` 字符串字面量（client.js:11118-11127），**不校验魔数** → 畸形 base64 会被接受并上传，最终在 provider 侧报错。应改为按魔数判定真实类型，判不出就**拒绝并明确提示**，而不是猜。
- **N4｜分享图片仍受 1.4MB 内联上限**（`pending_attachment.dart:93-96`）：原生降到 1600px/q85 通常够，但**典型 4000×3000 手机照降到 1600px 仍可能 >1.4MB**（高细节场景），用户会看到"图片 X MB 超过内联上限 1.4MB"——这个功能对"随手分享一张刚拍的照片"这个最高频场景可能直接失败。**必须真机验证**。
- **N5｜`pushConfig` 只有在进入设置页才刷新？** 不成立：`dsh_service.dart:611` 在启动流程里就 `await fetchPushConfig()`。此项撤回，记录在此以免后人重复怀疑。
- **N6｜`session/page` 的 `maxMessages: 200` 同样影响 `getSessionHistory`**（`index.js:1150-1153` 用 `maxMessages: 100`）—— 既有能力，不在本审计范围，但同一类"窗口假设"缺陷说明这是**系统性错误模式**，不是单点。

## 5. 测试为什么没拦住（针对"假数据下成立"）

**App 侧**：`dsh_mobile/test/widgets/queue_and_task_center_test.dart` 的每个用例都靠注入口摆数据 —— `debugSetQueue`（44/52/66/74/89 行）、`debugSetRunning`、`debugSetDeliveryMode`、`debugSetTaskCenter`（162/202/214 行）。**没有一条测试经过 HTTP**。`test/models/task_center_test.dart` 全是 `fromJson` 解析（13/34/50/69/112/126 行 group）。

⇒ 这些"通过"的测试证明的是：**给定正确 JSON，UI 渲染正确**。它们**不可能**发现 F1（网关返回 `[]`）、F2（路由被吞）、F3（cwd 不是 git）——因为这三件事发生在**测试从未触碰的那一段**（服务端取数与网络响应形状）。

**网关侧**：`tests/unit/features.test.mjs` 只 `import` 纯函数（`features.mjs` 的 13-28 行），**不 import `index.js`**（该文件把 HTTP 面、RPC、MUX 全部收在自己手里，无法脱离引擎单测 —— 注释自己承认了）。因此：
- 路由**分发顺序**（F2 的根因）**零覆盖**；
- projcache **文件名约定**（S1）**零覆盖**；
- `session/page` 窗口边界（F1）**零覆盖**。

`tests/unit/security-hardening.test.mjs` 命中的是 URL 白名单，与路由顺序无关。

**结论**：318 个 Flutter 测试 + 190 个网关测试，**没有一个**会因 F1/F2/F3/S1 红掉。这不是测试数量问题，是**测试断言的对象错了**：测的是"我摆好数据后页面长什么样"，而不是"真实链路上数据能不能到页面"。用户那句"为了完成任务而完成"，在测试层面有精确对应物。

## 6. 我无法自证的判定（明确标注）

| 判定 | 为什么无法自证 | 谁能证 |
|---|---|---|
| 交付物在 Android 上能否被 WPS/系统应用打开 | 需真机 + 安装应用；FileProvider 授权、`MimeTypeMap` 对 `.docx` 的判定、`FLAG_ACTIVITY_NEW_TASK` 行为都只在真机成立 | 用户真机 |
| 深链接冷启动是否真的落到目标会话 | 需杀进程后点 ntfy 通知；`main.dart:83-85` 与 `onNewIntent` 的时序我只有静态核对 | 用户真机 |
| 图片分享（含 4000×3000 原图与 HEIC）能否成功 | 需真实相册分享；`BitmapFactory` 解码结果与 1.4MB 上限的交互只能在真机测 | 用户真机 |
| 排队/插话在真机上"发出去之后是否有确认反馈" | 队列读取恒空（F2 已证）；但"发送动作本身**确实到达引擎**"我未做写入型探测（**为不污染数据主动放弃**） | 需一次真机发送 |
| ntfy 端到端送达 | 服务端到第三方（`n.cnm.asia` / ntfy.sh）的出口链路与手机订阅状态都在我探测范围外；且配置当前是关的 | 用户配置后真机测 |
| `job/list` 在**有作业时**的返回形状 | 本机无活作业样本，只有 schema 一致性的结构证明 | 需一次长任务（`run_in_background`） |

## 7. 严重度排序（先致命）

1. **F1 交付物列表恒空 → 下载恒 403**（5 个真实会话全复现，含最有利样本）—— 手机侧最强刚需，完全不工作；**用户已踩**
2. **F2 队列 GET 被通配路由吞掉**（活实例响应体实测）—— 8 项里的第 1 项完全不可达，且**静默伪装成"没有排队消息"**
3. **F3 diff 审阅对当前 100% 会话返回 not-a-git-repository**（全库 cwd 聚合 + 逐会话探测）—— 语义还错（工作树 ≠ 本轮改动）
4. **S1 projcache 目录名不匹配，45% 落空** —— 放大 F1/F3；`session/stats` 侥幸不受影响
5. **S2 ntfy 闭环缺 5 环 + 无去重 + 无 audit** —— 交付叙事与真机现实差距最大的一项
6. **S3 作业/定时零真实数据，`degraded` 被 UI 吞掉** —— 结构对，无证据
7. **N3/N4 图片分享回退路径静默污染 + 1.4MB 上限对原图偏紧** —— 需真机
8. **N1/N2 交付物"预览"实为全量下载，错误文案误导**
9. **测试体系未覆盖任何真实链路**（§5）—— 这是让 1-6 能"通过"的结构性原因

## 8. 给实现者的一句话

F1/F2/S1 三个缺陷的共同形态是：**把"读不到"渲染成"没有"**。F1 的 403 把解析失败说成权限不足；F2 的空队列看不出路由被吞；S1 的 projcache 落空被当作"没有工作区"；S3 的 degraded 被当作"没有作业"。**只要把"未知"和"空"在 UI 与错误码上彻底分开，这批问题会在用户第一次使用时立刻暴露，而不是靠审计去挖。**
