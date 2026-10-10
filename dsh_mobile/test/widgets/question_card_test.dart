import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/user_question.dart';
import 'package:dsh_mobile/views/widgets/attachment_tile.dart';
import 'package:dsh_mobile/views/widgets/question_card.dart';

/// 提问卡片 / TODO 面板 / 附件瓦片的 **UI 渲染** 验收。
///
/// 断言的是实际渲染出来的文字与可点击区域，不是"数据模型算对了"。中间隔着
/// 布局、溢出、禁用态这些只有在 widget tree 里才会暴露的问题 —— 只测模型
/// 会让一个按钮明明显示却点不动也照样全绿。
void main() {
  PendingQuestion buildPending({
    String eventId = 'evt-1',
    List<Map<String, dynamic>>? questions,
    String sessionId = 'session-abc',
  }) {
    return PendingQuestion.fromJson({
      'eventId': eventId,
      'sessionId': sessionId,
      'questions': questions ??
          [
            {'id': 'q1', 'question': '要继续吗？', 'options': [
              {'label': '继续'},
              {'label': '停止'},
            ]}
          ],
    });
  }

  Future<void> pumpCard(
    WidgetTester tester, {
    required PendingQuestion pending,
    bool canAnswer = true,
    bool Function(Map<String, List<String>>, Map<String, String>)? onSubmit,
    VoidCallback? onDismiss,
    double height = 1400,
  }) async {
    tester.view.physicalSize = Size(1000, height.toDouble());
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: QuestionCard(
            pending: pending,
            canAnswer: canAnswer,
            onSubmit: onSubmit ?? (_, __) => true,
            onDismiss: onDismiss ?? () {},
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  group('QuestionCard 渲染', () {
    testWidgets('渲染问题文本与全部选项', (tester) async {
      await pumpCard(tester, pending: buildPending());

      expect(find.text('Agent 有问题要问你'), findsOneWidget);
      expect(find.text('要继续吗？'), findsOneWidget);
      expect(find.text('继续'), findsOneWidget);
      expect(find.text('停止'), findsOneWidget);
      // 未答完时按钮禁用，并明确告知还差什么
      expect(find.text('请回答上面每一道题'), findsOneWidget);
    });

    testWidgets('detail 与 header 都被渲染出来', (tester) async {
      await pumpCard(
        tester,
        pending: buildPending(questions: [
          {
            'id': 'q1',
            'header': '数据存储',
            'question': '选哪个数据库？',
            'detail': '当前有 2322 个会话，需要按会话过滤。',
            'options': [
              {'label': 'SQLite'},
            ],
          }
        ]),
      );

      expect(find.text('数据存储'), findsOneWidget);
      expect(find.textContaining('2322 个会话'), findsOneWidget);
    });

    testWidgets('plan-review 显示审阅标题，并按名标注批准项', (tester) async {
      await pumpCard(
        tester,
        pending: buildPending(questions: [
          {
            'id': 'q1',
            'question': '按这份计划继续吗？',
            'options': [
              {'label': '否决'},
              {'label': '批准'},
            ],
            'intent': {'kind': 'plan-review', 'approve': '批准'},
          }
        ]),
      );

      expect(find.text('Agent 请你审阅一份计划'), findsOneWidget);
      // 「批准」排在第二位也必须被认出来 —— 引擎按名指定，不靠顺序
      expect(find.text('批准'), findsWidgets);
      expect(find.text('批准'), findsNWidgets(2), reason: '选项本身 + 「批准」徽章');
      expect(find.text('否决'), findsOneWidget);
    });

    testWidgets('无 intent 时不给任何选项打「批准」标记', (tester) async {
      await pumpCard(tester, pending: buildPending());
      // 只有选项本身，没有徽章
      expect(find.text('批准'), findsNothing);
    });

    testWidgets('选项描述被渲染', (tester) async {
      await pumpCard(
        tester,
        pending: buildPending(questions: [
          {
            'id': 'q1',
            'question': '继续?',
            'options': [
              {'label': '继续', 'description': '按原计划执行'},
            ],
          }
        ]),
      );
      expect(find.text('按原计划执行'), findsOneWidget);
    });

    testWidgets('多道题全部渲染，且逐题提示', (tester) async {
      await pumpCard(
        tester,
        pending: buildPending(questions: [
          {
            'id': 'q1',
            'question': '第一道题?',
            'options': [
              {'label': '甲'}
            ]
          },
          {
            'id': 'q2',
            'question': '第二道题?',
            'options': [
              {'label': '乙'}
            ]
          },
        ]),
      );
      expect(find.text('第一道题?'), findsOneWidget);
      expect(find.text('第二道题?'), findsOneWidget);
      expect(find.textContaining('共 2 道'), findsOneWidget);
    });
  });

  group('QuestionCard 交互', () {
    testWidgets('选中选项后提交按钮才可用，并上报正确的选择', (tester) async {
      Map<String, List<String>>? gotSel;
      Map<String, String>? gotCustom;
      await pumpCard(
        tester,
        pending: buildPending(),
        onSubmit: (sel, cus) {
          gotSel = sel;
          gotCustom = cus;
          return true;
        },
      );

      // 未答时按钮禁用
      final submitBtn = find.widgetWithText(FilledButton, '提交回答');
      expect(tester.widget<FilledButton>(submitBtn).onPressed, isNull);

      await tester.tap(find.text('继续'));
      await tester.pump();
      expect(find.text('将把回答发送给 Agent'), findsOneWidget);
      expect(tester.widget<FilledButton>(submitBtn).onPressed, isNotNull);

      await tester.tap(submitBtn);
      await tester.pump();
      expect(gotSel, isNotNull);
      expect(gotSel!['q1'], ['继续']);
      expect(gotCustom, isNotNull);
    });

    testWidgets('单选：再点一次取消选择', (tester) async {
      await pumpCard(tester, pending: buildPending());
      await tester.tap(find.text('继续'));
      await tester.pump();
      expect(find.text('将把回答发送给 Agent'), findsOneWidget);

      // 再点一次 → 取消
      await tester.tap(find.text('继续'));
      await tester.pump();
      expect(find.text('请回答上面每一道题'), findsOneWidget);
    });

    testWidgets('单选：点另一个选项会替换，而不是叠加', (tester) async {
      Map<String, List<String>>? gotSel;
      await pumpCard(
        tester,
        pending: buildPending(),
        onSubmit: (sel, _) {
          gotSel = sel;
          return true;
        },
      );
      await tester.tap(find.text('继续'));
      await tester.pump();
      await tester.tap(find.text('停止'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '提交回答'));
      await tester.pump();
      expect(gotSel!['q1'], ['停止']);
    });

    testWidgets('多选：可以同时选多个', (tester) async {
      Map<String, List<String>>? gotSel;
      await pumpCard(
        tester,
        pending: buildPending(questions: [
          {
            'id': 'q1',
            'question': '选哪些?',
            'multiSelect': true,
            'options': [
              {'label': 'A'},
              {'label': 'B'},
              {'label': 'C'},
            ],
          }
        ]),
        onSubmit: (sel, _) {
          gotSel = sel;
          return true;
        },
      );
      await tester.tap(find.text('A'));
      await tester.pump();
      await tester.tap(find.text('B'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '提交回答'));
      await tester.pump();
      expect(gotSel!['q1']!.toSet(), {'A', 'B'});
    });

    testWidgets('两道题时必须都答完才允许提交', (tester) async {
      Map<String, List<String>>? gotSel;
      await pumpCard(
        tester,
        pending: buildPending(questions: [
          {
            'id': 'q1',
            'question': '第一道?',
            'options': [
              {'label': '甲'}
            ]
          },
          {
            'id': 'q2',
            'question': '第二道?',
            'options': [
              {'label': '乙'}
            ]
          },
        ]),
        onSubmit: (sel, _) {
          gotSel = sel;
          return true;
        },
      );

      await tester.tap(find.text('甲'));
      await tester.pump();
      final btn = find.widgetWithText(FilledButton, '提交回答');
      expect(tester.widget<FilledButton>(btn).onPressed, isNull, reason: '还有一道没答');

      await tester.tap(find.text('乙'));
      await tester.pump();
      expect(tester.widget<FilledButton>(btn).onPressed, isNotNull);

      await tester.tap(btn);
      await tester.pump();
      expect(gotSel!.keys.toSet(), {'q1', 'q2'});
    });

    testWidgets('只填自定义文本也算作答', (tester) async {
      Map<String, List<String>>? gotSel;
      Map<String, String>? gotCustom;
      await pumpCard(
        tester,
        pending: buildPending(),
        onSubmit: (sel, cus) {
          gotSel = sel;
          gotCustom = cus;
          return true;
        },
      );

      await tester.enterText(find.byType(TextField), '我自己写的答案');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '提交回答'));
      await tester.pump();

      expect(gotCustom!['q1'], '我自己写的答案');
      // 没点任何选项时 selections 里**没有** q1 这个键（不是空数组）。
      // 服务端用 `?? const []` 兜成空列表，这是有意的稀疏表示：为空数组和
      // "没有这个键"在引擎侧等价，没必要为未选项占位。
      expect(gotSel!.containsKey('q1'), isFalse);
      expect(gotSel!['q1'], isNull);
    });
  });

  group('QuestionCard 降级与失败', () {
    testWidgets('离线时按钮禁用并给出说明', (tester) async {
      await pumpCard(tester, pending: buildPending(), canAnswer: false);

      expect(find.text('当前未连接到网关，无法提交回答。Agent 仍在等待。'), findsOneWidget);
      // 即使选中了选项也不能提交
      await tester.tap(find.text('继续'));
      await tester.pump();
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '提交回答')).onPressed, isNull);
    });

    testWidgets('提交失败（未发出）时恢复可提交状态，不把卡片弄丢', (tester) async {
      await pumpCard(tester, pending: buildPending(), onSubmit: (_, __) => false);

      await tester.tap(find.text('继续'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '提交回答'));
      await tester.pump();

      // 按钮恢复可用 → 用户能重试；卡片仍在 → 上下文没丢
      expect(find.text('要继续吗？'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '提交回答')).onPressed, isNotNull);
    });

    testWidgets('收起按钮先确认，且明确说明这不是拒绝', (tester) async {
      var dismissed = false;
      await pumpCard(tester, pending: buildPending(), onDismiss: () => dismissed = true);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      // 必须先弹确认，且说清「不是拒绝、去桌面端回答」
      expect(find.text('在手机上略过这个提问？'), findsOneWidget);
      expect(find.textContaining('这不是拒绝回答'), findsOneWidget);
      expect(dismissed, isFalse, reason: '没确认前不能收起');

      await tester.tap(find.text('在手机上收起'));
      await tester.pumpAndSettle();
      expect(dismissed, isTrue);
    });

    testWidgets('确认框里选「继续回答」则不收起', (tester) async {
      var dismissed = false;
      await pumpCard(tester, pending: buildPending(), onDismiss: () => dismissed = true);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续回答'));
      await tester.pumpAndSettle();
      expect(dismissed, isFalse);
      expect(find.text('要继续吗？'), findsOneWidget);
    });
  });

  group('TodoPanel 渲染', () {
    Future<void> pumpTodos(WidgetTester tester, List<TodoItem> todos) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: TodoPanel(todos: todos))),
      ));
      await tester.pump();
    }

    testWidgets('渲染每一条与完成计数', (tester) async {
      await pumpTodos(tester, [
        TodoItem.fromJson({'content': '读源码', 'status': 'completed'}),
        TodoItem.fromJson({'content': '补转发', 'status': 'in_progress'}),
        TodoItem.fromJson({'content': '写测试', 'status': 'pending'}),
      ]);

      expect(find.text('任务进度'), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
      expect(find.text('读源码'), findsOneWidget);
      expect(find.text('补转发'), findsOneWidget);
      expect(find.text('写测试'), findsOneWidget);
    });

    testWidgets('空列表不渲染任何东西', (tester) async {
      await pumpTodos(tester, []);
      expect(find.byType(TodoPanel), findsOneWidget); // 组件在，但没有可见内容
      expect(find.text('任务进度'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('全部完成时计数为 n/n', (tester) async {
      await pumpTodos(tester, [
        TodoItem.fromJson({'content': 'a', 'status': 'completed'}),
        TodoItem.fromJson({'content': 'b', 'status': 'completed'}),
      ]);
      expect(find.text('2/2'), findsOneWidget);
    });
  });

  group('AttachmentImageTile', () {
    testWidgets('没有网关连接时给出明确提示而不是空白', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AttachmentImageTile(
            ref: AttachmentRef.fromJson({'id': 'att-1', 'mimeType': 'image/png'}),
            endpoint: null,
          ),
        ),
      ));
      await tester.pump();
      expect(find.textContaining('未连接网关'), findsOneWidget);
    });

    testWidgets('渲染尺寸与大小元信息', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AttachmentImageTile(
            ref: AttachmentRef.fromJson({
              'id': 'att-1',
              'mimeType': 'image/png',
              'width': 800,
              'height': 600,
              'bytes': 20480,
            }),
            endpoint: null,
          ),
        ),
      ));
      await tester.pump();
      expect(find.textContaining('800×600'), findsOneWidget);
      expect(find.textContaining('KB'), findsOneWidget);
    });
  });

  group('QuestionErrorBanner', () {
    testWidgets('渲染错误文案并带图标', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: QuestionErrorBanner(message: '该提问已过期')),
      ));
      await tester.pump();
      expect(find.text('该提问已过期'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    });
  });

  group('QuestionCard 多选项布局（回归：提交按钮被顶出屏幕）', () {
    /// 用户实测场景：多选题、每个选项带 description，卡片挂在输入框上方的
    /// 固定区（自身不在可滚动列表里），选项一多提交按钮就被顶出屏幕外。
    /// 修法是卡片限高 + 题目区内滚 + 提交按钮钉底。这组测试断言的就是
    /// "无论多少选项，提交按钮永远在视口内可点"。
    PendingQuestion buildWidePending() {
      final options = List.generate(
        12,
        (i) => {'label': '选项${i + 1}', 'description': '这是第 ${i + 1} 个选项的说明文字，比较长'},
      );
      return PendingQuestion.fromJson({
        'eventId': 'evt-wide',
        'sessionId': 'session-abc',
        'questions': [
          {'id': 'q1', 'question': '请选择所有适用的项？', 'options': options, 'multiSelect': true},
        ],
      });
    }

    Future<void> pumpInFixedArea(WidgetTester tester, PendingQuestion pending) async {
      // 模拟真实挂载环境：卡片上方有一个撑满剩余空间的占位（相当于消息
      // 列表），卡片本身在 Column 固定区 —— 即它**不能**靠外层滚动自救。
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              SizedBox(
                width: 1000,
                child: QuestionCard(
                  pending: pending,
                  canAnswer: true,
                  onSubmit: (_, __) => true,
                  onDismiss: () {},
                ),
              ),
            ],
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('选项再多，提交按钮仍在屏幕内且可点击', (tester) async {
      await pumpInFixedArea(tester, buildWidePending());

      final btn = find.widgetWithText(FilledButton, '提交回答');
      expect(btn, findsOneWidget);
      // 按钮中心必须落在视口内 —— 这就是"最下面没法提交"的反向断言。
      final center = tester.getCenter(btn);
      expect(center.dy, lessThan(2400), reason: '提交按钮被顶出屏幕（复现了用户报告的 bug）');
      expect(center.dy, greaterThan(0));
    });

    testWidgets('超出的选项收进卡片内部滚动区，不撑破限高', (tester) async {
      await pumpInFixedArea(tester, buildWidePending());

      final cardSize = tester.getSize(find.byType(QuestionCard));
      // 420 maxHeight + 12 上下 margin = 上限 432。没有限高时这张
      // 12 选项卡的实际高度远超此值（每个选项两行文字 + 间距）。
      expect(cardSize.height, lessThan(433), reason: '卡片必须被 maxHeight=420 约束，不能无限撑高');
    });
  });
}