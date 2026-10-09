import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 语音输入（§4.2）。
///
/// ## 为什么用系统语音识别而不是「录音 + 上传识别」
///
/// * 零服务端改动：网关不需要新增识别端点，也不需要处理音频流。
/// * 复用手机上已有的识别模型，离线设备也能用。
/// * 隐私：音频不出设备（用离线模型时），不上传任何音频。
///
/// 代价是**依赖设备上存在可用的语音服务**。部分 ROM 或无 Google 服务的设备上
/// 没有，系统会直接报不可用。所以 [init] 必须在按钮可点之前跑一次，失败时如实
/// 告诉用户"这台设备不支持语音输入"，而不是让按钮点了没反应。
///
/// ## 关于 locale
///
/// 插件用 `String localeId`（形如 `"zh_CN"`），**不是** Dart 的 `Locale`。
/// 不显式传的话部分 ROM 会拿英文模型去识别中文，出来的东西完全不能用 ——
/// 所以这里默认给中文，并允许调用方覆盖。
class VoiceInputService {
  VoiceInputService._();
  static final VoiceInputService instance = VoiceInputService._();

  /// 语音后端。
  ///
  /// 注意 `SpeechToText()` 是**工厂单例**（见 [debugReset] 的说明），所以这个字段
  /// 持有的是一个进程级共享对象 —— 别试图靠"换一个实例"来隔离状态，那做不到。
  final SpeechToText _speech = SpeechToText();

  bool _initialized = false;
  bool _available = false;
  bool _listening = false;

  /// 上一次探测是否因为**平台不回调**而超时。
  ///
  /// 单独记这一位：它与"设备不支持"的处置完全不同 —— 前者值得重试一次
  /// （权限对话框那次可能被打断了），后者重试多少次都一样。
  bool _initTimedOut = false;

  /// 平台调用超时时长。
  ///
  /// 做成实例字段而不是常量，是为了让测试能在几百毫秒内驱动"平台不回调"这条
  /// 路径 —— 否则验证它就得在测试里真等 12 秒。
  @visibleForTesting
  Duration initTimeout = const Duration(seconds: 12);

  @visibleForTesting
  Duration listenTimeout = const Duration(seconds: 6);

  /// 设备是否有可用的语音识别服务。
  bool get isAvailable => _available;

  bool get isListening => _listening;

  /// 上一次识别的错误（供 UI 展示"没有听清"之类的具体原因）。
  String? get lastError => _speech.lastError?.errorMsg;

