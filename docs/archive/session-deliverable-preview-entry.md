# 会话内产物「点开即预览」（Android / Flutter 端）

日期：2026-10-15
范围：**仅 App 端**（`dsh_mobile/`）。网关侧一个字节未改，**不需要重启 dsh web**。
验收状态：`flutter analyze` 无问题；全量 `flutter test` **453 通过 / 0 失败**（新增 33 条）。
未做：真机验收（本机无 Android SDK / adb，见 §6）。

---

## 0. 结论

会话里现在有三条路都能"点开看一眼产物"，且**三条逐字同一套行为**：

| 入口 | 主点击 | 长按 |
|---|---|---|
| 消息流「本轮产出」卡片 | **就地预览弹层**（本次新增） | 下载 / 用其它应用打开 |
| 消息正文里的产物引用 | **就地预览弹层**（本次新增） | 长按复制原文 |
| 信息面板 → 交付物 | 就地预览弹层（原有） | 下载 / 用其它应用打开 |

外加一条顺带修掉的空洞：**消息正文里的链接此前点了完全没反应**。

---

## 1. 改之前是什么样（三个已核实的事实）

1. 「本轮产出」卡片点击走的是 `_openDeliverable` —— **下载 + 拉起系统应用**，要落一份文件到手机再切 App，而用户此刻通常只是想看一眼。
2. 信息面板点文件名是**就地预览**，长按才是下载。也就是说**同一个文件在两个入口行为相反**，用户没法从界面上学到任何一种。
3. `SafeMarkdown` 没有传 `onTapLink`，而 `flutter_markdown` 在 `onTapLink == null` 时**整段跳过点击处理**（包内 `widget.dart` 的 `if (widget.onTapLink != null)`），它不会自己退回 `url_launcher`。所以正文里所有链接——http 的、文件路径的——**点了都毫无反应**，且不报错。

---

## 2. 改了什么

### 2.1 新增：`lib/widgets/inline_file_links.dart`（纯逻辑，可直接单测）

正文里的产物引用 → markdown 链接 `[原文](dsh-file:<百分号编码的绝对路径>)`。

四条约束，每条都有对应测试：

1. **只链接化本会话 `present` 声明过的产物**。刻意不做"看起来像路径"的通用识别——通用正则会命中正文里的示例路径、别人的目录、纯属打比方的文件名，而**点开一个不存在的文件比点不动更糟**：它把一句可信的话变成了一次报错。清单是白名单，零误伤。
2. **围栏代码块一个字符都不动**。多行代码里的路径属于程序文本，在那里插 `[..](..)` 会让用户直接看到 markdown 源码。
3. **行内 code 例外，但条件严格**：`` `报告.docx` `` 是 agent 提产物最常见的写法，而反引号内根本不解析 markdown——原样跳过等于这功能一半失效。所以当反引号内**整段恰好就是这个产物名**时，连反引号一起换成链接；内部还有别的字符（`` `见 报告.docx` ``）就整段不动。
4. **已有的链接与裸 URL 不动**，避免链接里嵌链接。

其它实现细节：

- 路径用**百分号编码**且额外编码 `(` `)` `'` —— `Uri.encodeComponent` 保留这三个字符，而 `)` 正是 markdown 内联链接的结束符，`报告(1).docx` 这种自动重命名的产物会当场截断链接。
- 候选词含**两种斜杠的变体**：网关回传的 `display` 保留 agent 当初写的反斜杠，而 agent 在正文里常写正斜杠的同一个文件。
- 词边界 + 最长优先 + 不重叠贪心：`my报表.xlsx` 和 `out\报表.xlsx\bak` 都不会被算成命中，`out/报表.xlsx` 也不会被 `报表.xlsx` 吃掉一半。
- **幂等**：改写结果里的链接会被整体跳过，重复预处理结果相同。

### 2.2 新增：`lib/views/widgets/deliverable_preview_sheet.dart`

预览弹层从 `session_info_sheet.dart` 原样抽出并公开，成为**全 App 唯一的预览入口**：

```dart
showDeliverablePreview(context, item: item, loader: ..., onDownload: ...)
```

三个入口共用一份实现与一套手势，差异只剩"谁传的 loader"。原有的 `ValueKey`（`deliverable-preview-copy` / `-download` / `-error` / `-binary` / `-truncated`）全部保留不变。

### 2.3 改：`lib/widgets/safe_markdown.dart`

新增并透传 `onTapLink`（含注释说明"不传≠默认行为，而是链接全哑"）。

### 2.4 改：`lib/views/widgets/turn_output_card.dart`

行上两个动作位：主点击预览、长按下载。同时：

- 传了下载回调时，尾部图标从**下载箭头换成眼睛** —— 画着下载箭头却在点下去时开预览，图标就在说假话。
- 加一行 `点文件名就地预览 · 长按下载 / 用其它应用打开`（key `turn-output-hint`）。长按完全不可发现，不写出来就等于没有这个功能。
- 只给 `onOpen`（没有下载出口）时不画提示、也不承诺长按。

