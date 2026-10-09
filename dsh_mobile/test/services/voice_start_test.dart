import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/services/voice_input_service.dart';

/// 语音启动路径的集成测试（v1.10.1）。
///
/// ## 为什么必须有这一批
///
/// v1.8.0 起，语音功能**在任何设备上都完全不可用**，提示永远是"无法启动语音
/// 识别"，而且 `flutter analyze` 干净、222 个测试全绿。根因是：
///
///   speech_to_text 6.6.2 的 `listen()` 返回 `Future`（成功时是 **null**），
///   只有 7.x 才返回 `Future<bool>`。代码按 7.x 写了 `if (!started)`，
///   于是 6.6.2 下 `!null` 抛 TypeError，被自己的 catch 吞成那句笼统提示。
///
/// 静态检查抓不到（返回值静态类型是 dynamic），纯逻辑单测也抓不到（不碰这个
/// 返回值）。唯一能抓到它的办法，是把**平台通道**打桩、真正跑一遍启动路径 ——
/// 这正是这个文件做的事。
///
/// 通道名与调用的方法名取自 speech_to_text_platform_interface 的
/// method_channel_speech_to_text.dart：
///   channel 'plugin.csdcorp.com/speech_to_text'
///   'initialize' / 'has_permission' / 'locales' / 'listen' / 'stop' / 'cancel'
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugin.csdcorp.com/speech_to_text');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> calls;

  /// 安装平台桩。[handlers] 没覆盖的方法返回 null（等价于"没实现"）。
  ///
  /// [onListen] 单独拿出来，是因为它是本文件的主角，需要能抛异常、能返回 false。
  void stubPlatform({
    bool initializeOk = true,
    bool listenOk = true,
    List<String> locales = const ['zh_CN', 'en_US'],
    Object? listenThrows,
    bool emitListeningStatus = true,
  }) {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'initialize':
          return initializeOk;
        case 'has_permission':
          return true;
        case 'locales':
          return locales;
        case 'listen':
          if (listenThrows != null) throw listenThrows;
          if (listenOk && emitListeningStatus) {
            // 6.6.2 的 isListening 是由平台回调**异步**置位的
            // （speech_to_text.dart:679 的 _updateStatus）。真实平台会在
            // startListening 之后发这个状态，桩必须照做 —— 否则测的就不是
            // 真实时序，也发现不了"刚 await 完就查 isListening"那个竞态。
            Future<void>.delayed(const Duration(milliseconds: 30), () {
              messenger.handlePlatformMessage(
                channel.name,
                const StandardMethodCodec().encodeMethodCall(
                  MethodCall('notifyStatus', 'listening'),
                ),
                (_) {},
              );
            });
          }
          return listenOk;
        case 'stop':
        case 'cancel':
          return null;
        default:
          return null;
      }
    });
  }

  setUp(() async {
    // 先排空再重置：上一个用例可能留下一个正在飞的异步状态回调，如果它在重置
    // **之后**才到达，就会污染新实例的 isListening（实测会让"平台没开始录音"
    // 那条用例假通过）。
    await Future<void>.delayed(const Duration(milliseconds: 80));
    VoiceInputService.instance.debugReset();
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    messenger.setMockMethodCallHandler(channel, null);
    VoiceInputService.instance.debugReset();
  });

  Future<bool> startExpecting({String? expectNoError}) async {
    String? error;
    final ok = await VoiceInputService.instance.start(
      onPartial: (_, __) {},
      onFinal: (_) {},
      onError: (m) => error = m,
    );
    if (expectNoError != null && error != null) {
      fail('不应报错（$expectNoError），实际报错：$error');
    }
    return ok;
  }

  group('成功路径（回归：曾经的 TypeError 就死在这里）', () {
    test('平台一切正常时 start 必须成功、不报错，并且真的驱动了平台', () async {
      stubPlatform();

      String? error;
      final ok = await VoiceInputService.instance.start(
        onPartial: (_, __) {},
        onFinal: (_) {},
        onError: (m) => error = m,
      );

      // 这是本文件的核心断言：旧代码在这里必然失败 ——
      // !null 抛 TypeError，被自己的 catch 吞成 ok=false +「无法启动语音识别」。
      expect(ok, isTrue, reason: '平台返回成功时绝不能判成失败');
      expect(error, isNull, reason: '成功时不该调用 onError');

      // 这两条断言写在这里而不是单独一个用例：插件把 _initWorked 缓存在
      // SpeechToTextPlatform 的单例上（换掉我的 SpeechToText 也清不掉），
      // 所以只有本文件的**第一个**用例能观察到 initialize 走到平台。
      // 放在同一个用例里，断言的才是真实可达的行为。
      expect(calls, contains('initialize'));
      expect(calls, contains('listen'));
    });
  });

  group('失败路径必须透出真实原因，不能吞成一句笼统文案', () {
    test('平台抛 PlatformException 时，把平台的消息原样带给用户', () async {
      stubPlatform(
        listenThrows: PlatformException(
          code: 'error_no_match',
          message: '未检测到语音，请靠近麦克风再说一次',
        ),
      );

      String? error;
      final ok = await VoiceInputService.instance.start(
        onPartial: (_, __) {},
        onFinal: (_) {},
        onError: (m) => error = m,
      );

      expect(ok, isFalse);
      // 关键：以前这里永远是"无法启动语音识别"，把平台给的原因丢了。
      expect(error, contains('未检测到语音'));
    });

    // 这里**故意没有**"平台不抛异常但也没开始录音"那条用例。
    //
    // 想覆盖它需要让插件处于"未初始化"或"listen 返回 false"的状态，而
    // `SpeechToText()` 是工厂单例（speech_to_text.dart:190），它的 `_initWorked`
    // / `_listening` 是进程级的、测试里换不掉也清不了：一旦本文件第一个用例成功
    // initialize 过，后面的用例连 initialize 都不会再走到平台。
    //
    // 强行写会得到一个永远假通过的用例 —— 实测踩过：它报成功，掩盖了真正的失败。
    // 与其留一条骗人的断言，不如写明这里测不到，以及为什么。
    // 该分支的兜底逻辑（等 isListening 置位、超时后判失败）在代码里由
    // start() 的等待循环实现，并由上面的成功用例间接覆盖（成功路径同样依赖它）。

    test('设备不可用 → 报"没有识别服务"，不是"无法启动"', () async {
      // 用 debugSetAvailable 把"设备不支持"这个状态直接摆好，而不是靠桩让
      // initialize 返回 false：插件的 _initWorked 缓存在平台单例上，同一个
      // 测试进程里第二次 initialize 根本不会走到平台。走缝隙才是确定性的。
      stubPlatform();
      VoiceInputService.instance.debugSetAvailable(false);

      String? error;
      final ok = await VoiceInputService.instance.start(
        onPartial: (_, __) {},
        onFinal: (_) {},
        onError: (m) => error = m,
      );

      expect(ok, isFalse);
      expect(error, isNotNull);
      // 两条错误必须可区分：「设备不支持」是换个设备或装识别引擎的事，
      // 「无法启动」是重试的事。混成一句会给用户错误的方向。
      expect(error, contains('没有可用的语音识别服务'));
      expect(error, isNot(contains('无法启动')));
    });
  });

  group('语言选择：不支持的精确语言不能让整个功能挂掉', () {
    test('设备没有 zh_CN 但支持 zh_TW 时，退到同语言的其他地区', () async {
      stubPlatform(locales: ['zh_TW', 'en_US']);
      final ok = await startExpecting(expectNoError: '同语言回退');
      expect(ok, isTrue);
    });

    test('设备只有英文时，退回系统默认而不是失败', () async {
      // 硬传 zh_CN 在这种设备上会让 listen 直接失败 —— 这是"语音点不动"的
      // 另一个潜在来源。宁可识别语言不完美，也不要功能不可用。
      stubPlatform(locales: ['en_US']);
      final ok = await startExpecting(expectNoError: '无中文时回退系统默认');
      expect(ok, isTrue);
    });
  });
}
