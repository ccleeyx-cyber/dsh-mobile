# 测试分层与危险性说明

本文件取代 2026-10-17 删除的 `TEST_INFRA.md`（那份文档的目录树、用例数、缺陷清单
都已过期）。**只保留仍然成立的内容**：哪些命令能随手跑、每个 script 会碰什么、跑之前
要备份什么。

---

## 一、两层，不要混

| 层 | 位置 | 隔离方式 | 能随手跑吗 |
|---|---|---|---|
| **hermetic 单测** | `tests/unit/**/*.test.mjs` | 每个文件用 `mkdtempSync` 造一个一次性 `DSH_HOME`；插件用 mock Cordis ctx 在**空闲端口**上真加载；需要上游时自己起一个假引擎（HTTP + WS），把网关的 MUX 与 `$events/result` RPC 接管掉 | ✅ 唯一可以随手跑的 |
| **live / E2E** | `tests/e2e/**/*.test.js` | 无隔离：打**真实**网关 `127.0.0.1:3088`、在**真实**工作区建会话、消耗**真实** LLM token；其中 destructive 一批还会改你的真实 `~/.dsh` 配置与真实工作区文件 | ⚠️ / 🛑 必须显式指名 |

关键事实：hermetic 单测**零次**真实网关调用、不建会话、不打 LLM、不改真实配置。
`tests/unit/archived-filter.test.mjs` 与 `event-forwarding.test.mjs` 会真的把插件
`apply()` 起来、甚至起一个假上游 —— 但打的是自己起的实例，**绝不碰你正在运行的
dsh web**（3080/3081/3088 始终由真实进程持有）。

`npm test` / `npm run verify` 都等于 `npm run test:unit`，只跑 hermetic 那一层。

---

## 二、每个 script 会碰什么

| 命令 | 会碰什么 | 随手跑？ |
|---|---|---|
| `npm test` / `test:unit` / `verify` | 全部 hermetic：`mkdtempSync` 隔离 `DSH_HOME`，0 次真实调用 | ✅ |
| `npm run test:e2e` / `test:live` | 真实网关 `:3088` + 真实会话 + 真实 token | ⚠️ |
| `npm run test:tier1` ~ `test:tier4` | 同上，按分层切分 | ⚠️ |
| `npm run test:destructive` | 写真实 `~/.dsh` 与真实工作区文件；已接入 `tests/e2e/helpers/guard.js` 的快照-恢复，但恢复只覆盖登记过的字段 | 🛑 先备份 |
| `npm run test:sweep` | 只归档 state 文件里记录过的空会话；`DSH_E2E_FORCE=1` 连有内容的也归档 | 🛑（带 FORCE 时） |

`test:unit` **故意不挂** `--import ./tests/cleanup-hook.mjs`：它一个会话都不建，
挂上反而会让一次"安全"的单测去扫并归档你真实工作区里的遗留会话。所有 live 脚本都挂。

2026-10-17 删除的脚本（此处不再列出命令，只留记录）：`test:challenger` 一族、
`bench` / `bench:policy` / `bench:burst`、`probe:dsh`。它们打真实网关、建真实会话
且创建的会话不进回收表，详见 `CHANGELOG.md` 的 `[Unreleased]`。

---

## 三、跑 live / destructive 之前要备份什么

```powershell
# 1. 全局策略与设备授权（destructive 一批的主战场）
Copy-Item "$env:USERPROFILE\.dsh\mobile-access\permissions.json" `
          "$env:USERPROFILE\.dsh\mobile-access\permissions.json.bak"

# 2. 真实工作区里可能被 memory 测试写到的文件
#    workspace-memory / mobile-developer-memory 会写 MEMORY.md、USER.MD 及其测试副本
# 3. 会话账本：test:sweep 会归档 state 文件里记录过的会话，跑前先看清有哪些
```

`tests/e2e/helpers/guard.js` 的规则：先快照**精确**的原值再改、用 `hasOwnProperty`
恢复（绝不 `orig.x || fallback`，合法的 `0 / false / ''` 必须原样回来）、在 `finally`
里恢复并事后校验是否落地。

---

## 四、目录布局（现状）

```
tests/
├── cleanup-hook.mjs                  # live 脚本的进程退出钩子：归档自己建的空会话
├── unit/                             # hermetic，node --test 默认发现（不传 glob）
│   └── *.test.mjs                    #   见 `cd tests/unit && node --test`
└── e2e/
    ├── helpers/
    │   ├── client.js                 # 复用 REST + WebSocket 客户端（别手写 fetch/WebSocket）
    │   ├── fixtures.js               # 配置常量、令牌、测试负载
    │   ├── guard.js                  # 真实状态快照-恢复（destructive 一批依赖它）
    │   └── session-cleanup.js        # 空会话归档（test:sweep 调用它）
    ├── tier1-features/               # 单点功能：健康/鉴权、会话、prompt/cancel、审批、权限、模型、memory
    ├── tier2-boundary/               # 边界：令牌、sessionId、超大 payload、坏 JSON、路径穿越
    ├── tier3-cross-feature/          # 跨功能：流式+审批、断线重连、权限变更+prompt、双客户端广播
    └── tier4-workloads/              # 多步用户旅程（MW-1/3/4/5）与持久化压力用例
```

`node --test` 的 glob 只写 `**/*.test.js`。**不要把 glob 当参数传给 `node --test`**：
glob 展开是 Node 21+ 才有的，CI 的 Node 22 之外的低版本会把
`"tests/unit/**/*.test.mjs"` 当字面路径报 `Could not find`。`test:unit` 用
`cd tests/unit && node --test` 的默认发现（Node 18 起就有），任何版本都成立；
live 那几个脚本仍用 glob，因为它们只在本地跑、没进 CI。

---

## 五、测试设计方法（live E2E 层仍在用）

1. **类别划分**：鉴权方式（Bearer / `x-dsh-token` / `?token=` / `x-auth-code` / 无）、
   会话生命周期、审批生命周期、权限配置、WebSocket 消息。
2. **边界值**：空/空白/超长/带元字符的令牌与 sessionId；0 字节、1MB、5MB 负载；
   深层嵌套与坏 JSON；未编码参数与路径穿越。
3. **交叉组合**：流式+审批、断线+重连+重同步、权限切换+prompt、双客户端广播、
   会话级模型切换+执行。
4. **端到端旅程**：完整生命周期、审批、弱网恢复、安全策略管理、工作区 memory。

CI 只跑 hermetic 那一层（见 `.github/workflows/bridge-tests.yml`）。