  /// 探测设备是否具备语音识别能力，并申请麦克风权限。
  ///
  /// 返回是否可用。**权限被拒与设备不支持是两回事**：
  /// 前者应该引导用户去设置里开权限，后者只能告知不支持。两种都返回 false，
  /// 由 [lastError] / 调用方区分，避免给用户错误的指引。
  ///
  /// 这里刻意**不接受 localeId**：语言是在 [start] 里选的，而选择需要先拿到
  /// 设备支持的语言列表 —— 那份列表正是 initialize() 的产物。把语言参数放在
  /// 这里只会诱使人以为它能起作用。
  Future<bool> init() async {
    if (_initialized) return _available;
    _initialized = true;
    _initTimedOut = false;
    try {
      _available = await _speech
          .initialize(
            onStatus: (status) {
              // done / notListening：自动结束，UI 据此把麦克风按钮恢复常态。
              if (status == 'done' || status == 'notListening') {
                _listening = false;
              }
            },
            onError: (e) {
              _listening = false;
              debugPrint('[VoiceInput] 识别错误: ${e.errorMsg}');
            },
            // 用户说完但系统没给出终止信号时的兜底。给太短会在用户思考措辞时
            // 直接掐断，太长则会让"忘了关"的情况一直占着麦克风。
            finalTimeout: const Duration(milliseconds: 30000),
            // ⚠️ 只申请麦克风，**不要**连带申请 BLUETOOTH_CONNECT。
            //
            // 插件默认会把 RECORD_AUDIO 和 BLUETOOTH_CONNECT **一起**
            // requestPermissions（见 SpeechToTextPlugin.kt:495 的
            // `if (!noBluetoothOpt) requiredPermissions.plus(BLUETOOTH_CONNECT)`），
            // 而我们的 manifest 只声明了 RECORD_AUDIO。
            //
            // 申请一个没在 manifest 里声明的运行时权限是错误用法：Android 会直接
            // 否掉它，整个申请流程也跟着走偏 —— 权限对话框不出现、或回调不落地。
            // 语音输入并不需要蓝牙耳机路由，索性让插件根本不去要它。
            options: [SpeechToText.androidNoBluetooth],
          )
          // 这个超时不是"防御性写法"，它修的是一个真实症状。
          //
          // 平台的 initialize 走的是 ActivityCompat.requestPermissions，结果**只**
          // 由 onRequestPermissionsResult 回调送达。那个回调一旦不来（权限对话框
          // 被系统抑制、Activity 期间重建等），插件里的 result 就永远留在
          // activeResult 槽里 —— 这个 Future **永不完成**，await 挂死。
          // 用户看到的就是"点了完全没反应"，连一句报错都没有。
          //
          // 宁可报超时，也不能无声无息。
          .timeout(initTimeout);
    } on TimeoutException {
      debugPrint('[VoiceInput] 初始化超时：平台始终没有回调');
      _available = false;
      _initTimedOut = true;
    } catch (e) {
      debugPrint('[VoiceInput] 初始化失败: $e');
      _available = false;
    }
    // 探测失败**不永久缓存**。
    //
    // 这一行是修一个真实缺陷：原先 _initialized 一旦置 true，失败结果就被记死，
    // 之后每次点击都直接返回"不可用"，用户哪怕去系统设置里开了麦克风权限，
    // 回到 App 也依然点不动 —— 只能重装。清掉标记后，下次点击会重新探测。
    if (!_available) _initialized = false;
    return _available;
  }

  /// 语音不可用的**具体原因**，用于给用户可执行的指引。
  ///
  /// 必须把「没授权麦克风」和「设备没有识别服务」分开：前者的修复动作是去系统
  /// 设置开权限，后者只能换设备。混成一句"不可用"会让用户在设置里白找一圈，
  /// 而这正是"点了没反应、也没弹权限"那种体验的来源。
  Future<String> unavailableReason() async {
    // 超时与"设备不支持"必须分开说：前者重试一次往往就好（第一次的权限对话框
    // 可能被打断了），后者重试多少次都一样。混成一句会让用户白试。
    if (_initTimedOut) {
      return '语音识别没有响应（平台未回调）。请再点一次；'
          '若仍无反应，长按麦克风查看诊断';
    }
    try {
      if (!await _speech.hasPermission.timeout(const Duration(seconds: 5))) {
        return '未获得麦克风权限：请到「系统设置 → 应用 → DSH Mobile → 权限」中允许麦克风，然后回到这里再点一次';
      }
    } catch (e) {
      debugPrint('[VoiceInput] 权限查询失败: $e');
    }
    return '这台设备没有可用的语音识别服务（部分精简版系统不带识别引擎）。'
        '长按麦克风可查看诊断';
  }

  /// 一份可直接展示的语音状态报告。
  ///
  /// 加它的直接原因：用户报"点了没反应"。而"没反应"这个描述**无法区分**下面
  /// 任何一种原因 —— 设备没有识别引擎、权限被拒且系统不再弹窗、插件卡在权限
  /// 回调上、中文语言包缺失、上次会话没释放。
  ///
  /// 与其反复猜，不如让 App 把每一步的实测结果说出来：用户截一张图，就能直接
  /// 定位到是哪一环。
  Future<String> diagnose() async {
    final lines = <String>[];
    lines.add('探测状态: ${_initialized ? "已完成" : "未完成"}');
    lines.add('平台回调超时: ${_initTimedOut ? "是" : "否"}');
    lines.add('服务可用: ${_available ? "是" : "否"}');
    lines.add('正在识别: ${_listening ? "是" : "否"}');

    try {
      final granted = await _speech
          .hasPermission
          .timeout(const Duration(seconds: 5));
      lines.add('麦克风权限: ${granted ? "已授予" : "未授予"}');
    } catch (e) {
      lines.add('麦克风权限: 查询失败 ($e)');
    }

    try {
      final locales = await _speech
          .locales()
          .timeout(const Duration(seconds: 5));
      final zh = locales.where((l) => l.localeId.toLowerCase().startsWith('zh'));
      lines.add('可用语言数: ${locales.length}');
      lines.add('中文语言包: ${zh.isEmpty ? "无" : zh.map((l) => l.localeId).take(4).join(", ")}');
      if (zh.isEmpty && locales.isNotEmpty) {
        lines.add('  → 设备没有中文识别包，即便能启动也识别不出中文');
      }
      if (locales.isEmpty) {
        lines.add('  → 语言列表为空，通常意味着识别服务不可用');
      }
    } catch (e) {
      lines.add('可用语言: 查询失败 ($e)');
    }

    final err = lastError;
    if (err != null && err.isNotEmpty) lines.add('上次错误: $err');

    return lines.join('\n');
  }

