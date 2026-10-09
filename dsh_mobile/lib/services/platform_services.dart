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
        if ((text != null && text.isNotEmpty) || (imagePath != null && imagePath.isNotEmpty)) {
          return SharedContent(text: text ?? '', imagePath: imagePath ?? '');
        }
      }
    } catch (_) {
      // 原生侧没注册（平台不支持）→ 静默无分享，正常路径。
    }
    return null;
  }
}

class SharedContent {
  final String text;
  final String imagePath;
  const SharedContent({required this.text, required this.imagePath});
}
