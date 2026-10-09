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

  final SpeechToText _speech = SpeechToText();

  bool _initialized = false;
  bool _available = false;
  bool _listening = false;

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
  Future<bool> init({String localeId = defaultLocaleId}) async {
    if (_initialized) return _available;
    _initialized = true;
    try {
      _available = await _speech.initialize(
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
      );
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
    try {
      if (!await _speech.hasPermission) {
        return '未获得麦克风权限：请到「系统设置 → 应用 → DSH Mobile → 权限」中允许麦克风，然后回到这里再点一次';
      }
    } catch (e) {
      debugPrint('[VoiceInput] 权限查询失败: $e');
    }
    return '这台设备没有可用的语音识别服务（部分精简版系统不带识别引擎）';
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
    if (!_available && !await init(localeId: localeId)) {
      onError?.call(await unavailableReason());
      return false;
    }

    try {
      final started = await _speech.listen(
        listenOptions: SpeechListenOptions(
          // 语言放这里而不是 listen() 的顶层参数：后者已标记 deprecated。
          // 不指定的话部分 ROM 会拿英文模型去识别中文。
          localeId: localeId,
          // 流式：文字边说边出，不必等说完。
          partialResults: true,
          // dictation：说完一句自动停顿，把结果当成完整一段。
          listenMode: ListenMode.dictation,
          // 永久性错误（如权限被收回）时自动结束本次会话，避免反复重试。
          cancelOnError: true,
        ),
      );
      if (!started) {
        onError?.call(lastError ?? '无法启动语音识别');
      }
      _listening = started;
      return started;
    } catch (e) {
      debugPrint('[VoiceInput] 启动识别失败: $e');
      _listening = false;
      onError?.call('无法启动语音识别');
      return false;
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

  @visibleForTesting
  bool debugGetListening() => _listening;
}