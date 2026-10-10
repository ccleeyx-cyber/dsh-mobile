import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/models/task_center.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/custom_settings_view.dart';

/// 设置页「离线推送 (ntfy)」区块的界面回归测试（v1.14）。
///
/// 钉住的是**用户须知**那一条：网关里填好地址与 topic 只决定"往哪儿发"，
/// ntfy 是发布/订阅模型 —— 手机上还得有一个客户端订阅同一个 topic，否则
/// 一条提示都不会有。之前只有三个输入框，用户不知道后半段，于是配好之后
/// "一直收不到"却没有任何线索可查。
///
/// 全部走内存注入口（`debugSetTaskCenter` 摆 `pushConfig`），**不打真实网关**：
/// 历史上打真实网关的测试往用户会话里塞过上千条垃圾数据。
void main() {
  Future<DshService> pumpSettings(WidgetTester tester, {Size size = const Size(420, 1600)}) async {
    tester.view.physicalSize = size;
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

  Future<void> scrollToPush(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(CustomSettingsView.pushRequirementNoteKey),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  testWidgets('推送区块写明必须自备 ntfy 客户端并订阅同一 topic', (tester) async {
    final dsh = await pumpSettings(tester);
    dsh.debugSetTaskCenter(push: const PushConfig(enabled: false, url: '', topic: '', hasToken: false));
    await tester.pump();
    await scrollToPush(tester);

    expect(find.byKey(CustomSettingsView.pushRequirementNoteKey), findsOneWidget);

    // 三件用户必须知道的事，逐条断言（少一条这个区块就等于没说）。
    expect(
      find.textContaining('安装一个 ntfy 客户端'),
      findsOneWidget,
      reason: '必须告诉用户要去装一个客户端 App',
    );
    expect(
      find.textContaining('订阅与下面完全相同的一个 topic'),
      findsOneWidget,
      reason: '必须告诉用户订阅同一个 topic',
    );
    expect(
      find.textContaining('手机不会有任何提示'),
      findsOneWidget,
      reason: '必须说明"什么都没配好就是完全没有提示"，否则用户只会以为功能坏了',
    );
    await teardown(tester);
  });

  testWidgets('推送区块说明"App 在线时不发 ntfy"，避免用户把它当成坏了', (tester) async {
    final dsh = await pumpSettings(tester);
    dsh.debugSetTaskCenter(push: const PushConfig(enabled: true, url: 'https://ntfy.sh', topic: 't', hasToken: false));
    await tester.pump();
    await scrollToPush(tester);

    // 去重（App 活着时只弹本地通知）是网关侧的行为，界面上必须说清这个前提，
    // 否则用户开着 App 测推送、什么都没收到，就会判定"功能没做"。
    expect(
      find.textContaining('只在 App 不在线'),
      findsOneWidget,
      reason: '必须说明 ntfy 只在 App 不在线时发送',
    );
    expect(find.textContaining('不会重复推两条'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('网关回显的推送配置会灌进输入框（已开启时显示"推送已开启"）', (tester) async {
    final dsh = await pumpSettings(tester);
    dsh.debugSetTaskCenter(
      push: const PushConfig(enabled: true, url: 'https://ntfy.sh', topic: 'my-topic', hasToken: true),
    );
    await tester.pump();
    await scrollToPush(tester);

    expect(find.text('推送已开启'), findsOneWidget);
    // 断言 controller 的值而不是 hint：hint 也是 Text，会被 widgetWithText 误命中。
    expect(
      tester.widget<TextField>(find.byKey(CustomSettingsView.pushUrlFieldKey)).controller?.text,
      'https://ntfy.sh',
    );
    expect(
      tester.widget<TextField>(find.byKey(CustomSettingsView.pushTopicFieldKey)).controller?.text,
      'my-topic',
    );
    await teardown(tester);
  });

  testWidgets('令牌永不回显：已保存时只提示"留空表示不改动"且字段为空', (tester) async {
    final dsh = await pumpSettings(tester);
    dsh.debugSetTaskCenter(
      push: const PushConfig(enabled: true, url: 'https://ntfy.sh', topic: 'my-topic', hasToken: true),
    );
    await tester.pump();
    await scrollToPush(tester);

    expect(find.text('已保存，留空表示不改动'), findsOneWidget);
    // 网关从不下发 token 本身：字段必须为空、且是密码型。
    final token = tester.widget<TextField>(find.byKey(CustomSettingsView.pushTokenFieldKey));
    expect(token.controller?.text, '', reason: '已保存的 token 不得回显到界面');
    expect(token.obscureText, isTrue);
    await teardown(tester);
  });

  testWidgets('未保存过令牌时不谎称"已保存"', (tester) async {
    final dsh = await pumpSettings(tester);
    dsh.debugSetTaskCenter(
      push: const PushConfig(enabled: true, url: 'https://ntfy.sh', topic: 'my-topic', hasToken: false),
    );
    await tester.pump();
    await scrollToPush(tester);

    expect(find.text('已保存，留空表示不改动'), findsNothing);
    expect(find.text('可留空'), findsOneWidget);
    await teardown(tester);
  });
}
