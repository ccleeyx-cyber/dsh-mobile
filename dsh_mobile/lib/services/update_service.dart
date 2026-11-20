import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/app_version.dart';
import '../models/client_update.dart';
import 'platform_services.dart';

/// 下载 APK 的结果。[bytes] 非空即代表**已通过校验、可以交给系统安装器**。
class UpdateDownload {
  final List<int>? bytes;
  final IntegrityResult? integrity;

  /// 网络/HTTP 层失败原因（非空时 [bytes] 必为 null）。
  final String? error;

  const UpdateDownload({this.bytes, this.integrity, this.error});

  static const UpdateDownload empty = UpdateDownload(error: '没有拿到内容');
}

/// 客户端更新：可选的 `latest.json` 清单 + APK 下载 + 安装交接。
///
/// ## 这个类**只服务 Android**
///
/// 整条动线（latest.json 的 versionCode、按 ABI 拆分的 .apk、交给系统包安装器）
/// 是 Android 的发布形态。iOS 的更新由 App Store / TestFlight 负责 —— 系统不允许
/// 应用自更新，侧载 .ipa 也不是 App 能做的事。所以在 iOS 上 [check] 与 [download]
/// 一律拒绝工作（见 [apkUpdatesSupported]），由 UI 换成"打开发布页 / 去 App Store"，
/// 而不是下载一个在 iOS 上永远装不上的 .apk 文件。
///
/// 设计上的三条硬约束：
///  1. **启动时不查**。没有任何后台/自动检查，只有用户在设置里点「检查更新」才会
///     发这一次请求（和以前"更新只指向发布页"的静默行为一致，只是现在用户主动问
///     时能给出确定答案）。
///  2. **源不可用绝不等于"已是最新"**。[check] 返回 null 表示"问不到"，调用方必须
///     回退到打开发布页；只有真的解析到清单、且 versionCode 不比本机大，才允许说
///     "已是最新"。
///  3. **校验不过就不装**。字节数/哈希任何一项不符都拒绝安装（见
///     [verifyApkBytes]），而不是"装装看"。
///
/// 安装动线复用已有的原生通道（`MainActivity.openBytesInSystemApp`：FileProvider +
/// ACTION_VIEW，MIME 由扩展名推出来，`.apk` 会落到系统包安装器），因此**零新增
/// 原生代码、零新增 pub 依赖**。APK 会先整份读进内存再经 MethodChannel 交给原生
/// （与"打开交付物"同一条路）；按 ABI 拆分后的包约 8 MB，这条路径的开销可以接受。
class UpdateService {
  const UpdateService._();

  static const Duration _manifestTimeout = Duration(seconds: 10);
  static const Duration _downloadTimeout = Duration(minutes: 5);

  /// 本平台是否支持"下载 APK 自更新"。iOS 恒为 false，理由见类注释。
  ///
  /// 用 `defaultTargetPlatform` 而不是 `Platform.isIOS`：后者依赖 dart:io，
  /// 在 widget 测试里会跟着宿主机（macOS/Linux）走，测不出 iOS 分支。
  static bool get apkUpdatesSupported =>
      defaultTargetPlatform != TargetPlatform.iOS;

  /// GitHub 对没有 UA 的请求会 403，显式带上自己的标识（也方便在日志里对账）。
  ///
  /// 平台名不再写死 Android：请求头会出现在网关/发布侧日志里，写错平台会让
  /// 排查"这个 404 是谁打的"变成猜谜。
  static String get _userAgent =>
      'dsh-mobile/${AppVersion.version}+${AppVersion.buildNumber} '
      '(${defaultTargetPlatform == TargetPlatform.iOS ? 'iOS' : 'Android'})';

  static Map<String, String> get _manifestHeaders => {
        'Accept': 'application/json',
        'User-Agent': _userAgent,
      };

  static Map<String, String> get _downloadHeaders => {
        'Accept': 'application/vnd.android.package-archive, application/octet-stream',
        'User-Agent': _userAgent,
      };

  /// 最近一次 [check] 失败的具体原因（成功时清空）。
  ///
  /// 为什么要留这个：以前 check 失败只有 null 一种结果，界面只能说"检查不可用"，
  /// 用户没法区分**清单没上传**（发布侧问题）、**网络到不了 GitHub**（网络问题）
  /// 和 **JSON 坏了**（发布侧问题）。日志里有，但用户看不到日志。
  static String lastFailure = '';

