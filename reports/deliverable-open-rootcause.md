# 交付物「点不开」根因定位与修复

日期：2026-10-10
范围：引擎 `deliverables/presented` → 网关 `/api/mobile/deliverables`(+`/download`) → App `http.get` → MethodChannel `dsh_mobile/file` → `MainActivity.openBytes`
活实例基线：`dsh web` PID 47652，启动 16:03:54；bridge **1.14.0**，监听 `0.0.0.0:3088`，引擎 `127.0.0.1:3080`
约束遵守：**未重启 dsh web**（PID 47652 在整个过程中存活、启动时间未变）、**未创建任何会话**、全部探测为只读
复现脚本：`.probe/*.mjs`（只读；运行时自行从 `~/.dsh/.credentials.yaml` 与 `mobile-bridge/config.json` 取密钥，**脚本与报告里都不含任何明文令牌**）

---

## 0. 结论（一句话）

**交付物清单从数据源起就永远是空的**：网关扫描用的 `session/page` 请求漏了**引擎强制必填**的 `throughSeq`，被引擎的 wire 校验直接拒掉（`gateway/input-invalid`），异常被 `catch` 吞成 `records: []`。因此 `/api/mobile/deliverables` 对**任意会话**都返回 `deliverables: []`，列表根本没有行可点。

同时存在两个**一旦数据通了就会立刻咬人**的下游缺陷：投影缓存文件名判定只覆盖 13.6% 的会话（`cwd` 恒为 `null` → 相对路径解析到 dsh web 进程自己的工作目录），以及 `sendFile` 在文件不存在时**不写任何响应**（下载挂到 App 的 60 秒超时）。

另有**追加必修**的 RC-5：`GET /api/mobile/sessions/*` 通配分支排在功能路由之前，把 `sessions/queue` 当成了会话 id，**队列功能在生产上完全不可达且不报错**（实测返回一个名为 "queue" 的假会话）。已改为"分发前置 + 通配负向守卫"，并补了能覆盖分发顺序的回归锁。

**五处根因全部有直接证据**，均已在真实引擎/活网关上复现。**所有网关改动都需要用户重启 `dsh web` 才生效**（本轮未重启）。

---

## 1. 根因（RC-1…RC-5）

### RC-1 —— `session/page` 缺 `throughSeq`：扫描数据源 100% 失效【致命、直接成因】

`dsh-server-plugin/lib/index.js` 的 `readSessionRecords()` 旧代码发的是：

```js
{ address: { kind: 'session', sessionId }, maxMessages: 200 }   // 缺 throughSeq
```

**证据 A —— 引擎 wire 模式（`throughSeq` 必填，`maxMessages` 可选）**

`@deepseek-ai/dsh-api-session-controller/lib/typert.host.js`：

```js
'throughSeq': z.number().readonly(),                    // 第 630 行：无 .optional()
'maxMessages': z.number().readonly().optional(),        // 第 632 行：可选
```

同一包 `lib/types/types.d.ts`：

```ts
export interface SessionPageRequest {
    readonly address: SessionAddress;
    readonly throughSeq: number;      // ← REQUIRED
    readonly beforeSeq?: number;
    readonly maxMessages?: number;
    readonly turnWindow?: { readonly minMessages: number; readonly minTurns: number };
}
```

**证据 B —— 活引擎 A/B（唯一变量就是 `throughSeq`）**

```
{address, maxMessages:200}                 => ok=false err=gateway/input-invalid
   "typert gateway: session/page: wire field \"request\" failed boundary validation"
{address, throughSeq:1e15, maxMessages:50} => 越过 wire 校验（进入会话查找阶段）
```

在 120 个真实会话上扫描：修好形状后 **114 个成功返回记录**（共 102,627 条事件），唯一的差异就是补上了 `throughSeq`。

**证据 C —— 活网关端到端（最关键的一条）**

会话 `session-b014a73e-90d9-4160-a084-d6dea8cbe435` 里**确实**存在真实交付物事件：

