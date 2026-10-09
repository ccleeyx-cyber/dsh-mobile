/// Build identity for the app.
///
/// Keep in sync with `pubspec.yaml` (`version: 1.7.0+19`). The bridge exposes a
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

  static const String version = '1.7.0';
  static const String buildNumber = '19';
}
