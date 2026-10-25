# Changelog

本文件按 `dsh_mobile/pubspec.yaml` 的版本号手工维护。
`build-apk.yml` 发布时会取对应版本小节的正文作为 GitHub Release notes。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [1.39.10] - 2026-10-26

### 修复：不同供应商的同名模型在选择器里会同时显示"使用中"

- 模型选择器原先只比模型 id，还额外做了一次「去掉供应商前缀」的宽松比较。不同供应商本来就有同名模型（如 wb 的 `cn:glm-5.3` 与 qwen 的 `glm-5.3`、wb 的 `cn:deepseek-v4-pro` 与 qwen 的 `deepseek-v4-pro`），去掉前缀后两者同串，于是选中一条、两家同时高亮。
- 现在先按完整 id 精确命中；只有在名单里找不到该 id 时才退回前缀比较，且要求候选**唯一**，多候选时用当前模型所属供应商收敛；仍无法唯一确定就一条都不点亮。
- 会话内切换与设置页改全局默认两个入口共用同一判定，`currentModelProviderKey` 提供当前模型的准确归属。

## [1.39.9] - 2026-10-26

### 修复：会话跨端同步、重复消息与长回合状态（网关 1.16.2）

- 同一次发送的自动重试固定使用同一个 requestId；网关合并并发重试，历史与实时提问按 rpcId 精确配对，不再靠正文或时间戳猜测。
- Web 发起的提问也进入实时流；done 携带最终正文，App 结束时合并补拉最终历史，避免网页已完成而手机仍缺结果。
- 旧回合的迟到增量不会重新点亮流式状态；运行补拉与结束补拉按会话合并并校验代次。
- 长回合不再因超过 45 秒被误判为空闲；缓存恢复保留分页状态，对账后及时更新历史缓存。
- CI 出包前执行 Flutter 静态检查、Flutter 测试与网关隔离测试。

## [Unreleased]

### 网关 1.16.1：提问在手机短暂断线时不再丢失

- 问题到达时若手机订阅者恰好为 0，不再立刻写 `question/relinquished`；先暂存
  5 分钟，手机重连并 `subscribe_questions` 时随 `pending` 一起回放。
- 回放前读取引擎 `userQuestions` 投影，只补发仍为 `active` 的 callId；网页已经
  答过的问题不会以旧卡片出现。
- 有订阅者时行为不变；离线通知在无人订阅时也会照常触发。

对应现网现象：问题 10:37:38 到达、手机 10:37:46 才重连，旧逻辑在 8 秒的空窗里
已经放弃投递，手机端因此没有出现选择卡片。

---

## [1.39.8] - 2026-10-25

### 修复：工具参数增量被当成正文

- 网关的 `tool_call` 帧里带的 `delta` 是**工具参数**增量，而手机端的正文分支
  判定条件是"帧里有 delta 字段"——于是它先被命中，工具参数碎片被拼进回复正文，
  这次工具调用也不再有任何增量落到工具卡上。现在工具帧先截住、直接丢弃这些
  冗余增量（`tool_start` 已经带完整参数）。

### 优化：发完消息不再"卡一下"才看见在跑

- **逐条消息记忆化**：聊天页是全页订阅，服务每通知一次就会对屏幕上每条可见消息
  重跑一遍 `MarkdownBody` 解析 + 产物链接扫描 + 工具卡。现在按「正文/思考内容、
  工具条数与运行中数量、流式状态、轮首、高亮、交付物白名单」算签名，没变就复用
  上一次构建的子树，整棵跳过。

---

## [1.39.7] - 2026-10-25

### 优化：会话信息面板开着也不掉帧

- **面板订阅换成数据签名选择器**：以前是 `Consumer<DshService>`，流式回复期间每
  150ms 通知一次就整块重建一次，可面板显示的东西一个都没变。现在只有它真正依赖的
  十几项（用量、交付物、变更、作业、定时、子代理、团队）变了才重建。
- **「轨迹」tab 改为按需构建**：轨迹是从**全部消息**推导出来的（每条消息、每次
  工具调用都要跑正则与逐行解析），以前宿主每次重建都要先算它一遍。收成构造器后，
  只有真的切到「轨迹」才付这笔钱，并且同一份消息只算一次。

---

## [1.39.6] - 2026-10-25

### 优化：会话信息面板打开不再卡顿

- **小节级构建缓存**：面板外面套着 `Consumer<DshService>`，流式期间每 150ms 重建一次；
  现在数据没变的小节直接复用上一次构建的子树，整棵跳过，不再反复重扫交付物分组、
  变更清单与队友列表。
- **1 秒 ticker 只推动作业时长**：它原来是一次空的 `setState()`，等于每秒把整个面板
  重建一遍；现在只有「作业」小节的签名跟着 tick 变。
- **面板内容单独成层**（`RepaintBoundary`）：滑入动画和滚动只做位移与合成，不再每帧
  重新光栅化整片内容。

### 移除：设置 → 远程访问

- 入口删除。这一页只在「连不上」时才有信息量，而那时它自己也刷新不出来；连得上时
  又不需要看它 —— 一个进不去又没人看的页面不值得占设置首屏一张卡。
- 通道能力未删：`DshService.refreshRemoteAccess`、`RemoteAccessState` 与网关的
  `/api/mobile/remote-access` 都还在，只是手机端不再有入口。

---

## [1.39.5] - 2026-10-25

### 优化：长会话滑动不再掉帧

- **每条消息独立重绘边界**：新内容到达时历史消息不再跟着重排重绘，会话越长收益越明显。
- **上下文标记扫描按消息 id 永久缓存**：已结束的消息只扫一次，不再是每次刷新重扫 9 个
  `indexOf`。
- **流式通知窗口 100ms → 150ms**：长会话下整页重建次数减少约三分之一，观感不变。
- **Markdown 清洗缓存 8 → 128 条**并改为批量淘汰，滚动时不再反复重跑正则。

### 新增：正文里的交互组件可以直接提交

- `dsh-ui` 表单组件（输入 / 单选 / 多选 / 下拉 / 开关 / 滑块 / 按钮 / 判题）接通提交：
  点按后把动作名与组件数据以 `[genui-action]` 回传给模型。
- 回传消息在会话里折叠成「已提交选择」，不把发给模型的指令原文摊在对话里。

---

## [1.39.4] - 2026-10-25

### 设置首屏直接切换服务器

- 设置页第一层新增「当前服务器」卡：显示别名、地址与连接状态，不再需要先进入
  「连接与诊断」才能看到自己在哪台机器上。
- 点「切换」打开服务器面板，选择另一台立即连接；从设置到换机完成由五步缩成两步。
- 面板保留「管理服务器」入口，添加、重命名、删除仍走连接页，不再把表单塞回设置首页。
- 一台都没有保存时，首屏入口显示「添加」，点击直接进入连接页。

---

## [1.39.3] - 2026-10-25

### 优化：工具执行过程不再铺原始 JSON

- **折叠态直接显示命令摘要**：`bash · 4 条命令 · 列出脚本`，不展开也能看出跑了什么。
- **展开后按命令分条展示**：解析 `command` / `description` 字段，说明在上、命令在下；
  多条并行命令带 `#1/#2` 序号。支持无分隔符拼接的多个 JSON 对象、JSON 数组与
  代码围栏。
- **原始参数改为二级开关**：默认不显示大段 `{"command":...}`，需要排查协议时再点
  「查看原始参数」；收起卡片时自动复位。
- **复制按钮复制可执行命令**，而不是复制整段 JSON。

新增 `tool_input_view` 解析单测和 bash 多命令卡片回归。

---

## [1.39.2] - 2026-10-25

### 安全修复

- **禁止匿名自助配对。** 配对码只能由电脑端设置页或管理 Token 生成；私网/回环来源
  不再免鉴权。此前经 cloudflared 回源也可自助发码并兑换读写设备 Token。
- **撤销设备立即断开已有 WebSocket。** 旧连接不再只是收到广播，服务端同时关闭它；
  每个 WS 消息还会复验设备是否仍有效。
- **Memory 路由按真实路径校验。** 工作区内的 symlink/junction 不能再越界读写。
- **Runbook 解释器默认禁止。** 数组/字符串命令统一受限；需
  `DSH_RUNBOOK_ALLOW_INTERPRETERS=1` 且 `danger: high` 才能启用。
- **cloudflared 使用内置官方 SHA-256 校验。** 缓存与系统二进制不再只检查“不像 HTML”。
- **资源上限。** WS/MUX 单帧、RPC 响应、每设备并发请求、流式缓冲与工具输出均有上限；
  认证失败表和上传桶定期清理。
- **ntfy 默认只允许公网 HTTPS。** 自建 http/私网 ntfy 需宿主机显式
  `DSH_NTFY_ALLOW_PRIVATE=1`。
- **权限输入校验。** 执行策略、沙箱模式、步数与会话策略非法值直接 400，不再静默写入。

### App

- **REST 与 WSS 共用 TLS/TOFU 校验。** 自签 HTTPS 不再出现“WS 连上、历史/发送失败”。
- **连接代次隔离。** 快速切换网关时，旧连接的事件与迟到 HTTP 响应不会写入新网关状态。
- **首次完整加载写回历史缓存。** 第二次打开会话可以直接首帧回填。

### 文档

- 根 README 更新 TLS、配对和发布说明；App README 不再指导本机打包或直接映射 3088。

---

## [1.39.1] - 2026-10-23

### 换图标：小鲸鱼线稿

从建项目起用的都是 **Flutter 默认 logo**（一只蓝色几何箭头），一直没换过，放在桌面上
既不像这个 App，也和 DeepSeek 那点关系都看不出来。这次换成一只蓝色线稿小鲸鱼，白底、
单色、无渐变无阴影 —— 小尺寸下也认得出是一只鲸鱼，而不是一团色块。

- 母版：`dsh_mobile/assets/branding/app-icon-1024.png`（1024×1024 满幅、四周留白，
  **不预先烘圆角**，形状由启动器裁）。
- 新增 `scripts/make-app-icons.ps1`：从母版生成 Android 5 档 `ic_launcher`
  （48/72/96/144/192）。母版换图时只改这一张、重跑一次，不再手改五个 PNG。
- 补上之前缺的**自适应图标**（Android 8+）：`mipmap-anydpi-v26/ic_launcher(_round).xml`
  + `drawable-nodpi/ic_launcher_foreground.png` + `values/ic_launcher_background.xml`，
  Manifest 加 `android:roundIcon` —— 圆形/圆角遮罩下不会露出白边。
- 备选母版留在 `assets/branding/`：`app-icon-alt-solid.png`（蓝底白鲸）、
  `app-icon-alt-navy.png`（深蓝底 + 青色水花），换图命令见脚本头注释。

⚠️ 图标只在重新 build + 安装后才会变；部分启动器还会缓存旧图标，卸载重装或重启
启动器才会刷新。

---

## [1.39.0] - 2026-10-22

用户报的三件事，都是"明明该能用、但用起来不对劲"的那种。

### 上架准备：插件改名 `dsh-mobile-access`

要发到插件市场（deepseek.stream）时发现 npm 上的 `dsh-mobile-bridge` 已经是别人的包
（作者 `dshapp`，0.3.6，做的是 iPhone + Noise 隧道的手机远程插件——同一个场景，
同名会让人装错）。改名不影响功能，只影响身份：

- 包名 `dsh-mobile-bridge` → **`dsh-mobile-access`**；`cordis.patch.yml` 的实例
  `id`/`name` 一起改（Cordis 按包名解析模块）。
- `package.json` 补齐市场要求：`dsh.name` / `dsh.category`、`license`、`author`、
  `keywords`、`repository`、`engines.node (>=22.15)`；版本对齐 `BRIDGE_VERSION`
  （1.15.1），并加了**版本漂移测试**。
- 新增 `LICENSE`（MIT）、重写插件 README（功能介绍/安装/首次使用/端口/配置/安全边界）。
- 新增 `scripts/pack-plugin.mjs`：按市场上的校验规则打 ZIP（根层必须有 package.json、
  不许混进 node_modules），打完再自检一遍。
- 新增 `tests/unit/plugin-market.test.mjs`：把市场会拦的那几条（entry 必须是 .js、
  `dsh.bundle.patch` 必须存在且是 YAML 列表、README/LICENSE 必须在、版本要一致）
  变成本地单测——别等上传后看红字。

⚠️ 改名后两台宿主机都要重新 link 一次（`dsh plugin remove 旧名` + `add link:...`），
否则重启时 Cordis 找不到 `dsh-mobile-access` 这个模块。

### 修复：改名漏掉插件内部的身份字符串（客户端面板会跟着失效）

改名只改了 `package.json` 和 bundle patch，**插件内部还写着旧名**：

| 位置 | 旧值 | 为什么必须一致 |
|---|---|---|
| `client/client.js` 的 `__ModuleLoader__.load({ id })` | `dsh-mobile-bridge` | 客户端模块按 id 注册，宿主按**包名**给出的路径加载 → 对不上时"移动终端"面板静默消失 |
| `client/client.js` 的 `module.exports.name` | `dsh-mobile-bridge` | 同上，客户端插件的注册名 |
| `lib/index.js` 的 `const name`（Cordis 插件名） | `dsh-mobile-bridge` | 服务端插件身份，日志与依赖解析都用它 |
| `/health` 自报的 `name` | `dsh-mobile-bridge` | 手机端与诊断页看到的"我是谁" |

- 三处身份现在与包名一致；RPC 通道 `/dsh-mobile-bridge` **刻意不改**（它是线缆上的
  命名空间，两端一起用；改名只会在"浏览器缓存着旧客户端"的窗口里制造 404）。
- `tests/unit/plugin-market.test.mjs` 新增断言：包名 == 客户端 id == 客户端 name ==
  Cordis name。以后改名漏改任何一处都会在单测里炸出来。

### 修复：`pack-plugin.mjs` 依赖系统 `tar`，在 GNU tar 下直接失败

`tar -a -f E:\...zip` 在 GNU tar（PortableGit 自带）里会把盘符 `E:` 当成远端主机，
报 `Cannot connect to E: resolve failed`；Windows 自带的 bsdtar 又认这个写法 ——
同一个脚本在两个终端里行为不同。现在 ZIP 由脚本自己用 `zlib.deflateRawSync` 写出
（无外部命令、无依赖），写完从字节里回读中央目录校验根层与条目数。

### 新增：连接页可以给网关起**别名**

用户原话：「app 连接那里，需要加一个别名，像我现在需要连接多个 dsh 客户端，
域名相同的话就没办法区分了」。原先 `ServerConfig.name` 这个字段早就存在，但只有在
「另存为新网关」时弹窗问一次，日常"填地址 → 保存并进入聊天"这条路根本不写它，于是
下拉框里两条同名域名的记录长得一模一样。

- 连接表单第一位就是**别名**输入框（留空回落到「地址:端口」），随配置一起存取。
- 下拉项改成两行：别名在上、地址在下（关闭态仍是一行，不把顶部那一行顶高）；
  别名万一重复，地址还能兜底区分。
- 「另存为新网关」不再二次弹窗问名字 —— 直接用表单里的别名。
- 新建时撞名自动加 `(2)`、`(3)`（`StorageService.uniqueProfileName`），
  保证列表里永远不会有两条无法区分的记录。
- **扫码配对时自动带出电脑主机名**：配对载荷里本来就有 `name: os.hostname()`，
  App 之前一直没读。多台电脑走同一个域名时，这是不用手打就能区分的现成信息。
- 「设置 → 连接与诊断」顶部加一行别名，先知道"我在哪台"，再看地址。

### 新增：新建工作区改成**点选目录**

以前是手写服务端绝对路径。真正的问题不是打字慢，而是**手机上根本看不见电脑的
目录树**：路径全靠记忆，错一层就建到别处。

- 网关新增 `GET /api/mobile/workspaces/roots` 与 `GET /api/mobile/workspaces/browse`：
  给出起点（主目录 / 已登记工作区的上级 / 工作区本身 / 实际用到的盘），逐层列
  **子目录**。
