import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/widgets/workspace_create_sheet.dart';

/// [feat 2026-10-22] 新建工作区改成**点选目录**。
///
/// 用户原话：「新建工作区目前是手写，这个要改成点选」。
///
/// 这个文件测的是**降级路径**（没有网关时）—— 那正是最容易出事的一条：接口不可
/// 用时不能给用户一个永远空着的目录列表，必须退回手写并说明原因。点选本身的
/// 数据来自网关，其边界在 `tests/unit/workspace-browse.test.mjs` 里钉住。
void main() {
  Future<DshService> pumpSheet(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
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
                  onPressed: () => showWorkspaceCreateSheet(context, dsh),
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

  testWidgets('网关不支持目录选择时自动落到手写，并说明原因', (tester) async {
    // DshService 没有配置 → 两个浏览接口直接返回 ok:false
    await pumpSheet(tester);

    expect(find.byKey(const ValueKey('workspace-create-manual-path')), findsOneWidget);
    expect(find.textContaining('可以直接填路径'), findsOneWidget);
    // 没有网关时不该假装能点选
    expect(find.byKey(const ValueKey('workspace-create-up')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('相对路径就地报错（不关弹层、不丢输入）', (tester) async {
    await pumpSheet(tester);

    await tester.enterText(
        find.byKey(const ValueKey('workspace-create-manual-path')), 'workspace/proj');
    await tester.tap(find.byKey(const ValueKey('workspace-create-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workspace-create-error')), findsOneWidget);
    expect(find.textContaining('绝对路径'), findsOneWidget);
    // 输入没有被清掉
    expect(find.text('workspace/proj'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('绝对路径提交失败时错误留在弹层里', (tester) async {
    await pumpSheet(tester);

    await tester.enterText(
        find.byKey(const ValueKey('workspace-create-manual-path')), r'E:\workspace\proj');
    await tester.tap(find.byKey(const ValueKey('workspace-create-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workspace-create-error')), findsOneWidget);
    // 弹层还在：路径已经选好，关掉等于让用户重来
    expect(find.byKey(const ValueKey('workspace-create-submit')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('名称随路径自动带出，用户改过就不再覆盖', (tester) async {
    await pumpSheet(tester);

    final pathField = find.byKey(const ValueKey('workspace-create-manual-path'));
    await tester.enterText(pathField, r'E:\workspace\my-project');
    await tester.pumpAndSettle();
    expect(find.text('my-project'), findsWidgets);

    // 用户手改成别的名字，再改路径也不该被冲掉
    await tester.enterText(find.byKey(const ValueKey('workspace-create-title')), '我的工程');
    await tester.enterText(pathField, r'E:\workspace\another-one');
    await tester.pumpAndSettle();
    expect(find.text('我的工程'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('360dp 下不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
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
                  onPressed: () => showWorkspaceCreateSheet(context, dsh),
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
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
