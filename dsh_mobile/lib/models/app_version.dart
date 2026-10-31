/// App 的构建身份。
///
/// **唯一真源是 `dsh_mobile/pubspec.yaml` 的 `version: x.y.z+n`**，一路这样走到
/// App 里，中途没有任何人手抄写：
///
///   1. `pubspec.yaml` → `version: 1.23.0+57`
///   2. `scripts/app-version.mjs` 解析出 `1.23.0` / `57` / `com.example.dsh_mobile`
///      （`android/app/build.gradle` 的 `applicationId`）
///   3. CI（`.github/workflows/build-apk.yml`）把三者经
///      `--dart-define=APP_VERSION=... --dart-define=APP_BUILD=... --dart-define=APP_PACKAGE_NAME=...`
///      传给 `flutter build apk`；本地也可以 `flutter run $(node ../scripts/app-version.mjs --defines)`
///   4. 本文件两个 `String.fromEnvironment` 直接读注入值
///
/// 下面的 **default 值只是裸 `flutter run` / IDE 运行时的兜底**，不是第二份真源：
/// 发布产物里的值永远来自第 3 步的注入。它们必须与当前 pubspec 那一行对得上，
/// `test/models/client_update_test.dart` 里有一条"默认值与 pubspec 不漂移"的断言专门
/// 盯这件事（改版本号时它会红，而不是让裸跑的构建悄悄显示旧版本）。
///
/// 网关的 `BRIDGE_VERSION`（`dsh-server-plugin/lib/core.mjs`）**与 App 版本无关**：
/// 两边独立起号、号段不同，任何"App 版本 ≥ 网关版本就说明功能可用"的推断都是错的。
/// 网关支不支持某个功能一律靠**能力协商**判断，例如
/// `DshService.archivedFilterSupported`（由 `GET /api/mobile/workspaces` 回显的
/// `archivedMode` 驱动）或 `DshService.questionsSubscribed`（由网关是否回应
/// `subscribe_questions` 驱动）—— 因为 1.4.1 的提问/TODO/图片功能需要网关侧
/// patch 0003，旧网关会**静默忽略**那些帧，靠版本号猜必错。
class AppVersion {
  const AppVersion._();

  /// 展示用版本号（`x.y.z`），构建期由 pubspec 注入。
  static const String version =
      String.fromEnvironment('APP_VERSION', defaultValue: '1.39.15');

  /// 构建号（pubspec `+n`），即 Android 的 versionCode 来源。
  ///
  /// 更新检查拿它做比较：**必须严格递增**，否则新 APK 装不上去（Android 拒绝
  /// 降级覆盖安装），清单里的 versionCode 也会被判成"没有新版"。
  static const String buildNumber =
      String.fromEnvironment('APP_BUILD', defaultValue: '104');

  /// 本 APK 的 applicationId。用于校验 `latest.json` 不是给别的应用准备的。
  ///
  /// CI 从 `android/app/build.gradle` 解析后注入；本地裸跑用这里的兜底值。
  static const String packageName = String.fromEnvironment(
    'APP_PACKAGE_NAME',
    defaultValue: 'com.example.dsh_mobile',
  );

  /// `buildNumber` 的整数形式；解析不出来算 0（比任何清单都小 → 不会误判为"已是最新"）。
  static int get buildCode => int.tryParse(buildNumber) ?? 0;

  /// 客户端更新唯一的真值来源：GitHub Releases。
  ///
  /// 用 `releases/latest` 而不是某个具体 tag —— 它永远指向最新一次发布，不需要
  /// 任何人维护。刻意**不**改成"先问网关要最新版本号再比对"：那要求网关侧额外
  /// 配置环境变量（`DSH_LATEST_APP_VERSION`）并手工把 APK 放到盘上，漏一个就会
  /// 对着旧客户端说"已是最新"，比不做更糟。
  static const String releasesUrl =
      'https://github.com/ccleeyx-cyber/dsh-mobile/releases/latest';

  /// 与发布页**同级**的可选清单（GitHub Release 的 `latest` asset 别名）。
  ///
  /// 这是"可选的加速源"，不是必需：取不到就回退到打开发布页（老行为）。有了它才能
  /// 在 App 内拿到 versionCode / size / sha256，从而在把 APK 交给系统安装器之前
  /// 做一次真正的校验（见 `models/client_update.dart`）。
  static const String latestJsonUrl = '$releasesUrl/download/latest.json';
}
