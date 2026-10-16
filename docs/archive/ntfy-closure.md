# ntfy 离线推送闭环补齐：去重 / 可归因 / 用户须知

日期：2026-10-10
范围：`dsh-server-plugin/lib/features.mjs`、`dsh-server-plugin/lib/index.js`、`tests/unit/features.test.mjs`、`dsh_mobile/lib/views/custom_settings_view.dart`、`dsh_mobile/test/widgets/push_settings_test.dart`
基线：T4 审计判定 ntfy "只是看起来完成了"（`push/config = {enabled:false,url:"",topic:"",hasToken:false}`，闭环缺 5 环），本任务补其中可验证的 3 环
约束遵守：**未重启 dsh web**、**未创建会话**、**未真发任何网络推送**（全部注入桩）、未触碰 T3 范围文件

---

## 1. 去重：App 活着时不再下发 ntfy

### 改了什么

`features.mjs` 新增两个纯函数，`index.js` 的 `pushNtfy()` 改为经过它们：

```js
export function countDeliverableClients(clients, openReadyState = WS_OPEN)
export function shouldPushNtfy(config, clients, openReadyState = WS_OPEN)
```

`shouldPushNtfy` = `config.ntfyEnabled === true && countDeliverableClients(...) === 0`。

### "活跃连接"的判定依据（现成状态，非猜测）

| 条件 | 来源 | 含义 |
|---|---|---|
| `readyState === OPEN` | `broadcastToMobileClients` 判断"能投递"用的**同一条件**（`index.js`） | 任何其他状态都收不到帧 |
| `isAlive !== false` | `wss.on('connection')` 置 true；`ws.on('pong')` 与**每条入站消息**都置 true | 30s 心跳扫描（`HEARTBEAT_INTERVAL_MS`）把它置 false 并发 ping；**下一轮仍为 false 就 `terminate()`** ⇒ `false` = 整整一个 ping 周期没收到 pong |

### 取舍（写进代码注释，Lead 已认可方向）

- ping 在途那一刻（`false`，仅毫秒级）被误判为 dead → 代价是**重复通知**，只是烦。
- 把 OPEN 但 peer 已消失的 socket 当作 alive → 代价是**漏掉通知**，用户什么都不知道。

⇒ 采用心跳标志、接受毫秒窗口：**宁可多弹一次，不可漏**。

### 用户可见语义（必须同时写进 UI，见 §3）

审批 / 提问 / 回合结束这三个事件本来也会 `broadcastToMobileClients` 给手机，App 收到后自己弹本地通知。所以：
**App 在线 ⇒ 只弹本地一条；App 不在线（进程被杀 / 断网 / 锁屏）⇒ 才走 ntfy。** ntfy 是 fallback，不是并行通道。

---

## 2. 可归因：推送成败进 audit（且不泄露信道）

### 改了什么

`features.mjs` 新增 `deliverNtfy({ kind, detail, config, clients, openReadyState, send, audit, logger })`，`index.js` 提供真实 transport `sendNtfyOverHttp(request)` 注入进去。**永不 reject**（推送不得拖累/失败掉它所报告的那次审批或回合）。

每一次调用都写一条 `ntfy/push`：

| outcome | reason / status | 用户能据此判断 |
|---|---|---|
| `skipped` | `disabled` | 开关没开 |
| `skipped` | `app-connected` | App 在线、被去重抑制（**这是新行为，正是"我开着 App 所以没收到"的正确解释**） |
| `skipped` | `not-pushable` | 这个事件种类本来就不推 |
| `skipped` | `unconfigured` | 地址或 topic 没配 |
| `sent` | `status` | 送达 |
| `failed` | `status` / `reason` | ntfy 拒绝（如 403/429）或传输异常 |

另加 `pushTest()` 的 `ntfy/test` 审计（同样含 status / reason / host / topicLength）。**测试推送刻意绕过去重**：用户手动点"测试推送"必须真发，否则他永远无法验证信道（已在代码注释里写明）。

### 不记录 token / 完整 topic（两条防线）

1. `describeNtfyTarget(config)` → 只输出 **`host`**（如 `ntfy.sh`，回答"发到哪儿了"）与 **`topicLength`**（回答"topic 填了没"）。topic 是信道共享秘密、token 是凭据，二者都不进审计环（审计环可经已鉴权路由读出）。
2. `redactNtfyDetail(text, config)` → 把 token 与 topic 明文替换成 `[redacted]`，并截断到 160 字符。传输错误消息由第三方库生成、其 URL 里含 topic，所以不能只靠"库不会回显"这个假设。

