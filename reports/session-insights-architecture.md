# 会话内信息架构设计（撤销独立「任务」页）

- 任务：task-3（T3），作者：session-insights-arch
- 范围：只做设计，**本轮不修改任何源码**（`chat_view.dart` / `main_shell.dart` 一行未动，见文末改动清单待 Lead 冻结后派发）
- 基准用户：**重度手机远程操控 DSH 的人**——PC 上跑着 dsh web，人在外面用手机盯长会话、收产出、盯上下文余量、必要时终止跑飞的东西
- 用户定案（不讨论）：交付物 / 用量 / 本次变更本就该显示在**会话**里，且**只统计该会话**

---

## 0. 唯一推荐方案（一页结论）

**一句话**：删掉「任务」tab 和 `task_center_view.dart`；把这三类信息拆成**「事件进流、状态进头」**两层——交付物在本轮结束时以**消息流内的「本轮产出」卡片**出现（瞬时、锚在产出它的那一轮后面），三类信息的**常驻状态**压成 AppBar 下方一条**单行会话状态条**（`执行中 · 产出 3 · 改动 12 · 上下文 62%`，超出即隐藏），点它展开成**可滚动的底部信息面板**（用量/目标、交付物按轮分组、本次变更、后台作业、定时任务）。

| 信息 | 常驻形态 | 详情形态 | 不进会话的部分 |
|---|---|---|---|
| 交付物 | 流内「本轮产出」卡片（本轮结束瞬间）+ 状态条 `产出 N` | 面板内按轮倒序分组，默认展开最新一轮 | — |
| 用量 | 状态条 `上下文 62%`（>70% 才带 2px 进度线） | 面板顶部：本轮 ~N（客户端差分）、会话累计、used/window、下一轮预计、goal | 六格 token 看板（删） |
| 本次变更 | 状态条 `改动 N`（非 git 仓库整段隐藏） | 面板内文件清单，点开单文件 diff（迁移现有 `_DiffSheet`） | 常驻「不是 git 仓库」说明卡（删） |
| 后台作业 | 状态条 `运行中 N`（仅存在 live 作业时出现） | 面板内一行一个 + 终止（二次确认） | job 的 kind/progress/detail 长文本拼接（删） |
| 定时任务 | **不进流、不上状态条** | 面板最底部默认折叠的小节，仅「删除」 | 独立入口（不需要） |

底部导航回到 **4 个**：对话 / 工作区 / 安全策略 / 设置。

---

## 1. 判定原则：事件进流，状态进头

上一轮的错误不是"信息选错了"，是**信息放错了位置**：把 `sessionId` 域的信息放进了一个**不属于任何会话的页面**。用户在会话里产生了"这东西产出到哪了/这轮烧了多少"的疑问，却要跳出去、丢掉消息流上下文、再跳回来——而跳回来要重新加载历史。

由此定两条不可动摇的判定：

1. **事件进流（event → stream）**：回答"**刚刚**发生了什么"的信息，必须出现在消息流里它发生的位置。判据：这条信息在时间轴上有一个唯一正确的锚点。
2. **状态进头（state → header）**：回答"这个会话**现在**是什么样"的信息，进 AppBar 下方的常驻状态条；它必须能承受"重开 App 后仍然正确"，因此它的真值只能来自可重放的 REST 读取，不能依赖任何一次性 WS 帧。
3. **一次性的量不进头**：状态条只有一个屏幕宽度的信任额度——**任何一面"显示 0 / 显示未知"会产生误解的信息，都不许常驻**（这正是 `queueBadge` 那个缺陷的教训，见 §4）。

### 为什么不是另外四种形态

| 候选 | 判决 | 理由 |
|---|---|---|
| 会话顶部**就地可折叠**信息区 | ✗ 作为主形态 | 展开后把消息流整体下推，正在读的内容被顶走、滚动位置跳变；手机竖屏可用高度只有 ~640dp，这块还要和 AppBar（~56dp）抢位置。取它的**信息层级**，但不取它的**就地展开**：常驻只留 1 行，展开动作改成底部弹层 |
| **消息流里常驻**卡片 | ✗ 作为状态载体 | 状态不是事件，重开一次会话就"没了"；而且长会话会积累几十张卡片，把消息流塞满。只让**交付物**用它（它确实是事件） |
| **侧滑抽屉** | ✗ | ①盖住消息流，竖屏下用户要点着屏幕看内容对照；②与已有手势直接冲突——`main_shell.dart` 的 `PopScope` 已经把侧滑定义成"回工作区"，会话内再挂一个侧滑抽屉会让同一手势有两种含义 |
| **输入框上方**信息条 | ✗ 作为常驻形态，✓ 作为**阈值触发**形态 | 键盘弹起时这块空间被压到最紧，而这里恰好是"我要打字"的地方。唯一的例外是**上下文 ≥85%**：那是一个必须当场做的决策（继续会被截断 / 该新开会话），此时它值得占用一行；平时一行都不占 |
| **底部弹层** | ✓ 作为展开态 | `showModalBottomSheet(isScrollControlled: true)` 自带滚动，几十个交付物/变更不会挤压消息流；关掉即回到原来的滚动位置，无副作用。它不适合当**入口**（多一次点击才知道"有没有东西"），所以入口是状态条 |