  /// 开始识别。
  ///
  /// [onPartial] 每次识别到新片段时回调**完整的当前文本**（已包含此前的部分），
  /// 调用方应整段替换输入框内容 —— 追加会得到"你好你好你好世界世界"这种叠字，
  /// 这是流式识别最常见的接入错误。
  ///
  /// [onFinal] 识别结束时回调最终文本。
  Future<bool> start({
    required void Function(String text, double confidence) onPartial,
    required void Function(String text) onFinal,
    void Function(String message)? onError,
    String localeId = defaultLocaleId,
  }) async {
    if (!_available && !await init()) {
      onError?.call(await unavailableReason());
      return false;
    }

    try {
      // ⚠️ 绝对不要用 listen() 的返回值判断成败。
      //
      // speech_to_text 6.6.2 的签名是 `Future listen(...)` —— 成功时返回 **null**
      // （只有 7.x 才是 `Future<bool>`）。按 7.x 的写法写 `if (!started)`，在
      // 6.6.2 下 `!null` 会抛 TypeError，而那个异常被下面的 catch 吞掉、报成一句
      // 笼统的「无法启动语音识别」—— 在任何设备上都必然复现，且完全看不出原因。
      // 这个坑已经踩过一次（v1.8.0 起语音一直不可用，就是这个）。
      //
      // 约定：失败**只通过抛异常**表达；成功与否以 isListening 为准（插件内部
      // 拿到 started 之后也是这么记的）。
      await _speech
          .listen(
            listenOptions: SpeechListenOptions(
              // 语言放这里而不是 listen() 的顶层参数：后者已标记 deprecated。
              localeId: await _resolveLocale(localeId),
              // 流式：文字边说边出，不必等说完。
              partialResults: true,
              // dictation：说完一句自动停顿，把结果当成完整一段。
              listenMode: ListenMode.dictation,
              // 永久性错误（如权限被收回）时自动结束本次会话，避免反复重试。
              cancelOnError: true,
            ),
          )
          // 同 init()：平台不回调就会永久挂住，那又变成"点了没反应"。
          .timeout(listenTimeout);

      // 判定"到底开没开"，这里有两个坑叠在一起：
      //
      //   1. 6.6.2 的 listen() 在平台返回 **false** 时也**不会抛异常** ——
      //      它内部拿到 started 后只在 true 分支里做事，false 被静默吞掉。
      //      所以"没抛异常"并不等于"已经开始"。
      //   2. isListening 不是 listen() 里同步置位的，而是由平台的状态回调
      //      经 _updateStatus 异步设置（6.6.2 的 speech_to_text.dart:679）。
      //      刚 await 完就查它，会是 false，从而把成功误判成失败。
      //
      // 因此：等回调到达（最多 600ms，每 100ms 查一次），再以 isListening 为准。
      // 代价最多 600ms，只在真正启动失败时才会走到最后一步；而麦克风按钮本来
      // 就显示着转圈，用户感知不到。
      for (var attempt = 0; attempt < 6; attempt++) {
        if (_speech.isListening) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _listening = _speech.isListening;
      if (!_listening) {
        onError?.call(lastError ?? '麦克风没有开始录音，可能被其他应用占用');
      }
      return _listening;
    } on SpeechToTextNotInitializedException {
      // 允许下次点击重新初始化，不要把它变成永久失败。
      _initialized = false;
      _listening = false;
      onError?.call('语音识别尚未就绪，请再点一次');
      return false;
    } on TimeoutException {
      // 平台对 listen() 没回调：系统语音服务收下了请求却没应答。
      // 常见于识别引擎被停用、或上一次会话没释放。
      _initialized = false; // 允许下次重新初始化，别把状态记死
      _listening = false;
      onError?.call('启动语音识别超时：系统语音服务没有响应。'
          '请确认系统里已启用语音识别（或它正被其他应用占用），然后重试');
      return false;
    } on ListenFailedException catch (e) {
      _listening = false;
      // 插件把**平台侧的真实原因**放在 message 里，直接透出去 —— 别再吞成一句
      // 笼统的"无法启动"。像"未授权录音""语言不可用"都是用户能自己处理的。
      final msg = e.message?.trim() ?? '';
      onError?.call(msg.isNotEmpty ? msg : '无法启动语音识别');
      return false;
    } catch (e) {
      _listening = false;
      debugPrint('[VoiceInput] 启动识别失败: $e');
      // 带上真实异常类型：下次再出问题，提示里就有能定位的线索，
      // 而不是又一个无从下手的笼统文案。
      onError?.call('无法启动语音识别：${e.runtimeType}');
      return false;
    }
  }

  /// 挑一个**设备真正支持**的语言。
  ///
  /// 硬传 zh_CN 在没装中文识别包的设备上会让 listen 直接失败，用户只会看到
  /// "无法启动"。所以先查 `locales`：能用中文就用中文，退一步只匹配语言码
  /// （设备只有 zh_TW 时也总比失败强），都没有就返回 null 让插件用系统默认。
  ///
  /// 一个能工作的近似请求，好过一个必然失败的精确请求。
  Future<String?> _resolveLocale(String preferred) async {
    try {
      // 6.6.2 里 locales 是**方法**（返回 Future），不是 getter。
      final available = await _speech.locales();
      if (available.isEmpty) return preferred;
      String norm(String s) => s.replaceAll('-', '_').toLowerCase();
      final want = norm(preferred);
      for (final l in available) {
        if (norm(l.localeId) == want) return l.localeId;
      }
      final lang = want.split('_').first;
      for (final l in available) {
        if (norm(l.localeId).split('_').first == lang) return l.localeId;
      }
      return null;
    } catch (e) {
      debugPrint('[VoiceInput] 语言列表查询失败: $e');
      return preferred;
    }
  }

  /// 停止识别并保留已识别内容。
  Future<void> stop() async {
    if (!_listening) return;
    try {
      await _speech.stop();
    } catch (e) {
      debugPrint('[VoiceInput] 停止失败: $e');
    }
    _listening = false;
  }

  /// 取消识别并丢弃结果。
  Future<void> cancel() async {
    try {
      await _speech.cancel();
    } catch (_) {}
    _listening = false;
  }

  /// 默认识别语言：简体中文。
  static const String defaultLocaleId = 'zh_CN';

  @visibleForTesting
  void debugSetAvailable(bool v) {
    _available = v;
    _initialized = true;
  }

  /// 把单例恢复到"从未初始化"的状态。
  ///
  /// ⚠️ 只能重置**本服务**自己的状态，重置不了插件内部的。
  ///
  /// speech_to_text 的 `SpeechToText()` 是**工厂单例**
  /// （speech_to_text.dart:190 `factory SpeechToText() => _instance;`），
  /// 所以它内部的 `_initWorked` / `_listening` 是进程级的、外部换不掉也清不了。
  /// 写测试的人必须知道这一点：一个用例里成功 initialize 过之后，后面的用例就
  /// **不可能**再观察到 initialize 走到平台（插件会直接返回缓存值）。
  /// 这一条踩过坑 —— 曾经以为 `_speech = SpeechToText()` 是"换个新实例"，
  /// 实际是空操作，导致几个用例连环假通过。
  @visibleForTesting
  void debugReset() {
    _initialized = false;
    _available = false;
    _listening = false;
  }

  @visibleForTesting
  bool debugGetListening() => _listening;
}