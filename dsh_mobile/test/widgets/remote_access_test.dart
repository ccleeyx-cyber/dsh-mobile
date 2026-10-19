import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/custom_settings_view.dart';
import 'package:dsh_mobile/views/settings/remote_access_view.dart';

/// v1.35 / 1.6 —— 「远程访问」可达性与表单硬约束。
///
/// 钉三件事：
///  1. 入口必须能从设置页点到（入口化之后，少画一行入口编译器不会报错）；
///  2. 远程地址**必须是 https**：明文远程会让 token 暴露在公网，这不是提示而是拒绝；
///  3. 360dp 小屏不溢出（这一页有长指纹、长地址、按钮行）。
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
    await tester.pump(const Duration(seconds: 21));
  }

  testWidgets('设置页能进入「远程访问」', (tester) async {
    await pumpHub(tester);

    final entry = find.byKey(const ValueKey('settings-open-remote'));
    expect(entry, findsOneWidget);

    await tester.scrollUntilVisible(entry, 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(RemoteAccessView), findsOneWidget);

    await teardown(tester);
  });

  testWidgets('远程地址拒绝明文 http', (tester) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DshService>.value(value: DshService()),
          ChangeNotifierProvider<ThemeController>.value(value: ThemeController()),
        ],
        child: MaterialApp(
          builder: (ctx, c) => ThemeScope(isDark: false, child: c ?? const SizedBox()),
          home: const RemoteAccessView(),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey('remote-url-field')),
      'http://insecure.example.com',
    );
    await tester.tap(find.byKey(const ValueKey('remote-save-button')));
    await tester.pump();

    expect(find.textContaining('必须使用 https'), findsOneWidget);

    await teardown(tester);
  });

  testWidgets('空地址给出必填提示', (tester) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DshService>.value(value: DshService()),
          ChangeNotifierProvider<ThemeController>.value(value: ThemeController()),
        ],
        child: MaterialApp(
          builder: (ctx, c) => ThemeScope(isDark: false, child: c ?? const SizedBox()),
          home: const RemoteAccessView(),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('remote-save-button')));
    await tester.pump();

    expect(find.text('请填写远程地址'), findsOneWidget);

    await teardown(tester);
  });

  testWidgets('360dp 窄屏不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DshService>.value(value: DshService()),
          ChangeNotifierProvider<ThemeController>.value(value: ThemeController()),
        ],
        child: MaterialApp(
          builder: (ctx, c) => ThemeScope(isDark: false, child: c ?? const SizedBox()),
          home: const RemoteAccessView(),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);

    await teardown(tester);
  });
}
