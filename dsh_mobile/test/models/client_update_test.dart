import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/app_version.dart';
import 'package:dsh_mobile/models/client_update.dart';

/// 客户端更新动线的回归测试。
///
/// 这条路径被改过一次方向，所以要有断言钉住结论：更新**只指向 GitHub Releases**，
/// 不再走"问网关要版本号再比对"。
///
/// 为什么不用网关那套：它要求网关侧额外配置 `DSH_LATEST_APP_VERSION` 并把 APK
/// 手工放进盘里，`/dsh-agent.apk` 还可能是旧文件。任一环节没跟上，界面就会言之
/// 凿凿地说"已是最新" —— 对着一个落后好几版的客户端说这句话，比不做更新检查更糟。
/// 发布页本身没有可漂移的中间状态。
///
/// 后半部分钉住新增的"可选 latest.json 清单"的准入与校验结论：清单**只**能是
/// 加速源，不可用时必须回退，绝不能把"问不到"说成"已是最新"。
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

    test('latest.json 就在发布页的同级约定位置', () {
      expect(
        AppVersion.latestJsonUrl,
        'https://github.com/ccleeyx-cyber/dsh-mobile/releases/latest/download/latest.json',
      );
      expect(AppVersion.latestJsonUrl.startsWith('${AppVersion.releasesUrl}/download/'), isTrue,
          reason: '同级约定：必须是 releases/latest 下的 download 别名，发布方不用额外配置');
      expect(AppVersion.latestJsonUrl.startsWith('https://'), isTrue);
    });
  });

  group('版本真源不漂移（pubspec.yaml 是唯一真源）', () {
    /// 允许 `flutter test` 从包根或仓库根跑。
    File repoFile(String name) {
      final local = File(name);
      return local.existsSync() ? local : File('dsh_mobile/$name');
    }

    test('未注入时，AppVersion 的兜底默认值与 pubspec.yaml 完全一致', () {
      final pubspec = repoFile('pubspec.yaml');
      expect(pubspec.existsSync(), isTrue, reason: '测试工作目录既不是包根也不是仓库根');

      final m = RegExp(r'^version:[ \t]*(\S+)[ \t]*$', multiLine: true)
          .firstMatch(pubspec.readAsStringSync());
      expect(m, isNotNull, reason: 'pubspec.yaml 里必须有 version 行');
      final raw = m!.group(1)!;
      expect(raw.contains('+'), isTrue,
          reason: 'version 必须写成 x.y.z+n —— +n 是 Android versionCode 的来源，缺了没法判断能否覆盖安装');
      final parts = raw.split('+');

      // 构建期用 --dart-define 注入时，AppVersion 读到的应当是注入值；
      // 没有注入（裸 flutter run / flutter test）时，兜底默认值必须与 pubspec 对得上。
      const injectedVersion = String.fromEnvironment('APP_VERSION');
      const injectedBuild = String.fromEnvironment('APP_BUILD');
      if (injectedVersion.isEmpty && injectedBuild.isEmpty) {
        expect(AppVersion.version, parts[0],
            reason: 'pubspec 版本变了，app_version.dart 里 APP_VERSION 的兜底默认值也要跟着改');
        expect(AppVersion.buildNumber, parts[1],
            reason: 'pubspec 构建号变了，app_version.dart 里 APP_BUILD 的兜底默认值也要跟着改');
      } else {
        expect(AppVersion.version, injectedVersion);
        expect(AppVersion.buildNumber, injectedBuild);
      }
      expect(AppVersion.buildCode, int.parse(parts[1]),
          reason: 'buildCode 必须能解析成整数，否则更新比较会恒判"已是最新"');
    });

    test('packageName 与 android/app/build.gradle 的 applicationId 一致', () {
      final gradle = repoFile('android/app/build.gradle');
      expect(gradle.existsSync(), isTrue);
      final m = RegExp(r'''applicationId\s*[=(]\s*["']([^"']+)["']''')
          .firstMatch(gradle.readAsStringSync());
      expect(m, isNotNull, reason: 'build.gradle 里必须有 applicationId');
      expect(AppVersion.packageName, m!.group(1),
          reason: '两者的差集会让 latest.json 的包名校验永远失败');
    });
  });

  group('latest.json 清单：准入判定（纯逻辑，不联网）', () {
    UpdateManifest manifest({
      int schemaVersion = 1,
      String version = '1.21.0',
      int versionCode = 55,
      String packageName = 'com.example.dsh_mobile',
      String downloadUrl = 'https://github.com/ccleeyx-cyber/dsh-mobile/releases/download/v1.21.0/app.apk',
      int? size,
      String? sha256,
      String? releaseNotes,
    }) =>
        UpdateManifest(
          schemaVersion: schemaVersion,
          version: version,
          versionCode: versionCode,
          packageName: packageName,
          downloadUrl: downloadUrl,
          size: size,
          sha256: sha256,
          releaseNotes: releaseNotes,
        );

    UpdateCheck admit(UpdateManifest m, {int currentVersionCode = 55}) =>
        UpdateCheck.fromManifest(
          m,
          currentVersionCode: currentVersionCode,
          currentPackageName: 'com.example.dsh_mobile',
        );

    test('versionCode 严格更大才算有新版', () {
      expect(admit(manifest(versionCode: 56)).verdict, UpdateVerdict.available);
      expect(admit(manifest(versionCode: 56)).hasUpdate, isTrue);
    });

    test('versionCode 相等或更小一律是"已是最新"（同码装不上）', () {
      expect(admit(manifest(versionCode: 55)).verdict, UpdateVerdict.upToDate);
      expect(admit(manifest(versionCode: 54)).verdict, UpdateVerdict.upToDate);
    });

    test('包名不符直接拒绝（清单不是给本应用的）', () {
      final c = admit(manifest(versionCode: 99, packageName: 'com.other.app'));
      expect(c.verdict, UpdateVerdict.manifestRejected);
      expect(c.hasUpdate, isFalse);
      expect(c.note, contains('com.other.app'));
    });

    test('不认识的 schemaVersion 直接拒绝，而不是"尽力解析"', () {
      expect(admit(manifest(schemaVersion: 2, versionCode: 99)).verdict,
          UpdateVerdict.manifestRejected);
    });

    test('结构不合法一律返回 null，绝不抛异常', () {
      expect(UpdateManifest.tryParse(null), isNull);
      expect(UpdateManifest.tryParse('nope'), isNull);
      expect(UpdateManifest.tryParse(<String, dynamic>{}), isNull);
      expect(UpdateManifest.tryParse(<String, dynamic>{'version': '1.21.0'}), isNull);
      // downloadUrl 必须 https：这串 URL 会去拉一个要装到手机上的 APK。
      expect(
        UpdateManifest.tryParse(<String, dynamic>{
          'schemaVersion': 1,
          'version': '1.21.0',
          'versionCode': 56,
          'packageName': 'com.example.dsh_mobile',
          'downloadUrl': 'http://example.invalid/app.apk',
        }),
        isNull,
      );
      // versionCode 必须是正整数。
      expect(
        UpdateManifest.tryParse(<String, dynamic>{
          'schemaVersion': 1,
          'version': '1.21.0',
          'versionCode': 0,
          'packageName': 'com.example.dsh_mobile',
          'downloadUrl': 'https://example.invalid/app.apk',
        }),
        isNull,
      );
      expect(parseUpdateManifestJson('{ not json'), isNull);
      final ok = parseUpdateManifestJson(jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'version': '1.21.0',
        'versionCode': 56,
        'packageName': 'com.example.dsh_mobile',
        'downloadUrl': 'https://example.invalid/app.apk',
        'size': 3,
        'sha256': sha256Hex(utf8.encode('abc')),
        'releaseNotes': '说明',
      }));
      expect(ok, isNotNull);
      expect(ok!.versionCode, 56);
      expect(ok.size, 3);
      expect(ok.releaseNotes, '说明');
    });
  });

  group('下载后的安装前校验', () {
    final abc = utf8.encode('abc'); // sha256 的标准测试向量
    const abcSha = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

    UpdateManifest manifest({int? size, String? sha256}) => UpdateManifest(
          schemaVersion: 1,
          version: '1.21.0',
          versionCode: 56,
          packageName: 'com.example.dsh_mobile',
          downloadUrl: 'https://example.invalid/app.apk',
          size: size,
          sha256: sha256,
        );

    test('sha256 用标准向量钉住实现', () {
      expect(sha256Hex(abc), abcSha);
    });

    test('size（若提供）必须与实际字节数一致，否则拒绝安装', () {
      final r = verifyApkBytes(abc, manifest(size: 4));
      expect(r.verdict, IntegrityVerdict.sizeMismatch);
      expect(r.installable, isFalse);
      expect(r.byteLength, 3);
    });

    test('sha256 匹配且 size 一致 → 通过', () {
      final r = verifyApkBytes(abc, manifest(size: 3, sha256: abcSha));
      expect(r.verdict, IntegrityVerdict.ok);
      expect(r.installable, isTrue);
      expect(r.actualSha256, abcSha);
    });

    test('sha256 不匹配 → 拒绝安装（内容被换过/截断）', () {
      final r = verifyApkBytes(abc, manifest(sha256: List.filled(64, 'a').join()));
      expect(r.verdict, IntegrityVerdict.sha256Mismatch);
      expect(r.installable, isFalse);
    });

    test('sha256 格式不对 → 按不可信处理，不当成"没提供"', () {
      final r = verifyApkBytes(abc, manifest(sha256: 'deadbeef'));
      expect(r.verdict, IntegrityVerdict.sha256Malformed);
      expect(r.installable, isFalse);
    });

    test('清单没给 sha256 → 如实标注未校验，但仍允许安装', () {
      final r = verifyApkBytes(abc, manifest(size: 3));
      expect(r.verdict, IntegrityVerdict.unverified);
      expect(r.installable, isTrue);
      expect(r.note, contains('未校验'));
    });

    test('大小写不敏感的 sha256（清单大写也应能通过比对）', () {
      final r = verifyApkBytes(abc, manifest(sha256: abcSha.toUpperCase()));
      expect(r.verdict, IntegrityVerdict.ok);
    });
  });
}
