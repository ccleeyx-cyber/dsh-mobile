import 'dart:convert';

// crypto 3.0.7 目前**已经**在 pubspec.lock 里（transitive 依赖），并且
// .dart_tool/package_config.json 已解析到本机 pub cache，所以这里 import 不需要联网
// `pub get`、也不会改动 lockfile（本任务明确冻结 pubspec.yaml，不能把 crypto 提升为
// 直接依赖，所以显式屏蔽 depend_on_referenced_packages）。
//
// ⚠️ 风险与修法：crypto 是传递依赖，将来某个上层依赖不再带它时，这个 import 会在
// **编译期**失败。届时的正确修法是把 `crypto: ^3.0.7` 写进 pubspec 的 dependencies，
// 而不是删掉哈希校验。之所以仍然这样做：Dart 标准库没有 SHA-256，而"下载完直接交给
// 系统安装器、连哈希都不比一次"是本来可以避免的信任缺口。
// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart' as crypto;

/// SHA-256 的**小写 hex**（与 `latest.json` 里 `sha256` 字段的约定一致）。
String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// 更新清单（`latest.json`）的准入判定结果。
enum UpdateVerdict {
  /// 有可安装的新版。
  available,

  /// 清单有效，但本机已经是最新（versionCode 不比本机大）。
  upToDate,

  /// 清单存在但**不可信**：schema 不认识 / 包名不是本应用 / 链接不是 https。
  /// 这种情况一律当作"没有可用的更新源"，由调用方回退到打开发布页。
  manifestRejected,
}

/// `https://…/releases/latest/download/latest.json` 的内容。
///
/// 约定形状：
/// ```json
/// { "schemaVersion": 1, "version": "1.21.0", "versionCode": 55,
///   "packageName": "com.example.dsh_mobile", "downloadUrl": "https://…/app.apk",
///   "size": 12345, "sha256": "…64 hex…", "releaseNotes": "…" }
/// ```
/// 它**只是可选加速源**：发布方没放这个文件时接口就是 404，客户端回退到发布页，
/// 功能不比以前差。
class UpdateManifest {
  /// 本客户端认得的清单版本。将来字段语义变了才 +1；不认识的版本直接拒绝，
  /// 而不是"尽力解析"——误读一个新格式比没有更新检查更危险。
  static const int supportedSchemaVersion = 1;

  final int schemaVersion;
  final String version;
  final int versionCode;
  final String packageName;
  final String downloadUrl;

  /// APK 字节数；提供则必须与实际下载到的字节数一致。
  final int? size;

  /// APK 的 SHA-256（64 位小写 hex）；提供则必须校验通过才允许安装。
  final String? sha256;

  /// 发布说明（可空）。
  final String? releaseNotes;

  const UpdateManifest({
    required this.schemaVersion,
    required this.version,
    required this.versionCode,
    required this.packageName,
    required this.downloadUrl,
    this.size,
    this.sha256,
    this.releaseNotes,
  });

  /// 解析清单。**任何结构问题都返回 null，绝不抛异常**：一个新引入的源不应该
  /// 让"点一下检查更新"变成崩溃。
  static UpdateManifest? tryParse(Object? decoded) {
    if (decoded is! Map) return null;

    final schemaVersion = _asInt(decoded['schemaVersion']);
    final versionCode = _asInt(decoded['versionCode']);
    final version = _asString(decoded['version']);
    final packageName = _asString(decoded['packageName']);
    final downloadUrl = _asString(decoded['downloadUrl']);

    if (schemaVersion == null || versionCode == null || versionCode <= 0) return null;
    if (version == null || packageName == null || downloadUrl == null) return null;
    // 只接受 https：这串 URL 会直接去拉一个要装到手机上的 APK。
    if (!downloadUrl.startsWith('https://')) return null;

    final size = _asInt(decoded['size']);
    final sha = _asString(decoded['sha256']);
    final notes = _asString(decoded['releaseNotes']);

    return UpdateManifest(
      schemaVersion: schemaVersion,
      version: version,
      versionCode: versionCode,
      packageName: packageName,
      downloadUrl: downloadUrl,
      size: (size != null && size > 0) ? size : null,
      sha256: sha?.toLowerCase(),
      releaseNotes: (notes != null && notes.isNotEmpty) ? notes : null,
    );
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static String? _asString(Object? v) {
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return null;
  }
}

/// 一次更新检查的结论。
class UpdateCheck {
  final UpdateVerdict verdict;
  final UpdateManifest? manifest;

  /// 人类可读的原因，直接进 UI/日志。`available` 时为空串。
  final String note;

  const UpdateCheck._(this.verdict, this.manifest, this.note);

  bool get hasUpdate => verdict == UpdateVerdict.available;