```json
{"type":"deliverables/presented","seq":4061,"data":{"turn":10,"files":[
  {"path":"E:\\workspace\\个人\\dsh_mobile\\DSH-Mobile-v1.13.0-新功能与验收清单.docx"}]}}
```

但活网关返回：

```
GET http://127.0.0.1:3088/api/mobile/deliverables?sessionId=session-b014a73e-…
→ {"ok":true,"code":0,"deliverables":[]}
```

**证据 D —— 下载侧同样 403**

```
GET /api/mobile/deliverables/download?...&path=<上面那个真实路径>
→ http=403  {"ok":false,"code":403,"error":"该文件不在本会话的交付物清单中"}
```

（403 是"declared 集合为空"的正确结果，不是判定逻辑的 bug。）

**为什么一直没被发现**：`tests/unit/features.test.mjs` 里所有路由测试都把 `readSessionRecords` 当**注入依赖**（`readSessionRecords: async () => overrides.sessionRecords`）。单测覆盖的是路由，**从不覆盖请求形状**，所以这个 bug 有测试也照样出厂。

---

### RC-2 —— 投影缓存文件名判定只覆盖 13.6% 的会话：`cwd` 恒为 `null`【下游致命】

`readSessionCwd()` / `readProjectionRows()` 旧代码先剥掉 `session-` 前缀，再无脑读 `${clean}.json`。

**证据 —— 实测 2468 个缓存文件名的两种形态**

```
projcache files 2468  with identity.cwd 2468  with turnBoundary.seq 2468
文件名形态： session-<uuid>.json = 2133 ｜ <uuid>.json = 335
能命中旧 "<clean>.json" 查找的文件 = 335  →  仅 13.6%
```

具体到 `session-03ba0334-462f-4838-beac-783599a96e08`：旧查找目标 `03ba0334-….json` **不存在**，真实文件是 `session-03ba0334-….json`。

**活网关证据**

```
GET /api/mobile/workspace/changes?sessionId=session-b014a73e-…
→ {"ok":true,"code":0,"available":false,"reason":"no-workspace","files":[]}
```

该会话的 `identity.cwd` 实际是 `E:\workspace\个人`（同一缓存文件里就有）。所以 `readWorkspaceChanges()` 的 `no-workspace` 是**假阴性**。

**后果链**：`cwd = null` → `extractDeliverables(records, null)` 里 `path.resolve('.', raw)` 用**dsh web 进程自己的工作目录**解析相对路径 → 得到一个并不存在的绝对路径 → 该路径**同时进入清单和下载校验**（所以 200/403 判定自洽），但落到 `fs.statSync` 时必然抛异常 → 触发 RC-3。

真实事件里相对路径是主流（例：`数据库变更/2026-10-09_月续基数导入2026-10/03_变更记录.md`、`GzSkymis\src\com\sky\mis\db\dao\CustomerDAO.java`），所以这条会命中绝大多数交付物。

---

### RC-3 —— `sendFile` 失败时不写响应：下载挂死到 60 秒超时 = 用户眼里的「点不开」【下游致命】

`dsh-server-plugin/lib/index.js`：

```js
function sendFile(absPath, displayName) {
  let stat;
  try { stat = fs.statSync(absPath); } catch { resolve(false); return; }  // ← 什么都不写
  if (!stat.isFile()) { resolve(false); return; }                         // ← 什么都不写
  ...
}
```

而路由侧旧代码把它当"发完就完"：

```js
await deps.sendFile(row.path, row.display);
return true;                     // ← 没有基于返回值的错误分支
```

**后果**：socket 保持打开、无任何响应。App 侧 `task_center_view.dart` 的 `_openDeliverable` 是 `http.get(...).timeout(const Duration(seconds: 60))`，于是用户看到的是**转圈 60 秒后弹一句泛化的超时提示**——这正是"点不开"的体感。配合 RC-2，相对路径交付物**必然**走到这条路径。

---

### RC-4 —— `maxMessages` 是"消息数"预算且从旧端截断：静默丢交付物【即使修好 RC-1 也会漏】