- 范围是算出来的、不是客户端传的：路径不在起点之内就是 400，且只回目录名（选一个
  目录当工作区用不到文件名）。`..`、`\\?\` 一律拒绝。
- App 弹层：起点胶囊 → 目录列表下钻 → 上一级 → 「用「xxx」创建工作区」；已登记的
  目录会直接标出来；名称随所选目录自动带出（用户改过就不再覆盖）；目录还不存在时
  有「在此新建文件夹」。
- 老网关（< 1.15.0）没有这两个接口 → 自动退回手写路径并说明原因，不留白屏。

### 新增：模型选择按**供应商分组**

网关原先把 `providers` 里每家的模型拍平成一个数组，供应商身份在拍平那一刻就丢了，
手机端只能看到一个几十条的平铺列表。现在每条模型带 `provider` / `providerLabel`，
App 侧按供应商分组：分组标题 + 带条数的供应商胶囊（点一下只看这一家）+ 搜索同时过滤
两者。`wb` 与 `qwen` 各自成组，顺序跟配置里一致（不按字母重排）。老网关没这两个
字段时按模型 id 的 `xxx:` 前缀兜底，并在标题上写明"按 ID 前缀"——不把猜测说成事实。

### 修复：「目录概览」执行必然失败（Windows）

默认模板第三条是 `ls -lt`，而网关跑在 Windows 上：`execFile('ls')` 直接 ENOENT，
App 拿不到原因就只能显示「执行失败」，用户看不出是"这台机器没有 ls"。

- 网关内置一份**只读**的 `ls`（`-l/-t/-r/-a`）：不开 shell、不 exec 任何进程；已有
  runbooks.yaml 原样生效，不用改 YAML。其他 POSIX 命令仍按原规则走真实执行器。
- 失败原因一定是一句人话（`command-not-found` → 「电脑上找不到命令 X」），不再让 App
  落到「执行失败」兜底。
- 结果弹层里注明「由网关内置实现结果，未启动系统命令」——不假装电脑上装了 ls。

### 修复：密钥轮换后手机只剩第一句话（网关永久 401）

事故现场（2026-10-22 实测）：dsh web 00:26 启动，网关在 `apply()` 里把
`~/.dsh/.credentials.yaml` 的 secret 读进 cookieFactory；10:19 那个文件被重写（密钥
轮换），网关仍拿旧 secret 签名 → 之后**每一次 RPC 都是 `unauthorized`**，事件流也连
不上。手机端表现为「会话里只剩我发的第一段文字」：历史走不到引擎的 `session/page`，
只能掉到投影缓存 `titleInput` 的兜底；会话信息、流式输出全都没有。

- 根因是**只读一次、用到进程结束**，只能靠重启恢复。现在：RPC 收到 `unauthorized`
  就重读密钥、重建 cookieFactory 并**重试一次**；上游 MUX 重连前也重读一次。
- 边界：只重试一次；密钥没变（文件内容相同）就如实抛原错，不假装重试过；非 401 的
  失败（网络抖动/方法不存在）不触发重载。
- `~/.dsh/mobile-bridge/audit.log` 会记一条 `bridge/secret-reloaded`，事后能查。

### 修复：诊断页把"通"的引擎标成 FAIL

`engine_rpc` 探针原先用假会话号打 `session/page`，引擎回答
`session "diagnostics-probe" not found` —— 那**证明**通道是通的，却被判成失败。
密钥修好之后诊断页仍然一片红，等于把人往错的方向带。

- 探针改用 `session/modelCatalog`（不需要任何 id，无副作用）。
- 新增 `isTransportFailure()`：`unauthorized / ECONNREFUSED / 超时 / 响应解析失败`
  这类才算 down；引擎有应答（域错误、参数错）一律算通，并在 detail 里写明是什么应答。

⚠️ 这个修复本身也要重启 dsh web 才生效（插件在进程内）。

### 顺带

- `runbook_view.dart` 的 `../../` 导入改回 `../`（文件在 `views/` 下一层，旧写法只能
  靠分析器容错通过）。
- 网关 `BRIDGE_VERSION` 1.14.0 → 1.15.0（新路由）。

⚠️ 网关部分需重启 dsh web 生效；App 侧随本版 APK 生效。

## [1.38.0] - 2026-10-21

按 2026-10-21 的优化清单执行。清单里 7 项有 5 项经核实**早已在代码里修好**
（队列路由顺序、投影缓存两种拼写、交付物全量翻页、cwd 父目录回溯、ntfy 去重+
audit），这次只做真正还缺的部分。

### 新增：diff 能区分「本轮改了哪些文件」

以前只能把 `git status` 的**累计**未提交改动整列出来 —— 一个积压了 30 个未提交
文件的仓库会把这 30 个全列上，手机端没法知道哪 3 个是刚跑完那一轮改的。

- 网关取会话日志里**最新一条 `user/message` 之后**的 `tool/call`，据此给每条变更打
  `thisTurn` 三态：`true` / `false` / `null`（`null` = 窗口里没有人类消息，无法判定，
  **绝不**当成 `true` —— 那样会把整个积压说成本轮的工作）。
- 本轮的行排在最前（`sort` 稳定，组内仍按 git 顺序）。
- App 侧在变更行上显示「本轮」小标；`false` 与 `null` 都不显示。
- 扫描有界：git 能回答时只取最新 2 页（`WORKSPACE_CHANGES_TURN_PAGES`），因为这个
  接口在每轮结束时都会打一次；非 git 工作区仍用完整预算，那里 tool-call 就是答案。
- `lastUserTurnStartSeq()` / `thisTurn` 有单测，其中一条专门锁「未知 ≠ 是」。

### 修复：交付物「点不开」被说成权限问题

`resolveDeliverable` 查不到时一律回 403「该文件不在本会话的交付物清单中」，把三种
完全不同的原因混成一句：

| 真实原因 | 现在的回答 |
|---|---|
| 会话没记录 cwd，相对路径解析不到（多为很旧的会话） | `reason: deliverable-cwd-unknown` + 提示「不是权限问题」 |
| 这个会话根本没声明过交付物 | `reason: deliverable-none-presented` |
| 声明过，但请求的路径不在其中 | `reason: deliverable-not-in-set` + 已声明项数 |

回包新增 `reason` / `hint` / `presentedCount`，**不回传清单里的具体路径**（否则拒绝
接口就成了文件枚举口）。`extractDeliverables` / `resolveDeliverable` 下沉到
`core.mjs`，`features.mjs` 原样再导出 —— `features.mjs` 本来就 import
`extensions.mjs`，反向 import 会成环。

### 修复：App 把所有 403 当成 Token 失效

`_checkResponseAuth` 原来判 `401 || 403`，于是**任何资源级拒绝**都会走
`handleAuthFailure()`：清凭据、把用户踢回配对页，并给出「Token已失效或无访问权限」。
网关自己的鉴权拒绝**一律是 401**（`core.mjs` 的 `authenticateRequest` 与 `index.js`
的统一鉴权门），403 从来只表示"这个资源不许"：

- 点开不在清单里的交付物
- 删除内置审批预设
- 读写会话工作区之外的路径

现在只有 401 触发鉴权失败；403 交给各调用方把 `body['error']` 显示出来（它们本来
就会这么做）。这条不改的话，前面那条"更准确的错误原因"根本到不了用户眼前。

### 新增：SecureStore 的观测点与真机验收清单

`SecureStoreBridge.kt` 每个方法都打出 `DshSecure` 标签的 logcat 记录
（**只打长度与结果，不打凭据内容**），`ping` 额外报 `keyExists` —— 这是"改锁屏密码
后密钥被清掉"这类现场唯一能复现的证据。

验收步骤写在 [docs/securestore-device-verification.md](docs/securestore-device-verification.md)：
**那是待办清单，还没有执行记录**（本机没有 Android SDK）。

### 验证

- 网关 `npm test`：**535 项 / 533 过** / 2 跳过 / 0 失败（较 v1.37.2 的 527 项新增 8 条：
  轮次归属 4 条、交付物拒绝原因 4 条）。
- App：`flutter analyze` / `flutter test` **未跑**（本机无 Flutter SDK），Dart 侧改动
  为新增可选字段 + 一处条件渲染 + 一处鉴权判定收窄，需在有 Flutter 的机器上补跑。

---

## [1.37.2] - 2026-10-21

真机反馈两件事：**扫码配对仍失败**（手动填 host+端口可以），**提问卡的「提交回答」
点不到**。

### 修复 1：二维码扫不出来（密度问题）

真机实测载荷 **504 字节** —— 约 121×121 模块，而面板只按 180px 显示，等于
**1.49px/模块**，手机摄像头根本解不出来。这不是协议问题，是我一路加字段把码撑爆了。

- 去掉与 `hosts`/`host`/`port`/`reach` 完全重复的 `lanHosts` / `publicHost` /
  `publicPort` / `expiresAt`（App 一个都没读）；
- 去掉 `certFingerprint`：App **从来没读过**它 —— 真正的 TOFU 在连接层
  `badCertificateCallback` + `CertTrust`，只在自签握手时触发，与配对载荷无关。
  它单独占 76 字节，是最大的一笔冗余；
- 渲染放大：PNG 360→**720**、面板显示 180→**240px**；纠错等级 M→**L**
  （屏幕显示的码不需要 15% 冗余）。

结果：载荷 504→**261 字节**，密度 **1.49 → 3.29 px/模块（2.2 倍）**。

### 修复 2：「提交回答」点不到

提问卡原来写死 `maxHeight: 420`，而它所在的 dock 上限是 **0.45 屏高（约 350dp）**
—— 提交行落在 dock 可视区之外。更麻烦的是**两层滚动**：dock 外层是
`SingleChildScrollView`，卡片内部又有一个滚动区，手指在选项上拖只会滚内层，外层
纹丝不动，于是看起来"按钮永远点不到"。

- `QuestionCard` 新增 `maxHeight` 参数，`ChatBlockerDock` 把 dock 的可用高度传下去，
  卡片按可用空间收缩；
- `maxHeight` 的语义定为「这张卡**占用的总高度**」，内部扣掉自身 8+4 的 margin
  （否则 300 的预算会占到 312，仍然被切掉一点）—— 这一条是被新测试抓出来的。

### 验证

- App：`flutter analyze` 零问题；`flutter test` **835 全绿**。新增用例用
  **`hitTestable()`** 断言提交按钮真的能点中（`findsOneWidget` 只证明它在 widget
  树里 —— 之前的用例正是这样漏掉"按钮存在但点不到"）。
- 网关：`npm test` **527 项 / 525 过** / 2 跳过 / 0 失败（配对载荷断言改为
  `reach`；`/health` 的指纹断言保留，配对载荷明确断言**不含**指纹并写明原因）。

---

## [1.37.1] - 2026-10-21

### 补丁 3（同日 · 仅网关 · 找到"面板切换后隧道从不启动"的真因）

用户贴了截图：面板上已选「临时隧道（cloudflared）」、状态卡显示"隧道未启动"、
进度条空转。查配置：`provider=cloudflared` 确实在 **17:39:26 写进去了**，网关
也在 **17:37:54 重启过**（新代码），但接口一直 `stage=idle`。

**根因：设置页保存走 RPC `config/update`，而 `reconcileRemoteAccess()` 只挂在
HTTP `POST /api/mobile/remote-access` 与网关启动两处。** 也就是说，**最主要的
那个入口（面板切换）恰恰不会启动隧道** —— 配置写进去了，进程从来没被拉起。

### 改法

- `store.mjs` 新增 `onConfigSaved(fn)` 钩子，**`saveConfig` 写完配置后统一触发**。
  网关在 `apply()` 里注册 → 任何保存路径（面板 RPC、HTTP、未来新增的）都会对账，
  不再有"某条路径忘了调 reconcile"这种漏网。
- 顺带修：设置页进度条原来在 `idle` / `stopped` 也会显示（截图里那条空转的蓝条），
  现在只在 preparing / requesting / requested / connecting 阶段出现，并补了
  preparing 的宽度。
- 测试环境加 `DSH_TUNNEL_AUTOSTART=0`：单测绝不真 spawn cloudflared（否则
  provider=cloudflared 的用例会真的连公网）。

### 端到端实测（模拟"面板保存"，独立实例 + 临时 DSH_HOME）

```
1) 初始 provider=none
2) 模拟面板保存 provider=cloudflared ...
   [tunnel] 复用系统中已有的 cloudflared：~/.dsh/dsh-pocket/bin/cloudflared.exe
   t+2s stage=requesting
   t+4s stage=requested  https://highest-rss-critical-make.trycloudflare.com
   t+6s stage=ready
=== 面板保存路径端到端成功 ===
```

### 验证

- 网关 `npm test`：**527 项 / 525 过** / 2 跳过 / 0 失败（新增"任何一次 saveConfig
  都要触发配置已保存钩子"）。
- App：`flutter analyze` 零问题；`flutter test` **834 全绿**（未改动）。

### 补丁 2（同日 · 仅网关 · 我实测复现并修掉了两个真 bug）

用户说"还是不行，你自己能不能先测试一下"。测了，确实不行，原因很具体：

**Bug A：自动启动挂错了地方。** `reconcileRemoteAccess()` 原本在
`tlsServer.listen(...)` 的回调里 —— **TLS 端口没起来时隧道永远不会启动**。而隧道
指向的是明文回环 `127.0.0.1:<listenPort>`，跟本机 TLS 毫无关系。已挪到明文网关的
`server.listen` 回调。

**Bug B：我的"版本不符就重下"把唯一能用的二进制删了。** 真机现场：
`cloudflared.exe.part` **0 字节**（17:18 创建），52MB 下载卡死，而下载阶段没有
任何状态 → 界面只剩"隧道未启动"。而实测 2026.2.0 **是能正常注册的** —— 版本旧
≠ 不能用。改法三条：

- 版本不一致**继续用**现有二进制（只 warn，不删、不阻塞）；
- 自己目录没有时，**先找系统上已有的** cloudflared（`DSH_CLOUDFLARED_PATH` →
  `~/.dsh/dsh-pocket/bin` → 常见系统目录 → PATH）。本机正好有 dsh-pocket 装的
  2026.9.1，直接复用，根本不需要下载；
- 下载加 180s 硬超时，并清理上次残留的 `.part`。

**顺带**：
- 新增 `preparing` 阶段（"正在准备 cloudflared"）—— `ensureCloudflared` 在 spawn
  之前跑，以前这段只能显示"隧道未启动"，用户完全看不出在干什么；
- `audit()` 落盘（上一补丁）在这次排查里直接起作用了：能看到 17:16 重启后**没有
  任何 tunnel/start**，才定位到 Bug A。

### 端到端实测（独立网关实例 + 临时 DSH_HOME，不碰用户实例）

```
[gw] [tunnel] 复用系统中已有的 cloudflared：~/.dsh/dsh-pocket/bin/cloudflared.exe
t+2s  stage=requesting  正在向 Cloudflare 申请隧道域名…
t+6s  stage=requested   已拿到域名，等待边缘注册
t+18s stage=ready       ✅ https://during-commented-slot-trackbacks.trycloudflare.com
=== 端到端成功 ===
```

### 验证

- 网关 `npm test`：**526 项 / 524 过** / 2 跳过 / 0 失败（新增"系统里已有
  cloudflared 时直接复用"；版本用例改为断言"旧版继续用"）。
- App：`flutter analyze` 零问题；`flutter test` **834 全绿**（App 未改动）。

### 补丁（同日 · 仅网关，重启 dsh web 生效，不需要重装 App）

用户追问「临时域名和填了 token 都不行」。做 A/B 对照实验后，三条事实同时成立：

```
同一台机器、同一条命令、只换二进制：
  我的 (cloudflared 2026.2.0)  : Registered=1 → https://semi-bras-…trycloudflare.com
  dsh-pocket (2026.9.1)        : Registered=1 → https://reduces-differ-…trycloudflare.com
```

也就是说：**网络当时是通的、两种形态都能连、两个版本也都能注册**。真正的问题是
三件"看不见"的事：

1. **audit 从来不落盘。** `audit()` 只写内存环形缓冲，磁盘上的 `audit.log` 是更早
   实现留下的死文件（真机最后一行为 **09-28**）。于是"隧道为什么失败、谁在什么时候
   切了 provider"**重启后一个字都不剩** —— 这才是"为什么查不出来"。
2. **版本钉死在 2026.2.0**（2 月构建），且 `ensureCloudflared` 命中已有文件就直接
   复用，永不升级。同机的 dsh-pocket 用 2026.9.1；旧版在这台机器上会额外报
   `cfd-features.argotunnel.com` DNS 超时。
3. **失败原因会被覆盖。** 30s 超时先写好一句能照着做的话，紧接着 kill 进程触发
   `exit` 事件，`lastError` 被改成「退出 code=1」，那句诊断就没了。

### 改法

- `audit()` **落盘**：JSONL 追加到 `~/.dsh/mobile-bridge/audit.log`，超过 2MB 轮转
  成 `.1`；写盘失败不影响业务。
- `CLOUDFLARED_VERSION` → **2026.9.1**；`ensureCloudflared` 增加版本探测
  （`probeVersion`），**版本不符就重下**，一致才复用。
- 隧道失败现场跨实例保留（`lastTunnelFailure`：时间 / 模式 / 阶段 / 原因），
  暴露在 `remote-access` 的 `lastFailure` 字段并写入 audit；`exit` 事件不再覆盖
  已有诊断。失败原因还会通过 `reason` 回落到界面（"上次失败：…"），所以设置页与
  App 现有的那一行就能看到它，不需要新增控件。

### 验证

- 网关 `npm test`：**525 项 / 523 过** / 2 跳过 / 0 失败。新增 2 条：版本过旧要
  重下、版本一致才复用；audit 必须落盘。

### 修复 + 增强（cloudflared：照 `dsh-pocket` 的做法重做，四条差异三条是我错了）

用户让参考 `dsh-pocket` 的实现。读完它的 `lib/tunnel.mjs`（621 行）后，我的隧道
实现有四处与人家不同，其中三处是我的问题：

| 项 | dsh-pocket | 我原来 | 结论 |
|---|---|---|---|
| 指哪 | `http://127.0.0.1:<port>`（**明文回环**） | `https://127.0.0.1:3443`，且 TLS 没起来就 409 | **我错**：公网那一段由 Cloudflare 终结 TLS，本机是回环，把「必须有 TLS」当前置条件是绑死两件无关的事 |
| 超时 | 30s 硬超时，文案直接点名 Clash TUN 会掐断隧道 | 无超时，边缘被阻断就永远 `starting` | **我错**：「永远未就绪」的根源之一 |
| 地址解析 | 正则排除 `api.` 子域（issue #32） | `https://[a-z0-9-]+\.trycloudflare\.com` —— 会把申请失败时打印的 `https://api.trycloudflare.com` 当成隧道地址 | **我错**：真机探针输出里就有这一行，手机拿到的会是 API 端点（返回 10005） |
| 形态 | 快速隧道 + **命名隧道**（自带 token + 固定域名） | 只有快速隧道 | **缺能力**：随机域名每次重连都变，谈不上"能用" |