  /// 纯逻辑准入判定（不联网，可单测）：
  ///  * schemaVersion 必须认识；
  ///  * packageName 必须等于本机（防止清单被换成别的应用的 APK）；
  ///  * versionCode 必须**严格大于**本机（等于也不算：装不上，Android 拒绝同码覆盖）。
  static UpdateCheck fromManifest(
    UpdateManifest m, {
    required int currentVersionCode,
    required String currentPackageName,
  }) {
    if (m.schemaVersion != UpdateManifest.supportedSchemaVersion) {
      return UpdateCheck._(
        UpdateVerdict.manifestRejected,
        m,
        '清单约定版本 schemaVersion=${m.schemaVersion}，本客户端只认 '
            '${UpdateManifest.supportedSchemaVersion}',
      );
    }
    if (currentPackageName.isNotEmpty && m.packageName != currentPackageName) {
      return UpdateCheck._(
        UpdateVerdict.manifestRejected,
        m,
        '清单是给另一个应用准备的（${m.packageName} ≠ 本机 $currentPackageName）',
      );
    }
    if (m.versionCode <= currentVersionCode) {
      return UpdateCheck._(
        UpdateVerdict.upToDate,
        m,
        '发布页 versionCode=${m.versionCode}，本机 $currentVersionCode',
      );
    }
    return UpdateCheck._(UpdateVerdict.available, m, '');
  }
}

/// 下载字节的校验结论。
enum IntegrityVerdict {
  /// size（若提供）与 sha256（若提供）全部通过。
  ok,

  /// 清单**没有**提供 sha256 —— 如实标注"未校验哈希"，仍然允许安装。
  ///
  /// Dart 标准库没有 SHA-256，本仓库靠 `package:crypto`（见文件头注释）；
  /// 如果将来 crypto 不可用，这一档也是诚实的降级出口。
  unverified,

  /// 实际字节数与清单的 size 不一致 → 拒绝安装。
  sizeMismatch,

  /// 清单给了 sha256 但格式不对（不是 64 位 hex）→ 拒绝安装（不把它当"没提供"）。
  sha256Malformed,

  /// 哈希对不上 → 拒绝安装。这是最严重的一档：文件在传输中被换掉/截断。
  sha256Mismatch,
}

class IntegrityResult {
  final IntegrityVerdict verdict;

  /// 人类可读结论，直接展示给用户、同时写日志。
  final String note;

  /// 实算出来的哈希（清单没给 sha256 时仍然算，便于排查）。
  final String actualSha256;

  final int byteLength;

  const IntegrityResult({
    required this.verdict,
    required this.note,
    required this.actualSha256,
    required this.byteLength,
  });

  /// 是否允许把这份字节交给系统安装器。
  bool get installable =>
      verdict == IntegrityVerdict.ok || verdict == IntegrityVerdict.unverified;
}

/// 下载完、安装前的校验（**App 侧能做到的部分**）。
///
/// 做不到的部分要说清楚，别假装做了：
///  * **签名一致性由系统安装器校验**：我们只把字节交给系统（FileProvider +
///    ACTION_VIEW），Android 会用已安装应用的签名去比对，签名不同直接拒绝安装。
///    App 自己不解析 APK 签名 —— 那需要重写 zip/APK 签名块解析，且最终裁决权
///    本来就在系统手里。
///  * 哈希只证明"字节与清单一致"，不证明"清单本身可信"。清单来自 https 的
///    GitHub Release，信任根是 TLS + GitHub 账号，这里不做签名链。
IntegrityResult verifyApkBytes(List<int> bytes, UpdateManifest manifest) {
  final actual = sha256Hex(bytes);

  if (manifest.size != null && manifest.size != bytes.length) {
    return IntegrityResult(
      verdict: IntegrityVerdict.sizeMismatch,
      note: '字节数不符：清单 ${manifest.size} 字节，实收 ${bytes.length} 字节',
      actualSha256: actual,
      byteLength: bytes.length,
    );
  }

  // 大小写归一：清单是别人生成的，`SHA256` 字段写成大写 hex 也应当能校验通过。
  final expected = manifest.sha256?.trim().toLowerCase();
  if (expected == null || expected.isEmpty) {
    return IntegrityResult(
      verdict: IntegrityVerdict.unverified,
      note: '清单未提供 sha256，本次未校验哈希（仅比对了字节数）',
      actualSha256: actual,
      byteLength: bytes.length,
    );
  }

  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) {
    return IntegrityResult(
      verdict: IntegrityVerdict.sha256Malformed,
      note: '清单里的 sha256 不是 64 位 hex，无法校验 → 按不可信处理',
      actualSha256: actual,
      byteLength: bytes.length,
    );
  }

  if (actual != expected) {
    return IntegrityResult(
      verdict: IntegrityVerdict.sha256Mismatch,
      note: 'sha256 不匹配：清单 $expected，实际 $actual',
      actualSha256: actual,
      byteLength: bytes.length,
    );
  }

  return IntegrityResult(
    verdict: IntegrityVerdict.ok,
    note: 'sha256 已校验通过（${actual.substring(0, 12)}…）',
    actualSha256: actual,
    byteLength: bytes.length,
  );
}

/// 把清单 JSON 文本解析成 [UpdateManifest]；JSON 本身坏了就返回 null。
UpdateManifest? parseUpdateManifestJson(String body) {
  try {
    return UpdateManifest.tryParse(jsonDecode(body));
  } catch (_) {
    return null;
  }
}
