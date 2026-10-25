import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/models/server_config.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/services/storage_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/config_page.dart';
import 'package:dsh_mobile/views/settings/gateway_switcher_card.dart';

/// 设置首屏的服务器切换。
///
/// 用户的真实目标是"快速换服务器"，所以这里钉住的是**步数**：设置页第一屏
/// 就能看到当前服务器、点开列表、选一台立即连接。不是让用户再进连接页找下拉框。
class _RecordingDshService extends DshService {
  ServerConfig? connected;

  @override
  Future<void> connect(ServerConfig config) async {
    connected = config;
  }
}

void main() {
  Future<void> settle(WidgetTester tester, [int frames = 10]) async {
    for (var i = 0; i < frames; i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> seedProfiles() async {
    await StorageService.upsertProfile(ServerConfig(
      id: 'home',
      name: '家里',
      host: 'home.example.com',
      port: 3088,
      token: 'tok-home',
    ));
    await StorageService.upsertProfile(ServerConfig(
      id: 'office',
      name: '公司',
      host: 'office.example.com',
      port: 3088,
      token: 'tok-office',
    ));
    await StorageService.setActiveProfile('home');
  }

  Future<_RecordingDshService> pumpCard(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dsh = _RecordingDshService();
    await tester.pumpWidget(
      MaterialApp(
        builder: (ctx, child) =>
            ThemeScope(isDark: false, child: child ?? const SizedBox()),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [GatewaySwitcherCard(dsh: dsh)],
          ),
        ),
      ),
    );
    await settle(tester, 12);
    return dsh;
  }

  testWidgets('设置首屏显示当前服务器，切换列表里能一键连接另一台', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.runAsync(seedProfiles);

    final dsh = await pumpCard(tester);

    expect(find.text('当前服务器'), findsOneWidget);
    expect(find.text('家里'), findsOneWidget);
    expect(find.text('home.example.com:3088 · 未连接'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-gateway-switch-button')),
        findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey('settings-gateway-switch-button')));
    await settle(tester, 4);

    expect(find.text('切换服务器'), findsOneWidget);
    expect(find.text('公司'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey('settings-gateway-option-office')));
    await settle(tester, 12);

    expect(dsh.connected?.id, 'office', reason: '选一台服务器就必须真的发起连接');
    expect(find.text('公司'), findsOneWidget, reason: '切换后首屏必须变成新服务器的名字');
    expect(find.text('切换服务器'), findsNothing, reason: '选择后 sheet 应关闭');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('一台都没保存时，首屏入口是「添加」而不是空切换面板', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await pumpCard(tester);

    expect(find.text('尚未添加服务器'), findsOneWidget);
    expect(find.text('添加'), findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey('settings-gateway-switch-button')));
    await settle(tester, 10);

    expect(find.byType(ConfigPage), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
