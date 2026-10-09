import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/services/voice_input_service.dart';

/// 「语音按钮点了没反应」的回归测试。
///
/// ## 症状为什么必须先变成"有反馈"
///
/// 用户报的原始描述是「点了还是没反应」——**连一句报错都没有**。而"没反应"这个
/// 现象无法区分下面几种彼此无关的原因：
///
///   * 设备没有语音识别引擎
///   * 麦克风权限被拒，且系统不再弹窗
///   * 插件卡在 Android 的权限回调上（`initialize` 永不完成）
///   * 缺中文语言包
///   * 上一次识别会话没释放
///
/// 前两组测试守的是"**任何**失败都必须在几秒内变成一条可见提示"，也就是把
/// "静默挂死"这个类别整体消灭掉 —— 这比修某一种具体原因更重要，因为后者永远
/// 会有新的。
///
/// 第三组守的是本次真正定位到的那个 Android 侧问题：插件默认会连带申请
/// `BLUETOOTH_CONNECT`，而我们的 manifest 只声明了 `RECORD_AUDIO`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugin.csdcorp.com/speech_to_text');

  /// 记录下发给平台的方法调用，供断言检查参数。
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 装一个 mock：按 [responses] 回包；某个方法没列出就返回 null。
  /// 用 [neverReplies] 可以让指定方法**永不回包** —— 这正是线上挂死的形态。
  void stub(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  group('平台不回调时必须在有限时间内给出反馈（不能静默挂死）', () {
    test('initialize 不回调 → init() 会在超时后返回 false，而不是永久挂起', () async {
      stub((MethodCall call) {
        if (call.method == 'initialize') {
          // 永不完成：等价于 Android 侧 requestPermissions 的回调没送达
          return Completer<Object?>().future;
        }
        return Future<Object?>.value(null);
      });

      final svc = VoiceInputService.instance;
      svc.debugReset();
      svc.initTimeout = const Duration(milliseconds: 300);

      final sw = Stopwatch()..start();
      final ok = await svc.init();
      sw.stop();

      expect(ok, isFalse, reason: '平台不回调只能是"不可用"，不能是"也不返回"');
      expect(
        sw.elapsedMilliseconds < 3000,
        isTrue,
        reason: '必须在超时后立刻返回；实际用了 ${sw.elapsedMilliseconds}ms',
      );
    });

    test('这类失败的原因文案要区分于"设备不支持"', () async {
      stub((MethodCall call) {
        if (call.method == 'initialize') return Completer<Object?>().future;
        return Future<Object?>.value(null);
      });

      final svc = VoiceInputService.instance;
      svc.debugReset();
      svc.initTimeout = const Duration(milliseconds: 300);
      await svc.init();

      final reason = await svc.unavailableReason();
      // 超时和"设备没有识别引擎"的处置完全不同：前者值得再点一次，
      // 后者重试多少次都一样。文案混在一起会让用户白试。
      expect(reason.contains('没有响应'), isTrue, reason: '实际文案: $reason');
      expect(reason.contains('没有可用的语音识别服务'), isFalse,
          reason: '超时不能被说成设备不支持');
    });

    test('超时后允许再次探测，不能把失败记死', () async {
      var attempt = 0;
      stub((MethodCall call) {
        if (call.method == 'initialize') {
          attempt++;
          // 第一次不回调（超时），第二次正常回 false
          if (attempt == 1) return Completer<Object?>().future;
          return Future<Object?>.value(false);
        }
        return Future<Object?>.value(null);
      });

      final svc = VoiceInputService.instance;
      svc.debugReset();
      svc.initTimeout = const Duration(milliseconds: 250);

      await svc.init();
      await svc.init();

      expect(attempt, greaterThanOrEqualTo(2),
          reason: '超时后必须重新探测：用户可能就是那一次对话框被打断了，'
              '记住失败等于让他只能重装 App');
    });
  });

  group('initialize 的参数（本次定位到的 Android 侧问题）', () {
    test('必须带上 androidNoBluetooth，不要去申请未声明的 BLUETOOTH_CONNECT', () async {
      stub((MethodCall call) => Future<Object?>.value(false));

      final svc = VoiceInputService.instance;
      svc.debugReset();
      await svc.init();

      final init = calls.firstWhere(
        (c) => c.method == 'initialize',
        orElse: () => throw StateError('没有调用 initialize'),
      );

      // 参数是**扁平 map**：platform interface 里对每个 SpeechConfigOption 执行
      //   params[option.name] = option.value
      // 所以是 arguments['noBluetooth']，不是 arguments['options']。
      final args = init.arguments is Map ? init.arguments as Map : const {};

      expect(
        args['noBluetooth'],
        isTrue,
        reason: '必须传 androidNoBluetooth（会展开成 noBluetooth=true）。'
            '插件默认把 RECORD_AUDIO 与 BLUETOOTH_CONNECT 一起 requestPermissions'
            '（SpeechToTextPlugin.kt:495），而 manifest 只声明了 RECORD_AUDIO；'
            '申请未声明的运行时权限会被 Android 直接否掉，'
            '整个权限申请流程跟着走偏。实际参数: $args',
      );
    });
  });

  group('locales() 挂死时仍必须走到 listen（手机实测到的真凶）', () {
    // 用户手机上的诊断报告是：
    //     服务可用: 是 / 麦克风权限: 已授予 / 可用语言: 查询失败(5s 超时)
    //
    // 即设备有识别引擎、权限也给了，但 locales() 永不返回。而 start() 里
    // `localeId: await _resolveLocale(localeId)` 是 listen() 的**实参**，排在
    // listen() 之前求值 —— 加在 listen() 上的超时保护不到它。它一挂死，listen()
    // 永远轮不到执行，用户看到的就是"点了完全没反应"。
    //
    // 这一组守的就是：语言列表查不出来**不能**挡住 listen。
    test('locales 永不返回时，start() 仍会调用 listen 并返回', () async {
      stub((MethodCall call) {
        switch (call.method) {
          case 'initialize':
            return Future<Object?>.value(true);
          case 'has_permission':
            return Future<Object?>.value(true);
          case 'locales':
            // 永不完成 —— 等价于那台设备上的实际行为
            return Completer<Object?>().future;
          case 'listen':
            return Future<Object?>.value(true);
          default:
            return Future<Object?>.value(null);
        }
      });

      final svc = VoiceInputService.instance;
      svc.debugReset();
      svc.localeProbeTimeout = const Duration(milliseconds: 250);
      svc.listenTimeout = const Duration(seconds: 2);

      final sw = Stopwatch()..start();
      await svc.start(
        onPartial: (_, __) {},
        onFinal: (_) {},
        onError: (_) {},
      );
      sw.stop();

      expect(
        calls.any((c) => c.method == 'listen'),
        isTrue,
        reason: '必须走到 listen。若为否，说明卡在了 _resolveLocale 里的 '
            'locales() 上 —— 这正是"点了没反应"的成因（连报错都没有，因为根本'
            '没走到报错那一步）。实际调用: ${calls.map((c) => c.method).toList()}',
      );
      expect(
        sw.elapsedMilliseconds < 6000,
        isTrue,
        reason: '必须在有限时间内返回；实际 ${sw.elapsedMilliseconds}ms',
      );
    });

    test('查过一次超时后不再重复查（不让每次点击都白等）', () async {
      var localeCalls = 0;
      stub((MethodCall call) {
        switch (call.method) {
          case 'initialize':
            return Future<Object?>.value(true);
          case 'has_permission':
            return Future<Object?>.value(true);
          case 'locales':
            localeCalls++;
            return Completer<Object?>().future;
          case 'listen':
            return Future<Object?>.value(true);
          default:
            return Future<Object?>.value(null);
        }
      });

      final svc = VoiceInputService.instance;
      svc.debugReset();
      svc.localeProbeTimeout = const Duration(milliseconds: 200);
      svc.listenTimeout = const Duration(seconds: 1);

      await svc.start(onPartial: (_, __) {}, onFinal: (_) {}, onError: (_) {});
      await svc.start(onPartial: (_, __) {}, onFinal: (_) {}, onError: (_) {});

      // 语言只是提示，查过一次超时就把结论记住；否则用户每次点击都要多等一个
      // 超时的时长，体感上就是"麦克风反应很慢"。
      expect(localeCalls, 1,
          reason: '第二次点击不应再查 locales；实际查了 $localeCalls 次');
    });
  });

  group('识别结果必须真的到达 Dart（"能录音但转化不出文字"）', () {
    // 用户报的原话：「点击了语音那个图标，也显示了收音的动画，但是就是录不到，
    // 没有发送语音过去，也没有转化成文字」——动画能出来说明麦克风开了、
    // listen 成功了；但一个字都没有，说明**识别结果没有去处**。
    //
    // 成因：listen() 的 onResult 参数从来没传过，所以插件把结果交付给一个 null
    // 回调。本方法的 onPartial / onFinal 曾经只出现在签名里，函数体一次都没引用，
    // 而 analyze 不把"形参未使用"当警告 —— 于是这个漏法不报任何错，一路到用户手上。
    //
    // 这一组直接模拟平台把识别结果推进来，断言它真的变成了文字。

    /// 模拟平台 → App 的回调帧（插件用 textRecognition 方法名回传 JSON 字符串）。
    Future<void> pushRecognition(String words, {bool finalResult = false}) async {
      final payload = jsonEncode({
        'alternates': [
          {'recognizedWords': words, 'confidence': 0.92}
        ],
        'finalResult': finalResult,
      });
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall('textRecognition', payload)),
        (ByteData? _) {},
      );
    }

    void stubHappy() {
      stub((MethodCall call) {
        switch (call.method) {
          case 'initialize':
            return Future<Object?>.value(true);
          case 'has_permission':
            return Future<Object?>.value(true);
          case 'locales':
            return Future<Object?>.value(['zh_CN:中文']);
          case 'listen':
            return Future<Object?>.value(true);
          default:
            return Future<Object?>.value(null);
        }
      });
    }

    test('平台推来中间结果 → onPartial 收到文字', () async {
      stubHappy();
      final svc = VoiceInputService.instance;
      svc.debugReset();

      final partials = <String>[];
      await svc.start(
        onPartial: (text, _) => partials.add(text),
        onFinal: (_) {},
        onError: (_) {},
      );

      await pushRecognition('你好');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        partials,
        contains('你好'),
        reason: '中间结果必须到达 onPartial。若为空，最可能的原因是 listen() '
            '没有传 onResult —— 那样麦克风会正常打开、动画也会动，但识别结果'
            '被交付给一个 null 回调，一个字都出不来。实际收到: $partials',
      );
    });

    test('平台推来最终结果 → onFinal 收到完整文字', () async {
      stubHappy();
      final svc = VoiceInputService.instance;
      svc.debugReset();

      final finals = <String>[];
      await svc.start(
        onPartial: (_, __) {},
        onFinal: finals.add,
        onError: (_) {},
      );

      await pushRecognition('今天天气不错', finalResult: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        finals,
        contains('今天天气不错'),
        reason: '最终结果必须到达 onFinal，否则输入框永远拿不到文字。'
            '实际收到: $finals',
      );
    });

    test('空文本不回调（避免把输入框清空）', () async {
      stubHappy();
      final svc = VoiceInputService.instance;
      svc.debugReset();

      final partials = <String>[];
      await svc.start(
        onPartial: (text, _) => partials.add(text),
        onFinal: (_) {},
        onError: (_) {},
      );

      await pushRecognition('');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 空字符串直接丢弃：把它交给上层会把用户已经输入的内容清掉。
      expect(partials, isEmpty, reason: '空结果不应回调；实际: $partials');
    });
  });

  group('诊断报告能区分各种原因', () {
    test('正常情况下报告包含每一项探测结果', () async {
      stub((MethodCall call) {
        switch (call.method) {
          case 'initialize':
            return Future<Object?>.value(true);
          case 'has_permission':
            return Future<Object?>.value(true);
          case 'locales':
            // 平台返回的是 "localeId:name" 形式的**字符串**列表。
            // （speech_to_text.dart 的 locales() 按 ':' 切成两段再包成 LocaleName，
            //  切不出两段的项会被直接丢掉 —— 所以给 map 只会得到空列表。）
            return Future<Object?>.value(['zh_CN:中文', 'en_US:English']);
          default:
            return Future<Object?>.value(null);
        }
      });

      final svc = VoiceInputService.instance;
      svc.debugReset();
      await svc.init();
      final report = await svc.diagnose();

      for (final needle in ['服务可用', '麦克风权限', '可用语言数', '中文语言包']) {
        expect(report.contains(needle), isTrue,
            reason: '诊断报告缺少「$needle」这一项，用户截屏也定位不到。报告:\n$report');
      }
      expect(report.contains('zh_CN'), isTrue, reason: '应列出中文语言包');
    });

    test('没有中文语言包时要明确指出后果', () async {
      stub((MethodCall call) {
        switch (call.method) {
          case 'initialize':
            return Future<Object?>.value(true);
          case 'has_permission':
            return Future<Object?>.value(true);
          case 'locales':
            return Future<Object?>.value(['en_US:English']);
          default:
            return Future<Object?>.value(null);
        }
      });

      final svc = VoiceInputService.instance;
      svc.debugReset();
      await svc.init();
      final report = await svc.diagnose();

      // 这一条是给用户看的可执行结论：能启动、但识别不出中文。
      expect(report.contains('没有中文识别包'), isTrue, reason: '报告:\n$report');
    });

    test('语言列表为空时要点明识别服务不可用', () async {
      stub((MethodCall call) {
        switch (call.method) {
          case 'initialize':
            return Future<Object?>.value(true);
          case 'has_permission':
            return Future<Object?>.value(true);
          case 'locales':
            return Future<Object?>.value(<Object?>[]);
          default:
            return Future<Object?>.value(null);
        }
      });

      final svc = VoiceInputService.instance;
      svc.debugReset();
      await svc.init();
      final report = await svc.diagnose();

      expect(report.contains('识别服务不可用'), isTrue, reason: '报告:\n$report');
    });

    test('诊断本身超时也要给出报告，不能打不开', () async {
      stub((MethodCall call) {
        if (call.method == 'locales') return Completer<Object?>().future;
        if (call.method == 'has_permission') return Completer<Object?>().future;
        return Future<Object?>.value(true);
      });

      final svc = VoiceInputService.instance;
      svc.debugReset();
      // diagnose() 内部对 hasPermission/locales 各留了 5s 超时；这里只验证它
      // 最终仍能返回一份带内容的文本，而不是把对话框永远卡在转圈上。
      final report = await svc
          .diagnose()
          .timeout(const Duration(seconds: 25), onTimeout: () => '__TIMEOUT__');

      expect(report, isNot('__TIMEOUT__'),
          reason: 'diagnose() 自己必须收口，否则用户看到的是一个永远转圈的对话框');
      expect(report.isNotEmpty, isTrue);
    }, timeout: const Timeout(Duration(seconds: 40)));
  });
}
