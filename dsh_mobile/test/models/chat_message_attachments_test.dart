import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/chat_message.dart';

/// 消息级附件与「逐轮权威用量」的解析测试（2026-10-17）。
///
/// 起因是两个用户能直接看到的缺陷：
///
/// * **手机发出去的图片完全不显示**（Web 端有）。引擎把附件记成独立的 content part
///   （`{type:'image'|'file', attachment:{attachmentId, mediaType, width, height, bytes, name}}`），
///   而网关以前只把 `text` part 拼进正文 —— 附件在历史里彻底消失，手机自然什么都拿不到。
/// * **「本轮用量」恒为 `—`**。以前只能靠"回合起止两次 stats 读数相减"，基线没记到就
///   永远出不来；现在网关把该轮各 step 的 `usage` 汇总成 `tokens` 挂在那条 user 消息上。
///
/// 这一层的失败模式是**静默丢字段**（少一个附件、少一个 token 都不报错），所以下面
/// 每条都同时钉住"认得出来"和"坏数据不拖垮整条消息"。
void main() {
  /// 网关回传的形状（与实时 `attachment` 帧同构，见 AttachmentRef.fromJson）。
  Map<String, dynamic> imageAttachment() => {
        'id': 'sha256:d4ca127809edd73b79deb6058647b66cbbd023f99b37a32fc8c02c7622d10305',
        'mimeType': 'image/jpeg',
        'width': 736,
        'height': 1600,
        'bytes': 229795,
        'filename': 'scaled_7125.jpg',
      };

  Map<String, dynamic> fileAttachment() => {
        'id': 'sha256:16bb540d7b4cf587f60ab1b39a1b9144cdd2e31acc87fa768c57a9adc1b77a2c',
        'mimeType': 'application/octet-stream',
        'bytes': 21769,
        'filename': '工作日报.xlsx',
      };

  group('附件解析', () {
    test('图片附件：id / mimeType / 尺寸 / 体积 / 文件名 都要落到 AttachmentRef', () {
      final msg = ChatMessage(
        id: 'm1',
        role: 'user',
        content: '看这张图',
        attachments: [imageAttachment()],
      );

      expect(msg.hasAttachments, isTrue);
      expect(msg.attachments.length, 1);
      final ref = msg.attachments.single;
      expect(ref.id, startsWith('sha256:d4ca'));
      expect(ref.mimeType, 'image/jpeg');
      expect(ref.width, 736);
      expect(ref.height, 1600);
      expect(ref.byteSize, 229795);
      expect(ref.filename, 'scaled_7125.jpg');
      expect(ref.isImage, isTrue);
    });

    test('文件附件也要认，且不能被判成图片', () {
      final msg = ChatMessage(
        id: 'm2',
        role: 'user',
        content: '工作日报.xlsx',
        attachments: [fileAttachment()],
      );
      final ref = msg.attachments.single;
      expect(ref.filename, '工作日报.xlsx');
      expect(ref.isImage, isFalse);
      expect(ref.byteSize, 21769);
    });

    test('一条坏附件只跳过它自己，不拖垮其它附件与正文', () {
      final msg = ChatMessage(
        id: 'm3',
        role: 'user',
        content: '正文必须还在',
        attachments: [
          {'mimeType': 'image/png'}, // 缺 id：AttachmentRef.fromJson 会抛
          'not-a-map',
          imageAttachment(),
        ],
      );

      expect(msg.content, '正文必须还在');
      expect(msg.attachments.length, 1, reason: '坏数据被跳过，好的那条要留下');
      expect(msg.attachments.single.filename, 'scaled_7125.jpg');
    });

    test('没有附件时不带任何字段（hasAttachments=false）', () {
      final msg = ChatMessage(id: 'm4', role: 'user', content: '纯文本');
      expect(msg.hasAttachments, isFalse);
      expect(msg.attachments, isEmpty);
      expect(msg.localImagePreviews, isEmpty);
    });

    test('本机即时预览也算"有附件"', () {
      final msg = ChatMessage(
        id: 'm5',
        role: 'user',
        content: '刚发出的图',
        localImagePreviews: [Uint8List.fromList([1, 2, 3])],
      );
      expect(msg.hasAttachments, isTrue);
      expect(msg.attachments, isEmpty);
      expect(msg.localImagePreviews.single.length, 3);
    });
  });

  group('逐轮权威用量', () {
    test('tokens 落到 turnTokens；字符串数字也读得出来', () {
      expect(ChatMessage(id: 'm6', role: 'user', content: 'x', turnTokens: 12345).turnTokens, 12345);
    });

    test('没给就是 null（不是 0）', () {
      final msg = ChatMessage(id: 'm7', role: 'user', content: 'x');
      expect(msg.turnTokens, isNull);
    });
  });
}
