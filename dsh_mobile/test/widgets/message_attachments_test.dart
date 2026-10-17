import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/services/voice_input_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';
import 'package:dsh_mobile/views/widgets/attachment_tile.dart';

/// 消息级附件的渲染回归（2026-10-17）。
///
/// 起因：**手机自己发出去的图片完全不显示**（Web 端有）。网关侧把非 text part 整段丢了
/// （已修），而聊天页也从来没有渲染过消息级附件 —— 附件只出现在输入框上方那条"本轮
/// 附件"里。这里钉住三件事：服务端图片附件渲染成缩略图、文件附件渲染成文件行、本机刚
/// 发出那张图在自己的字节还在手上时就有预览。
///
/// 正文走 SafeMarkdown（不是 `Text`），所以这些用例**不**断言正文文本 —— 正文有没有
/// 被吞由网关侧的转换测试和 `ChatMessage` 的解析测试负责，混在一起只会让 finder 变脆。
void main() {
  Future<DshService> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dsh = DshService();
    dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-abc', title: 't'));
    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: MaterialApp(
          builder: (ctx, child) => ThemeScope(isDark: false, child: child ?? const SizedBox()),
          home: const ChatView(),
        ),
      ),
    );
    await tester.pump();
    return dsh;
  }

  /// 收尾：拆掉树并把 ChatView 拉起的 VoiceInputService 计时器推完。
  ///
  /// 必须**在每个用例体末尾显式调用** —— 挂在 addTearDown 里来不及：Flutter 的
  /// "Timer is still pending" 检查发生在用例体结束时，早于 tearDown 回调。
  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 22));
    VoiceInputService.instance.debugReset();
  }

  ChatMessage userMsg(String id, String content, {int? seq, List<dynamic>? attachments, List<Uint8List>? previews}) =>
      ChatMessage(
        id: id,
        role: 'user',
        content: content,
        seq: seq,
        timestamp: DateTime.now(),
        attachments: attachments,
        localImagePreviews: previews,
      );

  testWidgets('服务端图片附件渲染成缩略图块（不再是"什么都看不到"）', (tester) async {
    final dsh = await pumpChat(tester);
    dsh.debugSetMessages([
      userMsg(
        'u1',
        '看一下这张截图',
        seq: 1296,
        attachments: [
          {
            'id': 'sha256:d4ca127809edd73b79deb6058647b66cbbd023f99b37a32fc8c02c7622d10305',
            'mimeType': 'image/jpeg',
            'width': 736,
            'height': 1600,
            'bytes': 229795,
            'filename': 'scaled_7125.jpg',
          },
        ],
      ),
    ]);
    await tester.pump();

    expect(find.byType(AttachmentImageTile), findsOneWidget);
    expect(find.text('scaled_7125.jpg'), findsOneWidget, reason: '文件名要能看到，别只给个方块');

    await teardown(tester);
  });

  testWidgets('文件附件渲染成一行文件条（图标 + 文件名 + 体积）', (tester) async {
    final dsh = await pumpChat(tester);
    dsh.debugSetMessages([
      userMsg(
        'u2',
        '把这个迁移过去',
        seq: 340,
        attachments: [
          {
            'id': 'sha256:16bb540d7b4cf587f60ab1b39a1b9144cdd2e31acc87fa768c57a9adc1b77a2c',
            'mimeType': 'application/octet-stream',
            'bytes': 21769,
            'filename': '工作日报.xlsx',
          },
        ],
      ),
    ]);
    await tester.pump();

    expect(find.text('工作日报.xlsx'), findsOneWidget);
    expect(find.byIcon(Icons.attach_file_rounded), findsOneWidget);
    // 文件不是图片：绝不能当成图片去拉缩略图（那会得到一个永久转圈的方块）。
    expect(find.byType(AttachmentImageTile), findsNothing);

    await teardown(tester);
  });

  testWidgets('本机刚发出去的图片：字节还在手上就先显示预览', (tester) async {
    final dsh = await pumpChat(tester);
    // 1x1 PNG。
    final png = <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ];
    dsh.debugSetMessages([
      userMsg('local1', '看图\n\n📎 screenshot.png', previews: [Uint8List.fromList(png)]),
    ]);
    await tester.pump();

    expect(find.byType(Image), findsWidgets, reason: '本地预览必须立刻渲染，不等轮询回包');
    expect(find.byType(AttachmentImageTile), findsNothing, reason: '还没拿到服务端附件，不该凭空造一个');

    await teardown(tester);
  });

  testWidgets('没有附件的普通消息不会多出任何附件块', (tester) async {
    final dsh = await pumpChat(tester);
    dsh.debugSetMessages([userMsg('u3', '纯文本提问')]);
    await tester.pump();

    expect(find.byType(AttachmentImageTile), findsNothing);
    expect(find.byIcon(Icons.attach_file_rounded), findsNothing);

    await teardown(tester);
  });
}