### 改法

- **目标改明文回环**：隧道指向 `http://127.0.0.1:<listenPort>`，删除「TLS 未启用
  → 409」这条前提（`tls-disabled` 分支一起删掉）。隧道与自签证书从此无关。
- **30s 硬超时**：没建立就判 `failed`，`lastError` 写明「若开着代理/VPN（Clash 等
  TUN 模式）会掐断隧道连接，退出后重试；或改用自己的反向代理（NPS）」。
- **地址解析排除 `api.`**：`parseTunnelUrl` 加负向前瞻，并补了用例（`api` 子域、
  纯 `https://api.trycloudflare.com` 都必须返回 null）。
- **命名隧道**：`remoteAccess.cloudflared = { token, host }`。token 非空 → 用
  `--no-autoupdate tunnel run --protocol http2`（token 走 `TUNNEL_TOKEN` 环境变量），
  就绪后地址取配置域名（cloudflared 不会打印它）；token 为空 → 快速隧道。
  设置页在 cloudflared 档下多两个输入框（token / 固定域名），并注明在 Cloudflare
  Zero Trust 里把隧道指向 `http://localhost:3088`。
- 同时删掉 `--edge-ip-version 4`（对齐参考实现；http2 已在用 TCP 443）。
- 服务端 `remote-access` 多返回 `mode`（`named` / `quick`），App 远程访问页显示
  「形态：命名隧道（固定域名）/ 快速隧道（地址会变）」。

### 验证

- 网关 `npm test`：**523 项 / 521 过** / 2 跳过 / 0 失败。新增 4 条 tunnel 用例：
  明文回环参数、`api.` 子域不被当地址、30s 超时点名代理、命名隧道走 `tunnel run`
  且就绪后用配置域名；另加 1 条路由用例（配 token 切 named 模式）。
- App：`flutter analyze` 零问题；`flutter test` **834 全绿**。

### 仍未解决的问题（如实说明）

这台机器**连不上 Cloudflare 隧道边缘**（探针实测 5 次重试全失败）。上面这些改动
让失败变得**可见且可操作**（30s 内给结论 + 点名代理），但没有改变"出站被阻断"这个
客观事实。要让 quick/named 隧道真的在这里工作，需要让
`198.41.192.0/19`、`198.41.200.0/24` 的 **7844（TCP+UDP）** 走直连；有固定域名时
命名隧道是更合适的形态。

---

## [1.37.0] - 2026-10-21

### 修复（设置页整体逻辑：**对外宣称的地址只有单一来源了**）

用户实测三连问，逐条查下来是同一个病根：**"这台机器叫什么地址"被四个地方各写了
一遍**，谁也不看 provider。

| 现象 | 真因 |
|---|---|
| 选「仅内网」，二维码里还是公网域名 | 配对载荷**无条件**用 `cfg.npsHost`（三处各写一份：`/pair/qr`、`/pair/info`、设置页 RPC） |
| 局域网地址是 `172.19.0.1` / `172.20.128.1` | `getLocalIp`/`primaryLanIpv4` 取「第一个非 internal IPv4」——那是最先枚举到的 Clash TUN 与 WSL 虚拟网卡；真实网卡是 `10.49.80.16` |
| 只有「未就绪」，没有进度 | 服务端只回 `status: starting`，界面无法区分「申请域名 / 等边缘 / 边缘重试中」 |

### 改法

- **新增 `lib/net-address.mjs`**：按「虚拟网卡判死 + 真实网卡加分 + 网段排序
  （192.168 > 10 > 172.16-31、APIPA 排最后）」挑选局域网地址。`/health`、配对
  载荷、`remote-access`、设置页 RPC 全部改用它 —— 不再有第二套算法。
- **新增 `advertise()`**：对外地址的唯一来源。`provider=none` 时 **publicUrl 恒为
  null**；`nps` 用配置拼；`cloudflared` 只在边缘注册成功后才有值。
- **三个配对载荷入口合并成 `buildPairPayload()`**：`/pair/qr`、`/pair/info`、设置
  页 RPC 共用一份（此前是三份拷贝，细节各不相同：一份有 `expiresAt`、一份没有）。
- **配对载荷新增 `scheme` 与 `lanPort`**：公网可能是 https（NPS 开 TLS 或
  cloudflared），而 App 之前硬编码 `http://$host:$port` 去配对 —— 扫公网二维码
  必然失败。现在 App 按 `scheme` 配对，局域网回退一律 http + 网关监听端口。
- **进度可视化**：`tunnel.mjs` 暴露 `stage` / `attempts` / `startedAt`，服务端转成
  `stage / stageLabel / attempts / elapsedMs`；电脑端设置页有阶段进度条（申请
  30% → 等边缘 65% → 重试 85%）+ 「第 N 次重试 · 已用时 12s」，手机端有
  `LinearProgressIndicator` + 同样的阶段文案，并在建立中每 3 秒自动轮询。
- 设置页两张卡都改成如实显示：**公网地址 / 局域网地址 / 手机现在该走哪条**；
  二维码卡显示「二维码里的地址（含 scheme）」与「扫码的手机需在同一局域网」。

### 验证

- 网关 `npm test`：**517 项 / 515 过** / 2 跳过 / 0 失败。新增 8 条 `net-address`
  用例（真机形态：WSL 排在前面仍要挑出真实网卡；Clash TUN 不能当首选；APIPA 排
  最后）与 2 条载荷用例（**provider=none 时二维码绝不能再带公网域名** ← 这次
  报的 bug；provider=nps 时 scheme/端口跟着配置走）。
- App：`flutter analyze` 零问题；`flutter test` **834 全绿**。

---

## [1.36.4] - 2026-10-21

### 补丁（同日 · 仅网关，重启 dsh web 生效，不需要重装 App）

用户问「我切换了 provider，怎么知道隧道生成成功没有」—— 暴露的缺口是：选择在
**电脑端设置页**，而那一页看不到隧道的实时状态，得跑去手机或命令行确认。

- 新增 RPC `remote-access/status`（与 HTTP `GET /api/mobile/remote-access`
  共用同一份实现，由 `index.js` 注入 —— 隧道进程状态在那边，不能在 rpc 层另算）。
- 设置页新增「🌐 远程接入状态」卡：当前方式 / 公网地址 / 就绪 / 出口由谁提供 +
  失败原因 + 「复制公网地址」。cloudflared 未就绪时**每 3 秒自动轮询**（点完保存
  用户会盯着这一屏等，让他自己点刷新等于把结果变成猜谜），就绪后停止轮询。
- 保存后立刻拉一次状态，切到 cloudflared 时能当场看到「未就绪 → 已就绪」。
- 注意：`client.js` 自带一份 `ENDPOINTS`（浏览器侧不能 import 服务端模块），
  加端点必须两处都改，代码里已写明。

### 补丁 2（同日 · 仅网关，重启生效）：边缘重试不再「永远未就绪」

真机切到 cloudflared 后一直显示未就绪。探针实测暴露出两段失败：

```
failed to request quick Tunnel: Post https://api.trycloudflare.com/tunnel:
context deadline exceeded                      ← 默认协议下连申请都超时
INF | https://xxx.trycloudflare.com |           ← 加 --protocol http2 后域名拿到
INF Retrying connection ... ip=198.41.192.57    ← 但连不上边缘，2→4→8→16→32s 无限退避
```

代码原来只认 `unable to establish connection with cloudflare edge`，而实际输出是
`Retrying connection` —— 状态于是永远停在 `starting`，界面永远「未就绪」，用户
看不出原因。（另：`Test-NetConnection` 对 7844 显示「可达」不可信，本机 Clash
TUN 会把 connect 伪造成成功。）

- 三次重试仍不成功就判 `failed`，`lastError` 写明「到 198.41.192.0/19:7844 的
  出站被阻断」并给出替代方案（改 NPS / 放行该网段）；
- 判失败后杀掉进程，不留一个按 32s 退避永远重试的僵尸；
- 两次以内仍算 `starting`（网络抖动不该立刻判死）。

### 重构（远程接入：NPS 与 cloudflared 收敛成同一个能力的两种 provider）

用户指出的设计问题：**这两件事是同一层的东西，却被实现成两个互不知晓的功能**。
`cloudflared` 是「没有 NPS 时的接入方式」，和 NPS 同级，不是另一个独立功能。

原来的错位：

| | NPS | cloudflared |
|---|---|---|
| 配置在哪 | 电脑端 config（`npsHost/npsPort/useHttps`） | 无配置，进程状态只在内存 |
| 谁启停 | 不需要（外部反代） | **手机端的按钮** |
| 就绪判定 | 无 | `Registered tunnel connection` |
| 与对方的关系 | 不知道 cloudflared 存在 | 不知道 NPS 存在 |

所以用户既看不出这是二选一，也不知道该填哪个地址；更要命的是**隧道没开时手机
根本连不上，那个"开启隧道"的按钮点不到**（死循环）。

### 定案：严格互斥，三选一

```json
"remoteAccess": { "provider": "none | nps | cloudflared", "nps": { "host": "", "port": 3088, "useHttps": false } }
```

- **配置在电脑端**（DSH 设置页新增「远程接入方式」三选一 + NPS 字段）；
- **cloudflared 随网关启动自动拉起、退出自动回收**，切走 provider 时立即停掉
  （互斥的执行点）；
- **手机端只读**：`GET /api/mobile/remote-access` → provider / 公网地址 / 是否就绪
  / 原因。手机上的开关全部删除，改为「复制地址」「填入下方」两个动作；
- **旧配置零回归**：只有 `npsHost` 的老安装按「填了就是 NPS」映射成
  `provider: nps`；新装默认 `none`（此前默认值写死了 `n.cnm.asia`，等于让任何
  人装完就指向一个他不拥有的域名）。

### 改动清单

- 网关 `store.mjs`：`normalizeRemoteAccess` / `legacyNpsFields`，`loadConfig`
  做旧→新映射，`saveConfig` 同时接受新旧两种写法（顶层字段与 `remoteAccess`
  永远同步，不再有两个真源）。
- 网关 `index.js`：`remoteAccessPayload()`（统一视图）、`startQuickTunnel()`
  （提取自原路由，幂等）、`reconcileRemoteAccess()`（互斥执行点）、
  `GET/POST /api/mobile/remote-access`、TLS 就绪后自动对账；旧
  `/tunnel/start|stop` 降级为**只对 cloudflared 生效**的排障端点（provider 不是
  cloudflared 时 409 `provider-not-managed`）。
- 网关 `rpc.mjs`：`config/get` 下发 `remoteAccess`，`npsUrl` 只在 provider=nps
  时给值。
- 电脑端设置页 `client/client.js`：三选一按钮 + 条件显示的 NPS 字段与 HTTPS 勾选；
  保存只写 `remoteAccess`。
- App：新增 `models/remote_access.dart`；`refreshRemoteAccess()` 取代
  `refreshTunnel/startTunnel/stopTunnel`（后三者删除，无人再用）；远程访问页
  从「配置 + 开关」收敛成「状态 + 复制 + 指纹确认」。

### 验证

- 网关 `npm test`：508 项 / **506 过** / 2 跳过（POSIX）/ 0 失败。新增
  `remote-access.test.mjs`（6 条：新装默认 none、旧配置映射、切换保留 NPS 字段、
  缺 host 回落、旧字段自动切 nps、显式 none 不被覆盖）与 8 条路由用例
  （互斥 409、缺 host 400、managed/ready 语义、TLS 关闭拒绝开隧道）。
- App `flutter analyze` 零问题；`flutter test` **834 全绿**（新增 5 条模型解析）。

### 顺带修掉的两个自造缺陷

- 切换 provider 时**不能 await 隧道启动**：首次要下载 60MB 二进制，await 等于让
  「点一下切换」卡几分钟。现在只落配置并后台发起，状态由 GET 如实反映。
- 新路由一开始被放在 `jsonBody` 解析**之前**，命中 TDZ
  （`Cannot access 'jsonBody' before initialization`），请求永不返回 —— 测试是
  靠"卡住 15 秒"暴露的。

---

## [1.36.3] - 2026-10-21

### 变更（Runbook 搬进会话信息面板）

- **新增「Runbook」tab**：会话信息面板从「概览 / 轨迹」两档变成三档，Runbook
  作为第三个 tab 嵌进去（复用 `RunbookView`，`embedded: true` 时不画自己的
  Scaffold/AppBar，避免双层标题）。
- **同时修掉一个让它基本不可用的缺陷**：命令在哪个目录跑，网关的规则是
  「会话给了 `cwd` 就用会话的，否则回落到 `~/.dsh`」。原设置页入口没有会话
  上下文，于是默认模板三条里两条 git 命令直接
  `fatal: not a git repository（exit 128）`。现在宿主把当前会话 id 带上，
  `cwd` 就是该会话的工作区。
- **移除设置页的 Runbook 入口**：搬走而不是复制一份 —— 没有会话上下文的那个
  入口只会跑出上面那个错。测试里加了反向钉子（该 key 必须不存在），谁要加回来
  得先解决目录问题。

### 顺带带上（网关，需重启 dsh web 生效）

- `skills/list` 补齐 `request` 包裹层：上一版按 `commands/list` 的形状发了
  `{ args: { sessionId } }`，但它的参数是 `request`（`source: json`），引擎拿到
  `undefined` 直接抛错 → 手机端只显示「当前工作区没有可用技能」。现在失败原因
  还会写进宿主日志（原始错误不下发客户端）。

### 验证

- App：`flutter analyze` 零问题；`flutter test` **829 全绿**（新增「信息面板里有
  Runbook tab」「嵌入模式不画 AppBar」「设置页不再有 Runbook 入口」三条）。
- 网关：`npm test` 495 项 / 494 过 / 2 跳过（POSIX）/ 0 失败。

---

## [1.36.2] - 2026-10-21

手机端 `/` 菜单补上**技能目录**。真机反馈：手动打 `/` 只出来默认的几个命令，而
web 端同样的 `/` 能列出全部 skill / 插件。

### 修复（斜杠菜单 · App + 网关）

- **根因**：web 的 `/` 菜单是**两路合并** —— 命令来自引擎 `commands/list`，技能
  来自 `skills/list`（`@deepseek-ai/dsh-client-ui-skill` 的 fetchCatalog 直接调
  `skills.list({ sessionId })`）。手机端此前只接了命令那一路，所以 skill 一个都
  不出现。
- **网关**新增 `GET /api/mobile/sessions/skills?sessionId=…`，转发引擎
  `skills/list`，只挑手机菜单需要的 `name` / `description` / `source`
  （`description` 为空时回落到 `whenToUse`）。引擎拒绝时回空表 + `degraded`，
  **不给静态兜底**：硬编码的 skill 名字等于教用户输引擎不认的命令。
- **App**：手动输入 `/` 的面板改为「命令 · 模板 · 技能」三段，技能单列一组
  （与命令语义不同：一个由引擎注册、一个来自 skill 目录，混排会让人分不清）。
  选中技能与命令一样插入 `/name ` —— 与 web 端一致。

### 行为约定（用户指定）

- **点闪电按钮 = 默认的那几个**（命令 + 模板），不拉技能目录；
- **手动输入 `/` = 全部**（命令 + 模板 + 技能）。

### 验证

- 网关：`npm test` 495 项 / **493 过** / 2 跳过（POSIX）/ 0 失败。新增 4 条：
  透传与 `whenToUse` 回落、`value{}` 包装容错、引擎拒绝降级、缺 sessionId 400。
- App：`flutter analyze` 零问题；`flutter test` **827 全绿**。原「打 / 弹出模板面板」
  用例按新行为改写为「弹出全量面板」，并新增「点闪电不带技能组」的对照用例。

---

## [1.36.1] - 2026-10-21

真机反馈的两处**消息渲染**缺陷，根因都在 `widgets/safe_markdown.dart`。同时把上一版
遗留的网关侧「停止发包」改动随本版一起发（1.36.0 的 APK 先行发布，网关改动当时
还没进仓库）。

### 修复（消息渲染）

- **段内单换行被折叠成一个空格**：`MarkdownBody` 默认 `softLineBreak: false`，
  flutter_markdown 的实现是 `text.replaceAll(' ?\n *', ' ')`。而模型正文习惯用
  **单换行分句、空行分段**，于是整段文字在手机上糊成一坨（网页端是 GFM breaks
  语义，正常换行）。改为 `softLineBreak: true`，单换行按硬换行渲染，与网页端一致。
