# dsh-mobile

DeepSeek Harness（DSH）的手机端控制台 + 配套网关插件。

```
dsh_mobile/          Flutter Android 客户端（本仓库的主体）
dsh-server-plugin/   Node.js 网关插件，跑在 DSH 宿主机上
tests/               网关插件的测试（node --test），分层见 docs/TESTING.md
scripts/             手动工具：等 APK 构建产物、读 APK 版本号
docs/                测试分层说明（TESTING.md）
docs/archive/        历史设计与排查记录（只作证据，描述的状态可能已修复）
```

---

## 一、环境要求

| 项 | 版本 | 说明 |
|---|---|---|
| Flutter | 3.24.5 | Dart 3.5.4。`pubspec.yaml` 里 `speech_to_text` 被钉在 6.6.2，原因见该依赖上方的注释 |
| Node | >= 22.15.0 | 跑网关插件和测试。低版本会让 `sessiontitle` 那批用例在 CI 上 INVALID，见 `package.json` 的 `engines` |
| Android SDK | 带 Command-line Tools | 只编 APK 时需要 |

```bash
# 客户端
cd dsh_mobile
flutter pub get
flutter analyze          # 必须零问题（CI 用 --fatal-warnings）
flutter test

# 网关测试
cd ..
npm test                 # 只跑 hermetic 单测，见下
```

---

## 二、测试：哪些能随手跑，哪些会烧真钱

`package.json` 的每个 script 都带 `//` 前缀的注释说明它的危险性，这里概括：

| 命令 | 会碰什么 | 能随手跑吗 |
|---|---|---|
| `npm test` / `npm run test:unit` / `verify` | 全部 hermetic：用 `mkdtempSync` 隔离 `DSH_HOME`，**零次**真实网关调用，不建会话、不打 LLM、不改真实配置 | ✅ 唯一可以随手跑的 |
| `npm run test:e2e` / `test:live` / `test:tier1..4` | 打真实网关 `:3088`，在真实工作区建会话，消耗真实 LLM token | ⚠️ 显式指名才跑 |
| `npm run test:destructive` | 改你的真实策略（`~/.dsh`）与真实工作区文件；已接入 `tests/e2e/helpers/guard.js` 的快照-恢复，但恢复只覆盖登记过的字段 | 🛑 跑前备份 `~/.dsh/mobile-access/permissions.json` |

完整清单、备份步骤与目录布局见 [docs/TESTING.md](docs/TESTING.md)。

测试跑出的空会话用手动清理：

```bash
npm run test:sweep                    # 只归档空会话
DSH_E2E_FORCE=1 npm run test:sweep    # 连有内容的也归档（危险）
```

---

## 三、发布 APK

版本号唯一真源是 `dsh_mobile/pubspec.yaml` 的 `version: x.y.z+n`。

```bash
git push origin main
```

**触发条件是「push 到 main」，不是打 tag**（2026-10-17 核对工作流后更正：本文档此前写的是
`git tag v1.18.0 && git push origin v1.18.0`，而 `build-apk.yml` 的 `on:` 只有
`branches: [main, master]` + `pull_request` + `workflow_dispatch` —— 没有 `tags:`，
所以推 tag 不会触发任何构建；release job 的 `if:` 也明确要求
`github.event_name == 'push' && github.ref == 'refs/heads/main'`）。

`.github/workflows/build-apk.yml` 会读 pubspec 里的版本、按 ABI 拆分构建，然后**按该版本
自动创建（或更新）GitHub Release `v<version>`**，release notes 取 `CHANGELOG.md` 里
`## [<version>]` 那一节的正文（取不到就退回提交列表）。因此：

- 发布 = 改 `pubspec.yaml` 的版本号 + 写 `CHANGELOG.md` 同名小节 + push 到 main；
- 同一个版本号重复 push 会**更新**同一个 release（不会产生第二个），资产被覆盖；
- tag 不必打，打了也不会触发构建 —— 真要和 tag 对齐，只能是 `v<version>` 与 pubspec 一致时
  手工补一个，纯属文档性标记。

