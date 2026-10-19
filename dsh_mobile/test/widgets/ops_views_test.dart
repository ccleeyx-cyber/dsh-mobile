import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/alerts_view.dart';
import 'package:dsh_mobile/views/custom_settings_view.dart';
import 'package:dsh_mobile/views/runbook_view.dart';

/// v1.35 / 3.2 + 3.4 —— 运维入口可达性与空态。
///
/// 入口化之后少画一行入口编译器不会报错，所以入口必须被测试钉住。
/// 空态单独钉：`还没有告警` 与 Runbook 的引导文案是用户第一次打开时唯一
/// 能看到的解释，写丢就成了白屏。
void main() {
  Future<DshService> pumpHub(WidgetTester tester, {double width = 420}) async {
    tester.view.physicalSize = Size(width, 1600);
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
    await tester.pump(const Duration(seconds: 5));
  }

  Widget wrap(Widget child) => MultiProvider(
        providers: [
          ChangeNotifierProvider<DshService>.value(value: DshService()),
          ChangeNotifierProvider<ThemeController>.value(value: ThemeController()),
        ],
        child: MaterialApp(
          builder: (ctx, c) => ThemeScope(isDark: false, child: c ?? const SizedBox()),
          home: child,
        ),
      );

  testWidgets('设置页有 Runbook 与告警入口，且能点进去', (tester) async {
    await pumpHub(tester);

    final runbookEntry = find.byKey(const ValueKey('settings-open-runbook'));
    final alertsEntry = find.byKey(const ValueKey('settings-open-alerts'));
    expect(runbookEntry, findsOneWidget);
    expect(alertsEntry, findsOneWidget);

    await tester.scrollUntilVisible(runbookEntry, 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(runbookEntry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(RunbookView), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(alertsEntry, 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(alertsEntry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertsView), findsOneWidget);

    await teardown(tester);
  });

  testWidgets('告警空态：不显示 0，给出一句解释', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(wrap(const AlertsView()));
    await tester.pump();

    expect(find.text('还没有告警'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    // DshService 没有配置 → refreshAlerts 直接返回，不应崩溃
    expect(tester.takeException(), isNull);

    await teardown(tester);
  });

  testWidgets('Runbook 空态给出"去电脑上编辑"的指引', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(wrap(const RunbookView()));
    await tester.pump();

    expect(find.textContaining('runbooks.yaml'), findsWidgets);
    expect(tester.takeException(), isNull);

    await teardown(tester);
  });

  testWidgets('360dp 下两个页面都不溢出', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const RunbookView()));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(wrap(const AlertsView()));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await teardown(tester);
  });
}
