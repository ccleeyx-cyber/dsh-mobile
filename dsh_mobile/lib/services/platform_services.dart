import 'package:flutter/services.dart';

/// 打开外部 URL（APK 下载页等）。
///
/// 走原生 MethodChannel（dsh_mobile/url），不引入 url_launcher ——
/// 只为一个"跳浏览器"动线加一个带 transitive 依赖的插件不划算。
class UrlOpener {
  static const MethodChannel _ch = MethodChannel('dsh_mobile/url');

  /// 返回是否成功拉起。失败（无浏览器等）时调用方应提示改用复制直链。
  static Future<bool> open(String url) async {
    try {
      return await _ch.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// 系统分享入口（SEND intent）。
///
/// 启动/恢复时检查一次；文字填进输入框草稿，图片走附件管线。
/// 用 MethodChannel 而不是 share 插件：我们只需要"读出别人塞过来的内容"，
/// 不需要反向分享。
class ShareReceiver {
  static const MethodChannel _ch = MethodChannel('dsh_mobile/share');

  /// 拉取（并消费）启动时通过 SEND intent 传入的内容。null = 没有待处理分享。
  static Future<SharedContent?> consumePending() async {
    try {
      final raw = await _ch.invokeMethod<dynamic>('consumePending');
      if (raw is Map) {
        final text = raw['text']?.toString();
        final imagePath = raw['imagePath']?.toString();
        final imageName = raw['imageName']?.toString();
        if ((text != null && text.isNotEmpty) || (imagePath != null && imagePath.isNotEmpty)) {
          return SharedContent(
            text: text ?? '',
            imagePath: imagePath ?? '',
            imageName: imageName ?? '',
          );
        }
      }
    } catch (_) {
      // 原生侧没注册（平台不支持）→ 静默无分享，正常路径。
    }
    return null;
  }
}

/// 深链接：`dshmobile://open?session=<id>`（离线推送点开后直达会话）。
///
/// 两个方向都要接：
///  * 冷启动时 Intent 已经在 Activity 里，Dart 起来后主动取一次；
///  * 运行中再点推送 → 原生 `openSession` 反向回调进来。
class DeepLinkReceiver {
  static const MethodChannel _ch = MethodChannel('dsh_mobile/deeplink');

  /// 原生推来的会话 id（运行中收到深链接时）。
  static void Function(String sessionId)? onOpenSession;

  static Future<void> attach() async {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'openSession') {
        final raw = call.arguments;
        final sessionId = raw is Map ? raw['sessionId']?.toString() : null;
        if (sessionId != null && sessionId.isNotEmpty) {
          onOpenSession?.call(sessionId);
        }
      }
      return null;
    });
  }

  /// 冷启动遗留的会话 id，取走即清。null 表示这次启动不是被深链接拉起的。
  static Future<String?> consumePending() async {
    try {
      final raw = await _ch.invokeMethod<dynamic>('consumePending');
      final sessionId = raw?.toString();
      if (sessionId != null && sessionId.isNotEmpty) return sessionId;
    } catch (_) {}
    return null;
  }
}

/// 把字节交给系统应用打开（交付物下载后用）。
class FileOpener {
  static const MethodChannel _ch = MethodChannel('dsh_mobile/file');

  /// 返回是否真的拉起了某个应用。失败时调用方应提示"已下载但没有应用能打开"。
  static Future<bool> openBytes(String name, List<int> bytes) async {
    try {
      return await _ch.invokeMethod<bool>('openBytes', {
            'name': name,
            'bytes': Uint8List.fromList(bytes),
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}

class SharedContent {
  final String text;
  final String imagePath;
  final String imageName;
  const SharedContent({required this.text, required this.imagePath, this.imageName = ''});
}
