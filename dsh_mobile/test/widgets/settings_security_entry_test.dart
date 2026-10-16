import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/custom_settings_view.dart';
import 'package:dsh_mobile/views/security_permissions_view.dart';

/// 「安全策略」入口的回归测试（v1.22）。
///
/// 这一条是**可达性**测试，不是外观测试。安全策略原本是底部导航的一级 tab，
/// v1.22 把它降成了设置页里的推入页 —— 一旦那个入口没渲染出来（或者点了不跳），
/// 整个权限/审批预设页面就**没有任何入口能到达**，而编译器不会报错、其它测试
/// 也全绿。仓库里已经有过一次同类教训（"把 RPC 接对了，却没让用户摸到它"），
/// 所以这里钉住两件事：入口在，且点得进去。
void main() {
  Future<DshService> pumpSettings(WidgetTester tester) async {
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

  testWidgets('设置页有「安全策略与授权」入口', (tester) async {
    await pumpSettings(tester);

    expect(find.text('安全策略与授权'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-security-subtitle')), findsOneWidget);
    // 没有任何待处理项时给的是能力说明，不是"0 项等待处理"。
    expect(find.text('Agent 执行权限、审批规则与预设'), findsOneWidget);

    await teardown(tester);
  });

  testWidgets('点入口能进入安全策略页（否则整页没有任何入口）', (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.text('安全策略与授权'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SecurityPermissionsView), findsOneWidget);

    await teardown(tester);
  });
}
