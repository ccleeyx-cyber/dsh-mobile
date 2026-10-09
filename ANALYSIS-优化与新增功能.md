# dsh-mobile 项目分析：可优化项 & 可新增功能

> 分析时间：2026-10-08 · 代码基线：`be22acf`（v1.3.0+13）
> 方式：纯静态阅读 + 只读 git/文件核实，**未运行任何测试、未启动服务、未改动任何被审代码**
> 所有结论均带 `文件:行号` 证据；§1.17 的密钥有效性为**实机比对确认**（只比对、未打印明文）
> 本文档由主 agent 与三个子代理（网关安全 / Flutter 客户端 / 测试与发布）的报告合并而成

---

## 0. 现状速览

| 层 | 位置 | 规模（实测） | 说明 |
|---|---|---|---|
| Flutter 客户端 | `dsh_mobile/` | 23 个 lib dart 文件，**7,215 行** + 3 个测试文件 244 行 | 单 `ChangeNotifier`（30 字段 / 33 getter / 61 处 notify）+ 4 tab IndexedStack 常驻 |
| 桥接网关 | `dsh-server-plugin/` | `lib/index.js` **1858** · `core.mjs` **862** · `store.mjs` 295 · `rpc.mjs` 113 · `client.js` 333 · `public/index.html` **895** | 另有 **`index.js.legacy` 2084 行**（未跟踪，含明文密钥，见 §1.17） |
| 测试 | `tests/` | **40 个文件 / 7,583 行 / 251 个 it / 850 条 assert** | unit 622 · tier1-4 e2e 2433 · stress-challenger 3312 · race 452 · probe 122 |
| CI | `.github/workflows/` | 2 个生效（`build-apk.yml` 90 · `bridge-tests.yml` 69）+ **1 个已提交的死文件**（`dsh_mobile/.github/workflows/build-apk.yml` 51 行，永不执行） | 构 APK + 跑 unit/analyze |

架构：手机 App ⇄ (HTTP REST + `/mobile-ws` WebSocket) ⇄ 桥接网关 3088 ⇄ (伪造 Cookie + `ws://127.0.0.1:3080/api/remote.mux`) ⇄ DSH 引擎。

### 0.1 缺陷分布（合并后）

| 级别 | 条数 | 章节 |
|---|---|---|
| 🔴🔴 **安全应急** | 1 | §1.17（引擎 HMAC 密钥泄露且**当前有效**） |
| 🔴 **P0** | 26 | §1.1–§1.16、§1.18–§1.27 |
| 🟠 P1 安全/健壮性 | 11 | §2.1–§2.11 |
| 🟡 P2 架构/性能 | 7 + 10 | §3.1–§3.7、§6.1–§6.10 |
| 🟢 可新增功能 | 19 + 13 + 若干 | §4.1–§4.3、§6.11 |
| 落地顺序 | **51 步 / 6 批** | §5 |

### 0.2 整体评价（三路深挖后修订）

**功能骨架完整、测试资产体量厚实（7,583 行）、v1.3.0 "消除谎报成功" 的方向是对的。** 但有四类结构性问题，比第一版分析判断的更严重：

1. **一条完整的远程 RCE 攻击链已经成立**（§1.17 + §1.18 + §1.19 + §1.20 + §1.21 五处互相咬合）：泄露的引擎 HMAC 密钥当前仍然有效 → 可自签 cookie 绕过网关直连 3080；而即使不走这条路，默认策略 `auto-read` 的分类器也能被 `cat ~/.dsh/.credentials.yaml` 直接把这把钥匙**广播给所有已连接客户端**。
2. **"看起来修好了、实际还是坏的"共 14+ 处**（§1.13 表）：Persona 整套死功能、3 个假 slider、NPS 地址不参与任何 URL、审批 `options` 解析了从不渲染、暗色主题是亮色副本、会话级 `ask` 是假开关（§1.18 洞 5）、待审批角标永远不亮（§1.22b）、设备配对与角色控制整条链路空实现（§1.23）、版本比对永远不可能成功（§1.8）。**全项目 grep `TODO|FIXME|UnimplementedError` = 0 命中** —— 没有显式占位符，全是静默失效，比 TODO 更难发现。
3. **测试套件正在污染你的真实环境**（§1.14，直接命中你 10-08 定的红线）：自动回收机制**五处失效叠加**、`cleanup-hook.mjs` 是从未被 `--import` 的死文件、6 处把真实策略改成 `danger-full-access` 且不恢复、今天工作区根目录就躺着 3 个测试垃圾文件。而 251 个 it / 850 条 assert 里有 **~83 条是 grep Dart 源码字面串**、**~25 处恒真或 OR 链**、**12+ 处测试名与断言不符**、**流式主链路在真实网关上零覆盖** —— 体量厚实但含金量远低于表面。
4. **引擎能力被丢弃约 80%**（§1.5、§4.1）：`user-questions/request` 被丢会让会话**永久卡死且无任何 UI 信号**（比审批卡死更糟，因为没有队列可查）。

**最痛的用户可见问题**仍是 §1.1（每次构建签名不同 → 必须卸载重装 → 连带清空 host/token），但**最紧急**的是 §1.17。

---

## 1. P0：现在就该修的 27 个问题

> 排序按严重度，不按发现顺序。§1.17 是唯一一条"今天就该动手"的。

### 1.1 Release APK 每次构建签名都不一样 → 手机无法覆盖安装 ⭐最痛

**证据链：**
- `git ls-files dsh_mobile/android` 只返回 **1 个文件**：`android/app/src/main/AndroidManifest.xml`
- 没有 `android/app/build.gradle`、没有 `key.properties`、没有 keystore、没有 gradle wrapper
- `.github/workflows/build-apk.yml:40` 用 `flutter create . --platforms=android` **现场重新生成**整个 android 工程
- Flutter 模板生成的 `build.gradle` 里 release 段是 `signingConfig = signingConfigs.debug`
- GitHub Actions 每次都是全新 VM → 现生成一把临时 `debug.keystore` → **每个 APK 的签名证书都不同**

**后果：** Android 判定为"不同应用"，覆盖安装直接失败，必须先卸载。而卸载会连带清掉 `SharedPreferences` 里的 host/token（`storage_service.dart:10`），每次升级都要重填配置。仓库根目录堆了 5 个 APK、`public/` 里堆了 7 个（合计约 270MB），基本就是这个问题的化石记录。

**改法：**
1. 把 `android/` 完整工程提交入库（`gradlew`、`build.gradle`、`settings.gradle`、`res/`、`MainActivity.kt`），CI 删掉 `flutter create .` 这一步
2. keystore 放 GitHub Secrets（base64），`android/key.properties` 走 gitignore，`build.gradle` 里条件加载
3. 顺手把 `package="com.example.dsh_mobile"`（`AndroidManifest.xml:2`）改成真实包名——**注意这一步只能在首次上架前做，之后改包名等于换应用**
4. 加上真实应用图标：现在 `res/` 没入库，`flutter create` 会把图标重置成默认 Flutter 绿标

---

### 1.2 设备配对发出去的 token 根本用不了，"撤销设备"也是空操作

**证据链：**
- `lib/index.js:1271-1286`：配对成功后 `newToken()` 生成 token，只把 `hashToken(token)` 写进 `devices.json`，然后把明文 token 返回给手机
- `lib/store.mjs:105-113`：`verifyToken()` 只比对 `cfg.token` 和 `process.env.DSH_AUTH_TOKEN`，**从来不查 `devices.json`**
- ⇒ 手机拿着配对得到的 token，下一个请求就是 401

连带三个失效：
- `lib/core.mjs:731`：`authenticateRequest` 返回的 device 恒为硬编码 `{ id: 'admin', name: '移动终端', role: 'readwrite' }`
- `lib/index.js:1312`：`touchDevice('admin', ...)` → `store.mjs:266-267` 找不到 id 为 `admin` 的设备 → `lastSeenAt` **永远不更新**，设置页显示的设备活跃时间是死的
- `lib/rpc.mjs:100-105`：`revokeDevice` 只是把设备从 `devices.json` 删掉，但 `verifyToken` 不读这个文件 → **撤销无效，全局 token 照样能用**。这是安全问题，不只是功能 bug
- `lib/store.mjs:115-117`：`roleCanWrite()` 恒 `return true` → 角色模型是装饰

**改法：** `verifyToken` 改成三级校验：全局 token → `devices.json` 里 `sha256(input)` 匹配且 `revoked !== true` → 命中设备时返回真实 device 对象（id/name/role）而不是硬编码 admin。`roleCanWrite(role)` 真正按角色判断，给"只读设备"留口子。

---

### 1.3 审批仍然在"谎报成功"，而且"始终允许"被静默降级

v1.3.0 的发布说明写着「消除谎报成功」，但审批这条主路径上还有两处：

**(a) 失败也返回 ok:true**
```
lib/index.js:1083   coreApprovals.remove(appr, eventId);      // ← 先把审批从队列删掉
lib/index.js:1092   await callDshRpc('$events/result', ...)   // ← 再通知引擎
lib/index.js:1102-1104  catch (e) { logger.warn(...) }        // ← 失败只打 warn
lib/index.js:1113-1120  return { ok: true, code: 0, ... }     // ← 照样告诉手机"成功了"
```
引擎没收到 → Agent 继续卡在审批门上 → 手机显示"已授权放行"（`security_permissions_view.dart:399-401`）。用户看到的是绿勾，实际卡死。**顺序应该反过来：RPC 成功后才出队，失败保留队列并如实返回 5xx。**

**(b) `allow` 被归一成 `allowed-once`**
```
lib/index.js:1066-1068 和 1079-1081
  (outcome === 'allow' || outcome === 'allowed-once' || outcome === 'approve') → 'allowed-once'
```
"始终允许"的语义被抹掉了。而客户端 `approval_card.dart:520` 也只发 `'allowed-once'`、`:494` 只发 `'rejected'`——**App 里压根没有"始终允许"按钮**。结果就是：Agent 每调一次工具，你就得点一次手机。这是当前移动端体验最大的摩擦源。

**改法：** 网关保留 outcome 原义并透传给引擎；App 的"允许"按钮改成上滑/长按展开三档：`仅此次` / `本会话始终允许` / `此类命令始终允许`，后两档写进 `permissions.json` 的规则表（`store.mjs:119-126` 的 `DEFAULT_PERMISSIONS` 加一个 `allowRules: []`）。

---

### 1.4 `tool/result` 靠"最后一个工具"配对 → 并行工具调用时输出错配

```
lib/index.js:913   follower.tools.push(toolObj);              // 只有 name/input，广播时不带 id
lib/index.js:914   broadcastToMobileClients({ type:'tool_start', sessionId, tool, input })  // ← 无 id
lib/index.js:916-919  const t = follower.tools[follower.tools.length - 1];  // ← 拿最后一个
                     t.output = ev.data?.output
lib/index.js:921   broadcastToMobileClients({ type:'tool_result', sessionId, output })      // ← 无 id
```
DSH 明确支持一个消息块里并行发多个工具调用。三个工具并行时，谁先返回就把输出塞给"最后 push 的那个"卡片 → **手机上工具卡和输出对不上**。`ev.data.id` / `callId` 上游是有的（`:907` 已经在读 `ev.data?.id`），只是没往下传。

**改法：** `tool_start` / `tool_result` 都带 `callId`，网关侧用 `Map<callId, toolObj>` 索引，客户端按 id 更新对应卡片。

---

### 1.5 引擎事件被丢掉 ~80%，其中 `ask_user_question` 会让会话永久卡死 ⭐产品级缺陷

`handleUpstreamMuxMessage`（`lib/index.js:832-1061`）实际只处理这些：

| 处理了 | 位置 |
|---|---|
| `assistant-stream` start/chunk（reasoning-delta / text-delta / tool-call-delta） | :863-885 |
| `turn/start`、`turn/end`、`tool/call`、`tool/result` | :889-922 |
| `$events` 的 `ready` / `cancel` / `approval/request` | :931-1011 |

**其余全部落到 `return`（:923-925）被静默丢弃。** 而从引擎包里实测提取到的事件/RPC 名称包括：

```
user-questions/request     ← ask_user_question，Agent 主动提问
todo/write                 ← 任务清单进度
image/png image/jpeg image/gif image/webp image/offload   ← 图片
compaction/start compaction/end compaction/summary        ← 上下文压缩
goal/change goal/activation-changed                       ← 长任务轮次
subagent/catalog subagent/descriptor                      ← 子代理
step/start step/end                                       ← 细粒度步骤
feedback/message-put feedback/message-delete feedback/record  ← 消息反馈
command/run command/done terminal/view                    ← 终端
schedule/change plugin-manager/* api-session/status
session/search session/fork session/rename session/title
session/attachment session/updateQueue session/steer
workspace-file/* （文件读/列目录/大小校验）
```

**最要命的是 `user-questions/request`：** Agent 调用 `ask_user_question` 时，引擎在等一个回答。网关不认识这个事件 → 不转发 → 手机上看不到问题 → 用户以为 Agent 在思考 → **会话无限期挂住，且没有任何提示**。这比审批卡住更隐蔽，因为审批至少有队列可查。

（`lib/index.js:955` 只匹配 `val.event === 'approval/request'`，`user-questions/request` 不在这个分支里。）

**改法（分两步）：**
1. **兜底**：在 `handleUpstreamMuxMessage` 末尾加一条"未识别帧"分支，广播 `{type:'raw_event', eventType, sessionId, payload}`，客户端渲染成可折叠的 Raw 卡并写 rawLog。协议漂移立刻可见，不再静默丢失。
2. **逐个接通**：按 §4.1 的优先级把 `user-questions` / `todo` / `image` 三个先做掉，投入产出比最高。

---

### 1.6 GitHub PAT 明文躺在 `.git/config` 里，而且脚本依赖这种做法 ⚠️立即处理

```
git remote -v → https://ghp_aBdL****（已脱敏）@github.com/ccleeyx-cyber/dsh-mobile.git
scripts/await-apk.mjs:24-26   execSync('git remote get-url origin') → /ghp_[A-Za-z0-9]+/
scripts/await-apk.mjs:6-7     注释明确写「Reads the PAT from the origin remote URL」
```
commit `87869eb` 的标题是"移除测试与探针中的硬编码凭据"——源码里的确实清了，但**凭据搬到了 remote URL**，仍然是明文落盘（`.git/config`），而且被脚本固化成了工作流。这个 PAT 对私有仓有 `contents:write`。

**改法：**
1. **马上去 GitHub 吊销这个 `ghp_` token**（它已经出现在明文配置和脚本逻辑里）
2. `git remote set-url origin https://github.com/ccleeyx-cyber/dsh-mobile.git`，凭据交给 Git Credential Manager
3. `await-apk.mjs` 只读 `process.env.GITHUB_TOKEN`，删掉 `token()` 那段抓取逻辑
4. CI 加 secret 扫描门禁（`dsh-server-plugin/scripts/check-secret.mjs` 已有雏形，只有 23 行，扩一下接进 `bridge-tests.yml`）

---

### 1.7 `getWorkspacesData()` 同步全量读盘 + N+1，会卡死整个网关

`lib/index.js:438-540`。每次调用 `/api/mobile/workspaces`：

```
:445   readFileSync + JSON.parse 整个 workspace.json
:454   for (const sId of sessionIds)            ← 遍历所有工作区的所有会话
:477-478  for (const cPath of candidates) { fs.existsSync(cPath)   ← 每会话最多 3 次 existsSync
:480      JSON.parse(fs.readFileSync(cPath))     ← 每会话读一整个 projection cache 文件
:507      getSettingsData()                      ← ⚠️ 在循环体里！每会话再读一次设置
:509      coreApprovals.list().filter(...)       ← O(会话数 × 审批数)
```
全部是**同步 API**，执行期间 Node 事件循环完全阻塞 → WebSocket 帧、审批推送、心跳全部停摆。

会话数一多就爆炸：你自己的 DSH home 曾经累积到 1270 个会话（`core.mjs:796` 的注释也写着 "the E2E suite accumulated >1000 empty sessions"）。1000 会话 × (3 次 existsSync + 1 次 readFileSync+JSON.parse + 1 次 getSettingsData) ≈ 数千次同步系统调用，秒级卡顿起步。

**改法（按性价比排序）：**
1. `getSettingsData()` 提到循环外，一次调用（一行改动，立刻消掉 N+1）
2. 审批先按 sessionId 建一次索引 Map，循环里 O(1) 查
3. 全量换 `fs.promises` 异步 + `Promise.all` 分片并发
4. 加内存缓存：`workspace.json` 和 projcache 目录用 `fs.watch` / mtime 失效
5. **分页**：每工作区只返回最近 N 条会话 + 总数，客户端下拉加载更多
6. 治本：见 §3.1，改用引擎的 `session/list` / `session/page` RPC

---

### 1.8 版本号 6 处漂移，"版本比对"功能永远是错的

| 位置 | 值 |
|---|---|
| `dsh_mobile/pubspec.yaml:4` | `1.3.0+13` |
| `dsh_mobile/lib/models/app_version.dart:8-9` | `'1.3.0'` / `'13'`（手抄） |
| `dsh-server-plugin/lib/core.mjs:39` | `BRIDGE_VERSION = '1.2.9'` ← 陈旧 |
| `package.json:3` | `"1.2.9"` ← 陈旧 |
| `.github/workflows/build-apk.yml:60-61` | `tag_name: v1.3.0` + 手写发布说明 ← 每次发版要手改 |
| `dsh-server-plugin/client/client.js:271` | UI 上硬编码 `'(v1.2.8)'` ← 陈旧两代 |

`app_version.dart:3-4` 的注释写着「The bridge exposes the same value via `GET /api/mobile/health` as `version`, so the two can be compared」——但 bridge 报 `1.2.9`、App 报 `1.3.0`，**这个比对永远不相等**，任何基于它的"版本落后"提示都是假信号。v1.3.0 发布说明里「版本号单一来源」这条实际没做到。

**改法：** `pubspec.yaml` 作为唯一来源 → 加一个 `scripts/sync-version.mjs`，构建前生成 `app_version.dart`、写入 `core.mjs` 的 `BRIDGE_VERSION`（或改成读 `package.json`）、把 tag 名和 release body 参数化。CI 里用已经写好的 `scripts/read-apk-version.mjs`（目前还是 untracked 状态，`git status` 显示 `?? scripts/read-apk-version.mjs`）反向断言"APK 里的 versionName == pubspec 版本"。

### 1.9 超过 4 分钟的任务，UI 会静默"假装结束" ⭐功能性缺陷

```
dsh_service.dart:617   maxTicks = 350
dsh_service.dart:619   Timer.periodic(Duration(milliseconds: 700), ...)
dsh_service.dart:621-631  tick 到上限 → 停轮询 + 强制 _isSending=false + isStreaming=false
```
350 × 700ms ≈ **245 秒**。服务端还在跑，手机上却显示"已完成"、输入框解禁、流式光标消失。**编码 Agent 任务动辄十几分钟**，这条几乎必然被踩到，而且用户完全无法察觉（没有任何"轮询已超时，状态可能不准"的提示）。

**改法：** 去掉 maxTicks 硬上限，改成"连续 N 次无变化就退避到 3s/10s"的自适应轮询；或者干脆修好 §1.10 的 WS follow，让推送成为主通道、轮询只做兜底。到上限时必须给用户显式提示。

---

