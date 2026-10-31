/// 按字节魔数识别图片的**真实**类型（v1.39.15）。
///
/// 为什么需要它：扩展名会撒谎，而且撒谎的正是我们自己这条链路。
/// image_picker 在 Android 端缩放图片时（`ImageResizer.createImageOnExternalDirectory`）
/// 是这样决定的：
///
/// ```java
/// boolean saveAsPNG = bitmap.hasAlpha();
/// bitmap.compress(saveAsPNG ? PNG : JPEG, imageQuality, outputStream);
/// ```
///
/// 也就是说**编码格式由位图有没有 alpha 通道决定，与文件名无关**，而输出文件名
/// 却沿用原文件名（`/scaled_ + 原名`）。安卓截图是无 alpha 的 PNG —— 于是产出一个
/// 叫 `scaled_193118.png`、内容却是 JPEG 的文件。
///
/// 引擎侧（`@deepseek-ai/dsh-attachment-local` 的 `inspectMetadata`）会用魔数嗅探
/// 真实类型，一旦和客户端声明的 `mediaType` 不一致就整条拒绝：
///
/// ```
/// Declared image type does not match its bytes.   (IMAGE_TYPE_MISMATCH)
/// ```
///
/// 表现就是 App 里「未送达 · 点此重试」。所以**声明类型必须来自字节，扩展名只能兜底**。
///
/// 只覆盖引擎同样认识的几种位图格式；认不出返回 null（由调用方退回扩展名判断），
/// 不认识的格式去猜反而会造出新的不一致。HEIC 故意不猜：引擎嗅探给的是
/// `image/heif` 一类的名字，猜错又是一个 IMAGE_TYPE_MISMATCH。
String? sniffImageMediaType(List<int> bytes) {
  bool startsAt(int offset, List<int> signature) {
    if (bytes.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }

  if (startsAt(0, const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsAt(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (startsAt(0, const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (startsAt(0, const [0x52, 0x49, 0x46, 0x46]) &&
      startsAt(8, const [0x57, 0x45, 0x42, 0x50])) {
    return 'image/webp';
  }
  if (startsAt(0, const [0x42, 0x4D])) return 'image/bmp';
  return null;
}