**键盘规则（统一）**：状态条在 `appBar.bottom`，属顶部，键盘弹出时**不参与压缩**，所以"执行中/产出/上下文"在打字时依然可读——这是把状态条放顶部而不是放输入框上方的决定性理由。输入框上方只保留已有的队列 dock（它是"我要发的话"）与阈值压力提示。

---

## 2. (a) 三项信息的形态与取舍

### 2.1 交付物 → 流内「本轮产出」卡片（主）+ 状态条 `产出 N`（状态）

**用户什么时候真的需要看它**：在"agent 说做完了"那一刻——他等着的东西出现了，下一步动作是**把它拿到手机上**（下载/用系统应用打开/转发）。这个时刻在时间轴上就是**本轮 assistant 消息结束的位置**，所以卡片跟在那一轮后面是唯一不别扭的锚点。次要时刻是"过了一周我回来找这个会话产出了什么"——那是状态查询，交给状态条 + 面板。

**卡片的具体行为（关键，避免出现"锚在错的一轮"）**：

- 触发：当前会话收到 WS `deliverables` 帧（`index.js:1542-1557` 已存在），或 `done` 到达时确认本轮有交付。
- 渲染位置：`chat_view.dart` 的 `ListView.builder`（`:1923`）尾部追加第 `messages.length + activeApprovals.length` 项。
- **只在本轮尚未被"翻页"时显示**：显示条件是「最后一条消息是 assistant」且「此后没有新的 user 消息」且「本轮不是正在发送中」。用户一旦发出下一条消息，卡片自动消失（它已经不再是"刚刚发生的事"），记录转由状态条/面板承接。这条规则同时消灭了"卡片挂在错误的一轮后面"这个坑。
- 内容：标题「本轮产出」，最多 5 行（图标 + 文件名 + 描述），超出显示「还有 N 个」→ 打开面板。每行点按 = 下载并用系统应用打开（复用现有 `_openDeliverable` 逻辑，迁移到新文件）。
- 失败反馈**内联在卡片里**（一行红字 + 重试），不用 SnackBar：卡片就是用户刚看的地方，SnackBar 会在他视线之外消失。
- ⚠️ **卡片的行必须用 REST `GET /api/mobile/deliverables` 返回的 rows**（`path` 是网关解析后的**绝对路径**，`display` 才是给人看的相对名）。WS 帧里只有相对 `path` + `description`。若拿 WS 帧的 path 去请求下载，会被 `resolveDeliverable`（`features.mjs:138-145`，按绝对路径做**精确成员判定**）判 403——这正是 T1 在查的"点不开"这一类成因。帧只用来触发"有新东西了"，不当作数据源。
- 卡片**不**显示 diff、不显示用量：一轮结束时刻用户要的是文件，别的东西会把卡片撑成一张报表。

### 2.2 用量 → 状态条一个数字 + 面板里的三项（不是六格看板）

**用户什么时候真的需要看它**：只有两个场景。（1）**担心这轮烧太多**——发生在一轮结束时；（2）**怀疑快撞上下文上限**——这是一个**随时**可能冒出来的顾虑，所以它必须常驻可见，而"烧了多少"不需要。

所以：