`maxMessages` 只统计 `user/message` / `assistant/message`（`history.js` `MESSAGE_TYPES` + `isAppendSurfaceEvent`），事件本身不计入。实测：

| 会话 | maxMessages | 返回 records | 覆盖 seq | 页内交付物事件 |
|---|---|---|---|---|
| `a98ee935`（cursor 3019，共 8 个交付物事件）| 200 | 1393 | [1627..3019] | **6**（丢 seq 439、1503）|
| 同上 | 2000 | 3020 | [0..3019] | **8** |

载荷代价：同会话 `maxMessages=200` → **3.9 MB**，`500` → 7.9 MB，全量 → 11.2 MB。所以"加大 maxMessages"是错的轴：既贵又不保证完整。

（旧注释"present 声明很少、页面携带最新事件就够了"因此不成立。）

---

### RC-5 —— `sessions/*` GET 通配分支吞掉 `/sessions/queue`【追加必修，T4 独立实测发现并由我复核确认】

`lib/index.js` 只有一个通配分支（全文件仅此一处 `startsWith('/api/mobile/…')`）：

```js
if (pathname.startsWith('/api/mobile/sessions/') && req.method === 'GET') {
  const sessionId = pathname.replace('/api/mobile/sessions/', '').trim();
  const history = await getSessionHistory(sessionId);   // ← "queue" 被当成会话 id
  ...
}
```

而 `handleFeatureRoute` 的调用点原本在它**下方约 420 行**，所以注册在 `/api/mobile/sessions/` 前缀下的 GET 功能路由会被静默吞掉。

**活实例实测（只读 GET，修复前；token 取自 `~/.dsh/mobile-bridge/config.json`）**

| 请求 | 实测响应 | 判定 |
|---|---|---|
| `GET /api/mobile/sessions/queue?sessionId=session-03ba0334-…` | `{"ok":true,"code":0,"data":{"sessionId":"queue","isRunning":false,"model":"cn:deepseek-v4.1-flash","lastTurn":null,"messages":[]}}` | **被吞**（伪造出一个叫 "queue" 的空会话）✗ |
| `GET /api/mobile/sessions/archive` | `{"data":{"sessionId":"archive",…}}` | 同样被吞，但 `/sessions/archive` **只有 POST 路由**，无功能损失（同一个坑） |
| `GET /api/mobile/sessions/search?q=x` | `{"ok":true,"code":0,"query":"x","results":[…]}` | 正常（早先已单独排除）✓ |
| `GET /api/mobile/schedules?sessionId=…` | `{"ok":true,"code":0,"schedules":[]}` | 正常（不在该前缀下）✓ |
| `GET /api/mobile/jobs?sessionId=…` | `{"ok":true,"code":0,"jobs":[]}` | 正常 ✓ |
| `GET /api/mobile/session/stats?sessionId=…` | `{"ok":true,"code":0,"stats":{…}}` | 正常 ✓ |
| `GET /api/mobile/workspace/changes?sessionId=…` | `{"ok":true,"code":0,"available":false,"reason":"no-workspace","files":[]}` | 路由可达（返回值错是 RC-2）✓ |
| `GET /api/mobile/push/config` | `{"ok":true,"code":0,"push":{…}}` | 正常 ✓ |

**逐项结论**（不是"看代码推断"）：**只有 `GET /api/mobile/sessions/queue` 一条功能路由被遮蔽**。
- 通配分支**只有一个且仅匹配 GET** → 所有 POST 功能路由（`sessions/queue`、`schedules/delete`、`jobs/kill`、`push/*`）都不受影响；
- 其余新路由（`schedules` / `jobs` / `deliverables` / `deliverables/download` / `session/stats` / `workspace/*` / `push/*`）都**不在** `/api/mobile/sessions/` 前缀下，实测全部可达。

**后果**：队列 GET 在生产上不可达。App 拿不到 `data['queue']` 就当空数组且不置错（`dsh_service.dart` 的 `fetchQueue`），于是**永远显示"没有排队消息"——看起来像正常状态**。

