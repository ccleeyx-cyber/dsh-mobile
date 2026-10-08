/// Build identity for the app.
///
/// Keep in sync with `pubspec.yaml` (`version:`). The bridge exposes the same
/// value via `GET /api/mobile/health` as `version`, so the two can be compared.
class AppVersion {
  const AppVersion._();

  static const String version = '1.2.9';
  static const String buildNumber = '12';
}