- 状态条只显示 `上下文 62%`（来自 `pressureTokens / contextWindow`，`task_center.dart:277-282` 已有 `contextFraction`）。**>70% 时**在状态条下方加一条 2px 进度线（>85% 转 danger 色），这是"离上限还有多远"的一眼可读化。
- `≥85%` 时在**输入卡片内最上方**补一行 `上下文 92% · 建议新开会话`（带一个跳到新建会话的动作）。低于阈值一句话都不出现。
- 面板顶部三项：**本轮 ~N**（见下）、**会话累计 N**、**上下文 used / window**（有 `projectedTokens` 时补 `下一轮预计 M`）。**删除** `输入(未缓存) / 输出 / 缓存读 / 缓存写` 四格。
- **「本轮烧了多少」是客户端算出来的，不需要服务端改动**：`tokenUsage` 是**单调累计**的会话投影（`features.mjs:279-325`），所以在 `done` 时用 `totalTokens` 与上一次 `done` 记下的基线相减，就是这一轮的消耗。实现：service 里存 `_statsBaselineTokens`，每次 `done` 刷新基线。**仅当两次 `source` 都是 `'live'` 时才显示**；若为 `'cache'`（会话不在内存里，是最后一次上报的快照）则显示 `本轮 —`，绝不显示一个编出来的 0。

### 2.3 本次变更 → 状态条一个计数 + 面板清单 + 单文件 diff

**为什么它不能像交付物那样挂在"那一轮"后面**——这是一个必须讲清的数据事实：

`GET /api/mobile/workspace/changes`（`features.mjs:615-621` → `index.js:302-311`）返回的是**当前 git 工作树的未提交状态**，是**整个工作区的累计真值**，**没有 per-turn 归属**；引擎自己的 `workspace/changes` 事件只带一个轮号（`index.js:1559-1565`，注释明说快照留在 Host、无法回放给手机）。**「本轮改了哪些文件」这个数据在当前架构里不存在**。任何"把变更清单拆到每轮消息后面"的设计都是在编数据。

所以本次变更按**状态**处理：状态条 `改动 12`，点开在面板里看清单、点单文件看 diff。用户真正的工作流也支持这个判断——**他要审的是"现在工作区被改成什么样了"，而不是"第 3 轮改了哪两行"**；发现不对时他会去工作区页看文件。

- 非 git 仓库：`available=false` + `reason`（`index.js:302-311` 已正确降级）。**判决：可接受**。理由：引擎侧的变更快照不通过 RPC 暴露，要支持非 git 场景就必须新增服务端能力（引擎级快照 + 新路由 + 重启才能验），而收益只是"在一个本来就没有版本管理的目录里列文件"。**但必须改呈现**：状态条上**整段隐藏**（未知/不可用 ≠ 干净，显示"改动 0"是撒谎），面板里只保留一行说明文字，不再像现在这样常驻一整块说明卡（`task_center_view.dart:568-579`）。

### 2.4 状态条的精确形态与"未知"语义

```
[● 执行中] 产出 3 · 改动 12 · 上下文 62%
──────────────────────────────────  ← 仅 >70% 时出现的 2px 进度线
```

- 高度 ~34dp，放进 `appBar.bottom`（把现有 1px 分隔线并入同一次 `PreferredSize`）。
- 每一段都可点：`产出` → 面板滚到交付物；`改动` → 面板滚到变更；`上下文` → 面板滚到用量。
- **未知即隐藏**：`改动` 未成功拉过 → 不显示（而非显示 0）；`产出` = 0 时**显示**（0 是已知真值，且"这个会话没有产出"本身有价值）；`运行中 N` 仅在 `jobs.any(isLive)` 时出现。
- **强调色即"未读"**：`产出` 段在有新交付物且用户尚未打开面板时用 accent 色；打开面板（或点过卡片里的文件）后转为普通色。用内存里的 `Map<sessionId, acknowledgedSeq>` 记录，**不落盘**——重开 App 后再强调一次无害。
- 状态条自身必须是**独立的小 widget**（新文件 `session_status_strip.dart`）并内部用 `context.select` 只订阅三个标量，避免把任何新的计算塞进 `ChatView.build`（那个 build 里已经有约 20 处逻辑，且每次 `notifyListeners` 都会跑）。

---

## 3. (b) 后台作业 / 定时任务：进会话，但待遇不同

两者数据源都是 `sessionId` 域（`/api/mobile/jobs`、`/api/mobile/schedules`），按 §1 原则它们**属于会话**。但它们的"可行动价值"差一个数量级：

**后台作业 —— 进会话（状态条一段 + 面板一节）。**
理由：作业是"你没在看的时候还在继续跑"的东西。当前唯一的会话级活信号是 `session.isRunning`（由 WS `session_status` 维护）——**一个回合结束（`done`）之后，后台作业可能仍在跑**，此时状态条必须能说出这件事，否则用户会得出"它停了"的错误结论，然后关掉手机走人。这不是把 CLI 搬手机，这是真值：**手机上唯一能对作业做的动作（终止）是 CLI 做不到的**（你人在外面）。
反例（不做）：不把 `kind · progress · detail` 拼成一串显示（`task_center_view.dart:340-343`）——那段文本在 360dp 上多数不可读、且不可行动。面板里一行只放 `状态徽标 + label`，`detail` 折进点击展开。