**为什么有单测也没拦住**：`tests/unit/features.test.mjs` 只 import `features.mjs` 的纯函数与 `handleFeatureRoute`，**从不 import `index.js`**，所以两处分发器的**先后顺序**零覆盖——这正是 F2 能活下来的原因。

---

## 2. 已排除的怀疑点（有证据的反证，不是"大概率没问题"）

| 怀疑点 | 结论 | 证据 |
|---|---|---|
| (d) App 与网关的 query 参数名不一致 | **无缺陷** | App `deliverableUrl()` 用 `path`，网关读 `parsedUrl.query?.path`（`features.mjs`）——逐字一致 |
| (d) `sessionId` 前缀形态不一致 | **无缺陷** | App `fetchDeliverables` 传 `_currentSession.sessionId`；网关两处都用 `toFullSessionId()` 归一化。实测 `session-<uuid>` 与裸 `<uuid>` 均可用 |
| (c) 下载请求鉴权头 | **无缺陷** | `authHeadersForDownload => _authHeaders` 同时带 `Authorization: Bearer …` 与 `x-dsh-token`（`dsh_service.dart` 的 `_authHeaders` getter），与 `core.mjs extractToken()` 接受的头一致 |
| (c) `sendFile` 的 Content-Length / Content-Type | **正确** | `writeHead(200, {'Content-Type':'application/octet-stream','Content-Length':stat.size, 'Content-Disposition': filename*=UTF-8''…})`，用真实 `stat.size` |
| (e) FileProvider authority 与 manifest 不一致 | **无缺陷** | `MainActivity.kt:251` 用 `"$packageName.fileprovider"`；manifest `android:authorities="${applicationId}.fileprovider"`；`app/build.gradle:52` `applicationId = "com.example.dsh_mobile"`，**无 `applicationIdSuffix`** → 三者恒等 |
| (e) `file_paths.xml` 未覆盖落盘目录 | **无缺陷** | 代码写 `cacheDir/deliverables/`（`MainActivity.kt:244`）；`file_paths.xml` 声明 `<cache-path name="deliverables" path="deliverables/" />` —— 精确匹配 |
| (e) `openBytes` 静默吞异常 | **设计如此且如实回传** | `openBytesInSystemApp` 捕获异常 `return false`；`FileOpener.openBytes` 返回 `false`；调用方 toast「已下载，但没有应用能打开」。空字节提前返回 `false`。**不是**静默失败 |
| 文件名/扩展名丢失 | **无缺陷** | `DeliverableItem.fileName` 取 `display` 的 basename，扩展名保留；原生侧 `MimeTypeMap` 由扩展名推 mime |
| (f) `session/projections` 能否给 cursor / cwd | **不能** | 活会话 projections 返回 22 个投影行，**不含 `turnBoundary`**；`session/list` 的 `SessionSummary` 无序列字段（且探针返回 `gateway/arguments-invalid`）|
| `throughSeq: -1` 是否等于"最新" | **否，返回空页** | 实测 `{throughSeq:-1, maxMessages:50}` → `ok:true, records:0, hasMore:false`；引擎把它映射成 `end = min(-1+1, …) = 0` |

---

## 3. 修复

### 3.1 `dsh-server-plugin/lib/features.mjs`

1. **新增 `collectSessionRecords({ callDshRpc, sessionId, maxPages, messagesPerPage })`** —— 交付物扫描的真正数据源：
   - 先做 **cursor 探针**：`session/page` 传 `throughSeq: Number.MAX_SAFE_INTEGER`，从引擎的 `gateway/bad-request: … is past cursor C` 里取 `C`（**只有 221 字节**）。这是唯一可行的 cursor 来源（`session/projections` 与 `session/list` 都不给，`-1` 返回空页），已在 4/4 会话上验证与引擎 `sourceCursor` 完全相等。
   - 再用 `{ address, throughSeq: cursor, maxMessages, beforeSeq }` **向旧端分页**，`maxMessages: 500` / 最多 `8` 页；按 `seq` 去重、升序返回（`extractDeliverables` 期望的顺序）。
   - 页预算耗尽时返回 `truncated: true` —— **宁可如实说"不完整"，也不静默漏**。