- **```dsh-ui 围栏退化成裸 JSON**：清洗层的围栏正则只认 `\n` —— 闭合围栏的模式是
  `^[ \t]{0,3}`{3,}[ \t]*$`，CRLF 下这一行是 "```\r"，`\r` 不在 `[ \t]` 里，匹配
  必然失败，整段于是被当成**未闭合代码块**，本该渲染成列表/表格的地方显示成一坨
  JSON。现在清洗入口先把 `\r\n` / `\r` 归一成 `\n`。

### 移除（网关侧，需重启 dsh web 生效）

- **网关不再托管、也不再分发安装包**：删除 `/dsh-agent.apk` 与
  `/api/mobile/download/apk` 两个路由、`lib/apk-source.mjs`（含「本地没有就从最新
  Release 自动抓回」的缓存层）、`/api/mobile/version` 里的
  `apkUrl`/`apkSize`/`apkMtime` 字段，以及设置页 RPC 返回的 `apkUrl`/`npsApkUrl`。
  安装包的唯一来源是 **GitHub Releases** —— App 的更新检查本来就直连
  `releases/latest/download/latest.json`（`models/update_service.dart`），本次只是
  把网关这条多余通路彻底去掉。
- **网关首页的 APK 卡改为 Releases 链接**，删掉指向 `/dsh-agent.apk` 的二维码与
  写死的版本/大小（那两行早已停在 `v1.1.0 · 22.28 MB`，是典型的陈旧信息）。

移除理由：这层缓存必须与远端版本对齐，一旦忘记刷新就会长期静默发旧包（1.31.1
事故）；而且 `ensureApk` 只判「文件存在且 >1MB」就返回，**从不比对版本** ——
上一版发布时实测 `public/dsh-agent.apk` 仍是 10-19 的 v1.35.1，正是这个缺口的复现。
网关既不留包也不转发包，就不存在"发的是哪一版"这个状态。

### 验证

- App：`flutter analyze` 零问题；`flutter test` **826 全绿**（新增
  `test/widgets/safe_markdown_render_test.dart` 3 条：CRLF 围栏仍出组件、LF 对照、
  段内单换行保留）。
- 网关：`npm test` 491 项 / 489 过 / 2 跳过（POSIX）/ 0 失败。
- 两条渲染修复都有 widget 级回归钉子；真机观感由用户侧确认。

---

## [1.36.0] - 2026-10-21

一次「把审查结论真正改掉」的版本：文档归因订正、深色模式可读性、几处会让状态卡死
或让人误判的空态/超时兜底，以及无障碍与触控热区。

### 修复（视觉与可读性）

- **深色模式角标白字读不出来**：`main_shell` 的待办数字与输入区队列角标都是白字
  压在亮琥珀上，深色侧对比度仅 **1.65:1**（正文 AA 要求 4.5:1）。新增 `onWarning`
  token，两侧改用深色前景（浅色 5.62:1 / 深色 10.5:1）。
- **实心品牌蓝上的白字偏淡**：深色 accent(`#6E8BFF`) 上白字仅 **2.6:1**。新增
  `onAccent` token，替换 14 处按钮/图标的 `Colors.white`（深色 5.60:1）。

### 修复（状态与兜底）

- **提问卡可能永久停在「发送中…」**：提交成功分支原先从不复位提交态，只等网关
  `question_settled` 事件。该事件丢失（重连 / 切后台 / 网关重启）时卡片永久禁用，
  用户既不能重发也不能改答，而 agent 侧一直阻塞。现在 8 秒兜底复位，并提示
  「没收到确认，可再点一次提交」。
- **工作区页把「还没加载」说成「没找到」**：冷启动或断网时用户没有任何搜索行为，
  却看到「没有找到匹配的工作区」，会读成数据丢了。现在三态：加载中转圈 /
  失败带错误原因与重试 / 真空（无搜索词时只说「还没有工作区」）。
- **推荐问题插入不落草稿**：点「分析项目代码」这类推荐后，文本只写进输入框控制器，
  不写 DraftStore、光标也没有位置 —— 进程被杀即丢，且要再点一次输入框才能接着
  打字。改为与模板插入同一条路径（追加 + 光标到末尾 + 写草稿）。
- **保存项目记忆 / 审批批准拒绝可连点**：弱网下连点会发两次 PUT、两条 respond
  （第二条落在 `alreadyGone`，界面看起来像报错）。补 in-flight 禁用 + 转圈 +
  8 秒兜底。

### 修复（布局与适配）

- **审批/提问 dock 高度没扣键盘**：上限按全屏高度算，而 chat 页已关
  `resizeToAvoidBottomInset`，小屏 + 键盘时会把消息区挤得很小。改为先扣
  `viewInsets.bottom` 再取 45%。
- **MEMORY.md 编辑弹层不可滚**：固定 220 高编辑器 + `Column(min)` 无滚动容器，
  640dp 小屏 + 键盘必然溢出。现在整层可滚，编辑器高度按可用高度自适应 120~220。
- **复制路径热区只有 13dp**：裸 `Icon` + `GestureDetector`，真机上要瞄。新增
  `MinimumTouchTarget`（44dp 基线，本处取 38dp），命中区 13dp → 38dp。
  刻意**不**把整行改成可点：那会让 `ExpansionTile` 的中心落进复制区，点卡片变成
  复制而不是展开（本次改法被既有测试当场挡下，见验证）。

### 修复（无障碍）

- 发送键、排队角标、消息「⋯」、复制路径补 `Semantics` 标签；此前读屏只念「按钮」。
  全 lib 的 `Semantics(` 从 2 处增至 6 处。

### 修复（构建）

- `compileSdk` 显式 35（原跟随 `flutter.compileSdkVersion` 解析为 34，而
  `flutter_plugin_android_lifecycle` 已要求 ≥35，构建一直在打警告）。

### 文档

- 订正「本机无 Android SDK」的错误归因：SDK 在 `D:\android-sdk`、模拟器
  `dsh_test` 也在，真实阻塞是工作区路径含非 ASCII 字符被 AGP 8.1 拒绝
  （`android.overridePathCheck` 亦无效）。详见 `docs/2026-10-20-全面审查分析.md`。
- 新增该分析文档：审查基线、按严重度的问题清单、修复记录与未做项的理由。

### 验证

- App：`flutter analyze` 零问题；`flutter test` **823 全绿**（原 821，新增
  `test/widgets/workspaces_empty_state_test.dart` 2 条，钉住「无搜索行为不能说
  没找到」这条动机本身）。
- 网关：`npm test` 500 过 / 2 跳过 / 0 失败（本版未改网关代码）。

### 已知边界

- **本版 UI 改动未经真机验证**：本机无真机/模拟器在连（`adb devices` 为空），
  且工作区路径含非 ASCII 字符导致本地无法出包。按仓库纪律（v1.27.1 的教训）
  这些行为变化应在真机上看一眼再发；本次按要求补齐版本与 CHANGELOG 后发布，
  真机验收由用户侧另行安排。
- **消息页重建仍未收窄**：`chat_view` 顶层 `Provider.of` 仍是 listen:true，流式
  期间顶栏与输入卡片会跟着重建。收窄需要改 `ChatAppBar` / `ChatTopBanners` /
  `ChatComposer` 的构造契约，属独立重构，未在本版做。

---

## [1.35.1] - 2026-10-19

### 新增

- **桌面小组件**（补上 1.35.0 的已知边界）：显示当前会话、连接/执行状态、
  上下文占用与待审批数量。数据由 App 推入（连接态、会话、待审批都活在 Dart 侧，
  原生自己拉一遍必然与 App 内显示不一致）；部件在 App 进程未启动时也能渲染上次
  快照。
  - **部件上没有「批准」按钮**：部件没有展示命令原文的位置，一次误触的代价不对
    称。点击整块 = 打开 App。
  - 节流 5 秒 + 内容去重；待审批数 > 0 时绕过节流立即刷新。

### 修复

- **重启 dsh web 会给自己记一条「引擎连接丢失」告警**：上游 MUX 在主动关闭时
  同样触发 close 回调，被当成故障写进收件箱（1.35.0 实测：重启后台就有一条
  critical）。现在主动关闭（isDisposed）不再入箱。

### 验证

- App：`flutter analyze` 零问题；`flutter test` 全绿（新增小组件通道 4 条：
  去重 / 节流 / 待审批强制刷新 / 通道缺失静默降级）。
- Kotlin 与 AppWidget 布局**由 CI 构建验证**（本机虽有 Android SDK，但工作区路径
  含非 ASCII 字符，AGP 在配置期直接拒绝构建；`android.overridePathCheck` 也只在
  Dart 前端换一种失败方式。详见 `docs/2026-10-20-全面审查分析.md` §2.1）：
  `Build Android APK` 通过即说明原生侧至少能编译与打包。

---

## [1.35.0] - 2026-10-19

一个「出门也能干活」的版本：加密通道、锁屏一键审批、Runbook 与告警收件箱。
四个功能都是同一个问题的不同侧面 —— 人不在电脑前时，Agent 还能不能继续跑。

> ⚠️ **网关侧改动需重启 dsh web 后生效**：TLS 监听与证书、配对指纹下发、
> cloudflared 托管、Runbook 路由、告警引擎、审批令牌与 decide 端点。App 侧
> 改动随本版 APK 生效。

### 新增（安全通道 · 网关侧）

- **自签 TLS（3443）+ TOFU 指纹**：`lib/tls.mjs` 零依赖签发 ECDSA P-256 自签证书
  （幂等复用、SAN 变化重签、旧证书备份、私钥 0600）；`/health` 回 `tlsPort` 与
  `certFingerprint`；`/pair/qr`、`/pair/info`、设置页二维码统一携带指纹。
  - 明文 3088 **行为不变**：TLS 是新增端口不是替换，老配置零回归。
  - `BRIDGE_TLS_PORT=0` 可关闭；端口被占用只 warn，不阻断明文端口。
- **App 侧 TOFU**：`services/cert_trust.dart` 三态（首次信任 / 匹配 / 变更需确认），
  按「网关 × 通道」分条存 Keystore；指纹变化时**拦截连接并停止自动重连**，
  在「远程访问」页面展示新旧指纹供用户判断。
- **cloudflared quick tunnel 托管**：`lib/tunnel.mjs` 固定版本下载（sha256 或
  头部校验、失败不阻塞启动、系统 curl 兜底）、地址解析、进程随宿主退出。
  - 就绪判定以 `Registered tunnel connection` 为准：先打印域名再连边缘，
    边缘握手失败时域名是死的（访问会得到 Cloudflare 1033），不能报 ready。
  - `DSH_CLOUDFLARED_PATH` 可直接复用已装好的二进制。
- **「远程访问」二级页**：隧道开关与当前地址、远程地址配置（**强制 https**，
  明文远程直接拒绝）、证书指纹与变更确认。远程保存在独立 profile
  （`<id>-remote`）里，局域网那条仍然保留，可一键切回。

### 新增（锁屏即时审批 · 网关侧 + App）

- **单次审批令牌**：审批入队时铸造 24 字节令牌（15 分钟 TTL、只存 SHA-256），
  新增 `POST /api/mobile/approvals/decide`，结构化错误码
  `unknown / expired / mismatch / consumed / conflict / sensitive / engine-rejected`。
  同向重复请求幂等（`alreadyApplied`），反向请求 409。
- **敏感审批不给令牌**：`danger-full-access` 策略下的审批 `approvalToken: null`，
  通知不出现批准按钮，必须回 App 看命令原文 —— 一次误触不该等于无确认执行。
- **通知动作按钮**：审批通知带 批准 / 拒绝 / 稍后 三个动作；动作直接调 decide
  端点（不经过 device token），结果显示为一条简短通知。稍后只收起通知、不答复
  网关，回 App 里仍能看到审批。
- **审计不含明文令牌**：`approval/requested` 记录会剥掉 token。

### 新增（运维台 · 网关侧 + App）

- **Runbook**：`lib/runbook.mjs` + `~/.dsh/mobile-access/runbooks.yaml`。
  命令在网关侧执行，**不过 shell**：管道/重定向/连接符一律拒绝，二进制走白名单
  （`DSH_RUNBOOK_ALLOW` 可扩展），`danger: high` 强制二次确认，输出只回尾部 N 行。
  改完 YAML 刷新即生效。App 侧「Runbook」页展示命令原文、高危弹确认、结果带
  退出码与耗时。
- **告警引擎**：`lib/alerts.mjs` + `~/.dsh/mobile-access/alerts-state.json`。
  四条规则（回合失败 / 上下文过高 / 引擎掉线 / 作业失败），10 分钟去重窗口，
  只有 critical 走 ntfy 推送。App 侧新增「告警」收件箱与未读徽标。

### 修复（真机验证中暴露）

- **下载通道单点**：Node 的 https 在 `release-assets.githubusercontent.com`
  上被 EOF 断开（curl 可下），下载增加文件直写与系统 curl 兜底。
- **隧道状态撒谎**：此前解析到域名就报「已开通」，边缘连不上时用户看到的是一个
  永远打不开的地址；现在边缘失败如实降级并保留原因，status 端点也不再把失败
  回落成 idle。

### 验证

- 网关：`npm test` 491 项，489 通过（2 项 POSIX 权限用例在 Windows 跳过）。
- App：`flutter analyze` 零问题；`flutter test` 全绿。
- 真机（2026-10-19，用户执行重启后）：HTTPS 3443 健康检查通过、配对指纹三处
  一致、明文 3088 零回归、WSS 真实握手成功。

### 已知边界

- **桌面小组件（原计划 3.5）本期未交付**：需要本地编译与真机渲染验证。本机虽有
  Android SDK 与 `dsh_test` 模拟器，但工作区路径含非 ASCII 字符，AGP 拒绝构建；
  也无真机在连。按仓库自身纪律（v1.27.1 的教训：没上真机就发版会出事），
  不盲写原生代码，留到下一版。
- **quick tunnel 在受限网络不可用**：本机到 Cloudflare 边缘的 TLS 握手被 EOF
  断开（QUIC 与 http2、直连与本地代理都试过）。功能实现完整，换网络即可用；
  国内长期使用建议 Tailscale 或自有反向代理（把 NPS 目标改到 3443 的 TLS
  端口即可让现有隧道变成 HTTPS）。
- **App 侧动作按钮未做真机验证**：本机无真机/模拟器在连，且工作区路径含非 ASCII
  字符导致本地出包被 AGP 拒绝，随本版发布后由用户验证。
  客户端逻辑已有单测覆盖（令牌解析、按钮门槛、错误码文案）。

---

## [1.34.1] - 2026-10-18

### 修复（用户反馈：⚡ 面板最底下吊着一行「提示词模板」）

- 分组标题原先**无条件渲染**：网关没下发模板时（很常见），弹层底部只剩一行
  没有内容的标题，看起来像界面坏了。现在**哪组有内容才画哪组标题**，
  两组的标题分别叫「本地快捷指令」「网关模板」，只有一组时两个标题都不画
  （弹层标题已经叫「命令与模板」，额外一行只增加噪音）。

### 变更（用户反馈：会话顶部那个左箭头有必要吗）

- **删除**顶栏的返回箭头。它等价于底部「工作区」tab 与 Android 侧滑返回
  （`PopScope` 已把"对话页侧滑"映射成切 tab），而会话是一级 tab、不是推入页，
  箭头等于"从一个根跳到另一个根"，语义不成立。
- 随之删掉 `ChatAppBar.onBackToWorkspaces` 与 `ChatView.onOpenWorkspaces`
  两个已无调用者的参数；`automaticallyImplyLeading: false` 防止将来被包进
  推入路由时又冒出一个箭义错误的箭头。
- 标题左侧空出 48dp，长会话名不再那么早被省略。

### 验证

- `flutter analyze` 无问题；`flutter test` 全过（+1：顶栏无返回箭头；
  「只有一组时不画分组标题」并入既有面板用例）。

---

## [1.34.0] - 2026-10-18

### 修复（用户反馈：从「关于与更新」返回会弹出输入法）

- 根因是**焦点恢复**：对话页的输入框保活在 `IndexedStack` 里，切到设置后它仍是
  "最后一个获得焦点的可编辑控件"，从二级页返回时 Flutter 把焦点还给它 → 系统
  输入法自己弹出，而屏幕上没有任何输入框。
- 三处一起修：切 tab 时 `unfocus`；推设置二级页前 `unfocus`；不在对话页时用
  `ExcludeFocus` 把整棵对话子树排除在焦点之外（防止任何路径再把焦点还回去）。

### 修复（用户反馈：检查更新没用）

- **真因在发布侧，不在客户端**：`build-apk.yml` 只上传 APK，从来没产出
  `latest.json`，而 App 读的正是 `releases/latest/download/latest.json` —— 永远
  404，只能回退成"更新检查不可用"。
- 新增 `scripts/latest-manifest.mjs`：从 pubspec + build.gradle 解析
  version / versionCode / packageName，对 `arm64-v8a` 包算 size 与 sha256，
  产出与 `UpdateManifest` 一一对应的清单（含 releaseNotes）。
- 发布 job 生成 `dist/latest.json` 并作为 release 资产上传；生成失败即 job 失败
  （不允许"发了一个没有清单的版本"）。