### 1.10 冷启动时 `follow` 帧被静默丢弃 → 这才是必须靠 700ms 轮询兜底的真正原因

```
dsh_service.dart:230   _channel = WebSocketChannel.connect(uri);   // 惰性，握手未完成
dsh_service.dart:232-239  只有收到「第一帧」才把 _status 置为 connected
dsh_service.dart:274   await fetchWorkspaces();                    // 紧接着就开始发 HTTP
dsh_service.dart:316   selectSession(...)
dsh_service.dart:368   _sendWsJson({'type':'follow', ...})
dsh_service.dart:343-351  _sendWsJson 只在 _status == connected 时才真发，否则只 debugPrint
```
冷启动路径上 `follow` 几乎必然在 WS 首帧到达之前发出 → **被静默丢弃**，网关永远不知道该推哪个会话的流（`index.js:1764-1778` 收不到 subscribe 就不 `followSession`）→ 客户端只能靠 700ms 全量轮询拿数据 → 又引发 §1.7 / §3.4 的全部性能问题。

**这是一条因果链的源头**，修好它，轮询、流量、重建全都能降下来。

**改法：** `await _channel!.ready` 后再发初始帧；`_sendWsJson` 改成"未连接就入待发队列，连上后 flush"；`follow` 加 ack 超时重发（网关的 `follow_ack`（`index.js:1777`）现在客户端根本没接，见 §3.6）。

---

### 1.11 半开连接（half-open）完全检测不到

`dsh_service.dart:1494-1507` 每 15 秒发一次 `'ping'`，但：
- **没有 `lastPongAt`、没有 pong 超时判定、没有读超时**
- 发送异常被 `catch (_) {}` 吞掉（`:1504`）
- 收到 pong 后什么都不做（`:1251`、`:1258` 直接 return）

手机切 Wi-Fi↔4G、NAT 表项过期、隧道静默断开时，TCP 不会给 `onDone`/`onError` → `_status` 恒为 `connected`，UI 显示"在线"，但发消息全部超时、`_sendWsJson` 静默失败。**这是移动端长连接的头号故障模式，当前零覆盖。**

顺带：三种探活写法并存 —— 心跳发裸 `'ping'`（`:1503`）、重连后发 `{'type':'ping'}` JSON（`:1625`）、resume 又发裸 `'ping'`（`:1664`）。

**改法：** 记 `lastPongAt`，超过 2 个心跳周期没收到 pong 就主动 `sink.close()` 触发重连；统一探活协议；发送失败计入健康度。

---

### 1.12 `ConfigPage` 完全没有 `dispose()`，5 个 Controller 每次进页面泄漏一次

`config_page.dart:17-23` 创建了 `_hostController` / `_portController` / `_tokenController` / `_npsController` / `_authCodeController`，**全文件 grep `void dispose()` 零命中**。而 ConfigPage 会被反复 push（`main_shell.dart:118-120`、`chat_view.dart:901-903`、`custom_settings_view.dart:398-401`）→ 每进一次配置页泄漏 5 个 controller。

同类：`approval_card.dart:56` 拒绝理由 sheet 的 `TextEditingController` 没有 `.whenComplete(() => dispose())`（对比 `workspaces_view.dart:239` 的 MEMORY 编辑器**做对了**，说明是遗漏不是风格）。

**还有一条更隐蔽的**：`workspaces_view.dart:33-42` 有个 3 秒定时器，虽然 `dispose()` 里 cancel 了（`:47-48`），但 **`main_shell.dart:133-146` 的 IndexedStack 让 4 个 tab 永不 dispose** → 只要 App 在前台，**无论用户在哪个 tab，每 3 秒一次全量 `/api/mobile/workspaces`**（正好撞上 §1.7 那个同步全量读盘的接口）。`handleAppPaused`（`dsh_service.dart:1677-1681`）只停了 `_sessionPollTimer`，**没停这个 UI 层定时器**。

---

### 1.13 一整批"看起来能用、其实是安慰剂"的功能

| # | 功能 | 证据 | 判定 |
|---|---|---|---|
| 1 | **Persona 智能体人设**：service 全套 + model 完整（`dsh_service.dart:1139-1182`、`persona.dart:1-37`），每次连接还白发一次 `/api/mobile/personas`（`:279`） | grep 全 lib：除 service/model 外 **0 处引用** | **整套死功能**。`custom_settings_view.dart` 的区块编号从 `// 1.`(:220) 跳到 `// 3.`(:325)，缺的 2 就是被删掉的 Persona 区块 |
| 2 | **深度思考预算 slider**（`custom_settings_view.dart:278-295`） | `dsh_service.dart:1184-1187` 只赋值 + notify；prompt body 只有 `sessionId/text/model`（`:563-567`） | **UI 安慰剂**，拖动无任何服务端效果 |
| 3 | **Temperature slider**（`custom_settings_view.dart:298-318`） | `dsh_service.dart:1189-1192` 同上 | **UI 安慰剂** |
| 4 | **NPS 地址输入框** | 采集 `config_page.dart:185-193`、持久化 `server_config.dart:7,74,83`；但 `httpBaseUrl`/`wsUrl` 只用 `cleanHost:cleanPort`（`server_config.dart:59-67`） | **从不参与任何 URL 构造** |
| 5 | **审批多选项 `options`** | 解析了（`approval_request.dart:13,61`），但 `approval_card.dart:222-539` 只有"拒绝/允许一次"两个按钮 | **从不渲染** → 服务端多选项审批在手机上不可表达（这正是 §4.1-1 `ask_user_question` 的现成落点） |
| 6 | **暗色主题** | `main.dart:85-96` darkTheme 是亮色副本（`brightness: Brightness.light`），`:97` `themeMode` 硬锁 light | **12 行死配置** |
| 7 | **版本比对** | `app_version.dart:3-4` 注释说要比对 health 的 `version`，但代码从不解析（`dsh_service.dart:182` 只探活） | **死设计意图** |
| 8 | `SessionMeta.lastSeq` | `workspace.dart:7,17,35,45,66,78` 全链路解析/序列化 | **零读取方** → 直接导致 §3.8 无序号去重能力 |
| 9 | `setSessionPermission()` | `dsh_service.dart:1110-1115` | **无调用方**（`chat_view.dart:366-382` 自己拼 map 调 `updatePermissions`） |
| 10 | `disconnect()` | `dsh_service.dart:1683-1698` | 除 `dispose()` 外无调用方 → **UI 里没有"断开连接"入口** |
| 11 | `case 'clear'` | `chat_view.dart:1307-1309` | itemBuilder（`:1315-1357`）只产出 model/permission/workspaces/delete 四项 → **不可达分支** |
| 12 | `ACCESS_NETWORK_STATE` 权限 | `AndroidManifest.xml:6` | 代码零使用（无 `connectivity_plus`）→ **冗余权限声明** |
| 13 | `cupertino_icons` 依赖 | `pubspec.yaml:14` | grep `CupertinoIcons` = 0 |
| 14 | 回车发送 | `chat_view.dart:1863` `onSubmitted` + `:1854` `maxLines: 4` | 多行 TextField 默认 action 是换行 → **onSubmitted 基本不触发** |

> 全项目 grep `TODO|FIXME|UnimplementedError|占位|敬请期待` = **0 命中**。没有显式占位符，但有 **14+ 处静默死代码/安慰剂**——比 TODO 更难发现，因为 UI 上看着是完整的。

### 1.14 🔴 测试套件正在污染你的真实环境，而且自动回收机制整体失效

**这条直接命中你 2026-10-08 定的规矩（"跑测试前必须先确认不会污染真实数据"）。1270 条空会话不是意外，是这套测试的必然结果，而且现在还在发生。**

**(a) 往你的真实工作区留垃圾文件（已核实：三个文件都在，时间戳是今天）**
```
E:\workspace\个人\E2E_MEMORY_TEST.MD            47 B   2026-10-08 14:27:57   ← workspace-memory.test.js:46
E:\workspace\个人\LARGE_MEMORY_TEST.MD      96,016 B   2026-10-08 14:28:08   ← oversized-payloads.test.js:71
E:\workspace\个人\PROJECT_WORKLOAD_MEMORY.MD   116 B   2026-10-08 14:28:41   ← mobile-developer-memory.test.js:19
```
⚠️ **注意这三个文件在仓库之外**（仓库根是 `E:\workspace\个人\dsh_mobile`，实测 `git check-ignore` 直接报 `is outside repository`）→ **`.gitignore` 根本管不到它们**，它们污染的是你日常干活的真实工作区目录，会出现在 DSH 的 workspace-file 视图、被 `glob`/`grep` 扫到、被 Agent 当成项目文件读取。

**改法不是加 gitignore，而是让测试写到临时目录**：这三个用例的 `workspacePath` 应指向 `fs.mkdtempSync(os.tmpdir())` 或一个专用的 `tests/.sandbox/` 工作区，测完 `rm -rf`。顺带在 `.gitignore:43-47`（已有的测试残留规则区）补上 `apk-artifact.zip`（`await-apk.mjs:111` 会写到 cwd）。

**(b) 篡改真实权限/模型配置且不恢复**
| 位置 | 干了什么 |
|---|---|
| `tier1-features/permissions.test.js:97` | 对你的**真实会话**设 `danger-full-access`，TC5 **无任何 restore**（同文件 TC2/3/4 都有 `:44-47`/`:64-67`/`:84-87`） |
| `tier3-cross-feature/permission-prompt.test.js:67-70` | finally 里恢复成**硬编码 `'auto-read'`**，而不是 `:15` 明明读到的 `origPolicy` → 你原本是 `ask` 的话，跑一次测试就**被静默降级** |
| 同上 `:74-91` | 留下 `maxSteps: 30` 不恢复 |
| `tier1-features/models-and-settings.test.js:39-42` | 改**全局默认模型**，既不存原值也不恢复；`:49-65` 改真实会话模型同样不恢复 |
| `tier4-workloads/benchmark-policy-sync.mjs:26,51-59` | 30 轮把真实全局策略在 `danger-full-access`/`workspace-write`/`auto-read` 之间反复刷，**全程无 before/after 备份**（对比 `policy-sync-persistence-stress.test.js:28-49` 是做对了的） |
| `burst-concurrency-stress.mjs:37,44-46` | 同上，还额外翻 `protectGit` |

而且这些 restore **都不在 try/finally 内** → 中途 assert 失败就跳过恢复，环境被永久改坏。

**(c) 会话自动回收：五处失效叠加**
1. **`tests/cleanup-hook.mjs` 是死文件**：全仓 grep `cleanup-hook` 只命中它自己（`:6/:11/:19`）。`package.json:8-18` 六条 test 脚本全是裸 `node --test`，**没有一条带 `--import ./tests/cleanup-hook.mjs`**——而它自己的注释 `:5-8` 声称"wired through `--import`"。**注释与实际接线状态相反。**
2. **即使接上，语义也是错的**：`cleanup-hook.mjs:19` 是**顶层 await**，会在模块加载时（测试**开始之前**）执行清理；`:13-17` 的 `process.on('exit')` 是**空函数体**。而 `session-cleanup.js:137` 是 `writeState([])` → 测试前先把上一轮待清理的 id 表**清空** → 泄漏永久化。
3. **登记条件把真实 id 形态过滤掉了**：`client.js:72` 排除 `sid.startsWith('session-')`，但真实会话 id 恰恰常以 `session-` 开头（`session-cleanup.js:36` 专门 strip 这个前缀、`delete-session.test.mjs:51` 的 `['session-a','session-b']` 为证）→ **prompt 隐式建会话的主要形态根本不登记**。
4. **大量测试绕过登记路径**：`stress_cancel.mjs`、`r3_adversarial_verify.mjs`、`m2/m3/m4_*` 直接手写 `fetch`/`new WebSocket`（`m3_stress_challenge.test.js:289/414/567`、`m2:351/421` 等 27 处），**创建的会话完全不进回收表**。`probe_dsh.cjs:106` 更是绕过网关直连引擎 3080 建会话，`:119` 用 `session/delete` 清理——而这个 RPC **项目自己在 `session-cleanup.js:10` 就认定不存在** → **每跑一次 probe 必泄漏一个真实会话**。
5. **归档方式与引擎抢写**：`session-cleanup.js:17-19` 自己写明"Editing workspace.json **does not stick** — the engine holds the table in memory and rewrites the file within seconds"，但 `:81-101` 恰恰就是读-改-写 `workspace.json` → 无锁竞态，引擎在 `:83` 读与 `:101` rename 之间回写就把 `archivedSessionIds` 覆盖丢掉。加上 `:29` 的 `STATE_FILE` 在 `os.tmpdir()` **无 run-id 隔离**，并发运行互相 `writeState([])` 抹掉对方记录。

**(d) 一次 `npm test` 的真实代价（静态调用点 + 循环放大实测）**
- 约 **750~850 次**真实 HTTP/WS 调用
- 创建约 **55~65 个真实会话**
- 其中约 **25~30 次是真实 LLM prompt**（`stress_cancel.mjs:29` `'Hello, what is 2+2?'`、`:134` 10 次、`r3_adversarial_verify.mjs:35/98/110/178`、`prompt-and-cancel.test.js:123/172/215`）→ **真金白银的 token 消耗**
- `npm run verify` 再加 bench：约 **900~1100 次**调用
- 固定 sleep 合计 **8210ms**，全程 `--test-concurrency=1` 串行

**改法（按顺序）：**
1. 立刻给 `.gitignore` 补 `E2E_MEMORY_TEST.MD`/`LARGE_MEMORY_TEST.MD`/`PROJECT_WORKLOAD_MEMORY.MD`/`apk-artifact.zip`，并清掉现有残留
2. 抽 `withRestoredPermissions(fn)` helper（照抄 `policy-sync-persistence-stress.test.js:28-49` 的正确做法），所有策略/模型变更必须经它，restore 一律 try/finally + 精确回填原值，**禁止 `|| 'auto-read'` 这种兜底**
3. `package.json` 拆分脚本：`test:fast`（hermetic unit，可进 CI）/ `test:contract`（打一次性容器）/ **`test:destructive`（会改真实配置的，默认不进 `npm test`）**。现在 `package.json:7` 把破坏性测试和 hermetic 单测混在一条命令里，是最大的使用陷阱
4. 修回收链：`--import` 接上 + 改成 `test.after`/`beforeExit` + 删掉 `client.js:72` 的 `session-` 前缀过滤 + `STATE_FILE` 加 run-id + 把 m2/m3/stress/r3 的手写 fetch 统一换回 `apiRequest`
5. bench/stress 一律用临时 `DSH_HOME`（现在只有 `smoke-bridge.test.mjs:19` 做了隔离，`m2:315-321`、`m3:211-217` 起真网关却**不隔离 DSH_HOME**，读写的是你真实的 `permissions.json`/`workspace.json`）
6. 给真实 LLM prompt 的那些用例加 `SKIP_LIVE_LLM=1` 开关，默认走 mock upstream

---

### 1.15 `.gitignore` 的"永不提交"规则已经被突破

`.gitignore:31-33` 原文：
```
# Agent orchestration scratch — contains sub-agent transcripts with live
# tokens (GitHub PATs, bridge tokens, engine secrets). Never commit.
.agents/
```
但 `git ls-files` **包含 `.agents/hooks.json`** —— gitignore 对已跟踪文件无效。该文件内容是机器专属绝对路径（`E:\soft\aionUi\resources\bundled-aioncore\win32-x64\aioncore.exe`），这次没泄密是运气，**规则已经实际失效**。

**改法：** `git rm --cached .agents/hooks.json`；同时 CI 加 secret 扫描门禁（见 §5.4）。

顺带一条同类的：`dsh-server-plugin/scripts/check-secret.mjs:18` 打印密钥**前 8 字符**、`:25` 打印**前 12 字符 + 长度** → 一旦被 CI 或 agent 调用，就把引擎 HMAC 密钥前缀写进日志，可用于缩小离线爆破搜索空间。

---

### 1.16 APK 下载链路在任何新克隆环境必然 404，且下载页显示的版本错了 3 个

- `lib/index.js:1186` 要读 `public/dsh-agent.apk`，但 `.gitignore:17` 是 `**/*.apk` → **运行所必需的二进制被排除在版本库外**，新机器部署即 404（`:1196-1199`）
- 回退路径写死过期版本：`:1187` `dsh-agent-v1.2.6.apk`、`:1188` `../../dsh-agent-v1.2.0.apk` → 当前发布 v1.3.0，用户可能**静默下到 v1.2.0**
- `public/index.html:539` 硬编码 `版本: v1.1.0 • 大小: 22.28 MB`（实际 v1.3.0 / 22.8 MB），而 `:819-822` 还会据此生成二维码 → **用户扫码看到的版本和大小都是错的**
- CI 从不下回产物放进 `public/`，而 `custom_settings_view.dart:475-489` 提供了"复制 APK 下载直链"功能指向它 → 这条链路完全靠手工放置

**改法：** 删掉两个写死回退；改为读 `public/apk-manifest.json`（版本/文件名/size/sha256，CI 发布后回填），或直接 302 到 GitHub Release asset；下载页文案从 manifest 渲染。

### 1.17 🔴🔴 引擎 HMAC 签名密钥已泄露在 git 历史中，且**当前仍然有效**（已实测确认）

这是本次分析最严重的一条，我已亲自验证，不是推测。

**实测结果：**
```
legacy 含引擎密钥字面量: True          ← index.js.legacy 仍在磁盘（75,973 B，未跟踪）
legacy 含真实令牌字面量: True
git log --all -S 'Ci223VxbS2XsFJm0pUnm3eU'  → c411a7f / 1dc8a24 / 5e95a6d
git log --all -S 'dsh_19f234dcf9fe14fc2409901e6a7bbe7e73b1' → 同上三个 commit
引擎 credentials.yaml secret 长度 = 43
当前引擎 secret == 泄露值 ? True       ← 🔴 泄露的密钥现在就是活的生产密钥
当前网关 token == 泄露值 ? False       ← 令牌已换（好事）
当前网关 token 长度 = 8                ← ⚠️ 但只有 8 字符，且全链路零限速
```

**注意那个 commit 的标题**：`c411a7f fix(bridge): 统一网关核心逻辑、修复假删除接口、**移除硬编码密钥**` —— 它只从 HEAD 移除了，**历史三个 commit 里全都还在**。`git log -S` 一条命令就能捞回来。

**完整攻击链（每一环都已在代码中定位）：**
```
1. 拿到仓库读权限（PAT 已泄露在 .git/config，见 §1.1）
2. git log --all -S 'Ci223' → 取出引擎 HMAC secret
3. core.mjs:90-115 createCookieFactory 就是现成的利用说明书：
     cookie 名 = sha256(authority)
     cookie 值 = HMAC-SHA256(secret, body)，有效期 24h
4. 自签 dsh-auth-* cookie → 直连 3080
5. 3080 是 DSH 引擎本体 = 宿主机任意代码执行
   ⚠️ 完全绕过网关的鉴权、审批、auto-read 分类器、审计——那一层根本不在路径上
```

**现实暴露面：** DSH 把 3080 硬编码绑 `127.0.0.1`（这是官方的有意设计，理由是"避免把 RCE 暴露到网络"）。所以第 4 步要求攻击者能触达 3080。你装了 `dsh-port-3080-3081-diagnose` 和 `nps-tunnel-troubleshoot` 两个技能，说明你确实在用 **dsh-pocket 这类"改头代理"（绑 0.0.0.0，把 Host/Origin 改写成 127.0.0.1:3080）+ NPS 隧道**。那条路径一旦开着，**这个泄露的密钥就是远程 root**。