2. **新增 `parseCursorFromPastSeqError(message)`** —— 解析 cursor 探针的报错；形状变了就返回 `null`（退化成"无数据"，绝不给出错误页）。
3. **新增 `projectionCacheFileNames(sessionId)`** —— 同时给出 `<clean>.json` 与 `session-<clean>.json` 两个候选。
4. **新增 `FEATURE_ROUTES` + `claimsMobileFeatureRoute(method, pathname)`** —— 本模块声明的完整 method+path 清单与判定函数，供 `index.js` 的通配分支做负向守卫，并让"清单 vs 真实行为"可被单测互相钉住。
5. **下载路由**：`await deps.sendFile(...)` **检查返回值**，为 `false` 时回 `404`（含 `path`），不再让 socket 悬空。

### 3.2 `dsh-server-plugin/lib/index.js`

1. **`handleFeatureRoute` 的分发整块前移到 `sessions/*` GET 通配分支之前**（RC-5）。
   - 已核对**无反向遮蔽**：把 `index.js` 全部 `/api/mobile/*` 路由与 `features.mjs` 声明面对比，**交集为空**——重排序不会让任何既有路由失去可达性。
   - 同时给通配分支加上 `!claimsMobileFeatureRoute(req.method, pathname)` 守卫：**即使将来有人把分发挪回去，功能路由也不会再被偷走**。
   - 之前只对 `sessions/search` 打过单个补丁；这次改成**排序 + 守卫**，从"再补一个排除项"升级为"这一整类不再复发"。
2. **新增 `readProjectionRecord()`**（用 `projectionCacheFileNames` 逐候选查找），`readSessionCwd()` / `readProjectionRows()` 改走它 → 缓存命中率 13.6% → 100%。
   顺带修好 `/api/mobile/workspace/changes`（假 `no-workspace`）与 `/api/mobile/session/stats` 的缓存回退。
3. **`readSessionRecords()` 改用 `collectSessionRecords()`**，并把 `truncated` 透出去；仍在 RPC 失败时诚实返回空并在日志里写明原因。
4. **`sendFile()` 补文档**：明确 `false` = 一个字节都没写、错误响应归调用方负责（防止将来又有人忽略返回值）。

### 3.3 未改动的文件（经证据判定无需改动）

`dsh_mobile/lib/services/platform_services.dart`、`MainActivity.kt`、`res/xml/file_paths.xml`、`dsh_service.dart` —— 见第 2 节逐条反证。按任务要求**未触碰** `task_center_view.dart` / `chat_view.dart`（由其他成员负责），`FileOpener.openBytes(name, bytes) -> Future<bool>` API 保持不变。

---

## 4. 回归测试

`tests/unit/features.test.mjs` 新增 **7 个**用例，全部钉住被修的具体行为（`node --test tests/unit/features.test.mjs`）：

| 用例 | 钉住的行为 |
|---|---|
| `parseCursorFromPastSeqError: reads the engine cursor, refuses anything else` | 用**真实抓取的报错文本**解析出 `4431`；`not found` / `input-invalid` / `-3` / `undefined` 一律 `null` |
| `collectSessionRecords: every page carries the REQUIRED throughSeq` | **每一次** `session/page` 都带 `throughSeq`（RC-1 的回归锁）|
| `collectSessionRecords: walks backwards with beforeSeq and never truncates silently` | 首页无 `beforeSeq`、后续页 `beforeSeq` = 上一页起始 seq、`throughSeq` 钉在 cursor；结果升序去重且交付物不丢 |
| `collectSessionRecords: page budget exhaustion is reported, not hidden` | 预算耗尽 → `truncated: true` |
| `collectSessionRecords: an unknown session yields no records, not an exception` | 会话不存在 → 空结果，不抛异常 |
| `projectionCacheFileNames: reaches BOTH cache filename spellings` | 两种文件名形态都产出候选（RC-2 的回归锁）|
| `route: deliverable download 404s instead of leaving the socket unanswered` | `sendFile → false` 时必须回 404（RC-3 的回归锁）|
| `route: deliverables reports the scan truncation flag` | 路由透出 `truncated` |
| `claimsMobileFeatureRoute: knows every route handleFeatureRoute really claims` | 对 `FEATURE_ROUTES` 里**每一条**都实跑 `handleFeatureRoute` 并断言返回 `true` → 清单与真实行为不可能漂移（RC-5）|
| `claimsMobileFeatureRoute: a real session id still belongs to history` | 真实 `session-<uuid>` / 裸 uuid 必须**不**被声明（通配分支仍能取历史）；方法敏感（`GET/POST` 不串） |
| `index.js: the feature dispatch precedes the sessions/* GET wildcard` | **顺序不变量**：直接读真实 `index.js` 源文本，断言 `handleFeatureRoute(` 调用点行位**早于** `startsWith('/api/mobile/sessions/')`，且通配块内含 `!claimsMobileFeatureRoute(`（RC-5 的回归锁）|

