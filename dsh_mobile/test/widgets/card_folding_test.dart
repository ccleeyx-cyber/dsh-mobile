import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/widgets/thinking_card.dart';
import 'package:dsh_mobile/widgets/tool_call_card.dart';
import 'package:dsh_mobile/models/chat_message.dart';

void main() {
  group('ThinkingCard Ergonomics & Bounded Display', () {
    testWidgets('respects user manual collapse during active streaming', (tester) async {
      // 1. Initial streaming thinking card
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ThinkingCard(content: 'Initial thoughts...', isThinking: true),
          ),
        ),
      );

      expect(find.text('深度思考中...'), findsOneWidget);
      expect(find.text('Initial thoughts...'), findsOneWidget);

      // 2. User collapses thinking card
      await tester.tap(find.text('深度思考中...'));
      // 这里必须用 pump() 而不是 pumpAndSettle()。
      //
      // isThinking: true 时卡片头部渲染 CircularProgressIndicator
      // （thinking_card.dart:118），那是永久重复动画，pumpAndSettle() 会一直
      // 推进到超时并抛错。而折叠动作本身只是 setState + `if (_expanded)` 条件
      // 渲染，没有过渡动画，推进一帧就足够。
      //
      // 这是既有缺陷而非本次改动引入：本文件此前从未在 CI 中运行过（
      // bridge-tests.yml 里的 flutter test 步骤是新加的），所以一直没暴露。
      // 已用 `git show HEAD:` 的原版 thinking_card.dart 复核，改动前同样失败。
      await tester.pump();
      expect(find.text('Initial thoughts...'), findsNothing);

      // 3. New token chunk arrives (rebuild with new content & isThinking: true)
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ThinkingCard(content: 'Initial thoughts... more streaming tokens', isThinking: true),
          ),
        ),
      );
      await tester.pump();

      // CARD MUST REMAIN COLLAPSED (Regression bug fix)
      expect(find.text('Initial thoughts... more streaming tokens'), findsNothing);
    });

    testWidgets('enforces maxHeight 280 constraint with internal scroll view', (tester) async {
      final longContent = List.generate(100, (i) => 'Line $i: detailed cognitive step').join('\n');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ThinkingCard(content: longContent, isThinking: false),
          ),
        ),
      );

      // Expand card
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      // Verify bounded container height is <= 280
      final containerFinder = find.byWidgetPredicate(
        (w) => w is Container && w.constraints?.maxHeight == 280,
      );
      expect(containerFinder, findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(find.byType(Scrollbar), findsOneWidget);
    });

    testWidgets('provides single-handed copy and fold buttons', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ThinkingCard(content: 'Analysis completed successfully', isThinking: false),
          ),
        ),
      );

      // Tap header to expand
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      expect(find.text('复制'), findsOneWidget);
      expect(find.text('收起'), findsOneWidget);

      // Tap bottom fold button
      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();

      expect(find.text('复制'), findsNothing);
    });
  });

  group('ToolCallCard Ergonomics & Metrics', () {
    testWidgets('displays command summary, badge and handles bounded output', (tester) async {
      final tool = ToolExecution(
        name: 'run_shell',
        input: 'git status -s',
        output: 'M lib/widgets/thinking_card.dart\nM lib/widgets/tool_call_card.dart',
        isRunning: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToolCallCard(tool: tool),
          ),
        ),
      );

      // Collapsed summary checks
      expect(find.text('工具调用: run_shell'), findsOneWidget);
      expect(find.textContaining('2 行'), findsOneWidget);

      // Tap to expand
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      // Both input and output must have maxHeight: 240
      final boundedContainers = find.byWidgetPredicate(
        (w) => w is Container && w.constraints?.maxHeight == 240,
      );
      expect(boundedContainers, findsNWidgets(2));

      // Quick collapse button check
      expect(find.text('收起工具调用'), findsOneWidget);
      await tester.tap(find.text('收起工具调用'));
      await tester.pumpAndSettle();

      // Should be collapsed
      expect(find.text('输入参数:'), findsNothing);
    });

    testWidgets('displays running spinner when tool is executing', (tester) async {
      final runningTool = ToolExecution(
        name: 'fetch_docs',
        input: 'https://docs.deepseek.com',
        output: '',
        isRunning: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToolCallCard(tool: runningTool),
          ),
        ),
      );

      expect(find.text('运行中...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}
