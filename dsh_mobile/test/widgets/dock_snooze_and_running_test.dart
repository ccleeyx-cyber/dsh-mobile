import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/approval_request.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';
import 'package:dsh_mobile/widgets/approval_card.dart';

/// Phase 5.2（多会话并行指示）+ Phase 5.5（审批「稍后」）的回归测试。
///
/// 这两条都靠"界面上看得见"成立，所以断言必须落在**渲染结果**上：
///
/// 1. 多会话指示：只在"确实知道有别的会话在跑"时出现。工作区列表没拉过
///    （`workspaces` 为空）时必须整段消失 —— 显示 0 等于编了一个
///    "没有别的东西在跑"的结论，而真相是"不知道"。这条正是本仓库反复
///    踩过的坑（旧任务页角标把"没拉过"显示成 0）。
///
/// 2. 审批「稍后」：收起后必须留一行痕迹（"N 项审批已延后"），否则审批
///    凭空消失，用户会以为它被处理了；到点必须自己长回来；并且**绝不能**
///    调网关 reject —— 稍后是界面层决定，不是一次答复。
void main() {
  Future<DshService> pumpChat(
    WidgetTester tester, {
    Size size = const Size(400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dsh = DshService();
    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: MaterialApp(
          builder: (ctx, child) => ThemeScope(
            isDark: false,
            child: MediaQuery(
              data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.noScaling),
              child: child ?? const SizedBox(),
            ),
          ),
          home: const ChatView(),
        ),
      ),
    );
    await tester.pump();
    return dsh;
  }

  /// 收掉语音初始化看门狗（12s），否则每个用例都会因 "Timer is still pending"
  /// 失败 —— 那是与本文件无关的噪声。必须在用例体内调用（不变式检查先于 tearDown）。
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 21));
  }

  ApprovalRequest approval(String sessionId, {String id = 'a1'}) =>
      ApprovalRequest.fromJson({
        'id': id,
        'eventId': 'evt-$id',
        'sessionId': sessionId,
        'toolName': 'shell',
        'command': 'ls -la',
        'createdAt': 1,
      });

  SessionMeta session(String id, {String title = '会话', bool running = false}) =>
      SessionMeta(sessionId: id, title: title, isRunning: running);

  Workspace workspace(List<SessionMeta> sessions, {String title = '工作区'}) =>
      Workspace(
        workspaceId: 'ws-1',
        title: title,
        path: '/tmp/ws',
        createdAt: '',
        updatedAt: '',
        sessionCount: sessions.length,
        pendingApprovals: 0,
        hasRunning: sessions.any((s) => s.isRunning),
        sessions: sessions,
      );

  group('Phase 5.5 审批「稍后」', () {
    testWidgets('点稍后 → 卡片收起、留一行痕迹、可提前处理', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-abc', title: 't'));
      dsh.debugSetPendingApprovals([approval('session-abc')]);
      await tester.pumpAndSettle();

      expect(find.byType(ApprovalCard), findsOneWidget);
      expect(find.byKey(const ValueKey('approval-snooze')), findsOneWidget,
          reason: '有 onSnooze 时才渲染；dock 必须把它接上');

      await tester.tap(find.byKey(const ValueKey('approval-snooze')));
      await tester.pumpAndSettle();

      // 卡片收起，但**不能凭空消失**。
      expect(find.byType(ApprovalCard), findsNothing);
      expect(find.text('1 项审批已延后'), findsOneWidget,
          reason: '不留痕迹的话用户会以为审批被处理掉了');

      // 关键：稍后不能是一次答复 —— 网关侧这条审批必须还在 pending。
      expect(dsh.pendingApprovals.length, 1,
          reason: '「稍后」是本地收起，绝不能把审批从 pending 里去掉');

      // 提前处理：立刻长回来。
      await tester.tap(find.byKey(const ValueKey('approval-unsnooze-all')));
      await tester.pumpAndSettle();
      expect(find.byType(ApprovalCard), findsOneWidget);
      expect(find.textContaining('项审批已延后'), findsNothing);

      await settle(tester);
    });

    testWidgets('15 分钟后自动长回来（定时器真的会恢复渲染）', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-abc', title: 't'));
      dsh.debugSetPendingApprovals([approval('session-abc')]);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('approval-snooze')));
      await tester.pumpAndSettle();
      expect(find.byType(ApprovalCard), findsNothing);

      // 差一秒还在延后态。
      await tester.pump(const Duration(minutes: 15) - const Duration(seconds: 1));
      expect(find.byType(ApprovalCard), findsNothing);

      // 到点自己长回来。
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byType(ApprovalCard), findsOneWidget,
          reason: '延后到点必须恢复渲染，否则审批就永远看不到了');

      await settle(tester);
    });

    testWidgets('审批在别处被处理掉 → 延后记录与定时器一起清掉', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-abc', title: 't'));
      dsh.debugSetPendingApprovals([approval('session-abc')]);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('approval-snooze')));
      await tester.pumpAndSettle();

      // 另一个设备把它批准了：本地 pending 列表清空。
      dsh.debugSetPendingApprovals([]);
      await tester.pumpAndSettle();

      expect(find.textContaining('项审批已延后'), findsNothing,
          reason: '审批都没了，延后痕迹也必须消失');

      // 再等过延后点：不能抛（没有 setState-after-dispose / 无残留定时器）。
      await tester.pump(const Duration(minutes: 16));
      await tester.pumpAndSettle();
      expect(find.byType(ApprovalCard), findsNothing);

      await settle(tester);
    });
  });

  group('Phase 5.2 多会话并行指示', () {
    testWidgets('别处有会话在跑 → 状态条出现「另外 N 个会话执行中」', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetCurrentSession(session('session-abc'));
      dsh.debugSetWorkspaces([
        workspace([
          session('session-abc'),
          session('session-def', title: '另一个', running: true),
          session('session-ghi', title: '第三个', running: true),
        ]),
      ]);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('strip-other-running')), findsOneWidget);
      // [v1.28] 文案从「另外 N 个会话执行中」压到「N 个在跑」：真机上原来那 14 个字
      // 把「缓存命中 99%」顶出屏幕、右侧被硬裁成一个「缓」字。语义不变，只是更短。
      expect(find.textContaining('2 个在跑'), findsOneWidget);

      await settle(tester);
    });

    testWidgets('当前会话自己不算「另外」', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetCurrentSession(session('session-abc', running: true));
      dsh.debugSetWorkspaces([
        workspace([session('session-abc', running: true)]),
      ]);
      // 当前会话在跑 → 顶栏有「执行中」的 CircularProgressIndicator（永久动画），
      // 所以这里只能 pump，不能用 pumpAndSettle。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const ValueKey('strip-other-running')), findsNothing,
          reason: '当前会话在跑由「执行中」徽标负责，两处都报等于说两遍');

      await settle(tester);
    });

    testWidgets('工作区列表没拉过 → 整段隐藏，绝不显示 0', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetCurrentSession(session('session-abc'));
      // 不调 debugSetWorkspaces：模拟"刚进 App，还没拉到工作区列表"。
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('strip-other-running')), findsNothing);
      expect(find.textContaining('另外'), findsNothing,
          reason: '未知必须隐藏 —— 显示「另外 0 个」是把"不知道"说成"没有"');

      await settle(tester);
    });

    testWidgets('点一下弹出会话选择，选中后按 id 打开（不是按标题）', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetCurrentSession(session('session-abc'));
      dsh.debugSetWorkspaces([
        workspace([
          session('session-abc'),
          session('session-def', title: '另一个', running: true),
        ], title: '主工作区'),
      ]);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('strip-other-running')));
      // 不能用 pumpAndSettle：弹层里每一行都有一个 `CircularProgressIndicator`
      // 表示"正在跑"，那是**永久重复动画**，pumpAndSettle 会一直等到超时。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('1 个会话正在执行'), findsOneWidget);
      // 列表里要能看出是哪个工作区的会话（不同工作区可以有同名会话）。
      expect(find.text('主工作区'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('other-running-session-def')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(dsh.currentSession?.sessionId, 'session-def');

      await settle(tester);
    });
  });
}
