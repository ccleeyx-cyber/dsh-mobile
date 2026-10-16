# 运行中投递语义重设计：默认排队 + 二次确认才插话

- 任务：task-2（T2）
- 作者：queue-steer-ux（交互设计评审）
- 审查对象：上一轮 v1.13「运行中排队 / 插话」实现（`main` 工作副本，行号均为改动前）
- 路径约定：`dsh_mobile/...` 相对于 git 仓库根 `dsh_mobile/`；引擎引用相对于 `C:\Users\Administrator\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh\`（只读核对）
- 本阶段**未改动任何源码**，尤其未动 `chat_view.dart`（T3 写冲突文件）

---

## 0. 结论（先读这一段）

1. **方向反了。** 上一轮做的是「一个常驻开关，让用户在两个危险等级之间预选」，用户要的是「默认永远安全 + 显式升级一次」。这两者不是同一个东西，前者必然产生「用户忘了它还停在插话」的失效场景。
2. **唯一推荐方案：删掉投递模式这个概念。** 运行中发送**恒为排队**，不持久化、不记忆、无开关。「立即插话」只保留一个入口——**队列条目上的文字按钮**，且必须**二次点击**确认。发送键永远只做发送，停止键移到独立位置。
3. **投递语义不需要改后端。** 网关 `dsh-server-plugin/lib/index.js:2826` 已经是 `jsonBody.mode === 'steer' ? 'steer' : 'queue'`，「默认排队」在后端天然成立。上一轮的问题 100% 在客户端：把一个本应是一次性决策的投递动作，做成了跨会话、跨重启的持久状态。
4. **"插话置灰"也不需要改后端**（回答了 Lead 的猜测）：`features.mjs:31-63` `selectQueueRows` **只返回 `inbox['next-turn']`**，所以对手机可见的每一行，引擎侧 `target === 'next-turn'` 恒成立；唯一有效判据就是 `agent.status === 'running'`（客户端 = `dsh.isSessionRunning`）。详见 2.3。
5. **但有一处必须改后端，而且比"target"严重**：引擎的结构化错误码（`session/steer-unavailable`、`session/queue-item-not-found`）在 `dsh-server-plugin/lib/core.mjs:161-162` **就被丢掉了**，网关和手机都拿不到。所以"这一轮刚好跑完了"这种正常时序在手机上会被报成红色失败。修复点见 3.6。Lead 担心的 `[object Object]` **当前不会发生**（`error` 是字符串），但客户端 `.toString()` 是脆弱点。详见 1.8。
6. **顺带审的结论：这一项上一轮确实主要是为交差。** 功能面铺得比用户需求宽（持久化 + 网关协议 + 测试组），但没有一处是"用户实际会遇到的路径"的推演；用户的原话是准确的。详见第 4 节。
7. 有一件事上一轮**做对了**，不需要改：停止键只在 `dsh.isSending`（本机发起）时出现（`chat_view.dart:3239`），所以"手机旁观点一下就停掉电脑端的活"这条**不成立**。见 1.3。

---

## 1. (a) 现有实现的具体失效场景

### 1.1 ⛔ 常驻开关静默改变"下一次发送"的含义（严重度：高，正是用户抱怨的那条）

**代码位置**

- `dsh_mobile/lib/views/chat_view.dart:3298-3339` `_buildDeliveryModeChip`：`if (!dsh.isSessionRunning) return const SizedBox.shrink();` —— 开关**只在回合跑起来之后**才出现。
- `dsh_mobile/lib/views/chat_view.dart:2878`：这枚开关挂在操作行里，紧邻发送键。
- `dsh_mobile/lib/services/dsh_service.dart:2150` `deliveryMode` getter、`2152-2158` `setDeliveryMode` **写 SharedPreferences**。
- `dsh_mobile/lib/services/storage_service.dart:69-79` `dsh_delivery_mode` 的读写。
- `dsh_mobile/lib/services/dsh_service.dart:610` `await loadDeliveryMode();` —— **每次启动都读回来**。

**复现步骤**

1. 手机上打开一个会话，发起一轮长任务（要跑几分钟）。
2. 此时操作行出现「排队」开关，点一下变成「插话」（`chat_view.dart:3306` 立刻 `setDeliveryMode('steer')`，落盘）。
3. 这一轮跑完。开关消失（`3299` 直接 `SizedBox.shrink()`）——**用户看不到任何"我还停在插话"的痕迹**。
4. 关掉 App 再打开，或切到另一个会话，明天再来。
5. 用户在这个会话里开始打字。**打字时开关不存在**（会话空闲），输入框里没有一句话提示投递方式。
6. 电脑端（或另一个客户端）发起了新一轮，手机顶栏出现「执行中」徽标，**开关同时突然出现，而且已经是「插话」态**（因为第 2 步落盘了）。
7. 用户按习惯直接点发送 —— 这条消息以 `mode:'steer'` 投出去，插进了正在跑的回合。用户全程没有做过任何"我现在要打断"的决定。

**为什么这是设计缺陷而不是 bug**：`chat_view.dart:3299` 的注释说"只在会话跑着的时候出现：空闲时这枚开关没有任何作用"，但恰恰相反——它**在空闲时最需要出现**（那是用户准备输入的时刻），而有作用的那一刻（用户点发送前）它只是一个 13px 图标 + 11.5px 文字的胶囊，和旁边的模型胶囊、麦克风、发送键同色系，不构成任何"当前状态是危险的"警示。

### 1.2 ⛔ 同一个位置承担两个相反语义 → 误取消自己的回合（严重度：高）

**代码位置**

- `dsh_mobile/lib/views/chat_view.dart:3234-3292` `_buildSendButton`：
  - `3239`：`if ((dsh.isSending || dsh.isCanceling) && !canSend)` → 返回**停止键**（`3251` `dsh.cancelActiveTurn()`）。
  - `3269-3289`：否则返回**发送键**。
- `dsh_mobile/lib/views/chat_view.dart:3230-3233` 的注释已经自认踩过这个坑：

  > ⚠️ 整个判断必须包在 ValueListenableBuilder 里。最初把 `hasDraft` 写在函数开头……于是"敲了字按钮还是停止键"，点了就等于取消自己的回合。这个 bug 由 widget 测试抓到。

**这里只修了「重建时机」，没修「同一个位置在两种状态下做相反的事」这个根因。** 输入框被清空并不只有"用户手动删掉"一种途径：

- `chat_view.dart:1468-1479`：切换会话时直接覆盖 controller —— `_inputController.text = restored;`（`1477`）。若目标会话草稿为空，输入框无条件被清空。
- `chat_view.dart:2672-2680` `_redoHoldTalk`：`_inputController.clear();`（`2673`）。
- `dsh_service.dart` 里 `updateDraft('')` 路径同样会清草稿。

**复现步骤（误取消）**

1. 手机上发起一轮耗时任务，输入框此时为空 → 按钮是**停止键**（这是预期行为）。
2. 用户在输入框里打了一段话准备排队发出去。
3. 在没点发送的情况下，切到侧栏另一个会话、再切回来（或点一次「重录」）。
4. `chat_view.dart:1477` 把输入框覆盖为目标会话的草稿；若为空则输入框变空，而回合仍在跑。
5. 按钮**在没有用户任何输入动作的情况下**变回停止键；位置没变、形状没变（只是图标从 ↑ 变成 ■）。用户回神后点了一下刚才那个位置 → `3251` `cancelActiveTurn()` → **自己把正在跑的活取消了，还丢掉了一整轮的进度**。

**关键点**：上一轮补的 widget 测试（`queue_and_task_center_test.dart:131-142`）只覆盖了"进入文字 → 停止键变发送键"这一条正向路径，没有覆盖"输入框被外部清空 → 发送键变回停止键"，所以这个坑在测试里看不出来，在真机上依然存在。

### 1.3 ✅（做对了）多客户端：手机旁观不会误停电脑端的活 —— 但投递方式仍然是错的

**代码位置**

- `dsh_mobile/lib/services/dsh_service.dart:365-371`：`isSessionRunning => _isSending || (_currentSession?.isRunning ?? false)`，注释明确说"会话是电脑端发起、手机只是在看"也算在跑。
- `chat_view.dart:3239` 停止键用的是 **`dsh.isSending`**（本机发起），**不是** `isSessionRunning`。

**结论**：手机旁观电脑端的回合时，空输入框看到的是**置灰的发送键**，不是停止键。所以"手机一按就停掉电脑端的活"这条**不成立**，这一点上一轮是对的，不要改。

**但多客户端下依然有两个真问题**：

1. **投递方式是手机本地的、且全局持久化的**（`storage_service.dart:69` 是单一 key，不带 sessionId）。电脑端完全不知道手机被设成了插话。手机上任何一次"插话"会把 `dsh_delivery_mode=steer` 留下来，此后**所有会话**（包括电脑端正在跑的、手机只是旁观的）默认都走插话。
2. **旁观态也在渲染危险控件**：`_buildDeliveryModeChip` 判的是 `isSessionRunning`（包含"别人在跑"），所以手机在看别人跑的时候也能把模式切成插话，且这个切换没人会知道。队列行的「立即插话」（`chat_view.dart:3076`）同理，判的也是 `isSessionRunning` —— 手机可以对**电脑端发起的回合**执行插话。

### 1.4 ⛔ 队列条目的「立即插话」是一次点击直达，且有误触邻键（严重度：高，直接违反用户"要再点一次"的要求）

**代码位置**

- `dsh_mobile/lib/views/chat_view.dart:3069-3077`：三个按钮依次排开，间距只有一个 `SizedBox(width: 4)`：

  ```dart
  _queueIconButton(Icons.edit_outlined, '编辑', () => _editQueueRow(dsh, row)),
  _queueIconButton(Icons.close_rounded, '删除', () => _removeQueueRow(dsh, row)),
  _queueIconButton(
    Icons.bolt_rounded,
    '立即插话',
    dsh.isSessionRunning ? () => _steerQueueRow(dsh, row) : null,
  ),
  ```

- `dsh_mobile/lib/views/chat_view.dart:3094-3110` `_queueIconButton`：`Padding(EdgeInsets.all(4))` + `Icon(size: 16)` → **触摸区 24×24 dp**（Material 最低建议 48×48 dp）。
- `dsh_mobile/lib/views/chat_view.dart:3119-3124` `_steerQueueRow`：`HapticFeedback.mediumImpact(); final ok = await dsh.queueAction(row.id, 'steer');` —— **没有任何确认，一次点击就把一条正在排队的消息插进运行中的回合**。

**复现步骤**

1. 跑一轮长任务，期间发 2-3 条消息排队（`chat_view.dart:3039` 显示"3 条排队消息"）。
2. 用户想删掉第 2 条 → 点最右边的关闭图标。
3. 手指偏移 4px，落在紧邻的 ⚡ 上（两键中心距 28px，触点 24px）。
4. 第 2 条消息**立刻**被插进正在跑的回合（`chat_view.dart:3121`），只回一个 2 秒的 toast（`3123`）。用户以为自己删掉了它。

**注意**：这里的危险等级**高于**发送键。发送键误发只是多排一条消息；这里的误触会**改变正在执行的任务的上下文**（引擎会把它当作 `steering` 注入最近的步骤）。

### 1.5 ⛔ 空输入框 → 停止键 / 队列浮层：渲染在输入卡片内部会挤掉消息区（严重度：中）

**代码位置与真实布局**

- `chat_view.dart:1706`：`body: Column(...)`；`1855` 是**唯一**的 `Expanded`（消息列表）；`2034` `_buildInputBar(dsh)` 是它的**兄弟节点，高度不设上限**。
- `chat_view.dart:2712-2736`：输入卡片是 `Container` → `SafeArea` → `Container` → `Column(mainAxisSize: min)`，内部自上而下叠了：**队列面板（`2737`）+ 待发附件（`2740`）+ 模板 chips（`2743`）+ 文本框 + 操作行**。
- `chat_view.dart:3019-3092` `_buildQueueDock`：最多 3 条（`3054` `rows.take(3)`），每条的 `Text` 允许 `maxLines: 2`（`3063`），外加标题行与"还有 N 条"行。

**所以"会不会被键盘遮挡"这个问法本身是错的**：`Scaffold` 默认 `resizeToAvoidBottomInset: true`，输入卡片始终浮在键盘之上、不会被遮挡；**被挤压的是消息列表**。在 360×640 dp 的小屏上，键盘约 280dp，输入卡片在"3 条队列 + 2 个附件 + 1 行模板 + 5 行文本"时可达 250dp 左右，留给对话历史的只剩几十像素。用户此时**看不到 agent 在做什么**，而这恰恰是"要不要插话"这个判断唯一需要的证据。

**这是结构性缺陷，不是参数问题**：会话级信息（队列）被放进了输入控件内部，而输入控件在纵向是无上限的。

### 1.6 ⚠️ 回执文案与真实投递模式可能不一致（严重度：低，但会误导）

- `chat_view.dart:419` 先在调用前读一次 `final mode = dsh.deliveryMode;`
- `dsh_service.dart:2259` 在**请求体内**再读一次 `'mode': _deliveryMode`

两次读之间隔着 `await`（最多 20s 超时）。用户在等待期间点一下那枚开关，`chat_view.dart:423` 的 toast（"已插话发送"/"已加入队列"）说的和线上实际带走的 mode 可以相反。

### 1.7 ⚠️ 文案与引擎真实语义不符

- UI：`chat_view.dart:3302` Tooltip `'插话：打断当前回合立刻看这句话'`。
- 引擎：`dsh-api-session-controller/lib/index.js:882` `if (request.mode === "steer") agent.steer(message);`、`883` `else agent.followup(message);`
  → `steer` = **在最近的一个步骤边界把消息插进去**（best-effort，"nearest step"），**不是**取消/打断本轮；`queue` = `followup`，排在当前回合之后。
- 另外 `dsh-api-session-controller/lib/index.js:966`：

  ```js
  if (request.action.kind === "steer" && (target !== "next-turn" || agent.status !== "running"))
      throw new RemoteError("session/steer-unavailable", "current turn no longer accepts steering", { itemId });
  ```

  `session/steer-unavailable` 的真正含义是"**这一轮刚好跑完了**"，属于正常时序，不是错误。而 `chat_view.dart:3123` / `dsh_service.dart:2224-2229` 把它当普通失败 toast（`'插话失败'`），品牌色用红；`queueAction` 甚至不解析响应里的 `code`，UI 无法区分"网络失败"和"本轮已结束"。

### 1.8 ⛔ 引擎错误码在网关 RPC 边界就被丢掉了 —— UI 无法区分「本轮已结束」和「网络失败」（严重度：中高，链路已核实）

Lead 要求核实"错误是对象还是字符串、UI 会不会显示 `[object Object]`"。**核实结论：当前不会出现 `[object Object]`，但错误码（`code`）在更上游就已经丢失**，这比对象/字符串问题严重。

三层链路逐一核实：

**第 1 层 —— RPC 边界（问题真正的位置）**：`dsh_mobile/dsh-server-plugin/lib/core.mjs:128-168` `callDshRpc`

```js
// core.mjs:156-166
const parsed = JSON.parse(data);
if (parsed.result && parsed.result.ok === true) {
  resolve(parsed.result.value);
} else {
  const err = (parsed.result && parsed.result.error) || { message: 'RPC Error: ' + data };
  reject(new Error(err.message || JSON.stringify(err)));   // ← 只保留 message
}
```

引擎的 `RemoteError` 是结构化对象（`{ code: 'session/steer-unavailable', message: '...', details: { itemId } }`，见 `dsh-api-session-controller/lib/index.js:966`），但这里 `reject` 出去的是一个**普通 `Error`，`code` 与 `details` 被丢弃**，只剩下 `message` 文本。
⇒ **网关的任何路由都不可能转发引擎错误码**，因为到它们手里时已经没有了。（`index.js:2674` 的 `err?.code` 是 Node 的 `EADDRINUSE` 之类，见 `index.js:3465`，不是引擎码。）

**第 2 层 —— 路由出口**：`dsh_mobile/dsh-server-plugin/lib/features.mjs:515-517`

```js
} catch (err) {
  sendJson(502, { ok: false, code: 502, error: err?.message || 'queue update failed' });
}
```

- `error` 是**字符串**（`err.message`，`Error` 会把 message 强制成字符串）→ **不会出现 `[object Object]`**。Lead 这条担心不成立。
- 但它把 `code` 写成了 HTTP 语义的 `502`，引擎的 `session/steer-unavailable` / `session/queue-item-not-found` 完全没有出口。
- `/api/mobile/sessions/prompt` 同理：`index.js:2900` `sendJson(500, { ok: false, error: err?.message || 'Prompt execution failed' })`。

**第 3 层 —— 客户端**：`dsh_mobile/lib/services/dsh_service.dart:2224-2229`

```dart
var msg = 'HTTP ${res.statusCode}';
try {
  final data = jsonDecode(utf8.decode(res.bodyBytes));
  if (data['error'] != null) msg = data['error'].toString();   // ← 隐患
} catch (_) {}
```

- 今天 `data['error']` 是字符串，`.toString()` 是恒等操作，**不会**变成 `[object Object]`。
- 但这个 `.toString()` 意味着**一旦网关改成 `error: err`（对象）就会退化成 `[object Object]`**。属于"现在没事、改一行就出事"的脆弱点。

**对设计的直接约束**：2.5 那张表里"`session/steer-unavailable` 不当失败、`queue-item-not-found` 静默收敛"这两条**在当前网关下无法实现**（UI 拿不到 code，只能去对错误文本做字符串匹配 —— 那是不可接受的实现）。所以要落地这两条，必须先修 `core.mjs:161-162` 与 `features.mjs:516`，见 3.6。**这是本次唯一需要网关改动的地方，且与 `target` 无关。**

---

## 2. (b) 重设计（唯一推荐方案，不提供选项）

### 2.0 设计原则

> **投递方式不是"状态"，是"每一次发送时的决策"。** 默认决策永远是排队，无法被记住、无法被预置；插话是一次显式的、需要二次确认的升级动作。

### 2.1 删除全局投递模式（含持久化记忆）

- 从 UI、服务层、持久化层**全部删除** `deliveryMode` / `setDeliveryMode` / `loadDeliveryMode` / `dsh_delivery_mode` / `_buildDeliveryModeChip`。
- 运行中发送**恒为** `mode: 'queue'`，无例外、无开关、无快捷键。
- **要不要保留"上次选择"的记忆？结论：不保留。** 理由：
  1. **与用户的要求直接冲突。** 用户要的是"默认"。任何形式的记忆都会让"默认"在下一次变成 `steer` —— 那就不是默认，是"上次的残留"，而这正是 1.1 那个失效场景的成因。
  2. **收益极小。** 插话是高成本、低频动作（打断正在执行的任务），而记忆节省的只是"一次点击"。用误打断的风险换一次点击，不划算。
  3. **真正的插话入口在队列条目上**（见 2.3）。用户想插话时那条消息**已经**在队列里，成本是「点一次 + 确认一次」，比"提前把模式切到插话再发送"路径更短、更明确，而且用户此刻才掌握足够信息（本轮跑到哪了、我排在第几）。
- SharedPreferences 里已落盘的 `dsh_delivery_mode` **不写迁移代码清理**（读都不再读，无害；写清理逻辑反而是净增代码）。

### 2.2 默认排队时用户看到什么（发送瞬间的反馈）

发送动作本身不变（乐观清空输入框与附件，保留连续发送的手感），但反馈从"一个 2 秒的 toast"换成三层可见、可撤回的证据：

1. **输入框原地不动，上方出现一张「已排队」回执条**（替换 `_toast('已加入队列')`）：
   `[队列图标] 已排队 · 本轮结束后自动发送` + 右侧文字按钮 **「撤回」**。
   - 「撤回」**一次点击即生效**（不需要二次确认）：撤回是安全方向，多一次确认只会让人撤回不掉。
   - 5 秒后回执条自动收起，信息并入下面的队列面板（不永久占高度）。
   - 发送失败时**同一条位置**变红：`[错误图标] 排队失败，内容已放回输入框` + 「重试」。
2. **队列面板标题改成有语义的**（`chat_view.dart:3039`）：
   - 由 `'${rows.length} 条排队消息'` → `'${rows.length} 条排队中 · 本轮结束后自动发送'`；
   - 第一条加一行浅色副文案 `本轮结束后按顺序发出`。
3. **输入卡片顶部一行常驻说明**（新增，仅 `dsh.isSessionRunning` 时渲染，约 18dp 高、11px `textTertiary`）：
   `本轮执行中 · 你发的消息会在本轮结束后自动发送`。
   - 位置：放在队列面板**之上**（`chat_view.dart:2737` 之前）。
   - 作用：把"这一条发送的含义变了"讲在**用户打字之前**，而不是打完之后靠按钮颜色猜。这是对 1.1 的直接修复。
   - 不要用输入框 `hintText`：那一位已经被长按说话的手势层占用（`chat_view.dart:2794-2797` 的注释说明了原因）。

### 2.3 「立即插话」的入口：**只在队列条目上**（发送前不给入口）

**入口位置结论：不在发送前、不在发送后出现的 toast 上，只在队列条目上。**

- **不放在发送前。** 放进发送前就必须靠一枚"提前预设"的开关来表达（因为没有别的办法让用户在按下之前告诉系统"我要插话"），而那正是本次出问题的根源。用户原话是"如果要插入，需要**再点一次**是否直接发送的操作"——那一次点击发生在**消息已经发出去、并以"排队中"的形式摆在用户眼前之后**。
- **每一条队列行给一个文字按钮「立即插话」**，替换现在那个 16px 的 `Icons.bolt_rounded`（`chat_view.dart:3071-3077`）。
  - 用文字而非图标：图标没有语义（⚡ 在本 App 里已经被复用在发送键上，`3268`/`3283`，同一个图标两种含义）；文字按钮的触摸区也天然达到 36-44dp。
  - 与「删除」之间**拉开至少 12dp**，消除 1.4 的邻键误触。
- **桌面端已有同构的先例**（可作为设计依据）：`dsh-client-ui-conversation/lib/client.js:15579-15595` 的队列行就是 Tooltip `queue.steer`（"插话发送"）+ `onClick: applyAction(row.id, { kind: "steer" })`，非运行态 `disabled`；并且 `client.js:14822-14827` 的文案是 `"queue.steer": "插话发送"` / `"queue.steer.unavailable": "仅运行中可插话发送"` / `"queue.steerFailed": "插话发送失败，请重试。"`。手机端沿用这个入口位置，只是**加上用户要求的确认**。

**确认方式：二次点击同位置按钮（不用弹窗、不用长按）**

- 第一次点击：按钮**就地**从 `立即插话` 变成 **`确认插话？`**（warning 实心 + 白字），同时该行左侧出现一行极短副文案：`会插进当前步骤，本轮不会重来`。
  - 注意措辞：**不要写"打断本轮"**，引擎语义是 `agent.steer`（1.7），写"打断"会造成"它会把本轮重启/取消"的错误预期。
- 2.5 秒内没有第二次点击 → 自动还原成 `立即插话`，没有任何副作用。
- 第二次点击才真正调 `dsh.queueAction(row.id, 'steer')`。
- 同一时刻只允许一条处于待确认态（再点另一条会先还原上一条）。
- **为什么不用确认弹窗**：弹窗会盖住屏幕，而"值不值得插话"这个判断需要看着上面正在跑的 agent 输出（1.5 说明这块空间本来就紧张）；而且弹窗的默认焦点/位置在移动端很容易被连点穿过。二次点击的位置稳定、可视、无需等待动画。
- **为什么不用长按**：长按在本 App 里已经被「长按说话」占用（`chat_view.dart:2807-2809` 的 `chat-hold-layer`），同屏再引入一个长按手势既会和现有长按竞争，又没有任何可发现性（没有可见提示用户不会知道要长按）。

**可用性判据（已核实：不需要 `target`，网关不用改）**

Lead 曾担心 `selectQueueRows` 拍平了 `next-turn`/`next-step` 导致 UI 拿不到 `target`。**核实结论：该担心不成立，且判据比预期的更简单。**

- `dsh_mobile/dsh-server-plugin/lib/features.mjs:31-63` `selectQueueRows`：`const rows = Array.isArray(inbox['next-turn']) ? inbox['next-turn'] : [];`（`34`）——**只转发 `next-turn`**，`next-step` 根本不返回（`22-27` 的文档注释明说）。返回行形状固定为 `{ id, text, attachments, createdAt }`（`55-59`），**没有也不需要 `target` 字段**。
- 引擎判定 target 的方式是"这个 id 落在哪个数组里"，不是行上的字段：`dsh-api-session-controller/lib/index.js:955-963` 先查 `agent.inbox.nextTurn`，查不到才回落到 `nextStep`。
- ⇒ 对**手机可见的每一行**，`located.target === 'next-turn'` **恒成立**；`index.js:966` 里 `target !== 'next-turn'` 这个条件永远不成立。
- ⇒ **唯一真正决定"能否插话"的变量是 `agent.status === 'running'`**，而它在客户端就是 `dsh.isSessionRunning`（`dsh_service.dart:370-371`，其中 `_currentSession?.isRunning` 正是引擎 status 的投影）。
- ⇒ `chat_view.dart:3076` 现有的判据**是对的，保留**。不需要新增字段、不需要网关为置灰做改动。

**但判据要满足用户要求的"不能点了才报错"**：现在非运行时该按钮是 `onTap: null`（`3076`）——置灰**没有说明原因**，用户看到的是一个死按钮。改为：

- 运行中 → 文字按钮 `立即插话`，可点。
- 非运行中 → 同一位置的**灰字** `本轮已结束`（不可点），或行尾附一行 `仅本轮运行中可插话`。
- 文案直接复用桌面端已有口径：`client.js:14823` `"queue.steer.unavailable": "仅运行中可插话发送"`。

**已知限制（如实记录，本次不修）**：`selectQueueRows` 把 `inbox.next-step` 的行**全部丢弃**，手机完全看不到它们、也无法编辑/删除。对当前用户路径暂无影响（`mode:'queue'` 走 `agent.followup` → 落 `next-turn`，可见；`steer` 成功的条目是**离开**队列，不需要留在面板里），所以本次**不建议**扩大 `selectQueueRows` 的口径 —— 那会让 `target` 从常量变成变量，反而必须连带改造置灰判据与 `queueAction`。

### 2.4 发送键 / 停止键：彻底分家

- **发送键永远在原来的实心圆形位置（最右），永远只做发送。** 运行中也是发送（排队），图标仍是 `Icons.arrow_upward_rounded`；`3268`/`3283` 那套"变 ⚡ 变 warning 色"删掉（⚡ 留给队列条目的插话，一义一图）。
- 运行中在发送键上叠加一个**队列数量角标**（小圆底 + 数字），这是"你现在的发送会排队，已经排了 N 条"的唯一必要提示。
- **停止键移到独立位置**：操作行**最左端**，`chat_view.dart:2871-2876` 现在放 `+` 的位置；`+` 右移到模型胶囊旁。形状为**描边圆形 + danger 色 + `Icons.stop_rounded`**，与实心 accent 的发送键在颜色、填充、位置上三重区分。
- 只在 `dsh.isSending`（本机发起的回合）时渲染停止键 —— 保持 `3239` 原有的正确判断，不要改成 `isSessionRunning`（否则就制造出 1.3 里那个原本不存在的"旁观误停"问题）。
- 这样 1.2 的失效场景被**结构性消除**：清空输入框不再改变任何按钮的语义。

### 2.5 失败如何回滚

| 场景 | 回滚动作 |
| --- | --- |
| 排队投递失败（`deliverWhileRunning` 返回 false） | 正文 + 附件原样放回输入框（`chat_view.dart:427-431` 现有逻辑**保留**）；回执条变红：`排队失败，内容已放回输入框` + 「重试」。**不要**用 `_toast`：`chat_view.dart:2690-2701` 的 `_toast` 会 `clearSnackBars()` 且 2 秒消失，用户可能完全没看见就丢了内容 |
| 插话失败（`queueAction` 返回 false，普通错误） | 条目**留在队列里**（服务端是唯一真值，`dsh_service.dart:2197-2200` 的注释已经说明原因，保留）；按钮还原成 `立即插话`；在该行下方就地显示失败的 `queueError` |
| 插话返回 `session/steer-unavailable` | **不当失败**：文案 `本轮已结束，消息会照常排队发送`，用中性色不用红色；条目保持排队态（刷新后它可能已经进 transcript，本身就是"照常排队发送"的完成态）。**前置依赖：必须先修 3.6 的错误码透传，否则 UI 拿不到这个 code** |
| 插话/删除时条目已被引擎领走（`session/queue-item-not-found`） | **静默收敛**，不报错：条目消失 + 就地一行浅色 `这条已经发出去了` + `fetchQueue()` 对齐服务端真值。桌面端就是这么做的（`client.js:14354` / `3661`：遇到这两个 code 直接 `return`，不弹错）。**同样依赖 3.6** |

**竞态收敛的统一原则（覆盖所有队列动作）**：队列面板是**服务端快照**，用户看到的那一刻就可能过期。所以：

1. 任何队列动作失败后，**先 `fetchQueue()` 对齐，再决定要不要报错**——若刷新后条目已不在队列里，说明它已被领走，属于正常时序，**不报错**。
2. **禁止**用字符串匹配错误文本来区分 `steer-unavailable` 与 `queue-item-not-found`（网关 `core.mjs:162` 只给了文本，见 1.8）。要么修 3.6 拿到结构化的 `code`，要么按第 1 条统一走"刷新后判断"。
3. 动作进行中，该行按钮进入局部 loading（复用 `queueLoading`，`chat_view.dart:3043-3044` 已有 spinner 位置），防止连点产生第二个请求。
4. 面板整体在不可用时（`dsh.queueError` 非空）保留上一次的真实条目 + 错误提示（`chat_view.dart:3047-3051` 已有这个做法，保留），不要清空面板。

### 2.6 成功如何反馈

- **排队成功**：回执条 `已排队 · 本轮结束后自动发送`（2.2）+ 队列面板条数 +1 + `dsh_service.dart:2266` 的 `fetchQueue()` 已经是真值来源，保留。
- **插话成功**：条目从队列面板**立即消失**，同时在该行原位置显示一行 2 秒的浅色确认 `已插话发送`（就地反馈，不用全屏 toast）。
  - 建议（可选实现）：额外在消息流末尾插入一条本地"已插话"占位气泡。这**不违反** `chat_view.dart:400-402` "不插本地乐观气泡"的原则——那条原则的理由是"队列与回合真值以服务端为准，插本地副本会变成两条"；插话路径上队列条目**已经不存在**，不存在重复源。若实现成本高，退化为只有就地确认文案，**不作为验收项**。

### 2.7 与用户硬规则的对照

| 用户要求 | 本方案 |
| --- | --- |
| 会话进行中发消息 → 默认排队 | 恒为 `mode:'queue'`，无开关无记忆（2.1） |
| 等上一段结束才自动发送 | 复用引擎 `agent.followup` 语义 + `fetchQueue` 在回合结束刷新（`dsh_service.dart:3088`） |
| 要插入需要**再点一次** | 队列条目「立即插话」→「确认插话？」二次点击（2.3） |
| 有确认感、不能一次误触就打断 | 二次点击 + 自动还原 + 触摸区加大 + 与删除拉开间距（2.3） |

---

## 3. (c) 精确改动清单

> 行号对应**改动前**的 `main` 工作副本。`chat_view.dart` 与 T3 有写冲突 → **设计冻结后由 T2 实施**，T3 的改动落地后行号会整体位移，实施时以代码片段而非行号为准。

### 3.1 `dsh_mobile/lib/views/chat_view.dart`

| # | 位置 | 动作 |
| --- | --- | --- |
| 1 | `3294-3339`（`_buildDeliveryModeChip` 全段含文档注释） | **删除** |
| 2 | `2878`（`_buildDeliveryModeChip(dsh),`） | **删除**（操作行里那一项） |
| 3 | `2871-2876`（`_buildComposerIcon(Icons.add_rounded ...)`） | **移动**到 `_buildModelPill`（`2879`）左侧 |
| 4 | `2870-2884` 操作行 | **新增**首项 `_buildStopButton(dsh)`（放在原 `+` 的位置） |
| 5 | 新增 `_buildStopButton(DshService dsh)` | 仅 `dsh.isSessionRunning && dsh.isSending` 时返回描边圆形 danger 停止键（`key: ValueKey('chat-stop-button')`），`onTap: dsh.cancelActiveTurn`；否则 `SizedBox.shrink()` |
| 6 | `3234-3292`（`_buildSendButton`） | 删除 `3239-3264` 的停止键分支；删除 `3268` 的 `steering` 计算与 `3278`/`3283` 的变色变图标；发送键恒为实心 accent + `Icons.arrow_upward_rounded`；`onTap` 恒为 `canSend ? () => _sendMessage(dsh) : null`（`key: ValueKey('chat-send-button')`）；`ValueListenableBuilder` 包裹保留（`3235-3237`） |
| 7 | 新增（`_buildSendButton` 内） | 运行中且 `dsh.queueItems.isNotEmpty` 时，在发送键右上角叠加队列数角标 |
| 8 | `369-408`（`_sendMessage`） | `399-406` 的 `if (dsh.isSessionRunning)` 保留，但注释改为"恒排队"；`403` 不变 |
| 9 | `414-433`（`_deliverWhileRunning`） | 删除 `419` `final mode = dsh.deliveryMode;`；`423` 的 `_toast(mode == 'steer' ? ... )` 改为 `setState(() => _queueReceipt = QueueReceipt(text: text, ok: true));`；`432` 的 `_toast` 改为 `setState(() => _queueReceipt = QueueReceipt(text: text, ok: false));` **并且**保留 `427-431` 的内容回填 |
| 10 | 新增状态字段 | `QueueReceipt? _queueReceipt;` + `Timer? _receiptTimer;`（5s 后清空）；`String? _steerConfirmArmedId;` + `Timer? _steerArmTimer;`；两个 Timer 都要在 `dispose()` 里 `cancel()` |
| 11 | 新增 `_buildQueueReceipt()` | 回执条（成功=中性色 + 「撤回」；失败=danger 色 + 「重试」）；插到 `_buildQueueDock(dsh)`（`2737`）**之前** |
| 12 | 新增 `_buildRunningHint(dsh)` | `dsh.isSessionRunning` 时渲染一行 11px `textTertiary`：`本轮执行中 · 你发的消息会在本轮结束后自动发送`；插到 `2737` 之前、`_buildQueueReceipt` 之后 |
| 13 | `2737` / `2740` / `2743` 的 children 顺序 | 变为：`_buildRunningHint` → `_buildQueueReceipt` → `_buildQueueDock` → 附件 → 模板 chips → 文本框 → 操作行 |
| 14 | `3039` | 标题文案 → `'${rows.length} 条排队中 · 本轮结束后自动发送'` |
| 15 | `3069-3077` | 三个 `_queueIconButton` 改为：`编辑`（保留图标，触摸区补到 36dp）、`删除`（同上）、**「立即插话」文字按钮**（`key: ValueKey('queue-steer-${row.id}')`）；三者之间 `SizedBox(width: 12)` |
| 16 | 新增 `_queueTextButton(String label, VoidCallback? onTap, {Color? color})` | 文字按钮基件；替换/并列 `_queueIconButton`（`3094-3110`）；`_queueIconButton` 的 `EdgeInsets.all(4)` + `size: 16`（24dp 触摸区）必须放大到 ≥36dp |
| 17 | `3119-3124`（`_steerQueueRow`） | 改为两步：未武装 → `setState(_steerConfirmArmedId = row.id)` + `_steerArmTimer = Timer(2.5s, 还原)`；已武装 → 真正调 `dsh.queueAction(row.id, 'steer')`。按 `queueAction` 的 `queueErrorCode` 分支文案（`session/steer-unavailable` / `session/queue-item-not-found` → "这一轮已经结束，消息会照常排队发送"，中性色；其他 → 红字 + 还原按钮） |
| 18 | `3112-3117`（`_removeQueueRow`） | 不变（回执条的「撤回」复用它） |

### 3.2 `dsh_mobile/lib/services/dsh_service.dart`

| # | 位置 | 动作 |
| --- | --- | --- |
| 1 | `2135`（`String _deliveryMode = 'queue';`） | **删除** |
| 2 | `2150`（`String get deliveryMode`） | **删除** |
| 3 | `2152-2158`（`setDeliveryMode`） | **删除** |
| 4 | `2161-2164`（`loadDeliveryMode`） | **删除** |
| 5 | `610`（`await loadDeliveryMode();`） | **删除** |
| 6 | `2296-2300`（`debugSetDeliveryMode`） | **删除** |
| 7 | `2259`（`'mode': _deliveryMode,`） | 改为 `'mode': 'queue',`，并补注释：运行中投递恒为排队，插话只走 `queueAction(...,'steer')` |
| 8 | `2125` 附近 | **新增** `String _queueErrorCode = '';` + `String get queueErrorCode => _queueErrorCode;`（**字符串**的引擎 code，如 `session/steer-unavailable`，不是 int；现有 `2224-2229` 只解析 `error` 文本，无法区分"本轮已结束"与"网络失败"——见 1.8） |
| 9 | `2219-2230` | 成功分支 `_queueErrorCode = ''`；失败分支取 `data['code']`（**前提：3.6 已落地**，否则该字段不存在）。在 3.6 落地前，此处改为按 2.5 的统一原则"失败先 `fetchQueue()` 对齐再判" |
| 9b | `2226-2228`（`msg = data['error'].toString()`） | 改为结构化取值：`final e = data['error']; msg = e is String ? e : (e?['message']?.toString() ?? 'HTTP ${res.statusCode}');` —— 消除 1.8 第 3 层那个"网关改成对象就显示 `[object Object]`"的脆弱点 |
| 10 | 新增测试注入口 | `@visibleForTesting void debugSetDeliverResult(bool ok)` + `debugSetQueueActionResult(bool ok, {int code = 0})`，让"运行中发送 / 插话"两条路径可以在**不联网**的前提下被测（重要：不加这个口子，`deliverWhileRunning` 必然打真网关，违反本阶段硬规则 2，也违背 `2283-2287` 注释里已经写明的历史教训） |

### 3.3 `dsh_mobile/lib/services/storage_service.dart`

| # | 位置 | 动作 |
| --- | --- | --- |
| 1 | `69`（`_keyDeliveryMode`） | **删除** |
| 2 | `71-74`（`loadDeliveryMode`） | **删除** |
| 3 | `76-79`（`saveDeliveryMode`） | **删除** |
| 4 | — | 已落盘的 `dsh_delivery_mode` 键**不清理**（不再读即无害；写迁移代码是净增代码） |

### 3.4 不需要改的

- **网关 `dsh-server-plugin/lib/index.js:2826`**：`jsonBody.mode === 'steer' ? 'steer' : 'queue'` 已经是默认排队，保留（这是"默认排队"不需要后端改动的根据）。
- **`dsh-server-plugin/lib/features.mjs:75-86 / 503-519`**：`normalizeQueueAction` + `session/updateQueue` 已经完整支持 `edit/remove/steer`，且 `79` 行的 `steer` 分支原样透传给引擎，保留。
- **`dsh-server-plugin/lib/features.mjs:31-63` `selectQueueRows`**：**不需要**暴露 `target`（已核实只返回 `next-turn`，target 对可见行恒成立），也**不需要**扩大口径去暴露 `next-step`。见 2.3。
- **`dsh-server-plugin/lib/index.js:2842-2857`**：`session/prompt` 的 `mode` 透传，保留。
- **`dsh_mobile/lib/views/task_center_view.dart:166`**：队列只读展示，保持只读（动作收敛到对话页），但 `183` 行的文案要与新标题口径一致。

> 唯一需要网关改动的是错误码透传，见 **3.6**（与 `target`、与 `mode` 都无关）。

### 3.5 测试清单

**`dsh_mobile/test/widgets/queue_and_task_center_test.dart`**

- 🔴 **删除** `103-143` 整个 `group('投递方式切换')` —— 该组的两个用例（`104` 空闲时不显示开关、`113` 点击切换）断言的正是要删除的开关；`131-142`（空框停止键 / 有文字变发送键）**必须重写**为"两个按钮在两个独立位置"，否则它会把 1.2 那个误取消结构钉在回归网里。
- 🟡 **改写** `87-100`（"会话没在跑时「插话」按钮置灰"）：按钮从图标变文字，且非运行时**不渲染**插话入口（而非置灰）。
- 🟢 `42-85` 队列面板三个用例**保留**（空不渲染 / 条数与内容 / 3 条上限 / 错误显示）。

**新增用例（同一文件，或拆 `test/widgets/running_delivery_test.dart`）**

| # | 用例 | 断言要点 |
| --- | --- | --- |
| 1 | 运行中发送**恒为排队**，界面上没有任何模式开关 | `debugSetRunning(true)`；`enterText` + 点发送；`find.text('排队')` / `find.text('插话')` 均 `findsNothing`（防"开关又偷渡回来"）；出现「已排队」回执 |
| 2 | 运行中发送失败 → 正文回到输入框 | `debugSetDeliverResult(false)`；断言 `find.text('原文')` 在输入框内、附件行重新出现、回执条是失败态 |
| 3 | 发送键与停止键**是两个不同位置的控件** | `debugSetRunning(true)` + 空输入框：`find.byKey('chat-stop-button')` 与 `find.byKey('chat-send-button')` 同时存在（**上一版这里只有一个**，是本条设计的关键回归） |
| 4 | 输入框被外部清空时，发送键**不会**变成停止键 | 有文字 → 模拟 `_inputController.clear()`（切会话/重录路径）→ 断言停止键位置与发送键位置都没变、且点击发送不会触发 cancel |
| 5 | 非本机发起的回合**不渲染**停止键 | `debugSetRunning(true)` 但只让 `_currentSession.isRunning=true`、`isSending=false` → `find.byKey('chat-stop-button')` 为 `findsNothing`（保住 1.3 那个正确行为） |
| 6 | 队列条目第一次点击「立即插话」只进入待确认态 | 点击 → 文案变 `确认插话？`、`dsh.queueItems` 不变、无 toast、无网络（靠注入口证明 `queueAction` 未被调用） |
| 7 | 第二次点击才真正插话 | 连点两次 → `debugSetQueueActionResult(true)` → 断言走通、条目消失、出现确认文案 |
| 8 | 待确认态 2.5 秒自动还原 | `await tester.pump(const Duration(seconds: 3))` → 文案回到 `立即插话` |
| 9 | 插话返回 `session/steer-unavailable` 时条目保留、文案中性 | 注入 `ok=false, code=steer-unavailable` → 断言文案含"这一轮已经结束"、条目仍在 `queueItems` 里 |
| 10 | 运行中说明行只在 `isSessionRunning` 时出现 | 空闲 `findsNothing`；运行中 `findsOneWidget` |
| 11 | 面板不挤压输入 | 3 条队列 + 2 个附件同时渲染，`tester.takeException()` 为 null 且文本框仍可 `enterText`（在 `Size(360, 640)` 下跑） |
| 12 | 非运行时插话入口**置灰并说明原因**（不是死按钮、也不是点了报错） | 注入队列 + `debugSetRunning(false)` → 断言该行出现 `仅本轮运行中可插话`，且不存在可点的 `queue-steer-${id}` |
| 13 | 条目已被领走 → 静默收敛 | 注入 `ok=false, code='session/queue-item-not-found'`，同时把该条目从 `debugSetQueue` 里去掉 → 断言**没有**红色错误、出现 `这条已经发出去了` |
| 14 | 失败后先对齐再报错（竞态统一原则） | 注入 `ok=false`（普通错误）但 `queueItems` 仍含该条目 → 断言显示失败；注入 `ok=false` 且条目已消失 → 断言不显示失败 |
| 15 | 网关错误消息为对象时不退化成 `[object Object]` | 用 mock 响应体 `{"ok":false,"code":502,"error":{"message":"boom"}}` → 断言 UI 文本含 `boom` 且不含 `[object Object]`（对应 3.2 #9b） |

### 3.6 ⚠️ 需网关改动（**不在 T2 写范围内，请 Lead 派发**）

目的：让手机能区分"这一轮刚好跑完了"（正常时序）与"真的失败了"，从而落地 2.5 的竞态收敛。改动只有两处、共约 4 行。

| # | 文件:行 | 改动 |
| --- | --- | --- |
| 1 | `dsh-server-plugin/lib/core.mjs:161-162` | **错误码在 RPC 边界丢失的唯一修复点。**<br>现在：`const err = (parsed.result && parsed.result.error) \|\| { message: 'RPC Error: ' + data }; reject(new Error(err.message \|\| JSON.stringify(err)));`<br>改为：保留引擎的结构化字段 —— `const e = new Error(err.message \|\| JSON.stringify(err)); e.code = err.code; e.details = err.details; reject(e);`<br>（`err.code` 就是 `session/steer-unavailable` / `session/queue-item-not-found` / `session/attachment-invalid` 等，见 `dsh-api-session-controller/lib/index.js:966`、`:947`、`:940`） |
| 2 | `dsh-server-plugin/lib/features.mjs:515-517` | 现在：`sendJson(502, { ok: false, code: 502, error: err?.message \|\| 'queue update failed' });`<br>改为：`sendJson(502, { ok: false, code: 502, engineCode: err?.code \|\| '', error: err?.message \|\| 'queue update failed' });` —— **`error` 保持字符串**（不要改成对象，否则会碰到 3.2 #9b 那个脆弱点），新增独立的 `engineCode` 字段 |
| 3 | `dsh-server-plugin/lib/index.js:2900`（可选，同一类问题） | `/prompt` 的失败出口同样丢码；至少把 `engineCode: err?.code \|\| ''` 带上，让"模型不支持图片"（`session/attachment-invalid`）这类失败也能被手机识别 |
| 4 | 新增单测 | `node --test tests/unit/<file>.test.mjs`：断言 `callDshRpc` 的 reject 结果带 `code`；断言 `features.mjs` 的 queue catch 分支把 `engineCode` 写进响应体。`features.mjs` 是纯函数模块（`1-11` 行的模块注释明确了"不 import index.js/core.mjs，可在无引擎下单测"的设计），所以路由出口这部分**可以在单测里直接覆盖** |

**为什么不能只改客户端**：`core.mjs:162` 之后，`code` 在网关进程内**已经不存在**，客户端无论怎么解析都拿不到。这不是"要不要透传"的选择，是链路上唯一的修复点。

**是否阻塞 T2**：**不阻塞**。1.8 的结论给出两条路：(a) 先落 3.6 拿到结构化 code；(b) 不依赖 code，统一走 2.5 的"失败先 `fetchQueue()` 对齐，再决定是否报错"。**建议 T2 按 (b) 实现**（自足、不跨模块阻塞），3.6 落地后再把 (b) 升级成按 code 精确分支。两种实现在 UI 上的最终表现一致，测试用例 13/14 覆盖的是行为本身而非实现方式。

---

## 4. (d) 顺带审：这一项上一轮是否只为交差

### 结论：**是。** 功能面铺得比用户需求宽，但几乎没有一处是对"用户实际会遇到的路径"的推演。

**支持这个结论的证据**

1. **语义方向反了，而这是可验证的**：用户要"默认排队 + 显式升级"，实现做的是"两个危险等级之间预选 + 记住上次选择"。前者是"安全默认 + 显式动作"，后者是"状态机 + 记忆"。用户抱怨的不是某个 bug，是这个模型本身——所以他的原话（"插话消息就这个逻辑就错了"）指的是设计，不是实现细节。
2. **复杂度花在了不需要的地方**：`deliveryMode` 一路做进持久化（`storage_service.dart:69-79`）、做进服务层（`dsh_service.dart:2150-2164`）、做进测试（`queue_and_task_center_test.dart:103-143`），共约 60 行产物 —— 全部服务于"让两种模式都能用"，而用户的诉求是"让我不容易误打断"。
3. **自认踩过的坑只修了表面**：`chat_view.dart:3230-3233` 注释承认过"敲了字还是停止键 → 点了等于取消自己的回合"，修法是包进 `ValueListenableBuilder`（修重建时机），没有处理"同一个位置承担两个相反语义"这个根因（1.2）。而会话切换（`1468-1479`）依然会无条件覆盖输入框，因此这个坑**在真机上仍然可复现**，只是新增的测试没覆盖它。
4. **危险动作的确认等级不一致，且与用户明确要求相反**：发送键上花心思做了"排队/插话"颜色区分（`3278`），而真正直接改变运行中任务上下文的队列「立即插话」（`3071-3077` / `3119-3124`）是 **24dp 图标 + 一次点击 + 无确认**，还紧贴「删除」。用户明确说了"需要再点一次是否直接发送的操作"，这一处恰恰**一次点击直达**。
5. **多客户端场景处理了一半**：`dsh_service.dart:365-371` 的注释显示作者想过"电脑端发起、手机旁观"这件事，并且**在停止键上处理对了**（`3239` 用 `isSending` 而不是 `isSessionRunning`）。但同一个思考没有延续到投递方式：手机可以在旁观态下切换/预置投递模式（`3299` 判的是 `isSessionRunning`），而这个选择是全设备、跨会话持久化的，电脑端毫不知情（1.3）。
6. **没有做布局/空间推演**：队列面板被放进输入卡片（`2737`），而输入卡片是唯一 `Expanded`（`1855` 消息列表）的兄弟节点且高度无上限（`2713`）。"会不会被键盘遮住"这个问题里隐含的假设（遮挡）不成立，真正的问题是**消息区被挤掉**（1.5）——说明这块只被渲染过、没有被在真实屏幕尺寸下推演过。

**应当承认做对的部分**（避免因这次重做把正确的设计一起推翻）

- `_sendMessage` 在运行中**不插本地乐观气泡**（`400-402`）：判断正确，理由是"队列与回合真值都以服务端为准，插本地副本会在引擎回传后变成两条"。**保留**。
- 队列操作**绝不本地乐观删除**（`dsh_service.dart:2197-2200`、`chat_view.dart:3016-3018`）：正确，网关失败时条目仍在队列里等待执行，本地抹掉会让用户以为撤回了。**保留**。
- 停止键用 `isSending` 而不是 `isSessionRunning`（`3239`）：正确，避免手机误停电脑端的任务。**保留**。
- 队列面板"最多列 3 条，其余去任务页"（`3054`、`3081-3088`）：方向正确，是唯一一处体现了"别把输入框挤出屏幕"意识的地方。**保留 3 条上限不动**（避免与 T3 的写冲突面扩大），但把面板整体位置调整留给 3.1#13。
- `session/steer-unavailable` / `session/queue-item-not-found` 在引擎侧**本来就有**精确的结构化错误码，`normalizeQueueAction`（`features.mjs:75-86`）的入参校验也与引擎准入规则对齐（避免往返后才发现无效编辑）：基础设施做得比 UI 层扎实。问题在于**两条消费链都没接通** —— 网关在 `core.mjs:161-162` 把 code 丢了（1.8），客户端 `dsh_service.dart:2224-2229` 只取 `error` 文本，于是这些精心定义的错误码在整条链路上没有任何一处被用到。

---

## 5. 附录：事实核对（引擎侧只读探测）

| 事实 | 证据 |
| --- | --- |
| `mode:'steer'` = 插进最近的步骤，**不是**取消本轮 | `@deepseek-ai/dsh/node_modules/dsh-api-session-controller/lib/index.js:882` `if (request.mode === "steer") agent.steer(message);` |
| `mode:'queue'` = 排在当前回合之后 | 同上 `:883` `else agent.followup(message);` |
| 三种落位 | `dsh-api-session-controller/lib/client.js:1686` `const placement = this.running ? input.mode === "steer" ? "steering" : "queued" : "transcript";` |
| `steer-unavailable` 的触发条件 = 本轮已经不再收插话 | `dsh-api-session-controller/lib/index.js:966` `if (request.action.kind === "steer" && (target !== "next-turn" || agent.status !== "running")) throw new RemoteError("session/steer-unavailable", ...)` |
| **桌面端默认就是"排队"** | `dsh-client-ui-conversation/lib/client.js:14387-14388` `/** Default preserves Enter-as-Queue for running conversations. */ const DEFAULT_BUSY_ENTER_BEHAVIOR = "queue";` |
| 桌面端"再点一次/另一种手势才插话"的先例 | 同文件 `14411-14415` `resolveSubmitMode(preferred, running, gesture, steeringAvailable)`：plain Enter → `preferred`（默认 queue），accelerated chord → `preferred === "queue" ? "steer" : "queue"` |
| 桌面端队列条的插话入口 | 同文件 `15579-15595` Tooltip `queue.steer`、`disabled: busy !== null \|\| !running`、`onClick: () => applyAction(row.id, { kind: "steer" }, t("queue.steerFailed"))` |
| 桌面端文案 | 同文件 `14822` `"queue.steer": "插话发送"`、`14823` `"queue.steer.unavailable": "仅运行中可插话发送"`、`14827` `"queue.steerFailed": "插话发送失败，请重试。"` |
| 网关默认排队 | `dsh_mobile/dsh-server-plugin/lib/index.js:2826` `const deliveryMode = jsonBody.mode === 'steer' ? 'steer' : 'queue';` |
| `selectQueueRows` **只**返回 `next-turn`（`next-step` 被丢弃） | `dsh_mobile/dsh-server-plugin/lib/features.mjs:34` `const rows = Array.isArray(inbox['next-turn']) ? inbox['next-turn'] : [];`；行形状 `55-59` 无 `target` 字段 |
| 引擎判定 target = 落在哪个 inbox 数组，不是行上的字段 | `dsh-api-session-controller/lib/index.js:955-963`（先 `nextTurn` 后 `nextStep`），`966` 用 `target !== 'next-turn'` 做前置条件 |
| ⇒ 手机可见行的 `target` 恒为 `next-turn`，"能否插话"只取决于 status | 由上两条推出；客户端判据 = `dsh_service.dart:370-371` `isSessionRunning` |
| 引擎错误码在网关 RPC 边界被丢弃 | `dsh-server-plugin/lib/core.mjs:161-162` `reject(new Error(err.message \|\| JSON.stringify(err)));` —— 只保留 message |
| 队列路由出口只给 HTTP 语义的 `code:502` | `dsh-server-plugin/lib/features.mjs:515-517` `sendJson(502, { ok:false, code:502, error: err?.message \|\| 'queue update failed' })` |
| ⇒ 当前 HTTP 响应的 `error` 是**字符串**，不会出现 `[object Object]` | 同上（`Error.message` 必为字符串）；客户端 `dsh_service.dart:2226-2228` 的 `.toString()` 是脆弱点而非现有 bug |
| `/prompt` 失败出口同样丢码 | `dsh-server-plugin/lib/index.js:2900` |
| 桌面端对这两个竞态码的处理是"静默 return，不弹错" | `dsh-client-ui-conversation/lib/client.js:14354`、`3661` |
| `session/updateQueue` 的 `steer` 前置条件是"目标为 next-turn **且** agent 正在 running" | `dsh-api-session-controller/lib/index.js:966`；`981-982` 成功后 `agent.inbox.remove(itemId); agent.steer(message);` |
| `edit` 只接受文本块且必须含非空白文本 | 同上 `939-940`（`session/attachment-invalid` / `gateway/bad-request`） |

**一句话**：手机端要做的事不是"把引擎的两个 mode 都摆出来让用户选"，而是**跟随桌面端已经确立的默认（排队）+ 把桌面端单击直达的插话按钮补上用户要求的二次确认**；配套需要网关补一行错误码透传（3.6），否则"本轮刚好跑完"这种正常时序在手机上会被报成失败。

**给 Lead 的三条待办判定**

1. ❌ 不需要派发："暴露 `target` / 按 target 置灰" —— 核实为不需要（`selectQueueRows` 只返回 `next-turn`，见 2.3）。
2. ✅ 建议派发：`core.mjs:161-162` + `features.mjs:516` 的结构化错误码透传（3.6，约 4 行）。**不阻塞 T2**：T2 先按 2.5 的"失败先 `fetchQueue()` 对齐再报错"实现，效果等价。
3. ✅ T2 实施边界：`chat_view.dart`（与 T3 写冲突，需冻结后串行）、`dsh_service.dart`、`storage_service.dart`。**本阶段只产出本报告，未动任何源码。**

---

## 6. 实施结果（T5，2026-10-10）

**状态**：按冻结设计实施完成。`flutter analyze --no-pub` → `No issues found!`；`flutter test` → **376 passed / 0 failed**。

**改动文件（严格限于 T5 写范围）**

| 文件 | 改动 |
| --- | --- |
| `dsh_mobile/lib/views/chat_view.dart` | 删常驻开关与 ⚡ 语义；停止键移到操作行最左；新增运行说明行 / 回执条 / 二次确认插话 / 回执「撤回」；队列条目改文字按钮并放大触摸区；修切会话草稿键错误；操作行按剩余空间压缩模型胶囊 |
| `dsh_mobile/lib/services/dsh_service.dart` | 删 `deliveryMode`/`setDeliveryMode`/`loadDeliveryMode`/`debugSetDeliveryMode`；`deliverWhileRunning` 恒 `mode:'queue'`；`queueAction` 返回 `QueueActionOutcome`（applied/alreadyGone/failed）+ 失败先对齐再判；新增 `queueKnown` 三态与 `jobsDegraded`；`fetchQueue`/`fetchJobs`/`deliverWhileRunning` 加 `_sessionLoadSeq` 守卫；新增 `debugSetDeliverResult`/`debugSetQueueActionResult`/`debugLastQueueAction` 注入口 |
| `dsh_mobile/lib/services/storage_service.dart` | 删 `dsh_delivery_mode` 键与读写（旧值不清理，不再被读取） |
| `dsh_mobile/test/widgets/queue_and_task_center_test.dart` | 删「投递方式切换」整组；改队列面板文案断言；新增"读不到 ≠ 确实为空"与"给原因而不是死按钮" |
| `dsh_mobile/test/widgets/queue_steer_impl_test.dart`（新，18 条） | 语义用例：默认排队、回执撤回、失败回滚、双键分家、旁观不给停止键、切会话回归 ×2、二次确认 ×4、竞态收敛、触摸区、小屏不溢出、队列未知态 |

**与冻结设计的 4 处偏离（均有实测理由）**

1. **错误码透传（3.6）按 Lead 裁决未派发** → 落地为 `QueueActionOutcome`：失败后先 `fetchQueue()` 对齐，刷新后条目已不在队列即判定 `alreadyGone` 静默收敛。**未依赖 `code`，也未做错误文本匹配**。`engineCode` 仍是可选增强：网关补上后，这里的判定可升级为按码分支（行为不变，少一次多余刷新）。
2. **设计外发现并修掉一个真 bug（Lead 裁决 3 要求）**：`chat_view.dart` 切会话时原代码 `dsh.updateDraft(_inputController.text)` 的草稿键是"当前会话"，而此刻当前会话**已经是新会话** —— 正文被写进新会话的草稿槽（串味），且用户在旧会话打的字回到旧会话时会"消失"；更糟的是**首次进入会话**时这条调用会把该会话已存的草稿用空串清掉（`DraftStore.write('')` = 删除）。现改为只把正文写回**上一个会话**的键，且首次进入不写。
3. **修掉 1.5 的病根之一**：在 360dp 宽实测操作行 `317 > 316`（RenderFlex 溢出 1px，改动前就存在、被新增的小屏用例抓到）。模型胶囊的可读宽度改为按剩余空间计算（`clamp(40, 104)`），不再钉死 104。
4. **队列可见性三态**：`queueKnown` 为 `null/true/false`（未查过 / 确实为空 / 读不到），UI 只在 `false` 时显示"队列状态未知"。这直接对应 T4 实测的"`GET /sessions/queue` 被通配路由吞掉"：修好路由前后界面从此可分辨。

**"改动前变红"的证据（逐条实测，非推断）**

- 草稿串味用例：临时还原为 `dsh.updateDraft(...)` → `Expected: exactly one matching candidate / Actual: Found 0 widgets with text "B 的草稿"`（新代码下通过）。
- 首次进入清空草稿用例：临时还原为无条件的 `updateDraft` → `Found 0 widgets with text "差点丢掉的半句话"`（新代码下通过）。
- 小屏溢出用例：改动前实测渲染树 `extent=316.0 kids=[36,36,0,151,2,44,4,44]`（合计 317）→ 溢出 1px；修复后通过。
- 其余语义用例（回执、二次确认、双键分家）断言的控件/文案在旧代码里**根本不存在**，必然变红。

**仍未验证项（诚实清单）**

1. **真实网关往返一次都没跑过**：所有投递路径都用注入口测试（这是硬规则 2 的要求）。因此 `POST /api/mobile/sessions/prompt` 的实际请求体带 `mode:'queue'`、以及网关真实响应里 `queue` 字段是否存在，都只有代码级依据。**需要一次真机 smoke**（发一条、看它排队、本轮结束后自动发出）。
2. **`[object Object]` 防御分支无单测**（报告 3.2 #9b）：`DshService._httpClient` 没有注入口，测试里构造不出"error 是对象"的 HTTP 响应。代码已写成结构化取值，但**未覆盖**。
3. **字体放大未验证**：操作行的压缩只按宽度算（`LayoutBuilder`），没按 `textScaleFactor`。无障碍大字号下可能仍溢出，**未验证**。
4. **真机观感未验证**：360×640 下已保证"不溢出 + 输入框可用"，但"队列面板 + 提示条 + 说明行"合计占掉多少消息区、观感是否可接受，只有数字没有真机。
5. **`queueKnown` / `jobsDegraded` 的消费方尚未接线**：本次只把字段暴露出去（信息面板属 T3 范围），所以"读不到"在信息面板上仍可能显示成"没有"。
6. **失败收敛的乐观假设**：`alreadyGone` 的判据是"失败 + 刷新后条目不在队列里"。若网关在失败时**也**已把条目删掉（引擎受理了但网关超时），会被当作正常时序静默收敛，用户不会看到任何提示。选择乐观侧是刻意的（误报红错的伤害更大），但**未经真实网络验证**。
7. **`steer` 之后队列不刷新**：`_settleQueueAction(applied)` 依赖 `queueAction` 内部的 `fetchQueue()` 收敛条目；插话成功的条目会从 `next-turn` 移到引擎的 `next-step`，因此界面上它就是"消失"。真机上是否会出现"条目短暂还在"的闪烁，**未验证**。

**给 Lead 的一条环境观察（非本人改动，但会影响最终 diff 审查）**

仓库工作区在这次会话期间从 clean 变成了 **28 个文件 modified**（含删除 `lib/views/chat_page.dart`、`settings_view.dart`，以及 `lib/main.dart`、`pubspec.yaml`、多个 model/widget 的改动），而 `HEAD` 未移动（`git reflog` 里没有 `reset` / `checkout` 条目，最近提交仍是 15:57 的 `8f303c8`）。形态上像是有人对这批未提交的 v1.13 工作做过 `git stash` → `pop`。
本人本轮只写了 5 个文件（3 个 lib + 2 个测试）——已用文件修改时间核对。**建议在做最终 diff review 之前先确认这批改动的来源**，否则会把别人的进行中工作算进本次交付。