**已用真实 audit sink 验证**（不是只验证我自己传的 payload）：把 4 种结局的载荷过一遍 `core.mjs` 的 `createAuditSink`，再 `JSON.stringify(sink.read(50))` 断言不含 `SECRET-TOPIC` / `SECRET-TOKEN`，同时**必须**含 `ntfy.example.com`。因为 sink 自己还会从 `reason` 派生 `command`、并在缺 `reason` 时回落 `JSON.stringify(norm)`——只测我传进去的 payload 不足以证明可读出来的内容干净。

---

## 3. 用户须知：设置页写明"还得装客户端"

`dsh_mobile/lib/views/custom_settings_view.dart` 新增 `_buildPushRequirementNote()`（警告色描边卡片，紧贴输入框上方），四条：

1. 在应用商店安装一个 **ntfy 客户端**（官方开源 App，Android/iOS 都有）。
2. 在客户端里**订阅与下面完全相同的一个 topic**（一个字都不能差）。
3. 没装客户端，或 topic 对不上 → **手机不会有任何提示**。
4. 提醒**只在 App 不在线时才经 ntfy 发送**；App 活着时由它自己弹本地通知，**不会重复推两条**。

**为什么第 4 条必须写**：这次去重上线后，"开着 App 测推送 → 什么都没收到"是**正确行为**。不写清楚，用户会把已修好的功能判成坏了——这正是 T4 说"只是看起来完成"的同一类问题。

同时给推送区块加了 `@visibleForTesting` key（`pushRequirementNoteKey` / `pushUrlFieldKey` / `pushTopicFieldKey` / `pushTokenFieldKey`），让测试按 key 断言而不是依赖会变的文案。

---

## 4. 顺带修掉的两处真实布局缺陷（同一文件，非本任务范围）

`custom_settings_view.dart` 在手机宽度（420 逻辑 px）下有两处 `RenderFlex` 溢出，屏幕上是黄黑斜纹：

| 位置 | 问题 | 溢出 |
|---|---|---|
| `_buildSectionHeader` | `Row([Icon, SizedBox, Text(title)])` 缺 `Expanded`；标题如"大语言模型与思考引擎 (LLM & Reasoning)"很长 | 67 px |
| "深度思考预算 (Reasoning Budget)" 行 | `MainAxisAlignment.spaceBetween` 下两个裸 `Text` 都不可收缩 | 97 px |

两处各加一个 `Expanded`（+8px 间距）。属于**真实可见缺陷**，且不修的话任何渲染设置页的 widget 测试都必然变红。

---

## 5. 验证

### 5.1 已验证（本轮实测）

```
node --check dsh-server-plugin/lib/features.mjs   →  通过
node --check dsh-server-plugin/lib/index.js       →  通过
node --test tests/unit/features.test.mjs          →  pass 52 | fail 0
网关全量单测（9 个文件逐个跑，按退出码判定）        →  9/9 PASS，211 个测试，0 失败
flutter analyze --no-pub                          →  我的两个文件输出为空（见 5.2）
```

新增 / 相关用例：

| 用例 | 钉住的行为 |
|---|---|
| `countDeliverableClients: only OPEN sockets the heartbeat has not written off` | 4 种非 OPEN 状态、`isAlive:false`、`isAlive` 缺失、混合集合的计数 |
| `shouldPushNtfy: the switch must be strictly on, and a live App wins` | 有连接→不发 / 无连接→发 / 心跳判死→发 / `'true'` 字符串不算开 |
| `deliverNtfy: a live App suppresses the push and the audit says why` | 有连接时 `send` **零调用**，且审计写明 `app-connected` |
| `deliverNtfy: with no live App the push goes out and the status is recorded` | 无连接时恰好一次推送 + `status:200` 落审计 |
| `deliverNtfy: a rejected push is audited with its status, never swallowed` | 403/500 → `failed` + status，且只 warn 一次 |
| `deliverNtfy: a transport exception is audited, not thrown at the caller` | 异常不冒泡到调用方 |
| `deliverNtfy: never logs the token or the topic (any outcome)` | 5 种结局 × 断言审计+warn+info 全文不含 token/topic，且含 host |
| `deliverNtfy: disabled / not-pushable / unconfigured are distinguishable` | 三种跳过原因互不混淆，且都留审计 |
| `describeNtfyTarget / redactNtfyDetail` | host+长度、非法 URL、明文替换、160 字符上限 |
| `the REAL audit sink can be served to a client without leaking the channel` | **过真实 `createAuditSink`** 后仍无 token/topic（防 sink 归一化把秘密带回来） |