### 2.5 改：`lib/views/chat_view.dart`

- 产出卡片：`onOpen → _previewDeliverable`、`onDownload → _openDeliverable`（原下载链路原样保留，只是退到长按）。
- 正文：`data: linkifyDeliverableRefs(displayContent, dsh.deliverables)` + `onTapLink` 分发。
- 链接分发 `_openMessageLink` 分三类，**只有两类能开**：`dsh-file:` → 预览；`http(s)` → 系统浏览器（复用既有 `UrlOpener` MethodChannel）；其余 → 一句说明而不是静默失败。"点了没反应"和"这个链接打不开"是两件不同的事。
- 点 `dsh-file:` 链接时会**回到当前清单复核一次**：这条消息渲染之后清单可能已刷新（切了会话、重拉了 REST），拿旧路径去请求只会得到 403。

---

## 3. 测试

```
flutter analyze --no-pub                      → No issues found!
flutter test --no-pub                         → 453 passed（新增 33）

新增 test/widgets/inline_file_links_test.dart          26 条
新增 test/widgets/deliverable_preview_entry_test.dart   7 条
```

新测试的关键成对断言（"该变的必须变 / 不该动的一个字符都不动"）：

- 裸文件名、正斜杠写法、相对路径、带括号文件名 → 都变链接，且 href 解码回**清单里的绝对路径**（不断言编码串，否则改一次编码方式就全红且看不出链对没有）；
- 不在清单里的文件、空清单、围栏代码块、行内 code 内有杂字、已有链接、裸 URL、词内命中、更长路径前缀 → **一个字符都不动**；
- 集成断言走真实 `ChatView` + 可注入 `DshService`（无服务器配置 → 取内容在本地短路，**零网络、不建会话、不打 LLM**）：点卡片 → 弹出预览弹层；正文里产物名**真的挂上点击 recognizer**（只断言"文字显示出来了"是不够的）；点正文链接 → 打开**同一个**弹层。

> 记一笔踩坑：`SafeMarkdown` 是 selectable 的，渲染出去的是 `SelectableText`（内部 `EditableText`），所以 `tester.tapOnText` / `find.byType(RichText)` 都找不到它。测试改为从 `SelectableText.textSpan` 里取出 flutter_markdown 挂的那个 recognizer 并触发 —— 走的是同一条 `onTapLink` 回调链路。

---

## 4. 已知边界（如实声明，不是"待办"）

1. **二进制产物仍是"下载 / 用其它应用打开"**，不在 App 内渲染 —— 这是本次明确选定的范围（`docx / xlsx / pptx / pdf / 图片`）。它们在预览弹层里会显示一句"二进制文件不支持文本预览"加下载出口。要做真预览需要网关侧转换，属另一件事。
2. **不在清单里的正文路径不可点**。这是白名单设计的必然结果，不是遗漏。
3. 围栏代码块内的路径不可点（理由见 §2.1 约束 2）。
4. 正文里写相对路径的**已有** markdown 链接（`[x](out/a.md)`）会走到"这个链接不是本会话的产物"提示——它没有 `dsh-file:` 标记。若希望这类也打开，需要再扩一层（本次未做）。

---

## 5. 出包

本机**没有 Android SDK / adb**（`flutter doctor`：`Unable to locate Android SDK`），所以产物走既有的 CI 流程：

```
# 1) 推送触发 build-apk.yml（或在 GitHub 上 workflow_dispatch）
# 2) 拉产物
$env:GITHUB_TOKEN = 'github_pat_...'
node scripts/await-apk.mjs --timeout-minutes=25
```

⚠️ **签名**：CI 只有在配了 `ANDROID_KEYSTORE_BASE64` 等 secrets 时才用固定 release key；否则回退 debug key，**每次构建签名都不同 → 覆盖安装会失败，必须先卸载**（会丢本地 token，需要重新配对）。装之前先确认手机上手那版的签名来源。

版本号：`pubspec.yaml` 现为 `1.16.1+48`，本次**未擅自 bump** —— CI 的 tag / release / artifact 名全从它读，改不改由你定。

---

## 6. 真机验收步骤（待执行）

1. 装新 APK，进一个有产物的会话（或让 agent `present` 一个 `.md`）。
2. 消息流尾部出现「本轮产出」卡片 → **点文件名**：应当是**就地弹层显示内容**，不下载、不跳出 App；底部有「复制」「下载 / 打开」。
3. 该卡片**长按**文件名：走原来的下载 + 系统应用打开。
4. 让 agent 在正文里提到同一个产物（`` `报告名.md` `` 或直接写文件名）：该名字应变成**链接色**，点一下打开**同一个**弹层。
5. 正文里给一个普通 `https://` 链接：点一下应拉起系统浏览器。
6. 正文里写一个**不在清单里**的文件名：应当**不可点**（没有链接色）。
7. 点开一个 `.docx` 产物：应当是"二进制文件…请下载后用本机应用打开" + 下载出口（这是预期行为，见 §4.1）。