**回归锁已实测"修复前会变红"**（不只是声称）：

```
# 用旧 index.js（git HEAD 版本）+ 新 features.mjs 跑那一条测试
node --test --test-name-pattern "feature dispatch precedes" tests/unit/features.test.mjs
  ℹ pass 0
  ℹ fail 1
  AssertionError [ERR_ASSERTION]: handleFeatureRoute must run before the sessions/* wildcard
    (dispatch@123732, wildcard@106215)      ← 修复前：分发在通配之后 = bug
# 换回修复后的 index.js
  ℹ pass 1  ℹ fail 0
# 交换前后 index.js 的 SHA256 一致，确认实验未污染工作区
```

**为什么这条用"源文本顺序断言"而不是"绑端口发真请求"**：`index.js` 的请求处理器没有导出，要发真请求就得 `apply()` 起真实 server（绑端口）并让它去连 `ws://127.0.0.1:3080` 的 MUX——在单测里会碰到运行中的引擎，违背本轮"只读探测、不污染"的硬规则。顺序断言精确钉住的就是那条不变量本身，且**已验证修复前为红**；真实的 HTTP 行为另有第 5.2 节的活实例实测覆盖。

**结果**

```
node --test tests/unit/features.test.mjs   →  pass 42 | fail 0 | exit 0
全量单测（9 个文件逐个跑）                  →  9/9 PASS，201 个测试，0 失败（按退出码判定）
node --check features.mjs / index.js        →  通过
flutter analyze --no-pub                    →  No issues found! (3.5s)   [未改任何 Dart/Kotlin]
```

---

## 5. 验证方式：证据链

### 5.1 修复后的数据路径已在**真实引擎**上端到端跑通

用真实签名 cookie 驱动修复后的 `collectSessionRecords` + `extractDeliverables` + 修复后的 `cwd` 查找（脚本 `.probe/verify-fixed-path.mjs`，只读）：

```
##### session-b014a73e-…        cwd = "E:\workspace\个人"
  scan: cursor=4431 pages=2 records=4432 truncated=false
  extractDeliverables -> 1 row(s)
    display="E:\workspace\个人\dsh_mobile\DSH-Mobile-v1.13.0-新功能与验收清单.docx"
    host: OK 5900 bytes        | download-membership: OK

##### session-a98ee935-…        cwd = "E:\workspace\GZ"
  scan: cursor=3019 pages=1 records=3020 truncated=false
  extractDeliverables -> 10 row(s)      ← 旧代码只能看到 6 条
    GzSkymis\src\com\sky\mis\db\dao\CustomerDAO.java     host: OK 78362 bytes  | OK
    …（共 10 条，全部 host: OK，字节数为真实 stat 大小）

##### session-bed3b110-…        cwd = "E:\workspace\GZ"
  extractDeliverables -> 4 row(s)       全部 host: OK

##### session-fdbc3c8c-…  （本机 cursor 最大者，14087）  cwd = "E:\workspace\个人"
  scan: cursor=14087 pages=5 records=14088 truncated=false
  extractDeliverables -> 4 row(s)       全部 host: OK（如 …\dsh_mobile\ANALYSIS-优化与新增功能.md 135922 bytes）

TOTAL deliverable rows recovered by the fixed path: 19
```