- 「更新检查不可用」对话框现在带出**具体原因**（HTTP 状态/解析失败/异常），
  用户能分清是发布侧漏传还是手机到不了 GitHub。

### 新增

- **附件多选**：图片、文件都支持一次选多个；单条失败不拖垮整批，最后汇总
  "加了几个 / 跳过几个 / 为什么"。
- **内联图片总预算**：多选后按整条消息累计（`maxInlineTotalBytes` 1.4MB 原始
  字节）判断，超出预算的图不挂上并明确说明 —— 否则会在发送时才撞网关 2MB 上限。
- 输入框默认两行（`minLines: 2`），一行看起来太窄；超过 5 行才滚动。

### 验证

- `flutter analyze` 无问题；`flutter test` 全过。
- `node scripts/latest-manifest.mjs` 本地跑通，字段与客户端解析一致。

---

## [1.33.0] - 2026-10-18

### 修复（用户反馈：快捷指令"没地方使用"）

- **本地快捷指令不再需要重启 App 才可见。** 根因：`ChatComposer` 常驻在
  `IndexedStack` 里、State 永不复建，本地条目只在 `initState` 读一次盘 ——
  设置页新建/删除之后回到对话页，面板里还是 App 启动那一刻的快照。
  现在**每次打开面板都重读一次**（`_openCommandOrSnippetSheet`）。
- **面板空态不再静默降级。** 本地为空时给出一句说明 + 「去新建」按钮，
  直接推到快捷指令页；此前会悄悄回落到只有斜杠命令的老面板，一句解释都没有。
- **打一个 `/` 自动弹出同一个面板**。⚡ 图标没有文字、tooltip 只有长按可见，
  是这套功能唯一的入口 —— 用用户本来就有的斜杠习惯把它带出来。
- 修复 `_appendSnippetTemplate` 的格式损坏（`{ final cur` 挤在一行）。

### 变更（设置页：全量表单 → 入口式 hub）

用户反馈「设置页显得杂乱」后按"层级"重排，而不是只调视觉：

- **首页只留状态与入口**：连接与诊断 / 通知（状态卡 + 离线推送入口）/
  安全与授权 / 模型 / 快捷指令 / 外观 / 关于与更新，一屏可扫完。
- 新增四个二级页（`lib/views/settings/`）：
  - `ConnectivityView`：**合并**原「网关健康」与「网络与网关诊断」两张卡
    （结论 banner → 地址与延迟 → 重连/切换服务器 → 逐项健康指标）；
  - `PushSettingsView`：原内联的 ntfy 表单（须知、三输入框、保存/测试）；
  - `SnippetsView`：原内联的快捷指令列表 + 增删改排序 + 试填，
    页首写明"在对话输入框 ⚡ 里用"；
  - `AboutView`：版本、检查更新、发布页。
- 分区标题去掉英文副标题（`LLM & Reasoning` 之类对用户只是噪音，
  也是窄屏在 `&` 处断行的来源）。
- 通知状态卡与离线推送入口**相邻**（同一件事的两条路径，此前被安全策略卡隔开）。
- `custom_settings_view.dart` 从 2146 行降到 500 行左右；样式统一到
  `settings/settings_widgets.dart`（`SettingsNavCard` / `SettingsSectionHeader`）。

### 移除

- **运维面板（`HostOpsView`，1650 行）整体删除**：服务端命令、文件浏览、
  目标板与连接诊断重叠度高，其余职责属于桌面端。
- `gateway_health_view.dart` 删除（内容已并入 `ConnectivityView`）。

### 验证

- `flutter analyze` 无问题；`flutter test` 778 全过（+6）。
- 新增 `settings_hub_test` 4 条：四个入口都能点进去 / 首页不再内联大表单 /
  运维面板确实没了 / 360dp+1.3x 不溢出。
- 新增 `composer_focus_and_hints_test` 2 条：设置里新建的指令**不重启**即可见
  （缓存过期回归）/ 打 `/` 自动弹面板。
- `settings_snippets_test`、`push_settings_test` 改为直接 pump 二级页，
  原有 17 条断言一条未改（键名与文案保持）。

---

## [1.32.2] - 2026-10-18

### 修复（用户反馈：点开会话仍感觉"从上往下滑到最新"，卡且体验差）

- **消息列表改为 `reverse: true`（微信/Telegram 同款标准形态）：点开会话即最新内容，全程零滚动。**
  1.32.1 的"贴底窗口"只是把 300ms 动画换成瞬时跳，闪跳本身没消除 —— 根因是
  正序列表挂载在 offset 0（视觉顶部=最旧消息），渲染完再 postFrame 跳底部。
  反转后 offset 0 = 视觉底部 = 最新消息，挂载天然锚定，不再需要任何跳转：
  - 打开会话：列表直接就是最新内容（缓存回填、首屏 GET、尾部增量到达时
    视口纹丝不动）。
  - 用户上翻看历史时来了新消息：视口不被拖走（列表锚定底边的天然特性）。
  - 顶部加载更早历史：现有内容视觉位置天然不变 —— 正序时代那套
    `oldMax/newMax` delta 平移补偿整个删除。
  - 搜索/轮次跳转的按比例粗滚同步翻转（`max*(1-ratio)`）。
  - "本轮产出"卡渲染在最新消息之下；"已到会话开头"在视觉顶部。
  - 打开会话期间缓存已有内容时不再整屏转圈（消除"打开白屏一下"）。
- 删除 1.32.1 引入的贴底窗口状态机（`_pinningToBottom` / `_pinStartedAt` /
  `_isInitialFill`）—— 反转列表使它整个不再必要。

### 验证

- `flutter analyze` 无问题；`flutter test` 772 全过。新增
  `reverse_chat_list_test` 4 条回归：挂载即最新 / buildItem 正序索引语义 /
  上翻不被新消息拖走 / 产出卡在视觉底部。

---

## [1.32.1] - 2026-10-17

### 修复（用户反馈：点开会话总是"从上往下滚"到最后）

- **打开会话改为瞬时贴底，不做滚动动画。**
  成因：会话打开后消息是分批到达的（缓存回填 → 首屏 GET → 尾部增量），
  每一批增长都触发一次 300ms 的 `scrollToBottom()` 动画 —— 用户看到的
  就是列表一路往下滚。现在切会话时进入"贴底窗口"（1.5s 内或仍在拉历史）：
  这几批一律 `jumpTo` 直接定位到底部，看不到滚动过程。
- 动画只留给**会话内真正新到的消息**（打开之后再来消息仍平滑滚动）。
- 用户一上手拖动（ScrollStart/Update）立刻退出贴底窗口：他已经接管位置，
  不该再被拉回底部。

### 验证

- `flutter analyze` 无问题；`flutter test` 768 通过。

---

## [1.32.0] - 2026-10-17

### 修复（用户反馈：每次打开会话都要重新加载，非常卡）

- **打开会话不再每次重拉整个会话。** 旧路径在首屏那次 GET 之后无条件跑
  `ensureFullHistory()`，把整个会话一页页翻完（实测 10 轮 / 7 页 / **1.58 MB**）
  —— 来回切会话 = 每一切一次的卡顿，这是"打开很卡"的直接来源。
  现在加了**进程内会话消息缓存**（LRU，上限 6 个会话）：
  - 再打开同一个会话：首帧直接回填上次的内容，不再空屏等网络；
  - 网络只补**尾部增量**（一次轻量 resync），不再 7 页地翻；
  - 缓存只用于首帧渲染、不做真相：网络结果回来走既有的对账合并覆盖；
  - 会话删除时对应缓存条目一并剔除（否则会拿回"已不存在"的旧内容）；
  - 上限 6 + LRU，避免长会话长期驻留把内存吃满。
- 缓存命中时首屏那次 GET **不再整体替换**消息列表（它只带最新一页，整体赋值
  会把缓存里更早的历史冲掉）——改走 `reconcile` 的窗口合并。

### 修复（用户反馈：产出徽标位置）

- 产出徽标（📦 N）从标题行右端移到**第二行最右边、紧跟「上下文 xx%」之后**
  —— 用户明确要求"放在上下文那个右边"。
- 顺带把第二行的分隔符 padding 从 5 收到 3：360dp 上长会话名 + 长工作区 +
  执行中 + 上下文 + 产出徽标这一行正好差 7.5px 溢出，收紧后 360dp 用例全绿。

### 验证

- `flutter analyze` 无问题；`flutter test` 768 通过（新增
  `session_history_cache_test.dart`，并更新顶栏三条用例）。

---

## [1.31.2] - 2026-10-17

### 修复（用户反馈：会话页顶部的「产出」）

- **「产出 N」不再单独占一行。** 上一版把它留在事件带里 —— 那是一条挂在顶栏下方
  的独立横带，用户的原话是"产出单独一行太突兀"。它其实和「执行中 / 工作区 /
  上下文」同属**身份类读数**，现在改成标题行右端的一枚紧凑徽标（📦 N）：
  - 未读时用强调色 + 加粗（"有新东西"的信号保留）；
  - 读过后回落到弱色，数量仍可点，进信息面板的交付物小节；
  - 标题是 `Flexible`，挤不下时让位的是标题文字，360dp 上也不会整行溢出。
- 事件带从此只承载**临时事件**：正在重连、后台作业在跑、别处有会话在跑。
  这几种都不出现时，整条只剩 1dp 分隔线（原本产出未读时也会撑出一条 36dp 的带）。
- 上一轮 `TurnOutputCard` 的紧凑化保留不变（消息流里那一条同样不再是卡片块）。

### 验证

- `flutter analyze` 无问题；`flutter test` 767 通过（`session_insights_test` 里
  "事件带挂在 AppBar 下方"、"360dp 最挤的一帧不溢出"、"点产出打开信息面板"
  三条已按新形态更新，钉住徽标存在且不溢出）。

---

## [1.31.1] - 2026-10-17

与 1.31.0 内容相同的一次**重新发版**：上一版的 CI 构建虽成功、GitHub Release
资产也更新了，但网关 `GET /dsh-agent.apk` 分发的仍是 `public/dsh-agent.apk`
里那份 2026-10-06 的旧包 —— 手机从网关下载到的自然还是旧版本。

版本号 +1（build 70）触发一次全新构建，并把新 APK 投放回
`dsh-server-plugin/public/dsh-agent.apk`（网关该路由每次请求都 stat + 流式读取
磁盘文件，换文件即生效，不需要重启 dsh web）。

### 变更

- `pubspec.yaml` 版本 1.31.0+69 → **1.31.1+70**（`app_version.dart` 兜底常量同步）。
- 内容与 1.31.0 一致，见下一节（含产出条紧凑化、工作区顶部执行中 pill 删除）。

---

## [1.31.0] - 2026-10-17

全面代码审查后的第一批修复（方案见 `docs/2026-10-17-审查修复执行方案.md`）。
本轮重点是四个「注释声称已修、代码未生效」的空操作修复与默认模型链路 ——
全部附带钉住行为的回归测试（`regression_2026_10_17_test.dart` 等，新增 7 条）。

### 修复（服务层）

- **重连耗尽后手动重试失效**：`retryConnection` 只重置计数器、不解除
  `_reconnectExhausted` 闸，而承诺"重新武装"的 `armReconnectRetry` 全工程零调用。
  现在 retryConnection / selectSession / createNewSession / handleAppResumed
  都会真正重新武装。
- **`_executeReconnect` 缺 `await ready`**：靠首帧才翻 connected，重连路径发的
  ping 被状态守卫拦成死代码；网关建连后不主动推帧时永远卡在 connecting 且
  无自愈。补 await ready + catch，两处 `IOWebSocketChannel.connect` 都加了
  10s connectTimeout（SYN 黑洞不再挂 2 分钟）。
- **取消栅栏误伤远端新回合**：手机取消后，电脑端在同一会话发起的新回合会被
  增量守卫整轮丢弃。现在收到 isRunning 上升沿或对账发现新 user 消息时栅栏让路。
- **轮询对账丢字段**：三处手写消息解析漂移，对账路径漏了
  attachments/turnTokens/noticeKind 等 6 个字段（历史图片消失、逐轮 token 回退）。
  收敛为统一的 `ChatMessage.fromWire` 工厂。
- **isSessionRunning 恒真**：`dsh.currentSession` 与自身比较，别的会话在跑时
  本会话也点亮停止键。服务侧新增 `sendingSessionId`，停止键只在"本会话真的在
  本机跑"时出现。
- **语音 `onAutoStopped` 自赋值 no-op**：引擎自动结束（静音超时/时长上限）永远
  无法通知 UI。fake 与真实路径都补挂了实例字段。
- **清空凭据复活**：`_writeSecrets` 对空字段现在会删掉 Keystore 槽位；
  `deleteProfile` 补删迁移前的旧槽。SecureStore 的文档注释与实现对齐。

### 修复（默认模型）

- **新建会话不再继承上一会话的模型**：`createNewSession` 重置
  `_currentSessionModel`，新会话显示并使用设置页的默认模型；创建成功后主动调
  `session/selectModel` RPC 按会话级注入 —— 这条通道立即生效，不依赖引擎重启。
  网关 `sessions/create` 接受可选 model 作为老客户端兜底。
- 设置页提示文案改为「App 新建会话立即生效；引擎全局对齐需重启 dsh web」。

### 修复（UI/UX）

- 弹层内 3 处 SnackBar 改为面板级内联提示（SnackBar 会被 bottom sheet 盖住，
  用户看不到操作结果）；两处 `_refresh` 补 catch，异常进内联提示。
- 日志查看器只在"已在底部附近"时才自动跟随 —— 此前每 2 秒无条件拉底，
  上翻读历史会被反复拽走。
- 输入区提示（ComposerNotice）收敛为单一所有者 `ComposerNoticeBus`：父级与
  composer 的双 Timer 不再互踩（排队回执把语音错误提示提前抹掉的问题）。
- 点按听写改为**追加**而非整段覆盖已打字草稿；「撤回插队」有草稿时也走追加。
- 斜杠命令在"/ 开头但无空格"时不再产生双斜杠（composer 与 chat_sheets 同步修）。
- 触控目标：状态胶囊动作按钮 ≥44dp、附件删除 32px、消息「⋯」32px、权限胶囊
  放宽到 46dp（「全信任」不再截断）。
- 工作区会话行尾三个相邻小图标收进「⋯」菜单（删除不再紧邻归档）。
- 工作区卡片加稳定 key（轮询/过滤下展开状态不再错位）；会话列表默认只渲染
  最近 50 条 +「展开全部」（1275 条会话的工作区不再一次性全量构建）。
- Ping 测速补 mounted 检查；手动重连有 loading 反馈并防连点。
- 录音 30s 看门狗随 partial 顺延（正常长句不再被强切误报）。
- 消息高亮 3s 清除与再次高亮互斥；会话内查找按「查询+条数+流版本」记忆化
  （流式期间不再每 tick 全文扫描）。
- 会话切换时清理跨会话的 GlobalKey 注册表与产出已读标记（慢性内存增长）。

### 修复（网关 dsh-server-plugin —— 需重启 dsh web 生效）

- **配对码铸造加闸**：`/pair/qr`、`/pair/info` 此前可无限自助发码（公网部署下
  等于零门槛换全权限 token）。现在要求有效 token，或来源为本机/私网。
- **鉴权爆破退避修复**：`X-Forwarded-For` 默认不再作为退避键（直连场景每请求
  换一个伪造 XFF 即可绕过限速；部署在可信反代后设 `BRIDGE_TRUST_PROXY=1`）；
  WS upgrade 的 401 同样计入退避。
- **readonly 反转为 deny-by-default**：POST/PUT 一律拒绝只读设备，不再依赖
  会漏项的白名单（此前 workspaces/create、quick-commands/run 等 6 条写路由
  全部在名单外）。
- **jobs/follow 前缀失配**：`collect-` 流帧此前永远路由不到，后台任务日志
  实际永远为空。
- 会话权限策略键归一化（`session-` 前缀两种拼写不再静默回落全局策略）；
  附件读取加 60s/30 次频率桶；`touchDevice` 30s 节流（不再每 2.5s 重写
  devices.json）。

### 验证

- `flutter analyze` 无问题；`flutter test` 767 通过（含新增回归 7 条）。
- `npm test`（hermetic）408 通过。

---

## [1.30.0] - 2026-10-17

会话页顶栏重做。这一轮**只动顶部**：不碰数据口径、不碰消息流、不碰打包链路。

旧版是「56dp 单行标题（13pt）+ 34dp 状态数字条」，合计 90dp 常驻。那条 34dp 里塞了
8 组读数，360dp 屏上**必然溢出** —— 真机截图里被硬裁在「改动」处，只能靠一条 14dp
渐隐去遮掩，等于承认"有一半读数用户看不到"。同时会话名只比这些数字大 1.5pt，整个
顶部没有主次，用户的反馈是"看着不对劲，但说不清哪不对"。

### 改变

- **顶栏改为「52dp 双行身份栏 + 按需出现的事件带」**：
  - 第一行：会话名 15pt/600（`AppText.heading`），单行省略；
  - 第二行：`●执行中 · 📁工作区 · 上下文 62%`，上下文 ≥85% 转红、>70% 转橙；
  - 第三行：事件带，只在「未读产出 / 后台作业 / 别处执行中 / 正在重连」时出现，
    无事件时只留 1dp 分隔线。
  常态高度 53dp（原 90dp，省 38dp），有事件时 88dp。
