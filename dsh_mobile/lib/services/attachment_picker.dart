import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../models/pending_attachment.dart';

/// 选取图片与文件（§4.2 上传图片/文件，v1.10.0）。
///
/// 这一层刻意只做"把系统选择器的结果变成字节 + 名字 + 媒体类型"这一件事，
/// 不含任何压缩策略之外的业务判断、不发网络请求。原因有两个：
///
/// * 上传需要网关地址与认证头，那属于 [DshService]（它已经持有配置和令牌）；
/// * 选取要调原生插件、在单测里跑不起来，而"超限校验 / base64 编码"这些真正
///   容易出错的逻辑应该被测到 —— 所以它们放在 [PendingImage.fromPicked] 里，
///   这一层保持薄到没有可测的逻辑。
class AttachmentPicker {
  AttachmentPicker._();
  static final AttachmentPicker instance = AttachmentPicker._();

  final ImagePicker _imagePicker = ImagePicker();

  /// 从相册选一张图片，**在选取阶段就压缩**。
  ///
  /// 压缩参数不是随便定的：网关的 JSON 请求体上限 2MB，而图片要 base64 内联
  /// （只有 image part 能让模型看见图片）。手机直出照片通常 3~5MB，编码后
  /// 4~6.7MB，必然超限。1600px / quality 80 一般落在 200~500KB，留有充足余量。
  ///
  /// 只提供相册、不提供拍照：拍照需要在 manifest 里声明 CAMERA 权限，而多要一个
  /// 权限是有实际代价的（用户会看到、部分 ROM 会因此调整行为）。真要拍照，
  /// 用户用系统相机拍完再从相册选，效果一样。等确实有人抱怨再开。
  Future<PickedMedia?> pickImage() => _pickImage(ImageSource.gallery);

  Future<PickedMedia?> _pickImage(ImageSource source) async {
    final picked = await _imagePicker.pickImage(
      source: source,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 80,
    );
    if (picked == null) return null;
    final bytes = await picked.readAsBytes();
    // image_picker 在本机压缩后统一输出 JPEG（除非原图是 PNG 且未压缩），
    // 所以按扩展名判断，兜底给 jpeg 而不是 octet-stream —— 后者会被引擎拒绝，
    // 因为 image part 的 mediaType 必须是 image/*。
    final mime = _mimeFor(picked.name, fallback: 'image/jpeg');
    return PickedMedia(bytes: bytes, name: picked.name, mimeType: mime);
  }

  /// 选任意文件。
  ///
  /// 用 withData 直接把字节读进内存：走的是独立的原始字节上传路由（32MB 上限），
  /// 不经过 JSON，所以不需要压缩。代价是内存占用等于文件大小，
  /// 由 [maxUploadBytes] 在上传前兜住。
  Future<PickedMedia?> pickFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    final file = result?.files.single;
    if (file == null) return null;
    final bytes = file.bytes;
    if (bytes == null) return null;
    return PickedMedia(
      bytes: bytes,
      name: file.name,
      mimeType: _mimeFor(file.name),
    );
  }

  /// 单次上传的字节上限，与网关侧的 MAX_UPLOAD_BYTES 保持一致。
  ///
  /// 故意在 App 侧也判一次：让用户在选完文件的那一刻就知道太大，而不是等传完
  /// 32MB 才被服务端拒绝 —— 他可能正在用流量。
  static const int maxUploadBytes = 32 * 1024 * 1024;

  /// 按扩展名推断媒体类型。认不出就给 octet-stream。
  ///
  /// 不引 mime 包：这里只需要覆盖用户实际会发的类型，多一个依赖换不来什么。
  static String _mimeFor(String filename, {String fallback = 'application/octet-stream'}) {
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return fallback;
    switch (filename.substring(dot + 1).toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'bmp':
        return 'image/bmp';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
      case 'log':
      case 'md':
        return 'text/plain';
      case 'json':
        return 'application/json';
      case 'csv':
        return 'text/csv';
      case 'zip':
        return 'application/zip';
      case 'apk':
        return 'application/vnd.android.package-archive';
      default:
        return fallback;
    }
  }
}
