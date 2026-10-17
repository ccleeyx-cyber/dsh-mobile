import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/trajectory.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/widgets/trajectory_sheet.dart';

/// 轨迹导出的测试（Phase 5.3）。
///
/// 两份断言各钉一件事：
///  * **纯序列化**：md 的结构与"取不到就写 `—`"这条诚实规则。它最容易在后续
///    重构里被"顺手填个默认值"毁掉，而那时界面看起来完全正常；
///  * **按钮**：点下去真的把 md 放进剪贴板（这个工程没有分享依赖，剪贴板就是
///    唯一的出口），并且回执只说"已复制"。
void main() {
  final t0 = DateTime(2026, 10, 16, 22, 0, 0);
  final t1 = DateTime(2026, 10, 16, 22, 0, 3);
  final t3 = DateTime(2026, 10, 16, 22, 1, 2);
  final t4 = DateTime(2026, 10, 16, 22, 3, 0);

  ChatMessage msg({
    required String id,
    required String role,
    String content = '',
    String? thinking,
    List<ToolExecution>? tools,
    required DateTime at,
    int? turnTokens,
  }) =>
      ChatMessage(
        id: id,
        role: role,
        content: content,
        thinking: thinking,
        tools: tools,
        timestamp: at,
        turnTokens: turnTokens,
      );

  /// 两轮：第 1 轮带思考 + 工具 + 回复；第 2 轮只有一条用户消息（耗时必然取不到）。
  Trajectory twoTurns({
    int? liveTurnTokens,
    bool running = false,
    String toolOutput = 'a.dart\nb.dart',
  }) =>
      Trajectory.build([
        msg(
            id: 'c1',
            role: 'system',
            content: 'MNEMON RUNTIME MEMORY SNAPSHOT\n上下文内容',
            at: t0),
        msg(id: 'u1', role: 'user', content: '帮我看看目录', at: t0),
        msg(
          id: 'a1',
          role: 'assistant',
          thinking: '先列目录',
          content: '看完了，一共 3 个文件',
          tools: [
            ToolExecution(
                name: 'bash',
                input: 'ls -la',
                output: toolOutput,
                isRunning: false),
          ],
          at: t3,
        ),
        msg(id: 'u2', role: 'user', content: '再帮我改一下', at: t4),
      ], liveTurnTokens: liveTurnTokens, running: running);

  group('Markdown 结构', () {
    test('头部概览 + 每轮一个二级标题 + 一行摘要', () {
      final md = trajectoryToMarkdown(twoTurns(), now: t4);

      expect(md, startsWith('# 会话轨迹'));
      expect(md, contains('2 轮'));
      expect(md, contains('次工具调用'));
      expect(md, contains('- 导出时间：2026-10-16 22:03:00'));

      expect(md, contains('## 第 1 轮'));
      expect(md, contains('## 第 2 轮'));
      // 摘要必须是**一行**：时间 / 耗时 / Token 三个字段都在同一行里。
      expect(
        md,
        contains('- 时间：22:00:00 → 22:01:02 · 耗时：1m02s · Token：—'),
      );
    });

    test('事件按 输入 / 思考 / 工具调用 / 回复 分节，工具带参数与输出', () {
      final md = trajectoryToMarkdown(twoTurns(), now: t4);

      expect(md, contains('#### 输入 · 22:00:00'));
      expect(md, contains('#### 思考 · 22:01:02'));
      expect(md, contains('#### 工具调用 · bash · 22:01:02'));
      expect(md, contains('#### 回复 · 22:01:02'));

      expect(md, contains('**参数**'));
      expect(md, contains('ls -la'));
      expect(md, contains('**输出**'));
      expect(md, contains('a.dart'));
      expect(md, contains('b.dart'));
      // 正文本身也要在（导出不是"只导工具"）。
      expect(md, contains('看完了，一共 3 个文件'));
      expect(md, contains('帮我看看目录'));
    });

    test('取不到的耗时写 —，绝不写 0s', () {
      final md = trajectoryToMarkdown(twoTurns(), now: t4);
      final turn2 = md.substring(md.indexOf('## 第 2 轮'));

      expect(turn2, contains('耗时：—'));
      expect(turn2, isNot(contains('0.0s')));
      expect(turn2, isNot(contains('耗时：0s')));
      // 整轮只有一个事件 → 首尾同一时刻，只写一个时间点，不写"→ 同一时刻"。
      expect(turn2, contains('时间：22:03:00 · 耗时：—'));
    });

    test('取不到的 token 写 —；取得到的写精确值', () {
      expect(trajectoryToMarkdown(twoTurns(), now: t4), contains('Token：—'));

      final withTokens = Trajectory.build([
        msg(id: 'u1', role: 'user', content: '第一轮', at: t0, turnTokens: 5521),
        msg(id: 'a1', role: 'assistant', content: '回复', at: t3),
      ]);
      final md = trajectoryToMarkdown(withTokens, now: t4);
      expect(md, contains('Token：5521'));
      expect(md, isNot(contains('5.5k')), reason: '导出的 md 是拿来分析的，别四舍五入');
    });

    test('运行中的轮写"进行中（截至导出时刻）"，不编结束时间', () {
      final md = trajectoryToMarkdown(twoTurns(running: true), now: t4);
      expect(md, contains('→ 进行中'));
      expect(md, contains('（进行中，截至导出时刻）'));
    });

    test('上下文块默认省略，但必须说明省略了几条', () {
      final md = trajectoryToMarkdown(twoTurns(), now: t4);
      expect(md, contains('已省略 1 条上下文/记忆块/通知'));
      expect(md, isNot(contains('#### 上下文')));
      expect(md, isNot(contains('MNEMON RUNTIME MEMORY SNAPSHOT')));
    });

    test('打开「显示上下文」后导出会带上它们，重复也不会丢', () {
      final md =
          trajectoryToMarkdown(twoTurns(), now: t4, includeContext: true);
      expect(md, contains('#### 上下文 · 22:00:00'));
      expect(md, contains('MNEMON RUNTIME MEMORY SNAPSHOT'));
      expect(md, isNot(contains('已省略')));
    });

    test('空轨迹给一句说明，而不是一个只有标题的文件', () {
      final md = trajectoryToMarkdown(Trajectory.build(const []), now: t4);
      expect(md, contains('（这段会话还没有可以导出的轮。）'));
    });

    test('内容里自带反引号时围栏自动加长，不会提前闭合', () {
      final md = trajectoryToMarkdown(
        twoTurns(toolOutput: '```dart\nvoid main() {}\n```'),
        now: t4,
      );
      // 内容里有 3 个反引号 → 围栏必须是 4 个。
      expect(md, contains('````'));
      expect(md, contains('void main() {}'));
    });

    test('同一轮内的多个工具按调用顺序出现', () {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: '跑两步', at: t0),
        msg(
          id: 'a1',
          role: 'assistant',
          tools: [
            ToolExecution(
                name: 'bash', input: 'one', output: 'first', isRunning: false),
            ToolExecution(
                name: 'grep', input: 'two', output: 'second', isRunning: false),
          ],
          at: t1,
        ),
      ]);
      final md = trajectoryToMarkdown(traj, now: t4);
      final bash = md.indexOf('#### 工具调用 · bash');
      final grep = md.indexOf('#### 工具调用 · grep');
      expect(bash, greaterThan(0));
      expect(grep, greaterThan(bash));
    });
  });

  group('导出按钮', () {
    Future<void> pumpSheet(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (ctx, c) =>
              ThemeScope(isDark: false, child: c ?? const SizedBox()),
          home: Scaffold(body: child),
        ),
      );
      await tester.pump();
    }

    testWidgets('点「导出 Markdown」把 md 放进剪贴板并回执"已复制"', (tester) async {
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await pumpSheet(tester, TrajectorySheet(trajectory: twoTurns(), now: t4));

      expect(find.byKey(TrajectorySheet.exportButtonKey), findsOneWidget);
      // 导出是"点下去才生成"：还没点的时候不该有 md 文本挂在树里。
      expect(find.textContaining('# 会话轨迹'), findsNothing);

      await tester.tap(find.byKey(TrajectorySheet.exportButtonKey));
      await tester.pump();

      expect(copied, isNotNull);
      expect(copied, contains('# 会话轨迹'));
      expect(copied, contains('## 第 1 轮'));
      expect(copied, contains('耗时：—'));
      expect(find.text('已复制 Markdown'), findsOneWidget);
    });

    testWidgets('打开上下文开关后导出会带上上下文块', (tester) async {
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await pumpSheet(tester, TrajectorySheet(trajectory: twoTurns(), now: t4));
      await tester.tap(find.byKey(const ValueKey('trajectory-context-toggle')));
      await tester.pump();

      await tester.tap(find.byKey(TrajectorySheet.exportButtonKey));
      await tester.pump();

      expect(copied, contains('#### 上下文'));
      expect(copied, contains('MNEMON RUNTIME MEMORY SNAPSHOT'));
    });

    testWidgets('没有上下文块时底部也只有一枚按钮，不空出半行', (tester) async {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: 'a', at: t0),
        msg(id: 'a1', role: 'assistant', content: 'b', at: t1),
      ]);
      await pumpSheet(tester, TrajectorySheet(trajectory: traj, now: t4));

      expect(find.byKey(const ValueKey('trajectory-context-toggle')),
          findsNothing);
      expect(find.byKey(TrajectorySheet.exportButtonKey), findsOneWidget);
    });

    testWidgets('360dp 宽 + 系统字号 1.3x：底部动作行不溢出（按钮不能把开关挤掉）', (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          builder: (ctx, c) => MediaQuery(
            data: MediaQuery.of(ctx)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: ThemeScope(isDark: false, child: c ?? const SizedBox()),
          ),
          home:
              Scaffold(body: TrajectorySheet(trajectory: twoTurns(), now: t4)),
        ),
      );
      await tester.pump();

      // 开关和导出按钮必须同时在场，且没有溢出异常。
      expect(find.byKey(const ValueKey('trajectory-context-toggle')),
          findsOneWidget);
      expect(find.byKey(TrajectorySheet.exportButtonKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
