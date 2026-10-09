import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/pending_attachment.dart';

/// 附件的 wire 形状与准入校验（§4.2 上传图片/文件，v1.10.0）。
///
/// 这一层值得单测，是因为它是"模型能不能看见图片"和"请求会不会超限"的唯一
/// 决定点，而且完全不依赖原生插件 —— 选取动作在单测里跑不起来，但真正会出错的
/// 判断（part 形状、大小上限、编码）都在这里。
///
/// part 形状的权威定义是引擎的 `PromptContentPart`
/// （@deepseek-ai/dsh-api-session-controller 的类型声明）：
///   { type:'text', text }
///   { type:'image', mediaType, data:<base64>, name? }
///   { type:'file', receiptId }
/// 形状写错不会在本机报错，只会在真实发送时被引擎判为无效附件。
void main() {
  PickedMedia media(List<int> bytes, {String name = 'a.jpg', String mime = 'image/jpeg'}) =>
      PickedMedia(bytes: Uint8List.fromList(bytes), name: name, mimeType: mime);

  group('PendingImage 的 wire part', () {
    test('形状必须与引擎的 image part 完全一致', () {
      final img = PendingImage.fromPicked(media([1, 2, 3]), localId: 'x1');
      final part = img.toWirePart();

      expect(part['type'], 'image');
      expect(part['mediaType'], 'image/jpeg');
      expect(part['name'], 'a.jpg');
      // data 必须是标准 base64，不能带 data: 前缀 —— 引擎要求 canonical base64。
      expect(part['data'], base64Encode([1, 2, 3]));
      expect(part['data'], isNot(contains('data:')));
    });

    test('base64 在挂载时就编码好，发送时不再计算', () {
      final img = PendingImage.fromPicked(media([9, 9]), localId: 'x2');
      // 直接断言编码结果是合法 base64 且能解回原字节
      expect(base64Decode(img.base64Data), [9, 9]);
    });

    test('byteLength 记录原始字节数（不是编码后长度）', () {
      final img = PendingImage.fromPicked(media(List.filled(1000, 7)), localId: 'x3');
      expect(img.byteLength, 1000);
    });
  });

  group('PendingImage 的准入校验', () {
    test('超限必须抛错，并且消息里给出实际体积', () {
      final tooBig = List.filled(maxInlineImageBytes + 1, 1);
      expect(
        () => PendingImage.fromPicked(media(tooBig), localId: 'x4'),
        throwsA(
          isA<AttachmentError>().having((e) => e.message, 'message', contains('超过内联上限')),
        ),
      );
    });

    test('刚好等于上限必须通过（边界不能误杀）', () {
      final exact = List.filled(maxInlineImageBytes, 1);
      final img = PendingImage.fromPicked(media(exact), localId: 'x5');
      expect(img.byteLength, maxInlineImageBytes);
    });

    test('空图片被拒绝', () {
      expect(
        () => PendingImage.fromPicked(media([]), localId: 'x6'),
        throwsA(isA<AttachmentError>()),
      );
    });

    test('非图片的媒体类型被拒绝（防止从文件入口误挂进 image part）', () {
      expect(
        () => PendingImage.fromPicked(
          media([1], name: 'a.pdf', mime: 'application/pdf'),
          localId: 'x7',
        ),
        throwsA(isA<AttachmentError>()),
      );
    });
  });

  group('PendingFile 的 wire part', () {
    test('只带 receiptId，不带字节', () {
      const f = PendingFile(
        localId: 'f1',
        name: 'report.pdf',
        byteLength: 123,
        receiptId: 'r-abc',
      );
      final part = f.toWirePart();
      expect(part, {'type': 'file', 'receiptId': 'r-abc'});
      // 关键：文件体积可能十几 MB，绝不能出现在 JSON 里。
      expect(part.containsKey('data'), isFalse);
    });
  });

  group('体积展示', () {
    test('按量级切换单位', () {
      expect(
        const PendingFile(localId: '1', name: 'a', byteLength: 512, receiptId: 'r').sizeLabel,
        '512 B',
      );
      expect(
        const PendingFile(localId: '2', name: 'a', byteLength: 2048, receiptId: 'r').sizeLabel,
        '2 KB',
      );
      expect(
        const PendingFile(localId: '3', name: 'a', byteLength: 3 * 1024 * 1024, receiptId: 'r').sizeLabel,
        '3.0 MB',
      );
    });
  });

  group('isImage 判定', () {
    test('只有 image/* 算图片', () {
      expect(media([1], mime: 'image/png').isImage, isTrue);
      expect(media([1], mime: 'application/pdf').isImage, isFalse);
      expect(media([1], mime: 'application/octet-stream').isImage, isFalse);
    });
  });
}
