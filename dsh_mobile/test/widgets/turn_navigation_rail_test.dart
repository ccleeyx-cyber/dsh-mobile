import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/services/voice_input_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';
import 'package:dsh_mobile/views/widgets/turn_navigation_rail.dart';

/// 轮次导航刻度（v1.26.0，电脑端同款）。
///
/// 用户原话："需要有会话轮数快捷选择，就和 web 端的一样"。所以这里钉住的是
/// **可点、点得准、当前轮看得出来** —— 刻度点不中在用户眼里就是"这功能没反应"。
void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (ctx, c) =>
            ThemeScope(isDark: false, child: c ?? const SizedBox()),
        home: Scaffold(body: Center(child: child)),
      ),
    );
    await tester.pump();
  }

  List<TurnMark> marks(int n) =>
      [for (var i = 1; i <= n; i++) TurnMark(turn: i, messageId: 'm$i')];

  testWidgets('一轮一格：10 轮就是 10 格，且带"跳到第 N 轮"提示', (tester) async {
    await pump(
      tester,
      TurnNavigationRail(marks: marks(10), currentTurn: 3, onSelect: (_) {}),
    );

    expect(find.byKey(const ValueKey('turn-nav-rail')), findsOneWidget);
    for (var i = 1; i <= 10; i++) {
      expect(find.byKey(ValueKey('turn-nav-$i')), findsOneWidget,
          reason: '第 $i 轮必须有刻度');
    }
    expect(find.byKey(const ValueKey('turn-nav-11')), findsNothing);
    expect(find.byTooltip('跳到第 3 轮'), findsOneWidget);
  });

  testWidgets('点第 N 格回传第 N 轮（不是索引）', (tester) async {
    final tapped = <int>[];
    await pump(
      tester,
      TurnNavigationRail(marks: marks(5), currentTurn: 1, onSelect: tapped.add),
    );

    await tester.tap(find.byKey(const ValueKey('turn-nav-4')));
    await tester.pump();
    expect(tapped, [4]);
  });

  testWidgets('当前轮更长更深，其它轮安静', (tester) async {
    await pump(
      tester,
      TurnNavigationRail(marks: marks(3), currentTurn: 2, onSelect: (_) {}),
    );

    String description(int turn) {
      // 刻度是 AnimatedContainer，宽度/颜色由 BoxDecoration 决定。
      final box = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(ValueKey('turn-nav-$turn')),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final deco = box.decoration! as BoxDecoration;
      return '${(box.constraints?.maxWidth ?? -1)}|${deco.color}';
    }

    // 当前轮 17dp 细条、其余 6dp 圆点（v1.27：其余刻度从 10dp 收到 6dp 圆点，
    // 解决"14 轮以后间距压到 2dp、点不中"那件事）。宽度差仍然是"我在哪一轮"
    // 的一眼可读化。
    expect(description(2).split('|').first, '17.0');
    expect(description(1).split('|').first, '6.0');
  });

  testWidgets('没有轮次时整条不渲染（不留空白浮层）', (tester) async {
    await pump(
        tester,
        TurnNavigationRail(
            marks: const [], currentTurn: null, onSelect: (_) {}));
    expect(find.byKey(const ValueKey('turn-nav-rail')), findsNothing);
  });

  testWidgets('当前轮未知（null）时不高亮任何一格，但都能点', (tester) async {
    final tapped = <int>[];
    await pump(
      tester,
      TurnNavigationRail(
          marks: marks(3), currentTurn: null, onSelect: tapped.add),
    );
    expect(find.byKey(const ValueKey('turn-nav-rail')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('turn-nav-1')));
    await tester.pump();
    expect(tapped, [1]);
  });

  testWidgets('间距固定 5，且超过 10 轮时不压紧而是放进占屏高 40% 的内部滚动列', (tester) async {
    // 60 轮：如果还按"14 轮以后压到 2dp"的老逻辑，这里会挤成一条糊。
    await pump(
      tester,
      TurnNavigationRail(marks: marks(60), currentTurn: 5, onSelect: (_) {}),
    );

    // 相邻两格的垂直中心距 = 3(刻度高) + 5(间距)。第一格仍然在屏上，可以直接量。
    final a = tester.getCenter(find.byKey(const ValueKey('turn-nav-1')));
    final b = tester.getCenter(find.byKey(const ValueKey('turn-nav-2')));
    expect(b.dy - a.dy, closeTo(8.0, 0.01), reason: '间距必须恒为 5，不随轮数压紧');

    // 视口高 900 → 滚动区上限 360，加上容器自身 padding 8×2 与 1px 边框 ×2。
    final rail = tester.getSize(find.byKey(const ValueKey('turn-nav-rail')));
    expect(rail.height, lessThanOrEqualTo(360.0 + 16.0 + 2.0),
        reason: '超过 10 轮要交给内部滚动，而不是拉成一条顶出屏幕的长条');
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按 rail 弹出轮次选择弹层，点一格直接跳那一轮', (tester) async {
    final tapped = <int>[];
    await pump(
      tester,
      TurnNavigationRail(
          marks: marks(12), currentTurn: 3, onSelect: tapped.add),
    );

    await tester.longPress(find.byKey(const ValueKey('turn-nav-rail')));
    await tester.pumpAndSettle();
    expect(find.text('跳到某一轮'), findsOneWidget, reason: '长按必须能唤出轮次选择');
    expect(find.byKey(const ValueKey('turn-picker-7')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('turn-picker-7')));
    await tester.pumpAndSettle();
    expect(tapped, [7], reason: '选中哪一轮就回传哪一轮');
  });

  // ---- 挂进 ChatView：刻度只数真人回合 ----
  //
  // 这是最容易悄悄错的一条：注入通知的 `role` 也是 `user`，上下文/记忆块也是。
  // 如果它们被算成一轮，刻度格数会比状态条的 `N 轮` 多，用户点"第 3 轮"会跳到
  // 一条子代理结算通知上。
  testWidgets('ChatView 里刻度格数 = 真人回话数（注入/上下文不算）', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dsh = DshService();
    dsh.debugSetCurrentSession(
        SessionMeta(sessionId: 'session-abc', title: 't'));
    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: MaterialApp(
          builder: (ctx, c) =>
              ThemeScope(isDark: false, child: c ?? const SizedBox()),
          home: const ChatView(),
        ),
      ),
    );
    await tester.pump();

    ChatMessage msg(String id, String role, String content, int seq) =>
        ChatMessage(
          id: id,
          role: role,
          content: content,
          seq: seq,
          timestamp: DateTime.now().subtract(Duration(minutes: 30 - seq % 10)),
        );

    dsh.debugSetMessages([
      // 上下文块：不算一轮
      msg('ctx', 'user', 'MNEMON RUNTIME MEMORY SNAPSHOT\nRevision: abc', 1),
      // 真人第一轮
      msg('u1', 'user', '第一轮提问', 2),
      msg('a1', 'assistant', '第一轮回复', 3),
      // 注入通知：不算一轮
      msg(
          'n1',
          'user',
          'Background subagent 6f29a191 finished and will do no further work unless you send it more.',
          4),
      // 真人第二轮
      msg('u2', 'user', '第二轮提问', 5),
      msg('a2', 'assistant', '第二轮回复', 6),
      // 真人第三轮
      msg('u3', 'user', '第三轮提问', 7),
      msg('a3', 'assistant', '第三轮回复', 8),
    ]);
    await tester.pump();

    expect(find.byKey(const ValueKey('turn-nav-rail')), findsOneWidget);
    for (var i = 1; i <= 3; i++) {
      expect(find.byKey(ValueKey('turn-nav-$i')), findsOneWidget,
          reason: '第 $i 轮是真人的');
    }
    expect(find.byKey(const ValueKey('turn-nav-4')), findsNothing,
        reason: '注入通知不能占一格');

    // 收尾：拆树 + 推掉 VoiceInputService 的计时器（否则报 "Timer is still pending"）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 22));
    VoiceInputService.instance.debugReset();
  });
}