  /// 主动检查更新（用户点击触发）。返回 null = 清单不可用。
  ///
  /// 任何失败（404 没有这个 asset、超时、离线、JSON 坏了、字段不合法）都归到
  /// null，由调用方回退到发布页 —— 功能不会因为新源不可用而变差。
  static Future<UpdateCheck?> check({http.Client? client}) async {
    // iOS 上不查：latest.json 描述的是 Android 包，拿它比版本只会得出
    // "有新版"这种在 iOS 上无法执行的结论。直接回 null（"问不到"），
    // 调用方据此走"打开发布页 / App Store"的回退分支。
    if (!apkUpdatesSupported) {
      lastFailure = 'iOS 版由 App Store 更新，不使用 APK 清单。';
      return null;
    }
    final own = client == null ? http.Client() : null;
    final c = client ?? own!;
    lastFailure = '';
    try {
      final res = await c
          .get(Uri.parse(AppVersion.latestJsonUrl), headers: _manifestHeaders)
          .timeout(_manifestTimeout);
      if (res.statusCode != 200) {
        lastFailure = 'latest.json 返回 HTTP ${res.statusCode}';
        debugPrint('[UpdateService] latest.json HTTP ${res.statusCode} → 视为源不可用，回退发布页');
        return null;
      }
      final manifest = parseUpdateManifestJson(utf8.decode(res.bodyBytes));
      if (manifest == null) {
        lastFailure = 'latest.json 解析不出可用清单（字段缺失或版本号不合法）';
        debugPrint('[UpdateService] latest.json 解析不出可用清单 → 回退发布页');
        return null;
      }
      final check = UpdateCheck.fromManifest(
        manifest,
        currentVersionCode: AppVersion.buildCode,
        currentPackageName: AppVersion.packageName,
      );
      debugPrint(
        '[UpdateService] 清单 v${manifest.version}+${manifest.versionCode} '
        '→ ${check.verdict.name}${check.note.isEmpty ? '' : '（${check.note}）'}',
      );
      return check;
    } catch (e) {
      lastFailure = '请求失败：$e';
      debugPrint('[UpdateService] 检查更新失败: $e');
      return null;
    } finally {
      own?.close();
    }
  }

  /// 下载 APK 并做安装前校验。**校验不过就不返回字节**。
  static Future<UpdateDownload> download(
    UpdateManifest manifest, {
    http.Client? client,
  }) async {
    // 双保险：check() 已经拦过一次，但 download 是公开 API（测试也会直接调），
    // 不能让它在 iOS 上真的去下 8MB 的 .apk。
    if (!apkUpdatesSupported) {
      return const UpdateDownload(error: 'iOS 版不支持通过 APK 更新，请前往 App Store。');
    }
    final own = client == null ? http.Client() : null;
    final c = client ?? own!;
    try {
      final res = await c
          .get(Uri.parse(manifest.downloadUrl), headers: _downloadHeaders)
          .timeout(_downloadTimeout);
      if (res.statusCode != 200) {
        return UpdateDownload(error: '下载失败：HTTP ${res.statusCode}');
      }
      final bytes = res.bodyBytes;
      if (bytes.isEmpty) return const UpdateDownload(error: '下载到的内容是空的');

      final integrity = verifyApkBytes(bytes, manifest);
      debugPrint(
        '[UpdateService] 收到 ${bytes.length} 字节 → ${integrity.verdict.name}: ${integrity.note}',
      );
      return UpdateDownload(
        bytes: integrity.installable ? bytes : null,
        integrity: integrity,
      );
    } catch (e) {
      return UpdateDownload(error: '下载出错：$e');
    } finally {
      own?.close();
    }
  }

  /// 把已校验的字节交给系统安装器。
  ///
  /// 底层是 `MainActivity.openBytesInSystemApp`：写进 `cacheDir/deliverables/`，
  /// 经 FileProvider 授权后用 ACTION_VIEW + `application/vnd.android.package-archive`
  /// 拉起系统包安装器。
  ///
  /// **签名一致性由系统安装器校验**：Android 拿已安装应用的签名去比对，签名不同会
  /// 直接拒绝升级（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`）。App 侧不解析 APK 签名，
  /// 也不假装校验过 —— 最终裁决权本来就在系统手里。
  ///
  /// ⚠️ 需要说明的现实：Android 8.0（API 26）起，应用内拉起安装器要求
  /// `android.permission.REQUEST_INSTALL_PACKAGES`，而本仓库的 AndroidManifest
  /// **没有声明**它（`android/**` 在本轮任务里冻结，不在改动范围内）。因此真机上
  /// 这一步很可能被系统直接拒绝 → 返回 false，UI 回退到"打开发布页"。也就是说这条
  /// 路在补上该权限之前是"能下载能校验、装由系统说了算"，不会比现在更差。
  static Future<bool> handToSystemInstaller(
    UpdateManifest manifest,
    List<int> bytes,
  ) {
    // iOS 上**故意**返回 false：系统没有任何能"安装 .apk"的接口，
    // 经 UIActivityViewController 把 .apk 丢进分享面板只会让用户一脸茫然。
    // 如实回 false，让 UI 显示"请改用 App Store / 打开发布页"。
    if (!apkUpdatesSupported) return Future<bool>.value(false);
    return FileOpener.openBytes('dsh-mobile-${manifest.version}.apk', bytes);
  }
}
