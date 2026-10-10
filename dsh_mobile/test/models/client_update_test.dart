import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/app_version.dart';

/// 客户端更新动线的回归测试。
///
/// 这条路径被改过一次方向，所以要有断言钉住结论：更新**只指向 GitHub Releases**，
/// 不再走"问网关要版本号再比对"。
///
/// 为什么不用网关那套：它要求网关侧额外配置 `DSH_LATEST_APP_VERSION` 并把 APK
/// 手工放进盘里，`/dsh-agent.apk` 还可能是旧文件。任一环节没跟上，界面就会言之
/// 凿凿地说"已是最新" —— 对着一个落后好几版的客户端说这句话，比不做更新检查更糟。
/// 发布页本身没有可漂移的中间状态。
void main() {
  group('客户端更新只指向发布页', () {
    test('releasesUrl 是 releases/latest，而不是某个具体 tag', () {
      expect(
        AppVersion.releasesUrl,
        'https://github.com/ccleeyx-cyber/dsh-mobile/releases/latest',
      );
      // 具体 tag 会随每次发布过期，必须用 /latest 让 GitHub 自己解析。
      expect(AppVersion.releasesUrl.endsWith('/latest'), isTrue);
      expect(RegExp(r'/tag/v\d').hasMatch(AppVersion.releasesUrl), isFalse);
    });

    test('不再把网关上那个可能过期的 APK 当更新来源', () {
      expect(AppVersion.releasesUrl.contains('dsh-agent.apk'), isFalse);
      expect(AppVersion.releasesUrl.contains('127.0.0.1'), isFalse);
      expect(AppVersion.releasesUrl.startsWith('https://'), isTrue,
          reason: '明示 https：这串链接会被交给系统浏览器打开');
    });

    test('展示用的版本号与构建号是分开发布的（构建号必须递增才装得上）', () {
      expect(AppVersion.version, isNotEmpty);
      expect(int.tryParse(AppVersion.buildNumber), isNotNull,
          reason: '构建号必须是整数，否则无法推导 android versionCode');
    });
  });
}
