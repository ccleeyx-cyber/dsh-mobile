# Changelog

本文件按 `dsh_mobile/pubspec.yaml` 的版本号手工维护。
`build-apk.yml` 发布时会取对应版本小节的正文作为 GitHub Release notes。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

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
