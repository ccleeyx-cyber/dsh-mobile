import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/user_question.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/widgets/question_card.dart';
import 'package:dsh_mobile/views/widgets/message_search.dart';
import 'package:dsh_mobile/views/widgets/message_search_panel.dart';

/// 深色模式的 **渲染** 验收（v1.6.0）。
///
/// 这一批测试是深色模式能不能上线的判据，也是它区别于此前那个"安慰剂
/// darkTheme"的根本原因：那次的主题能构建、能通过所有测试，但没有一处断言
/// 真实 widget 在深色下画出来的颜色。
///
/// 做法是把 widget 放进 `ThemeScope(isDark: true)`，然后去 widget 树上找
/// 具体的 Container/Text，取它们的实际 `color`。断言的是**渲染出来的值**，
/// 不是"token 层有没有定义"—— 后者上一版就已经通过了。
void main() {
  Future<void> pumpDark(WidgetTester tester, Widget child, {Size? size}) async {
    tester.view.physicalSize = size ?? const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ThemeScope(isDark: true, child: child)));
    await tester.pump();
  }

  /// 找出树里第一个满足条件的 Container 的实际背景色。
  Color? containerColor(WidgetTester tester, bool Function(BoxDecoration d) test) {
    for (final w in tester.widgetList<Container>(find.byType(Container))) {
      final dec = w.decoration;
      if (dec is BoxDecoration && test(dec)) return dec.color;
    }
    return null;
  }

  group('QuestionCard 在深色下真的变深', () {
    Future<PendingQuestion> pending() async => PendingQuestion.fromJson({
          'eventId': 'e1',
          'sessionId': 's1',
          'questions': [
            {
              'id': 'q1',
              'question': '要继续吗？',
              'options': [
                {'label': '继续'}
              ],
            }
          ],
        });

    testWidgets('卡片底色取 questionSurface 的深色值', (tester) async {
      await pumpDark(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: QuestionCard(
              pending: await pending(),
              canAnswer: true,
              onSubmit: (_, __) => true,
              onDismiss: () {},
            ),
          ),
        ),
      );

      final bg = containerColor(tester, (d) => d.color == AppColors.questionSurfaceDark);
      expect(bg, AppColors.questionSurfaceDark,
          reason: '提问卡片在深色下必须用深色底；用浅色底就是"深色骨架 + 白卡片"的花屏');

      // 且绝对不能还是浅色的那个值
      expect(containerColor(tester, (d) => d.color == AppColors.questionSurface), isNull,
          reason: '深色下不应再出现浅色提问卡片底');
    });

    testWidgets('描边取 questionBorder 的深色值', (tester) async {
      await pumpDark(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: QuestionCard(
              pending: await pending(),
              canAnswer: true,
              onSubmit: (_, __) => true,
              onDismiss: () {},
            ),
          ),
        ),
      );
      final border = containerColor(tester, (d) {
        final b = d.border;
        return b is Border && b.top.color == AppColors.questionBorderDark;
      });
      expect(border, isNotNull, reason: '深色下提问卡描边应取深色值');
    });

    testWidgets('提交按钮的禁用态在深色下不是浅色块', (tester) async {
      await pumpDark(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: QuestionCard(
              pending: await pending(),
              canAnswer: true,
              onSubmit: (_, __) => true,
              onDismiss: () {},
            ),
          ),
        ),
      );
      final disabled = tester.widget<FilledButton>(find.byType(FilledButton));
      // 按钮当前是禁用的（未作答），所以必须解析 disabled 分支的颜色。
      const states = {WidgetState.disabled};
      final bg = disabled.style?.backgroundColor?.resolve(states);
      expect(bg, isNotNull);
      if (bg != null) {
        expect(ThemeData.estimateBrightnessForColor(bg), isNot(Brightness.light),
            reason: '深色下禁用按钮若仍是浅色，会在深底上非常刺眼');
      }
    });
  });

  group('TodoPanel 在深色下真的变深', () {
    testWidgets('面板底色取 surface 的深色值', (tester) async {
      await pumpDark(
        tester,
        Scaffold(
          body: TodoPanel(todos: [
            TodoItem.fromJson({'content': '读源码', 'status': 'completed'}),
            TodoItem.fromJson({'content': '写测试', 'status': 'in_progress'}),
          ]),
        ),
      );
      final bg = containerColor(tester, (d) => d.color == AppColors.surfaceDark);
      expect(bg, AppColors.surfaceDark);
      expect(containerColor(tester, (d) => d.color == AppColors.surface), isNull);
    });
  });

  group('搜索面板在深色下真的变深', () {
    testWidgets('面板与输入区取深色面', (tester) async {
      final hit = SearchHit(
        messageIndex: 0,
        matchStart: 0,
        matchEnd: 6,
        text: '找到 target 了',
        field: SearchField.content,
        timestamp: DateTime(2026, 1, 1),
      );
      await pumpDark(
        tester,
        Scaffold(
          body: MessageSearchPanel(
            query: 'target',
            results: [(first: hit, count: 1)],
            totalHits: 1,
            onQueryChanged: (_) {},
            onClose: () {},
            onJumpTo: (_) {},
          ),
        ),
      );
      final bg = containerColor(tester, (d) => d.color == AppColors.surfaceDark);
      expect(bg, isNotNull, reason: '搜索面板在深色下必须是深色面板');
      expect(containerColor(tester, (d) => d.color == AppColors.surface), isNull);
    });
  });

  group('浅色下没有被误伤', () {
    testWidgets('ThemeScope(isDark:false) 时卡片仍是浅色', (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final pending = PendingQuestion.fromJson({
        'eventId': 'e1',
        'sessionId': 's1',
        'questions': [
          {
            'id': 'q1',
            'question': '要继续吗？',
            'options': [
              {'label': '继续'}
            ],
          }
        ],
      });

      await tester.pumpWidget(MaterialApp(
        home: ThemeScope(
          isDark: false,
          child: Scaffold(
            body: SingleChildScrollView(
              child: QuestionCard(
                pending: pending,
                canAnswer: true,
                onSubmit: (_, __) => true,
                onDismiss: () {},
              ),
            ),
          ),
        ),
      ));
      await tester.pump();

      final bg = containerColor(tester, (d) => d.color == AppColors.questionSurface);
      expect(bg, AppColors.questionSurface,
          reason: '浅色模式必须与改动前逐像素一致 —— 这是整个重构的风险点');
      expect(containerColor(tester, (d) => d.color == AppColors.questionSurfaceDark), isNull);
    });
  });

  group('两个模式的取���确实不同', () {
    testWidgets('同一 widget 在两种模式下的底色不同', (tester) async {
      Future<Color?> read({required bool isDark}) async {
        tester.view.physicalSize = const Size(1000, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final pending = PendingQuestion.fromJson({
          'eventId': 'e',
          'sessionId': 's',
          'questions': [
            {
              'id': 'q',
              'question': 'x',
              'options': [
                {'label': 'a'}
              ],
            }
          ],
        });
        await tester.pumpWidget(MaterialApp(
          home: ThemeScope(
            isDark: isDark,
            child: Scaffold(
              body: SingleChildScrollView(
                child: QuestionCard(
                  pending: pending,
                  canAnswer: true,
                  onSubmit: (_, __) => true,
                  onDismiss: () {},
                ),
              ),
            ),
          ),
        ));
        await tester.pump();
        return containerColor(
          tester,
          (d) => d.color == AppColors.questionSurface || d.color == AppColors.questionSurfaceDark,
        );
      }

      final light = await read(isDark: false);
      final dark = await read(isDark: true);
      expect(light, AppColors.questionSurface);
      expect(dark, AppColors.questionSurfaceDark);
      expect(light, isNot(dark));
    });
  });
}