**修复前**：这 4 个会话在活网关上都是 `{"deliverables":[]}`（0 条）。
**修复后**：19 条，路径全部落到真实宿主文件、字节数为真实大小、下载成员判定全部 OK。
其中 `a98ee935` 旧代码只能看到 6 条（10 条里的 6 条），修复后 10 条全出；
**本机最长的会话（14088 条事件）用 5 页走完、`truncated: false`**，即 8 页预算在本机全部 2468 个会话上都够用。

### 5.2 真实会话里 `deliverables/presented` 确实存在（数据源不是空集）

对 120 个最近会话做只读扫描：**34 个会话含交付物事件，共 69 条**，全部为 `{turn, callId, files:[{path, description}]}` 形状，与 `extractDeliverables` 期望一致。
（⚠️ 会话日志是**多帧 zstd** 压缩：`zlib.zstdDecompressSync` 只解第一帧，直接 grep/`Select-String` 会**假阴性**——早期用 `user/message` 做对照时命中同样为 0，据此判定"扫描方法无效"，结论只以 RPC 为准。）

### 5.3 用户可执行的验证

> **本轮全部网关改动（RC-1 ~ RC-5）都必须重启 `dsh web` 才生效。** 活实例 PID 47652 当前仍加载旧模块（它正在把 `GET /sessions/queue` 解析成名为 "queue" 的假会话）。本次按硬规则**没有重启**。若本轮还有其他成员改了网关，会合并进**同一次重启**。

1. 重启 `dsh web`（PID 47652）。
2. **RC-5 验证（最快、无需 App）**——修复前返回假会话，修复后必须回队列形状：
   ```
   curl -s -H "x-dsh-token: <token>" "http://127.0.0.1:3088/api/mobile/sessions/queue?sessionId=session-03ba0334-462f-4838-beac-783599a96e08"
   ```
   修复前（已实测）：`{"ok":true,"code":0,"data":{"sessionId":"queue",…,"messages":[]}}`
   修复后期望：`{"ok":true,"code":0,"queue":[…]}`（**必须是 `queue` 键，不能再有 `data.sessionId`**）
3. **RC-1/RC-2 验证**（token 取自 `~/.dsh/mobile-bridge/config.json`）：
   ```
   curl -s -H "x-dsh-token: <token>" "http://127.0.0.1:3088/api/mobile/deliverables?sessionId=session-b014a73e-90d9-4160-a084-d6dea8cbe435"
   ```
   期望：`deliverables` 含 1 条、`path` 为 `E:\workspace\个人\dsh_mobile\DSH-Mobile-v1.13.0-新功能与验收清单.docx`（不再是 `[]`）。
   同法验 RC-2：`/api/mobile/workspace/changes?sessionId=session-b014a73e-…` 应从 `"available":false,"reason":"no-workspace"` 变成 `"available":true` 且带 `E:\workspace\个人` 下的真实变更。
4. **RC-1/RC-3 下载验证**：
   ```
   curl -s -o out.docx -w "%{http_code} %{size_download}\n" -H "x-dsh-token: <token>" \
     "http://127.0.0.1:3088/api/mobile/deliverables/download?sessionId=…&path=E%3A%5Cworkspace%5C个人%5Cdsh_mobile%5CDSH-Mobile-v1.13.0-新功能与验收清单.docx"
   ```
   期望：`200 5900`（**必须核对字节数 = 5900**，不是只看状态码）。
   RC-3 验证：把清单里那个文件**临时改名**后再下载，期望**立刻**得到 `404 {"code":404,"error":"交付物文件在宿主上已不存在或不可读"}`，而**不是**挂满 60 秒超时。
5. 手机装上含本次修复的网关配套版本后，打开任一**有交付物历史**的会话任务页，应能看到实际交付文件并能点开。

---

## 6. 仍未端到端验证的部分（如实声明）

