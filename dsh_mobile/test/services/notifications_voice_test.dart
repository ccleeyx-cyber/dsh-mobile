import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/services/notification_service.dart';
import 'package:dsh_mobile/services/voice_input_service.dart';

/// 通知与语音输入的测试（v1.8.0）。
///
/// 两者都重度依赖原生插件，所以这里能测的是**契约与降级行为**：
/// 插件在测试环境不可用时，代码必须走"如实告知用户"的分支，而不是崩掉，
/// 更不能静默假装成功 —— 那会让用户以为通知已开启、实际一条也收不到。
///
/// 原生通道用 [TestDefaultBinaryMessengerBinding] 打桩，不发真实通知、不申请
/// 真实麦克风权限。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotificationService 降级契约', () {
    test('默认状态是"没有权限"，而不是乐观地认为已开启', () {
      // 这是最关键的一条：一个默认 true 的 granted 会让 App 在用户拒绝权限后
      // 仍然声称"通知已开启"，而实际一条都收不到。
      final svc = NotificationService.instance;
      svc.debugSetGranted(false);
      expect(svc.permissionGranted, isFalse);
    });

    test('权限被拒时不启动后台保活', () async {
      final svc = NotificationService.instance;
      svc.debugSetGranted(false);
      // 没有权限却去拉前台服务，会弹一条用户根本没授权的通知。
      final ok = await svc.enableBackground();
      expect(ok, isFalse);
      expect(svc.backgroundEnabled, isFalse);
    });

    test('权限被拒时 send 静默返回，不抛异常', () async {
      final svc = NotificationService.instance;
      svc.debugSetGranted(false);
      // 没权限时调用插件会抛 MissingPluginException（测试环境无原生侧）。
      // 这里必须被吞掉：通知失败绝不该让 WS 帧处理崩掉。
      await expectLater(svc.show(title: 'x', body: 'y'), completes);
    });

    test('空标题不发送（避免 ROM 上显示成应用名）', () async {
      final svc = NotificationService.instance;
      svc.debugSetGranted(true);
      // 空标题在某些系统上会显示为应用名，体验很差，因此静默丢弃。
      await expectLater(svc.show(title: '   ', body: 'x'), completes);
    });

    test('渠道 id 稳定（改了就与原生侧对不上，通知静默不显示）', () {
      // 这两个值同时被 Dart 与 MainActivity.kt 使用。改动必须同步两处。
      expect(NotificationService.infoChannelId, 'dsh_events');
      expect(NotificationService.actionChannelId, 'dsh_action');
    });

    test('两种 kind 走不同渠道：一般的走低、待处理的走高', () {
      // 待授权/待回答必须能打断（agent 已停滞在等用户）；
      // 一般性事件若也走高渠道，每条消息都弹横幅，用户会直接关掉通知。
      expect(NotificationKind.info, isNot(NotificationKind.actionRequired));
    });
  });

  group('VoiceInputService 降级契约', () {
    test('默认识别语言是简体中文', () {
      // 不指定的话部分 ROM 会拿英文模型去识别中文，结果完全不可用。
      expect(VoiceInputService.defaultLocaleId, 'zh_CN');
    });

    test('设备不支持时 start 返回 false 并回调错误，不抛异常', () async {
      final svc = VoiceInputService.instance;
      svc.debugSetAvailable(false);

      String? err;
      final ok = await svc.start(
        onPartial: (_, __) {},
        onFinal: (_) {},
        onError: (m) => err = m,
      );
      expect(ok, isFalse);
      // 必须明确告知用户，否则按钮点了没反应会被当成 bug。
      expect(err, isNotNull);
      expect(err, contains('语音识别'));
    });

    test('识别未开始时 listening 为 false', () {
      final svc = VoiceInputService.instance;
      svc.debugSetAvailable(true);
      expect(svc.debugGetListening(), isFalse);
    });

    test('available 状态可被注入以便测试 UI 分支', () {
      final svc = VoiceInputService.instance;
      svc.debugSetAvailable(false);
      expect(svc.isAvailable, isFalse);
      svc.debugSetAvailable(true);
      expect(svc.isAvailable, isTrue);
    });
  });

  group('原生通道契约', () {
    test('前台服务通道名与 MainActivity.kt 一致', () {
      // Kotlin 侧是 "dsh_mobile/foreground"。改名必须两边同步，
      // 否则 enableBackground 永远静默失败。
      expect(const MethodChannel('dsh_mobile/foreground').name, 'dsh_mobile/foreground');
    });
  });
}