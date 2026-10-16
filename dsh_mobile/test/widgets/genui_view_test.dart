import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/widgets/genui/genui_charts.dart';
import 'package:dsh_mobile/widgets/genui/genui_inline.dart';
import 'package:dsh_mobile/widgets/genui/genui_parse.dart';
import 'package:dsh_mobile/widgets/genui/genui_view.dart';
import 'package:dsh_mobile/widgets/safe_markdown.dart';

/// ```dsh-ui 在手机端的渲染回归测试。
///
/// 核心断言只有一句：**围栏里的东西必须变成组件，而不是一坨 JSON 代码块**。
/// 这条链路此前完全不存在（GenUI 的渲染器是浏览器侧模块，手机端拿不到），所以
/// 每个用例都在钉住"端到端真的画出来了"。
void main() {
  Future<void> pump(WidgetTester tester, Widget child, {Size size = const Size(420, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (ctx, c) => ThemeScope(isDark: false, child: c ?? const SizedBox()),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );
    await tester.pump();
  }

  /// 一条正文：前面一句话 + 一个 dsh-ui 围栏。
  String body(String spec) => '结果如下：\n\n```dsh-ui\n$spec\n```';

  group('SafeMarkdown 接线：围栏 → 组件', () {
    testWidgets('表格围栏渲染成组件，而不是代码块', (tester) async {
      await pump(
        tester,
        SafeMarkdown(
          data: body('{"title":"概览","items":[{"type":"table","columns":["项目","值"],"rows":[["用例","453"]]}]}'),
        ),
      );

      expect(find.byType(GenuiSpecView), findsOneWidget);
      expect(find.text('概览'), findsOneWidget);
      expect(find.text('项目'), findsOneWidget);
      expect(find.text('453'), findsOneWidget);
      // 围栏标记本身绝不该出现在画面上
      expect(find.textContaining('```'), findsNothing);
      expect(find.textContaining('"type"'), findsNothing);
    });

    testWidgets('没有围栏的消息不引入组件层（保持原路径）', (tester) async {
      await pump(tester, const SafeMarkdown(data: '普通回答，**加粗**一下。'));
      expect(find.byType(GenuiSpecView), findsNothing);
      // ⚠️ 不能断言 RichText：SafeMarkdown 默认 selectable，markdown 渲染成
      // SelectableText（内部 EditableText），画面里没有 RichText。
      expect(find.byType(SelectableText), findsWidgets);
      expect(find.textContaining('普通回答', findRichText: true), findsWidgets);
    });

    testWidgets('JSON 坏掉的围栏退回代码块，但原文仍在', (tester) async {
      await pump(tester, SafeMarkdown(data: body('{"items":[{"type":"text"')));
      expect(find.byType(GenuiSpecView), findsNothing);
      // 原文以代码块形式保留 —— 用户至少能看到内容，不是空白
      expect(find.textContaining('"type"'), findsWidgets);
    });

    testWidgets('围栏前后的正文都还在', (tester) async {
      await pump(
        tester,
        const SafeMarkdown(data: '开头。\n\n```dsh-ui\n{"items":[{"type":"divider"}]}\n```\n\n结尾。'),
      );
      expect(find.byType(GenuiSpecView), findsOneWidget);
      expect(find.textContaining('开头'), findsWidgets);
      expect(find.textContaining('结尾'), findsWidgets);
    });
  });

  group('组件渲染', () {
    Future<void> pumpNode(WidgetTester tester, Map<String, dynamic> node) => pump(
          tester,
          GenuiSpecView(spec: GenuiSpec.fromJson({'items': [node]})!),
        );

    testWidgets('callout 的标题与正文都画出来（字段名是 content 不是 text）', (tester) async {
      await pumpNode(tester, {'type': 'callout', 'tone': 'warning', 'title': '注意', 'content': '这里有个坑'});
      expect(find.text('注意'), findsOneWidget);
      expect(find.text('这里有个坑'), findsOneWidget);
    });

    testWidgets('keyvalue 用 pairs 而不是 items', (tester) async {
      await pumpNode(tester, {
        'type': 'keyvalue',
        'pairs': [
          {'key': '端口', 'value': '3088'},
          {'key': '状态', 'value': 'running'},
        ],
      });
      expect(find.text('端口'), findsOneWidget);
      expect(find.text('3088'), findsOneWidget);
      expect(find.text('running'), findsOneWidget);
    });

    testWidgets('list 项用 label/description 这类别名也能归一化', (tester) async {
      await pumpNode(tester, {
        'type': 'list',
        'items': [
          {'label': '标题', 'description': '说明'},
          '裸字符串项',
        ],
      });
      expect(find.text('标题'), findsOneWidget);
      expect(find.text('说明'), findsOneWidget);
      expect(find.text('裸字符串项'), findsOneWidget);
    });

    testWidgets('stat 的数值与涨跌都渲染', (tester) async {
      await pumpNode(tester, {'type': 'stat', 'label': '用例', 'value': '453', 'delta': '+33'});
      expect(find.text('用例'), findsOneWidget);
      expect(find.text('453'), findsOneWidget);
      expect(find.text('+33'), findsOneWidget);
    });

    testWidgets('chart 交给自绘层（不依赖第三方图表库）', (tester) async {
      await pumpNode(tester, {
        'type': 'chart',
        'kind': 'bars',
        'data': [
          {'label': 'A', 'value': 3},
          {'label': 'B', 'value': 5},
        ],
      });
      expect(find.byType(GenuiChart), findsOneWidget);
    });

    testWidgets('不支持的类型给说明 + 原始数据，不丢信息', (tester) async {
      await pumpNode(tester, {'type': 'scene3d', 'meshes': [], 'title': '3D'});
      expect(find.textContaining('暂不支持'), findsOneWidget);
      expect(find.text('查看原始数据'), findsOneWidget);
    });

    testWidgets('steps 的序号与当前步都画出来', (tester) async {
      await pumpNode(tester, {
        'type': 'steps',
        'current': 1,
        'steps': [
          {'title': '第一步'},
          {'title': '第二步'},
        ],
      });
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('第一步'), findsOneWidget);
      expect(find.text('第二步'), findsOneWidget);
    });

    testWidgets('table 的合计行按数值列求和', (tester) async {
      await pumpNode(tester, {
        'type': 'table',
        'columns': ['项', '值'],
        'rows': [
          ['a', '3'],
          ['b', '5'],
        ],
        'total': true,
      });
      expect(find.text('合计'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
    });
  });

  group('行内富文本（纯函数）', () {
    const base = TextStyle(fontSize: 13);

    test('四种标记各自产出带样式的 span', () {
      final spans = parseGenuiInline('`code` **粗** ==亮== 末尾', base: base);

      TextSpan spanWithText(String t) =>
          spans.whereType<TextSpan>().firstWhere((s) => s.text == t);

      expect(spanWithText('code').style?.fontFamily, 'monospace');
      expect(spanWithText('粗').style?.fontWeight, FontWeight.w700);
      expect(spanWithText('亮').style?.backgroundColor, isNotNull);
      // 未被标记包裹的文字原样保留（标记之间的空白会单独成段，所以按包含判断）
      expect(spans.whereType<TextSpan>().map((s) => s.text).join(), contains('末尾'));
    });

    test('链接只在给了回调时可点，且只认 http/https/mailto', () {
      bool anyClickable(List<InlineSpan> spans) =>
          spans.whereType<TextSpan>().any((s) => s.recognizer != null);

      expect(anyClickable(parseGenuiInline('[官网](https://example.com)', base: base, onLink: (_) {})), isTrue);
      expect(
        anyClickable(parseGenuiInline('[官网](https://example.com)', base: base)),
        isFalse,
        reason: '没有回调时不能假装可点',
      );
      expect(
        anyClickable(parseGenuiInline('[x](javascript:void)', base: base, onLink: (_) {})),
        isFalse,
        reason: '非 http/https/mailto 协议不接受',
      );
    });

    test('没闭合的标记原样显示，不吞内容', () {
      final spans = parseGenuiInline('**没闭合的加粗', base: base);
      final text = spans.map((s) => (s as TextSpan).text).join();
      expect(text, '**没闭合的加粗');
    });

    test('空串产出空列表（不产生空 span）', () {
      expect(parseGenuiInline('', base: base), isEmpty);
    });
  });
}
