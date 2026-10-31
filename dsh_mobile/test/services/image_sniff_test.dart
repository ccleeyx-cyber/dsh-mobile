import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/pending_attachment.dart';
import 'package:dsh_mobile/services/attachment_picker.dart';
import 'package:dsh_mobile/services/image_sniff.dart';

/// 图片真实类型嗅探（v1.39.15）。
///
/// 钉住的是一个真实线上故障：安卓上选一张 PNG 截图，App 报
/// 「Declared image type does not match its bytes.」，消息未送达。
///
/// 成因不在服务端，而在扩展名撒谎 —— image_picker 在 Android 端缩放时按
/// `bitmap.hasAlpha()` 选编码格式（有 alpha 存 PNG，否则存 JPEG），可是输出文件名
/// 沿用原扩展名。安卓截图是无 alpha 的 PNG，于是产出 `scaled_193118.png` 却是
/// **JPEG 字节**；App 按扩展名声明 `image/png`，引擎用魔数嗅探出 `image/jpeg`，
/// 判 IMAGE_TYPE_MISMATCH 整条拒绝。
///
/// 所以这里的断言只有一条主线：**声明类型必须来自字节**，扩展名只在魔数认不出时兜底。
void main() {
  // 只是头部字节，不需要是能解码的完整图片 —— 嗅探只读魔数。
  final jpegBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]);
  final pngBytes = Uint8List.fromList(
      [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00]);
  final gifBytes = Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
  final webpBytes = Uint8List.fromList([
    0x52, 0x49, 0x46, 0x46, // RIFF
    0x24, 0x00, 0x00, 0x00, // chunk size
    0x57, 0x45, 0x42, 0x50, // WEBP
  ]);
  final bmpBytes = Uint8List.fromList([0x42, 0x4D, 0x36, 0x00]);

  group('sniffImageMediaType', () {
    test('认得出 JPEG / PNG / GIF / WEBP / BMP 的魔数', () {
      expect(sniffImageMediaType(jpegBytes), 'image/jpeg');
      expect(sniffImageMediaType(pngBytes), 'image/png');
      expect(sniffImageMediaType(gifBytes), 'image/gif');
      expect(sniffImageMediaType(webpBytes), 'image/webp');
      expect(sniffImageMediaType(bmpBytes), 'image/bmp');
    });

    test('认不出就返回 null，让调用方退回扩展名判断', () {
      expect(sniffImageMediaType(Uint8List.fromList([])), isNull);
      expect(sniffImageMediaType(Uint8List.fromList([0xFF, 0xD8])), isNull,
          reason: '只有 2 字节，连 JPEG 的三个魔数字节都不够，不能瞎猜');
      expect(sniffImageMediaType(Uint8List.fromList([0x25, 0x50, 0x44, 0x46])),
          isNull, reason: '%PDF 不是图片');
      expect(
          sniffImageMediaType(Uint8List.fromList([0x50, 0x4B, 0x03, 0x04])),
          isNull,
          reason: 'zip 容器（docx/apk）没有图片魔数，不能被猜成图片');
    });

    test('RIFF 头但不是 WEBP（比如 wav）不算 webp', () {
      final wav = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, //
        0x57, 0x41, 0x56, 0x45, // WAVE
      ]);
      expect(sniffImageMediaType(wav), isNull);
    });
  });

  group('回归：scaled_*.png 里其实是 JPEG 字节', () {
    test('名字是 .png、字节是 JPEG → 必须声明 image/jpeg', () {
      // 修复前唯一的判断方式是 `mimeForName(file.name)`，它会给出 image/png → 线上失败。
      expect(AttachmentPicker.mimeForName('scaled_193118.png'), 'image/png',
          reason: '扩展名本身当然还是 png —— 这正是坑所在');

      final mime = sniffImageMediaType(jpegBytes) ??
          AttachmentPicker.mimeForName('scaled_193118.png');
      expect(mime, 'image/jpeg');
    });

    test('整条 wire 上声明对了，引擎就不会判 IMAGE_TYPE_MISMATCH', () {
      final pending = PendingImage.fromPicked(
        PickedMedia(
          bytes: jpegBytes,
          name: 'scaled_193118.png',
          mimeType: sniffImageMediaType(jpegBytes) ?? 'image/png',
        ),
        localId: 'regression-1',
      );
      final part = pending.toWirePart();
      expect(part['type'], 'image');
      expect(part['mediaType'], 'image/jpeg', reason: '声明必须跟着字节走');
    });

    test('反过来也一样：带 alpha 的 PNG 不能被声明成 jpeg（分享入口的老 bug）', () {
      final pending = PendingImage.fromPicked(
        PickedMedia(
          bytes: pngBytes,
          name: 'sticker', // 分享入口会把名字强制补成 .jpg，类型不能再跟着错
          mimeType: sniffImageMediaType(pngBytes) ?? 'image/jpeg',
        ),
        localId: 'regression-2',
      );
      expect(pending.toWirePart()['mediaType'], 'image/png');
    });

    test('魔数认不出时才退回扩展名，且非图片文件不受影响', () {
      final unknown = Uint8List.fromList([0x00, 0x01, 0x02, 0x03]);
      expect(sniffImageMediaType(unknown), isNull);
      expect(AttachmentPicker.mimeForName('a.heic'), 'image/heic');
      expect(AttachmentPicker.mimeForName('工作日报.xlsx'), 'application/octet-stream');
    });
  });
}
