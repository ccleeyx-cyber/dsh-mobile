import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/views/workspaces_view.dart';

/// 工作区页的布局回归锁（v1.14.4）。
///
/// 两条来自用户的原话：
///   「工作区那里的布局还是不太好看，有点割裂」
///   「那个活跃和当前活跃，是不是没有必要有这个东西？」
///
/// 这些断言的作用是**防止又把它们加回来** —— 它们删除前没有任何测试覆盖，
/// 这正是装饰性元素能长期留下来的原因。
void main() {
  SessionMeta session(String id, String title, {bool isRunning = false}) => SessionMeta(
        sessionId: id,
        title: title,
        isRunning: isRunning,
        lastPromptAt: 1700000000000,
      );

  Workspace ws({String id = 'ws-a', String title = '工作区A', List<SessionMeta>? sessions, int archivedCount = 0}) =>
      Workspace(
        workspaceId: id,
        title: title,
        path: 'E:\\ws\\$id',
        archivedCount: archivedCount,
        sessions: sessions ?? [],
      );

  Future<DshService> pumpView(WidgetTester tester, List<Workspace> workspaces, {String mode = 'exclude'}) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dsh = DshService();
    dsh.debugSetWorkspaces(workspaces, archivedFilter: mode, archivedFilterSupported: true);
    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: const MaterialApp(home: WorkspacesView(active: true)),
      ),
    );
    await tester.pump();
    return dsh;
  }

  group('「活跃 / 当前活跃」已删除（用户判定为没必要）', () {
    testWidgets('不再出现「当前活跃」徽标', (tester) async {
      await pumpView(tester, [ws(sessions: [session('s1', '会话一')])]);
      expect(find.text('当前活跃'), findsNothing);
    });

    testWidgets('不再出现「设为活跃」按钮（展开卡片本身不再承担切换语义）', (tester) async {
      final dsh = await pumpView(tester, [
        ws(id: 'ws-a', sessions: [session('s1', '会话一')]),
        ws(id: 'ws-b', title: '工作区B', sessions: [session('s2', '会话二')]),
      ]);
      // 展开全部卡片，让操作栏都渲染出来
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byType(ExpansionTile).at(i), warnIfMissed: false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      }
      expect(find.text('设为活跃'), findsNothing);
      expect(dsh.currentWorkspace, isNull, reason: '展开不等于选中：不该有任何工作区被设为当前');
    });

    testWidgets('展开别的卡片不会改变当前工作区（展开 ≠ 切换）', (tester) async {
      final dsh = await pumpView(tester, [
        ws(id: 'ws-a', sessions: [session('s1', '会话一')]),
        ws(id: 'ws-b', title: '工作区B', sessions: [session('s2', '会话二')]),
      ]);
      // 先把「甲」设为当前工作区
      dsh.selectWorkspace(dsh.workspaces.first, autoSelectSession: false);
      await tester.pump();
      expect(dsh.currentWorkspace?.workspaceId, 'ws-a');

      // 再展开「乙」
      await tester.tap(find.byType(ExpansionTile).at(1), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // 这条会在"展开即切换工作区"那种实现下立刻变红 —— 那正是我一开始写错、
      // 又撤掉的做法：`selectWorkspace(autoSelectSession: false)` 的 else 分支
      // 会把正在看的会话与消息一起清空。
      expect(dsh.currentWorkspace?.workspaceId, 'ws-a',
          reason: '随手展开一个工作区不得把它变成当前工作区');
    });
  });

  group('页头不再堆四条平行横带', () {
    testWidgets('没有任务在跑、没有待审批时，顶部不渲染任何计数条', (tester) async {
      await pumpView(tester, [ws(sessions: [session('s1', '会话一')])]);
      expect(find.textContaining('个挂载项目'), findsNothing);
      expect(find.textContaining('个历史会话'), findsNothing);
      expect(find.textContaining('个任务执行中'), findsNothing);
      expect(find.textContaining('项待审批'), findsNothing);
    });

    testWidgets('有任务在跑时顶部也不渲染"执行中"条（用户已点名删除）', (tester) async {
      await pumpView(tester, [
        ws(sessions: [session('s1', '跑着的会话', isRunning: true)]),
      ]);
      // [fix 2026-10-17 用户反馈] 「N 个任务执行中」pill 已删除：哪个会话在跑，
      // 会话行上的「执行中」标记已经说了。顶部只保留"待审批"这一种行动信号。
      expect(find.textContaining('个任务执行中'), findsNothing);
      // 会话总数那枚也不回来 —— 它与每张卡片里的「共 N 个历史对话」重复。
      expect(find.textContaining('个历史会话'), findsNothing);
    });

    testWidgets('归档筛选仍然完整可见（它是有行动的控件，不是装饰）', (tester) async {
      await pumpView(tester, [ws(sessions: [session('s1', '会话一')])]);
      expect(find.text('未归档'), findsOneWidget);
      expect(find.text('已归档'), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);
    });
  });

  group('卡片本身仍然正确标记"当前"（靠外观，不靠徽标）', () {
    testWidgets('当前工作区的标题用强调色，其他工作区用主文字色', (tester) async {
      final dsh = await pumpView(tester, [
        ws(id: 'ws-a', title: '甲', sessions: [session('s1', '会话一')]),
        ws(id: 'ws-b', title: '乙', sessions: [session('s2', '会话二')]),
      ]);
      dsh.selectWorkspace(dsh.workspaces.first, autoSelectSession: false);
      await tester.pump();

      final current = tester.widget<Text>(find.text('甲'));
      final other = tester.widget<Text>(find.text('乙'));
      expect(current.style?.color, isNotNull);
      expect(other.style?.color, isNotNull);
      expect(current.style?.color, isNot(equals(other.style?.color)),
          reason: '当前工作区必须与其它工作区在文字颜色上可区分');
      expect(current.style?.fontWeight, FontWeight.w600);
    });
  });
}
