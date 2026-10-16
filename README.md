# dsh-mobile

DeepSeek Harness（DSH）的手机端控制台 + 配套网关插件。

```
dsh_mobile/          Flutter Android 客户端（本仓库的主体）
dsh-server-plugin/   Node.js 网关插件，跑在 DSH 宿主机上
tests/               网关插件的测试（node --test）
scripts/             手动工具：等 APK 构建产物、读 APK 版本号
patches/             网关的历史补丁（见下方警告）
reports/             设计与排查记录
```

---

## 一、环境要求

| 项 | 版本 | 说明 |
|---|---|---|
| Flutter | 3.24.5 | Dart 3.5.4。`pubspec.yaml` 里 `speech_to_text` 被钉在 6.6.2，原因见该依赖上方的注释 |
| Node | >= 20 | 跑网关插件和测试 |
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
| `npm test` / `npm run test:unit` | 全部 hermetic：用 `mkdtempSync` 隔离 `DSH_HOME`，**零次**真实网关调用，不建会话、不打 LLM、不改真实配置 | ✅ 唯一可以随手跑的 |
| `npm run test:e2e` / `test:tier1..4` | 打真实网关 `:3088`，在真实工作区建会话，消耗真实 LLM token | ⚠️ 显式指名才跑 |
| `npm run test:challenger*` | 同上，且包含并发压测 | ⚠️ |
| `npm run test:destructive` | 改你的真实策略（`~/.dsh`）与真实工作区文件，恢复不可靠 | 🛑 跑前备份 `~/.dsh/mobile-access/permissions.json` |
| `npm run bench` | 30~50 轮反复翻你的真实全局策略，无 before/after 备份 | 🛑 |
| `npm run probe:dsh` | 绕过网关直连引擎建会话，每次跑必泄漏一个真实会话 | 🛑 |

测试跑出的空会话用手动清理：

```bash
npm run test:sweep                    # 只归档空会话
DSH_E2E_FORCE=1 npm run test:sweep    # 连有内容的也归档（危险）
```

---

## 三、发布 APK

版本号唯一真源是 `dsh_mobile/pubspec.yaml` 的 `version: x.y.z+n`。

```bash
git tag v1.18.0 && git push origin v1.18.0
```

`.github/workflows/build-apk.yml` 会读 pubspec 里的版本、按 ABI 拆分构建、发布到
GitHub Releases，release notes 取 `CHANGELOG.md` 对应小节的正文。

```bash
scripts/await-apk.mjs <commit>    # 等 CI 出包并下载
```

---

## 四、已知阻塞：token 还躺在 SharedPreferences 里

网关 token 与 authCode 目前**明文**存在 `SharedPreferences`（`storage_service.dart`，
JSON 序列化进 `dsh_server_config` / `dsh_server_profiles`）。root 设备或 adb 本地可读。

`AndroidManifest.xml` 已设 `android:allowBackup="false"`，挡住云备份，但挡不住本地文件访问。

想迁到 `flutter_secure_storage`（Keystore 背书）的话，先解决这个依赖冲突：

```
speech_to_text 6.6.2  →  js ^0.7.1
flutter_secure_storage 9.x  →  js ^0.6.3     （8.x 及更早同样冲突）
```

即：**必须先放开 `speech_to_text` 的版本钉**，而那又要求升级 Flutter / plugin-loader
（7.x 的 `compileSdk = flutter.compileSdkVersion` 在 3.24.5 上直接构建失败）。
这是一条链，不是一行改动。在那之前，配置页至少会在关闭 HTTPS 时给出明文告警。

---

## 五、其他注意事项

- **`patches/` 里的三个补丁已无法 apply。** 插件从单文件 `lib/index.js` 重构成了模块
  （`core.mjs` / `features.mjs` / …），补丁的 hunk 对着旧单体行号。修复本身都已进
  `lib/`，这些文件只剩考古价值；`patches/README.md` 里"已验证 `git apply --check`
  exit 0"的说法已过期，0004–0006 只存在于文字中。
- **`TEST_READY.md` 已过期**，宣称的用例数与已知失败项都是修复前的状态，引用的两份
  规格文件也已不存在。
- `ANALYSIS-优化与新增功能.md` 是追加式工作笔记，不是设计文档。
