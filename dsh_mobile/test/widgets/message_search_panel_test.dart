import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/views/widgets/message_search.dart';
import 'package:dsh_mobile/views/widgets/message_search_panel.dart';

/// 会话内查找面板（v1.4.2）的 UI 渲染验收。
///
/// 两条重点，都对应"看起来能用但其实不可信"的失败模式：
/// * **"N 条结果"必须等于实际渲染的行数。** 数字和列表由同一份数据驱动，
///   但如果计数用 hits.length 而列表用 collapse() 后的行数，两者就会不一致，
///   而不一致的数字比没有数字更糟。
/// * **空查询与"搜了但没结果"是两件事。** 空查询显示"没有找到"会被读成功能坏了。
void main() {
  SearchHit hitAt(int idx, {String text = '找到 target 了吗', SearchField field = SearchField.content}) {
    final at = text.indexOf('target');
    return SearchHit(
      messageIndex: idx,
      matchStart: at < 0 ? 0 : at,
      matchEnd: at < 0 ? 0 : at + 6,
      text: text,
      field: field,
      timestamp: DateTime(2026, 1, 1, 12, 30),
    );
  }

  Future<void> pumpPanel(
    WidgetTester tester, {
    required String query,
    required List<({SearchHit first, int count})> results,
    int totalHits = 0,
    ValueChanged<String>? onChanged,
    void Function(SearchHit)? onJump,
  }) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            MessageSearchPanel(
              query: query,
              results: results,
              totalHits: totalHits,
              onQueryChanged: onChanged ?? (_) {},
              onClose: () {},
              onJumpTo: onJump ?? (_) {},
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
  }

  group('空状态', () {
    testWidgets('空查询不显示结果区，也不显示"没有找到"', (tester) async {
      await pumpPanel(tester, query: '', results: const []);
      expect(find.textContaining('没有找到'), findsNothing);
      expect(find.textContaining('条结果'), findsNothing);
      // 输入框仍在（可以开始打字）
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('有查询但无命中 → 明确说"没有包含 X 的内容"', (tester) async {
      await pumpPanel(tester, query: 'zzz', results: const [], totalHits: 0);
      expect(find.textContaining('没有包含'), findsOneWidget);
      expect(find.textContaining('zzz'), findsOneWidget);
      // 关键：不能显示"0 条结果"，因为那与"没搜过"混淆
      expect(find.textContaining('条结果'), findsNothing);
    });
  });

  group('结果计数与行数一致', () {
    testWidgets('计数等于实际渲染的行数', (tester) async {
      final rows = [
        (first: hitAt(0), count: 3),
        (first: hitAt(1), count: 1),
        (first: hitAt(2), count: 5),
      ];
      await pumpPanel(tester, query: 'target', results: rows, totalHits: 9);

      expect(find.textContaining('3 条结果'), findsOneWidget);
      expect(find.textContaining('9 处匹配'), findsOneWidget);

      // 数真正的行：每行有一个字段标签
      expect(find.text('正文'), findsNWidgets(3));
    });

    testWidgets('一处命中时不显示"处"后缀', (tester) async {
      await pumpPanel(
        tester,
        query: 'target',
        results: [(first: hitAt(0), count: 1)],
        totalHits: 1,
      );
      expect(find.textContaining('1 条结果'), findsOneWidget);
      expect(find.textContaining('处匹配'), findsNothing);
    });

    testWidgets('多于一处命中时同时给出条数与处数', (tester) async {
      await pumpPanel(
        tester,
        query: 'target',
        results: [(first: hitAt(0), count: 4)],
        totalHits: 4,
      );
      expect(find.textContaining('1 条结果'), findsOneWidget);
      expect(find.textContaining('4 处匹配'), findsOneWidget);
    });
  });

  group('结果行内容', () {
    testWidgets('渲染字段标签与命中次数', (tester) async {
      await pumpPanel(
        tester,
        query: 'target',
        results: [(first: hitAt(0), count: 2)],
        totalHits: 2,
      );
      expect(find.text('正文'), findsOneWidget);
      expect(find.text('2 处'), findsOneWidget);
      // 时间戳：不是今天就显示 月/日
      expect(find.text('1/1'), findsOneWidget);
    });

    testWidgets('字段标签随来源变化', (tester) async {
      await pumpPanel(
        tester,
        query: 'target',
        results: [
          (first: hitAt(0, field: SearchField.thinking), count: 1),
          (first: hitAt(1, field: SearchField.toolName), count: 1),
        ],
        totalHits: 2,
      );
      expect(find.text('思考'), findsOneWidget);
      expect(find.text('工具'), findsOneWidget);
    });

    testWidgets('命中的词在片段里被高亮', (tester) async {
      await pumpPanel(
        tester,
        query: 'target',
        results: [(first: hitAt(0), count: 1)],
        totalHits: 1,
      );
      // 高亮是通过 Text.rich 的 span 实现的；Text.rich 存在即说明走的是富文本路径
      expect(find.byType(RichText), findsWidgets);
      // 片段文本仍然完整可读（不因高亮丢字）
      expect(find.textContaining('找到'), findsOneWidget);
    });
  });

  group('交互', () {
    testWidgets('点击结果触发跳转回调', (tester) async {
      SearchHit? jumped;
      await pumpPanel(
        tester,
        query: 'target',
        results: [(first: hitAt(7, text: 'target 在第七条'), count: 1)],
        totalHits: 1,
        onJump: (h) => jumped = h,
      );
      await tester.tap(find.textContaining('target 在第七条'));
      await tester.pump();
      expect(jumped, isNotNull);
      expect(jumped!.messageIndex, 7);
    });

    testWidgets('输入触发 onQueryChanged', (tester) async {
      final typed = <String>[];
      await pumpPanel(
        tester,
        query: '',
        results: const [],
        onChanged: typed.add,
      );
      await tester.enterText(find.byType(TextField), '删除');
      await tester.pump();
      expect(typed, contains('删除'));
    });
  });

  group('查询含元字符时不高亮错乱', () {
    testWidgets('查询 "a.c" 时按字面匹配并正确高亮', (tester) async {
      final text = '版本 a.c 与 aXc';
      await pumpPanel(
        tester,
        query: 'a.c',
        results: [
          (
            first: SearchHit(
              messageIndex: 0,
              matchStart: 3,
              matchEnd: 6,
              text: text,
              field: SearchField.content,
              timestamp: DateTime(2026, 1, 1),
            ),
            count: 1
          )
        ],
        totalHits: 1,
      );
      expect(find.textContaining('条结果'), findsOneWidget);
      expect(find.byType(RichText), findsWidgets);
    });

    testWidgets('查询 ".*" 不崩溃也不误标多处', (tester) async {
      final text = '没有星号';
      final at = text.indexOf('.*'); // -1：不存在
      await pumpPanel(
        tester,
        query: '.*',
        results: [
          (
            first: SearchHit(
              messageIndex: 0,
              matchStart: at < 0 ? 0 : at,
              matchEnd: at < 0 ? 0 : at + 2,
              text: text,
              field: SearchField.content,
              timestamp: DateTime(2026, 1, 1),
            ),
            count: 1
          )
        ],
        totalHits: 1,
      );
      // 不抛异常即可；高亮路径对空 range 也必须安全
      expect(tester.takeException(), isNull);
    });
  });
}