import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/widgets/thinking_card.dart';
import 'package:dsh_mobile/widgets/tool_call_card.dart';
import 'package:dsh_mobile/models/chat_message.dart';

/// 折叠卡（思考 / 工具）的行为回归。
///
/// ## 2026-10-17 Phase 2 的断言迁移
///
/// 这个文件原来逐字锁死了旧视觉（「深度思考中...」「工具调用: run_shell」、
/// 折叠态的行数摘要、maxHeight 240、运行态的 '运行中...' + spinner）。Phase 2
/// 主动废弃了这些形态，所以断言改成**等价语义**：仍然测「折叠/展开可切换、
/// 边界高度、运行态可见、摘要位置」这四个行为，只是不再把废弃的文案当成契约。
///
/// 具体迁移（旧 → 新，以及为什么）：
/// * `find.text('深度思考中...')` → `find.textContaining('思考中')`：
///   折叠态文案改为「思考中 · N 字」/「思考过程 · N 字」（thinking_card.dart），
///   锁死整串会把"字数格式"变成测试契约，而要锁的是"流式中有一行进行态文案"。
/// * 展开态 `maxHeight == 280` **保留不动**：思考正文的限高没变。
/// * `find.text('工具调用: run_shell')` → `find.textContaining('run_shell')`：
///   单行紧凑条只渲染工具名，不再有「工具调用:」前缀。
/// * 折叠态 `find.textContaining('2 行')` → 反向断言 `findsNothing`：
///   摘要降级为"只在展开态显示"。反向断言锁的是设计本身，比原来更有价值。
/// * `maxHeight == 240` → `220`：输入/输出区限高按规格书收紧。
/// * `find.text('运行中...')` + `CircularProgressIndicator` →
///   `ValueKey('tool-status-dot-running')`：状态从徽章+文案降级成 6px 圆点，
///   颜色在 widget test 里无法可靠断言，所以用稳定的 key 断言"状态可见"。
void main() {
  group('ThinkingCard Ergonomics & Bounded Display', () {
    testWidgets('respects user manual collapse during active streaming',
        (tester) async {
      // 1. Initial streaming thinking card
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body:
                ThinkingCard(content: 'Initial thoughts...', isThinking: true),
          ),
        ),
      );

      expect(find.textContaining('思考中'), findsOneWidget);
      expect(find.text('Initial thoughts...'), findsOneWidget);

      // 2. User collapses thinking card
      await tester.tap(find.byType(InkWell).first);
      // 这里必须用 pump() 而不是 pumpAndSettle()。
      //
      // isThinking: true 时标题行渲染 CircularProgressIndicator
      // （thinking_card.dart 的进行态小指示器），那是永久重复动画，
      // pumpAndSettle() 会一直推进到超时并抛错。而折叠动作本身只是 setState +
      // `if (_expanded)` 条件渲染，没有过渡动画，推进一帧就足够。
      await tester.pump();
      expect(find.text('Initial thoughts...'), findsNothing);

      // 3. New token chunk arrives (rebuild with new content & isThinking: true)
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ThinkingCard(
                content: 'Initial thoughts... more streaming tokens',
                isThinking: true),
          ),
        ),
      );
      await tester.pump();

      // CARD MUST REMAIN COLLAPSED (Regression bug fix)
      expect(
          find.text('Initial thoughts... more streaming tokens'), findsNothing);
    });

    testWidgets('enforces maxHeight 280 constraint with internal scroll view',
        (tester) async {
      final longContent =
          List.generate(100, (i) => 'Line $i: detailed cognitive step')
              .join('\n');
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
            body: ThinkingCard(
                content: 'Analysis completed successfully', isThinking: false),
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

    testWidgets('折叠态是单行引用块：无填充底色、无描边（Phase 2.2）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ThinkingCard(content: 'done thinking', isThinking: false),
          ),
        ),
      );

      // 引用块的唯一装饰是左侧 2px 竖线；任何 BoxDecoration.color 都意味着
      // 它又变回了"卡片"。只在 ThinkingCard 子树里找，避免命中 Material 内部
      // 那些与本次改造无关的容器。
      final decorated = tester
          .widgetList<Container>(
        find.descendant(
          of: find.byType(ThinkingCard),
          matching: find.byType(Container),
        ),
      )
          .where((c) {
        final d = c.decoration;
        return d is BoxDecoration && d.color != null;
      });
      expect(decorated, isEmpty, reason: '思考块不得有填充底色');
      expect(find.textContaining('思考过程'), findsOneWidget);
    });

    testWidgets('思考结束自动收起，但用户干预过就不再抢（_userTouched）', (tester) async {
      Widget host(bool thinking) => MaterialApp(
            home: Scaffold(
              body: ThinkingCard(content: 'trace', isThinking: thinking),
            ),
          );

      // A. 用户从未表过态：思考结束后自动收起（省空间，想看可点开）
      await tester.pumpWidget(host(true));
      expect(find.text('trace'), findsOneWidget, reason: '流式中默认展开');
      await tester.pumpWidget(host(false));
      await tester.pump();
      expect(find.text('trace'), findsNothing, reason: '没表过态 → 结束后自动收起');

      // B. 用户表过态（收起再展开）：结束后**必须**保展开
      //
      // 这条锁的是「自动收起只对未被用户干预过的块生效」。用户在流式中点开
      // 思考想读，结束后被自动收掉，等于第二次抢他的状态 —— 与既有的
      // 「手动折叠不被抢」是同一条规则的另一个方向。
      await tester.pumpWidget(host(true));
      await tester.pump();
      await tester.tap(find.byType(InkWell).first);
      await tester.pump();
      await tester.tap(find.byType(InkWell).first);
      await tester.pump();
      expect(find.text('trace'), findsOneWidget);
      await tester.pumpWidget(host(false));
      await tester.pump();
      expect(find.text('trace'), findsOneWidget, reason: '用户表过态 → 不得抢走展开状态');
    });
  });

  group('ToolCallCard Ergonomics & Metrics', () {
    testWidgets('单行紧凑条：只有工具名与状态圆点，摘要在展开后才出现', (tester) async {
      final tool = ToolExecution(
        name: 'run_shell',
        input: 'git status -s',
        output:
            'M lib/widgets/thinking_card.dart\nM lib/widgets/tool_call_card.dart',
        isRunning: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToolCallCard(tool: tool),
          ),
        ),
      );

      // Collapsed: name + status dot only.
      expect(find.textContaining('run_shell'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('tool-status-dot-done')), findsOneWidget);
      // 摘要（「2 行 · X B」）降级为展开态专属 —— 折叠态不得出现行数摘要。
      expect(find.textContaining(' 行'), findsNothing);

      // Tap to expand
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      // Both input and output must have maxHeight: 220
      final boundedContainers = find.byWidgetPredicate(
        (w) => w is Container && w.constraints?.maxHeight == 220,
      );
      expect(boundedContainers, findsNWidgets(2));

      // 展开后摘要才出现（「执行输出 · 2 行 · 57 B」）
      expect(find.textContaining('2 行'), findsOneWidget);
      expect(find.textContaining('输入参数'), findsOneWidget);

      // Quick collapse button check
      expect(find.text('收起工具调用'), findsOneWidget);
      await tester.tap(find.text('收起工具调用'));
      await tester.pumpAndSettle();

      // Should be collapsed
      expect(find.textContaining('输入参数'), findsNothing);
    });

    testWidgets('bash 的结构化输入：折叠显示命令摘要，展开不再铺原始 JSON', (tester) async {
      final tool = ToolExecution(
        name: 'bash',
        input: '{"command":"cd /tmp && ls","description":"列出文件"}'
            '{"command":"pwd","description":"显示目录"}',
        output: 'ok',
        isRunning: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ToolCallCard(tool: tool)),
        ),
      );

      expect(find.textContaining('2 条命令'), findsOneWidget);
      expect(find.textContaining('{"command"'), findsNothing);

      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      expect(find.text('执行的命令 · 2 条'), findsOneWidget);
      expect(find.textContaining('列出文件'), findsWidgets);
      expect(find.text('cd /tmp && ls'), findsOneWidget);
      expect(find.text('pwd'), findsOneWidget);
      expect(find.textContaining('{"command"'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('tool-raw-input-toggle')));
      await tester.pumpAndSettle();
      expect(find.textContaining('{"command"'), findsOneWidget);
    });

    testWidgets('displays running status dot when tool is executing',
        (tester) async {
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

      // 运行态是 accent 呼吸圆点，不是 spinner —— key 比颜色更可靠。
      expect(find.byKey(const ValueKey('tool-status-dot-running')),
          findsOneWidget);
    });

    testWidgets('输出超过 50 行时终端式折叠：头 5 行 + 省略行 + 尾 5 行', (tester) async {
      final lines = List.generate(60, (i) => 'line-$i');
      final tool = ToolExecution(
        name: 'bash',
        input: 'seq 60',
        output: lines.join('\n'),
        isRunning: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToolCallCard(tool: tool),
          ),
        ),
      );
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      // 头 5 + 尾 5，中间 50 行折叠
      expect(find.textContaining('中间省略 50 行'), findsOneWidget);
      expect(find.textContaining('line-0'), findsOneWidget);
      expect(find.textContaining('line-59'), findsOneWidget);
      expect(find.textContaining('line-30'), findsNothing);

      // 点击展开全文
      await tester.tap(find.textContaining('中间省略 50 行'));
      await tester.pumpAndSettle();
      expect(find.textContaining('line-30'), findsOneWidget);
      expect(find.textContaining('中间省略 50 行'), findsNothing);
    });

    testWidgets('失败输出点亮失败圆点', (tester) async {
      final failed = ToolExecution(
        name: 'bash',
        input: 'npm test',
        output: 'Tests failed\nError: 3 assertions did not match',
        isRunning: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ToolCallCard(tool: failed),
          ),
        ),
      );

      expect(
          find.byKey(const ValueKey('tool-status-dot-failed')), findsOneWidget);
    });
  });

  group('AggregatedToolCalls（同消息内 ≥3 个工具调用聚合折叠）', () {
    List<ToolExecution> tools(int n) => [
          for (var i = 0; i < n; i++)
            ToolExecution(
                name: 'tool-$i', input: '', output: 'ok', isRunning: false),
        ];

    testWidgets('4 个工具调用折叠成一行，点击展开完整列表', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
                child: AggregatedToolCalls(tools: tools(4))),
          ),
        ),
      );

      expect(find.textContaining('执行了 4 个工具'), findsOneWidget);
      expect(find.textContaining('全部成功'), findsOneWidget);
      // 折叠态不渲染逐条工具
      expect(find.text('tool-0'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('tool-aggregate-toggle')));
      await tester.pumpAndSettle();

      expect(find.text('tool-0'), findsOneWidget);
      expect(find.text('tool-3'), findsOneWidget);
    });

    testWidgets('不到 3 个时逐条渲染，不聚合', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
                child: AggregatedToolCalls(tools: tools(2))),
          ),
        ),
      );

      expect(find.textContaining('执行了'), findsNothing);
      expect(find.text('tool-0'), findsOneWidget);
      expect(find.text('tool-1'), findsOneWidget);
    });
  });
}
