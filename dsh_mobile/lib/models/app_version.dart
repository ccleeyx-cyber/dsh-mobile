/// Build identity for the app.
///
/// Keep in sync with `pubspec.yaml` (`version: 1.10.6+28`). The bridge exposes a
/// comparable value via `GET /api/mobile/health` as `version`, so the two can be
/// checked against each other.
///
/// NOTE: this duplication is manual and has already drifted — the bridge reports
/// its own `1.2.9` while the app reported `1.3.0`, and the download page said
/// `v1.1.0`. Consolidating the 13 version sites onto a single source of truth is
/// tracked in ANALYSIS-优化与新增功能.md §1.8.
///
/// Do NOT use these strings to decide whether the gateway supports a feature.
/// They drift, and the bridge keeps its own independent numbering. Negotiate by
/// capability instead — e.g. `DshService.archivedFilterSupported` (driven by
/// the `archivedMode` the gateway echoes on `GET /api/mobile/workspaces`) or
/// `DshService.questionsSubscribed` (driven by the gateway answering
/// `subscribe_questions`), since 1.4.1's question/TODO/image features need
/// patch 0003 and an older gateway would silently ignore those frames.
class AppVersion {
  const AppVersion._();

  static const String version = '1.14.2';
  static const String buildNumber = '41';

  /// 客户端更新唯一的真值来源：GitHub Releases。
  ///
  /// 用 `releases/latest` 而不是某个具体 tag —— 它永远指向最新一次发布，不需要
  /// 任何人维护。刻意**不**改成"先问网关要最新版本号再比对"：那要求网关侧额外
  /// 配置环境变量（`DSH_LATEST_APP_VERSION`）并手工把 APK 放到盘上，漏一个就会
  /// 对着旧客户端说"已是最新"，比不做更糟。
  static const String releasesUrl =
      'https://github.com/ccleeyx-cyber/dsh-mobile/releases/latest';
}

