import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/task_center.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';
import 'package:dsh_mobile/views/widgets/deliverable_preview_sheet.dart';
import 'package:dsh_mobile/views/widgets/turn_output_card.dart';

/// 「在会话里直接点开产物预览」的回归测试。
///
/// 这条动线有三个入口，本次改动要保证它们**逐字同一套行为**：
///   A. 消息流「本轮产出」卡片 —— 主点击 = 预览，长按 = 下载；
///   B. 消息正文里的产物引用 —— 变成可点链接，点了就地预览；
///   C. 信息面板的交付物清单 —— 本来就是"点击预览 / 长按下载"，不改。
///
/// 最容易出的错不是崩，而是**入口之间不一致**：用户在会话里点一下发生下载、
/// 在面板里点一下只是看一眼。所以集成断言都用真实的 ChatView + 可注入的
/// `DshService`（无服务器配置 → 取内容是纯本地短路，**零网络**）。
void main() {
  // 交付物数据一律用 REST 返回的形状（绝对 path + 保留原样的相对 display）。
  const report = DeliverableItem(
    path: r'E:\workspace\个人\dsh_mobile\out\报表.xlsx',
    display: r'out\报表.xlsx',
    description: '本月汇总',
    turn: 3,
    seq: 30,
  );

  Future<void> pump(WidgetTester tester, Widget child, {Size size = const Size(420, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (ctx, c) => ThemeScope(isDark: false, child: c ?? const SizedBox()),
        home: Scaffold(body: child),
      ),
    );
    await tester.pump();
  }

  Future<DshService> pumpChat(WidgetTester tester, {Size size = const Size(420, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dsh = DshService();
    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: MaterialApp(
          builder: (ctx, c) => ThemeScope(isDark: false, child: c ?? const SizedBox()),
          home: const ChatView(),
        ),
      ),
    );
    await tester.pump();
    return dsh;
  }

  Future<DshService> chatWithSession(WidgetTester tester) async {
    final dsh = await pumpChat(tester);
    dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-a', title: '测试会话'));
    await tester.pump();
    return dsh;
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 21));
  }

  /// 屏幕上挂着点击 recognizer 的链接 span —— 按它的显示文字找。
  ///
  /// 为什么不直接用 `tester.tapOnText`：`SafeMarkdown` 是 selectable 的，渲染出去
  /// 的是 `SelectableText`（内部 `EditableText`），`find.textRange` 在它上面找不到
  /// TextRange。直接拿到 flutter_markdown 挂上去的那个 recognizer 并触发它，走的
  /// 是**同一条** onTapLink 回调链路 —— 断言"真的可点"而不是"文字显示出来了"。
  TapGestureRecognizer? linkRecognizer(WidgetTester tester, String label) {
    TapGestureRecognizer? found;
    bool walk(InlineSpan span) {
      if (span is! TextSpan) return false;
      final recognizer = span.recognizer;
      if (recognizer is TapGestureRecognizer && (span.text ?? '').contains(label)) {
        found = recognizer;
        return true;
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        if (walk(child)) return true;
      }
      return false;
    }

    for (final st in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
      final span = st.textSpan;
      if (span != null && walk(span)) break;
    }
    return found;
  }

  // ================================================== 产出卡片的手势 =====

  group('产出卡片：主点击预览、长按下载', () {
    testWidgets('点文件名走 onOpen，长按走 onDownload', (tester) async {
      DeliverableItem? opened;
      DeliverableItem? downloaded;
      await pump(
        tester,
        TurnOutputCard(
          deliverables: const [report],
          onOpen: (item) => opened = item,
          onDownload: (item) => downloaded = item,
        ),
      );

      await tester.tap(find.text('报表.xlsx'));
      await tester.pump();
      expect(opened?.path, report.path, reason: '主点击必须是"看一眼"，不是下载');
      expect(downloaded, isNull);

      await tester.longPress(find.text('报表.xlsx'));
      await tester.pump();
      expect(downloaded?.path, report.path, reason: '下载退到长按，且传的仍是绝对路径');
    });

    testWidgets('两个动作位都有时给出长按提示，尾部换成眼睛图标', (tester) async {
      await pump(
        tester,
        TurnOutputCard(
          deliverables: const [report],
          onOpen: (_) {},
          onDownload: (_) {},
        ),
      );
      // 长按完全不可发现 —— 不写出来就等于没有这个功能。
      expect(find.byKey(const ValueKey('turn-output-hint')), findsOneWidget);
      expect(find.byIcon(Icons.visibility_rounded), findsOneWidget);
      expect(find.byIcon(Icons.download_rounded), findsNothing,
          reason: '尾部画着下载箭头却在点下去时开预览，图标就在说假话');
    });

    testWidgets('没有下载出口时不画提示、也不承诺长按', (tester) async {
      await pump(tester, TurnOutputCard(deliverables: const [report], onOpen: (_) {}));
      expect(find.byKey(const ValueKey('turn-output-hint')), findsNothing);
      expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    });
  });

  // ============================================ 会话里点开预览（集成）====

  group('会话里点开产物预览', () {
    testWidgets('点产出卡片：就地弹出预览弹层，不下载', (tester) async {
      final dsh = await chatWithSession(tester);
      dsh.messages.add(ChatMessage(id: 'm1', role: 'assistant', content: '做完了'));
      dsh.debugSetTaskCenter(deliverables: const [report]);
      dsh.debugSetTaskCenter(deliverableEvents: 1);
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-output-card')), findsOneWidget);

      await tester.tap(find.text('报表.xlsx'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(DeliverablePreviewSheet), findsOneWidget);
      // 没有服务器配置 → 取内容在本地短路，所以这里一定是"读取失败"而不是转圈：
      // 它同时证明弹层真的去取了内容，且没打真实网络。
      expect(find.textContaining('读取失败'), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('正文里的产物名变成可点链接', (tester) async {
      final dsh = await chatWithSession(tester);
      dsh.messages.add(ChatMessage(id: 'm1', role: 'assistant', content: '已生成 报表.xlsx，请查看'));
      // 只给清单不给事件：不出卡片，这样屏幕上只有正文这一处出现文件名。
      dsh.debugSetTaskCenter(deliverables: const [report]);
      await tester.pump();

      expect(find.byKey(const ValueKey('turn-output-card')), findsNothing);
      expect(linkRecognizer(tester, '报表.xlsx'), isNotNull,
          reason: '正文里的产物必须真的挂上点击 recognizer，而不只是显示出来');
      await teardown(tester);
    });

    testWidgets('点正文里的产物链接：打开同一个预览弹层', (tester) async {
      final dsh = await chatWithSession(tester);
      dsh.messages.add(ChatMessage(id: 'm1', role: 'assistant', content: '已生成 报表.xlsx，请查看'));
      dsh.debugSetTaskCenter(deliverables: const [report]);
      await tester.pump();

      final recognizer = linkRecognizer(tester, '报表.xlsx');
      expect(recognizer, isNotNull, reason: '没有链接就无从谈起"点了会怎样"');
      recognizer!.onTap!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(DeliverablePreviewSheet), findsOneWidget,
          reason: '正文点链接与卡片点击必须是同一个弹层，不是第二条通路');
      await teardown(tester);
    });

    testWidgets('清单外的文件名不会变成链接（点了只会报错，不如不可点）', (tester) async {
      final dsh = await chatWithSession(tester);
      dsh.messages.add(ChatMessage(id: 'm1', role: 'assistant', content: '参考 别的文件.xlsx 里的做法'));
      dsh.debugSetTaskCenter(deliverables: const [report]);
      await tester.pump();

      expect(linkRecognizer(tester, '别的文件.xlsx'), isNull);
      await teardown(tester);
    });
  });
}