1. **活网关上的 HTTP 路由本身未跑过新代码。** 按硬规则没重启 dsh web，3088 上仍是旧模块。我只验证了路由**以下的**逻辑（`collectSessionRecords` / `extractDeliverables` / `cwd` 查找 / `sendFile` 的返回值契约）在真实引擎上正确，以及路由**以上**的行为由单测钉住。**§5.3 的五个步骤是唯一能补齐这段验证的方式。**
2. **RC-5 的修复只做了"顺序不变量"单测 + 活实例的旧行为实测**，没有在新代码上发过真实 HTTP 请求（同样需要重启）。§5.3 第 2 步是补齐方式。
3. **所述"经过真实请求分发的测试"是"源文本顺序断言 + 清单/行为交叉校验"，不是绑端口发真请求。** 原因见 §4：`index.js` 未导出请求处理器，起真实 server 会去连运行中的引擎 MUX，违背本轮只读硬规则。该断言已实测在修复前变红（`dispatch@123732 > wildcard@106215`），但它是**结构性**而非**行为性**验证——若将来有人把 `handleFeatureRoute` 整块搬走而源文本顺序侥幸不变，这条测试不会发现。
4. **`sendFile` 的 404 分支只做了单测验证**，没有对活实例发过"清单里存在但宿主文件已删"的真实请求（需要先让清单非空，而那要求重启）。
5. **`/api/mobile/deliverables` 的首次响应时延/载荷未在活实例上实测。** 修复后它是"1 次 cursor 探针 + 1~8 页"，实测单页最坏约 7.9 MB（长会话）。浏览器/手机端的实际耗时未测。已用 `truncated` 兜住正确性，但**性能未验证**。
6. **App 侧未重装 APK 实测。** `flutter analyze` 干净，但"点一下真能拉起系统应用"这一步需要真机 + 重装；且本次**没有改任何 Dart/Kotlin 文件**（判定为无缺陷），所以这条风险不变、也未被本次修复改善。
7. **我无法复现"用户确实看到了可点的行"。** 现有 App 代码里 `_deliverables` **只有** `/api/mobile/deliverables` 一条写入路径（`dsh_service.dart` 的 `fetchDeliverables()`；WS `deliverables` 帧只触发 `fetchDeliverables()`，不直接装行）。既然该路由此前对**所有**会话都返回 `[]`，用户当时应看到的是「这次任务还没有声明交付文件」提示而非可点条目。**"点不开"最可能是对"交付物功能完全拿不到东西/点了没反应"的整体描述**；我能证明的是数据路径返回 0 条、下载返回 403 / 会挂到 60 秒超时，**不能证明**用户当时点到了一个真实渲染的行。如果用户的现场是"看得到行"，那还需要一线现场证据（截图/录屏或 `adb logcat` 里 `[DshService] fetchDeliverables` 与 HTTP 码），因为这与当前代码的唯一写入路径矛盾。

> 注：本报告中 App 侧（`dsh_mobile/lib/**`）的引用一律用**符号名**而非行号——该目录由 T2/T3 并行修改，行号在持续移位。已知 T2/T3 已在 `dsh_service.dart` 的 `fetchQueue()` 里为 RC-5 补了 `_queueKnown` 三态（"200 但没有 `queue` 字段"不再被当成空队列），与本次网关侧修复方向一致。
8. **`maxPages: 8` × `messagesPerPage: 500` 的截断边界未在本机触达。** 本机 cursor 最大的会话（14087 / 14088 条事件）用 **5 页**走完且 `truncated: false`，说明本机 2468 个会话里没有一个需要超过 8 页。因此"预算耗尽 → `truncated: true` → 少列最老交付物"这条降级路径**只有单测覆盖，没有真实数据出现过**；它只在比本机最长会话还长（>4000 条 user/assistant 消息）的会话上才会发生。
9. **`cwd` 为 `null` 的会话**（无投影缓存文件）未被本次修复覆盖：相对路径仍会解析到 dsh web 进程目录。本机 2468/2468 都有缓存文件，所以此路径未在真实数据上出现过。