- **轮/步、tok/s、累计 tok、缓存命中、改动数不再常驻顶部**，统一在会话信息面板 ——
  它们本来就是"翻明细"才看的东西。
- **顶栏左侧新增会话列表入口。**「对话页侧滑返回 = 回工作区」早就实现了（`PopScope`），
  但界面上从来没有可见入口：用户能做的事，看不出来。
- **权限状态从「7px 单色点」改成「环 + 实心/空心」**：实心＝不再询问，空心＝还在问。
  颜色不再是唯一编码 —— 全权执行和每次询问此前在色觉障碍用户眼里是同一个点。
- **事件带触控热区从约 20dp 提到 36dp**（整颗胶囊高度都可点，移动端下限 44dp 的
  补充入口是顶栏那两个 48dp 按钮）。
- **「执行中」全页面只出现一次。** 此前顶栏徽标与状态条各渲染一枚，同一个事实说
  两遍，两条样式还不一样。
- **「产出 0」不再显示。** 事件带只报事件：读过的产出、已知 0 个产出都不占位置，
  总数归信息面板。

### 修复

- `ChatAppBar.preferredSize` 之前写死 `kToolbarHeight`，而它实际渲染的是"工具栏 +
  底部状态条"，两者差 34dp。Scaffold 用的是松约束，所以没有当场炸，但任何按
  `preferredSize` 计算的场景都会错。现在由 `bottom` 的真实高度算出。
- 顶栏那个从未被使用的 `onScrollToBottom` 参数已删除。

### 验证

- `flutter analyze` 无问题；`flutter test` 760 通过。
- 新增 360dp 用例覆盖最挤的一帧（长会话名 + 长工作区 + 执行中 + 75% 上下文 + 未读
  产出）：断言无溢出、顶栏总高 ≤ 88dp、被省略的只有工作区名。

---

## [1.29.2] - 2026-10-17

一轮**纯视觉与可读性**修复：不动数据口径、不动交互语义，只让界面把已经正确的信息
说得更清楚。全部来自真机截图逐屏审阅。

### 修复

- **轮次刻度改为无条件显示。** 旧版 `_buildTurnRail` 有 `marks.length < 8` 的门槛，
  理由是"4 轮会话里这列刻度只是一竖串小点，与 AI 消息左侧那条竖线叠在一起像杂质"
  —— 代价是绝大多数会话（都在 8 轮以内）根本没有刻度，用户看到的是"有的会话有、
  有的没有"，第一反应是渲染坏了。现在只要有真人回话就常驻，视觉冲突改用"当前轮是
  3×14 竖条、其余是 3×3 圆点"来区分，而不是靠"干脆不画"。**只有一条真人回话都
  没有时（空会话 / 只有系统注入）才不画** —— 那是"没有可跳的目标"，不是"轮数不够"。
- **进会话首屏的刻度不再全是灰点。** `_visibleTurn` 只在滚动通知里算出来，所以刚
  进会话时整条刻度没有一格高亮，看不出"我现在在第几轮"——而那正是这列刻度的一半
  价值。现在首帧后补一次探测。
- **「本轮消耗」不再裸显示「—」。** 一根横线要配一大段解释才读得懂，而那段说明本身
  又把面板撑得很啰嗦。改为「统计中…」+ 一个可点的 `?` 图标（解释收进 Tooltip）：
  常态安静，想知道口径的人点一下就有。**仍然绝不显示 0** —— 0 会被读成"这轮没花钱"。
- **「断线重连」与「切换服务器」的视觉权重对调。** 旧版把破坏性更强的「断线重连」
  做成实心主按钮，而它一按就会断开当前连接、正在跑的回合可能收不到后续增量；
  「切换服务器」反而是描边的次按钮。现在反过来，并且给重连加了确认弹窗 ——
  连接本来就断着时不问（那时重连是唯一出路）。
- **Ping 延迟补上第三档颜色。** 旧实现只有"<100 绿 / ≥100 橙"两档，300 ms 与
  3000 ms 长得一模一样，慢到不可用也看不出来。现在 <100 绿 / 100–300 橙 / >300 红。
- **「测速」按钮从绿改主蓝。** 它是个**动作**，绿是"状态良好"的语义；与旁边延迟
  数值的绿色并排会被读成同一件事。
- **设置页小节标题拆成主标题 + 英文副标题。** 中英挤在一行时，窄屏会在括号里的
  `&` 后面断开（"网络与网关诊断 (Connectivity &" / "Diagnostics)"），读起来像
  排版坏了。中文优先读，英文缩一号作为对照留在原地。
- **状态条右缘改成渐隐，替代硬裁切。** 内容比屏幕宽时，最后可见的常常正好是段间
  那个 `·`（真机截图里 `… 产出 0 ·` 后面空空如也），看起来像渲染到一半坏掉。
  渐隐带只有最后 14 dp，内容装得下时落在尾部留白上，不影响任何真实数字。
- **设置 tab 的选中态补上实心图标。** 另两个 tab（对话 / 工作区）选中都会换成实心
  版本，只有设置一直是同一枚描边图标 —— 选中时只剩那枚浅蓝胶囊在变。

### 调整

- **「本次变更」的解释横幅从警告黄改中性蓝灰。** 它说的是"清单为什么来自 Agent
  写入记录 / 为什么没有行数"，纯属事实陈述，没有任何要用户去修的事；黄条应该留给
  真正需要行动的场景。
- **工作区搜索框占位文案从「搜索会话：本页即时筛选，回车全库搜索」缩到「搜索会话…」。**
  长占位在 360 dp 上被截断，反而读不到重点；筛选行为由右侧「全库搜」按钮自有文案。

---

## [1.29.1] - 2026-10-17

会话信息面板**只剩现状描述**，动作全部回到各自归属地。这是最后一轮"减"，不是加。

### 调整

- **「会话操作」整块删除。** 用户的原话：这些在工作区页都能点，而且在这里还要多操作
  两步才够得到。一个只读的"现状描述"面板里混进"删除会话"这种不可撤销动作，本身也
  危险。新开 / 删除会话回工作区页，模型 / 权限在输入栏，轨迹是本面板的 tab。
- **「连接诊断」区块删除。** 它把 ping / 端口 / 网关版本这些一次性排查信息摆在会话面板
  里，而真正的排障入口是「设置 → 网络与网关诊断」—— 那里能测速、重连、换服务器，
  这里只能看。同一件事两处，删掉只能看的那处。
- **标题左边那条 32×3 的灰白短横线删除。** 这个面板是 `isScrollControlled` 的 bottom
  sheet，本身不可拖动重定位，那条线只起到"标题前面有个不明所以的小条"的作用。
- **运维面板入口重做成独立行卡片。** 之前塞在「网络与网关诊断」卡片底部当一个
  整宽按钮，和上面那堆只读值（地址 / 延迟 / 上游）混在一起，分不清"哪块是值、
  哪块是门"。现在它与那张卡**同级**：图标 + 标题 + 副标题 + 箭头，和设置页顶部的
  「安全策略与授权」是同一套形态。

> 顺带把 `SessionInfoSheet` 里 12 个已经没人用的参数（会话操作、诊断、运维出口、
> 模型 / 权限 / 工作区标签）和两个私有方法一起删了 —— 留着就是下一轮误用的入口。

---

## [1.29.0] - 2026-10-17

### 修复

- **智能体团队里"已完成"显示成"进行中"。** 引擎的 `agentTeam.members[].phase` 是
  **出生状态**：队友 spawn 出来之后一直是 `active`，跑完了也不改 —— 所以手机端永远
  显示"进行中"，而 Web 端显示"已完成"（两边看的是不同字段）。现在网关按**子会话自己
  的投影**算真实进度：有未闭合回合 = 进行中，`subagentTiming.lastTurnCompleted` =
  已完成。面板给"已完成"用终端绿（灰会和"创建中 / 未知"撞色）。

### 新增

- **新建工作区。** 工作区在引擎里就是 `workspace.json` 的一行（路径 + 名称 + 会话
  列表），所以新建 = 建目录 + 加一行；同一路径重复新建幂等返回，不会产生两个同名项。
  入口在工作区列表页右上角（`+`），填**服务端绝对路径** + 可选显示名；失败**留在
  弹窗里**，不关窗不消失 —— 用户刚打完一长串路径，失败时把窗口关掉等于让他重打。
  **需要重启 dsh web 才生效**（网关新增了 `/api/mobile/workspaces/create`）。

### 调整

- **切换模型 / 权限的提示搬到上半屏。** 新增 `TopToast`：顶部浮出、1.8 秒自己走。
  底部原本是输入卡片、状态胶囊、审批 dock 的地盘，贴底的 SnackBar 会盖住正在打的字，
  而且紧挨输入框容易被读成"输入框的一部分"。分工写进了文档：**这里只放不痛的消息**，
  失败一律留在原地（`InlineErrorBar` / 弹窗内红条 / `ComposerNotice`）。
- **运维面板从会话信息面板移到「设置 → 网络与网关诊断」。** 它做的是主机 / 引擎级的
  活（白名单命令、服务端文件浏览、连接诊断、目标板），与会话域无关；而它真正被用到的
  时机恰恰是"连不上 / 引擎异常"，也就是用户会来设置页排查的时候。

---

## [1.28.0] - 2026-10-17

用户装的 1.27.2 上跑了一轮，逐条修：

### 修复

- **滑动时轮次刻度乱跳。** 判定逻辑原来看"最后一条越过顶边的真人消息"，这里有两个
  抖动源：懒列表里视口上方的消息经常没被构建（`GlobalKey` 拿不到 context），循环看
  不到它们，`current` 就退回默认值 1；另外一条消息贴在顶边时，±1 像素的滚动会让它
  在"越过 / 没越过"之间反复横跳。改成**离视口中心最近的那一轮**，并且一个锚点都
  拿不到时保持现状 —— 距离是连续量，滚过一轮只会切换一次。
- **用户气泡选中文字看不见。** 气泡底是实心品牌蓝，而 Flutter 的选区高亮是 accent
  的半透明叠色，压在实心 accent 上几乎无变化：长按选中一句话，屏幕上像没反应。
  改成 accent 的浅色 tint + `textPrimary` 深字，选区高亮对比明显，气泡仍有品牌感。
- **智能体团队 / 子代理在 App 里永远不显示。** 根因在网关：`/api/mobile/sessions/team`
  与 `/api/mobile/sessions/subagents` 这两个 GET 路由**从来没实现过**，请求一律 404，
  面板只能显示"状态未知"或整块不渲染。现在网关从引擎的投影缓存读取
  `agentTeam`（成员 + 任务板，Lead 就是当前会话）与 `subagentCatalog.head.values`
  （childId / mode / label），如实标 `source: 'cache'`；读不到时回 503 而不是编空列表。
  **需要重启 dsh web 才生效。**

### 调整

- **对话权限搬进输入栏**，和模型胶囊并排（`🛡 询问` / `只读` / `全信任`，按松紧分色）。
  切换模型和切换权限是同一类动作 —— "发出去之前确认这一轮按什么规则跑"，埋在信息
  面板两层里没人会想起来去改；而误发的代价（全信任下直接执行）比换模型大得多。
  窄屏放不下时它会让位（宁可少一个胶囊，也不能把输入行顶溢出）。
- **会话信息面板**：「会话操作」删掉切换模型、对话权限、切换工作区（前两个搬去输入栏，
  第三个和底部工作区 tab 重复），只留新开 / 删除；「入口」里删掉"运行轨迹"行。
- **轨迹升级为面板顶部的同级 tab**（概览 / 轨迹），不再需要"面板 → 入口行 → 又一层
  弹层"。tab 里直接嵌 `TrajectorySheet`，跳到消息复用搜索/刻度那条路径。

---

## [1.27.2] - 2026-10-17

1.27.1 修完单点样式之后，真机截图暴露的是**结构问题**：垂直方向被切成一条条固定带
——顶栏 60 + 状态条 34 + 断线横幅 70 = 164dp（851dp 屏的 19%），下面还有审批 dock
和输入区，消息区被压成一条缝。

### 修复

- **顶栏回到单行 56dp。** 工作区名从"第二行"改成同一行里的小后缀
  （`会话名 📁个人`），完整归属进 tooltip；会话名改用 `Flexible` 吃剩余宽度 ——
  长名字时被省略的是工作区，不再是会话名。
- **断线横幅从双行 70dp 收到单行 ~40dp。** 错误详情并进同一行（超长省略、完整
  内容进 tooltip）。这条横幅在重连成功前一直挂着，不值得占 70dp。
- **轮次刻度门槛 3 → 8 轮。** 4 轮以内的会话里它就是左侧一竖串小点，而每条 AI
  消息左边本来已有一条 2px 竖线 —— 两列竖排元素叠在同一处，纯杂质。它的价值只在
  "十轮以上、靠滑找不回来"的场景。
- **「回到最新消息」改成 36dp 圆形按钮。** 原来是 130×30 的文字胶囊，直接压在最近
  一条气泡 / 工具卡上，把那一行字盖掉；文案移进 tooltip，遮挡面积缩小到 1/4。

---

## [1.27.1] - 2026-10-17

1.27.0 的界面重构**没有在真机上看过就发了**。这一版是把模拟器截图逐屏看一遍之后
补的：三处是我自己改坏的，三处是原本就有、被高信息密度放大的。

### 修复

- **轮次刻度压住正文。** 1.27.0 把刻度从右边缘挪到左边缘（为了避开返回手势和
  "回到最新"浮钮），但保留了那块半透明白底胶囊 —— 而左边缘正是每一行正文的起点，
  截图里「资产时间戳」被盖成「  产时间戳」。现在整条刻度**没有底色、没有边框**，
  只有 3dp 宽：当前轮是 3×14 的竖条，其余是 3×3 的点；轮数少于 3 时整条不渲染。
- **顶栏第二行被切。** 标题是两行（会话名 + 归属工作区），而 AppBar 用默认 56dp，
  第二行被下方状态条压掉下半截，看起来像渲染坏了。toolbarHeight 提到 60。
- **状态条右侧被硬裁。** 新加的「另外 N 个会话执行中」占 14 个字，把「缓存命中 99%」
  顶出屏幕，右边只剩一个「缓」字。改为排在末尾并压成「N 个在跑」。
- **审批卡被切成两半。** 卡片外面套了 `maxHeight: 300` + 内部滚动，真机上圆角和
  底部内边距全看不到，「批准/拒绝」正好落在切口上。去掉内层限高，交给 dock 自己的
  滚动；dock 上限同时从 0.55 收到 0.45 屏高，给消息流留出半个屏。
- **同一件事说三遍。** 断线在状态条和横幅各报一次；审批在横幅、卡片、输入框胶囊
  各报一次。现在断开只由横幅报（状态条只留"正在重连"），当前会话的审批只由 dock
  里的卡片表达，胶囊行不再收审批。
- **输入区看着像已经写了字。** placeholder 没有 hintStyle，回落到 16sp 深色；
  文案里还有一个 🎤 emoji 跟旁边的 Material 麦克风图标打架。改为 `textTertiary` /
  13.5sp /「发消息…」。
- **模型胶囊截掉了唯一有信息量的半截。** 显示成 `deepseek-v4.1-...`，而 `deepseek-`
  是所有模型共有的前缀。显示层省略它（`v4.1-flash`），完整名进 tooltip。
- **代码块的全屏按钮盖住第一行代码。** 给右侧留 30dp 视野。
- **用户消息的实心 accent 头像删除**：AI 没有头像、只有用户有，且它紧贴气泡抢重量。

### 调整

- Markdown 标题（h1–h6）与表格按手机重定尺度：表格单元格内边距 10/6、细边框、
  `blockSpacing` 14。默认值是给宽屏准备的（h3 有 20sp+），一屏里两个小标题就把
  正文压成注脚。

---

## [1.27.0] - 2026-10-17

一次**以"信息密度"和"错误可信度"为主轴的界面重构**。三个症状串在一起看：卡片套卡片让
一条复杂回复占 700dp、输入框上方叠了 6 层常驻内容、失败提示飘两秒就走。这一版没有加
新功能清单式的东西，主要是把已有的东西重新排布 —— 以及把"看起来成功但其实没成功"的
位置一个个堵掉。

### 重构

- **`chat_view.dart` 4842 行 → 1563 行。** 拆出 `chat_dock`（顶栏/横幅/审批提问 dock）、
  `composer`（输入区全部）、`chat_sheets`（7 个弹层）、`chat_scroll_controller`（滚动状态机）。
  纯剪切，11 个测试锚点原样保留。
- **消息流从"卡片套卡片"改成"裸排版"。** AI 气泡去掉底色与边框，改用左侧 2px 竖线；
  删掉每条消息的 30×30 头像；思考块从双层边框卡片变成无底色引用块；工具调用从卡片
  变成 28dp 单行条 + 6px 状态圆点。一条"思考 + 3 工具 + 正文"的消息体积
  **707dp → 302dp（−57%）**。
- **输入区 6 层常驻 → 1 行状态胶囊 + 1 行文本框。** 上下文告警/运行提示/队列/待办按
  「谁能卡住我」排序，同一刻只显示一条，其余收进「⋯」；队列默认折叠成一行。