**定时任务 —— 只进面板最底部的一个默认折叠小节，不进流、不上状态条。**
理由：`schedule/list` 返回的是"以后会被触发的东西"，它与**当前会话此刻是什么样**无关；用户设完基本不再看，唯一的动作是删除（`schedule/delete`）。它没有任何"需要在会话里被随时提醒"的时刻（真要触发时，它会作为一轮正常的 prompt 跑起来，并走已有的 `done` 通知）。把 `定时任务` 放进状态条 = 拿一个几乎永远是 0 的数字去挤状态条空间。

**结论：不需要任何独立入口。** 这两个都不需要单独页面：作业在"打开面板时才拉一次"（见 §4），定时藏在同一面板底部。它们**唯一可辩护的独立入口**形态是**跨会话总览**（"所有会话里还在跑的作业"、"今晚会自动跑的所有定时"）——那确实是会话内看不到的，但：
1. 网关当前**没有**全局 `jobs/schedules` 路由（只有 `sessionId` 参数版），要做就得新增服务端能力 + 重启才能验；
2. 用户这一轮的原始抱怨正是"什么都往那个新页面加"；
3. 跨会话的"有事在跑"已经有更好载体：**通知**（`done` / `approval_request` / `question_request` 都已推送）。

所以：**记为明确的非目标**，并写下触发条件——若用户日后真实反馈"作业跑完了我不知道"，正确做法是**给作业完成补一条推送通知**（服务端已有 ntfy 通道），而不是再长一个页面。

---

## 4. (c) 删除独立「任务」tab：导航、索引、角标

**判决：删除。** 底部导航回到 **4 个**：对话 / 工作区 / 安全策略 / 设置。

理由：这个 tab 装的全是**单会话**信息，它存在的唯一效果是让用户离开会话再回来；而且它一进页面就打 6 个请求（其中 2 个是全链路最贵的）。删掉它不是"少一个功能"，是**让功能回到能用的位置**。

### 索引与徽标（`main_shell.dart`）

- `:12` 删除 `import 'task_center_view.dart';`
- `:224-225` 从 `IndexedStack` 的 children 删除 `TaskCenterView(...)` 一项（`IndexedStack` 同时从 5 个子页变 4 个，`ChatView` / `WorkspacesView` / `SecurityPermissionsView` / `CustomSettingsView` 顺序不变）
- `:83-85` 删除 `else if (index == 2) { unawaited(dsh.refreshTaskCenter()); }`
- `:86` `_setIndex`：`index == 3` → `index == 2`（安全策略 → `fetchApprovals()`）
- `:88-90` `index == 4` → `index == 3`（设置 → `fetchSettings()`）
- `:216` `ChatView(onOpenSecurity: () => _setIndex(3))` → `_setIndex(2)`
- `:167` `canExit`：`_currentIndex == 1 || _currentIndex == 2`（工作区 / 安全策略）。**顺带修一处注释与代码不一致**：`:163-166` 的注释写的是"已经在工作区（或权限/设置页）时才放行为真正的退出"，但代码把设置页（旧 index 4）排除了。推荐直接写成 `canExit: _currentIndex != 0`，与注释对齐（设置页侧滑 = 退出 App）；若 Lead 想保持旧行为，用 `1 || 2`。
- `:143-147` 删除 `queueBadge` 的 `context.select`
- `:276-280` 删除「任务」`NavigationDestination`

### 角标数据来源缺陷：随 tab 一起消失，且**不需要**换个地方补

缺陷成因（可直接引用）：`jobs` 只有 `_setIndex(2)` → `refreshTaskCenter()` → `fetchJobs()` 这一条写入路径，而 `IndexedStack` 会保活子页，所以「任务」页一旦被访问过就再也不会刷新——**没进过 = 永远 0，进过 = 停在那一刻**（两个方向都错）。而且 `jobs` 没有任何 WS 事件驱动（`index.js` 的广播清单里没有 jobs），所以它注定会陈旧。