全部使用注入桩 `send`，**零真实网络请求**。

### 5.2 未验证 / 待整合口验证（如实声明）

1. **`test/widgets/push_settings_test.dart` 的执行结果待 Lead 在最终整合口跑。**
   原因：该测试必须 `import main.dart`（`CustomSettingsView` 自身就 `import '../main.dart'` 取 `ThemeController`），因此需要**整包可编译**；而当前 T3 的重构处于在途中间态（`task_center_view.dart` 被删且引用仍在、`chat_view.dart` 多处新 API 未落地），`flutter analyze` 报 14 个 error **全部在 T3 的文件里**。按 Lead 指示：不去改、不去临时注释 T3 的任何文件。
   已确认的是：**`custom_settings_view.dart` 与 `push_settings_test.dart` 自身 analyze 输出为空**（`flutter analyze | Select-String 'custom_settings_view|push_settings_test'` 无输出）。
   测试内容（5 个用例）：note 存在 + 三条要点逐句断言、"App 不在线才发/不重复两条"、回显灌入输入框、token 永不回显（字段为空 + `obscureText`）、未保存过 token 时不谎称"已保存"。断言一律按 key 取 `controller.text`，不用 `widgetWithText`（hint 也是 `Text`，会误命中）。
2. **真实送达未验证，且在本环境不可能验证。** ntfy 是外部服务；本轮约定禁止真发网络请求，实测 `push/config` 也是 `enabled:false,url:"",topic:""`。所以"消息真的落到用户手机的 ntfy 客户端上"这一步需要用户自备服务与客户端后自行确认。
3. **"无连接时下发"的判定只在单测里用桩验证过**，没有对着活实例造出"App 掉线 + 真实审批事件"的组合（那需要重启 dsh web 并真的触发一次审批，超出只读/不污染边界）。
4. **心跳窗口的取舍未在真实网络抖动下量化**：`isAlive === false` 的窗口理论上等于一次 ping 的 RTT，我没有测过弱网（高 RTT/丢包）下这个窗口会拉长多少，也就没有量化"重复通知"的实际发生率。
5. **两处布局修复只做了逻辑判断与 widget 测试渲染验证**（`flutter test` 若在整合口变红会由 Lead 交回），未在真机截图上确认斜纹消失。
6. `pushForEvent` 的 kind 清单未改动，所以"哪些事件值得推送"这个产品判断沿用原样（只有 `approval` / `question` / `turn-end` / `turn-failed`）。

---

## 6. 用户可执行验证（**需要重启 dsh web**）

本轮全部网关改动（含 T1 的 RC-1…RC-5）会合并进**同一次** `dsh web` 重启后生效。

1. 重启后确认推送配置与去重生效：
   ```
   curl -s -H "x-dsh-token: <token>" "http://127.0.0.1:3088/api/mobile/push/config"
   ```
2. **验去重**：保持 App 在线（前台或后台进程存活）→ 触发一次审批/提问/回合结束 → **不应**出现 ntfy 通知（App 自己弹本地通知）。
3. **验下发**：杀掉 App 进程 → 再触发一次 → 应收到 ntfy 通知；点通知经 `dshmobile://open?session=…` 直达会话。
4. **验可归因**：查 audit（`/api/mobile/audit-logs`）应有 `ntfy/push`：
   - 第 2 步看到 `outcome: "skipped"`, `reason: "app-connected"`, `liveClients: ≥1`
   - 第 3 步看到 `outcome: "sent"`, `status: 200`
   - 若失败：`outcome: "failed"` + `status`/`reason`，并带 `host` 与 `topicLength` 供比对；**任何一条都不应出现 token 或完整 topic**
5. **验用户须知**：设置 → 离线推送，应看到"还需要在手机上装一个 ntfy 客户端并订阅同一 topic"的四条说明。