同时网关自己也是 `0.0.0.0`（`dsh-server-plugin/index.js:28`、`lib/index.js:137,1807`），README 还明确教用户映射到公网——而它的令牌只有 8 字符、**全仓 `grep -E 'rate|throttle|attempt|lockout'` 在 `lib/` 下零命中**（无限速、无失败计数、无锁定）。

**处置（按顺序，前 3 步今天就该做）：**

```powershell
# ① 立刻轮换引擎 HMAC 密钥（这一步就让历史里的泄露值作废）
#    备份 → 删掉 → 让 DSH 重新生成 → 重启引擎
Copy-Item "$env:USERPROFILE\.dsh\.credentials.yaml" "$env:USERPROFILE\.dsh\.credentials.yaml.bak"
#    然后编辑该文件，把 secret: 换成一个新的 43 字符 base64url 随机值：
node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"
#    重启 dsh web 与网关

# ② 换掉只有 8 字符的网关令牌，换成 generateToken() 的 36 字符格式
#    编辑 ~/.dsh/mobile-bridge/config.json 的 token 字段，或：
node -e "console.log('dsh_'+require('crypto').randomBytes(16).toString('hex'))"

# ③ 作废泄露的 PAT（见 §1.1）+ 删除磁盘上的 legacy
cd 'E:\workspace\个人\dsh_mobile'
Remove-Item 'dsh-server-plugin\index.js.legacy'   # 未跟踪，删了不影响 git
#    GitHub → Settings → Developer settings → 撤销那个 ghp_ PAT

# ④ 清洗 git 历史（仓库是私有的，可以慢慢做，但必须做）
git filter-repo --replace-text <(echo "Ci223VxbS2XsFJm0pUnm3eU_PPhG4L1A9T6AWaTu4pA==>REDACTED")
#    或者更彻底：既然只有 25 个 commit、.git 仅 1.0 MB，
#    直接 squash 成一个初始 commit 重开历史，成本最低
```

**长期防线：** CI 加 `gitleaks`/`trufflehog` 扫全历史 + PR diff；给 `dsh-server-plugin/scripts/check-secret.mjs:18/25` 脱敏（它现在会把密钥**前 8 位和前 12 位**打到 stdout，一旦被 CI 或 agent 调用就等于把密钥前缀写进日志）；加一条"禁止源码中出现 base64url 长度 ≥32 的字面量"的静态检查。

---

### 1.18 默认策略 `auto-read` 的自动放行分类器可被绕过 → 密钥外泄 → 宿主机 shell

这条与 §1.17 组成闭环。默认策略就是 `auto-read`（`store.mjs:120-121`），而它的分类器有四个洞：