删掉 tab 后：
- 不做 jobs 的 tab 级角标。作业状态改为状态条上"仅存在 live 作业时出现"的一段 + 面板，**待作业不再有任何一个"看起来是 0 其实是未知"的数字**。
- `对话` tab 的角标保持 `pendingApprovals + pendingQuestions`（"agent 停下来等你"这个信号才是真正该在 tab 级出现的；`main_shell.dart:136-142` 已经有正确实现）。
- `排队消息` 不再需要 tab 角标：它在会话的输入框内（`_buildQueueDock`）和状态条上都有位置，而队列是**单会话**的——放在 tab 上反而误导（"哪个会话的队列？"）。
- 观测项（不在本轮做）：`工作区` tab 的角标用的是 `pendingCount`（审批数），与「安全策略」重复，语义上也不属于工作区。建议改为空或改为"有待授权操作的工作区数"，作为独立小修。

---

## 5. (d) 数据加载时机

### 5.1 先给成本口径（按服务端实现读出来的，不是猜的）

| 路由 | 服务端实现 | 成本档 |
|---|---|---|
| `sessions/queue` | `readProjections` 本地投影读（`features.mjs:495-501`） | **便宜**（无跨进程往返） |
| `session/stats` | 本地投影 + 投影缓存行（`features.mjs:643-650`） | **便宜** |
| `deliverables` | 一次 MUX RPC `session/page`（`maxMessages: 200`，`index.js:284-300`） | 中（一次跨进程往返） |
| `schedules` | 一次 MUX RPC `schedule/list`（`features.mjs:522-533`） | 中 |
| `workspace/changes` | **起 git 子进程**读工作树（`index.js:302-311`） | 贵，随仓库规模增长 |
| `jobs` | 打开一个 **stream Remote**，等首个整集帧，**超时 5s**（`features.mjs:550-560`） | **最贵/最慢** |

现状 = 进「任务」页 `Future.wait` 这 6 个（`dsh_service.dart:2528-2537`）：最贵的两个（jobs、changes）被放在最频繁的动作上。

### 5.2 唯一推荐方案：三档

**第一档｜进会话立即（首帧正确性所需，2 个，都便宜、都不跨进程）**
`fetchSessionStats()` + `fetchQueue()`。
改法：`dsh_service.dart:1047-1054`（`selectSession` 的 `finally`，现在只有 `unawaited(fetchQueue())`，`:1052`）→ 改为并发这两个。状态条首帧立刻有 `上下文 62%`，队列 dock 立刻有内容。

**第二档｜进会话后紧接一次（可取消，2 个，串行，不阻塞首帧）**
`fetchDeliverables()` → `fetchWorkspaceChanges()`。
理由：它们决定状态条的 `产出 N` / `改动 N`，必须在进会话后不久就正确（不能等用户点开面板——那就是回到了"要跳出去才知道"的老问题）；但首帧晚 100~300ms 无感，所以放在第一档之后串行、**并用现有的 `_sessionLoadSeq` 守卫**：切会话时结果直接丢弃。
总账：进会话 = 4 个请求，其中**只有 1 次 MUX 往返 + 1 次 git 子进程**，最贵的 jobs 与 schedules 被完全移出。

**第三档｜只在面板打开时懒加载（2 个，最贵的两个）**
`fetchJobs()` + `fetchSchedules()` —— 仅在 `SessionInfoSheet` 打开时拉一次；作业终止 / 定时删除后再各刷一次；面板自带一个手动刷新图标。关掉面板不再有任何请求。

### 5.3 事件驱动（复用已有信号，零新增服务端工作）

| WS 事件 | 动作 | 备注 |
|---|---|---|
| `deliverables`（`index.js:1542`） | `fetchDeliverables()` + 置「本轮产出」卡片待显示标记 + 状态条 `产出` 立即强调 | 已有调用（`dsh_service.dart:3027`），保留 |
| `workspace_changes`（`index.js:1559`） | **只置 `_changesDirty = true`，不在轮内拉** | ⚠️ 现在的 `:3029` 直接拉变更 = 每轮至少一次 git 子进程；而这个事件在轮内可能多次到达，且轮内的 git 状态会随着 agent 写文件中途抖动，数字没有意义 |
| `done` / `end` | `fetchSessionStats()`（刷新"本轮 ~N"基线）+ `fetchQueue()`（已有 `:3088`）+ 若 `_changesDirty` 则 `fetchWorkspaceChanges()` | 一次回合最多 1 次 git，且发生在轮末——正是"本次变更"有意义的时刻 |
| `session_status(isRunning)` | 只驱动状态条的执行中态 | 已有数据，无请求 |

### 5.4 三条硬性纪律

