import 'dart:convert';
import 'dart:typed_data';

/// 附件处理失败。消息面向用户，必须可执行。
class AttachmentError implements Exception {
  final String message;
  const AttachmentError(this.message);
  @override
  String toString() => message;
}

/// 待发送的附件（§4.2 上传图片/文件，v1.10.0）。
///
/// 存在的意义是把"已经准备好、只差发送"这件事变成一个显式对象 —— 用户在输入框
/// 上方能看到它、能删掉它，发送时再由它生成 wire part。这样"附件到底有没有挂上"
/// 永远是可查的，而不是藏在某个 bool 里。
///
/// 两种类型对应引擎的两种 content part（准确的联合类型见
/// `PromptContentPart`，@deepseek-ai/dsh-api-session-controller 的类型声明）：
///
/// * [PendingImage] → `{ type: 'image', mediaType, data: <base64>, name }`
/// * [PendingFile]  → `{ type: 'file', receiptId }`
///
/// **为什么图片不也用 file part**：只有 `image` part 会把图片作为视觉输入交给模型；
/// `file` part 只是一个文件引用，模型看不到内容。用户传一张截图就是想让 agent 看，
/// 所以图片必须走 image part。
sealed class PendingAttachment {
  /// 本地唯一标识，仅用于列表 key 与删除定位（不发给服务端）。
  final String localId;

  /// 展示名，同时作为服务端保存时的文件名。
  final String name;

  /// 原始字节数，用于展示体积。
  final int byteLength;

  const PendingAttachment({
    required this.localId,
    required this.name,
    required this.byteLength,
  });

  /// 转成 prompt 的 content part。发送时调用。
  Map<String, dynamic> toWirePart();

  /// 供 UI 展示的体积文本。
  String get sizeLabel {
    if (byteLength < 1024) return '$byteLength B';
    if (byteLength < 1024 * 1024) return '${(byteLength / 1024).toStringAsFixed(0)} KB';
    return '${(byteLength / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// 图片附件：字节已按 base64 编码好。
///
/// 之所以在**选取时**就编码而不是发送时，是因为编码要和"压缩后是否仍超过网关
/// 2MB JSON 上限"的校验放在一起 —— 超限就该在那一刻告诉用户并阻止挂载，
/// 而不是等他写完一段话、点了发送才失败。
class PendingImage extends PendingAttachment {
  /// 形如 `image/jpeg`。引擎只接受 `image/*`。
  final String mediaType;

  /// 标准 base64（无 data: 前缀）。
  final String base64Data;

  const PendingImage({
    required super.localId,
    required super.name,
    required super.byteLength,
    required this.mediaType,
    required this.base64Data,
  });

  @override
  Map<String, dynamic> toWirePart() => {
        'type': 'image',
        'mediaType': mediaType,
        'data': base64Data,
        'name': name,
      };

  /// 由选取结果构造一个可发送的图片附件。
  ///
  /// 超限时抛 [AttachmentError] 而不是静默丢弃 —— 用户必须知道这张图没挂上，
  /// 否则他会写完一段话、点发送，然后困惑为什么 agent 看不到图。
  static PendingImage fromPicked(PickedMedia media, {required String localId}) {
    if (!media.isImage) {
      throw const AttachmentError('这不是图片文件，请用「文件」入口选择');
    }
    if (media.bytes.isEmpty) {
      throw const AttachmentError('这张图片是空的，换一张试试');
    }
    if (media.bytes.length > maxInlineImageBytes) {
      final mb = (media.bytes.length / (1024 * 1024)).toStringAsFixed(1);
      throw AttachmentError('图片 ${mb}MB 超过内联上限 1.4MB，请先裁剪或压缩后再发');
    }
    return PendingImage(
      localId: localId,
      name: media.name,
      byteLength: media.bytes.length,
      mediaType: media.mimeType,
      base64Data: base64Encode(media.bytes),
    );
  }
}

/// 文件附件：已经上传到引擎、拿到了凭据。
///
/// 之所以先上传再发送，而不是把字节塞进 prompt：prompt 的 JSON 请求体有 2MB
/// 上限，而文件（PDF、日志、压缩包）动辄十几 MB。上传走的是一条独立的原始字节
/// 路由，有 32MB 上限，两者互不影响。
class PendingFile extends PendingAttachment {
  /// 引擎签发的上传凭据，只在接收它的那个会话作用域内有效。
  final String receiptId;

  const PendingFile({
    required super.localId,
    required super.name,
    required super.byteLength,
    required this.receiptId,
  });

  @override
  Map<String, dynamic> toWirePart() => {
        'type': 'file',
        'receiptId': receiptId,
      };
}

/// 一次"选中但还没处理完"的媒体。是选取结果与 [PendingAttachment] 之间的中间态。
class PickedMedia {
  final Uint8List bytes;
  final String name;

  /// 形如 `image/jpeg`；未知时用 `application/octet-stream`。
  final String mimeType;

  const PickedMedia({required this.bytes, required this.name, required this.mimeType});

  bool get isImage => mimeType.startsWith('image/');
}

/// 内联图片的字节上限。
///
/// 网关的 JSON 请求体上限是 2MB，而图片要以 base64 内联进 prompt。base64 会膨胀
/// 4/3，再留出文字、其他 part 与 JSON 结构的余量，所以取 1.4MB 原始字节
/// （编码后约 1.87MB）。
///
/// 之所以用"原始字节"而不是编码后长度做判据：调用方手上就是原始字节，先算
/// base64 长度再拒绝会白做一次编码。
const int maxInlineImageBytes = 1400 * 1024;
