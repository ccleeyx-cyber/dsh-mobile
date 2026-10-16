# Changelog

本文件按 `dsh_mobile/pubspec.yaml` 的版本号手工维护。
`build-apk.yml` 发布时会取对应版本小节的正文作为 GitHub Release notes。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

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