1. **离开会话不得继续轮询。** 所有新增读取都是"进会话触发一次 + 事件触发一次"，**不带任何 `Timer.periodic`**。不复制 `WorkspacesView` 那种轮询（它已用 `active: _currentIndex == 1` 正确约束，可作为模式参照）。
2. **切会话必须丢弃在途结果。** 这是**现存缺陷**，必须一起修：`fetchDeliverables`（`:2332-2353`）、`fetchWorkspaceChanges`（`:2366-2389`）、`fetchSchedules`、`fetchJobs`、`fetchSessionStats` 都在开头读 `_currentSession?.sessionId`、结尾**无条件**写 `_deliverables` / `_workspaceChanges` / …，**完全没有** `_sessionLoadSeq` 守卫（只有历史加载 `:1043-1048` 有）。快速切 A→B 时，A 的交付物/变更会显示在 B 的会话里——这比"多打几个请求"严重得多，且会直接把用户指向错的下载项。改法：`final seq = _sessionLoadSeq;` + 写回前 `if (seq != _sessionLoadSeq) return;`。
3. **应用进后台不发请求。** 事件驱动的部分天然停止（没有 WS 帧就没有动作）；`handleAppPaused` 已有；新增代码不得引入任何"回到前台就拉 6 个"的行为（`handleAppResumed` 只做重连与通知消费）。

### 5.5 明确不做（附触发条件）

不新增 `/api/mobile/session/overview` 聚合路由。3~4 个并行小请求在手机上多花的是 RTT，而现在的实际部署是手机经隧道访问 PC，RTT 是本方案的已知成本；但新增路由意味着**必须重启 dsh web 才能验证**（当前硬规则禁止），且会与现有 6 条会话域路由形成两套真值。**触发条件**：若实测弱网下第一+第二档合计 > 800ms 或明显影响首帧，再做聚合路由（届时它应当是纯投影读取，不含 git 与 MUX 往返）。

---

## 6. (e) 诚实审计：哪些是"为完成任务而完成"

### ① 用量看板的六格指标 —— **是，最典型的一项**
`task_center_view.dart:213-227` 展示了 `总 token / 输入(未缓存) / 输出 / 缓存读 / 缓存写 / 上下文占用`。一个重度手机用户能用这六个数字做什么？只有三个真实决策：**继续 / 新开会话（或压缩）/ 放弃**。而这三个决策只依赖两个信息——**离上下文上限还有多远**、**这轮是不是特别贵**。`缓存读 / 缓存写` 是提供方的计费口径（对用户 100% 不可行动），`总 token` 是**会话累计**（不是他问的"这轮"）。
→ **做法**：状态条只留 `上下文 X%`；面板留三项（本轮 ~N / 会话累计 / used·window，补 projectedTokens）；删掉四格；`source == 'cache'` 时明确标注"快照值"（`:247-249` 已有正确做法，保留）。

### ② 非 git 仓库没有变更视图 —— **可接受，但呈现方式要改**
理由见 §2.3。数据源限制是真实的（引擎快照不可回放，`index.js:302-311` 的注释已写明），为它造服务端能力不划算。**不可接受的是现在的呈现**：一块常驻的"这个工作区不是 git 仓库"说明卡（`:574-577`）会在**每一个**非 git 会话里永久占位，而这信息用户只需要知道一次。→ 状态条整段隐藏，面板留一行。

### ③ 交付物列表"最新一轮优先" —— **需要，且现在只做了一半**
网关照 `seq` 倒序返回（`features.mjs:124`），所以排序已经是对的；缺的是**分层**：一个长会话可能声明过几十个文件，而用户在手机上一次只看得下 5~8 行，他 99% 要的是**刚给他的那批**。`DeliverableItem.turn` / `seq` 已经在数据里（`task_center.dart:36-37`），但**模型没有解析网关已经返回的 `time`**（`features.mjs:120`），UI 也没有按 `turn` 分组。
→ **做法**：面板里按 `turn` 倒序分组（「第 N 轮 · 3 个文件」），**默认只展开最新一轮**，其余折叠；`turn` 为 null 的归入「未知轮次」。流内卡片同样只显示最新一轮（最多 5 个）。

### ④ 作业 / 定时的可视化是不是把 CLI 输出搬到手机 —— **作业：部分是，定时：基本是**
- **作业**：`job/list` 的原样呈现（`状态 + label + kind·progress·detail` 拼接）确实是搬运。但其中**两件事在手机上真的可行动**：知道"它还在跑"（否则你会误判回合结束=全部结束）和"终止它"（PC 不在手边）。→ 保留 `状态 + label + 终止`，砍掉 progress/detail 的拼接行。
- **定时**：`schedule/list` 的呈现就是搬运，且唯一动作是删除、删除后不影响当前会话任何状态。→ 降到面板最底部默认折叠的小节，不上状态条、不给计数。

