import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/services/notification_service.dart';

/// 「审批/提问一条通知都收不到」的回归测试。
///
/// ## 缺陷本体
///
/// 通知插件初始化时只给了 iOS 设置：
///
///     const InitializationSettings(iOS: DarwinInitializationSettings())
///
/// 而 flutter_local_notifications 在 Android 平台上是这样校验的
/// （flutter_local_notifications_plugin.dart:132）：
///
///     if (defaultTargetPlatform == TargetPlatform.android
///         && initializationSettings.android == null) {
///       throw ArgumentError(
///           'Android settings must be set when targeting Android platform.');
///     }
///
/// 于是 initialize() 每次都在这里抛，被通知服务自己的 catch 吞成一行 debugPrint；
/// 插件从未初始化成功，之后**每个** show() 也在未初始化的插件上抛、同样被吞 ——
/// 整条通知链路彻底静默失效，界面上完全看不出问题。
///
/// ## 为什么必须显式把平台切成 Android
///
/// `initialize()` 的分支判断依赖 `defaultTargetPlatform`。在非 Android 的测试
/// 主机上它不会是 android，那段校验根本不会执行 —— 于是这个 bug 在测试里
/// **永远复现不出来**。必须用 debugDefaultTargetPlatformOverride 明确指定，
/// 测的才是真机上会走的那条路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    NotificationService.instance.debugReset();
  });

  void stubAll(Object? answer) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return Future<Object?>.value(answer);
    });
  }

  group('Android 上通知插件必须真的初始化成功', () {
    test('init() 必须给 AndroidInitializationSettings（漏了则整条链路静默失效）', () async {
      stubAll(true);
      final svc = NotificationService.instance;
      svc.debugReset();

      await svc.init();

      final initCall = calls.firstWhere(
        (c) => c.method == 'initialize',
        orElse: () => throw StateError('没有调用插件的 initialize'),
      );

      final args = initCall.arguments is Map ? initCall.arguments as Map : const {};
      expect(
        args['defaultIcon'],
        isNotNull,
        reason: '必须传 AndroidInitializationSettings（会展开成 defaultIcon）。'
            '漏了它时 initialize() 在 Android 上直接抛 ArgumentError：'
            '"Android settings must be set when targeting Android platform." '
            '实际参数: $args',
      );
    });

    test('init() 之后插件必须处于就绪态，而不是"权限有、插件没起来"', () async {
      stubAll(true);
      final svc = NotificationService.instance;
      svc.debugReset();

      final granted = await svc.init();

      expect(granted, isTrue, reason: '前置条件：权限已授予');
      expect(
        svc.debugPluginReady,
        isTrue,
        reason: '插件必须真的初始化成功。若为否，show() 会在未初始化的插件上抛，'
            '被 catch 吞掉 —— 用户只看到"就是没有通知"',
      );
      expect(svc.ready, isTrue);
      expect(svc.lastError, isNull, reason: '不应留下失败原因');
    });

    test('初始化失败必须留痕，而不是静默', () async {
      // 让平台的 initialize 抛错，模拟真机上插件起不来
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        if (call.method == 'initialize') {
          return Future<Object?>.error(
            PlatformException(code: 'init-failed', message: '模拟初始化失败'),
          );
        }
        return Future<Object?>.value(true);
      });

      final svc = NotificationService.instance;
      svc.debugReset();
      await svc.init();

      expect(svc.debugPluginReady, isFalse);
      expect(svc.ready, isFalse, reason: '权限有但插件没就绪，整体不算可用');
      // 关键：必须能说出"为什么没通知"。以前这里什么都没有，用户只能自己猜。
      expect(svc.lastError, isNotNull,
          reason: '初始化失败必须留下可展示的原因，否则用户无从判断');
    });
  });

  group('未就绪时不能假装发了通知', () {
    test('插件未就绪时 show() 不抛异常，但会留痕且不调插件', () async {
      // 让初始化失败（模拟"权限拿到了、插件起不来"）
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        if (call.method == 'initialize') {
          return Future<Object?>.error(
            PlatformException(code: 'init-failed', message: '模拟初始化失败'),
          );
        }
        return Future<Object?>.value(true);
      });

      final svc = NotificationService.instance;
      svc.debugReset();
      await svc.init();
      expect(svc.debugPluginReady, isFalse, reason: '前置条件：插件没就绪');

      // 这正是旧代码的表现：show() 会在未初始化的插件上抛异常，被 catch 吞掉 ——
      // 用户只看到"什么也没发生"。现在要求它明确拦下来并留下原因。
      await svc.show(title: '需要你授权', body: 'rm -rf /');

      expect(svc.lastError, isNotNull, reason: '未发出必须留痕');
      expect(
        calls.any((c) => c.method == 'show'),
        isFalse,
        reason: '插件没就绪时不应调用 show() —— 那只会抛一个被吞掉的异常，'
            '既发不出通知，也留不下线索',
      );
    });

    test('没有通知权限时不调用 show，并说明原因', () async {
      stubAll(false); // 权限申请返回 false
      final svc = NotificationService.instance;
      svc.debugReset();
      final granted = await svc.init();
      expect(granted, isFalse);

      await svc.show(title: '需要你授权', body: 'xx');

      expect(calls.any((c) => c.method == 'show'), isFalse);
      expect(svc.lastError, contains('权限'));
    });
  });

  group('正常链路上 show() 要真的调用插件', () {
    test('权限与插件都就绪时，审批通知会发给插件', () async {
      stubAll(true);
      final svc = NotificationService.instance;
      svc.debugReset();
      await svc.init();

      await svc.show(
        title: '需要你授权',
        body: 'Bash：rm -rf /tmp/x',
        kind: NotificationKind.actionRequired,
      );

      final showCall = calls.firstWhere(
        (c) => c.method == 'show',
        orElse: () => throw StateError('没有调用 show —— 通知根本没发出去'),
      );
      expect(showCall.arguments is Map || showCall.arguments is List, isTrue);
      // 高重要性渠道：审批是"agent 已停下等你"，必须能弹横幅
      expect(
        showCall.arguments.toString().contains(NotificationService.actionChannelId),
        isTrue,
        reason: '审批通知必须走高重要性渠道，否则不会弹横幅、收不到"被打断"的效果',
      );
      expect(svc.lastError, isNull);
    });
  });
}