```
core.mjs:263-267  READ_ONLY_PREFIXES = ['ls','dir','cat','grep','find','head','tail','wc',
                                        'git status','git log','git diff','pwd','echo','which','where']
core.mjs:279      SHELL_METACHARACTERS = /[;&|><`$(){}[\]!*?~\n\r]/
core.mjs:281-288  isCommandReadOnly: 工具名命中 READ_ONLY_TOOLS 直接 return true（不看参数）
lib/index.js:971-979  auto-read → isCommandReadOnly(cmdToCheck, toolName) → shouldAutoApprove
lib/index.js:981-990  直接 callDshRpc('$events/result', {outcome:'allowed-once'})
```

**洞 1：破坏性命令被判为"只读"。** `find <path> -delete`、`find . -empty -delete` —— `-` 和字母都不在元字符集合里 → 判定只读 → **自动放行**。同理 `tail -f /dev/zero`（资源耗尽）、`git log --output=<file>`（`--output` 无元字符，实际会写文件）。

**洞 2：任意文件读 → 密钥外泄。** `cat C:\Users\Administrator\.dsh\.credentials.yaml`、`head -n 999 ~/.dsh/mobile-bridge/internal-secret` —— 无元字符 → 自动放行 → 输出经 `lib/index.js:921 broadcastToMobileClients({type:'tool_result', output})` **全量推给所有已连接客户端**。拿到 §1.17 那个密钥就能自签 cookie 直连 3080。

**洞 3：`READ_ONLY_TOOLS` 只看工具名。** `core.mjs:268` 的 `['read_file','view_file','search_web','list_dir']`，`core.mjs:282` 第一行就 `return true` —— **完全不看参数**。`read_file` 读 `~/.dsh/.credentials.yaml` 一样自动放行。

**洞 4：用"模型自述的理由"决定"命令"是否放行。**
```
lib/index.js:972-974  cmdToCheck = reason → val.request.command → input
```
`reason` 是**模型自己写的理由文本**。用理由决定命令，语义上就是错的；`reason` 恰好是 `'ls'`/`'pwd'` 时，**任何工具调用都会被自动放行**。

**洞 5（附带）：会话级 `ask` 是个假开关。**
```
lib/index.js:968  if (sessionPolicy === 'danger-full-access' || global === 'danger-full-access')
lib/index.js:971  } else if (sessionPolicy === 'auto-read'  || global === 'auto-read')
```
用 **OR** 合成 → 全局是 `auto-read`（默认）时，把某个会话单独设成 `ask` **完全不起作用**。而 Dart 端确实提供这个选项（`chat_view.dart:454-471`）→ 用户在手机上"把敏感会话改成每次询问"，实际上什么都没改。

**改法：**
1. 判定输入**只用结构化的 `val.request.command`/`input`**，删掉 `reason` 回退（`lib/index.js:972`）
2. `READ_ONLY_PREFIXES` 移除 `find` 和 `echo`；或加参数黑名单 `-delete/-exec/-execdir/-ok/-fprint/-fprintf/-o/--output`
3. `READ_ONLY_TOOLS` 改成"工具名 + 参数形状"双条件，不再 `return true`
4. 给 `cat/head/tail/grep/read_file` 加路径白名单（仅注册工作区内），**硬拦** `~/.dsh/**`、`*.credentials*`、`*internal-secret*`、`*.env`、`id_rsa`
5. 策略合成改为**会话优先、全局兜底**：`const eff = sessions.get(sid) ?? global.executionPolicy`。`core.mjs:680-683 forSession` **已经是这个正确语义**，直接用它，删掉 `968/971` 的 OR
6. 默认策略从 `auto-read` 改 `ask`（`store.mjs:120-121`）—— 代价是审批次数上升，但这正是 `ask` 应有的行为

---

### 1.19 `sessionId` 零校验 → 持令牌者可删除宿主机任意 `.json` 文件

```
lib/index.js:1510-1515   POST /api/mobile/sessions/delete
  → core.mjs:810         clean = id.replace(/^session-/,'')     ← 只剥前缀，无任何过滤
  → core.mjs:852-855     对 [`${clean}.json`, `${id}.json`, `session-${clean}.json`]
                         逐个 path.join(cacheDir, name) + fs.unlinkSync()
```
传 `sessionId = ../../../../.dsh/storages/workspace` → **删掉 `workspace.json`，整站会话列表归零**。

同一入口的第二条路径：`lib/index.js:1339` → `546-548` `path.join(projCacheDir, ${sessionId}.json)` + `553-555 readFileSync` → 任意 `*.json` 读取（受限：内容需符合 `record.rows` 结构才回显，`570-580`）。

第三条：`core.mjs:824-826` 把原始 `id` **无上限地 push** 进 `global.archivedSessionIds` 并写回 `workspace.json`（`843-845`）→ 该数组可被无限撑大，而 `lib/index.js:445-447` 每次列工作区都要全量 `readFileSync + JSON.parse + new Set(...)` → **可放大的持久化 DoS**。

**改法：** 在 `core.mjs` 加 `assertSessionId(id)`：`/^[A-Za-z0-9_-]{1,64}$/`，不匹配直接 400；在 `lib/index.js:1339 / 1367 / 1466 / 1511 / 1552 / 1582` **所有入口**调用；`archivedSessionIds` 加长度上限（如 5000，超出丢最旧）。

---

### 1.20 路径消毒器在"注册工作区表为空"时**整层跳过** → 任意绝对路径读写

```
core.mjs:231   if (registeredPaths.length > 0) {     ← 注册表为空则第 2 层校验整段跳过
core.mjs:244     if (!within) return { error:'...not a registered workspace', status:403 };
```
空表来源三条：`lib/index.js:442`（`workspace.json` 不存在时返回 `[]`）、`536-539`（解析异常返回 `[]`）、`144`（`lastWorkspaces` 初值）。

→ 只要 `~/.dsh/storages/workspace.json` 缺失/损坏/尚未生成，`GET|POST /api/mobile/memory` 的第 2 层静默失效。剩下的第 1 层（`core.mjs:213-220` 字面量 `..`/绝对路径/盘符检查）**只作用于 `fileName`，完全不约束 `workspacePath`**；第 3 层（`core.mjs:249-254`）只要求 `resolvedTarget` 落在**攻击者自选的** `resolvedWs` 内。

**结果：** `?workspacePath=C:\Windows\System32&fileName=drivers\etc\hosts` 通过全部检查 → `lib/index.js:1617 readFileSync` **任意读**、`lib/index.js:1636-1637 mkdirSync + writeFileSync` **任意写**（≤2MB）。

**改法：** 反转为 fail-closed —— `if (registeredPaths.length === 0) return { error:'No registered workspace', status:403 }`；把 `..`/绝对路径/盘符检查同样施加到 `wsPath`；写路径给 `fileName` 加白名单（`MEMORY.md`/`USER.md`/`AGENTS.md`/`*.md`）。

---

### 1.21 🔴🔴 手机断网即打崩**整个 dsh web**（unhandledRejection → 进程终止）

> **严重性上调（2026-10-08 实测）**：本条原记为 🔴 P0，现上调至 🔴🔴，与 §1.17 同级。原因是本轮确认了被杀进程的范围：
>
> - 监听 3088 的进程**就是 dsh web 本体**（PID 60260，命令行 `node …\@deepseek-ai\dsh\lib\bin.js web`，同时监听 3080/127.0.0.1 与 3088/0.0.0.0）。网关以 Cordis 插件形式跑在它进程内。
> - 所以 `throw err` 逃逸导致的进程终止，**不是「网关重启」，而是整个引擎连同所有活跃会话一起死**。
> - **不需要攻击者**。触发路径是日常操作：手机在 POST 上传途中断网、切 Wi-Fi、锁屏被系统回收 socket、或运营商 NAT 超时 → `ECONNRESET` → 进程终止。
> - 3088 绑 `0.0.0.0`，远程可达；配合 §1.17 的隧道场景，这也是一条稳定的远程 DoS。
> - 已在 `patches/0001` 中修复。

```
lib/index.js:1319-1325   let raw; try { raw = await readBodyWithLimit(...) }
                         catch (err) { if (err?.aborted || res.headersSent) return; throw err; }  ← 1324
lib/index.js:1330        try {   ← 业务 try 从这里才开始（catch 在 1675）
lib/index.js:1125        const server = createServer(async (req, res) => {   ← 无外层 try
```
`1324` 的 `throw err` 落在 `1330` 的 try **之外**，位于 `createServer(async (req,res)=>{...})`（`1125`）返回的 promise 里。Node 的 http server **不 await** 这个 promise → `unhandledRejection` → **Node ≥15 默认 `--unhandled-rejections=throw` 终止进程**。

`grep unhandledRejection|uncaughtException lib/index.js` = **0 命中**，全文件没有任何兜底 handler。

触发条件：`core.mjs:777 req.on('error', err => reject(err))` —— 注意它 reject 时**不带** `aborted: true`，而 `1323` 的守卫正是 `if (err?.aborted || res.headersSent) return;`，所以 socket 错误直接穿过守卫落到 `throw`。此时 `err.aborted` 为 undefined、`res.headersSent` 为 false。任何持令牌者可稳定复现；`POST /__mobile/pair` 走自己的读体分支（`1241-1256`）不受影响。

**改法（`patches/0001` 已实现）：** 不再 rethrow，改为 `if (!res.headersSent) sendJson(400, { error: 'Bad Request', message: '请求体读取失败或连接已中断' })` 并 `audit('http/body-read-failed', …)` 后 `return`；`sendJson` 调用本身再包一层 try/catch（socket 可能已经不可写）。另建议在 `apply` 顶层加 `process.on('unhandledRejection')` 兜底日志（记录但不吞）—— 该兜底**不在**补丁内，因为它属于全局进程行为，应由 dsh 本体而非插件决定。

---

### 1.22 审批状态机的三处致命缺陷

**(a) 先删后发，不可回滚**
```
lib/index.js:1083  coreApprovals.remove(appr, eventId);      ← 先出队
lib/index.js:1092  await callDshRpc('$events/result', {...}); ← 后通知引擎
lib/index.js:1102-1104  catch → 只 logger.warn
lib/index.js:1106  broadcastToMobileClients({type:'approval_settled', ...})
lib/index.js:1113-1120  仍 return { ok:true, code:0, ... }
```
上游 RPC 失败时：队列里已经没有了、手机已收到 `approval_settled`、HTTP 回了 `ok:true`，而**引擎侧的工具调用永久挂起**，`GET /api/mobile/approvals` 再也看不到它 —— 无任何恢复入口。
自动放行同样：`lib/index.js:982-987` `.catch(() => {})`，失败不重试、不审计、不降级为人工审批。

**改法：** 改成「标记 in-flight → await → 成功才 remove；失败则回滚入队并广播 `approval_settled{outcome:'failed',reason}`」；自动放行失败时降级为人工审批（`put` + 广播 `approval_request`）+ `audit('approval/auto-approve-failed')`。

**(b) 审批的 `sessionId` 取的是 agent id，不是 session id**
```
lib/index.js:957   const sessionId = val.agent || val.agentId || 'default';
```
连锁后果三条：
- `lib/index.js:964 getSessionPermission(sessionId)` 查 `sessionPolicies`（键是会话 id）→ **永远 miss** → 一律落到全局策略（这就是 §1.18 洞 5 的另一半原因）
- `core.mjs:624-627 removeBySession` 在删除会话时**清不掉**该会话遗留的审批
- `lib/index.js:509-513` 统计每会话 `pendingApprovals` 的过滤条件**恒为假** → **工作区列表上的"待审批角标"永远不亮**，而 Dart 端 `main_shell.dart:187-193` 正是靠这个数显示角标

**(c) 未命中时 HTTP 恒返回 200**
```
lib/index.js:1069-1076  返回 { ok:false, code:404 }
lib/index.js:1601-1602  sendJson(200, resOutcome)      ← 状态码恒定 200
```
手机与 Web 控制台同时点"允许"时，后到者收到 HTTP 200 + `ok:false`。Dart 端 `dsh_service.dart:1052-1054` 的 catch 只 debugPrint → **用户以为批了，Agent 实际卡死**。

**改法：** `sendJson(resOutcome.code && resOutcome.code !== 0 ? resOutcome.code : 200, resOutcome)`，并同步改 Dart 端读 body 而非只看状态码（这是必须一起改的联动项）。

---

### 1.23 设备配对与角色控制：整条链路是空实现

```
lib/index.js:1271-1286  配对成功 → newToken() → hashToken(token) 存进 devices.json 的 tokenHash
store.mjs:105-113       verifyToken 只比对 cfg.token 与 DSH_AUTH_TOKEN，
                        从不读 devices.json、从不比对 tokenHash
store.mjs:295           hashToken 定义了；tokenHash 的唯一读取点是 rpc.mjs:97 —— 用途是把它删掉
store.mjs:115-117       roleCanWrite() 恒 true，且无调用方
core.mjs:731            authenticateRequest 通过后恒定返回 {id:'admin', role:'readwrite'}
lib/index.js:1312       touchDevice(auth.device.id) → store.mjs:264-270 find(d=>d.id==='admin') 必然 miss
rpc.mjs:88-92           设置页的 pair/code 只 newPairCode() 返回，从不写 pairSession
                        而 lib/index.js:1261 校验时读的正是 pairSession
```

**结论：**
1. **配对发出去的令牌永远无法认证** —— 手机配对成功后拿到 token，下一次请求就 401
2. **从 DSH 设置页拿到的配对码必然失败** —— 手机输入后得到 `lib/index.js:1262` 的「配对码已失效或未生成」
3. **「只读/读写角色控制」（`lib/index.js:7` 头注释宣称）与「设备 lastSeen 统计」全是空实现**，而每个已鉴权请求还要为此白读一次磁盘（`touchDevice`）
4. `devices/revoke`（`rpc.mjs:100-105`）删掉的记录本来就没被用过
5. `POST /__mobile/pair` 无鉴权、无限速、6 位数字码、10 分钟有效、`lib/index.js:1265` 明文非常量时间比对 → 理论空间 10⁶，可以持续撞。**唯一"保护"是撞中后拿到的 token 根本无法使用**（第 1 点）—— 用 bug 掩盖 bug。

**改法（二选一）：**
- **(A) 修好**：`verifyToken` 增加设备令牌分支 —— `loadDevices()` 建内存索引 `Map<tokenHash, device>`（启动载入 + `saveDevices` 时更新），用 `crypto.timingSafeEqual(sha256(input), Buffer.from(tokenHash,'hex'))` 比对，命中返回真实 `{id,name,role}`；`pairSession` 提升为 `store.mjs` 的进程级单例（`setPairCode`/`consumePairCode`），让 `rpc.mjs:89` 与 `lib/index.js:1223-1225` 共用；给 `/__mobile/pair` 加 per-IP 尝试计数（5 次失败锁 15 分钟）
- **(B) 删掉**：`grep __mobile` 在 `dsh_mobile/lib` **零命中** —— Dart 端根本不用配对。若确认无其他客户端依赖，直接移除 `lib/index.js:1215-1303` + `rpc.mjs:88-92` + `store.mjs:217-295` 的 devices 部分，**减少约 150 行攻击面**

在 (A) 落地前，先直接删掉 `lib/index.js:1312` 那行注定失败的 `touchDevice`（每请求省 2 次 syscall + 1 次 parse）。

---

### 1.24 保存空 token 会导致网关**永久锁死**

```
store.mjs:48   DEFAULT_CONFIG.token = ''
store.mjs:91   updated.token = String(patch.token).trim() || DEFAULT_CONFIG.token   → 落盘空串
store.mjs:68-70  (raw.token && trim) || process.env.DSH_AUTH_TOKEN || generateToken()
                 ← 每次调用新生成一个随机令牌，且【不写回磁盘】
                 （对比 store.mjs:60-64 的新装路径是会写回的）
```
**后果：** 设置页每次刷新显示**不同**的令牌、手机怎么填都是 401、唯一出路是手工删 `~/.dsh/mobile-bridge/config.json`。

配套的两条：`client/client.js:61` `setToken(cfg.token || 'DSH_SECURE_TOKEN_2026')` 与 `public/index.html:677` 同名字面量 —— 4 处把**公开常量**当默认令牌；而 `store.mjs:91` 只做 `trim`、**无强度校验** → 运维在设置页点一下"保存配置"就会把网关令牌设成人人皆知的字符串。

**改法：** ① `saveConfig` 拒绝短 token：`if (t.length < 16) throw new Error('token 至少 16 字符')`；② `store.mjs:68-70` 的 `|| generateToken()` 分支改成「生成后立即 `writeFileSync` 落盘」（复用 `60-64` 的写法），这同时是已锁死机器的自愈路径；③ 去掉 `client.js:61/259`、`public/index.html:677` 的 `DSH_SECURE_TOKEN_2026` 兜底。

---

### 1.25 匿名可冲刷审计 + 未鉴权信息回显

- `/dsh-agent.apk` **无鉴权**（`lib/index.js:1184`，位于 `1306` 鉴权门之前）却每次写审计（`:1210 audit('apk/download',{ip,size})`），而审计环只有 **200 条**（`core.mjs:294,322-323`）→ **未认证攻击者发 200 次 HEAD 请求即可冲掉全部真实审批/prompt 审计记录**。`lib/index.js:1710 audit('ws/dead_prune')`、`1732 audit('ws/connect')` 同样可低成本刷。
- `lib/index.js:1159-1167`：token 无效时仍返回 `{port, version, name}` → 版本/端口指纹。
- 审计只在内存、**不落盘**（重启即丢），`rpc.mjs:107-108 case 'audit/list': return []` 恒空 → 设置页永远看不到任何审计。而 `core.mjs:319-320` 还会把整个 payload `JSON.stringify` 进 `reason` 字段，200 条 × 最大 2MB 输入 → 理论驻留数百 MB。

**改法：** 加约 40 行令牌桶限速（`/health` 与 `/__mobile/*` 5 req/s、`/api/mobile/*` 30 req/s、WS 升级 3/min，超限 429 + `Retry-After`）；认证失败单独计数（per-IP 10 次/分钟 → 锁 10 分钟 + `audit('auth/lockout')`）；`apk/download` 审计改采样或单独计数；审计环**分级**（安全事件与普通事件分两个缓冲，普通事件不可挤占安全事件）；审计落盘。

---

### 1.26 进程运行超过 24 小时后全线静默失效

```
core.mjs:98        cookie expiresAt = issuedAt + 86400*1000
core.mjs:106-108   current() 只在 cookie 为空时生成
lib/index.js:1810  refreshCookie() 只在启动时调一次
core.mjs:152-164   RPC caller 只 JSON.parse(data)，【完全忽略 res.statusCode】
```
→ 进程跑过 24h 后，mux 重连与所有 unary RPC 都带着**过期 cookie** → 全线 `unauthorized`，而日志里只有一句笼统的 RPC Error。**这是"用了一整天后手机突然全不响应，重启网关就好"这类疑难故障的根因。**

**改法：** ① `createRpcCaller` 检查 `res.statusCode === 401/403` → `cookieFactory.refresh()` 后**重试一次**（`session/prompt` 带 `requestId`，`lib/index.js:1406`，天然幂等）；② `current()` 内解析 `expiresAt`，剩余 <1h 自动 refresh；③ mux `open` 时（`lib/index.js:782`）先 refresh 一次。

---

### 1.27 `public/index.html`（895 行 Vue 控制台）已成孤儿

`lib/index.js:1145-1674` 的路由表里**没有 `/`、`/dashboard`、`/admin`、`/ui` 任何一条**（对比 `index.js.legacy:1367-1374` 原本有），也没有通用静态文件服务。但 `package.json:18` 仍把 `public` 打进发布物 → **895 行含审批/模型/工作区全套 UI 的 Vue 控制台在 1.2.x 重构中被静默丢弃**。

顺带：`public/index.html:677` 硬编码 `DSH_SECURE_TOKEN_2026`、`:832` 把 token 放进 WS query、`:539` 版本写成 `v1.1.0`（见 §1.16）。

**二选一：(A) 复活** —— 加 `GET /` 返回它，配一个白名单静态服务（仅 `public/index.html` 与 `*.apk`，`path.basename` 归一 + 拒绝 `..`），APK 路由补 `Range`/`ETag`/`Last-Modified`（现在 `:1201-1209` 全无，22MB 包每次全量重传、手机无法断点续传）。**(B) 删除** —— 连同 6 个历史 APK，发布物从 ~150MB 降到 ~22MB。

另外 `lib/index.js:1187-1188` 的两个 APK 回退路径指向 `..`（插件根）与 `../..`（`dsh_mobile/`），**都不指向 `public/`** —— 是重构遗留的错位路径，即使文件存在也找不到。

---

## 2. P1：安全与网络健壮性

| # | 问题 | 证据 | 改法 |
|---|---|---|---|
| 2.1 | **无任何失败限速/锁定**。README 开篇就写"防止扫描器爆破攻击"，但实现里没有 | 全仓 grep `rateLimit`/`failedAttempts` 零命中；`store.mjs:105-113` 裸比对 | 按 IP+token 做指数退避：5 次失败锁 15 分钟，写审计 |
| 2.2 | **token 走 URL query**，会进 nps/nginx 访问日志、代理缓存、浏览器历史 | `server_config.dart:66` `?token=$effectiveToken`；`core.mjs:721` 服务端也接受 `parsed.query.token` | WS 改成连上后第一帧发 `{type:'auth',token}` 鉴权；服务端保留 query 兼容一个版本后删除 |
| 2.3 | **token 明文存 SharedPreferences**，且无 App 锁 | `storage_service.dart:10` `jsonEncode(config.toJson())`，`server_config.dart:69-76` 含 token/authCode | 换 `flutter_secure_storage`（Android Keystore）；加 `local_auth` 生物识别门禁 |
| 2.4 | **CORS 全开 `*`**，叠加 token-in-query | `lib/index.js:1129` | 收敛为白名单 origin；移动 App 是原生客户端，根本不需要 CORS |
| 2.5 | **默认 bind `0.0.0.0`** + `usesCleartextTraffic="true"` 全局放开明文 | `dsh-server-plugin/index.js:28`；`AndroidManifest.xml:16` | 默认 `127.0.0.1`，公网靠 nps；Android 用 `network_security_config.xml` 只对你的域名放明文 |
| 2.6 | **token 比对非恒定时间**（`===`），且 `hashToken` 已实现却没用于校验 | `store.mjs:110-111`；`store.mjs:295` | `crypto.timingSafeEqual` + 走 hash 比对 |
| 2.7 | **配对码可爆破**：6 位数字、10 分钟有效、无尝试次数限制 | `store.mjs:287` `randomInt(0,1000000)`；`store.mjs:221` TTL；`index.js:1265` 裸 `!==` 比对 | 限 5 次尝试即作废该码；升到 8 位或改用一次性配对链接 |
| 2.8 | **`/dsh-agent.apk` 无鉴权**（在鉴权块 `:1306` 之前） | `lib/index.js:1184-1212` | 若有意公开就写注释说明；否则移到鉴权后 |
| 2.9 | **WS 鉴权失败时 App 会无限重连**而不是提示"授权码错误" | 网关 `index.js:1691-1693` 直接回 `HTTP/1.1 401` 裸文本并 destroy；App 侧 `dsh_service.dart:245` 靠 `errStr.contains('401')` 判断，Dart 抛的是 "was not upgraded to websocket"，**匹配不上** → 走 `:249-254` 通用错误 + `_scheduleReconnect()` 无限重试 | 网关改成先 `handleUpgrade` 再用 close code `4401` 关闭（App 的 `:259` 已经准备好处理 4001/4401/1008 了）；App 侧不要 await 首个消息，显式 `await _channel!.ready` 并 catch |
| 2.10 | 每次请求都同步读一次 `config.json` | `store.mjs:109` `verifyToken → loadConfig → ensureDataDir + readFileSync + JSON.parse` | 内存缓存 + mtime 失效 |
| 2.11 | **`loadConfig` 在配置损坏/token 为空时每次生成新随机 token 且不落盘** → 永久锁死自己 | `store.mjs:70`（`|| generateToken()`）、`store.mjs:78-80`（catch 分支） | 生成后立刻 `saveConfig`；catch 分支不要换 token，报错并保留原文件 |

---

## 3. P2：架构与性能

### 3.1 网关在刮 DSH 的内部文件格式，而不是调它的 RPC ⭐最大的架构风险

| 网关做法 | 证据 | 引擎其实提供了 |
|---|---|---|
| 读 `~/.dsh/storages/workspace.json` + `session_projcache/sessions/*.json`，解析 `rows.title.val` / `rows.sessionListMetadata.val.blank` / `rows.turnBoundary.val.openTurnStartSeq` | `lib/index.js:439-495` | `session/list`、`session/page`、`session/projections` |
| 直接改 `global.archivedSessionIds` 来"删除会话" | `core.mjs:789-805`（注释自述：引擎无 `session/delete` RPC） | `session/rename`、`session/title` 等已有；删除确实没有，但改内部文件是脆的 |
| 伪造 HMAC Cookie 登入引擎 Web 端调 RPC | `core.mjs:90-124`、`index.js:770-780` | `dsh-sdk-jsonrpc-server` / `dsh-api-remotes` 是正规入口 |

这些都是**未公开的内部结构**，DSH 升一个版本（session format 已经迭代到 v4，见 `dsh-session-format-v3-to-v4`）就可能全线崩。建议：凡是引擎有 RPC 的一律走 RPC，只把 `archivedSessionIds` 这类确实没有接口的留作兜底，并写清楚"依赖 DSH 版本 X 的内部格式"。

### 3.2 广播不按订阅过滤，`ws.sessionId` 记了却没用

```
lib/index.js:1766   ws.sessionId = sId;                     // ← 记录了
lib/index.js:747-754 broadcastToMobileClients(msg) { for (const ws of connectedClients) ws.send(raw) }  // ← 从不过滤
```
- 多设备时，A 手机看会话 1，B 手机看会话 2，**两边都收到全量流**：既是带宽浪费，也是隐私问题（不同工作区的内容互串）
- `ws.send` 不检查 `bufferedAmount`，无背压；`catch(_) {}` 吞掉发送失败（`:751`）
- `connectedClients` 无上限 → 连接数打满即 DoS
- 没有 `unsubscribe` 消息类型

**改法：** 广播时按 `ws.sessionId`（或订阅集合）过滤；`bufferedAmount > 阈值` 时丢弃 thinking delta 这类可丢帧、保留 approval/done 这类关键帧；`connectedClients.size` 上限 + 429。

### 3.3 三个巨型文件

| 文件 | 行数 | 具体问题 |
|---|---|---|
| `dsh_mobile/lib/views/chat_view.dart` | ~1900 | `build()` **单个方法 537 行**（`:1062-1599`）；`_buildMessageItem` 200 行（`:1626-1827`）；`_showModelSwitchSheet` 227 行（`:478-705`）；`_showSessionPermissionSheet` 181 行（`:215-396`）；`_showWorkspaceSwitchSheet`（`:777-860`） |
| `dsh-server-plugin/lib/index.js` | 1858 | 一条 `if (pathname === ... && req.method === ...)` 长链（`:1332-1687`，20+ 分支），无路由表、无中间件；`:1146-1156` 把 `core.mjs:716 extractToken` 的逻辑又抄了一遍 |
| `dsh_mobile/lib/services/dsh_service.dart` | 1706 | 一个 ChangeNotifier 管连接/会话/审批/设置/权限/审计/人设/模型；`notifyListeners()` **出现 100+ 次**；`connect()`（`:230-269`）和 `_executeReconnect()`（`:1582-1632`）两段 WS 监听接线几乎逐行重复 |

**建议拆分：**

```
chat_view.dart →
  views/chat/ChatView.dart            （骨架 + AppBar）
  views/chat/MessageList.dart         （ListView.builder + 自动滚动）
  views/chat/InputBar.dart
  views/chat/sheets/ModelSwitchSheet.dart
  views/chat/sheets/SessionPolicySheet.dart
  views/chat/sheets/WorkspaceSheet.dart

lib/index.js →
  lib/routes/{health,apk,pair,workspaces,sessions,settings,permissions,approvals,memory,audit,personas}.mjs
  lib/router.mjs        （路由表：method + path + handler + 是否需要鉴权）
  lib/upstream/mux.mjs  （connectUpstreamMux + handleUpstreamMuxMessage）
  lib/ws/clients.mjs    （连接池 + 订阅过滤 + 背压）

dsh_service.dart →
  services/ConnectionService.dart   （WS + 重连 + 心跳，唯一一处接线）
  services/SessionService.dart
  services/ApprovalService.dart
  services/SettingsService.dart
```

### 3.4 客户端渲染性能：每个 token 触发全树重建

`notifyListeners()` 在 `dsh_service.dart` 里 100+ 处，而 `main.dart:33-38` 只注册了**一个** `ChangeNotifierProvider`，没有 `Selector` / `Consumer` 粒度控制。流式输出时每个 `text-delta`（`index.js:879`）都会走一次 `notifyListeners`（`dsh_service.dart:1374-1413`）→ 整棵消费树重建，包括 4 个 tab、会话列表、审批卡。长回答 + 低端安卓机上必然掉帧。

**改法：**
1. 拆多个 Notifier（见 §3.3），至少把"流式文本"隔离出去
2. 流式文本用 `ValueNotifier<String>` 或 `StreamBuilder` 只包住当前那条消息气泡
3. 会话列表、审批角标用 `Selector<DshService, T>` 精确订阅
4. delta 做 16~33ms 节流合帧再 notify
5. 消息列表项加 `const` 构造 + `ValueKey(messageId)`

另外还有：`_sessionPollTimer` 每 **700ms** 轮询一次会话状态（`dsh_service.dart:619`），但网关本来就在推 `session_status`（`index.js:870/894/904`）——轮询是冗余的，白耗电量和流量。

### 3.5 连接建立慢：7 个请求串行

`dsh_service.dart:274-280`
```dart
await fetchWorkspaces(); await fetchSettings(); await fetchApprovals();
await fetchPermissions(); await fetchAuditLogs(); await fetchPersonas(); await measurePing();
```
串行走 nps 隧道，每个 RTT 几百毫秒 → 首屏 3~7 秒。改 `Future.wait([...])` 并行，`measurePing` 和 `fetchAuditLogs` 延后到首帧之后。

`testConnection`（`:180-206`）同样串行探 5 个端点、每个 4s 超时 → 最坏 20s 才告诉用户"连不上"。一个 `/api/mobile/health` 足够。而且 `:205 catch (_) {}` 把网络异常全吞了，用户只看到"失败"没有原因。

### 3.6 协议上有几条"发了没人听"的死消息

| 网关发出 | 位置 | 客户端是否处理 |
|---|---|---|
| `{type:'connected', version}` | `index.js:1738` | ❌ `dsh_service.dart:1258-1466` 的类型分支里没有 `connected` → **App 永远拿不到网关版本**，§1.8 的版本比对从客户端侧也断了 |
| `{type:'follow_ack'}` | `index.js:1777` | ❌ 无分支 |
| `{type:'approval_ack', ok}` | `index.js:1783` | ❌ 无分支 → §1.3 的"审批到底成没成功"客户端本来有机会知道，但没接 |

客户端的消息类型判断（`dsh_service.dart:1374`）还有个宽松兜底：`if (type == 'thinking' || type == 'delta' || type == 'token' || json.containsKey('delta') || json.containsKey('thinking'))` —— 任何带 `delta` 字段的未知帧都会被当成正文塞进气泡。建议改成显式白名单 + 未识别帧进 rawLog。

### 3.7 其它可优化点（零散但明确）

| 问题 | 证据 | 改法 |
|---|---|---|
| 审计日志只在内存，200 条封顶，重启即丢 | `store.mjs:128-129` `AUDIT_BUFFER_SIZE = 200` | 落 JSONL + 按大小轮转；App 的"安全中心"才有历史可查 |
| DSH 设置页的审计列表是空桩 | `rpc.mjs:107-108` `case 'audit/list': return [];` | 接 `readAudit()` |
| 状态恒报 running（同 §1.3 那类"谎报"） | `rpc.mjs:53` `status: deps.isListening ? 'running' : 'running'` | 真的去探端口 |
| `token/generate` 只返回不落盘，用户以为改好了 | `rpc.mjs:82-85` | 生成即 `saveConfig({token})`，或明确返回 `persisted:false` |
| RPC 把明文 token 回给设置页 | `rpc.mjs:56` `token: cfg.token` | 返回掩码 + 单独的"显示/复制"动作 |
| APK 回退路径写死陈旧版本 | `index.js:1187-1188`（`dsh-agent-v1.2.6.apk`、`dsh-agent-v1.2.0.apk`） | 删掉，只留 `public/dsh-agent.apk`，缺了就 404 |
| `public/` 堆 7 个历史 APK（~160MB），仓库根 5 个（~112MB） | 实测磁盘列举 | 只留 latest；历史版本走 GitHub Release（`build-apk.yml:56-88` 已经在建 Release 了） |
| 死文件：嵌套的 workflow，GitHub 根本不读 | `dsh_mobile/.github/workflows/build-apk.yml`（已被 git 跟踪） | 删 |
| CI 不跑 `flutter test`，3 个 dart 测试从不执行 | `bridge-tests.yml:66-69` 只有 analyze | 加一步 `flutter test` |
| CI 注释与 flag 自相矛盾 | `bridge-tests.yml:68` 注释「Treat analyzer infos as failures」，`:69` 实际 `--no-fatal-infos --no-fatal-warnings` | 二者取一 |
| `url.parse` 已弃用 | `index.js:1126` | `new URL(req.url, 'http://localhost')` |
| 上游 MUX 重连固定 3s、无退避 | `index.js:822` | 指数退避 + 上限 |
| 解析异常全静默 | `index.js:812`、`:1786`、`:497`、`:557` 都是 `catch (_) {}` | 至少 `logger.debug` + 计数，暴露到 `/health` |
| 测试两套体系并存，且被强制单并发 | `tests/m*_stress*.js` vs `tests/e2e/tier*/`；`package.json:9-17` 全部 `--test-concurrency=1` | 统一到 tier 体系；共享端口/DSH_HOME 改成每 worker 独立，恢复并发 |
| Flutter 侧只有 3 个测试文件 | `dsh_mobile/test/` 共 211 行 | 至少给 `dsh_service` 的消息解析和重连状态机补单测（纯逻辑，无需真机） |

---

## 4. 可新增功能

### 4.1 第一档：引擎已经有、网关接一下就能用（性价比最高）

按「价值 ÷ 工作量」排序：

| # | 功能 | 依赖的引擎事件/RPC（已实测存在） | 客户端要做什么 | 价值 |
|---|---|---|---|---|
| **1** | **回答 Agent 的提问** | `user-questions/request` | 选项卡片（单选/多选 + 自由输入），复用 `approval_card.dart` 的交互骨架 | 🔥 修掉 §1.5 的永久卡死 |
| **2** | **任务进度条（TODO）** | `todo/write` | 会话顶部一条可展开的清单，`pending/in_progress/completed` 三态 | 🔥 长任务时"Agent 到底在干嘛"一目了然 |
| **3** | **图片渲染** | `image/png\|jpeg\|gif\|webp`、`image/offload` | `safe_markdown.dart` 旁边加 `ImageCard`，支持点击放大 | 🔥 截图/图表/生成的图现在全是空白 |
| **4** | **拍照/截图/文件发给 Agent** | `session/attachment` + `dsh-client-file-upload` | 输入栏加 📎，`image_picker` + `file_picker`；网关加 multipart 转存 | 🔥 移动端独有杀手场景：拍报错截图、拍白板 |
| **5** | **会话搜索** | `session/search` | 会话列表顶部搜索框（现在 `workspaces_view.dart:19-20` 的搜索只在本地过滤已加载的会话） | 高 |
| **6** | **交付物下载/预览** | `dsh-tool-present` / `dsh-client-ui-deliverables` | "文件"tab 列出 Agent 产出的 docx/xlsx/pptx/pdf，点击用系统 App 打开 | 高 |
| **7** | **上下文压缩提示** | `compaction/start\|end\|summary` | 聊天流里插一条分隔卡"已压缩上下文 · 摘要…" | 中高（解释"为什么它突然忘了"） |
| **8** | **代码变更审阅（diff）** | `dsh-workspace-changes` + `workspace-file/*` | 文件树 + 只读预览 + 统一 diff 视图 | 高（手机上 review Agent 改了什么） |
| **9** | **子代理/团队可视化** | `subagent/catalog`、`subagent/descriptor` | 折叠树，显示每个子代理的状态与产出 | 中 |
| **10** | **会话重命名 / 从某条消息分叉** | `session/rename`、`session/title`、`session/fork` | 长按会话 → 重命名；长按消息 → "从这里重开" | 中 |
| **11** | **指令排队 & 中途插话** | `session/updateQueue`、`session/steer` | 输入栏在 Agent 运行时不禁用，改成"排队发送"/"插话" | 中高 |
| **12** | **只读实时终端** | `terminal/view`、`command/run\|done` | 第 5 个 tab 或会话内抽屉，等宽字体 + ANSI 着色 | 中 |
| **13** | **后台作业管理** | `dsh-api-job-controller`（`job/not-found` 等） | job 列表 / 输出 / kill | 中 |
| **14** | **用量看板（token & 成本）** | `dsh-token-meter`、`dsh-session-stats` | 设置页一个卡片：今日/本周 token、估算费用、最烧的会话 | 中 |
| **15** | **消息反馈（点赞/点踩）** | `feedback/message-put\|delete`、`feedback/record` | 气泡长按菜单 | 低中 |
| **16** | **计划模式审批** | `dsh-plan-mode` | plan 卡 + 批准/继续规划 | 中 |
| **17** | **定时任务 / Goal 轮次** | `schedule/change`、`goal/change`、`goal/activation-changed` | 手机上建定时任务、看 goal 跑到第几轮 | 中 |
| **18** | **技能 & 斜杠命令面板** | `dsh-skill`、`commands/change` | 输入 `/` 弹命令面板 | 中 |
| **19** | **会话导出分享** | `dsh-session-log-export` | 导出 markdown → 系统分享 | 低中 |

> 建议先做 **1 + 2 + 3**：三个都是"网关加一个 case 分支 + 客户端加一张卡"的量级，但把"手机端只能看文字流"直接升级成"手机端能完整参与 Agent 工作"。

### 4.2 第二档：移动端专属（引擎不管，纯客户端 + 网关小改）

| # | 功能 | 说明 | 关键点 |
|---|---|---|---|
| **1** | **推送通知** 🔥 | Agent 需要审批 / 提问 / 任务完成时主动推到手机 | 现在 App 必须前台开着 WS 才知道有事（`dsh_service.dart:1655-1666` 只在 resume 时补重连）。**这是"手机远程控 Agent"最缺的一环。** 最省事的实现：网关在 `approval_request`（`index.js:1007`）、`turn/end`（`:900`）、`user-questions` 时 POST 到 ntfy topic，手机装 ntfy 客户端或 App 内订阅；要做得好就接 FCM。注意 `AndroidManifest.xml:5-8` 目前只声明了 `INTERNET`/`ACCESS_NETWORK_STATE`/`VIBRATE`，**没有 `POST_NOTIFICATIONS`**（Android 13+ 必需），也没有前台服务/唤醒锁 |
| **2** | **深色模式** | `main.dart:85-96` 的 `darkTheme` 里 `brightness: Brightness.light`（写错了），`:97` 又 `themeMode: ThemeMode.light` 硬锁 → **现在完全没有深色模式**。而且全项目颜色是散落的 `Color(0xFF...)` 字面量（`main.dart:19-25`、`chat_view.dart` 各处） | 先把颜色收敛成 `AppColors` 语义令牌，再补 dark 调色板。夜间看代码/长文这是刚需 |
| **3** | **生物识别 App 锁** | `local_auth`，配合 §2.3 的 secure storage | token 明文存盘的前提下，这是必要的补偿控制 |
| **4** | **语音输入** | 引擎侧已有 `dsh-experimental-speech-to-text` / `dsh-experimental-voice-input-bundle`；客户端按住说话 | 走路/开车时给 Agent 下指令，移动端独有 |
| **5** | **多网关（多台电脑）** | `storage_service.dart:6` 只有一个 key `dsh_server_config`，`ServerConfig` 单实例 | 改成配置列表 + 快速切换；`server_config.dart:75` 已经存了 `npsAddress` 但没用上 |
| **6** | **审批规则化** | 见 §1.3(b) | 「本会话始终允许 pwsh」「始终允许 read」→ 把点按次数从 N 降到 1 |
| **7** | **离线草稿 & 断网重发** | 断网时输入不丢，连上自动发；配合 §3.5 的重连 | 地铁/电梯场景 |
| **8** | **Android 桌面小组件 + 通知角标** | 未读审批数角标、一键发常用 prompt | 免解锁直达 |
| **9** | **会话内查找 & 跳转** | 长会话里搜关键字、跳到某个工具调用 | 现在只有 `_jumpToBottom`（`chat_view.dart:126`） |
| **10** | **i18n** | 全项目中文硬编码（`approval_card.dart:346`、`security_permissions_view.dart:399-414` 等） | 抽 `AppStrings` + `flutter_localizations` |
| **11** | **平板/横屏适配** | `main_shell.dart` 4 tab 底部导航 | 宽屏改 `NavigationRail` + 双栏（会话列表 | 聊天） |
| **12** | **未识别帧 Raw 卡 + rawLog** | §1.5 的兜底 | 协议漂移可见，也是排查利器 |
| **13** | **网关健康仪表盘** | `/health`（`index.js:1170-1179`）目前只回 5 个字段 | 加上：上游 MUX 是否连通、connectedClients 数、审计计数、丢弃的未知事件数、每会话 follower 数、内存 |

### 4.3 第三档：中长期

- **端到端加密通道**：现在依赖 nps 明文隧道（`store.mjs:52` 默认 `useHttps: false`），token 一旦泄漏等于宿主机 shell 权限。可以做 WireGuard/Tailscale 直连，或网关内置自签证书 + 客户端证书固定（pinning）
- **多用户/多角色**：`core.mjs:731` 的 device 模型已经预留了 `role` 字段，`store.mjs:115` 的 `roleCanWrite` 也在——把"只读观察者"设备做出来，家人/同事可以看进度但不能批准危险操作
- **网关自动注册为 DSH 插件 + 设置页完整化**：`client/client.js` 308 行已经是注入 DSH Web 的设置面板，但目前只能改 token/port/nps；把设备列表、审计日志、会话白名单、限流配置都做进去
- **APK 自更新**：App 内检查 `/api/mobile/health` 的版本 → 拉 `/dsh-agent.apk` → 调 `PackageInstaller` 静默升级（前提是 §1.1 的签名先固定下来，否则装了也升不了）
- **iOS**：Flutter 侧代码基本可复用，但 iOS 后台 WebSocket 会被系统杀，推送必须走 APNs，工作量主要在这里

---

## 5. 建议的落地顺序

> 三路深挖后重排：**第 0 批是安全应急，今天就要做**；原第 1 批的"装机体验"降到第 2 批。

**第 0 批（安全应急，今天，约 1 小时）🔴**
1. **轮换引擎 HMAC 密钥** —— 泄露值当前仍然有效（§1.17，已实测）。这一步就让 git 历史里的密钥作废，是唯一"改一处即断整条攻击链"的动作
2. **换掉只有 8 字符的网关令牌**（§1.17）；顺手修 `saveConfig` 拒绝短 token + `loadConfig` 的 `|| generateToken()` 分支落盘（§1.24，同时是已锁死机器的自愈路径）
3. **作废泄露的 GitHub PAT** + `git remote set-url` 去凭据 + 改 `await-apk.mjs:22-32` 只读 `process.env.GITHUB_TOKEN`（§1.6）
4. **删掉磁盘上的 `index.js.legacy`**（75 KB，未跟踪，删了不影响 git）（§1.17）
5. **`auto-read` 分类器堵四个洞**：判定输入不再用 `reason`、`READ_ONLY_PREFIXES` 移除 `find`/`echo`、给 `cat/head/tail/read_file` 加 `~/.dsh/**` 黑名单、策略合成从 OR 改为"会话优先"（§1.18）—— 第 4 条同时修好"会话级 ask 是假开关"和"待审批角标永远不亮"（§1.22b）
6. **`assertSessionId()` 白名单** + 路径消毒器改 fail-closed（§1.19、§1.20）—— 两处各约 10 行，堵住任意删文件与任意读写
7. **`lib/index.js:1319-1327` 移进 try**（§1.21）—— 一行位置调整，消除唯一的远程崩溃路径
8. **`git rm --cached .agents/hooks.json`**（已核实确实在索引里，`.gitignore:33` 的"Never commit"规则已被突破）+ `.gitignore` 补 `apk-artifact.zip`（§1.15、§1.14a）
9. **删掉工作区里那三个测试垃圾文件**，并把这三个用例的写入目标改成临时目录 —— 注意它们在 `E:\workspace\个人\`，**在仓库之外，gitignore 管不到**（§1.14a）

**第 1 批（测试止血，半天）—— 不做这批，后面每一批都可能被测试污染掩盖**
10. **`package.json` 拆 `test:fast` / `test:contract` / `test:destructive`**，把会改真实策略的那批移出默认 `npm test`（§1.14b、§6.10）
11. **抽 `withRestoredPermissions(fn)` helper**，禁止 `|| 'auto-read'` 兜底；bench/stress 一律用临时 `DSH_HOME`（§1.14b）
12. **修会话回收链**：`--import` 接上 `cleanup-hook.mjs` + 改成 `test.after`/`beforeExit` + 删掉 `client.js:72` 的 `session-` 前缀过滤 + `STATE_FILE` 加 run-id（§1.14c）
13. **真实 LLM prompt 的用例加 `SKIP_LIVE_LLM=1` 开关**，默认走 mock upstream（§1.14d）
14. **删掉 `smoke-bridge.test.mjs:102` 的 `/^1\.2\.\d+$/`**（§6.10）—— 否则第 3 批的版本对齐会直接让 CI 红

**第 2 批（装机体验 & 发布链路，1~2 天）**
15. **提交完整 `android/` 工程 + 正式签名**，删掉 CI 的 `flutter create .` 与两处 cp hack（§1.1、§6.10）；`applicationId` 脱离 `com.example.*`（**上架后不可改，现在必须定**）；加 `--split-per-abi`（体积降 2-3 倍）
16. **Manifest 三条**：`allowBackup="false"` + `dataExtractionRules`、`networkSecurityConfig` 收敛 cleartext、`POST_NOTIFICATIONS`（§6.10，第三条是第 4 批推送的前置）
17. **APK 下载链路**：删掉两个写死的过期回退，改 `apk-manifest.json` 或 302 到 Release asset；`public/index.html:539` 的版本从 manifest 渲染（§1.16）
18. **修 `verifyToken` 认设备 token**，或直接删掉整条配对链路（Dart 端 `grep __mobile` 零命中）（§1.23）；先删掉 `lib/index.js:1312` 那行注定失败的 `touchDevice`
19. **审批改成"RPC 成功才出队"**，失败回滚入队并如实报错；未命中时返回真实状态码（§1.22a、§1.22c）
20. **cookie 24h 过期自动刷新**（§1.26）—— 修掉"用一整天后手机突然全不响应"
21. **`getSettingsData()` 移出循环** + 投影缓存加 mtime 缓存 + `readdirSync` 取代 3 连 `existsSync`（§1.7、§6.1）

**第 3 批（协议补全 & 版本对齐，2~4 天）**
22. **未识别帧兜底广播 + Raw 卡**（§1.5 第 1 步）
23. **接通 `user-questions/request`**（§4.1-1）—— 现在 `ask_user_question` 会让会话**永久卡死且无任何 UI 信号**；`approval_request.dart:13,61` 已解析的 `options` 字段正好是现成落点（§1.13-5）
24. **接通 `todo/write`**（§4.1-2）
25. **`tool_start/tool_result` 带 callId**（§1.4 + §6.9 客户端同一个 bug）
26. **修 `follow` 竞态**：`await _channel!.ready` + `_sendWsJson` 改待发队列 + `follow_ack` 超时重发（§1.10）—— **这是 700ms 轮询、O(n²) 重建、流量爆炸三件事的共同源头**
27. **半开连接检测**：`lastPongAt` + 2 个周期无 pong 就主动 close；统一三种探活写法（§1.11）
28. **去掉轮询 `maxTicks=350` 硬上限**，改自适应退避 + 到限显式提示（§1.9）
29. **版本号单一来源**（§1.8、§6.10 的 13 处）
30. **客户端补 `connected`/`approval_ack`/`follow_ack` 分支** + `_handleRawMessage` 加 default 日志（§3.6、§6.9）

**第 4 批（移动端体验，1 周）**
31. **推送通知 + deep link 直达审批**（§4.2-1、§6.10 Manifest 第三条）
32. **深色模式**（§4.2-2）—— 前置是先把 **481 处 `Color(0x…)`** 收敛成语义 token（§6.9）
33. **草稿恢复 + 重发按钮 + 消息本地缓存**（§6.7）—— 地铁/电梯场景从"完全不可用"变可用
34. **图片渲染 + 附件上传**（§4.1-3、4）
35. **biometric app lock + `flutter_secure_storage`** 取代明文 SharedPreferences（§6.10）
36. **错误分类映射**（timeout/DNS/证书/401/5xx → 人话 + 可操作建议），不再 `e.toString()` 直出（§6.9）
37. **清理 14+ 处安慰剂功能**：Persona 要么接 UI 要么删（现在每次连接白发一次请求）、reasoning budget / temperature / NPS 地址三个假 slider 要么真接通要么摘掉（§1.13）
38. **修 `ConfigPage` 的 `dispose()`** + `approval_card.dart:56` 的 controller + 让 3 秒定时器在非工作区 tab 时停（§1.12）

**第 5 批（性能 & 架构，穿插进行）**
39. **Markdown 渲染**：气泡抽独立 Widget 类 + `ValueKey` + `RepaintBoundary` + styleSheet 缓存 + 流式期间只重解析最后一条（§6.6）—— **单点收益最大**
40. **消息分页**：`sessions/:id` 加 `since`/`limit`，轮询改增量；`_reconcileSessionMessages` 加 diff 判空（§6.7）
41. **三处虚拟化修复**：`shrinkWrap`+`NeverScrollable` 换掉、安全页改 `ListView.builder`、审计日志加分页（§6.8）
42. **广播按订阅过滤 + 背压 + seq + 合帧 + `maxPayload`**（§3.2、§6.2）—— 预计带宽/CPU 降 40~60%，并修好跨设备内容泄露
43. **状态无界增长**：follower GC + `unsubscribe_session` + 审批 TTL + `coreTurns.clear()`（§6.3）
44. **O(n²) 字符串**：`textBuffer` 改数组惰性 join、请求体改 `Buffer.concat`、`coerceToolInput` 去 pretty-print（§6.4）
45. **拆三个巨型文件** + 状态拆分 + `Selector` 精确订阅（§3.3、§6.9）
46. **用引擎 RPC 取代刮内部文件**（§3.1）—— 上游会话格式已从 v3 迁到 v4，这条不做迟早被断
47. **删掉 core 的 12 处重复实现**（净删约 250 行，消除"改了 core 不生效"陷阱）（§6.5）
48. **CI 门禁补齐**：`flutter test`、`analyze --fatal-infos`、`dart format`、gitleaks、版本一致性、APK 完整性断言、concurrency、gradle 缓存（§6.11 的 1~10）
49. **删掉约 1200 行"grep Dart 源码"假测试**，等价断言迁到真 Dart 测试；两套测试体系合并（§6.10、§6.11）
50. **`public/index.html` 二选一**：复活（加 `GET /` + 白名单静态服务 + APK 断点续传）或删除（发布物 150MB → 22MB）（§1.27）
51. **`git filter-repo` 清洗历史**（仓库私有、只有 25 个 commit、`.git` 仅 1.0 MB —— 直接 squash 重开历史成本最低）（§1.17）

---

## 6. 三路深挖补充（子代理 A 网关 / B 客户端 / C 测试发布）

### 6.1 网关性能：`GET /api/mobile/workspaces` 的真实复杂度

设 W=工作区数、S=会话总数、A=待审批数、Y=单次 YAML 解析成本。`lib/index.js:438-540`：

| 步骤 | 行 | 复杂度 |
|---|---|---|
| 读 `workspace.json` + `new Set(archivedSessionIds)` | `445-447` | O(1) + O(归档数)，而归档数可被 §1.19 无限撑大 |
| **每个会话** 3 次 `existsSync` + `readFileSync` + `JSON.parse` **整个投影缓存文件**（只为取 5 个字段 `486-489`） | `461-480` | **O(S) 次全文件读+解析**，单次可达数百 KB |
| **循环内调 `getSettingsData()`** → 每次 `existsSync+readFileSync+YAML.parse(cordis.patch.yml)`（`271-306`）**再** `existsSync+readFileSync+YAML.parse(settings.yaml)`（`309-336`） | **`507`** | **O(S × Y) —— 整个网关最大的单点性能坑** |
| **循环内 `coreApprovals.list().filter(...)`**，而 `list()` 每次 `[...new Set(map.values())]` 新建 Set+数组 | `509-512` | O(S × A) 且每次分配 —— 而过滤条件**恒为假**（§1.22b），全部计算产出恒为 0 |
| 每会话 `getSessionFollower` 最多 3 次 Map 查找 + 3 次 `activePrompts.has` | `490-491` | O(S) |

全部是**同步**调用 → 阻塞事件循环。你的 DSH home 曾累积 1270 个会话（`core.mjs:796` 也提到"the E2E suite accumulated >1000 empty sessions"）→ 这个接口可以卡住事件循环数秒。

**更糟的是它被三处触发**：手机每次进工作区页、`workspaces_view.dart:33-42` 那个永不停歇的 3 秒定时器（§1.12）、以及路径消毒器 `lib/index.js:154` → **每次 `GET|POST /api/mobile/memory` 都会连带跑一次完整的 O(S×Y) 扫描**。

**改法：**
1. `getSettingsData()` 提到循环外算一次，并加基于文件 mtime 的缓存
2. 审批计数改循环外一次 `Map<sessionKey,count>` 预聚合（先修 §1.22b，否则直接删掉这段死计算）
3. 投影缓存只提取所需 5 字段后放进 `Map<sessionId,{mtime,meta}>`，`statSync` 的 mtime 未变则复用
4. 循环内 3 连 `existsSync` 改为一次 `readdirSync(projCacheDir)` 建 Set 后查表
5. **根治**：别刮内部存储了，改用引擎已有的 `session/list` / `session/page` RPC（§3 已述，会话格式上游已从 v3 迁到 v4）

### 6.2 网关：广播无过滤、无背压、无序号

```
lib/index.js:747-754  broadcastToMobileClients(msg) {
  for (const ws of connectedClients) if (ws.readyState===OPEN) { try { ws.send(raw) } catch(_){} }
}
```
1. **完全忽略背压**：不看 `send()` 返回值、不看 `ws.bufferedAmount`、无队列上限、无丢帧策略。高速 token 流（`876/879` 每 delta 一次广播）+ 蜂窝网慢客户端 → 发送缓冲在进程内**无界堆积**。唯一兜底是 30s ping/pong 扫尸（`1707-1725`），但 `ws.isAlive` 会被**任何**入站消息重置（`1747`）→ 一个只发不收的客户端永远不会被判死。
2. **全局无差别扇出**：广播不区分 `ws.sessionId`（`1766` 写入后**从无读取方**）→ N 台设备 × M 个被 follow 的会话 = 每台设备收到全部 M 路 token 流。**两台手机分别看两个会话时，彼此都会收到对方会话的完整明文内容** —— 这既是性能问题也是信息隔离缺失。
3. **载荷字段翻倍**：`876 {type:'thinking', delta:c.text, text:c.text}`、`879 {type:'delta', delta:c.text, text:c.text}` —— 同一字符串在 JSON 里出现两次，落在**最热路径**上。
4. **无 seq/turn/offset** → 客户端无法察觉缺口（这也是 §1.10 那个 follow 丢失无法被发现的原因）。
5. **无压缩**：`perMessageDeflate` 用 ws 默认 `false`，HTTP 侧也无 gzip —— 而 `thinking`/`delta` 是高度可压缩的自然语言。
6. **WS 无 `maxPayload`**（`1682`，取默认 **100MB**）vs HTTP 侧 2MB → 防护不对称。

**改法：** `broadcastToMobileClients(msg, filterSessionId)` 只发给订阅者；`bufferedAmount > 4MB` 时丢弃可重建帧并标记 `ws.lagging`，恢复时发一次 `resync`；所有流式帧加每会话单调 `seq`；加 16~33ms 合帧窗口合并同会话 delta；去掉重复字段（保留 `text`，`delta` 作过渡别名一个版本后删）；`maxPayload: 256*1024`；开 `perMessageDeflate`。**预计带宽与 CPU 下降 40~60%。**

### 6.3 网关：三处无界状态增长 + buffer 滞留

| 资源 | 创建 | 清理 | 结论 |
|---|---|---|---|
| `sessionFollowers` | `core.mjs:540-541` / `lib/index.js:855-856`（**双键写入**） | 仅 `1842 clear()`（进程退出） | ❌ **无运行期驱逐** |
| `pendingApprovals` | `1005 / 1044` | `942 / 1083 / 1527` + `1843 clear()` | ❌ **无 TTL、无上限**（对比 auditBuffer 有 200 上限） |
| `sessionTurnSeqs`/`cancelledTurnSeqs`/`lastCancelTimes` | `1387 / 1469` | **`1841-1843` 未包含** | ❌ 泄漏；`core.mjs:500-505 coreTurns.clear()` 从未被调用 |
| `follower.lastUpdated` | 写于 `853/858/1397`、`core.mjs:538` | — | **从无读取方** → 空闲驱逐从未实现 |
| `core.mjs:555 all()` | — | — | 死代码 |

**放大因素：** Dart 端每次切会话都发 follow（`dsh_service.dart:368,512,552,1639`），而 **`GET /api/mobile/sessions/:id` 这个只读接口本身就开上游流**（`lib/index.js:565 followSession`）。且**没有 `unsubscribe` 消息类型**（`1746-1787`）。→ 长跑进程的 `sessionFollowers` 会累积「历史上看过的每一个会话 × 2 个键」，每项还挂着 `textBuffer/thinkingBuffer/tools`。

**buffer 滞留：** `textBuffer/thinkingBuffer` 只在 `turn/start`（`866-869`）与 `turn/end`（`901-903`）被清。上游 mux 在 turn 中途断开时（`815-825`）`turn/end` 永不到达 → 该会话完整回答文本永久驻留，且 `isRunning` 卡在 `true`（`818-820` 只重置 `subscribed`）→ **手机端一直转圈**。

**改法：** 在 30s 心跳回调里加 follower GC（`!isRunning && 无 ws 订阅 && Date.now()-lastUpdated > 10min` → 发上游 close 帧 + 删双键）；新增 `{type:'unsubscribe_session'}`，`ws.sessionId` 改成 `ws.subscriptions:Set` 引用计数；`pendingApprovals` 加 TTL(30min)+上限(200)，过期时 `audit('approval/expired')` 并广播 `approval_settled{outcome:'expired'}`；`cleanupGateway` 补 `coreTurns.clear()`；`getSessionHistory` 不再隐式 follow。

### 6.4 网关：O(n²) 字符串热点

| 位置 | 问题 |
|---|---|
| `lib/index.js:878` `follower.textBuffer += c.text` | **每 token 一次全串复制**。回答 10 万字符时是 ~5×10⁹ 字节拷贝量级 |
| `lib/index.js:658,661` | 历史拼装反复 `+=` |
| `core.mjs:774` `raw += chunk`、`lib/index.js:1255` `body += chunk` | 2MB body 解析 O(n²) |
| `core.mjs:186` `JSON.stringify(input,null,2)` | pretty-print 用在**每条**工具调用广播与审计（`909,961`），体积比紧凑格式大 30~50% |
| `core.mjs:319-320` `JSON.stringify(norm)` 存进审计 `reason` | 含大 `input` 的 payload 二次全量序列化并驻留 ×200 条 |

**改法：** `textBuffer` 改 `string[]` + 惰性 join（读时缓存）；请求体改 `chunks.push(chunk)` + `Buffer.concat`；历史拼装改数组 push 后一次 `join('')`；`coerceToolInput` 去掉 `null,2`，超 4KB 截断加 `…(truncated, N bytes)`。

### 6.5 网关：其他确认项

- **键归一化三套并存**：`coreTurns` 用 `normalizeSessionKey`（剥前缀、**保留大小写**，`core.mjs:411-414`）；审批匹配用 `sessionIdMatches`（剥前缀 + **转小写**，`core.mjs:430-433`）；follower 查找用手写三键或运算（`core.mjs:552`）；`lib/index.js:491` 与 `567` 又各自手写一遍。同一会话在四个 Map 里可能以 3 种键形态存在。
- **`activePrompts` 泄漏**：写入用客户端原始 `sessionId`（`1389`），删除用上游派生的 `sId`+`cleanId`（`898-899`）→ 客户端传 `Session-ABC` 而上游报 `session-abc` 时 delete 全 miss → **该会话在工作区列表里永远显示 isRunning**（`491-495`）。
- **350ms 取消窗口会静默吞掉新 prompt**：`lib/index.js:1382-1383` 距上次 cancel <350ms 就直接回 `200 {cancelled:true}` → 客户端无从区分"我这条被吞了"与"上一条被取消了"。`1415` 的 `<500` 同理。而 `1406` 已经生成了 `crypto.randomUUID()` 作 `requestId` **却没用于幂等去重** —— 正确做法就在这行代码旁边。
- **上游 mux 固定 3s 重连、无退避无抖动无上限**（`822`）；**无重放/补帧协议** → 断线期间的 delta/tool 事件永久丢失，而广播帧不带 seq（§6.2）→ 客户端无法察觉缺口。`getSessionHistory` 的兜底是"取更长的 buffer"（`724`）→ 重连后可能文本重复拼接或被截断。
- **`currentEventsClientId` 单值全局**（`214,932,995,1093`）：重连窗口内（`817` 置 null）到达的自动放行会带 `clientId:null`（`983`）。
- **无 TLS**：`lib/index.js:1125 createServer` 纯 http。`store.mjs:52 useHttps` 字段只被 `rpc.mjs:51,71` 用来拼 NPS URL 的 scheme，**从不影响本地监听**。
- **CORS `*` 对每一个响应**（`1129-1131`，含 401 与 APK 二进制）；**无 Host 头校验**（DNS rebinding 面）；**WS 升级无 Origin 校验**（`1684-1704`，唯一设 Origin 的地方是**出站**到引擎的 `778`）→ 一旦 token 泄露，任意网页可建 CSWSH 连接并接收**全部**会话 token 流（因为广播是全局的）。
- **每请求 3~4 次同步磁盘 IO**：`verifyToken` → `loadConfig`（`store.mjs:55-81`，每次读盘且 `62` 带写盘副作用）→ `ensureDataDir`；再加上 §1.23 那个注定失败的 `touchDevice` 又是 2 次 syscall + 1 次 parse。全仓 `grep timingSafeEqual` **零命中**（非常量时间比对）。
- **`lib/index.js:99-105`** 的正则 `/^\s*secret\s*:\s*['"]?([^'"\s#]+)/mi` 会命中 `settings.yaml` 中**任意**名为 `secret` 的键（如某个 MCP server 的凭据）→ 拿错密钥后所有 RPC 静默 `unauthorized`。解析不到时 `114-121` 会把生成的密钥**明文写盘** `~/.dsh/mobile-bridge/internal-secret`，`chmod 0o600` 在 Windows 上是 no-op（`121` 注释自认）。
- **`index.js:57` 的 `effect` 桩是 no-op**：`lib/index.js:1850` 传的是 `() => () => { cleanupGateway() }`（一个**返回**清理函数的函数），`index.js:38 fn()` 只构造了内层箭头函数从不执行。且 `index.js:40` 只等 200ms 就 `process.exit`，而 `lib/index.js:1833-1839` 的优雅关闭最多等 1000ms → **SIGINT/SIGTERM 下 `server.close` 必然被打断**，`disposeRpc()`（1840）与 `audit('gateway/stop')`（1844）不会执行。
- **`isDisposed` 只在 3 处被检查**（`760/816/1815`），HTTP 与 WS 处理器都不检查 → 卸载后仍在飞的 `await callDshRpc` 会对已关闭的 `res`/`ws` 调 `sendJson`/`send`。
- **`configurePersistence`（`core.mjs:31-36`）与 `configurePermissionsPersistence`（`639-651`）是模块级可变全局** → 同进程二次 `apply()`（Cordis 热重载）会让后者覆盖前者；`createPermissionStore()` 若在注入前构造会拿到 `() => ({})` 兜底 → **权限全部回落默认值**。当前调用顺序恰好正确，但这是**靠调用顺序维持的隐式契约，无任何断言保护**。
- **无 `fs.watch`（grep 零命中）** → 引擎侧改了 `workspace.json` 或投影缓存，网关不会主动通知，手机必须重新拉一次 O(S×Y)。`session_status` 只对**已 follow** 的会话广播（`870`），未打开的会话在列表里的 `isRunning` 只能靠 `Date.now()-lastPromptAt < 45000` 这种时间窗**猜测**（`493-495`），会自然过期失真。
- **重复实现约 12 处，core 侧对应实现沦为死代码**（`extractToken` / `readBodyWithLimit` / `ensure` / `permStore.apply` / `nextId` / `isAnyPromptActive` / `sessionIdMatches` / `markAllUnsubscribed` / `loadYaml` / `dshHome` ×2 / `AUDIT_BUFFER_SIZE` ×2 / `getTurnSeq`+`setTurnSeq`）→ **改了 core 不生效**。逐项替换可净删约 250 行，`lib/index.js` 从 1858 降到 ~1400。

### 6.6 客户端：Markdown 每帧全量重解析，代价 O(n²)

链路：`notifyListeners()` → `chat_view.dart:1063` 整个 build → `1544 _buildMessageItem(msg)` → `1750 SafeMarkdown(...)` → `safe_markdown.dart:37 sanitizeMarkdown` → `41 MarkdownBody`。每次重建：
1. `sanitizeMarkdown` 跑 **2 个 RegExp 全文扫描**：`RegExp(r'```').allMatches(text)`（`safe_markdown.dart:9`，**枚举所有匹配只为数奇偶**）+ `replaceAll(RegExp(r'<(?![a-zA-Z/!])'), '&lt;')`（`:16`，**全文替换生成新字符串**）
2. `MarkdownStyleSheet` **每次现场构造**（`chat_view.dart:1758-1770`，非 const、非缓存、无 `==`）→ `MarkdownBody` 无法短路
3. `MarkdownBody` 重新解析**整篇 markdown** 并重建全部富文本；`selectable: true`（`1752`）额外包一层可选中文本区域
4. **触发频率：流式时每个 WS token 一次**（`dsh_service.dart:1403/1408`）**+ 每 700ms 轮询一次**（`801`）。第 n 个 token 要重解析 n 长度的全文 → **总代价 O(n²)**，一条 5000 字回复 ≈ 1250 万次字符解析量级
5. **同一帧内所有历史消息都重建**（无 key、无 const、`_buildMessageItem` 是方法不是 Widget 类）→ **每 token 重解析整个会话的全部 markdown**

**这是本项目最大的性能瓶颈。** 改法：把消息气泡抽成独立 `Widget` 类（可利用 element 复用短路）+ 加 `ValueKey(msg.id)` + `RepaintBoundary`（grep 全 lib **零命中**）；`MarkdownStyleSheet` 提到 `didChangeDependencies` 缓存；流式期间只重解析**最后一条**（用 `ValueListenableBuilder` 局部订阅）；`sanitizeMarkdown` 的结果按内容 hash 缓存。

同类热点：**单条消息单次 build ≈ 17 次全文扫描 + 4 个 RegExp** —— `chat_view.dart:1648-1655` 跑 8 次 `indexOf`、`chat_message.dart:67-77 isContextOrMemory` 跑 8 次 contains + 1 RegExp、`memory_card.dart:43-45` 跑 3 个 RegExp + 6 次 contains/startsWith。`tool_call_card.dart:50` 与 `221` **每次 build 对全文 `split('\n')` 两次**（一次算行数、一次标题里再算）。

### 6.7 客户端：消息零分页、零本地缓存

- `selectSession` 一次性拉全量：`GET /api/mobile/sessions/{id}` **无任何 limit/offset/cursor**（`dsh_service.dart:371-372`），服务端 `lib/index.js:590 maxMessages: 100` 硬上限、每条重新 `crypto.randomUUID()` 造 id（`626,648,686`）、无 `ETag`/`Last-Modified`/`since`
- **轮询每 700ms 重新拉取并重新解析全量消息列表**（`641-664` → `_reconcileSessionMessages` `706-802`，其中 `709-726` 又一次全量 DTO 映射，`799` 整体替换 `_messages`）→ 200 条消息的会话 = 每 700ms 传输+解码+构造 200×(1+n) 个对象+全 UI 重建
- `_reconcileSessionMessages` 每次生成**全新 ChatMessage 实例**（`711`）+ 整体替换（`799`）→ 所有子 widget 的 `didUpdateWidget` 都判定"变了"，三张卡的自动滚动逻辑每 tick 全跑一遍
- **`799-801` 无 diff 判空**：即使服务端**无任何变化**也无条件 `_messages = serverMessages; _streamRevision++; notifyListeners()`
- **消息零本地缓存**（`storage_service.dart` 只有 20 行、只存 ServerConfig）→ 地铁/电梯场景**完全不可读历史**
- **草稿丢失**：`chat_view.dart:199` **先 `_inputController.clear()` 再 send**，失败时只插一条 `❌ 发送失败`（`dsh_service.dart:597`）→ 输入框已空、**无重发按钮、无草稿恢复**
- 无序号去重能力（`SessionMeta.lastSeq` 是死字段，§1.13-8）→ WS delta 直接 `content += text`（`1406`），**任何重传/重复帧都会文本重复拼接**；且无条件写 `_messages.last` 不校验消息 id（`1384-1395`），轮询在两个 delta 之间替换 `_messages`（`799`）时 **delta 会拼到另一条消息上**
- 轮询侧合并用**字符串长度启发式**：`local.content.length > server.content.length && local.content.startsWith(server.content)`（`743-753`）→ 服务端做过 trim/规范化则 `startsWith` 为 false → **已渲染的流式文本被旧快照覆盖回退，用户看到文字"倒退"**
- 用户消息去重按 **content 完全相等 + 45 秒窗口**（`785-797`）→ 重复发同一句话会**丢掉一条**

### 6.8 客户端：虚拟化失效的三处

| 位置 | 问题 |
|---|---|
| `workspaces_view.dart:638-647` | `ListView.builder(shrinkWrap:true, physics:NeverScrollableScrollPhysics)` 嵌在 `ExpansionTile` 里 → **虚拟化完全失效**，展开的工作区所有会话一次性全构建（每个 `_buildSessionItem` 170 行、含 2-3 个 `CircularProgressIndicator`） |
| `security_permissions_view.dart:77` | `body: ListView(...)` **非 builder** → 所有区块（审批卡+策略矩阵+全部审计日志）一次性构建 |
| `security_permissions_view.dart:310-319` | 审计日志 `ListView.separated(shrinkWrap:true, physics:NeverScrollable...)` **无上限全量渲染**，且 `fetchAuditLogs`（`dsh_service.dart:1122-1137`）**不带 limit/分页参数** |

另外：**全 lib 只有 1 处 `key:`**（`config_page.dart:117` 的 `_formKey`），grep `ValueKey|ObjectKey|UniqueKey` = **0 命中**。而 `_buildMessageItem` 会按消息内容返回**不同根 widget 类型**（`MemoryCard` 分支 `1629/1661/1670` vs `Row` 分支 `1679`）→ 某条消息的 `isContextOrMemory` 判定在轮询间翻转时，Flutter 销毁重建整棵子树，**卡片展开态、滚动位置、文本选择全部丢失**。`workspaces_view.dart:461-462` 的 `ExpansionTile(initiallyExpanded:isCurrent)` **无 key** → 3 秒轮询重建 + 顺序变化时**展开态会串到错误的工作区上**。

`workspaces_view.dart:366` 的嵌套深度达 **14 层**，`custom_settings_view.dart:148` **22 层**，`chat_view.dart:664` **20 层**。

### 6.9 客户端：无设计 token、无 i18n

- **481 处 `Color(0x…)` 字面量**，`0xFF0078D4` 重复 **112 次**、`0xFF6B7280` 38、`0xFFE5E7EB` 35、`0xFF1F2937` 23、`0xFFF9FAFB` 12 —— **没有任何主题 token 文件**。单文件密度：`chat_view.dart` 163、`workspaces_view.dart` 90、`custom_settings_view.dart` 59。主色在 `main.dart:57,60,90,93` 又作为 seedColor/primary 出现 —— 明明有 `Theme.of(context).colorScheme.primary`，业务代码却一律硬写字面量。**这是暗色模式（§4.2）的前置阻塞项。**
- **56 处 `withOpacity()`** 阻止 `BoxDecoration` const 化
- **零 i18n**：`pubspec.yaml:9-36` 无 `flutter_localizations`、`MaterialApp` 无 `localizationsDelegates`/`supportedLocales`、无 `l10n.yaml`、无 `.arb`；实测 **281 处含中文的单引号字面量**，其中 **`dsh_service.dart` 29 处** —— **服务层也在拼中文用户文案**（`:128,195,202,260,419,425,597,605,606,980,991`）→ 错误文案与业务逻辑耦合，无法本地化；Material 内建组件只能回落英文
- **重复实现**：BoxDecoration 卡片模板 4+ 次；BottomSheet "拖动条+图标标题" 头部 **6 次**（宽高还各不一样：40×4 / 40×4 / 40×4 / 36×4）；`_buildPolicyOption`(`chat_view.dart:397-451`) ≈ `_buildPolicyRadioTile`(`security_permissions_view.dart:339-393`) **53 行近似重复**；`_showModelSwitchSheet` **双份**（`chat_view.dart:478-703` 226 行 + `custom_settings_view.dart:19-172` 154 行）；`_formatTime` **三份**（格式还不一致：`HH:mm:ss` vs `HH:mm`）；`_buildSectionHeader` 两份；**JSON 美化逻辑写了 3 遍**（`dsh_service.dart:134-145`、`chat_message.dart:17-28`、`approval_card.dart:29-40`）；**上下文标记表 3 份且已漂移**（`chat_message.dart:67-77`、`chat_view.dart:1636-1645`、`memory_card.dart:43-92`）；**硬编码兜底模型列表 2 份**（`chat_view.dart:487-491` / `custom_settings_view.dart:24-28`）
- **`chat_view.dart:480` `dsh.fetchSettings()` 无 await，紧接着 `482` 读 `dsh.settings`** → 必然读到旧值 → **首次打开模型 sheet 一定走硬编码兜底列表**
- **无任何模型实现 `==`/`hashCode`** → 所有比较都是身份比较；`ChatMessage` 的 `content`/`thinking`/`tools`/`isStreaming` **全可变**（`chat_message.dart:34-37`）且被 service 大量 in-place 改写（12 处），`Workspace.sessions` 是可变 List 被 9 处直接改写 → UI 与服务共享同一份可变对象，`const`/`shouldRebuild` 优化全部无从下手
- **`build()` 内部有副作用**：`chat_view.dart:1080-1126` 改 5 个 State 字段并 `addPostFrameCallback` 调度滚动（build 必须是纯函数，这会在 hot-reload/父级重建时产生不可预测的滚动跳动）；`main.dart:105-107` 同类
- **61 处 `notifyListeners()`** + 5 个页面全部 `listen:true` + `IndexedStack` 常驻（`main_shell.dart:133-146`）→ **每次通知 = 重建 4 个页面 + 底栏 + 所有卡片**。grep `Selector<|Consumer<|context.watch` = **0 命中**，零刷新范围控制
- **5+ 个无限 `CircularProgressIndicator` 同时运行**（`chat_view.dart:1233,1791`、`workspaces_view.dart:420,505,694,743`、`tool_call_card.dart:130`、`thinking_card.dart:121`、`custom_settings_view.dart:372`）→ 即使所在 tab 不可见，IndexedStack 保持其 state 与动画，**持续重绘、持续耗电**
- **`DateFormat` 每次调用现场构造**（`chat_view.dart:209,211`、`workspaces_view.dart:68,70`、`security_permissions_view.dart:33,35`）
- **lint 实际未生效**：`pubspec.yaml:36` 声明了 `flutter_lints` 但**仓库无 `analysis_options.yaml`** → 从未启用。这解释了 `chat_view.dart:612-690` 整块比外层少 22 空格缩进、`:697-700` 闭合括号错位这类重构残留
- **弃用 API**：`MaterialStateProperty`（应 `WidgetStateProperty`，`main_shell.dart:160,161,170,171`）、`ColorScheme.fromSeed(background:)`（应 `surface`，`main.dart:61,94`）、`Radio(activeColor:)` + `groupValue/onChanged`（`chat_view.dart:424`、`security_permissions_view.dart:366`）
- **8 处 `catch (_) {}` 完全静默**（`dsh_service.dart:198,205,595,984,1038,1206,1504`、`approval_request.dart:46`），其中 **`:1038` 是 WS 审批下发失败被吞 → 用户以为已提交**；另有 **22 处 `catch(e){debugPrint}`** 只打日志不上报不设 `_lastError` 不通知用户（`fetchWorkspaces` 失败只 debugPrint → 用户看到空列表无提示）
- **`safe_markdown.dart:40-46` 的 try/catch 抓不到 MarkdownBody 的解析异常**（那发生在子树 build/layout 阶段）→ 防线基本无效；真正的兜底是 `main.dart:12-29` 的 `ErrorWidget.builder`，代价是**把 `details.exceptionAsString()` 以 monospace 明文渲染给用户**
- **原始 Dart 异常串直出用户**：`_lastError = e.toString()`（7 处）→ `SocketException: Failed host lookup (OS Error: ... errno = 7)`、`HandshakeException`、`FormatException` 原样呈现，且横幅 `maxLines:1` + ellipsis（`chat_view.dart:993-994`）→ **长异常被截断且不可展开、不可复制**。无错误分类（timeout/DNS/证书/401/403/5xx/离线 → 人话+可操作建议），无错误码/traceId
- **完全没有自签证书处理能力**：grep `HttpClient|badCertificateCallback|SecurityContext|onHttpClientCreate` = **0 命中** → 用户勾选"启用 HTTPS/WSS"（`config_page.dart:207-212`）后遇到自签证书直接 `HandshakeException: CERTIFICATE_VERIFY_FAILED`，**无"证书不受信任，是否导入/信任指纹"的可操作路径**。且无证书 pinning —— 公网暴露一个可 RCE 的网关却没有任何 MITM 防护
- **`retryConnection()`（`148-154`）重置了 `_isTokenInvalid` 和 `_reconnectAttempts`，却没重置 `_isExplicitlyDisconnected`** → 一旦 `disconnect()` 被调用过，手动重试**静默 no-op**
- **jitter 用 `DateTime.now().millisecondsSinceEpoch % 400` 而非 `math.Random`**（grep `math.Random` = 0）→ 抖动近似确定性，**多客户端会同步雪崩重连**；且退避被 `min(n,6)` 钉死在 ~11.4s，第 7 次后不再增长
- **`_handleRawMessage` 是 243 行的 14 个 `if (type==…) {…return;}` 串联，无 switch、无 default、无未知类型日志**（`1249-1491`）→ 网关新增事件类型时客户端静默丢弃，**排障无线索**
- **`dsh_service.dart:1374` 用"有没有这个 key"当事件类型**：`if (type=='thinking'||type=='delta'||type=='token'||json.containsKey('delta')||json.containsKey('thinking'))` → 任何带 `delta` 字段的无关帧都会被当流式 token 拼进消息
- **`dsh_service.dart:1453-1458` `tool_result` 无条件写 `tools.last`** → 并发多工具时结果串到错误的工具上（`callId` 字段存在于 `approval_request.dart:10`，但消息侧的 `ToolExecution` 根本没有 id）—— 与网关侧 `lib/index.js:913-921` 的同一个 bug 两端呼应
- **`'Connection': 'close'`（`dsh_service.dart:164`）主动禁用 keep-alive**，却又在 `555` 注释说要"容忍反代 Keep-Alive 断连"并重试（`558-575`）→ 自相矛盾且性能反向
- **5 个 Scaffold 嵌套**：`main_shell.dart:96`（外层，`resizeToAvoidBottomInset:false`）+ 4 个 tab 各自 Scaffold → 5 份背景色、4 个独立 AppBar、双层 SafeArea，键盘行为靠 `chat_view.dart:1080-1094` 手工补偿
- **`custom_settings_view.dart:361-363`**：`setState(()=>_isTestingPing=true)` 后 `await`，回来时**无 mounted 检查**直接 `setState` → 页面销毁后异常风险

### 6.10 Android / CI / 发布（补充 §1.16 与前述）

**android 工程未入库的连锁后果（`git ls-files dsh_mobile/android` 只有 `AndroidManifest.xml` 一个文件）：**
- 本地 clone 后 `flutter build apk` **直接失败**（`README.md:27-33` 的说明与仓库实际状态矛盾）
- **`minSdk`/`targetSdk`/`compileSdk`/`versionCode`/`versionName`/签名/R8 全部不在版本控制中**，由 CI 当时的 Flutter 3.24.x 模板决定 → **构建不可复现**，Flutter 升版会静默改 SDK 级别（模板默认 minSdk 21 / target 34）
- **任何 Android 侧定制都无法持久化**：想加 `minSdk 24`、开 R8、配 `networkSecurityConfig`、加 `dataExtractionRules`、加签名 —— 写了也会在下次 CI `flutter create .` 时被模板覆盖（CI 只备份了 manifest，`build-apk.yml:37-39`）
- 磁盘上 `AndroidManifest.xml:15` 引用的 `@mipmap/ic_launcher`、`:22,28` 引用的 `@style/LaunchTheme`/`@style/NormalTheme`、`:19` 引用的 `.MainActivity` —— **资源与类文件全部缺失**，本地构建必失败

**Manifest 三条安全缺口：**
- **无 `android:allowBackup="false"`、无 `fullBackupContent`、无 `dataExtractionRules`** → 结合 `storage_service.dart:10` 的明文 token（整个 `ServerConfig` 含 `token`/`authCode` 被 `jsonEncode` 后 `prefs.setString`，落在 `/data/data/com.example.dsh_mobile/shared_prefs/dsh_server_config.xml`）→ **token 会随 Android 自动备份上传到 Google 云，且 `adb backup` 可直接导出**。无 `flutter_secure_storage`、无 Android Keystore、无 `local_auth`
- **`usesCleartextTraffic="true"`（`:16`）全局放开明文，且无 `networkSecurityConfig`** → 任何域名/IP 都可被明文嗅探与 MITM，而这是一个能远程执行代码的网关。正确做法是用 `networkSecurityConfig` **只对用户自己的主机**放行 cleartext
- **无 deep link**（无 `<intent-filter android:autoVerify>` + `<data android:scheme>`）→ **无法从通知动作/浏览器/二维码直接跳到某个审批或会话**，这正好堵住 §4.2 推送通知的"点击直达"能力。另缺 `enableOnBackInvokedCallback`（Android 13+/14 预测性返回手势）

**Token 出现在 WS URL query**：`server_config.dart:66` `'$scheme://$cleanHost:$cleanPort/mobile-ws?token=$effectiveToken'` → 进 nginx/反代 access log、进中间代理缓存、进抓包工具历史。应改为首帧认证或子协议。（HTTP 侧则是三个 header 同时塞同一个 token：`dsh_service.dart:161-163` —— 说明客户端不知道网关认哪个，把猜测写死了；而网关 `core.mjs:716-723` 其实四个载体都认。）

**CI 缺口：**
| 缺口 | 证据 | 影响 |
|---|---|---|
| **不跑 `flutter test`** | 两个 workflow grep `flutter test` → **0 命中** | **3 个 Dart 测试文件 / 12 个 test / 244 行永不执行**。而它们才是唯一真正验证 Flutter 行为的测试。与此同时 CI 却在跑 grep Dart 源码文本的 JS 假测试 |
| **~83 条断言是"grep Dart 源码字面串"** | `m4_stress_challenge.test.js` 121 条 assert 中 **56 条**是 `Src.includes(...)` + 12 处 readFileSync + 2 个 emulator 类；`m1_stress_challenge.test.js` 57 条中 **24 条**同类；`m3_stress_challenge.test.js:695-853` 用 **160 行 JS 复刻** Dart reconciliation 后自测；`m4_stress:74-75` 注释自认 "exactly matching dsh_service.dart lines 1381-1382" | **Dart 侧改了测试照样绿**；一次 `dart format` 就能让它们全红（而 CI 又不跑 format → 双向失守）；`m4_stress:490` 甚至断言中文 UI 文案字面量 `'访问令牌已失效 (HTTP 401)'` → 做 i18n 就红。**而真 Dart 测试已经做了正确版本**：`card_folding_test.dart:41-62` 用 `byWidgetPredicate(maxHeight==280)`、`dsh_service_m1_test.dart:42` 真验 `*(任务已被手动停止)*` |
| **analyze 门禁被自己的 flag 取消** | `bridge-tests.yml:68` 注释 "Treat analyzer **infos as failures**"，`:69` 命令却是 `--no-fatal-infos --no-fatal-warnings` | **注释与命令完全相反**，dead import/unused variable 全部放过 |
| **无 pub/gradle 缓存、无 concurrency 组** | 只有 `flutter-action` 的 `cache:true`（缓存的是 Flutter SDK）；`setup-java` 未设 `cache:gradle`；全仓无 `actions/cache`、无 `concurrency:` | 每次重下 Gradle 发行版 + 全部 Android 依赖 + 全量 `pub get` → **APK 构建常态 10~20 分钟**；连续两次 push → 两个 15 分钟 Gradle 构建并行抢 runner |
| **版本写进 CI 断言** | `smoke-bridge.test.mjs:102` `assert.match(r.data.version, /^1\.2\.\d+$/)` | 与 `core.mjs:39` 的 `'1.2.9'` 绑死 → **一旦对齐 pubspec 升到 1.3.0，唯一的 hermetic CI 门禁立刻红**。定时炸弹 |
| **`flutter build apk --release` 未加 `--split-per-abi`** | `build-apk.yml:44` | 产出含 armv7+arm64+x64 的 fat APK，**体积约 2-3 倍于必要值**（22.8MB → 应约 8-10MB）；也无 `--obfuscate --split-debug-info` |
| **`permissions: contents: write` 但 `pull_request` 也触发** | `build-apk.yml:10-11` + `:3-8` | 权限过宽，违反最小权限 |
| **`npm ci \|\| npm install` 掩盖锁文件不一致** | `bridge-tests.yml:34`；且 `dsh-server-plugin` **同时跟踪 `package-lock.json` 与 `pnpm-lock.yaml`** | 包管理器歧义，CI 可能装到与本地不同的依赖树 |
| **无 secret 扫描 / 依赖漏洞扫描 / dependabot** | 两个 workflow 无 `gitleaks`/`trufflehog`/`npm audit`/OSV；无 `.github/dependabot.yml` | **恰恰是最需要 secret 门禁的仓库却没有**（见 §1.17、§1.1、§1.15） |
| **`test:unit` 的依赖解析是隐式的** | `bridge-tests.yml:33-34` 在 `./dsh-server-plugin` 装依赖，`:37` 在**仓库根**跑 `npm run test:unit`（根 `package.json` 无 dependencies） | 靠 Node 向上找 `dsh-server-plugin/node_modules/ws` 才没崩，目录一动就挂 |

**测试有效性（251 个 it / 850 条 assert 的真实含金量）：**
- **恒真断言 6+ 处**：`ping-pong:54/99`（`assert.ok(pong)` 紧跟超时会 reject 的 `waitForMessage`）、`sessions:90`（`messages.length>=1`，握手 greeting 已保证）、`mobile-approval-flow(t1):32`（`typeof ok === 'boolean'`）、`oversized-payloads:64`（`catch(err){assert.ok(err)}`）、`reconnect-resync:28`（`elapsed<=5000` 但 elapsed 只包住超时 3000ms 的 connect → **数学上不可能 >5000**；`TEST_READY.md:46` 却宣称 "Reconnect <= 5000ms verified"）
- **OR 链约 19 处，其中 `malformed-json.test.js` 全文件 5 条全是 OR 链**（`:20 200||400||500`、`:30 400||200`、`:40 200||400`、`:50 400||200`、`:64 200||400`）→ 没有一条钉住契约。`session-id-boundary:59` 是 `400||500||200`（**接受一切状态码**）；`:36` 把 **500 崩溃判为 "graceful"**；`oversized-payloads:61` 号称验证 2MB 上限却 `413||400||500||200`；`ping-pong:72` 的正则含 **`timeout`** → **服务端挂死也算通过**
- **测试名与断言不符 12+ 处**：`sessions:57-76` **TC4 "deletes a session" 只断言 `200 + message==='Deleted'`，从不回读** → 这正是 `session-cleanup.js:9-12` 描述的"谎报 Deleted 实际没删"缺陷，**该测试在缺陷存在时也是绿的，等于给假删除背书**；`streaming-approval:12-37` TC1 名 "monitor approval lifecycle" 却**从不 prompt、从不触发 tool call、从不观察任何 approval 事件**；`permission-prompt:12-31` TC1 名 "takes effect before prompt execution" 却**全程没有提交任何 prompt**；`reconnect-resync:55-67` TC3 名 "without leaks" 却只断言 ping 200，**无任何 socket 数/句柄/内存测量**；`mobile-full-lifecycle` 的 `TEST_INFRA.md:55` 声明含 "submit prompt"，实际 `:13-73` **无任何 prompt 调用**
- **流式内容主链路在真实网关上零覆盖**：`thinking`/`delta`/`tool_call`/`tool_start`/`tool_result` 在测试里只出现在**本地 JS 模拟器**（`m4_stress:80-120`、`m1_adversarial:122-143`）中，**不是真实 WS 帧**。`session_deleted`(`index.js:1533`) 与 `select_session`(`1764/1776`) 全仓 grep 命中 **0** → **v1.3.0 头号修复"删除会话"的广播事件本体无测试**，App 的核心功能（流式渲染）在真实网关上一次都没被断言过
- **6 条路由零覆盖，其中 3 条正是 v1.3.0 的安全修复**：`/dsh-agent.apk`(`1184`)、`/__mobile/pair/code`(`1215`，发布说明称"配对码改用密码学随机生成，此前恒为 `000000`")、`/__mobile/pair`(`1232`，称"设备列表真实落盘")；另 `/api/mobile/ws`(`1688`) 与 `/api/mobile/memory`(`1607/1622`) 两个别名、personas 的 e2e 层
- **测试与发布说明直接冲突**：`prompt-and-cancel.test.js:96-104` 断言对**不存在的会话** cancel 返回 `200 + ok:true + 'Cancelled'`，而 `build-apk.yml:71` 声称"`sessions/cancel` 失败时**不再返回 200，改为 5xx**" → 二者必有一假。同类冲突 `stress_cancel.mjs:190-192`、`r3_adversarial_verify.mjs:232-234`。而 `m4_adversarial:117-120` 断言 `got413 || gotConnReset`（两种都算过）→ **该测试无法证伪 `build-apk.yml:77` 声称的"不再触发 ECONNRESET"**
- **`m4_adversarial_boundary_challenge.test.js` 测试名仍带 `BUG:` 前缀**（`:17/:31/:154`），注释 `:21` 仍写 "The server returns HTTP 200 and **leaks file content**"，但断言已是修复后的 `403`（`:24-28`）→ **文档与断言相反，误导后续维护者**
- **`TEST_READY.md` 的统计与 Defect 列表全部过时**：`:25-29` 称 "23 suites / 93 cases"（实测 e2e 层就有 24 文件、`it` 总数 251）；`:60-90` 列的 4 个 Defect 中 3 个已修复并有覆盖，**文档仍称它们是 open defects**，`:101-103` 还教人复现 "4 tests failing"
- **`benchmark-policy-sync.mjs` 全文 0 条 assert**，`:109-111` 的 SLA 违规只 `console.warn` → `npm run bench` **永远 exit 0**；且 `:32-46` 的 waiters **完全没有 timeout**，`:62 await Promise.all(waiters)` **一旦某客户端收不到帧就永不返回，bench 进程挂死**（对比 `policy-sync-persistence-stress.test.js:85-87` 就正确加了 5000ms reject）
- **`--test-concurrency=1` 的三个根因已核实**：① 固定端口常量（`smoke-bridge:27` 3199、`m2:275-276` 3098/3099、`m3:183-184` 3108/3109、`m3:306` 3118）而非 `port:0` → 并行必 `EADDRINUSE`；② 除 `smoke-bridge:19` 外**无人隔离 `DSH_HOME`** → `m2:315-321`、`m3:211-217` 起真网关却读写你**真实的** `permissions.json`/`workspace.json`；③ `session-cleanup.js:29` 的 `STATE_FILE` 在 `os.tmpdir()` **无 run-id**，并发互抹。代价：串行 + **8210ms 固定 sleep** → `npm run verify` 分钟级且无法并行加速
- **`BRIDGE_URL` 覆盖机制被自己的断言否决**：`health-and-auth.test.js:20/31` 断言 `res.data.port === 3088` → 一旦指向别的端口测试必红。另 `m3_1:31` 用 PowerShell `Get-NetTCPConnection -LocalPort 3088`（Windows-only + 写死端口）；`policy-sync-persistence-stress:21-24`、`benchmark-policy-sync:8-11`、`burst-concurrency-stress:8-11` 都把 `~/.dsh/mobile-access/permissions.json` **当本地文件读** → 远端跑必崩
- **两套测试体系平行重复且分类维度互相矛盾**：`tests/e2e/tierX`（按测试类型，24 文件）vs `tests/m*`（按里程碑 M1~M4 + **challenger agent 名**，8 文件平铺在根）。同一功能被 3~5 个体系各测一遍（路径穿越 4 处、2MB 上限 4 处、空白 sessionId 4 处）；`m4_adversarial` 与 `m4_empirical` 是**近似克隆**（三个 describe 标题一一对应）；`m1_stress` 与 `m1_adversarial` 同里程碑同层重复；`mobile-approval-flow.test.js` 在 tier1 和 tier4 **各存在一份同名文件**；`tier4-workloads/` 混了 5 个 `.test.js` + 2 个 `.mjs`，而 `package.json:13` 的 glob 是 `**/*.test.js` → **静默跳过那两个 .mjs**；文件扩展名四种混用（`.test.js`/`.test.mjs`/`.mjs`/`.cjs`）；`stress_cancel.mjs`/`r3_adversarial_verify.mjs` 是**裸脚本无 TAP**，只靠 `process.exit(1)`
- **`TEST_INFRA.md:86-118` 的目录树已过时**：未提 `session-cleanup.js`、未提 tier4 的 `policy-sync-persistence-stress` 与两个 .mjs 基准、**完全未提 `tests/` 根目录的 m1~m4 与 race 脚本**
- **fixtures 重复**：`MOCK_PAYLOADS`(`fixtures.js:33-45`) 几乎没被用（其余各处就地重造 `'Z'.repeat(3*1024*1024)` 等 5 份）；`MALFORMED_JSON_STRINGS`(`:39-45`) **零引用**；`client.js` 已提供 `apiRequest`/`createWsClient` 却被 **27 处手写 `fetch`/`new WebSocket`** 绕过（这正是会话登记失效的原因）；`smoke-bridge:32-55` 自建 `req()` 与 `apiRequest()` 功能重叠；`probe_dsh.cjs:29-50` 完整抄了一份 `core.mjs` 已导出的 base64url/HMAC cookie 逻辑

**版本号在 13 处重复维护，对外报 3 个冲突值**（§前述 + 补充）：桥接 `/health` → **1.2.9**、App UI → **1.3.0**、下载页 → **v1.1.0**。而 `build-apk.yml:82` 声称"**版本号单一来源**：统一由 `pubspec.yaml` 提供，`app_version.dart` 与之保持一致" —— 但 `app_version.dart:8-9` 是**两个独立的 `static const` 字面量**，`pubspec.yaml` 全文 39 行**无任何生成配置** → **该声明不成立**。

**仓库无 `CHANGELOG.md`/`RELEASE_NOTES.md`/`HISTORY.md`**；唯一的发布说明是**内联在 CI 里的 26 行中文 markdown**（`build-apk.yml:62-87`）→ 发布说明的 diff 混在 CI 配置 diff 里；`:60` 的 tag 不变则每次 push main 覆盖同一个 Release（softprops 默认 upsert），**旧版本的说明与产物一起丢失**；无 tag 序列 → 无法回答"v1.2.6 改了什么"。

### 6.11 新增的 CI 门禁 / 测试类型建议（补充 §4）

**门禁（按投入产出排序）：**
1. **secret 扫描**（最高价值，本仓风险已实测坐实）：`gitleaks/gitleaks-action@v2` 扫全历史 + PR diff
2. **`flutter test` + 覆盖率**：先设"不许下降"的软门禁（≥40%），逐步提到 70%
3. **`flutter analyze --fatal-infos --fatal-warnings` + `dart format --output=none --set-exit-if-changed .`**；补 `analysis_options.yaml` 落地已声明的 `flutter_lints`
4. **版本单一来源校验**：`scripts/check-version-consistency.mjs` 断言 `pubspec.yaml:4` == `app_version.dart:8`+`:9` == `core.mjs:39` == 根 `package.json:3` == Release tag，任一不符 exit 1 → 直接堵住 13 处漂移
5. **APK 产物完整性**：把未跟踪的 `scripts/read-apk-version.mjs`（109 行，`git status` 显示 `??`）入库并改造成断言式 —— 解开 AXML 断言 `versionName`==pubspec 版本、`versionCode`==build 号、**`package` != `com.example.*`**、**签名者非 Android Debug 证书**（这一条直接守住 §1 那个"每次构建签名不同"的根因）。同时修掉它 `:75` 的恒真循环条件（`while (scan < off+size+0 || scan < axml.length-8)` 左半永假）与 `:21-28` 的 PowerShell 依赖
6. **`concurrency` 组 + 分支保护**：`main` 的 required checks = `unit` + `flutter-analyze` + `flutter-test` + `gitleaks` + `version-consistency`
7. **`actionlint`**：catch `permissions` 过宽与 `npm ci || npm install` 这类反模式
8. **依赖漏洞扫描 + dependabot**（覆盖 `npm`/`pub`/`github-actions` 三个 ecosystem）；先统一包管理器并删掉 `pnpm-lock.yaml`
9. **APK 体积回归门禁**：记录上次 Release 的 size，±10% 失败（当前 22.0→22.8MB 无人看守）
10. **e2e 进 CI（用一次性容器）**：`bridge-tests.yml:3-8` 正确指出 e2e 现在不能进 CI（打真实网关+污染真实工作区）。**解法是让它能进** —— 新增 `docker-compose.test.yml` 起「一次性 DSH 引擎 + 桥接（临时 `DSH_HOME` 挂 emptydir）+ mock LLM upstream」，e2e 通过已支持的 `BRIDGE_URL`/`BRIDGE_WS_URL`(`fixtures.js:25-26`) 指向它。前置条件是修掉 §6.10 那些**否决覆盖机制的硬编码**

**测试类型：**
11. **`integration_test` 在模拟器跑**（当前完全缺失，`dev_dependencies` 只有 `flutter_test`+`flutter_lints`）：覆盖 4 条真实用户旅程（配置页连接 → 会话列表 → 发消息看流式渲染 → 审批卡一键放行）。**这是唯一能验证「`thinking`/`delta`/`tool_call` 帧真的被渲染成卡片」的手段**，正是 §6.10 指出的全线零覆盖区
12. **契约测试**：把 24 条路由 + 17 种 WS 出站帧 + 5 种入站帧固化为 OpenAPI/AsyncAPI 或 JSON Schema 快照，两端各跑校验 → 直接消灭 `res.data.logs || res.data.auditLogs` 那种"schema 不确定所以两个都收"的写法
13. **变异测试（stryker）跑 `core.mjs`**：这是量化"断言很弱"最直接的手段，预期会暴露那批恒真断言对应的代码变异**全部存活**
14. **属性/模糊测试（fast-check）**：对 `createPathSanitizer`、`parseJsonBody`、`normalizeSessionKey`/`sessionIdMatches` 随机生成 unicode/嵌套/超长/带盘符路径 —— 正是 §1.19/§1.20 两条穿越路径的守门测试
15. **真实泄漏检测**：断言服务端可观测指标 —— `connectedClients.size`(`index.js:1711/1721/1731/1789-1790`) 在 N 轮 churn 后回到基线、`process._getActiveHandles().length` 稳定、`followerRegistry` 条目数归零。取代 `m3_1:31` 那个 Windows-only 又写死端口的 `Get-NetTCPConnection`
16. **性能基准变成门禁**：断言 P99 ≤ 阈值、结果写 JSON artifact、CI 里与上次 main 比对，回归 >20% 则失败（`policy-sync-persistence-stress:150-153` 的 P99≤50ms 是正确范式，可复用）
17. **新增流式帧测试**：`tier1-features/streaming-frames.test.js`，复用 `m2_stress_challenge:284-300` 已有的 mock upstream `WebSocketServer` 手法注入 `assistant-stream` 帧（`index.js:863-885`），逐一断言 5 种出站帧的 payload 结构 + `select_session` + `session_deleted`
18. **新增配对与下载测试**：`tier1-features/pairing-and-download.test.js`，断言两次 `POST /pair/code` 返回**不同**且非 `000000` 的码、过期码被拒、配对后设备列表持久化、两个别名路由与主路由响应等价

**`package.json` 脚本体系重整（解决两套并存）：**
- 新增分层：`test:fast`（unit only，hermetic，CI 用）/ `test:contract`（e2e 打一次性容器）/ **`test:destructive`（会改真实配置的，默认不进 `npm test`）** / `bench`（带阈值门禁）
- 把 m2/m3 里**方法正确**的部分（`m2:271-559` 的 mock-upstream 隔离网关手法、`m3:302-692` 的流式 resync）迁进 `tier3-cross-feature/`；**删掉 m1/m4 的源码 grep 与 emulator（约 1200 行）**
- `stress_cancel.mjs`/`r3_adversarial_verify.mjs` 从裸脚本改写成 `node --test`，纳入 TAP
- `probe_dsh.cjs` 从 `package.json:23` 移到 `scripts/`（0 断言的诊断工具，`:27` 顶层 `resolveSecret()` 在无 `~/.dsh` 时 `process.exit(1)`，`:106/119` 还会直连引擎建会话并泄漏）
- **发布**：tag 驱动（`on: push: tags: ['v*']` + `tag_name: ${{ github.ref_name }}` + `body_path: CHANGELOG.md`）；新建 `CHANGELOG.md`（Keep a Changelog 格式，把 `build-apk.yml:62-87` 迁出来作 v1.3.0 条目，磁盘上 12 个 APK 文件名就是 v1.0.0~v1.2.9 的版本序列证据）；`await-apk.mjs` 加 `--expect-version` 校验（现在 `:101-119` 只下载 zip 就 exit 0，`:119` 还叫用户手动 `Expand-Archive`）；`git rm dsh_mobile/.github/workflows/build-apk.yml`

---

## 附：总结（三路深挖后修订）

**这个项目的"骨架"和"测试资产体量"已经超出一般个人项目的水准。但深挖之后，问题比第一版判断的更严重，集中在五处：**

**① 一条完整的远程 RCE 攻击链已经成立（唯一需要今天动手的）**
泄露在 git 历史三个 commit 里的引擎 HMAC 密钥**当前仍然有效**（已实机比对确认），拿着它就能自签 cookie 绕过网关直连 3080 = 宿主机任意代码执行。即使不走这条路，默认策略 `auto-read` 的分类器也认 `cat ~/.dsh/.credentials.yaml` 是"只读命令"，会把这同一把钥匙**广播给所有已连接的手机客户端**。配套还有：`sessionId` 零校验可删宿主机任意 `.json`、路径消毒器在注册表为空时整层跳过可任意读写、请求体中断可远程崩掉进程。**五处互相咬合，但轮换一次密钥就断掉最关键的那一环。**

**② 14+ 处"以为修好了其实没修好"，而且全是静默的**
配对发出去的 token 永远无法认证、设置页的配对码必然失败、角色控制与设备统计是空实现、审批仍在谎报成功、会话级 `ask` 是假开关（策略合成用了 OR）、待审批角标永远不亮（审批的 sessionId 取的是 agent id）、版本号 13 处漂移对外报 3 个冲突值、状态恒报 `running`、Persona 整套完整实现却零 UI 接入、3 个 slider 是纯安慰剂、暗色主题是亮色副本。**全项目 grep `TODO|FIXME` = 0 命中** —— 没有一个显式占位符，全是"UI 上看着完整、实际什么都没做"，这比 TODO 难发现得多。

**③ 测试套件正在污染你的真实环境，而它的含金量远低于表面**
自动回收机制五处失效叠加（`cleanup-hook.mjs` 是从未被 `--import` 的死文件，且它的顶层 await 会在测试**开始前**清空待清理表）；6 处把你的真实策略改成 `danger-full-access` 且不恢复，其中一处"恢复"是硬编码 `auto-read` 而非读到的原值；今天工作区根目录就躺着 3 个测试垃圾文件。同时 251 个 it / 850 条 assert 里：**~83 条是 grep Dart 源码字面串**（Dart 改了照样绿，`dart format` 一次就全红）、**~25 处恒真或 OR 链**（`malformed-json.test.js` 全文件 5 条断言没有一条钉住契约）、**12+ 处测试名与断言不符**（TC4 "deletes a session" 从不回读，等于给假删除背书）、**流式主链路在真实网关上零覆盖**、**CI 从不跑 `flutter test`**（3 个真 Dart 测试永不执行）。

**④ 引擎能力只用了约 20%**
`ask_user_question` 被丢会让会话**永久卡死且无任何 UI 信号**（比审批卡死更糟，因为没有队列可查）；TODO / 图片 / 附件 / 搜索 / diff / 语音 / 交付物这些引擎早就有的东西一个都没接。而 `approval_request.dart` 已经解析好的 `options` 字段，正好是 `ask_user_question` 的现成落点。

**⑤ 移动端最该有的几样东西缺失**
签名固定的可覆盖安装 APK（每次升级都要卸载重装，还会连带清空 host/token）、推送通知（不前台开着就什么都收不到，且 Manifest 连 `POST_NOTIFICATIONS` 都没声明、也没有 deep link 让通知能直达审批）、半开连接检测（Wi-Fi↔4G 切换后 UI 显示"在线"但全部超时）、消息本地缓存（地铁/电梯完全不可读）、草稿恢复（发送失败输入框已空且无重发按钮）、超过 4 分钟的任务 UI 会静默"假装结束"。

**性能上的三个单点最大收益**：Markdown 每 token 全文重解析（O(n²)，且同帧重建全部历史消息）、`getWorkspacesData()` 在每会话循环内重解析两份 YAML（O(S×Y)，1270 个会话可卡住事件循环数秒，还被一个永不停歇的 3 秒定时器反复触发）、冷启动 `follow` 帧被静默丢弃（**这是 700ms 全量轮询、全树重建、流量爆炸三件事的共同源头**）。

**执行建议：** 按 §5 走。**第 0 批（安全应急，约 1 小时）今天就做**，其中第 1 步轮换引擎密钥的收益远超其余全部；第 1 批（测试止血，半天）紧接着做，否则后面每一批的验证都可能被测试污染掩盖；然后再进第 2 批的装机体验。做完第 0~3 批（约 4~6 天），这个 App 的安全性和可用性会有一个台阶式的跳升。


---

## 7. 2026-10-09 复扫修复记录（v1.11.0 + bridge 1.3.0）

> 本轮按 §5/§6 建议顺序实作了扫描报告中列出的全部问题与功能。验证方式：
> 网关 `npm run test:unit` 151/151 绿；Flutter `flutter analyze` 0 告警、
> `flutter test` 284/284 绿。未运行任何 live 测试、未重启 dsh web、未建任何真实会话。

### 7.1 已修复的 Bug

| 原编号 | 修复内容 | 文件 |
|---|---|---|
| 一-1 | 重连后 data 回调补调 `_onSocketReady()`，提问订阅不再丢 | dsh_service.dart |
| 一-2 | 审批回传改为 RPC 成功才出队，失败保队列返回 502 供重试 | lib/index.js |
| 一-3 | `verifyToken` 三级校验（全局→设备哈希→env），`findDeviceByToken`、`roleCanWrite` 真实现，`authenticateRequest` 返回真实设备 | store.mjs / core.mjs |
| 一-4 | `switchModel` 双路失败时返回 false 并报错，不再假成功 | dsh_service.dart |
| 一-5 | 提问记录带 `offeredTo` 集合，一台手机断开只清它持有的提问 | lib/index.js |
| 一-6 | 自动放行 RPC 失败降级为人工审批卡片 | lib/index.js |
| 一-7 | RPC `audit/list` 注入 `readAudit` 真数据 | rpc.mjs / index.js |
| 一-8 | `fetchWorkspaces` in-flight Future 去重 | dsh_service.dart |
| 一-9 | `question_ack` 的 rpc-failed 保留卡片（网关侧也保记录，retryable 标志） | dsh_service.dart / index.js |
| 一-10 | 发送失败草稿还回**发起会话**的键（draftKeyAtSend） | dsh_service.dart |

### 7.2 性能优化

- **projCache mtime 缓存**（`createProjCacheReader`）：工作区轮询从 ~1000 次 readFileSync+JSON.parse/3s 降为 statSync 命中（core.mjs，getWorkspacesData/getSessionHistory/updateSessionModel 三处接入）。
- **广播按会话过滤**：`broadcastToMobileClients` 只发给 follow 该会话的 socket。
- **follower TTL**（10 分钟空闲清扫，挂 heartbeat interval）。
- **共享 http.Client + keep-alive**：去掉逐请求 `Connection: close`。
- **会话轮询降频** 700ms→2.5s（WS 为主通道，轮询兜底）。
- **testConnection 并行竞速**：最坏 20s → 4s。

### 7.3 安全加固

- WS 鉴权从 URL query 移到 header（IOWebSocketChannel.connect headers）。
- 配对码防爆破：5 次失败作废该码。
- 上传限流：每设备/IP 60s 窗口 10 次。
- 只读角色（readonly device）真正拦截全部写端点（WRITE_PATHS 统一守卫）。
- `allowBackup="false"`：阻止云备份带走 SharedPreferences 里的 token。

### 7.4 新增功能（v1.11.0）

1. **应用内更新检查**：网关 `GET /api/mobile/version` + 设置页「检查更新」（语义化版本比较，直接跳浏览器下载 APK）。
2. **通知点按直达会话**：payload `session:<kind>:<id>`，main() 挂回调、MainShell 消费跳转。
3. **会话归档/取消归档**：网关 `POST /api/mobile/sessions/archive`（写 archivedSessionIds）+ 工作区行内按钮。
4. **会话重命名**：网关 `POST /api/mobile/sessions/rename`（改 projcache title 行）+ 行内按钮。
5. **跨会话全库搜索**：网关 `GET /api/mobile/sessions/search` + 工作区「全库」按钮浮层，命中即跳。
6. **提示词模板**：网关 `GET/POST /api/mobile/snippets`（mobile-access/snippets.json，上限 50 条）+ 聊天输入框 chips + 设置页管理面板。
7. **Android 分享接收**：SEND intent（text/plain）→ 输入框；图片 intent-filter 已声明（内容消费暂缓）。
8. **openUrl 原生通道**（dsh_mobile/url）：跳浏览器下载 APK。

### 7.5 未尽事项（如实声明）

- **Kotlin 编译未本地验证**：gradle-8.3 发行包下载被本机网络（TLS 握手失败）拦截。MainActivity.kt 改动经人工复核（channel label/deprecated API/manifest 联动），CI build-apk 会兜底编译。
- **图片分享**只声明了 intent-filter，URI→附件管线的消费未接（content:// 流读取改动大，v1.12 再做）。
- **BRIDGE_VERSION** 1.2.9→1.3.0 手动 bump；版本三处漂移的根治（CI 从 pubspec 生成）仍欠着。