---

## 7. (f) 精确改动清单

> 本轮**未改动**任何源码。以下为冻结后派发用的清单。文件路径相对项目根 `E:\workspace\个人\dsh_mobile`。

### 7.1 删除
- `dsh_mobile/lib/views/task_center_view.dart`（737 行，整体删除）

### 7.2 新增
| 文件 | 内容 |
|---|---|
| `dsh_mobile/lib/views/widgets/session_status_strip.dart` | 单行状态条（≤34dp）：执行中徽标 / `产出 N` / `改动 N` / `上下文 X%` + 阈值进度线；每段可点开面板；内部 `context.select` 只订阅 3 个标量 |
| `dsh_mobile/lib/views/widgets/session_info_sheet.dart` | 底部信息面板（`isScrollControlled: true`）：用量与目标 / 交付物（按轮分组）/ 本次变更 + `_DiffSheet`（从 `task_center_view.dart:626-736` 迁移）/ 后台作业 / 定时任务（默认折叠）；负责第三档懒加载 `jobs` + `schedules` |
| `dsh_mobile/lib/views/widgets/turn_output_card.dart` | 流内「本轮产出」卡片；含内联失败态；点行 = 下载 + 原生打开（迁移 `_openDeliverable` 逻辑） |

### 7.3 `dsh_mobile/lib/models/task_center.dart`
- `:31-53` `DeliverableItem` 增加 `final int? time;` 并在 `fromJson` 解析 `json['time']`（网关已返回，`features.mjs:120`）
- 新增 `int? get latestTurn` / `static List<List<DeliverableItem>> groupByTurn(...)`（倒序、null 归末组）

### 7.4 `dsh_mobile/lib/services/dsh_service.dart`
- `:2528-2537` `refreshTaskCenter()` → 拆为
  - `fetchSessionOverview()`：`Future.wait([fetchSessionStats(), fetchQueue()])`（第一档）
  - `fetchSessionSecondary()`：顺序 `await fetchDeliverables(); await fetchWorkspaceChanges();`（第二档）
  - `fetchSessionExtras()`：`Future.wait([fetchJobs(), fetchSchedules()])`（第三档，仅面板调用）
- `:1047-1054` `finally` 内 `unawaited(fetchQueue())` → `unawaited(fetchSessionOverview()); unawaited(fetchSessionSecondary());`（第二档可被后续 `_sessionLoadSeq` 失效丢弃）
- `:2332` / `:2366` / `:2415` / `:2460` / `:2506` 五个 fetch 各加 `final seq = _sessionLoadSeq;` 与写回前 `if (seq != _sessionLoadSeq) return;`（§5.4-2，修现存跨会话串数据缺陷）
- `:2506-2525` `fetchSessionStats()` 结尾记录 `_statsBaselineTokens`（本轮 delta，仅 `source=='live'`）；新增 `int? get lastTurnBurnTokens`
- `:3019-3032` `workspace_changes` 分支：由"立即 `fetchWorkspaceChanges()`"改为"置 `_changesDirty = true`"
- `:3086-3088` `done` 分支：追加 `unawaited(fetchSessionStats());` 与 `if (_changesDirty) { _changesDirty = false; unawaited(fetchWorkspaceChanges()); }`
- `:2310-2329` `debugSetTaskCenter` 保留（加 `statsBaseline` 注入口）；`refreshTaskCenter` 的旧名字在改完后不再被引用，一并删除
- 删除其余以「任务页/任务中心」为名的注释（`:726`、`:2118`、`:2283`、`:2527`），避免实现者按注释去找已删除的页面（这些是注释，不是代码路径）

### 7.5 `dsh_mobile/lib/views/chat_view.dart`（**T2 拥有写权，本轮未动**）
- `:1505-1508` `appBar.bottom` 的 `PreferredSize(height: 1)` → `PreferredSize(height: 1 + 34)`，1px 分隔线之下内嵌 `SessionStatusStrip()`
- `:1928` `itemCount: dsh.messages.length + activeApprovals.length` → `+ (_showTurnOutput ? 1 : 0)`；`:1960` 之后新增尾部条目分支渲染 `TurnOutputCard`（显示条件见 §2.1，由 chat 侧状态 `_showTurnOutput` 控制）
- `:2733-2737` 输入卡片内、`_buildQueueDock` **之上**新增阈值压力行（仅 `contextFraction >= 0.85`）
- `:3023-3092` `_buildQueueDock`：唯一一处**用户可见**的失效指向是 `:3085` 的字符串 `'还有 ${rows.length - 3} 条（在「任务」页查看全部）'` → 改为 `'还有 N 条'` + 可点开 `SessionInfoSheet` 的队列段；`:3052-3053` 是解释性注释（"剩下的去「任务」页看"），随同一处一并改文字
- 新增方法：打开信息面板（供状态条各段与队列 dock 调用）
- 注意：`chat_view.dart:28` 的 `import '../models/task_center.dart'` 需要继续保留（队列/交付物模型仍在用）

