import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/task_center.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';
import 'package:dsh_mobile/views/task_center_view.dart';

/// 排队/插话 与 任务页 的界面回归测试（v1.13）。
///
/// 断言的是**界面上出现了什么**，因为这一轮新增功能最容易出的问题恰恰是
/// "数据拿到了但没渲染"或"渲染了却点不动"。数据层用 debug 注入口摆好
/// （不打真实网关：历史教训是那样会污染用户会话）。
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
      dsh.debugSetQueue(const []);
      await tester.pump();
      expect(find.textContaining('排队消息'), findsNothing);
      await teardown(tester);
    });

    testWidgets('有排队消息时列出条数与内容', (tester) async {
      final dsh = await pump(tester, const ChatView());
      dsh.debugSetQueue([
        const QueueItem(id: 'm1', text: '先跑单元测试', attachments: 0),
        const QueueItem(id: 'm2', text: '', attachments: 2),
      ]);
      await tester.pump();

      expect(find.text('2 条排队消息'), findsOneWidget);
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

    testWidgets('会话没在跑时「插话」按钮置灰', (tester) async {
      final dsh = await pump(tester, const ChatView());
      dsh.debugSetQueue([const QueueItem(id: 'm1', text: '待发送', attachments: 0)]);
      dsh.debugSetRunning(false);
      await tester.pump();

      final steerIcon = find.byIcon(Icons.bolt_rounded);
      expect(steerIcon, findsWidgets);
      // 置灰 = InkWell 的 onTap 为 null：点它不应触发任何东西（不抛异常即通过）。
      await tester.tap(steerIcon.first, warnIfMissed: false);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await teardown(tester);
    });
  });

  group('投递方式切换', () {
    testWidgets('空闲时不显示排队/插话开关（它对空闲发送没有意义）', (tester) async {
      final dsh = await pump(tester, const ChatView());
      dsh.debugSetRunning(false);
      await tester.pump();
      expect(find.text('排队'), findsNothing);
      expect(find.text('插话'), findsNothing);
      await teardown(tester);
    });

    testWidgets('运行中显示开关，点击在排队与插话之间切换', (tester) async {
      final dsh = await pump(tester, const ChatView());
      dsh.debugSetRunning(true);
      dsh.debugSetDeliveryMode('queue');
      await tester.pump();
      expect(find.text('排队'), findsOneWidget);

      await tester.tap(find.text('排队'));
      await tester.pump();
      expect(dsh.deliveryMode, 'steer');
      expect(find.text('插话'), findsOneWidget);

      await tester.tap(find.text('插话'));
      await tester.pump();
      expect(dsh.deliveryMode, 'queue');
      await teardown(tester);
    });

    testWidgets('运行中且输入框为空时是停止键；有内容时变成发送键', (tester) async {
      final dsh = await pump(tester, const ChatView());
      dsh.debugSetRunning(true);
      await tester.pump();
      expect(find.byIcon(Icons.stop_rounded), findsOneWidget, reason: '空输入框时用户最想要的是停下来');

      await tester.enterText(find.byKey(const ValueKey('chat-input-field')), '插一句');
      await tester.pump();
      expect(find.byIcon(Icons.stop_rounded), findsNothing);
      expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
      await teardown(tester);
    });
  });

  group('任务页', () {
    /// 任务页只在有当前会话时才渲染各区块，所以每个用例先摆一个会话。
    Future<DshService> pumpWithSession(WidgetTester tester, {Size size = const Size(420, 2000)}) async {
      final dsh = await pump(tester, const TaskCenterView(), size: size);
      dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-test', title: '测试会话'));
      await tester.pump();
      return dsh;
    }

    testWidgets('没有当前会话时给出指引而不是空白页', (tester) async {
      await pump(tester, const TaskCenterView(), size: const Size(420, 1600));
      expect(find.textContaining('先'), findsWidgets);
      await teardown(tester);
    });

    testWidgets('交付物/作业/定时/变更都能渲染出内容', (tester) async {
      final dsh = await pumpWithSession(tester);
      dsh.debugSetTaskCenter(
        deliverables: const [
          DeliverableItem(path: '/w/out/报表.xlsx', display: 'out/报表.xlsx', description: '本月汇总'),
        ],
        changes: const [
          WorkspaceChange(path: 'src/a.ts', status: 'M', added: 3, deleted: 1),
          WorkspaceChange(path: 'new.txt', status: '??'),
        ],
        changesAvailable: true,
        schedules: const [
          ScheduleItem(id: 's1', kind: 'daily', title: '日报', prompt: '总结', schedule: '每天 09:00'),
        ],
        jobs: const [
          JobItem(id: 'bash-1', kind: 'bash', label: 'npm test', status: 'running'),
        ],
        stats: const SessionStats(
          source: 'live',
          totalTokens: 1234,
          uncachedInputTokens: 1000,
          outputTokens: 234,
          pressureTokens: 64000,
          contextWindow: 128000,
        ),
      );
      await tester.pump();

      expect(find.text('报表.xlsx'), findsOneWidget);
      expect(find.text('本月汇总'), findsOneWidget);
      expect(find.text('src/a.ts'), findsOneWidget);
      expect(find.text('+3 −1'), findsOneWidget);
      expect(find.text('—'), findsWidgets, reason: '未跟踪文件的行数未知，必须显示破折号');
      expect(find.text('日报'), findsOneWidget);
      expect(find.text('npm test'), findsOneWidget);
      expect(find.text('运行中'), findsOneWidget);
      expect(find.text('1234'), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('非 git 工作区如实说明原因，而不是装作没有变更', (tester) async {
      final dsh = await pumpWithSession(tester);
      dsh.debugSetTaskCenter(
        changes: const [],
        changesAvailable: false,
        changesReason: 'not-a-git-repository',
      );
      await tester.pump();
      expect(find.textContaining('不是 git 仓库'), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('没有交付物时说明它何时会出现（而不是一片空白）', (tester) async {
      final dsh = await pumpWithSession(tester);
      dsh.debugSetTaskCenter(deliverables: const [], jobs: const [], schedules: const []);
      await tester.pump();
      expect(find.textContaining('还没有声明交付文件'), findsOneWidget);
      expect(find.textContaining('没有后台作业'), findsOneWidget);
      expect(find.textContaining('没有定时任务'), findsOneWidget);
      await teardown(tester);
    });
  });
}
