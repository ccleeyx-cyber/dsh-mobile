import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/models/server_config.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/services/storage_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/config_page.dart';

/// [feat 2026-10-22] 连接页的**别名**输入框。
///
/// 用户原话：「app 连接那里，需要加一个别名，像我现在需要连接多个 dsh 客户端，
/// 域名相同的话就没办法区分了」。这里钉住界面上的三件事：
///   1. 表单里有别名输入框，且会带出已保存的别名；
///   2. 同域名下"另存为新网关"用的是表单里的别名（不再弹一次窗问名字）；
///   3. 不给别名时自动生成可区分的名字，不会留下两行一模一样的下拉项。
///
/// 存储层的规则在 `test/services/profile_alias_test.dart`。
///
/// ⚠️ 这里**不用 `pumpAndSettle()`**：页面上有 `TextFormField` 的光标闪烁定时器，
/// 一旦有输入框拿到焦点，`pumpAndSettle` 会一直等"没有新帧"而超时（默认 10 分钟）。
/// 全部改成有界的 `pump`。
void main() {
  // 有界推帧：既推进异步（SharedPreferences / SecureStore 降级路径），又不会卡住。
  Future<void> settle(WidgetTester tester, [int frames = 6]) async {
    for (var i = 0; i < frames; i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpConfigPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DshService>.value(value: DshService()),
          ChangeNotifierProvider<ThemeController>.value(value: ThemeController()),
        ],
        child: MaterialApp(
          builder: (ctx, child) => ThemeScope(isDark: false, child: child ?? const SizedBox()),
          home: const ConfigPage(),
        ),
      ),
    );
    await settle(tester, 12);
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  }

  ServerConfig existingProfile() => ServerConfig(
        name: '公司笔记本',
        host: 'dsh.example.com',
        port: 3088,
        token: 'tok',
      );

  testWidgets('已保存的网关会把别名带进表单', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // ⚠️ testWidgets 的假异步里，真正的平台通道写入永远不会完成（实测挂死），
    // 所以持久化调用必须包在 runAsync 里。
    await tester.runAsync(() => StorageService.upsertProfile(existingProfile()));

    await pumpConfigPage(tester);

    final field = find.byKey(const ValueKey('config-alias'));
    expect(field, findsOneWidget);
    expect(tester.widget<TextFormField>(field).controller?.text, '公司笔记本');
    // 下拉框里也用别名，而不是域名
    expect(find.text('公司笔记本'), findsWidgets);

    await teardown(tester);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('同域名再存一台：用表单里的别名，不再弹窗问名字', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // ⚠️ testWidgets 的假异步里，真正的平台通道写入永远不会完成（实测挂死），
    // 所以持久化调用必须包在 runAsync 里。
    await tester.runAsync(() => StorageService.upsertProfile(existingProfile()));

    await pumpConfigPage(tester);

    await tester.enterText(find.byKey(const ValueKey('config-alias')), '家里台式机');
    await settle(tester, 2);

    final saveAsNew = find.text('把当前填写内容另存为新网关');
    await tester.scrollUntilVisible(saveAsNew, 240,
        scrollable: find.byType(Scrollable).first);
    await settle(tester, 2);
    await tester.tap(saveAsNew);
    await settle(tester, 8);

    final profiles = (await tester.runAsync(() => StorageService.loadProfiles()))!;
    expect(profiles.length, 2);
    expect(profiles.map((p) => p.displayName).toSet(), {'公司笔记本', '家里台式机'});
    // 域名相同、别名不同 —— 这正是用户说的场景
    expect(profiles.every((p) => p.cleanHost == 'dsh.example.com'), isTrue);

    await teardown(tester);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('别名留空时另存：自动用「主机:端口」而不是空名字', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // ⚠️ testWidgets 的假异步里，真正的平台通道写入永远不会完成（实测挂死），
    // 所以持久化调用必须包在 runAsync 里。
    await tester.runAsync(() => StorageService.upsertProfile(existingProfile()));

    await pumpConfigPage(tester);

    await tester.enterText(find.byKey(const ValueKey('config-alias')), '');
    await settle(tester, 2);

    final saveAsNew = find.text('把当前填写内容另存为新网关');
    await tester.scrollUntilVisible(saveAsNew, 240,
        scrollable: find.byType(Scrollable).first);
    await settle(tester, 2);
    await tester.tap(saveAsNew);
    await settle(tester, 8);

    final profiles = (await tester.runAsync(() => StorageService.loadProfiles()))!;
    expect(profiles.length, 2);
    final created = profiles.where((p) => p.name != '公司笔记本').toList();
    expect(created, isNotEmpty);
    expect(created.first.name.trim(), isNotEmpty);
    expect(created.first.name, contains('dsh.example.com'));
    // 两条仍然可区分
    expect(profiles.map((p) => p.displayName).toSet().length, 2);

    await teardown(tester);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('360dp 下带别名的两行下拉项不溢出', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.runAsync(() => StorageService.upsertProfile(existingProfile()));
    await tester.runAsync(() => StorageService.upsertProfile(ServerConfig(
          name: '家里台式机',
          host: 'dsh.example.com',
          port: 3099,
          token: 'tok',
        )));

    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DshService>.value(value: DshService()),
          ChangeNotifierProvider<ThemeController>.value(value: ThemeController()),
        ],
        child: MaterialApp(
          builder: (ctx, child) => ThemeScope(isDark: false, child: child ?? const SizedBox()),
          home: const ConfigPage(),
        ),
      ),
    );
    await settle(tester, 12);
    expect(tester.takeException(), isNull);

    // 展开下拉，确认两行项也放得下
    await tester.tap(find.byType(DropdownButton<String>));
    await settle(tester, 6);
    expect(tester.takeException(), isNull);
    expect(find.text('家里台式机'), findsWidgets);

    await teardown(tester);
  }, timeout: const Timeout(Duration(seconds: 60)));
}