### 7.6 `dsh_mobile/lib/views/main_shell.dart`（**本轮未动**）
见 §4 的逐行清单（`:12` `:83-85` `:86` `:88-90` `:143-147` `:167` `:216` `:224-225` `:276-280`）。

### 7.7 测试
| 文件 | 动作 |
|---|---|
| `dsh_mobile/test/widgets/queue_and_task_center_test.dart` | `:145-221` 的「任务页」group 整体重写：`TaskCenterView` → `SessionStatusStrip` + `SessionInfoSheet`（未知即隐藏、非 git 隐藏 `改动` 段、交付物按轮分组默认展开最新一轮、作业省略长文本）；`:72` 的"其余提示去任务页"文案断言同步改。文件名建议改为 `queue_and_session_insights_test.dart` |
| `dsh_mobile/test/models/task_center_test.dart` | 增加 `time` 解析与 `groupByTurn`（含 `turn` 全为 null、混合 null）用例 |
| 新增 `dsh_mobile/test/widgets/session_status_strip_test.dart` | 三段独立显示/隐藏、>70% 进度线、`产出` 未读强调色、点段打开面板 |
| 新增 `dsh_mobile/test/widgets/turn_output_card_test.dart` | 只显示最新一轮、超 5 行折叠、下载失败内联红字、用户发出下一条消息后消失 |
| 新增 `dsh_mobile/test/services/session_overview_load_test.dart` | 第三档懒加载（不进会话不拉 jobs/schedules）、`_sessionLoadSeq` 串会话丢弃、`done` 触发 stats 与 changes、`workspace_changes` 轮内不拉 git |
| `tests/unit/features.test.mjs` | 网关无改动，`deliverables` / `jobs` 既有用例（`:79-110`、`:344-385`）继续作为数据形状回归 |

### 7.8 命令
- 项目根：`node --test tests/unit/features.test.mjs`
- `E:\workspace\个人\dsh_mobile\dsh_mobile`：`D:\flutter\bin\flutter.bat test`（`rg` / `flutter` 不在 PATH，用全路径）

### 7.9 明确非目标
不做跨会话统计/全局看板；不做"本轮改了哪些文件"（数据不存在）；不做 `/session/overview` 聚合路由（触发条件见 §5.5）；不为作业做 tab 级角标（正确载体是通知）；不改任何网关路由（本轮冻结为**纯客户端改动**，因此**不需要重启 dsh web**）。

---

## 8. 依赖、风险与未验证项

1. **硬依赖 T1**：卡片与面板的行都复用同一条打开链路（`deliverableUrl` → `GET /download` → `MethodChannel` → `openBytes`）。T1 未修好之前，新形态的"点开"会继承同一个 bug。**顺序上必须先有 T1 的根因结论，再实现卡片**（否则会把失败点从"任务页"搬到"会话里"，看起来更糟）。
2. **chat_view.dart 与 T2 冲突**：§7.5 的改动（尤其输入卡片内新增一行压力提示）与 T2 的运行中投递改造落在同几行（`:2712-2743` 输入卡片、`:3019-3092` 队列 dock）。**必须串行**：建议 T2 先改完输入卡片结构，再叠加状态条与卡片（状态条在 AppBar、卡片在 ListView，两处都不与 T2 重叠）。
3. **未在活实例上验证**（按硬规则不重启、不造测试会话）：本报告的**数据形状结论**全部来自源码与单测夹具（`tests/unit/features.test.mjs:79-110`、`:344-385`），未对运行中的网关做过只读探测。因此"进会话 4 个请求"的**延迟**结论是成本排序推断，不是实测数字——§5.5 的聚合路由触发条件就是为此留的口子。
4. **状态条的"未读"语义**为内存态，重开 App 会重新强调一次；若用户觉得吵，再考虑落盘（`StorageService` 已有同类模式）。
5. **`done` 的 stats 基线**依赖 `source == 'live'`；会话不在内存（冷会话）时"本轮 ~N"显示 `—`，这是刻意的诚实降级。
