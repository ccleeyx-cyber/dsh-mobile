import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/widgets/workspace_create_sheet.dart';

/// [feat 2026-10-22] 新建工作区 = **点选目录**。
///
/// 这里用一个替身数据源（[WorkspaceRootsLoader]）驱动真实的弹层，钉住用户实际
/// 会做的动作：起点 → 下钻 → 上一级 → 用当前目录建。
///
/// 数据边界（只回子目录、拒绝越界路径）在网关侧：
/// `tests/unit/workspace-browse.test.mjs`。
void main() {
  const rootLabel = '上级 · workspace';

  /// 一棵假目录树：
  ///   E:\workspace            （起点）
  ///     ├─ 个人
  ///     │    └─ work
  ///     └─ dsh_mobile          （已登记工作区）
  WorkspaceDirListing fakeTree(String? path) {
    const roots = [
      WorkspaceRoot(path: r'E:\workspace', label: rootLabel, kind: 'parent'),
      WorkspaceRoot(path: r'C:\Users\me', label: '主目录', kind: 'home'),
    ];
    if (path == null) {
      return const WorkspaceDirListing(ok: true, roots: roots, path: 'E:\\workspace');
    }
    switch (path) {
      case r'E:\workspace':
        return const WorkspaceDirListing(
          ok: true,
          roots: roots,
          path: r'E:\workspace',
          name: 'workspace',
          entries: [
            WorkspaceDirEntry(name: '个人', path: r'E:\workspace\个人'),
            WorkspaceDirEntry(name: 'dsh_mobile', path: r'E:\workspace\dsh_mobile'),
          ],
        );
      case r'E:\workspace\个人':
        return const WorkspaceDirListing(
          ok: true,
          roots: roots,
          path: r'E:\workspace\个人',
          parent: r'E:\workspace',
          name: '个人',
          entries: [WorkspaceDirEntry(name: 'work', path: r'E:\workspace\个人\work')],
        );
      case r'E:\workspace\个人\work':
        return const WorkspaceDirListing(
          ok: true,
          roots: roots,
          path: r'E:\workspace\个人\work',
          parent: r'E:\workspace\个人',
          name: 'work',
        );
      case r'E:\workspace\dsh_mobile':
        return const WorkspaceDirListing(
          ok: true,
          roots: roots,
          path: r'E:\workspace\dsh_mobile',
          parent: r'E:\workspace',
          name: 'dsh_mobile',
          registeredWorkspaceId: 'ws-1',
          registeredTitle: 'dsh mobile',
        );
      case r'C:\Users\me':
        return const WorkspaceDirListing(
          ok: true,
          roots: roots,
          path: r'C:\Users\me',
          name: 'me',
          entries: [WorkspaceDirEntry(name: 'proj', path: r'C:\Users\me\proj')],
        );
      default:
        return WorkspaceDirListing(ok: false, path: path, error: '目录不存在');
    }
  }

  /// 注入用的异步包装（真实数据源也是异步的）。
  Future<WorkspaceDirListing> fake(String? path) async => fakeTree(path);

  Future<DshService> pumpPicker(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final dsh = DshService();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DshService>.value(value: dsh),
          ChangeNotifierProvider<ThemeController>.value(value: ThemeController()),
        ],
        child: MaterialApp(
          builder: (ctx, child) => ThemeScope(isDark: false, child: child ?? const SizedBox()),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showWorkspaceCreateSheet(context, dsh, browse: fake),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return dsh;
  }

  testWidgets('打开就给起点 + 第一层目录', (tester) async {
    await pumpPicker(tester);

    // 起点胶囊（主目录 / 上级）
    expect(find.text(rootLabel), findsWidgets);
    expect(find.text('主目录'), findsWidgets);
    // 自动进了第一个起点并列出子目录
    expect(find.byKey(const ValueKey('workspace-create-dir-个人')), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-create-dir-dsh_mobile')), findsOneWidget);
    // 当前目录显示在等宽的路径条里
    expect(find.text(r'E:\workspace'), findsWidgets);
    // 按钮直接说明会建在哪
    expect(find.textContaining('用「workspace」创建工作区'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点目录下钻，上一级能回去', (tester) async {
    await pumpPicker(tester);

    await tester.tap(find.byKey(const ValueKey('workspace-create-dir-个人')));
    await tester.pumpAndSettle();
    expect(find.textContaining('用「个人」创建工作区'), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-create-dir-work')), findsOneWidget);

    // 再下一层，然后点"上一级"退回
    await tester.tap(find.byKey(const ValueKey('workspace-create-dir-work')));
    await tester.pumpAndSettle();
    expect(find.textContaining('用「work」创建工作区'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('workspace-create-up')));
    await tester.pumpAndSettle();
    expect(find.textContaining('用「个人」创建工作区'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点起点胶囊换到另一个位置', (tester) async {
    await pumpPicker(tester);

    await tester.tap(find.byKey(const ValueKey('workspace-create-root-home-1')));
    await tester.pumpAndSettle();
    // 换起点之后路径条与列表都跟着换
    expect(find.text(r'C:\Users\me'), findsWidgets);
    expect(find.byKey(const ValueKey('workspace-create-dir-proj')), findsOneWidget);
    expect(find.textContaining('用「me」创建工作区'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('已登记的目录会提示，不会让人以为要再建一个', (tester) async {
    await pumpPicker(tester);

    await tester.tap(find.byKey(const ValueKey('workspace-create-dir-dsh_mobile')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已经是工作区'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('名称随所选的目录自动带出', (tester) async {
    await pumpPicker(tester);

    // 起点 workspace → 下钻到 个人
    await tester.tap(find.byKey(const ValueKey('workspace-create-dir-个人')));
    await tester.pumpAndSettle();
    final titleField = tester.widget<TextField>(
      find.byKey(const ValueKey('workspace-create-title')),
    );
    expect(titleField.controller?.text, '个人');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('切到手写输入后，按钮改成通用文案', (tester) async {
    await pumpPicker(tester);

    await tester.tap(find.byKey(const ValueKey('workspace-create-manual-toggle')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workspace-create-manual-path')), findsOneWidget);
    expect(find.text('创建工作区'), findsOneWidget);
    // 手写时当前目录已经带过去，不用从零打
    expect(find.text(r'E:\workspace'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
