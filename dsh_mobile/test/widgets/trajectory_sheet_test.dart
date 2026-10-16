import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/trajectory.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/services/voice_input_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';
import 'package:dsh_mobile/views/widgets/trajectory_sheet.dart';

/// 轨迹面板的回归测试。
///
/// 钉住的都是"看起来对、实际会骗人"的地方：耗时取不到必须显示 `—`（不是 `0s`）、
/// 历史轮的 token 必须是 `—`、时间概览在没有足够数据时**不出现**、上下文块默认
/// 不可见但能打开。以及入口：顶栏菜单里点得开。
void main() {
  final t0 = DateTime(2026, 10, 16, 22, 0, 0);
  final t1 = DateTime(2026, 10, 16, 22, 0, 3);
  final t2 = DateTime(2026, 10, 16, 22, 1, 0);
  final t3 = DateTime(2026, 10, 16, 22, 1, 2);
  final t4 = DateTime(2026, 10, 16, 22, 3, 0);
  final t5 = DateTime(2026, 10, 16, 22, 3, 4);

  ChatMessage msg({
    required String id,
    required String role,
    String content = '',
    String? thinking,
    List<ToolExecution>? tools,
    required DateTime at,
  }) =>
      ChatMessage(
        id: id,
        role: role,
        content: content,
        thinking: thinking,
        tools: tools,
        timestamp: at,
      );

  /// 两轮：第一轮带思考 + 工具 + 回复；第二轮只有一条用户消息（耗时必然是 `—`）。
  ///
  /// 默认 `running: false` —— 第二轮**没有结束时间**，面板必须显示 `—`；要测
  /// "进行中"的读数时显式传 true。
  Trajectory twoTurns({int? liveTurnTokens, bool running = false}) => Trajectory.build([
        msg(
          id: 'c1',
          role: 'system',
          content: 'MNEMON RUNTIME MEMORY SNAPSHOT\n上下文内容',
          at: t0,
        ),
        msg(id: 'u1', role: 'user', content: '帮我看看目录', at: t0),
        msg(
          id: 'a1',
          role: 'assistant',
          thinking: '先列目录',
          content: '看完了，一共 3 个文件',
          tools: [
            ToolExecution(name: 'bash', input: 'ls -la', output: 'a.dart\nb.dart', isRunning: false),
          ],
          at: t3,
        ),
        msg(id: 'u2', role: 'user', content: '再帮我改一下', at: t4),
      ], liveTurnTokens: liveTurnTokens, running: running);

  Future<void> pumpSheet(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(420, 900);
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

  String textOf(WidgetTester tester, Key key) =>
      tester.widget<Text>(find.byKey(key)).data ?? '';

  group('渲染', () {
    testWidgets('轮头、事件与摘要都在', (tester) async {
      await pumpSheet(tester, TrajectorySheet(trajectory: twoTurns(), now: t5));

      expect(find.text('轨迹'), findsOneWidget);
      expect(find.text('第 1 轮'), findsOneWidget);
      expect(find.text('第 2 轮'), findsOneWidget);

      final summary = textOf(tester, const ValueKey('trajectory-summary'));
      expect(summary, contains('2 轮'));
      expect(summary, contains('次工具调用'));

      // 事件：你 / 思考 / 工具名 / 回复。两轮各有一条用户消息，所以"你"出现两次。
      expect(find.text('你'), findsNWidgets(2));
      expect(find.text('思考'), findsOneWidget);
      expect(find.text('bash'), findsOneWidget);
      expect(find.text('回复'), findsOneWidget);
    });

    testWidgets('耗时取不到显示 —，取得到显示读数', (tester) async {
      await pumpSheet(tester, TrajectorySheet(trajectory: twoTurns(), now: t5));

      // 第 1 轮：t0(22:00:00) → t3(22:01:02)。
      expect(textOf(tester, const ValueKey('trajectory-turn-1-duration')), '1m02s');
      // 第 2 轮：只有一条用户消息，没有任何"结束时间"可言。
      expect(textOf(tester, const ValueKey('trajectory-turn-2-duration')), '—');
    });

    testWidgets('token 只给最后一轮，历史轮是 —（不是 0）', (tester) async {
      await pumpSheet(
        tester,
        TrajectorySheet(trajectory: twoTurns(liveTurnTokens: 12400), now: t5),
      );

      expect(textOf(tester, const ValueKey('trajectory-turn-1-tokens')), '—');
      expect(textOf(tester, const ValueKey('trajectory-turn-2-tokens')), '12.4k');
    });

    testWidgets('运行中的轮标"进行中"，且耗时按"到现在"算', (tester) async {
      await pumpSheet(
        tester,
        TrajectorySheet(trajectory: twoTurns(running: true), now: t5),
      );

      expect(find.text('进行中'), findsOneWidget);
      // 第 2 轮从 t4(22:03:00) 到 now t5(22:03:04)。
      expect(textOf(tester, const ValueKey('trajectory-turn-2-duration')), '4.0s');
    });

    testWidgets('空轨迹给一句说明，不假装有时间线', (tester) async {
      await pumpSheet(tester, TrajectorySheet(trajectory: Trajectory.build(const [])));
      expect(find.byKey(const ValueKey('trajectory-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('trajectory-time-band')), findsNothing);
    });
  });

  group('时间概览', () {
    testWidgets('少于两轮有耗时就不画（两根柱子没有信息量）', (tester) async {
      await pumpSheet(tester, TrajectorySheet(trajectory: twoTurns(), now: t5));
      expect(find.byKey(const ValueKey('trajectory-time-band')), findsNothing);
    });

    testWidgets('至少两轮有耗时时出现，并说明有几轮没数据', (tester) async {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: 'a', at: t0),
        msg(id: 'a1', role: 'assistant', content: 'b', at: t1),
        msg(id: 'u2', role: 'user', content: 'c', at: t2),
        msg(id: 'a2', role: 'assistant', content: 'd', at: t3),
        msg(id: 'u3', role: 'user', content: 'e', at: t4),
      ]);
      await pumpSheet(tester, TrajectorySheet(trajectory: traj, now: t5));

      expect(find.byKey(const ValueKey('trajectory-time-band')), findsOneWidget);
      expect(find.textContaining('1 轮没有可用的时间数据'), findsOneWidget);
    });
  });

  group('展开与跳转', () {
    testWidgets('点事件展开 detail，再点收起', (tester) async {
      await pumpSheet(tester, TrajectorySheet(trajectory: twoTurns(), now: t5));

      final toolRow = find.byKey(const ValueKey('trajectory-event-1-2'));
      // 展开后整行会变高，行中心会落到 detail 里 —— 而 detail 是 SelectableText
      // （自带点按手势，用来选字），点它不会收起。所以统一点行首的标签文字。
      final toolLabel = find.text('bash');
      expect(find.byKey(const ValueKey('trajectory-detail-1-2')), findsNothing);

      await tester.tap(toolLabel);
      await tester.pump();

      expect(find.byKey(const ValueKey('trajectory-detail-1-2')), findsOneWidget);
      final detail = tester.widget<SelectableText>(
        find.byKey(const ValueKey('trajectory-detail-1-2')),
      );
      expect(detail.data, contains('ls -la'));
      expect(detail.data, contains('a.dart'));

      expect(toolRow, findsOneWidget);
      await tester.tap(toolLabel);
      await tester.pump();
      expect(find.byKey(const ValueKey('trajectory-detail-1-2')), findsNothing);
    });

    testWidgets('没有回调时不显示跳转按钮（不给一个点了没反应的图标）', (tester) async {
      await pumpSheet(tester, TrajectorySheet(trajectory: twoTurns(), now: t5));
      expect(find.byKey(const ValueKey('trajectory-jump-1-0')), findsNothing);
    });

    testWidgets('点跳转回传消息 id', (tester) async {
      final jumped = <String>[];
      await pumpSheet(
        tester,
        TrajectorySheet(
          trajectory: twoTurns(),
          now: t5,
          onJumpToMessage: jumped.add,
        ),
      );

      await tester.tap(find.byKey(const ValueKey('trajectory-jump-1-0')));
      await tester.pump();

      expect(jumped, ['u1']);
    });
  });

  group('上下文块', () {
    testWidgets('默认不显示，开关打开后出现', (tester) async {
      await pumpSheet(tester, TrajectorySheet(trajectory: twoTurns(), now: t5));

      expect(find.text('上下文'), findsNothing, reason: '上下文不是动作，默认折叠');
      expect(find.byKey(const ValueKey('trajectory-context-toggle')), findsOneWidget);
      expect(find.textContaining('显示上下文/记忆块（1 条）'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('trajectory-context-toggle')));
      await tester.pump();

      expect(find.text('上下文'), findsOneWidget);
    });

    testWidgets('没有上下文块时不给开关', (tester) async {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: 'a', at: t0),
        msg(id: 'a1', role: 'assistant', content: 'b', at: t1),
      ]);
      await pumpSheet(tester, TrajectorySheet(trajectory: traj, now: t5));
      expect(find.byKey(const ValueKey('trajectory-context-toggle')), findsNothing);
    });
  });

  group('入口', () {
    /// ChatView 只依赖 DshService 与 ThemeScope；主题控制器只在菜单回调里用。
    Future<DshService> pumpChat(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final dsh = DshService();
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

    Future<void> teardown(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 21));
    }

    testWidgets('顶栏菜单里能打开轨迹面板', (tester) async {
      VoiceInputService.instance.debugSetAvailable(false);
      await pumpChat(tester);

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      // 两次 pump：菜单是带入场动画的路由，动画没跑完时菜单项虽然已经挂进树，
      // 但命中测试还拿不到它（tap 会警告 "would not hit test" 然后什么都不发生）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('运行轨迹'), findsOneWidget);

      await tester.tap(find.text('运行轨迹'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const ValueKey('trajectory-sheet')), findsOneWidget);
      // 这个测试的 DshService 没有会话数据 —— 面板必须老实说"还没有事件"，
      // 而不是渲染一个空壳时间线。
      expect(find.byKey(const ValueKey('trajectory-empty')), findsOneWidget);

      await teardown(tester);
    });
  });
}
