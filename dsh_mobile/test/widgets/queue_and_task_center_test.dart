import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/task_center.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';

/// 排队消息面板的界面回归测试（v1.13 引入；v1.14 改交互）。
///
/// ⚠️ v1.14 起**独立「任务」页已经删除**（会话洞察改成"事件进流、状态进头"：
/// 交付物/用量/变更/作业/定时都在当前会话里）。本文件原先的「任务页」分组随之
/// 删除，取而代之的是：
///   * 排队 dock 的**就地展开**（限高 220 + 内部滚动）—— 溢出不再跳转页面；
///   * 会话洞察的状态条 / 信息面板 / 本轮产出卡片 —— 在
///     `session_insights_test.dart` 里覆盖。
///
/// 断言的是**界面上出现了什么**，因为这一轮新增功能最容易出的问题恰恰是
/// "数据拿到了但没渲染"或"渲染了却点不动"。数据层用 debug 注入口摆好
/// （不打真实网关：历史教训是那样会污染用户会话）。
///
/// 运行中投递的语义测试（默认排队 / 二次确认才插话 / 失败回滚）在
/// `queue_steer_impl_test.dart` —— 那些用例需要 `debugSetDeliverResult` 之类的
/// 注入口，与本文件的"纯渲染"断言是两类事情。
void main() {
  Future<DshService> pump(WidgetTester tester, Widget child, {Size size = const Size(420, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dsh = DshService();
    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: MaterialApp(
          builder: (ctx, c) => ThemeScope(isDark: false, child: c ?? const SizedBox()),
          home: child,
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

  group('排队消息面板', () {
    testWidgets('没有排队消息时不渲染面板（不占空间）', (tester) async {
      final dsh = await pump(tester, const ChatView());
      // known: true = 服务端明确回了 queue 字段（空数组），这才代表"确实没有"。
      dsh.debugSetQueue(const [], known: true);
      await tester.pump();
      expect(find.textContaining('排队'), findsNothing);
      await teardown(tester);
    });

    testWidgets('读不到队列时说明"状态未知"，而不是静默当成空队列', (tester) async {
      final dsh = await pump(tester, const ChatView());
      // 生产上 GET /api/mobile/sessions/queue 曾被通配路由吞掉，响应里根本没有
      // queue 字段。那种情况必须与"确实没有排队消息"区分开 —— 否则修好路由之前
      // 和之后，界面一模一样。
      dsh.debugSetQueue(const [], known: false);
      await tester.pump();
      expect(find.text('队列状态未知'), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('有排队消息时列出条数与"本轮结束后自动发送"的含义', (tester) async {
      final dsh = await pump(tester, const ChatView());
      dsh.debugSetQueue([
        const QueueItem(id: 'm1', text: '先跑单元测试', attachments: 0),
        const QueueItem(id: 'm2', text: '', attachments: 2),
      ]);
      await tester.pump();

      expect(find.text('2 条排队中 · 本轮结束后自动发送'), findsOneWidget);
      expect(find.text('先跑单元测试'), findsOneWidget);
      expect(find.text('（2 个附件）'), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('错误信息显示在面板里，而不是静默空列表', (tester) async {
      final dsh = await pump(tester, const ChatView());
      dsh.debugSetQueue(const [], error: '读取排队消息失败: 网络不通');
      await tester.pump();
      expect(find.textContaining('读取排队消息失败'), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('队列很长时输入栏里只列 3 条，其余可**就地展开**（不再跳任务页）', (tester) async {
      final dsh = await pump(tester, const ChatView());
      dsh.debugSetQueue([
        for (var i = 1; i <= 5; i++) QueueItem(id: 'm$i', text: '排队第 $i 条', attachments: 0),
      ]);
      await tester.pump();

      expect(find.text('5 条排队中 · 本轮结束后自动发送'), findsOneWidget);
      expect(find.text('排队第 1 条'), findsOneWidget);
      expect(find.text('排队第 3 条'), findsOneWidget);
      expect(find.text('排队第 4 条'), findsNothing, reason: '第 4 条起不该出现在折叠态里');

      // 溢出提示必须是一个**动作**，而且不再指向任何二级页面。
      expect(find.textContaining('还有 2 条'), findsOneWidget);
      expect(find.textContaining('任务'), findsNothing, reason: '任务页已删除，不许留死链');

      await tester.tap(find.byKey(const ValueKey('queue-dock-toggle')));
      await tester.pump();
      expect(find.text('排队第 4 条'), findsOneWidget, reason: '就地展开后应能看到全部');
      expect(find.text('排队第 5 条'), findsOneWidget);
      expect(find.text('收起'), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('展开 20 条不会把输入卡片顶出屏幕（限高 + 内部滚动）', (tester) async {
      // 这一条是防"看起来做完、真机立刻溢出"的：输入卡片所在 Column 里，除了
      // 消息列表是 Expanded，输入卡片自身**高度无上限**。20 条 × 约 66px ≈ 1320px，
      // 不设限就必然 RenderFlex 溢出（黄黑条），而 420×900 的竖屏上输入框会被
      // 直接顶出可视区。
      final dsh = await pump(tester, const ChatView());
      dsh.debugSetQueue([
        for (var i = 1; i <= 20; i++) QueueItem(id: 'm$i', text: '排队第 $i 条', attachments: 0),
      ]);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('queue-dock-toggle')));
      await tester.pump();

      expect(tester.takeException(), isNull, reason: '展开不得触发布局溢出');
      final dockHeight = tester.getSize(find.byKey(const ValueKey('queue-dock'))).height;
      expect(dockHeight, lessThan(400), reason: '展开态必须限高（实测约 286px），不能随条数线性增长');

      // 输入卡片仍在屏幕内（没有被顶出去）。
      final inputBar = tester.getRect(find.byKey(const ValueKey('chat-input-bar')));
      expect(inputBar.bottom, lessThanOrEqualTo(900.0));
      expect(inputBar.top, greaterThan(0.0));
      await teardown(tester);
    });

    testWidgets('会话没在跑时给出"为什么不能插话"，而不是一个死按钮', (tester) async {
      final dsh = await pump(tester, const ChatView());
      dsh.debugSetQueue([const QueueItem(id: 'm1', text: '待发送', attachments: 0)]);
      dsh.debugSetRunning(false);
      await tester.pump();

      // 旧版是一个 onTap:null 的灰色 ⚡ —— 点了没反应，用户只能猜为什么。
      expect(find.text('仅本轮运行中可插话发送'), findsOneWidget);
      expect(find.text('立即插话'), findsNothing);
      expect(find.byKey(const ValueKey('queue-steer-m1')), findsNothing);
      await teardown(tester);
    });

    testWidgets('切换会话时回到折叠态（展开态是会话级界面状态）', (tester) async {
      final dsh = await pump(tester, const ChatView());
      dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-a', title: 'A'));
      dsh.debugSetQueue([
        for (var i = 1; i <= 5; i++) QueueItem(id: 'm$i', text: '排队第 $i 条', attachments: 0),
      ]);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('queue-dock-toggle')));
      await tester.pump();
      expect(find.text('排队第 5 条'), findsOneWidget);

      dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-b', title: 'B'));
      await tester.pump();
      expect(find.text('排队第 5 条'), findsNothing, reason: '换会话后不该继承上一个会话的展开态');
      await teardown(tester);
    });
  });
}
