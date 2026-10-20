import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/views/workspaces_view.dart';

/// 工作区页空列表的三种情况（[fix 2026-10-20]）。
///
/// 钉住的是**文案与状态的对应关系**，而不是"渲染出某个字符串"：
/// 用户没有任何搜索行为时，看到「没有找到匹配的工作区」会读成「我的工作区丢了」，
/// 这是这次修复的核心动机。
void main() {
  testWidgets('无数据且无搜索词 → 说「还没有工作区」，不说「没有找到匹配」', (tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dsh = DshService();
    dsh.debugSetWorkspaces(const <Workspace>[],
        archivedFilter: 'exclude', archivedFilterSupported: true);

    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: const MaterialApp(home: WorkspacesView(active: true)),
      ),
    );
    // 首帧 + 让 initState 里那次 fetchWorkspaces 的 setState 落地（离线时立即返回）。
    await tester.pump();
    await tester.pump();

    expect(find.text('还没有工作区'), findsOneWidget,
        reason: '没有搜索行为时不能说「没有找到匹配」');
    expect(find.text('没有找到匹配的工作区'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('有数据但搜索无命中 → 说「没有找到匹配的工作区」', (tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dsh = DshService();
    dsh.debugSetWorkspaces(
      [
        Workspace(
          workspaceId: 'ws-a',
          title: '工作区A',
          path: 'E:\\ws\\a',
          archivedCount: 0,
          sessions: const [],
        ),
      ],
      archivedFilter: 'exclude',
      archivedFilterSupported: true,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: const MaterialApp(home: WorkspacesView(active: true)),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 工作区卡片本身在，说明数据到了而不是加载态。
    expect(find.text('工作区A'), findsWidgets);

    await tester.enterText(find.byType(TextField).first, 'zzz-不存在的词');
    await tester.pump();

    expect(find.text('没有找到匹配的工作区'), findsOneWidget);
    expect(find.text('还没有工作区'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