- **顶栏 8 项菜单 → 2 个 icon。** 切换模型/权限/工作区/轨迹/运维/删除全部并入会话信息
  面板的「会话操作」分区；「切换主题」回到设置页（那里本来就有三选一分段控件）。
- **轮次刻度从右边缘挪到左边缘。** 右侧原本三个东西抢同一块热区：刻度、"回到最新"
  浮钮、Android 返回手势 —— 实测表现为"点刻度偶尔返回上一页"。

### 修复

- **深色主题的层级是反的。** `surfaceMuted(#374151)` 比 `surface(#1F2937)` 更亮，等于
  "越里面越亮"；边框 `#4B5563` 在深底上像白描边。改为统一「页面底最暗 → 浮层逐级
  变亮」，边框压到 `#30363D`。
- **失败提示会自己消失。** 保存失败、切换策略失败、归档失败、推送测试失败、引擎拒绝
  等十余处原来是 SnackBar（2~4 秒），而它们全都属于"界面看起来没变化"的操作 —— 提示
  一走，用户分不清"没成功"和"没点到"。改为页面内常驻错误条（`InlineErrorBar`），
  带重试/关闭，处理完或重试成功才消失。
- **语音改为"按住麦克风"后，空输入框长按毫无反应**，老用户会以为坏了。补一次性引导
  提示（`dsh_hint_hold_mic_v1`），且不挡键盘、不吃这次点击（用原始指针事件而不是
  长按识别器 —— 后者会和选词抢）。
- **语音回调在页面销毁后写 notice 导致异常**：`_showNotice` 及三条异步回链补齐
  `mounted` 守卫。
- **`steer`（插话）要求点两次**（首次进入"确认插话？"2.5 秒窗口）反直觉。改为点一次
  立即插队 + 3 秒回执可撤回。
- **代码块里的硬编码色值与 emoji 状态色**（`0xFF0369A1` 等）改为语义 token。

### 新增

- **消息长按统一菜单**：复制原文 / 引用（插在光标处、不覆盖草稿）/ 重新发送（有草稿时
  拒绝并说明）/ 查看本轮轨迹。正文长按**仍是系统选词**，菜单由气泡边缘或显式「⋯」触发。
- **代码块全屏阅读**：行号、横向滚动（长行不折行）、语法高亮（复用零依赖高亮器）、
  复制 / 复制为 Markdown。
- **交付物预览语法高亮** + 行号开关 + 「复制全部」；`.md` 可在渲染与源码之间切换。
- **会话内搜索加「上一条 / 下一条」**（`N/M` 位置指示 + 循环 + 结果列表跟随）。
- **审批支持「稍后 15 分钟」**：本地收起、**不答复网关**，到点自动长回来并提醒；
  dock 里留「N 项审批已延后 · 提前处理」。
- **多会话并行指示**：状态条最左显示「另外 N 个会话执行中」，点开可直接切过去；
  工作区列表没拉过时整段隐藏（绝不显示 0）。
- **批量批准**：弹层逐条列出（工具名 + 命令首行），启发式高危项默认不勾并标红，
  用户看清后才按下。
- **轨迹导出 Markdown**、**本地快捷指令**（`{param}` 一屏填完、与网关条目合并展示，
  网关条目只读）。

### 已知边界

- 设置页的**网关下发**提示词模板改为只读（编辑仍需回网关侧）。
- 命令拉取失败与"没有命令"在服务层被折叠成同一个空列表，所以输入区没有重试入口。
- 安卓侧只有分享**接收**通道，代码「分享」落地为「复制为 Markdown 代码块」并如实说明。
- 长按正文不弹菜单依赖手势竞技场"更深者先赢"，将来替换 `SelectableText` 实现会失效。

---

## [1.26.0] - 2026-10-17

上一版把"补到 5 轮"当成目标，方向是错的。这一版按用户原话改：**要看全部记录**，并且要有
**电脑端那样的轮次快捷选择**。

### 修复

- **首屏把整个会话补全，不再"补到 5 轮就停"。** 1.25.0 的门槛是 5 个真人回话，而真实会话
  一页常常一条真人消息都不含（整页都是工具调用记录）—— 实测用户那个 10 轮 / 3600 seq 的
  会话要 **7 页 / 1.58 MB** 才完整，卡在 4 页时看到的还是"只有两三轮"。现在一直翻到引擎说
  `hasMore=false`：每页结束通知一次界面（列表可见地长出来），会话切走立刻停，某页没有
  新增立刻停，40 页上限只是安全阀（实测 7 页）。

### 新增

- **轮次导航刻度（电脑端同款）。** 消息流右边缘一列短刻度：一轮一格，当前那轮更长更深，
  点某格直接跳到那一轮并短暂高亮（复用搜索命中/轨迹面板同一条跳转路径，目标没被构建时
  先按比例粗滚、下一帧精确对齐）。刻度只数**真人回话**，与状态条 `N 轮` 同一口径 ——
  注入通知与上下文块不占格，否则"第 3 轮"会跳到一条子代理结算通知上。
  "当前轮"用 GlobalKey 的全局位置算而不是滚动比例：一张工具卡能顶十屏，按比例算经常错
  一两轮。

### 已验证（活数据）

- 网关的逐轮用量归属在重启后已生效：`seq=1194 真人 tokens=19453`（1.24.0 时是 null），
  注入消息一律 null —— 所以「本轮消耗」现在显示的是**真人那一轮**的量。

---

## [1.25.0] - 2026-10-17

接着 1.24.0 的两个"还是不对"：会话仍然只显示两三轮、本轮消耗仍然不显示；外加一条新需求 ——
用量信息要跟电脑端一样显示。

### 修复

- **会话首屏自动补到 5 轮。** 1.24.0 修的是"上翻加载的旧轮被抹掉"，但用户根本没机会上翻：
  引擎那份历史窗口的预算按**消息条数**算，而一条回合里每个 step 都算一条消息 ——
  实测一个 351 步 / 6 轮的会话，一页只覆盖**一两轮**（首屏 13 条消息覆盖 685 个 seq，
  里面只有 1 个真人回合）。现在打开会话后在后台自动往回补页，补到 5 个真人回话为止
  （最多 4 页，每页实测 200~300 KB），任一次补页没有新增就停。
- **本轮消耗不再恒为 `—`（网关侧，需要重启 dsh web）。** 1.24.0 的逐轮用量归属规则是错的：
  它把**每一条** `user/message` 都当成"新一轮开始"，而引擎会在回合**中间**插入注入消息
  （`time-context` / `dsh-mnemon` / `agent-message` …），于是那一轮的 usage 全算到了注入
  消息头上 —— 而注入消息要么被网关丢弃、要么在 App 里渲染成通知卡，真人那条永远是 null。
  实测：`1902「我发现 app 还有有很多 bug…」`（真人）`tokens=null`，而
  `1843 time-context`（注入）拿到了 `10008`。现在按引擎自己的边界来：
  `turn/start` 开轮 + **真人消息**做载体；一轮里多条真人消息（回合进行中追问）按分段给值；
  回合未完、或分页从轮中间切进来（累加和残缺）一律给 `null`，绝不写 0。

### 新增

- **用量信息对齐电脑端。** 状态条现在有两组电脑端同款数字：
  `6 轮 351 步 · 210 tok/s`（来自引擎 `sessionStats` 投影的全日志计数与解码速度）、
  `113M tok · 缓存命中 99%`（`totalTokens` 与 `缓存读取/(未缓存输入+缓存读取)`，与电脑端
  同一口径；数字按电脑端的**截断**口径显示，113,704,827 → `113M` 而不是 `114M`）。
  信息面板的「用量」小节补了 `会话统计` 一行（轮/步/速度）与 `模型用时 · 工具调用用时 ·
  首 token 平均`，缓存复用那行带上命中率。
- 这些数字读不到时**整组隐藏**（老网关没有该投影），不会显示 `0 轮 0 步`；速度缺失时
  省略而不是 `0 tok/s`。

### 说明

- 逐轮用量与会话统计是**网关侧**改动，需要重启 `dsh web` 才生效；App 侧改动随本版 APK 生效。
  重启后历史里已有的对话也会补上「本轮消耗」（它读的是引擎日志里的 usage，不需要重跑）。

---

## [1.24.0] - 2026-10-17

修四个"我这边就是看不到"的问题：会话只显示三轮、手机发出去的图片被吞、归档点了没反应、
本轮用量恒为 `—`。四个都先用活数据定位到了具体那一行，再改。

### 修复

- **手机发出的图片/文件不再被吞（网关 + App 两侧）。** 引擎把附件记成独立的 content
  part（`{type:'image'|'file', attachment:{attachmentId, mediaType, width, height, bytes, name}}`），
  而网关的历史转换只拼接 `text` part —— **附件在历史里整段消失**（Web 端读的是原始事件
  所以看得到）。实测：手机上发的那张截图 `sha256:d4ca…` 一直在会话日志里，网关返回给
  手机的历史连字段都没有。现在网关把非 text part 归一成
  `attachments:[{id, mimeType, width, height, bytes, filename}]`（字节仍留在宿主机，手机按需
  走已认证的附件路由取），聊天页按 MIME 分流渲染：图片给缩略图，文件给一行文件条。
  **刚发出去那张图还会立刻显示本地预览**（字节本来就在自己手里，不必等 2~3 秒的轮询回包）。
  顺带修掉一个更隐蔽的行为：只发一张图、不带文字的消息以前**整条不产出**，附件连挂载点
  都没有。
- **会话不再只显示最近几轮（"五轮只剩三轮"）。** 服务端那份快照只覆盖最新一页（引擎按
  消息数给的窗口），用户上翻加载出来的更早几轮不在里面，而 `_reconcileSessionMessages`
  原来**整体替换**消息列表 —— 于是每 2.5 秒一次的轮询/重连都把翻出来的旧轮抹掉。现在按
  `seq` 把窗口之前的消息原样保留在头部（并避免与"保留最近本地提问"重复补插）。
  已实证服务端分页本身是好的（同一会话日志里 9 个用户回合都在，窗口只给了其中 3 个）。
- **归档点了以后立刻生效。** 网关侧本来就是对的（实测归档后 `exclude` 清单里没有它、
  `only`/`include` 里有它），是 App 成功后只翻转本地标志、**从不重拉列表**，而工作区列表
  渲染的是网关按 `archived` 过滤后的那份 —— 被归档的行就一直挂在"未归档"视图里。现在
  成功后主动重拉，并新增对网关 `session_archived` / `session_unarchived` 广播的处理
  （电脑端改归档，手机也会跟着变）。
- **"本轮用量"不再恒为 `—`。** 引擎其实**每个 step 的 `assistant/message` 都带 `usage`**
  （`inputTokens/outputTokens/totalTokens/cacheReadTokens`），只是网关把这份数据扔了，App
  只能靠"回合起止两次 stats 读数相减" —— 基线一旦没记到（切会话、冷启动到一个正在跑的
  会话、轮末 App 不在前台）就永远出不来值。现在网关把该轮各 step 的 usage 汇总到那条
  user 消息上（`tokens`，**未结束的轮不给值**、绝不写 0；只加
  `inputTokens+outputTokens`，因为 `totalTokens` 是跨 step 累计值），App 优先用这个权威值，
  本机相减退为兜底。

### 改进

- **轨迹面板能显示历史轮的 token 了**：以前只有最后一轮有数据源（其余显示 `—`），现在
  每个跑完的轮都显示引擎给的真实读数；最后一轮若是"正在跑"才回退到本机读数（且只补空、
  不覆盖权威值）。

### 说明

- 附件回传与逐轮用量是**网关侧**修复，需要重启 `dsh web`（网关进程）后才生效；App 侧的
  四个改动随本版 APK 生效。老网关下 App 行为不回归：附件字段缺失时 `hasAttachments` 为
  false，`tokens` 缺失时回退到原来的"两次读数相减"。

---

## [1.23.0] - 2026-10-17

修一条"看起来是我自己发的消息"：引擎注入的通知（子代理结算等）被渲染成蓝色用户气泡。

### 修复

- **子代理结算通知不再伪装成用户消息。** 子代理结束时 `dsh-subagent` 会把
  `Background subagent <childId> finished and will do no further work unless you send it
  more. Its closing message: <整段收尾>` 作为一条 **`user/message`** 写进会话事件日志
  —— 它就是这么唤醒父 agent 的。`role` 真的是 `user`，于是手机把它渲染成一个蓝色
  右对齐气泡，和用户亲手打的字长得一模一样，里面还塞着子代理的整段收尾（实测能占满
  两屏）。现在它渲染成**居中的灰色通知卡**：标题按种类给（子代理完成 / 被中止 /
  token 用尽 / 插件通知 / 系统指令 / 引擎通知），收尾正文默认折叠 3 行并标出字数，
  点一下展开，底部写明"引擎注入的通知（不是你说的话）"。
- **轨迹面板里它不再凭空开一轮。** 时间线按 `role` 分轮，而它的 role 是 `user`，
  于是会多出"第 N 轮"并把后面的轮号全带偏。现在归到折叠那一档（默认不可见、可计数）。
- **检查点的提示语不再拿它当标题。** `extractCheckpoints` 的 `pendingPrompt` 原来会
  被这类注入覆盖，分支列表里出现一行 `Background subagent …`。

### 新增

- **网关侧（权威判定）**：`core.mjs` 新增 `classifyHarnessNotice` / `readUserMessageSource`，
  并成为"什么 origin 才算真人回合"的唯一名单（`sessiontitle.mjs` 的 `isHumanTurn` 也读它，
  原先那份本地副本已删）。判定优先级：① 来源字段明确是人类 → **永远不是通知**（硬闸，
  人类正文里恰好引用这些话术时绝不能被误伤）；② 来源存在但不是人类 → 按来源分类
  （`plugin:<name>` / `agent-instructions` / …）；③ 来源缺失（老日志）→ 只认**锚定在
  开头**的已知文案。命中后消息额外带 `noticeKind` / `noticeVariant` / `noticeChildId` /
  `noticeBody`，**`role` 保持 `user`**（老 App 渲染行为不变）。
- **App 侧（兜底 + 渲染）**：`models/harness_notice.dart`（网关标记优先，没有标记时按
  同一套锚定文案认一次，供老网关与本地路径兜底）+ `widgets/harness_notice_card.dart`。
  `ChatMessage` 新增 `isHarnessNotice` / `notice`，渲染层**先判通知再判 user**。

### 说明

- 网关改动需要重启 `dsh web` 才生效；App 侧改动随 APK 生效。两层合起来才是完整修复：
  新 App + 旧网关走文案兜底，新网关 + 旧 App 保持原样（只是多了几个用不到的字段）。
- 文案清单是同一份知识、两种语言（网关 `core.mjs` 的 `SETTLEMENT_VARIANTS` 与 App
  `harness_notice.dart` 的 `_settlementVariants`），**改文案要两边一起改**，两边都有测试钉着。

---

## [1.22.0] - 2026-10-17

三件事：**新增「运行轨迹」面板**；**凭据迁进 Android Keystore**、把明文传输的风险说清；
以及一轮工程卫生（删掉不再成立的历史产物）。版本号从这一版起不再手抄：
`pubspec.yaml` 是唯一真源，由 `scripts/app-version.mjs` 解析、CI 经 `--dart-define` 注入。

### 新增

- **运行轨迹面板（会话内「轮 → 事件」时间线）。** 入口在对话页右上角「更多 → 运行轨迹」。
  每一轮列出该轮的**思考 → 工具调用（按调用顺序，可展开看参数与结果）→ 回复**，
  轮头给耗时与 token；顶部时间概览按各轮耗时占比画一段带子，点事件可「跳到消息」
  （关掉面板并滚到聊天流里那一条，短暂高亮）。实现分两层：
  `lib/models/trajectory.dart`（纯模型，可单测）与 `lib/views/widgets/trajectory_sheet.dart`
  （自包含面板，不读 `DshService`）。
  三条诚实规则写进了模型并有测试钉住：**耗时只在同一轮里至少有两个不同时刻的事件时才给**
  （只有一个事件时显示 `—`，因为"首尾差 0"会被读成"瞬间跑完"）；**token 只挂在最后一轮**
  （引擎只上报本轮增量，历史轮没有数据源，拿不到就是 `—` 而不是 0）；**上下文/记忆块单独
  归类**，默认折叠，底部给出"已隐藏 N 条"与开关。工具没有独立时间戳，界面底部明说
  "时间跟随所属消息"。
- **应用内更新检查与安装**（`lib/models/client_update.dart` + `lib/services/update_service.dart`）：
  可选读取与发布页同级的 `latest.json`（`schemaVersion/version/versionCode/packageName/
  downloadUrl/size/sha256/releaseNotes`），安装前校验 `versionCode` 严格递增、
  `packageName` 与本机一致、`size` 与实际字节数一致、`sha256`（可用时）匹配；
  清单取不到就**回退到打开发布页**（旧行为），不会因为新源不存在而变差。
  清单未提供 sha256 时按 `unverified` 档处理并在界面如实标注"未校验哈希"。
  签名一致性由系统安装器负责，App 侧不假装自己校验了签名。
  启动仍然静默，只有用户主动点「检查更新」才会发请求。
