import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/task_center.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/services/voice_input_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';

/// Phase 4.7 回归：消息 / 附件 / 产出卡的长按统一成一个 action sheet。
///
/// 这组用例要钉住的是**动作矩阵**（哪个上下文有哪些动作）和**手势边界**
/// （正文长按必须留给系统选词），而不是某条文案。手势边界那两条尤其重要：
///
/// * `长按正文不弹 sheet` —— 若它红了，说明为了做 action sheet 把选词抢掉了，
///   那正是规格明令禁止的"复制一段代码这种最常用操作消失"；
/// * `长按轮首标签行 / 点「⋯」弹 sheet` —— 若它红了，说明非正文区域那条
///   长按动线断了，功能退回成"只有一个按钮"。
void main() {
  const report = DeliverableItem(
    path: r'E:\workspace\个人\dsh_mobile\out\报表.xlsx',
    display: r'out\报表.xlsx',
    description: '本月汇总',
    turn: 3,
    seq: 30,
  );

  const sheetKey = ValueKey('message-actions-sheet');

  Future<DshService> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dsh = DshService();
    dsh.debugSetCurrentSession(
        SessionMeta(sessionId: 'session-a', title: '测试会话'));
    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: MaterialApp(
          builder: (ctx, child) =>
              ThemeScope(isDark: false, child: child ?? const SizedBox()),
          home: const ChatView(),
        ),
      ),
    );
    await tester.pump();
    return dsh;
  }

  /// 拆树 + 推完 ChatView 拉起的语音服务计时器（与 message_attachments_test 一致，
  /// 必须在用例体末尾显式调用：待定 Timer 检查早于 tearDown）。
  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 22));
    VoiceInputService.instance.debugReset();
  }

  ChatMessage userMsg(String id, String content,
          {List<dynamic>? attachments}) =>
      ChatMessage(
        id: id,
        role: 'user',
        content: content,
        timestamp: DateTime.now(),
        attachments: attachments,
      );

  ChatMessage aiMsg(String id, String content) => ChatMessage(
        id: id,
        role: 'assistant',
        content: content,
        timestamp: DateTime.now(),
      );

  /// 点「⋯」并等弹层动画落定。
  Future<void> openViaMoreButton(WidgetTester tester, String messageId) async {
    await tester.tap(find.byKey(ValueKey('message-more-$messageId')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 记录写到剪贴板的内容（`Clipboard.setData` 走 SystemChannels.platform）。
  List<String> captureClipboard(WidgetTester tester) {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments;
          if (args is Map && args['text'] is String) {
            copied.add(args['text'] as String);
          }
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    return copied;
  }

  // ================================================ 消息的动作矩阵 ====

  group('消息长按：动作按上下文裁剪', () {
    testWidgets('用户消息 = 复制 / 引用 / 重新发送，没有轨迹', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetMessages([userMsg('u1', '帮我看看这个 bug')]);
      await tester.pump();

      await openViaMoreButton(tester, 'u1');

      expect(find.byKey(sheetKey), findsOneWidget);
      expect(find.byKey(const ValueKey('message-action-copy')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('message-action-quote')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('message-action-resend')),
        findsOneWidget,
        reason: '重新发送只对"自己发过的"成立',
      );
      expect(
        find.byKey(const ValueKey('message-action-trajectory')),
        findsNothing,
        reason: '轨迹是 AI 侧的入口，用户消息上没有它',
      );

      await teardown(tester);
    });

    testWidgets('AI 消息 = 复制 / 引用 / 查看本轮轨迹，没有重新发送', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetMessages([aiMsg('a1', '已经改好了，可以重新测一遍')]);
      await tester.pump();

      await openViaMoreButton(tester, 'a1');

      expect(find.byKey(sheetKey), findsOneWidget);
      expect(find.byKey(const ValueKey('message-action-copy')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('message-action-quote')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('message-action-trajectory')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('message-action-resend')),
        findsNothing,
        reason: 'AI 的消息没有"重新发送"这回事',
      );

      await teardown(tester);
    });

    testWidgets('复制原文：写进剪贴板的正是这条消息的正文', (tester) async {
      final dsh = await pumpChat(tester);
      final copied = captureClipboard(tester);
      dsh.debugSetMessages([userMsg('u1', '帮我看看这个 bug')]);
      await tester.pump();

      await openViaMoreButton(tester, 'u1');
      await tester.tap(find.byKey(const ValueKey('message-action-copy')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(copied, contains('帮我看看这个 bug'));
      await teardown(tester);
    });

    testWidgets('引用：以 > 逐行缩进塞进输入框，且不覆盖已有草稿', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetMessages([aiMsg('a1', '第一行\n第二行')]);
      await tester.pump();

      // 先在输入框里放一句草稿：引用是"补一句"，不是"重来"。
      final field = find.byKey(const ValueKey('chat-input-field'));
      await tester.enterText(field, '接着问：');
      await tester.pump();

      await openViaMoreButton(tester, 'a1');
      await tester.tap(find.byKey(const ValueKey('message-action-quote')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final controller = tester.widget<TextField>(field).controller!;
      expect(controller.text, '接着问：> 第一行\n> 第二行\n\n');
      expect(
        controller.selection.baseOffset,
        controller.text.length,
        reason: '光标必须落在引用块之后，否则用户要继续写还得手动点一下',
      );

      await teardown(tester);
    });

    testWidgets('重新发送：输入框有草稿时不发、也不覆盖草稿', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetMessages([userMsg('u1', '重发我')]);
      await tester.pump();

      final field = find.byKey(const ValueKey('chat-input-field'));
      await tester.enterText(field, '我还没写完的草稿');
      await tester.pump();

      await openViaMoreButton(tester, 'u1');
      await tester.tap(find.byKey(const ValueKey('message-action-resend')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        tester.widget<TextField>(field).controller!.text,
        '我还没写完的草稿',
        reason: '重发是破坏性动作，不能顺手把草稿丢掉',
      );
      expect(
        find.textContaining('先清空再重发'),
        findsOneWidget,
        reason: '什么也没发生时必须说清为什么',
      );

      await teardown(tester);
    });

    testWidgets('空正文消息不弹空壳 sheet', (tester) async {
      final dsh = await pumpChat(tester);
      // 只有附件、没有正文：可做的事只剩附件那一组（走附件自己的长按），
      // 消息级动作一个都没有 —— 此时弹一个空列表等于告诉用户"长按坏了"。
      dsh.debugSetMessages([
        userMsg('u1', '   ', attachments: [
          {
            'id': 'sha256:abc',
            'mimeType': 'application/pdf',
            'bytes': 1024,
            'filename': 'spec.pdf',
          },
        ]),
      ]);
      await tester.pump();

      await openViaMoreButton(tester, 'u1');
      expect(find.byKey(sheetKey), findsNothing);

      await teardown(tester);
    });
  });

  // ================================================== 手势边界（选词）====

  group('长按的手势边界', () {
    testWidgets('长按正文不弹 sheet —— 选词仍然是系统行为', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetMessages([userMsg('u1', '这段文字要能选中复制')]);
      await tester.pump();

      // 正文必须仍然是可选的（规格明令禁止为了 sheet 关掉 selectable）。
      expect(find.byType(SelectableText), findsWidgets);

      // 精确定位到这一条正文的 `SelectableText`（不是"屏幕上第一个"）：长按点必须
      // 真的落在字上，否则"没弹 sheet"可能只是按到了空白处，用例就废了。
      final body = find.byWidgetPredicate(
        (w) =>
            w is SelectableText &&
            (w.textSpan?.toPlainText() ?? '').contains('这段文字要能选中复制'),
      );
      expect(body, findsOneWidget, reason: '正文没渲染成可选文本，这条用例就无从谈起');

      await tester.longPress(body);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(sheetKey),
        findsNothing,
        reason: '正文长按被 action sheet 抢走 = "复制一段代码"这条路没了',
      );

      await teardown(tester);
    });

    testWidgets('长按轮首标签行（非正文区）弹 sheet', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetMessages([aiMsg('a1', '已经改好了')]);
      await tester.pump();

      await tester.longPress(find.textContaining('AI ·'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(sheetKey),
        findsOneWidget,
        reason: '气泡外框必须是长按的命中区，否则长按这条路只剩"看不见的手势"',
      );

      await teardown(tester);
    });
  });

  // ========================================== 附件 / 产出卡（同一弹层）====

  group('附件与产出卡走同一个 sheet', () {
    testWidgets('图片附件：打开图片 / 复制文件名 / 复制附件 ID', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetMessages([
        userMsg('u1', '看这张', attachments: [
          {
            'id':
                'sha256:d4ca127809edd73b79deb6058647b66cbbd023f99b37a32fc8c02c7622d10305',
            'mimeType': 'image/jpeg',
            'width': 736,
            'height': 1600,
            'bytes': 229795,
            'filename': 'scaled_7125.jpg',
          },
        ]),
      ]);
      await tester.pump();

      await tester.longPress(find.text('scaled_7125.jpg'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(sheetKey), findsOneWidget);
      expect(find.byKey(const ValueKey('message-action-open-image')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('message-action-copy-filename')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('message-action-copy-attachment-id')),
          findsOneWidget);

      await teardown(tester);
    });

    testWidgets('文件附件没有"打开图片"这一项', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetMessages([
        userMsg('u2', '把这个迁移过去', attachments: [
          {
            'id':
                'sha256:16bb540d7b4cf587f60ab1b39a1b9144cdd2e31acc87fa768c57a9adc1b77a2c',
            'mimeType': 'application/octet-stream',
            'bytes': 21769,
            'filename': '工作日报.xlsx',
          },
        ]),
      ]);
      await tester.pump();

      await tester.longPress(find.text('工作日报.xlsx'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(sheetKey), findsOneWidget);
      expect(
        find.byKey(const ValueKey('message-action-open-image')),
        findsNothing,
        reason: '动作集按上下文裁剪：不是图片就不该有"打开图片"',
      );

      await teardown(tester);
    });

    testWidgets('产出卡长按：打开预览 / 下载并打开 / 复制路径', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.messages.add(aiMsg('a1', '做完了'));
      dsh.debugSetTaskCenter(
          deliverables: const [report], deliverableEvents: 1);
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-output-card')), findsOneWidget);

      await tester.longPress(find.text('报表.xlsx'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(sheetKey), findsOneWidget);
      expect(find.byKey(const ValueKey('message-action-open')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('message-action-download')),
        findsOneWidget,
        reason: '长按原来的语义（下载）必须还能做到，只是多了一层菜单',
      );
      expect(
        find.byKey(const ValueKey('message-action-copy-path')),
        findsOneWidget,
      );

      await teardown(tester);
    });

    testWidgets('产出卡「复制路径」复制的是 REST 的绝对路径', (tester) async {
      final dsh = await pumpChat(tester);
      final copied = captureClipboard(tester);
      dsh.messages.add(aiMsg('a1', '做完了'));
      dsh.debugSetTaskCenter(
          deliverables: const [report], deliverableEvents: 1);
      await tester.pump();

      await tester.longPress(find.text('报表.xlsx'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('message-action-copy-path')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(copied, contains(report.path));
      await teardown(tester);
    });
  });
}
