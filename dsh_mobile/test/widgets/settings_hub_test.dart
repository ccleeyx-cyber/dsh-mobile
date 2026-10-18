import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/custom_settings_view.dart';
import 'package:dsh_mobile/views/settings/about_view.dart';
import 'package:dsh_mobile/views/settings/connectivity_view.dart';
import 'package:dsh_mobile/views/settings/push_settings_view.dart';
import 'package:dsh_mobile/views/settings/snippets_view.dart';

/// 设置 hub 的**可达性**测试（v1.33）。
///
/// ## 为什么这组必须存在
///
/// 设置页从"一张全量铺开的表单"改成"入口 + 二级页"之后，每个二级页都变成了
/// **只能从这个入口到达**。少画一行入口，编译器不会报错、单元测试也全绿 ——
/// 而用户点遍整个设置页都找不到那个功能。仓库里已经有过同类教训（安全策略从
/// 一级 tab 降级时专门补了一条可达性测试），这里把四个入口一次钉住。
///
/// 顺带钉两件事：
///  * **首页不再内联大表单**（快捷指令列表、ntfy 输入框都在二级页里）——
///    否则"入口化"只是名义上的，卡片又会长回首页；
///  * **运维面板已移除**（v1.33 明确砍掉的功能，不允许悄悄长回来）。
void main() {
  Future<DshService> pumpHub(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dsh = DshService();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DshService>.value(value: dsh),
          ChangeNotifierProvider<ThemeController>.value(value: ThemeController()),
        ],
        child: MaterialApp(
          builder: (ctx, c) => ThemeScope(isDark: false, child: c ?? const SizedBox()),
          home: const CustomSettingsView(),
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

  Future<void> openAndBack(
    WidgetTester tester, {
    required Key entry,
    required Type page,
  }) async {
    await tester.scrollUntilVisible(find.byKey(entry), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pump();
    await tester.tap(find.byKey(entry));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(page), findsOneWidget, reason: '入口 $entry 必须能进入 $page');
    await tester.pageBack();
    await tester.pumpAndSettle();
  }

  testWidgets('四个二级页入口都在，且都能点进去', (tester) async {
    await pumpHub(tester);

    expect(find.byKey(const ValueKey('settings-open-connectivity')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-open-push')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-open-snippets')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-open-about')), findsOneWidget);
    // 安全策略是推入页里唯一仍然内联成卡片的入口（v1.22 起）。
    expect(find.text('安全策略与授权'), findsOneWidget);

    await openAndBack(tester, entry: const ValueKey('settings-open-connectivity'), page: ConnectivityView);
    await openAndBack(tester, entry: const ValueKey('settings-open-push'), page: PushSettingsView);
    await openAndBack(tester, entry: const ValueKey('settings-open-snippets'), page: SnippetsView);
    await openAndBack(tester, entry: const ValueKey('settings-open-about'), page: AboutView);

    await teardown(tester);
  });

  testWidgets('首页不再内联快捷指令列表与 ntfy 表单（入口化不是名义上的）', (tester) async {
    await pumpHub(tester);

    // 快捷指令的整块列表（含新增按钮）现在只在二级页里。
    expect(find.byKey(const ValueKey('settings-snippets-section')), findsNothing);
    expect(find.byKey(const ValueKey('snippet-add-local')), findsNothing);
    // ntfy 的三个输入框同理。
    expect(find.byKey(const ValueKey('push-url-field')), findsNothing);
    expect(find.byKey(const ValueKey('push-topic-field')), findsNothing);

    await teardown(tester);
  });

  testWidgets('运维面板已移除：设置页里不再有它的入口', (tester) async {
    await pumpHub(tester);

    expect(find.text('运维面板'), findsNothing);
    expect(find.byKey(const ValueKey('settings-open-host-ops')), findsNothing);

    await teardown(tester);
  });

  testWidgets('360dp 宽 + 1.3x 字号：hub 不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dsh = DshService();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DshService>.value(value: dsh),
          ChangeNotifierProvider<ThemeController>.value(value: ThemeController()),
        ],
        child: MaterialApp(
          builder: (ctx, c) {
            final content = ThemeScope(isDark: false, child: c ?? const SizedBox());
            return MediaQuery(
              data: MediaQuery.of(ctx).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: content,
            );
          },
          home: const CustomSettingsView(),
        ),
      ),
    );
    await tester.pump();

    // 懒构建：把最底下那张卡也滚进来，确保布局真的跑过一遍。
    await tester.scrollUntilVisible(find.byKey(const ValueKey('settings-open-about')), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pump();

    expect(tester.takeException(), isNull);

    await teardown(tester);
  });
}