- **`REQUEST_INSTALL_PACKAGES` 权限**：API 26+ 拉起系统安装器必须有它，否则点了没反应。
  声明它不等于能静默安装 —— 确认界面始终由系统托管。

### 安全

- **网关凭据（token / authCode）迁进 Android Keystore。** 新增 `lib/services/secure_store.dart`
  与原生 `SecureStoreBridge.kt`（`dsh_mobile/secure` 通道，AndroidKeyStore 别名
  `dsh_mobile_master` + AES-256/GCM），**零新增 pub 依赖** —— 因此不再被
  `speech_to_text` 与 `flutter_secure_storage` 的 `js` 版本冲突卡住（那正是 README §4 里
  列了很久的阻塞）。升级时把 SharedPreferences 里的旧明文写进 Keystore、**写后读回校验
  通过才删明文**；任一步失败就保留明文继续可用（宁可暂时不变好，也不能让人连不上）。
  无原生侧（Dart VM / 单元测试）或 API 21–22 或 Keystore 故障时**降级不抛异常**。
  顺带修掉一个静默缺陷：删除当前网关时旧的 `dsh_server_config` 镜像会在下次启动把它
  **复活**，现在写墓碑并拦截。
- **明文传输风险显式化**：新增 `res/xml/network_security_config.xml`（只有 system 信任锚，
  刻意不含 user CA），并在配置页把"Token 会以明文经网络传输（http:// 与 ws://），仅建议在
  可信局域网使用，远程请用 HTTPS / WSS"改成**常驻**提示。明文没有被一刀禁掉是刻意的：
  网关目前只有明文 HTTP、目标可能是任意内网 IP，而 network-security-config **不支持按
  CIDR 放行**；一刀禁会让功能直接不可用。自签证书指纹固定（pinning）本轮**未做**，
  理由是缺少指纹分发/轮换通道，写死只会让换证书的用户彻底连不上 —— 要做得先有
  TOFU + 变更告警的完整设计。

### 变更

- **一级导航从 4 个 tab 收敛成 3 个（对话 / 工作区 / 设置）。** 「安全策略」原本与「对话」
  平级，而它属于低频配置；更糟的是它的角标和「工作区」**挂着同一个待审批计数**，同一个
  数字在导航上出现两次。现在从「设置 → 安全策略与授权」推入，待处理数量由那张卡片承载
  （`N 项等待处理`），页内「去处理」会关掉本页并切回对话 tab。
  顺带删掉 `ChatView.onOpenSecurity` —— 从一级 tab 时代留下的死参数，从未被调用过。
- **版本号不再是手抄的**：`AppVersion.version/buildNumber/packageName` 改为
  `String.fromEnvironment`，由 `scripts/app-version.mjs`（唯一一份解析逻辑，pubspec 缺
  `+n` 或解析不到 applicationId 会直接报错退出）与 CI 的 `--dart-define` 注入；
  `test/models/client_update_test.dart` 新增一条"兜底默认值必须与 pubspec 一致"的断言，
  以后改版本号不同步会红，而不是让裸跑的构建悄悄显示旧版本。
- `reports/` 6 份设计与排查记录 + 1 份 docx 移入 `docs/archive/`，不再占仓库根；
  其中 `implementation-audit.md`、`deliverable-open-rootcause.md` 开头加注
  "缺陷已修复，本文仅作历史证据"。
- 新增 `docs/TESTING.md`：hermetic 单测 vs live 测试的分层、各 npm script 会碰什么、
  跑 destructive 前要备份什么、当前目录布局。
- `package.json` 的 `test:live` 不再串联已删除的 `test:challenger`；脚本注释里的
  `ANALYSIS-…md` 指向改为 `docs/TESTING.md`。
- `README.md` §2/§3/§5 与 `.github/workflows/bridge-tests.yml` 的陈旧注释改为描述当前
  状态（Dart 测试文件数、已提交的 `analysis_options.yaml`、已删除的文档/补丁/脚本、
  App 版本号的注入链路）。

### 修复

- **安全策略页的分区标题在手机上溢出。** `_buildSectionHeader` 的标题 `Text` 直接放在
  `Row` 里、按固有宽度参与布局，而标题带着括号里的中英全称（「Agent 执行权限与策略
  (Permission Policy)」）：实测 400×900 溢出 34px / 131px、420×1600 溢出 14px / 111px，
  屏幕上是 RenderFlex 的黄黑条纹。改为 `Expanded` 包裹，标题换行而不是把整行顶出去。
  此前没被发现是因为那个页面是底部导航的 tab，而唯一挂着它的测试跑在测试框架默认的
  800×600 画布上 —— 比任何真机都宽，永远不会溢出。

### 移除

- **历史补丁目录 `patches/`（0001–0003 三个 patch + README）已删除。** 内容早已进
  `dsh-server-plugin/lib/`，hunk 对着重构前的单体 `lib/index.js` 行号，`git apply --check`
  早已失败；仓库里没有任何代码读它们（唯一提及是单测注释，已同步改写）。
- **根目录 5 个历史 APK（v1.0.0~v1.3.0，约 112 MiB）与
  `dsh-server-plugin/public/` 里 6 个历史 APK（v1.2.1~v1.2.6，约 135 MiB）已删除。**
  `public/` 只保留版本号最高的 `dsh-agent.apk`（读出其 versionName 为 1.2.9）。
- **网关的 APK 下载候选链去掉两个已失效回退。** `lib/index.js` 原来依次尝试
  `public/dsh-agent.apk` → `../dsh-agent-v1.2.6.apk`（插件根）→ `../../dsh-agent-v1.2.0.apk`
  （仓库根）；后两条是重构留下的错位路径。现在只认 `public/dsh-agent.apk`，缺失时
  明确 404（附 hint），不再静默回退到不存在的老版本。
- **危险测试脚本清理**：`bench` / `bench:policy` / `bench:burst`（0 断言、永远 exit 0、
  waiters 无超时保护、无 before/after 备份）、`probe:dsh`（绕过网关直连引擎建会话，
  每次必泄漏一个真实会话）、`test:challenger` 一族（`tests/m1~m4_*` 共 10 个平铺在
  `tests/` 根的文件 + `stress_cancel.mjs` / `r3_adversarial_verify.mjs` 两个裸脚本，
  它们手写 `fetch`/`WebSocket` 绕过注册路径、创建的会话不进回收表）。
  `test:destructive` **保留**（已接入 `tests/e2e/helpers/guard.js` 的快照-恢复），
  风险提示保留在脚本注释与 `docs/TESTING.md`。
- **同名的重复用例删除一份**：`tests/e2e/tier4-workloads/mobile-approval-flow.test.js`
  与 `tier1-features/` 那份同名，其断言是 tier1 TC1/TC2-3/TC4/TC6 的严格子集
  （单条 MW-2 串行旅程，无并发、无新断言），故删 tier4 那份，MW-2 覆盖由 tier1 承担。
- **过期文档删除**：`TEST_READY.md`（自述过期、引用的 `ORIGINAL_REQUEST.md` /
  `PROJECT.md` 都不存在）、根目录 `ANALYSIS-优化与新增功能.md`（追加式工作笔记）、
  `TEST_INFRA.md`（目录树与用例数过期；仍然成立的分层说明重写为 `docs/TESTING.md`）。

---

## [1.21.0] - 2026-10-16

工程优化一轮，无新功能。

> 本节原写作 1.18.0 —— 那一版实际发的是移动端团队面板（见下）。本轮改动落地时
> pubspec 已经推进到 1.20.0，所以改由 1.21.0 承载；1.19.0 ~ 1.20.0 之间另有三批
> 改动，补齐在下方各节。

### 修复

- **流式渲染的 O(n²) 字符串拼接。** `ChatMessage.content += delta` 逐片拷贝整个
  字符串，一条 20 万字符的回复就是数十亿次字符拷贝。改为增量先进 `StringBuffer`、
  在 flush 边界才写回成品字段。`isStreaming = false` 时会自动 flush，覆盖 done /
  error / 取消 / 轮询超时兜底 / reconcile / stream_snapshot replay 全部路径 ——
  否则取消回合或弱网兜底时最后 100ms 的内容会凭空消失。
- **每个流式 chunk 都 `notifyListeners()`。** 网关 delta 帧可密到每秒数百片，每次都
  重建整个聊天页。改为 100ms 窗口合并：窗口内的增量进 buffer，到边界才通知一次。
- **整个聊天页跟着流式重建。** `ChatView.build()` 顶上的 `Provider.of` 是
  `listen: true`，一个 chunk 重建 AppBar、横幅、输入框、搜索面板。消息列表抽出为
  `MessageListView` 并用 `Selector` 限定重建范围；只给正在流式的那条气泡加
  `RepaintBoundary`（历史气泡不重绘，包了是浪费）。订阅 `streamRevision` 而不是
  `messages` —— 后者返回同一个 List 实例，`Selector` 的 `==` 永远判等。
- **`contextMarkers` 每条消息每次 build 扫 9 遍全文。** 按
  `(message id, content length)` 记忆化，流式期间不再重复扫。
- **附件图按原图尺寸解码。** `Image.network` 没设 `cacheWidth`，一张 12MP 照片
  （这里最大只显示 320dp）白占几十 MB。改为按 `maxWidth × devicePixelRatio` 解码。
- **`use_build_context_synchronously` × 8。** 跨 async gap 使用 `BuildContext`。
  其中 `host_ops_view.dart` 一处是真实缺陷：原守卫检查的是外层 State 的 `mounted`，
  而实际要 pop 的是对话框自己的 context，对话框已消失时会 `Navigator.pop` 一个
  不存在的 dialog。另有多处是方法参数遮蔽了 `State.context` 导致守卫失效。

### 改进

- **重连不再无限重试。** 退避封顶 12s 后旧逻辑会永久重试：网关半夜重启能让手机
  在后台每隔 12 秒醒一次，天亮烧掉一块电量而用户一无所知。现在上限 8 次，到顶停在
  `reconnectExhausted`，等用户主动操作（切会话 / resume / 重新连接）重新武装。
- **心跳从静默超时改为往返判定。** 旧判据是"45s 没收到任何服务器帧"，一个"偶尔漏
  几帧下来但实际投递不了"的半开连接永远满足不了它，看门狗形同虚设。改为发出 ping
  后连续 3 个周期收不到任何应答才判死。
- **`dispose()` 补上漏掉的清理。** 共享 `http.Client` 从未关闭（keep-alive 连接活到
  进程结束），`DraftStore` 的防抖写盘未 flush（最后一次输入直接丢），流式 flush
  定时器未取消。`DshService` 目前是进程级单例所以是潜伏问题，hot restart 时会真的漏。
- **配置页明文告警。** 关闭 HTTPS 时明确提示"Token 将以明文在每个请求头里传输"。
  真正的修法（token 迁 Keystore）被依赖链阻塞，见 README §4。
- **图片加载失败不再把异常原文显示给用户。** `errorBuilder` 原来把 `$error`
  （含完整请求 URL）直接铺在界面上。
- **启用 `flutter_lints`。** 提交 `analysis_options.yaml`，激活 `pubspec.yaml` 里
  声明却从未配置过的 linter；本地 `flutter analyze` 从此与 CI 的 `--fatal-warnings`
  一致。

### 测试

- `test:unit` 从手写文件列表改为目录默认发现（`cd tests/unit && node --test`）。旧列表
  漏了 6 个文件，其中 `features.test.mjs` 带一个**失败断言**（ntfy 改为根路径 JSON
  发布后断言没跟着改），绿灯纯属遗漏。单测 255 → 375。
  > 注意**不能**把 glob 当参数传给 `node --test`：glob 展开是 Node 21+ 才有的，CI 的
  > Node 20 会把 `"tests/unit/**/*.test.mjs"` 当字面路径报 `Could not find`（本轮
  > 实测踩到 —— 本机 Node 24 全绿，所以本地测不出来）。默认发现从 Node 18 起就有。
- **CI 的 Node 从 20 提到 22，`engines.node` 从 `>=20` 修正为 `>=22.15`。** 网关的
  `sessiontitle.mjs` 读会话事件日志要用 Node 内置 zstd（`zlib.zstdDecompressSync`），
  该 API 到 **Node v22.15.0** 才加入。原来钉 20 导致 `sessiontitle.test.mjs` 的 7 个
  用例在 CI 上全部 INVALID（`zstdCompressSync is not a function`），而本机 Node 24
  全绿 —— 又是一次版本偏差藏住的问题。`engines` 的旧值让"部分功能在该版本不可用"
  这件事在 CI 里不可见。
- 新增 `test/models/stream_buffer_test.dart`：钉住流式缓冲的三条契约（flush 前成品
  不可见、flush 后按序写回、streaming 结束必定 flush）。
- 新增 `AttachmentImageTile` 的 `cacheWidth` 回归测试。

### 工程卫生

- `.agents/hooks.json` 取消跟踪。它是机器本地配置（硬编码 `E:\soft\aionUi\...`），
  而 `.gitignore` 注释声称已于 2026-10-08 untrack —— 实际没有，本次补上。文件保留在
  磁盘上，只是不再进版本库。
- `.probe/` 的 17 个一次性排查脚本加入 ignore，保留有文档记载的
  `download-e2e.mjs`。
- 根目录 `DSH-Mobile-v1.13.0-新功能与验收清单.docx` 移入 `reports/`（此前不被任何
  gitignore 规则匹配，`git add -A` 会误提交）。
- 新增根 `README.md`（此前仓库没有前端门面）与本文件。

---

## [1.20.0] - 2026-10-16

### 修复

- **会话级切换模型是哑的。** 网关只把 `{provider:'wb', model}` 写进投影缓存文件，
  从不告诉引擎 —— 而投影缓存是引擎折叠日志的**输出**，手写等于断言一件没发生过
  的事。实测：在 App 里切换后 26 分钟内引擎侧没有任何 `model/selection` 事件，
  `request/header` 仍写着旧模型，直到重启 dsh web 才换。现在改走引擎的 RPC
  `session/selectModel`（与 `session/prompt` / `session/delete` 同一条通道）；
  provider 从引擎的 `session/modelCatalog` 解析而不再硬编码 `'wb'`；目录里没有的
  模型返回 502 并说明原因，而不是照样回 200。
- App 侧 `switchModel()` 拆成语义明确的两个动作：`selectSessionModel()`（聊天页，
  仅本会话、立即生效）与 `setDefaultModel()`（设置页，全局默认、仅新建会话生效，
  运行中的会话需重启 dsh web），界面写明生效范围与时机。

## [1.19.2] - 2026-10-16

### 修复

- **删除三个从来没有效果的权限设置**：`sandboxMode`（沙箱提权）、`protectGit`
  （敏感目录防护 —— 它宣称拦截 `.git`/`.dsh` 的覆盖写，而实现并不存在）、
  `maxSteps`（单轮步数上限）。三者只被校验、存储、回显，全链路没有任何消费者；
  真正驱动行为的只有 `defaultPolicy`。连带删除与「均衡」完全同义的内置预设
  `autonomous`（四个预设变三个）。网关保留这三个字段作遗留存储以兼容已安装的
  旧版 App，但校验改为"缺失即补默认值、带了才校验"。

## [1.19.1] - 2026-10-16

### 修复

- 删除「深度思考预算」与「采样创造力」两个滑块。App 从不发送这两个值：引擎的会话级
  接口只有 `reasoningEffort` 档位（不是 token 预算），`temperature` 属
  provider/model 配置级。两者连本地存储都没写，重启 App 即回到默认值 —— 滑块会动，
  但什么都不发生。

## [1.19.0] - 2026-10-16

### 新增

- **手机端原生渲染 ```dsh-ui 围栏。** GenUI 插件的渲染器是浏览器侧模块
  （`dsh.client.platform = "web"`，入口 `window.__ModuleLoader__`），手机端永远
  加载不到，围栏此前在手机上只显示成一坨 JSON。新增 `lib/widgets/genui/`
  （围栏切分与解析、行内富文本、自绘 bars/line/donut 图表、节点渲染），接线在
  `safe_markdown.dart`：没有围栏的消息仍走原来的单次 `MarkdownBody`。不支持的类型
  （echart / mermaid / scene3d / 需要 action 往返的表单等）降级为一句说明加可展开的
  原始 JSON，不丢信息。

### 修复

- **会话列表按投影新鲜度选择**（`readFreshestProjection`）。归档管理器迁移投影存储后
  主域文件被冻结，旧逻辑"命中第一个存在的就 break"会让迁移后仍在更新的会话被当成
  空会话隐藏（实测：某会话主域件停在 2026-10-11 且 `blank=true`，归档域件仍在更新、
  标题与轮数都正常）。

## [1.18.0] - 2026-10-16

### 新增

- 移动端团队面板（Agent Team）：会话页可看到协作成员与任务板。

### 修复

- 会话列表把会话 id 当标题显示。

---

## 历史

1.13.0 ~ 1.17.x 的记录见 git tag 与 commit message。
本 CHANGELOG 自 1.18.0 起建立 —— 之前的版本号只在 `pubspec.yaml` 里推进，
release workflow 一直 fallback 到 `generate_release_notes: true`。