App 里的版本号**不是手抄的**：CI 解析 pubspec（外加 `android/app/build.gradle` 的
`applicationId`）后，通过 `--dart-define=APP_VERSION/APP_BUILD/APP_PACKAGE_NAME`
注入 `flutter build apk`；本地跑同一个脚本，不必记参数：

```bash
node scripts/app-version.mjs            # 看版本真源
cd dsh_mobile && flutter run $(node ../scripts/app-version.mjs --defines)
```

新增任何 `flutter build` / `flutter run` 步骤（含 CI 里按 ABI 拆分的那一步）都要带上
这三个 `--dart-define`，漏了就会退回 `lib/models/app_version.dart` 里的兜底默认值。

```bash
scripts/await-apk.mjs <commit>    # 等 CI 出包并下载
```

仓库里**不留历史 APK**：根目录原本堆的 5 个（v1.0.0~v1.3.0，约 112 MiB）与
`dsh-server-plugin/public/` 里的 6 个（v1.2.1~v1.2.6，约 135 MiB）均已删除。

**2026-10-21 起网关也不再托管安装包**：`/dsh-agent.apk` 与
`/api/mobile/download/apk` 两个路由已移除，`public/` 里不留任何 APK，网关也不再
从 Release 抓包回本地。安装包的唯一来源是 **GitHub Releases** —— App 的更新检查
直接读 `releases/latest/download/latest.json`（见 `models/update_service.dart`），
DSH 设置页与网关首页只给 Releases 链接。

之所以把「自动从 Release 取回本地缓存」一起删掉：那层缓存必须与远端版本对齐，
一旦某次忘记刷新就会长期静默发旧包（1.31.1 事故），而它本身不带来任何业务价值。

历史版本走 GitHub Releases。

---

## 四、凭据与网络

- **凭据**：token / authCode 走 Android Keystore（AES-256/GCM，密钥不可导出）。
  迁移先写后校验，失败保留明文兜底；Android 5/6 或 Keystore 故障时同样降级。
- **TLS**：网关可同时监听明文 `3088` 与自签 HTTPS/WSS `3443`。App 的 REST 与
  WebSocket **共用同一套 TOFU 指纹校验**：首次信任，指纹变化时阻止连接并要求确认。
- **明文**：`3088` 仍可用，但 Token 会明文过网；只建议可信局域网。远程连接请启用
  HTTPS/WSS，或使用带公开证书的 cloudflared / 反向代理。
- **配对码**：只能由电脑端设置页或持有管理 Token 的管理端生成。匿名来源（包括
  经隧道回源、看起来像回环的请求）一律 `403`。
- **真机验证**：Keystore 的厂商 ROM 差异仍建议真机验收，步骤见
  [docs/securestore-device-verification.md](docs/securestore-device-verification.md)。

---

## 五、其他注意事项

- **历史补丁目录 `patches/` 已删除**（原 0001–0003 三个 patch + README）。插件早已从
  单文件 `lib/index.js` 重构成模块（`core.mjs` / `features.mjs` / …），补丁的 hunk 对着
  旧单体行号，`git apply --check` 早就失败；修复本身全部在 `lib/` 里，那些文件只剩考古
  价值。删除记录见 `CHANGELOG.md` 的 `[1.22.0]`。
- **过期文档已收敛，历史内容进 `docs/archive/`。** 已删除：`TEST_READY.md`（自述过期、
  引用的两份规格文件根本不存在）、根目录 `ANALYSIS-优化与新增功能.md`（追加式工作笔记）、
  `TEST_INFRA.md`（目录树与用例数都已过期）。其中仍然成立的部分（hermetic 单测 vs live
  测试的分层、各 script 会碰什么、跑前备份什么）重写为
  [docs/TESTING.md](docs/TESTING.md)。
- **设计与排查记录在 `docs/archive/`**（原仓库根的 `reports/`，2026-10-17 移入）。
  `implementation-audit.md` 与 `deliverable-open-rootcause.md` 描述的 F1/F2/S1 缺陷
  **已修复**，两份文件开头已注明"仅作历史证据"。
