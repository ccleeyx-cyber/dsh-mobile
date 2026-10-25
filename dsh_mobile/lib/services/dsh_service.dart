import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, X509Certificate;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:uuid/uuid.dart';
import '../models/server_config.dart';
import '../models/chat_message.dart';
import '../models/workspace.dart';
import '../models/approval_request.dart';
import '../models/dsh_settings.dart';
import '../models/permission_config.dart';
import '../models/user_question.dart';
import '../models/pending_attachment.dart';
import 'draft_store.dart';
import 'platform_services.dart';
import 'storage_service.dart';
import 'notification_service.dart';
import 'widget_bridge.dart';
import 'cert_trust.dart';
import '../models/audit_log.dart';
import '../models/persona.dart';
import '../models/gateway_features.dart';
import '../models/task_center.dart';
import '../models/bridge_extras.dart';
import '../models/remote_access.dart';

enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

/// 一条队列动作（edit / remove / steer）的结局。
///
/// 为什么不是 `bool`：失败有两种含义完全不同的情况，而它们的**用户可见后果相反**：
///
///   * [alreadyGone] —— 那条消息已被引擎领走（正常时序，比如你点「立即插话」的
///     同时这一轮刚好结束）。必须静默收敛，报错会把"本来就该发生的事"说成故障。
///   * [failed] —— 真的失败了（网络/权限/参数）。必须留着条目并说明原因。
///
/// 把两者压成一个 `false` 会让界面无论如何都要报一条红错，或者无论如何都不报
/// —— 两种都是错的。
enum QueueActionOutcome {
  /// 动作被服务端接受并已生效。
  applied,

  /// 目标条目已不在队列里（被引擎领取或被别处删掉），无需报错。
  alreadyGone,

  /// 真正的失败：条目应保持在队列里，界面要给出原因。
  failed,
}

class DshService extends ChangeNotifier {
  WebSocketChannel? _channel;
  Timer? _heartbeatTimer;
  Timer? _sessionPollTimer;

  /// Pong 看门狗：上次收到任何服务器帧（含 pong）的时间。
  ///
  /// 手机进后台后，系统/运营商 NAT 会把 WS 静默掐断 —— 写 ping 进死 socket
  /// **不报错**（数据进本地缓冲就返回），onError/onDone 都不触发，App 一直
  /// 以为"connected"。网关把提问帧发给死 socket，手机永远收不到 —— 这正是
  /// 「前台能收到、后台回来收不到」的根因。看门狗周期性检查：心跳已发出但
  /// 迟迟没有回帧，就主动判定连接半死并触发重连。
  DateTime? _lastServerFrameAt;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  String _lastError = '';
  ServerConfig? _currentConfig;
  final Uuid _uuid = const Uuid();

  /// 共享 HTTP 客户端（连接池 + keep-alive）。
  ///
  /// 每次 connect 按当前网关重建：HTTPS 时必须与 WSS 使用同一套 TOFU 证书
  /// 判定，否则会出现“WS 连上了、历史/发送却全部证书失败”。客户端同时绑定
  /// 连接代次，旧网关迟到的响应不会写进新网关的状态。
  http.Client _httpClient = http.Client();

  /// 连接代次：每次 connect/reconnect 自增。所有 socket 回调与 HTTP 客户端
  /// 都捕获当时的代次，切换网关后的旧回调直接丢弃。
  int _connectionGeneration = 0;

  bool _isGenerationCurrent(int generation) =>
      !_isDisposed && generation == _connectionGeneration;

  // Reconnection & Resilience State (F3.1, F3.2)
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _isExplicitlyDisconnected = false;
  bool _isDisposed = false;
  bool _isReconnecting = false;
  bool _isTokenInvalid = false;
  StreamSubscription? _channelSubscription;
  DateTime? _lastResumeCheck;

  static const int _baseReconnectDelayMs = 1000;
  static const int _maxReconnectDelayMs = 12000;
  static const double _backoffMultiplier = 1.5;
  static const int _maxJitterMs = 400;

  /// 重连尝试上限。
  ///
  /// 没有这个上限时，`_scheduleReconnect` 会以封顶 12s 的间隔**永久**重试：
  /// 网关半夜重启、笔记本合盖休眠、路由器改端口，手机都会在后台每隔 12 秒
  /// 醒一次试连，天亮时电量已经烧掉一小块，而用户对这一切一无所知。
  /// 超过上限就停在 `reconnectExhausted`，等下一次用户主动操作
  /// （切会话 / 下拉刷新 / App resume）时再 `_scheduleReconnect(immediate: true)`
  /// 重新武装 —— 见 [armReconnectRetry]。
  static const int _maxReconnectAttempts = 8;

  /// 心跳判定"半死连接"的两个阈值。
  ///
  /// 旧实现只看 `_lastServerFrameAt`（静默超时 45s）：一个"偶尔能收到几帧、
  /// 但实际投递不了"的连接永远不会触发它。改成**往返**判定：发出 ping 后
  /// 记 `_lastPingSentAt`，收到任意服务器帧就算应答；连续
  /// [_maxMissedPings] 个周期收不到应答才判死。
  static const int _maxMissedPings = 3;
  DateTime? _lastPingSentAt;
  int _missedPings = 0;

  /// 重连已耗尽：不再自动重试，直到用户主动操作重新武装。
  bool _reconnectExhausted = false;

  /// 供 UI 展示"重连已停止，需要手动重试"。
  /// （`reconnectAttempts` 的 getter 已存在于连接状态那一节，不重复声明。）
  bool get reconnectExhausted => _reconnectExhausted;

  // State
  List<Workspace> _workspaces = [];

  /// 会话列表的归档筛选模式，原样作为 `?archived=` 传给网关。
  /// 'exclude' = 未归档（默认，也是接入该功能之前的历史行为）
  /// 'only'    = 已归档
  /// 'include' = 全部
  String _archivedFilter = 'exclude';

  /// 网关是否真的执行了归档筛选。
  ///
  /// 判据是响应里的 `archivedMode` 回显是否等于我们请求的模式。旧网关会静默
  /// 忽略 `?archived=` 并照常返回未归档列表；若客户端不校验这一点，就会把那批
  /// 未归档会话标成「已归档」展示给用户 —— 那不是功能缺失，是主动误导。
  /// 所以宁可显式降级成「当前网关不支持」。
  bool _archivedFilterSupported = false;
  Workspace? _currentWorkspace;
  SessionMeta? _currentSession;
  List<ChatMessage> _messages = [];
  List<ApprovalRequest> _pendingApprovals = [];
  DshSettings? _settings;
  PermissionConfig _permissions = PermissionConfig();
  List<AuditLogItem> _auditLogs = [];
  List<AgentPersona> _personas = [];
  String? _activePersonaId;
  int _pingMs = -1;

  /// 提示词模板（quick replies），来自网关 /api/mobile/snippets。
  List<Snippet> _snippets = [];

  /// 当前会话最近一次回合的失败说明（网关 lastTurn / 实时 error 帧）。
  ///
  /// 非空时聊天页显示一条"上一轮以错误结束"横幅。存在的理由：错误只存在于
  /// 引擎的 turn/end.reason 里，若只弹一瞬、或只发一条后台通知，用户回到会话
  /// 时只会看到一条没有解释、停在半途的回答。
  TurnEndInfo? _lastTurnFailure;

  /// 用户已关闭失败横幅的会话（规范化 id），持久化到 SharedPreferences。
  final Set<String> _dismissedFailureSessions = {};
  bool _dismissedFailuresLoaded = false;
  bool _isLoadingHistory = false;

  // ---- 会话历史无限上翻（v1.15）[feat 2026-10-12] ----
  /// 是否还有更早历史可拉。
  bool _hasMoreHistory = false;

  /// 正在拉取更早历史（顶部转圈的信号源）。
  bool _isLoadingOlder = false;

  /// 下一页游标：当前最旧一条带 seq 消息的 seq。null = 还没有可翻页的锚点。
  int? _oldestHistorySeq;

  /// 已到会话开头（拉过一页且 hasMore=false）。
  bool _historyExhausted = false;
  bool get hasMoreHistory =>
      _hasMoreHistory && !_historyExhausted && _oldestHistorySeq != null;
  bool get isLoadingOlder => _isLoadingOlder;
  bool get historyExhausted => _historyExhausted;

  bool _isSending = false;
  bool _isCanceling = false;
  int _activeTurnSeq = 0;
  int _cancelledTurnSeq = 0;
  String? _currentSessionModel;
  int _sessionLoadSeq = 0;
  int _streamRevision = 0;

  // done 与随后的 session_status(false) 是同一回合的两个通知，只补拉一次。
  // generation 同时防止迟到的异步补拉串进已切换的会话或新回合。
  final Map<String, Future<void>> _finalResyncFlights = {};
  final Map<String, int> _sessionEpochs = {};
  final Map<String, int> _completedTurnEpochs = {};
  final Set<String> _remoteRunningSessions = {};

  String _syncKey(String sessionId) =>
      sessionId.replaceFirst(RegExp(r'^session-'), '').toLowerCase();

  int _sessionEpoch(String sessionId) => _sessionEpochs[_syncKey(sessionId)] ?? 0;

  void _advanceSessionEpoch(String sessionId) {
    final key = _syncKey(sessionId);
    _sessionEpochs[key] = _sessionEpoch(sessionId) + 1;
    _remoteRunningSessions.remove(key);
  }

  void _requestFinalResync(String sessionId) {
    final key = _syncKey(sessionId);
    if (_isDisposed || _finalResyncFlights.containsKey(key)) return;
    final epoch = _sessionEpoch(sessionId);
    _completedTurnEpochs[key] = epoch;
    // 微任务调度让紧随其后的 idle 与 done 共享同一次补拉，同时调用方
    // 可以同步完成收尾；开始之前若已被取消或来了新回合就不发旧请求。
    final future = Future<void>.microtask(() async {
      if (_isDisposed ||
          _sessionEpoch(sessionId) != epoch ||
          _completedTurnEpochs[key] != epoch) return;
      await (debugFinalResync ?? _resyncActiveSession)(sessionId);
    });
    _finalResyncFlights[key] = future;
    unawaited(future.catchError((Object error) {
      debugPrint('[DshService] 回合结束补拉失败: $error');
    }).whenComplete(() {
      if (identical(_finalResyncFlights[key], future)) {
        _finalResyncFlights.remove(key);
      }
      // 补拉返回前又来了新回合，不能把新回合误置为已完成。
      if (_sessionEpoch(sessionId) != epoch) {
        _completedTurnEpochs.remove(key);
      }
    }));
  }

  bool _acceptStreamFrame(String sessionId) {
    if (_isCanceling) return false;
    final key = _syncKey(sessionId);
    if (_remoteRunningSessions.contains(key)) {
      _completedTurnEpochs.remove(key);
      return true;
    }
    // 只按会话的完成代次拦截迟到帧。取消已由 _isCanceling 独占裁决，
    // 不能再拿全局 active/cancelled 序号挡住新会话或重连后的合法流。
    return _completedTurnEpochs[key] != _sessionEpoch(sessionId);
  }

  bool _beginRemoteStream(String sessionId) {
    final key = _syncKey(sessionId);
    if (_remoteRunningSessions.contains(key)) return false;
    _advanceSessionEpoch(sessionId);
    _completedTurnEpochs.remove(key);
    _remoteRunningSessions.add(key);
    return true;
  }

  /// 流式通知合并窗口（[fix 2026-10-25] 从 100ms 加大到 150ms）。
  ///
  /// 网关的 delta 帧可以密到每秒数百片，而 `notifyListeners()` 会让整个
  /// `ChatView`（含 AppBar / 横幅 / 输入框 / 搜索面板）重建一次。人眼在
  /// ~60fps 之上看不出区别，所以按窗口节流：窗口内的增量先进 buffer，
  /// 到边界才 flush + 通知一次。收尾的 flush 是立即的（不等满窗口），
  /// 否则最后一小段内容会迟一个窗口才显示。
  ///
  /// 100ms → 150ms：在长会话时 100ms 仍会触发 6-7 次/秒的全量重建，
  /// 而人眼对文字流的感知阈值在 100-200ms 之间，150ms 既流畅又减少 33% 重建。
  static const Duration _streamNotifyInterval = Duration(milliseconds: 150);
  DateTime? _lastStreamNotifyAt;
  Timer? _streamFlushTimer;

  /// 累积增量并（可能）延迟通知。由流式帧处理器调用。
  void _ingestStreamDelta(ChatMessage target,
      {String? content, String? thinking}) {
    target.appendStreamDelta(content: content, thinking: thinking);
    _scheduleStreamFlush();
  }

  void _scheduleStreamFlush() {
    final now = DateTime.now();
    final last = _lastStreamNotifyAt;
    if (last == null || now.difference(last) >= _streamNotifyInterval) {
      _flushStreamBuffers();
      return;
    }
    // 窗口内：只挂一个待执行的 flush，重复帧不叠加定时器。
    _streamFlushTimer ??=
        Timer(_streamNotifyInterval - now.difference(last), () {
      _streamFlushTimer = null;
      _lastStreamNotifyAt = null;
      _flushStreamBuffers();
    });
  }

  /// 立即 flush 所有流式消息的累积槽并通知。
  void _flushStreamBuffers() {
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    _lastStreamNotifyAt = DateTime.now();
    // flushStreamBuffers() 自身幂等（没有未成形增量时是 no-op），所以不必
    // 先判断"有没有内容要刷"再决定是否调用。
    for (final m in _messages) {
      if (m.isStreaming) m.flushStreamBuffers();
    }
    _streamRevision++;
    notifyListeners();
  }

  /// 等待本机用户回答的提问（patch 0003）。
  ///
  /// 只有订阅者才会收到这些，所以这里非空就意味着「agent 正在等一个人回答」，
  /// 而这个人应当就是拿着这台手机的人。切换会话时必须清空，否则会把上一个会话
  /// 的提问卡片显示到新会话里。
  final List<PendingQuestion> _pendingQuestions = [];

  /// 是否已向网关声明本机可以回答提问。断线重连后要重新订阅。
  bool _questionsSubscribed = false;

  /// 本次连接是否已经发过订阅请求（幂等用；每次 connect 重置）。
  bool _subscribeRequested = false;

  /// 最近一次提问失败/失效的原因，用于卡片上的提示。成功作答后清空。
  String? _lastQuestionError;

  /// 每个会话当前的 TODO 整表（`todo/write` 是整表替换，不是增量）。
  final Map<String, List<TodoItem>> _todos = {};

  /// 每个会话已知的图片附件元信息。**只有元数据，没有字节** —— 图片通过已鉴权
  /// 的附件路由按需拉取，所以这个 map 的内存占用与图片大小无关。
  final Map<String, Map<String, AttachmentRef>> _attachments = {};

  /// 按会话保存的输入草稿（v1.4.2 离线草稿）。
  ///
  /// 单例：main() 在 runApp 之前把 SharedPreferences 挂到 DraftStore.instance 上，
  /// 而这里是同一个实例。挂成两个实例会让"写进去的草稿读不出来"。
  /// 挂在 service 上（而不是 widget 上），是为了让「发送失败 / 离线」这条路径
  /// 也能决定草稿去留 —— 草稿规则取决于会话状态，不只是文本框内容。
  final DraftStore drafts = DraftStore.instance;

  /// 用于通知正文的会话名。找不到就用 id 前 8 位 —— 总比空白强。
  String _sessionDisplayTitle(String sessionId) {
    for (final ws in _workspaces) {
      for (final s in ws.sessions) {
        if (s.matchesSessionId(sessionId)) {
          final t = s.title.trim();
          return t.isEmpty
              ? '会话 ${sessionId.substring(0, sessionId.length.clamp(0, 8))}'
              : t;
        }
      }
    }
    final short = sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;
    return '会话 $short';
  }

  /// 事件通知（§4.2 推送通知）。单例，便于 UI 直接开关与查询状态。
  final NotificationService notifications = NotificationService.instance;

  DshService() {
    // [v1.35 / 2.3] 通知动作按钮 → 本服务。挂在构造函数里而不是 main()：
    // 这个回调要用本类持有的网关配置与 token，且测试里 new DshService() 也应
    // 处于同一条链路上。
    notifications.onNotificationAction = _handleNotificationAction;
  }

  /// [v1.35 / 3.5] 任何状态变化都顺带喂一次桌面小组件。
  ///
  /// 挂在 notifyListeners 而不是散落在十几个状态写入点：漏一个写入点，小组件
  /// 就会长期显示旧状态，而这种"看起来没事"的陈旧数据比不显示更危险。
  /// 节流与去重都在 WidgetBridge 里（5 秒 + 内容相同不重复推）。
  @override
  void notifyListeners() {
    super.notifyListeners();
    _pushWidgetSnapshot();
  }

  void _pushWidgetSnapshot() {
    try {
      final pct = _sessionStats?.contextFraction;
      final approvals = _pendingApprovals.length;
      final status = !isConnected ? '未连接' : (isSessionRunning ? '执行中' : '空闲');
      unawaited(WidgetBridge.push({
        'title': _currentSession?.title ?? '',
        'status': status,
        'context': pct == null ? '' : '${(pct * 100).round()}%',
        'approvals': approvals,
      }, force: approvals > 0));
    } catch (e) {
      // 小组件是增强能力，任何异常都不能影响主链路。
      debugPrint('[DshService] 小组件快照失败: $e');
    }
  }

  /// App 是否在前台。由 UI 层的生命周期回调维护。
  bool _isAppForeground = true;

  /// 由 UI 层在 AppLifecycleState 变化时调用。
  void setAppForeground(bool value) {
    if (_isAppForeground == value) return;
    _isAppForeground = value;
    // 回到前台就关掉后台保活：前台根本不需要它，留着只是白占一条常驻通知和
    // 一份电池。关不掉也不影响功能，只是通知会多一条。
    if (value) {
      notifications.disableBackground();
    }
  }

  /// 是否该发通知。
  ///
  /// **App 在前台时不发**：界面已经在展示这些事件，再弹一条系统通知等于把同一
  /// 件事在屏幕上说两遍，而且会打断正在进行的操作。通知真正要解决的是"用户不在
  /// 屏幕前、正在等结果"的场景。
  bool get shouldNotify => notifications.permissionGranted && !_isAppForeground;

  /// 是否需要为**某个会话的提问**发通知。
  ///
  /// 比 [shouldNotify] 宽一档：提问是"agent 已经停下来等人"，而它只在**当前
  /// 会话**的输入框上方渲染 —— 你在别的会话或别的 tab 时，即使 App 在前台，
  /// 屏幕上也没有任何提示。实测就是如此：提问到了网关，用户却既没看到卡片、
  /// 也没收到通知，只能以为任务还在跑。所以"不在眼前"也要提醒。
  bool shouldNotifyForSession(String? sessionId) {
    if (!notifications.permissionGranted) return false;
    if (!_isAppForeground) return true;
    final cur = _currentSession;
    if (cur == null) return true;
    if (sessionId == null || sessionId.isEmpty) return true;
    return !cur.matchesSessionId(sessionId);
  }

  /// 通知链路是否**真的**可用。
  ///
  /// 与 [shouldNotify] 的区别：那个只问"该不该发"，这个问"发了能不能到"。
  ///
  /// 加它的原因是一处真实误导：设置页原来只看权限就显示绿色的「后台通知已开启」，
  /// 而插件其实从未初始化成功（Android 上少了初始化设置会抛，异常被吞掉），
  /// 一条通知都发不出去 —— 用户看到的是"开关是开的，但就是没有通知"。
  bool get notificationsReady => notifications.ready;

  /// 通知链路最近一次失败的原因；正常时为 null。
  String? get notificationError => notifications.lastError;

  /// 是否已拉起前台保活服务（进程能在后台存活、连接不断）。
  bool get notificationBackgroundOn => notifications.backgroundEnabled;

  /// 开启后台通知能力（拉起前台保活服务）。
  ///
  /// 返回是否成功。**失败必须被如实告知用户**：Android 12+ 对后台启动前台服务
  /// 有限制，用户手动划掉通知也会让它失效。这个场景下"App 看起来能收通知但
  /// 其实收不到"是最糟的结果 —— 所以状态要暴露到 UI 上，而不是静默失败。
  Future<bool> enableBackgroundNotifications() =>
      notifications.enableBackground();

  /// 后台通知是否真的开着（UI 用来显示"后台通知已关闭"这类提示）。
  bool get backgroundNotificationsOn => notifications.backgroundEnabled;

  /// 通知权限是否拿到了。
  bool get notificationPermissionGranted => notifications.permissionGranted;

  /// 当前会话的草稿键。
  ///
  /// 尚未创建首个会话时用固定键 `__new__`：用户在会话产生之前打的字也不该
  /// 丢。网关返回真实 id 后草稿自然归属到新会话。
  String get _draftKey => _currentSession?.sessionId ?? '__new__';

  String get currentDraft => drafts.read(_draftKey);

  void updateDraft(String text) => drafts.write(_draftKey, text);

  /// 发出成功后清草稿。**只在成功分支里做** —— 见 [sendChatMessage] 的失败分支。
  /// （内部用发起时定格的草稿键，不再经由 _draftKey。）

  /// 离线 / 发送失败时把正文还回草稿。
  ///
  /// 这是草稿功能真正的价值：用户点发送 → 手机没信号 → 正文凭空消失，用户
  /// 只能凭记忆重打。所以失败时正文必须回到输入框。
  void restoreDraft(String text) => drafts.write(_draftKey, text);

  List<MapEntry<String, String>> get allDrafts => drafts.all();

  // Getters
  ConnectionStatus get status => _status;
  String get lastError => _lastError;
  void clearError() {
    _lastError = '';
    notifyListeners();
  }

  String get currentModel =>
      _currentSessionModel ??
      _settings?.currentModel ??
      'cn:deepseek-v4.1-flash';
  bool get isConnected => _status == ConnectionStatus.connected;
  ServerConfig? get currentConfig => _currentConfig;

  List<Workspace> get workspaces => _workspaces;

  /// 当前的归档筛选模式：'exclude' / 'only' / 'include'。
  String get archivedFilter => _archivedFilter;

  /// 网关是否支持归档筛选。为 false 时 UI 必须把筛选器藏起来或禁用，
  /// 而不是显示一个点了没反应的开关。
  bool get archivedFilterSupported => _archivedFilterSupported;

  /// 等待本机回答的提问，按到达顺序。非空即表示 agent 被卡在人机交互上。
  List<PendingQuestion> get pendingQuestions => _pendingQuestions;

  /// 当前会话（不是全部会话）的提问卡片。UI 应当只渲染这一份，否则会把
  /// 后台其它会话的提问显示到前台会话的输入框上方。
  List<PendingQuestion> get currentSessionQuestions {
    final s = _currentSession;
    if (s == null) return const [];
    return _pendingQuestions
        .where((q) => s.matchesSessionId(q.sessionId))
        .toList(growable: false);
  }

  /// 最近一次提问失败/失效原因；无则 null。
  String? get lastQuestionError => _lastQuestionError;

  /// 是否已订阅提问。重连后需要重新订阅，UI 可据此提示「提问功能未就绪」。
  bool get questionsSubscribed => _questionsSubscribed;

  /// 当前会话的 TODO 整表；没有则空列表。
  List<TodoItem> get currentTodos {
    final s = _currentSession;
    if (s == null) return const [];
    return _todos[s.sessionId.replaceFirst(RegExp(r'^session-'), '')] ??
        const [];
  }

  /// 当前会话的图片附件元信息（仅元数据，不含字节）。
  List<AttachmentRef> get currentAttachments {
    final s = _currentSession;
    if (s == null) return const [];
    final m = _attachments[s.sessionId.replaceFirst(RegExp(r'^session-'), '')];
    return m == null ? const [] : m.values.toList(growable: false);
  }

  Workspace? get currentWorkspace => _currentWorkspace;
  SessionMeta? get currentSession => _currentSession;

  /// 当前会话**实际所属**的工作区；判定不出来时为 null。
  ///
  /// 刻意不用 [currentWorkspace] 顶替：`SessionMeta` 身上没有 workspaceId，归属
  /// 只能按 `Workspace.sessions` 的成员关系反查。而 `openSessionById()`（搜索命中、
  /// 通知/深链接跳转）会在找不到所属工作区时构造一个最小 SessionMeta 直接进 ——
  /// 那种情况下把"上次选中的工作区"的名字显示在顶栏，就是**主动误导**：不同工作区
  /// 完全可以有同名会话，用户没有任何办法察觉自己看错了。返回 null 让 UI 隐藏这一
  /// 行，比给一个可能是错的答案好。
  Workspace? get workspaceOfCurrentSession {
    final sid = _currentSession?.sessionId;
    if (sid == null || sid.isEmpty) return null;
    for (final ws in _workspaces) {
      for (final s in ws.sessions) {
        if (s.matchesSessionId(sid)) return ws;
      }
    }
    return null;
  }

  List<ChatMessage> get messages => _messages;
  List<ApprovalRequest> get pendingApprovals => _pendingApprovals;
  DshSettings? get settings => _settings;
  PermissionConfig get permissions => _permissions;
  List<AuditLogItem> get auditLogs => _auditLogs;

  /// 当前会话最近一次回合的失败说明；无失败时为 null。
  TurnEndInfo? get lastTurnFailure => _lastTurnFailure;

  /// 用户已知悉该失败（横幅上的关闭按钮）：记进持久化的抑制表，重启后也不再弹，
  /// 直到该会话有新的一轮结束（那时旧失败已经过时，账就该清了）。
  void dismissTurnFailure() {
    final sid = _currentSession?.sessionId;
    if (sid != null) {
      _dismissedFailureSessions.add(_failureKey(sid));
      unawaited(StorageService.saveDismissedTurnFailures(
          _dismissedFailureSessions.toList()));
    }
    if (_lastTurnFailure == null) return;
    _lastTurnFailure = null;
    notifyListeners();
  }

  String _failureKey(String sessionId) =>
      sessionId.replaceAll('session-', '').toLowerCase();

  /// 唯一设置失败横幅的入口：被抑制过的会话不再重复弹同一条。
  void _applyTurnFailure(TurnEndInfo? info) {
    final sid = _currentSession?.sessionId;
    if (info == null || !info.failed) {
      _lastTurnFailure = null;
      return;
    }
    if (sid != null && _dismissedFailureSessions.contains(_failureKey(sid))) {
      _lastTurnFailure = null;
      return;
    }
    _lastTurnFailure = info;
  }

  List<AgentPersona> get personas => _personas;
  List<Snippet> get snippets => _snippets;
  String? get activePersonaId => _activePersonaId;
  int get pingMs => _pingMs;
  bool get isLoadingHistory => _isLoadingHistory;

  /// 切会话/新建会话时重置上翻分页状态。
  void _resetHistoryPaging() {
    _hasMoreHistory = false;
    _isLoadingOlder = false;
    _oldestHistorySeq = null;
    _historyExhausted = false;
  }

  /// 会话消息的**进程内缓存**（[fix 2026-10-17 用户反馈]）。
  ///
  /// 痛点：每次打开会话都要重拉整个会话（`ensureFullHistory` 实测 10 轮 / 7 页
  /// / 1.58 MB），来回切几次就会明显卡。缓存让"再打开一次"当帧就有内容。
  ///
  /// 三条纪律：
  /// 1. 缓存只用于**首帧渲染**，不做真相：网络结果回来后整体覆盖缓存，
  ///    并按历史锚点继续补页（见 selectSession / ensureFullHistory 的写回）。
  /// 2. 上限 [historyCacheLimit] 条会话（LRU），避免长会话长期驻留把内存吃满。
  /// 3. 会话被删除 / 会话内消息被清空时主动剔除（见 createNewSession 与
  ///    session_deleted 分支），否则会拿到一条已不存在的会话的旧内容。
  static const int historyCacheLimit = 6;
  final Map<String, _SessionHistorySnapshot> _historyCache = {};

  /// 写回缓存：只在"这份消息比缓存更完整"时更新（条数更多，或已翻到头）。
  void _cacheSessionHistory(String sessionId, bool exhausted) {
    if (sessionId.isEmpty || _messages.isEmpty) return;
    final existing = _historyCache[sessionId];
    if (existing != null &&
        existing.messages.length >= _messages.length &&
        existing.exhausted) {
      return;
    }
    // LRU：先删旧的再插入，让最近使用的留在末尾。
    _historyCache.remove(sessionId);
    if (_historyCache.length >= historyCacheLimit) {
      _historyCache.remove(_historyCache.keys.first);
    }
    _historyCache[sessionId] = _SessionHistorySnapshot(
      messages: List<ChatMessage>.of(_messages),
      exhausted: exhausted,
      cachedAt: DateTime.now(),
    );
  }

  /// 会话消息被外部改动/删除时清掉它的缓存条目。
  void _dropHistoryCache(String sessionId) {
    _historyCache.remove(sessionId);
  }

  /// 从已加载的消息里重算分页锚点（进入会话后调用一次）。
  void _recomputeHistoryAnchor() {
    for (final m in _messages) {
      if (m.seq != null && m.seq! < 900000) {
        _oldestHistorySeq = m.seq;
        break;
      }
    }
  }

  /// [feat 2026-10-12] 拉取更早一页历史并插入列表头部。
  ///
  /// 去重：网关页与实时流/轮询尾部可能重叠（边界 seq 同时出现在两边），按
  /// 「seq 相同」或「id 相同」丢弃已有消息；没有 seq 的页消息按内容+角色去重。
  ///
  /// 锚点推进：即使本页没有任何可渲染消息（全是注入上下文被过滤），也用网关
  /// 返回的 oldestSeq 前进游标，否则会永远卡在同一页。
  Future<void> loadOlderHistory() async {
    if (_isLoadingOlder || _historyExhausted) return;
    final cfg = _currentConfig;
    final session = _currentSession;
    if (cfg == null || session == null) return;
    final sessionId = session.sessionId;
    final anchor = _oldestHistorySeq;
    if (anchor == null) return;

    _isLoadingOlder = true;
    notifyListeners();
    try {
      final uri =
          Uri.parse('${cfg.httpBaseUrl}/api/mobile/sessions/history/page')
              .replace(queryParameters: {
        'sessionId': sessionId,
        'beforeSeq': '$anchor',
        'max': '60',
      });
      final res = await _httpClient
          .get(uri, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return;
      if (_currentSession == null ||
          !_currentSession!.matchesSessionId(sessionId)) return;
      if (res.statusCode != 200) return;

      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final payload = (data['data'] ?? data) as Map<String, dynamic>?;
      if (payload == null) return;
      final rawPage = payload['messages'] as List<dynamic>? ?? [];
      final hasMore = payload['hasMore'] == true;
      final oldestSeqRaw = payload['oldestSeq'];
      final pageOldest = oldestSeqRaw is num ? oldestSeqRaw.toInt() : null;

      // 去重身份集：已有消息的 seq 与 id。
      final knownSeqs = _messages.map((m) => m.seq).whereType<int>().toSet();
      final knownIds = _messages.map((m) => m.id).toSet();
      final older = <ChatMessage>[];
      for (final m in rawPage) {
        if (m is! Map) continue;
        final raw = Map<String, dynamic>.from(m);
        final seq = raw['seq'] is int
            ? raw['seq'] as int
            : (raw['seq'] is num ? (raw['seq'] as num).toInt() : null);
        final id = raw['id'] as String?;
        if ((seq != null && knownSeqs.contains(seq)) ||
            (id != null && knownIds.contains(id))) {
          continue;
        }
        final msg = ChatMessage.fromWire(raw, newId: _uuid.v4);
        knownSeqs.add(seq ?? -1);
        knownIds.add(msg.id);
        older.add(msg);
      }

      // 锚点：优先用本页最旧一条"真实消息"的 seq；退化用网关的 oldestSeq
      //（它按事件计，一定 <= 任何消息 seq，保证前进）。
      int? nextAnchor;
      for (final m in older) {
        if (m.seq != null && m.seq! < 900000) {
          nextAnchor = m.seq;
          break;
        }
      }
      nextAnchor ??=
          (pageOldest != null && pageOldest < anchor) ? pageOldest : null;

      if (!hasMore || nextAnchor == null) {
        _historyExhausted = true;
        _hasMoreHistory = false;
        if (older.isNotEmpty) {
          _messages.insertAll(0, older);
          _streamRevision++;
        }
        notifyListeners();
        return;
      }

      _messages.insertAll(0, older);
      _oldestHistorySeq = nextAnchor;
      _hasMoreHistory = hasMore;
      _streamRevision++;
    } catch (e) {
      debugPrint('[DshService] loadOlderHistory error: $e');
      // 静默失败：一次翻页失败不该打断用户正在看的会话。
    } finally {
      if (_currentSession != null &&
          _currentSession!.matchesSessionId(sessionId)) {
        _isLoadingOlder = false;
        notifyListeners();
      }
    }
  }

  /// 当前消息列表里的**真人**回合数（排除注入通知与上下文/记忆块）。
  ///
  /// 只用于"首屏够不够"的判断，不用于显示 —— 显示整会话轮数的是引擎的
  /// `sessionStats` 投影（见 `SessionStats.turns`）。
  int get _humanTurnCount => _messages
      .where((m) => m.isUser && !m.isHarnessNotice && !m.isContextOrMemory)
      .length;

  /// 首屏之后把**整个会话**的历史补齐（v1.26.0）。
  ///
  /// **为什么不再"补到 N 轮就停"**：1.25.0 设的门槛是 5 个真人回话，而真实会话里
  /// 一页常常一条真人消息都不含（整页都是工具调用记录）。实测一个 10 轮 / 3600 seq 的
  /// 会话要 **7 页 / 1.58 MB** 才完整 —— 门槛卡在 4 页时用户看到的还是"只有两三轮"。
  /// 所以这个门槛本身就是错的：用户要的是"所有记录"。
  ///
  /// 现在的策略：一直翻到引擎说 `hasMore=false`，每页结束通知一次界面（列表可见地
  /// 长出来），并且：
  ///   * 会话切走立刻停（`_sessionLoadSeq` 变了就不再为旧会话拉）；
  ///   * 某页没有新增消息立刻停（网关异常时不死循环）；
  ///   * 页数上限 [maxPages] 是**安全阀**，不是产品门槛（实测 7 页，40 页到不了）。
  ///
  /// 每页 200~300 KB，局域网下 7 页约 1~2 秒；列表按需构建，补进来的旧消息不会一次性
  /// 全部布局。
  Future<void> ensureFullHistory({int maxPages = 40}) async {
    final seq = _sessionLoadSeq;
    final sessionId = _currentSession?.sessionId;
    var pages = 0;
    while (hasMoreHistory && pages < maxPages) {
      final before = _messages.length;
      await loadOlderHistory();
      if (seq != _sessionLoadSeq) return; // 会话已切走
      pages++;
      if (_messages.length <= before) break; // 没有进展
      if (pages > 0) notifyListeners();
    }
    // [fix 2026-10-25] 首次加载也必须写回缓存。
    //
    // 旧实现只在“已有缓存”分支写回，首次打开走完整补页后什么都没留下，
    // 于是第二次打开仍然从零重拉全部历史 —— 这正是缓存本来要解决的问题。
    // 页数上限/网络失败时也可以缓存：exhausted 标志会如实告诉下次还要不要补。
    if (seq == _sessionLoadSeq &&
        sessionId != null &&
        _currentSession?.matchesSessionId(sessionId) == true) {
      _cacheSessionHistory(sessionId, _historyExhausted);
    }
  }

  bool get isSending => _isSending;
  bool get isCanceling => _isCanceling;

  /// 当前会话是否在跑（本机发起的或别的客户端发起的都算）。
  ///
  /// 输入栏据此切换"发送 → 排队/插话"，队列行的"插话"按钮也据此置灰。
  /// 只用 _isSending 判断会漏掉另一种常见情形：会话是电脑端发起、手机只是
  /// 在看 —— 那时同样不能直接发一条新回合。
  bool get isSessionRunning =>
      _isSending || (_currentSession?.isRunning ?? false);
  int get streamRevision => _streamRevision;

  // Connection Status Helpers & Reconnect Info (F3.1, F3.4)
  int get reconnectAttempts => _reconnectAttempts;
  bool get isReconnecting => _isReconnecting;
  bool get isConnecting => _status == ConnectionStatus.connecting;
  bool get isDisconnected => _status == ConnectionStatus.disconnected;
  bool get hasError => _status == ConnectionStatus.error;
  bool get isTokenInvalid => _isTokenInvalid;
  bool get hasAuthError => _isTokenInvalid;

  /// 正在发送的那一轮所属的**会话 id**（[fix 2026-10-17]）。
  ///
  /// `_isSending` 是全局标志，不看它属于哪个会话 —— 而 UI 的停止键 / 队列
  /// 入口必须只在本会话真的在跑时出现。此前 chat_view 拿
  /// `dsh.currentSession?.sessionId` 与自己比较，恒真，别的会话在跑时本会话
  /// 也会点亮停止键。所有把 `_isSending` 置 true 的写入点必须同步记录这里；
  /// 置 false 的路径由 `_isSending = false` 统一清空（见 `_setSending`）。
  String? _sendingSessionId;
  String? get sendingSessionId => _sendingSessionId;

  /// 统一的发送状态写入点：`running=true` 时记录会话归属，false 时清空。
  void _setSending(bool running, {String? sessionId}) {
    _isSending = running;
    if (running) {
      _sendingSessionId = sessionId;
    } else {
      _sendingSessionId = null;
    }
  }

  void handleAuthFailure(String reason) {
    _isTokenInvalid = true;
    _lastError = reason;
    _status = ConnectionStatus.error;
    _isReconnecting = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _sessionPollTimer?.cancel();
    _sessionPollTimer = null;
    _stopHeartbeat();
    // [fix 2026-10-17] 认证失败后旧 socket 此前一直活着并继续喂
    // _handleRawMessage（401 帧可反复触发 handleAuthFailure），泄漏到下一次
    // connect/disconnect。做与 disconnect 等价的清理。
    _channelSubscription?.cancel();
    _channelSubscription = null;
    try {
      _channel?.sink.close(ws_status.normalClosure);
    } catch (_) {}
    _channel = null;
    notifyListeners();
  }

  /// 最近一次 401 是否因「电脑端已移除此设备」。
  ///
  /// [feat 2026-10-12] 网关在设备被撤销后的 401 响应体带 device_revoked: true，
  /// 客户端凭它区分「token 输错了」与「被电脑端踢掉了」——前者提示换 token 即可，
  /// 后者要清本地凭据并回到配置页重新配对。
  bool _lastAuthFailureWasRevoked = false;
  bool get lastAuthFailureWasDeviceRevoked => _lastAuthFailureWasRevoked;

  /// 处理被电脑端撤销：清除本地凭据（token/authCode）、停掉重连与心跳、
  /// 关闭 socket。保留 host/port 与网关名，用户重新扫码/输入配对码时少打字。
  Future<void> handleDeviceRevoked() async {
    _lastAuthFailureWasRevoked = true;
    final cfg = _currentConfig;
    if (cfg != null) {
      cfg.token = '';
      cfg.authCode = '';
      try {
        await StorageService.saveConfig(cfg);
      } catch (e) {
        debugPrint('[DshService] 清除被撤销设备的凭据失败: $e');
      }
    }
    handleAuthFailure('电脑端已移除此设备');
    _isExplicitlyDisconnected = true;
    // [fix 2026-10-17] 此前用 goingAway(1001) —— 它是保留码，底层同步抛异常
    //（见 _cleanTeardownSocket 的注释），close 从未真正发生。改 normalClosure
    //（handleAuthFailure 里已经关过，这里只是兜底再试一次，幂等）。
    try {
      await _channel?.sink.close(ws_status.normalClosure);
    } catch (_) {}
    _channel = null;
  }

  void clearAuthError() {
    _isTokenInvalid = false;
    _lastError = '';
    _lastAuthFailureWasRevoked = false;
    notifyListeners();
  }

  bool _checkResponseAuth(http.Response res) {
    // 只有 401 是鉴权失败。
    //
    // [fix 2026-10-21] 这里原来把 403 也当鉴权失败（`401 || 403`），后果比措辞不
    // 准严重得多：网关**从不**用 403 表达鉴权问题（它自己的拒绝一律 401，见
    // lib/core.mjs 的 authenticateRequest 与 index.js 的统一鉴权门），而 403 是
    // 它对**资源级**拒绝的答复。于是下面三种正常拒绝都会被读成"Token 已失效"，
    // 进而清凭据、把用户踢回配对页，并给出一条完全错误的原因：
    //   * 点开一个不在本会话交付物清单里的文件（交付物下载/预览）
    //   * 删除内置审批预设（features/extensions 都回 403）
    //   * 读写会话工作区之外的路径（mapWorkspaceFileError → 403）
    // 调用方本来就会把非 200 的 body['error'] 显示出来，所以放开 403 之后
    // 用户看到的是"该文件不在清单中"这类真话，而不是被登出。
    if (res.statusCode == 401) {
      // [feat 2026-10-12] 401 + device_revoked：电脑端把这台手机踢了。
      // 清凭据 + 停连接；UI 层据 lastAuthFailureWasDeviceRevoked 弹提示并跳配置页。
      try {
        final body = jsonDecode(utf8.decode(res.bodyBytes));
        if (body is Map &&
            (body['device_revoked'] == true ||
                body['code2'] == 'device_revoked')) {
          unawaited(handleDeviceRevoked());
          return true;
        }
      } catch (_) {/* 非 JSON 401 走通用分支 */}
      handleAuthFailure('Token已失效或无访问权限 (HTTP ${res.statusCode})');
      return true;
    }
    return false;
  }

  String _coerceToolInput(dynamic raw) {
    if (raw == null) return '';
    if (raw is String) return raw;
    if (raw is Map || raw is List) {
      try {
        return const JsonEncoder.withIndent('  ').convert(raw);
      } catch (_) {
        return raw.toString();
      }
    }
    return raw.toString();
  }

  /// 手动触发网络重连 (F3.4)
  Future<void> retryConnection() async {
    if (_currentConfig == null) return;
    _lastError = '';
    _isTokenInvalid = false;
    // [fix 2026-10-17] 必须先解除"重连已耗尽"的闸：_scheduleReconnect 入口在
    // _reconnectExhausted 时直接早退，只重置计数器点不动耗尽后的重试 ——
    // armReconnectRetry 语义就是"人又碰了一下手机"，这里正是它的调用点。
    armReconnectRetry();
    _reconnectAttempts = 0;
    _scheduleReconnect(immediate: true);
  }

  // Headers for HTTP
  Map<String, String> get _authHeaders {
    final tokenVal = _currentConfig?.effectiveToken ?? '';
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $tokenVal',
      'x-dsh-token': tokenVal,
      'x-auth-code': tokenVal,
      // 不再发 'Connection: close'：共享 _httpClient 靠 keep-alive 复用
      // 连接，逐请求 close 会把它退化回每请求一握手的旧行为。
    };
  }

  // Test Connection
  Future<bool> testConnection(ServerConfig config) async {
    try {
      final tokenVal = config.effectiveToken;
      final headers = {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $tokenVal',
        'x-dsh-token': tokenVal,
        'x-auth-code': tokenVal,
      };

      final testEndpoints = [
        '${config.httpBaseUrl}/api/mobile/ping',
        '${config.httpBaseUrl}/api/mobile/health',
        '${config.httpBaseUrl}/health',
        '${config.httpBaseUrl}/api/mobile/workspaces',
        '${config.httpBaseUrl}/api/mobile/settings',
      ];

      // 测试连接也必须走与正式连接相同的证书策略，否则自签 HTTPS 会在这里
      // 被判成“不可达”，而用户保存后 WSS 却又能连上。
      final testClient = await _buildHttpClientFor(config);
      try {
        // 并行探测：旧实现串行试 5 个端点，每个 4s 超时 —— 全失败要等 20s。
        final futures = testEndpoints.map((endpoint) async {
          try {
            final res = await testClient
                .get(Uri.parse(endpoint), headers: headers)
                .timeout(const Duration(seconds: 4));
            return res;
          } catch (_) {
            return null;
          }
        });
        final responses = await Future.wait(futures);

        if (_pendingCertChange != null) {
          _lastError = '网关证书指纹已变化，连接被阻止；请确认新指纹后重试';
          return false;
        }
        for (final res in responses) {
          if (res == null) continue;
          if (res.statusCode == 401 || res.statusCode == 403) {
            // [feat 2026-10-12] testConnection 也可能撞上被撤销设备的 401：
            // 识别 device_revoked 并清凭据，让 UI 能引导回配对页。
            if (res.statusCode == 401) {
              try {
                final errBody = jsonDecode(utf8.decode(res.bodyBytes));
                if (errBody is Map &&
                    (errBody['device_revoked'] == true ||
                        errBody['code2'] == 'device_revoked')) {
                  await handleDeviceRevoked();
                  _lastError = '电脑端已移除此设备，请重新配对';
                  return false;
                }
              } catch (_) {}
            }
            _lastError = '认证失败 (HTTP ${res.statusCode}): 请核对访问令牌或授权码';
            return false;
          }
        }
        for (final res in responses) {
          if (res == null) continue;
          if (res.statusCode >= 200 && res.statusCode < 300) {
            try {
              final body = jsonDecode(res.body);
              if (body is Map &&
                  (body['authenticated'] == false || body['code'] == 401)) {
                _lastError = '认证失败: 授权码错误或未提供有效令牌';
                return false;
              }
            } catch (_) {}
            return true;
          }
        }
        _lastError = '网关无响应或不可达';
        return false;
      } finally {
        testClient.close();
      }
    } catch (e) {
      _lastError = e.toString();
      return false;
    }
  }

  // Connect
  Future<void> connect(ServerConfig config) async {
    final previous = _currentConfig;
    final switchingGateway = previous == null ||
        previous.id != config.id ||
        previous.cleanHost != config.cleanHost ||
        previous.cleanPort != config.cleanPort;
    _currentConfig = config;
    final generation = ++_connectionGeneration;
    // 旧网关发起的请求/轮询不能作为新网关的“在途请求”被复用。
    _fetchWorkspacesInFlight = null;
    _sessionPollInFlight = false;
    if (switchingGateway) {
      // 会话、工作区、审批都属于上一台网关；不清会把 A 的数据画到 B 上。
      _sessionLoadSeq++;
      _workspaces = [];
      _currentWorkspace = null;
      _currentSession = null;
      _messages = [];
      _pendingApprovals = [];
      _pendingQuestions.clear();
      _todos.clear();
      _attachments.clear();
      _historyCache.clear();
      _settings = null;
      _auditLogs = [];
      _personas = [];
      _snippets = [];
      _resetHistoryPaging();
      _resetSessionInsights();
    }
    // 加载"已关闭失败横幅"的账本（一次）。放在 connect 而不是构造里：构造是同步
    // 的，而 SharedPreferences 是异步的；connect 是每条使用路径的必经入口。
    if (!_dismissedFailuresLoaded) {
      _dismissedFailuresLoaded = true;
      try {
        final saved = await StorageService.loadDismissedTurnFailures();
        _dismissedFailureSessions
          ..clear()
          ..addAll(saved);
      } catch (e) {
        debugPrint('[DshService] 加载失败横幅抑制表失败: $e');
      }
    }
    _isExplicitlyDisconnected = false;
    _isTokenInvalid = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    // 主动连接 = 重新武装。上一轮可能已耗尽自动重试上限，此刻用户明确要求
    // 连一次，没有理由继续端着（见 _maxReconnectAttempts 的注释）。
    _reconnectExhausted = false;

    _status = ConnectionStatus.connecting;
    // 新连接：允许重新发一次订阅。
    _subscribeRequested = false;
    notifyListeners();

    try {
      await _cleanTeardownSocket();
      if (!_isGenerationCurrent(generation)) return;

      _certGatewayId = _gatewayIdOf(config);
      _pendingCertChange = null;
      // REST 与 WSS 必须使用同一份证书信任策略。
      await _replaceHttpClient(config, generation);
      if (!_isGenerationCurrent(generation)) return;

      // [v1.35 / 1.4] WSS 时先装载 TOFU 信任视图（握手回调是同步的，不能
      // 在里面读存储层）；HTTP 直连不需要，保持零开销。
      final tlsClient =
          config.effectiveUseHttps ? await _prepareTlsClient(config) : null;
      if (!_isGenerationCurrent(generation)) return;

      final uri = Uri.parse(config.wsUrl);
      // 鉴权走 header（不再放 URL query —— 代理日志会记录完整 URL）。
      // IOWebSocketChannel 是唯一带 headers 的 connect 变体；顶层
      // WebSocketChannel.connect 的签名没有 headers。旧网关不认这些
      // header 会在 upgrade 时 401，客户端走 handleAuthFailure 的既有
      // 路径提示换 token，不会静默失败。
      final channel = IOWebSocketChannel.connect(
        uri,
        // [fix 2026-10-17] SYN 黑洞时没有它要挂到 OS 级 TCP 超时（约 2 分钟）。
        // 与 _executeReconnect 对称。
        connectTimeout: const Duration(seconds: 10),
        customClient: tlsClient,
        headers: {
          'Authorization': 'Bearer ${config.effectiveToken}',
          'x-dsh-token': config.effectiveToken,
        },
      );
      _channel = channel;

      _channelSubscription = channel.stream.listen(
        (data) {
          if (!_isGenerationCurrent(generation) ||
              !identical(_channel, channel)) return;
          // 兜底：正常情况下 ready 已经把状态翻好了，这里再兜一次是为了应对
          // "消息比 ready 先到"的实现细节差异。
          _onSocketReady();
          _handleRawMessage(data);
        },
        onError: (error) {
          if (!_isGenerationCurrent(generation) ||
              !identical(_channel, channel)) return;
          debugPrint('[DshService] WebSocket error: $error');
          // [v1.35 / 1.4] 指纹不一致会以握手失败的形式冒到这里；它的处理与
          // 普通网络错误完全不同（不重连、要用户确认），必须最先分流。
          final certChange = _pendingCertChange;
          if (certChange != null) {
            _handleCertMismatch(certChange);
            return;
          }
          final errStr = error.toString().toLowerCase();
          if (errStr.contains('401') || errStr.contains('unauthorized')) {
            handleAuthFailure('WebSocket认证失败: 访问令牌无效');
            return;
          }
          _status = ConnectionStatus.error;
          _lastError = error.toString();
          _isReconnecting = false;
          _stopHeartbeat();
          notifyListeners();
          _scheduleReconnect();
        },
        onDone: () {
          if (!_isGenerationCurrent(generation) ||
              !identical(_channel, channel)) return;
          debugPrint('[DshService] WebSocket onDone closed');
          final code = channel.closeCode;
          if (code == 4001 || code == 4401 || code == 1008) {
            handleAuthFailure('连接已关闭: 认证失败或Token过期 (Code: $code)');
            return;
          }
          _status = ConnectionStatus.disconnected;
          _isReconnecting = false;
          _stopHeartbeat();
          notifyListeners();
          _scheduleReconnect();
        },
      );

      _startHeartbeat();

      // 等连接**真正打开**再标记 connected 并订阅。
      //
      // 为什么必须显式等 ready，而不能像原来那样"等第一条消息再翻状态"：
      // 网关那边是"收到订阅才发消息"，而 App 这边是"收到消息才订阅" —— 两边
      // 互等就是死锁，提问一个都到不了手机。实测就是这个表现：连接建立了、
      // 没有任何报错，但服务器一条 subscribe_questions 都没收到。
      try {
        await channel.ready;
        if (!_isGenerationCurrent(generation) ||
            !identical(_channel, channel)) {
          return;
        }
        _onSocketReady();
      } catch (e) {
        // ready 失败会走 stream 的 onError/onDone，由它们负责重连；这里只记录，
        // 不重复触发，避免两条路径同时排重连。
        debugPrint('[DshService] WS ready 失败: $e');
      }

      // Fetch initial data。每次 await 后都核对代次，避免旧网关的初始化流程
      // 在新连接建立后继续覆盖界面。
      for (final fetch in <Future<void> Function()>[
        () => fetchWorkspaces(),
        () => fetchSettings(),
        () => fetchApprovals(),
        () => fetchPermissions(),
        () => fetchAuditLogs(),
        () => fetchPersonas(),
        () => fetchSnippets(),
        () => fetchPushConfig(),
        () async {
          await measurePing();
        },
      ]) {
        if (!_isGenerationCurrent(generation)) return;
        await fetch();
      }
    } catch (e) {
      if (!_isGenerationCurrent(generation)) return;
      _status = ConnectionStatus.error;
      _lastError = e.toString();
      _isReconnecting = false;
      notifyListeners();
      _scheduleReconnect();
    }
  }

  // Workspaces Management
  //
  // in-flight 去重：工作区 tab 每 3 秒触发一次，而一次请求超时上限 8 秒 ——
  // 弱网下请求叠加堆积（最多 3 个并发打同一个网关）。这里把并发的调用折叠成
  // 同一个 Future：第二个调用者 await 到的是第一个调用的结果。
  Future<void>? _fetchWorkspacesInFlight;
  Future<void> fetchWorkspaces() {
    if (_currentConfig == null) return Future.value();
    final existing = _fetchWorkspacesInFlight;
    if (existing != null) return existing;
    final fut = _fetchWorkspacesInner();
    _fetchWorkspacesInFlight = fut;
    // 完成后清槽。比较的是槽位当前值（不是捕获 fut 的自引用——那在赋值前
    // 读不到），后到的调用者已拿走这个 Future，清槽不影响它们等待完成。
    unawaited(fut.whenComplete(() {
      if (_fetchWorkspacesInFlight == fut) {
        _fetchWorkspacesInFlight = null;
      }
    }));
    return fut;
  }

  Future<void> _fetchWorkspacesInner() async {
    try {
      // 归档过滤交给网关做，而不是拉全量回来在客户端筛：本机 2322 个会话里有
      // 1338 个已归档，全量传输会把一个定时轮询的响应放大到 2.4 倍。
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/workspaces')
              .replace(queryParameters: {'archived': _archivedFilter});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 8));
      if (_checkResponseAuth(res)) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final list = data['workspaces'] as List<dynamic>? ?? [];
        _workspaces = list
            .map((w) => Workspace.fromJson(w as Map<String, dynamic>))
            .toList();

        // 能力探测：只有网关如实回显了我们请求的模式，才算筛选真的生效了。
        _archivedFilterSupported =
            data['archivedMode']?.toString() == _archivedFilter;

        // 归档筛选只影响列表展示，不应该动用户正在看的会话。所以只有默认的
        // exclude 模式才做「当前工作区/会话」对账 —— 否则切一次筛选就会把正在
        // 读的会话顶掉，甚至把一条未归档会话塞进已归档列表里。
        if (_archivedFilter == 'exclude') {
          if (_currentWorkspace != null && _workspaces.isNotEmpty) {
            final matched = _workspaces.firstWhere(
              (w) => w.workspaceId == _currentWorkspace!.workspaceId,
              orElse: () => _workspaces.first,
            );
            _currentWorkspace = matched;
            // Preserve unsaved/active new session in the workspace session list
            final cur = _currentSession;
            if (cur != null &&
                !matched.sessions
                    .any((s) => s.matchesSessionId(cur.sessionId))) {
              matched.sessions.insert(0, cur);
            }
          } else if (_workspaces.isNotEmpty) {
            _currentWorkspace = _workspaces.first;
            if (_currentWorkspace!.sessions.isNotEmpty &&
                _currentSession == null) {
              await selectSession(_currentWorkspace!.sessions.first);
            }
          }
          // _workspaces 为空时（workspace.json 缺失）两个分支都不进：保持原有的
          // 当前工作区不动。此前 orElse: () => _workspaces.first 在空列表上会直接
          // 抛 StateError，是一条已存在的崩溃路径。
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DshService] fetchWorkspaces error: $e');
    }
  }

  /// 切换归档筛选并立刻重新拉取。
  ///
  /// 传入非法值会归一化为 'exclude'，与网关侧的归一化规则保持一致，
  /// 这样客户端请求的模式永远等于网关回显的模式。
  Future<void> setArchivedFilter(String mode) async {
    final next = (mode == 'only' || mode == 'include') ? mode : 'exclude';
    if (next == _archivedFilter) return;
    _archivedFilter = next;
    // 先通知一次，让筛选器的高亮立刻跟上，不必等网络往返。
    notifyListeners();
    await fetchWorkspaces();
  }

  /// 测试注入点：直接替换工作区列表与归档能力标志，完全不走网络。
  ///
  /// 需要它的理由：`_workspaces` 是私有的，且只有 fetchWorkspaces() 一条写入
  /// 路径，而后者必须联网。没有这个 seam，归档筛选就只能测数据层 —— 但
  /// 「服务端返回了几条」和「UI 实际渲染了几行」是两件事，中间还隔着过滤、
  /// 分组与折叠。只测前者会得出假的通过结论。
  @visibleForTesting
  void debugSetWorkspaces(
    List<Workspace> workspaces, {
    bool? archivedFilterSupported,
    String? archivedFilter,
  }) {
    _workspaces = workspaces;
    if (archivedFilterSupported != null) {
      _archivedFilterSupported = archivedFilterSupported;
    }
    if (archivedFilter != null) {
      _archivedFilter = archivedFilter;
    }
    notifyListeners();
  }

  /// 测试用：直接设定"当前会话"，不联网。
  ///
  /// 会话内的信息视图（状态条 / 信息面板 / 排队 dock）都只在**有当前会话**时
  /// 才渲染内容（没有会话时给的是"先去打开一个会话"的指引），所以没有这个缝
  /// 就测不到它们真正要测的东西。
  @visibleForTesting
  void debugSetCurrentSession(SessionMeta session) {
    _currentSession = session;
    notifyListeners();
  }

  /// 测试用：直接设定连接状态。
  ///
  /// 存在的原因：一批 UI 路径只在"已连接"时才可达（附件入口、发送、语音上传等），
  /// 而真正建连要开 WebSocket 打真实网关 —— 单测里既做不到也不该做。没有这个缝，
  /// 那些路径就只能靠人眼看，等于没测。
  @visibleForTesting
  void debugSetConnection(bool connected) {
    _status =
        connected ? ConnectionStatus.connected : ConnectionStatus.disconnected;
    notifyListeners();
  }

  /// 测试用：直接设定消息列表，不联网。
  ///
  /// 存在的理由是审批卡的位置：那条回归要证明的是「一条超长回复不能把审批卡顶出
  /// 屏幕」，而复现它必须能凭空造出一条任意长度的助手消息 —— 走真实网关既慢又
  /// 会留下真实会话。
  @visibleForTesting
  void debugSetMessages(List<ChatMessage> messages) {
    _messages = messages;
    notifyListeners();
  }

  /// 测试用：把当前内存里的消息按真实缓存路径写一次。
  @visibleForTesting
  void debugWriteHistoryCache() {
    final sessionId = _currentSession?.sessionId;
    if (sessionId != null) _cacheSessionHistory(sessionId, _historyExhausted);
  }

  /// 测试用：查询某个会话是否有缓存快照，以及快照是否已翻到头。
  @visibleForTesting
  ({int messages, bool exhausted})? debugHistoryCache(String sessionId) {
    final snapshot = _historyCache[sessionId];
    if (snapshot == null) return null;
    return (messages: snapshot.messages.length, exhausted: snapshot.exhausted);
  }

  /// 测试用：把一份"服务端快照"直接喂给 reconcile，不联网。
  ///
  /// 存在的理由是 2026-10-17 那个缺陷：reconcile 曾经整体替换 `_messages`，于是
  /// 每 2.5 秒一次的轮询会把用户上翻加载出来的更早几轮**全部抹掉**（"明明有五轮，
  /// 只显示三轮"）。这条路径平时只由轮询驱动，没有这个缝就只能靠人眼在真机上撞。
  @visibleForTesting
  void debugReconcileServerMessages(List<Map<String, dynamic>> raw,
      {bool isRunning = false}) {
    final sid = _currentSession?.sessionId;
    if (sid == null) return;
    _reconcileSessionMessages(raw, isRunning, sid);
  }

  @visibleForTesting
  void debugHandleRawMessage(Map<String, dynamic> frame) {
    _handleRawMessage(jsonEncode(frame));
  }

  @visibleForTesting
  Future<void> Function(String sessionId)? debugFinalResync;

  /// 测试用：当前消息列表里算作"真人回合"的条数。
  ///
  /// [ensureFullHistory] 的补页口径就用它 —— 而"哪些消息算真人回合"这条口径
  /// （注入通知不算、上下文/记忆块不算）只有在这里能单独观察。
  @visibleForTesting
  int get debugHumanTurnCount => _humanTurnCount;

  /// 测试用：直接设定待授权列表，不联网。
  ///
  /// 审批只由 fetchApprovals() 和 WebSocket 帧写入，两者都要真网关。审批卡的
  /// 布局（是否被长消息顶出屏幕、多张时如何呈现）是不依赖引擎行为的纯布局问题，
  /// 却只能从这张列表读 —— 没有这个缝就只能靠人眼看。
  @visibleForTesting
  void debugSetPendingApprovals(List<ApprovalRequest> approvals) {
    _pendingApprovals = approvals;
    notifyListeners();
  }

  /// 测试用：当前是否还会接受流式增量块。
  ///
  /// 单独把这条判断暴露出来，是因为"打开正在执行的会话看不到流式信息"这个 bug
  /// 就藏在这两个计数器的关系里（`_activeTurnSeq <= _cancelledTurnSeq` 恒真 ⇒
  /// 所有增量块被丢弃）。它只能靠真实走一遍 selectSession 才暴露得出来，所以
  /// 需要一个能直接观察的出口。
  @visibleForTesting
  bool get debugAcceptsStreamChunks => _activeTurnSeq > _cancelledTurnSeq;

  void selectWorkspace(Workspace ws, {bool autoSelectSession = true}) {
    _currentWorkspace = ws;
    _sessionPollTimer?.cancel();
    _sessionPollTimer = null;
    _sessionLoadSeq++; // Cancel any pending session loads
    _setSending(false);
    _isLoadingHistory = false;

    if (autoSelectSession && ws.sessions.isNotEmpty) {
      selectSession(ws.sessions.first);
    } else {
      _currentSession = null;
      _messages = [];
      notifyListeners();
    }
  }

  /// 回答一个待决提问。
  ///
  /// 只允许提交「每一道题都答了」的批次：引擎会把 `answers` 原样交给
  /// `ask_user_question`，漏答一道会让 agent 拿到一个残缺的答案，而空
  /// `selected` 会被理解成「用户跳过了这道题」—— 与用户实际看到的东西不符。
  ///
  /// 提交失败时**不**从 [_pendingQuestions] 里移除：网关可能仍然持有这个
  /// 请求（本方法只是没能把答复送出去），此时删掉卡片会让用户失去重试的
  /// 机会，也拿不到任何解释。
  bool answerQuestion(
    PendingQuestion pending, {
    required Map<String, List<String>> selections,
    required Map<String, String> customs,
  }) {
    final answers = <AskUserQuestionAnswerItem>[];
    for (final item in pending.questions) {
      final selected = selections[item.id] ?? const <String>[];
      final custom = customs[item.id] ?? '';
      final answer = AskUserQuestionAnswerItem(
          id: item.id, selected: selected, custom: custom);
      if (!answer.isAnswered) return false;
      answers.add(answer);
    }
    final ok = _sendWsJson({
      'type': 'question_answer',
      'eventId': pending.eventId,
      'answer': AskUserQuestionAnswer(answers).toJson(),
    });
    if (ok) _lastQuestionError = null;
    return ok;
  }

  /// 放弃一个待决提问。
  ///
  /// 这里**不**发送任何作答，也不叫网关代答 —— 只是把卡片收起来。真正的
  /// 释放由引擎侧的 waterfall 决定（网关在订阅者消失时会让 waterfall 落到
  /// Web UI）。所以桌面端仍可回答，手机上只是不再显示一个已经过期的输入框。
  void dismissQuestion(PendingQuestion pending) {
    if (_pendingQuestions.remove(pending)) {
      notifyListeners();
    }
  }

  /// 当前会话的图片附件下载地址。
  ///
  /// 走网关的已鉴权附件路由，因此必须把 Authorization 头一起带上 ——
  /// 裸 `Image.network(url)` 会 401。这里返回的是 URL + 头，由 UI 侧用
  /// `Image.network(..., headers: ...)` 渲染。
  ///
  /// **必须带 sessionId**（v1.10.0 修正）：引擎的 session/attachment RPC 是按
  /// 会话授权的 —— 它只允许读取"该会话真正引用过的图片"。此前只传 id，网关
  /// 那条路由又根本不存在，所以图片始终显示不出来。现在两边都补齐了。
  ({String url, Map<String, String> headers})? attachmentUrl(
    AttachmentRef ref, {
    String? sessionId,
  }) {
    final cfg = _currentConfig;
    if (cfg == null) return null;
    final sid = sessionId ?? _currentSession?.sessionId;
    if (sid == null || sid.isEmpty) return null;
    final uri = Uri.parse('${cfg.httpBaseUrl}/api/mobile/attachment').replace(
      queryParameters: {'id': ref.id, 'sessionId': sid},
    );
    return (url: uri.toString(), headers: _authHeaders);
  }

  /// 把文件原始字节上传到网关，换取引擎签发的 receiptId（§4.2）。
  ///
  /// 先上传再发送，而不是把字节塞进 prompt：prompt 的 JSON 请求体有 2MB 上限，
  /// 而文件动辄十几 MB。上传走独立的原始字节路由（32MB 上限）。
  ///
  /// 失败时抛 [AttachmentError]，消息面向用户 —— 上传失败必须当场说清，
  /// 不能让用户以为挂上了、发出去后才发现 agent 没收到。
  Future<String> uploadAttachment({
    required String name,
    required Uint8List bytes,
    String? sessionId,
  }) async {
    final cfg = _currentConfig;
    if (cfg == null) {
      throw const AttachmentError('尚未配置网关地址');
    }
    final sid = sessionId ?? _currentSession?.sessionId;
    if (sid == null || sid.isEmpty) {
      throw const AttachmentError('请先选择一个会话再上传文件');
    }
    if (bytes.isEmpty) {
      throw const AttachmentError('文件是空的');
    }

    final uri = Uri.parse('${cfg.httpBaseUrl}/api/mobile/upload').replace(
      queryParameters: {'sessionId': sid, 'name': name},
    );

    http.Response res;
    try {
      res = await _httpClient
          .post(
            uri,
            headers: {
              ..._authHeaders,
              'Content-Type': 'application/octet-stream',
            },
            body: bytes,
          )
          .timeout(const Duration(seconds: 120));
    } catch (e) {
      throw AttachmentError(
          '上传失败：${e is Exception ? e.toString().split(':').first : e}');
    }

    Map<String, dynamic> body = const {};
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      // 交给下面的状态码分支统一报错。
    }

    if (res.statusCode == 413) {
      throw AttachmentError(body['error']?.toString() ?? '文件超过大小上限');
    }
    if (res.statusCode != 200 || body['ok'] != true) {
      throw AttachmentError(
          body['error']?.toString() ?? '上传失败 (HTTP ${res.statusCode})');
    }
    final receiptId = body['receiptId']?.toString() ?? '';
    if (receiptId.isEmpty) {
      throw const AttachmentError('上传成功但服务端没有返回凭据，请重试');
    }
    return receiptId;
  }

  /// 连接已确立：标记状态，并声明愿意回答提问。
  ///
  /// 两处调用：`await _channel.ready`（主路径）与收到第一条消息时（兜底）。
  /// 幂等 —— 同一条连接上重复调用不会重复发订阅。
  void _onSocketReady() {
    if (_status != ConnectionStatus.connected) {
      _status = ConnectionStatus.connected;
      _reconnectAttempts = 0;
      _isReconnecting = false;
      notifyListeners();
    }
    if (_subscribeRequested) return;
    _subscribeRequested = true;
    final sent = _subscribeToQuestions();
    // [fix 2026-10-17] 发送失败时回滚标志：此前 send 静默失败（状态竞态/sink
    // 异常）后本连接周期内不会再订阅，提问功能整个静默失效，只有 resume 的
    // resubscribeQuestions 能补救。
    if (!sent) _subscribeRequested = false;
  }

  /// 向网关声明"这台手机愿意回答交互式提问"。
  ///
  /// 只在连接确立时调用（每次重连都要重新调用：网关按**活的 socket** 记录订阅，
  /// 重连会落到一个从没见过这台手机的新 socket 上，不重新声明就会静默地再也
  /// 收不到提问）。
  ///
  /// 网关那边的行为是二选一的：有订阅者才转发 `question_request` 给手机；
  /// 没有订阅者就把这次提问留给 Web UI（见 dsh-server-plugin 的
  /// `questionSubscribers.size === 0` 分支）。所以这一步漏了，表现就是
  /// 「agent 弹的选择在手机上完全不显示」—— 不是渲染问题，而是根本没收到。
  ///
  /// 返回是否真的发出去了（调用方据此决定是否回滚 [subscribed] 标志）。
  bool _subscribeToQuestions() {
    _questionsSubscribed = false;
    return _sendWsJson({'type': 'subscribe_questions'});
  }

  /// 回前台时的补强：再要一次 pending 重放。
  ///
  /// 网关对重复 subscribe 是幂等的（重新加集合 + 回放 pending），所以多发
  /// 一次没有副作用；而它恰好覆盖两个残余风险：
  /// 1. 连接活着但 App 在后台期间错过了实时帧（恰好没走到重连路径）；
  /// 2. 通知点击进来的瞬间连接还在重建中，subscribe 恰逢其时地晚到。
  /// 不做这层，这两种情况都要等下一次提问才暴露。
  void resubscribeQuestions() {
    if (_status == ConnectionStatus.connected) {
      _subscribeToQuestions();
    }
  }

  /// 返回是否真的发出去了。
  ///
  /// 提问的提交需要这个返回值：离线时 send 静默失败，而用户以为已经提交，
  /// 结果提问卡片一直挂在屏幕上、agent 一直等着 —— 必须当场告诉他没发出去。
  bool _sendWsJson(Map<String, dynamic> data) {
    if (_status == ConnectionStatus.connected && _channel != null) {
      try {
        _channel?.sink.add(jsonEncode(data));
        return true;
      } catch (e) {
        debugPrint('[DshService] _sendWsJson error: $e');
      }
    }
    return false;
  }

  // Session Management
  Future<void> selectSession(SessionMeta session) async {
    // [fix 2026-10-17] 用户主动操作 = 重新武装重连（armReconnectRetry 的文档
    // 承诺覆盖 selectSession，此前从未兑现 —— 8 次耗尽后切会话仍然连不上）。
    armReconnectRetry();
    final currentSeq = ++_sessionLoadSeq;
    _sessionPollTimer?.cancel();
    _sessionPollTimer = null;
    _currentSession = session;
    // 只自增 _activeTurnSeq，**不要**跟着把 _cancelledTurnSeq 也提上来。
    //
    // 这是"打开正在执行的会话看不到流式信息"的成因：流式块的守卫是
    //   if (_activeTurnSeq <= _cancelledTurnSeq) return;
    // 两者相等时该条件恒为真，于是每一个增量块都被丢掉 —— 用户看到的是一个
    // 一动不动、只有历史内容的会话。而从本机 sendChatMessage 发起的会话之所以
    // 正常，正是因为那里只自增 _activeTurnSeq（见 L915），不动 _cancelledTurnSeq。
    //
    // 切会话真正需要的是"丢弃上一个会话的残余块"，那由事件里的
    // matchesSessionId(sId) 判断负责（见流式块处理的开头）。turn 计数在这里只是
    // 让在途的旧块失效，不该被当成"这一轮已被取消"。
    _activeTurnSeq++;
    _advanceSessionEpoch(session.sessionId);
    _isCanceling = false;
    _cancelledTurnSeq = _activeTurnSeq - 1;
    _completedTurnEpochs.remove(_syncKey(session.sessionId));
    // [fix 2026-10-17 用户反馈] 先拿上一次打开过的完整消息做**立即回填**：
    // 每次打开会话都重拉整个会话（实测 10 轮 / 7 页 / 1.58 MB）是"打开很卡"
    // 的直接来源。缓存命中时列表当帧就有内容，真正的网络请求只去补尾部增量。
    final cached = _historyCache[session.sessionId];
    if (cached != null && cached.messages.isNotEmpty) {
      _messages = cached.messages.map((m) => m).toList();
      // 缓存里的"正在流式"标记不能带过来：那条消息是上次看到的中间态，
      // 现在它可能早已结束，也可能还在跑 —— 由即将到达的数据决定。
      for (final m in _messages) {
        m.isStreaming = false;
      }
      _recomputeHistoryAnchor();
      _historyExhausted = cached.exhausted;
      _hasMoreHistory = !cached.exhausted && _oldestHistorySeq != null;
      _isLoadingHistory = false;
    } else {
      _messages = []; // Clear immediately to prevent cross-contamination
    }
    // 提问**不跟着清**。这里曾是「点通知进来看不到选项」的真凶：
    // 提问经 WS 订阅重放/实时帧存在内存里，用户点通知 → openSessionById →
    // selectSession 把 _pendingQuestions 整个清空 —— 而网关只在 subscribe 时
    // 重放一次，清了就永远拿不回来（没有 HTTP 查询接口可补拉）。
    // 防"把别的会话的提问挂到当前会话"的职责本来就在 currentSessionQuestions
    // 的会话过滤上，这行 clear 既多余又有害。
    _lastQuestionError = null;
    // 失败横幅同样是会话级的：切走就清，等新会话自己的数据回来再决定。
    _lastTurnFailure = null;
    _setSending(false); // Reset sending state immediately
    _isLoadingHistory = true;
    _lastError = '';
    // 上一个会话的读数（交付物/变更/作业/用量）必须清掉：不清的话新会话的状态条
    // 会拿旧会话的上下文压力与作业数当自己的（这比"多打几个请求"严重得多）。
    _resetSessionInsights();
    // 无缓存时才重置分页；缓存已恢复了锚点和 exhausted，不能再清空。
    if (cached == null) _resetHistoryPaging();
    notifyListeners();

    // Notify server to follow this session for real-time streaming
    _sendWsJson({'type': 'follow', 'sessionId': session.sessionId});

    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/sessions/${session.sessionId}');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 8));
      if (_checkResponseAuth(res)) return;

      // Guard: if user switched to another session while HTTP was in flight, discard!
      if (currentSeq != _sessionLoadSeq) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final sessionData = data['data'] as Map<String, dynamic>?;
        final rawMessages = sessionData?['messages'] as List<dynamic>? ?? [];
        final isRunning = sessionData?['isRunning'] == true;
        final sModel = sessionData?['model'] as String?;
        // 最近一次回合是否以失败结束 —— 手机后连上来也能看到原因。
        _applyTurnFailure(TurnEndInfo.fromJson(sessionData?['lastTurn']));
        if (sModel != null && sModel.isNotEmpty) {
          _currentSessionModel = sModel;
        } else if (session.model.isNotEmpty) {
          _currentSessionModel = session.model;
        } else {
          _currentSessionModel = _settings?.currentModel;
        }

        if (cached != null && cached.messages.isNotEmpty) {
          // 缓存命中：首屏这个 GET 只带**最新一页**，直接整体赋值会把缓存里
          // 更早的历史冲掉。走轮询用的那套对账合并：窗口内的按服务端替换，
          // 窗口之前的（更早几轮）按 seq 留着不动。
          _reconcileSessionMessages(rawMessages, isRunning, session.sessionId);
          if (isRunning && _messages.isNotEmpty && _messages.last.isAssistant) {
            _messages.last.isStreaming = true;
          }
        } else {
          _messages = rawMessages.map((m) {
            // [fix 2026-10-17] 统一走 ChatMessage.fromWire（三处解析收敛，
            // 防字段漂移）。
            return ChatMessage.fromWire(
              Map<String, dynamic>.from(m as Map),
              newId: _uuid.v4,
            );
          }).toList();
        }

        if (isRunning && _messages.isNotEmpty && _messages.last.isAssistant) {
          _messages.last.isStreaming = true;
          _setSending(true, sessionId: session.sessionId);
          _startSessionPolling(session.sessionId);
        } else {
          _setSending(false);
        }

        // [feat 2026-10-12] 首屏历史加载完成后，用最旧一条带 seq 的消息作为
        // 上翻锚点。网关getSessionHistory 已在消息上带 seq。
        _recomputeHistoryAnchor();
        // 缓存命中时别把"已翻到头"的事实抹掉（上面 reconcile 不碰这个字段，
        // 这里只在没有缓存时才重置）。
        if (cached == null) {
          _historyExhausted = false;
          _hasMoreHistory = _oldestHistorySeq != null;
        }
      } else {
        _lastError = '加载历史失败 (HTTP ${res.statusCode})';
        debugPrint('[DshService] $_lastError');
      }
    } catch (e) {
      if (currentSeq == _sessionLoadSeq) {
        debugPrint('[DshService] selectSession error: $e');
        _lastError = '加载会话异常: $e';
      }
    } finally {
      if (currentSeq == _sessionLoadSeq) {
        _isLoadingHistory = false;
        notifyListeners();
        // 会话洞察三档加载（v1.14）。
        //
        // 第一档立刻发：`stats` + `queue` 都是本地投影读，决定状态条首帧有没有
        // 上下文压力和队列内容。
        unawaited(fetchSessionOverview());
        // [fix 2026-10-17] 首屏那一页常常只覆盖一两轮（窗口的预算是按消息条数给的，
        // 而每步都算一条消息）。缓存命中时**不重拉全量** —— 只补尾部增量：
        // 首屏那一次 GET 已经拿到了最新一页，之前补齐过的完整历史在缓存里。
        // 缓存未命中才按老办法把整个会话补齐。
        if (cached != null) {
          _cacheSessionHistory(session.sessionId, _historyExhausted);
          // 轻量增量：只拉最新一页核对尾部（不再 7 页地翻）。
          unawaited(_resyncActiveSession(session.sessionId));
        } else {
          unawaited(ensureFullHistory());
        }
        // 第二档紧接一次：交付物（一次 MUX RPC）→ 变更（一个 git 子进程）。
        // 两个都决定状态条上的数字，但比第一档贵，所以不参与首帧；里面每一环
        // 都带会话守卫，会话切走就停。
        unawaited(fetchSessionSecondary());
      }
    }
  }

  Future<void> createNewSession([String? workspaceId]) async {
    // [fix 2026-10-17] 新会话不得继承上一个会话的模型：_currentSessionModel 是
    // 会话级字段，切到新会话必须重置 —— 否则 temp/real SessionMeta 与首条
    // 消息都携带上一会话的模型，设置页的默认模型被静默绕过（用户实测报告）。
    _currentSessionModel = null;
    armReconnectRetry();
    final currentSeq =
        ++_sessionLoadSeq; // Invalidate any in-flight session loads
    _sessionPollTimer?.cancel();
    _sessionPollTimer = null;
    _setSending(false);
    // 同 selectSession：只自增，不要跟着把 _cancelledTurnSeq 提上来。
    // 新会话里本来没有在跑的回合，把两者设成相等只是给后面埋下同一个雷。
    _activeTurnSeq++;
    _isLoadingHistory = false;
    _lastError = '';

    // Immediately empty out messages as requested: "点击新增会话之后应该是出现一个空的会话"
    _messages = [];
    _resetHistoryPaging();
    // 新会话没有任何读数：清掉上一个会话的（同 selectSession）。
    _resetSessionInsights();

    final targetWsId = workspaceId ?? _currentWorkspace?.workspaceId;
    if (targetWsId != null) {
      final matched = _workspaces.firstWhere(
        (w) => w.workspaceId == targetWsId,
        orElse: () => _workspaces.first,
      );
      _currentWorkspace = matched;
    } else if (_currentWorkspace == null && _workspaces.isNotEmpty) {
      _currentWorkspace = _workspaces.first;
    }

    if (_currentConfig == null || _currentWorkspace == null) {
      notifyListeners();
      return;
    }

    // Temporary session ID for clean empty state before server response
    final tempSessionId = 'session-${_uuid.v4()}';
    final tempSession = SessionMeta(
      sessionId: tempSessionId,
      title: '新对话',
      model: _currentSessionModel ?? _settings?.currentModel ?? '',
      lastPromptAt: DateTime.now().millisecondsSinceEpoch,
    );
    _currentSession = tempSession;
    _currentWorkspace!.sessions.insert(0, tempSession);
    _messages = []; // Empty session!
    notifyListeners();

    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/sessions/create');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({
              'workspaceId': _currentWorkspace!.workspaceId,
              // [fix 2026-10-17] 网关 create 后按此字段注入默认模型（兜底路径，
              // 主路径是下面 selectSessionModel 的显式注入）。
              if (_settings?.currentModel != null &&
                  _settings!.currentModel.isNotEmpty)
                'model': _settings!.currentModel,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (_checkResponseAuth(res)) return;

      // Guard: if user switched to another session while request was in-flight, discard
      if (currentSeq != _sessionLoadSeq) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final realSessionId = data['sessionId']?.toString() ??
            data['session']?['sessionId']?.toString();
        if (realSessionId != null && realSessionId.isNotEmpty) {
          // [fix 2026-10-17] 新会话的模型 = 设置页的默认模型（_currentSessionModel
          // 已在入口重置为 null，这里必然回落到 settings）。
          final defaultModel = _settings?.currentModel ?? '';
          final realSession = SessionMeta(
            sessionId: realSessionId,
            title: '新对话',
            model: defaultModel,
            lastPromptAt: DateTime.now().millisecondsSinceEpoch,
          );
          if (_currentWorkspace != null) {
            final idx = _currentWorkspace!.sessions
                .indexWhere((s) => s.sessionId == tempSessionId);
            if (idx != -1) {
              _currentWorkspace!.sessions[idx] = realSession;
            } else {
              _currentWorkspace!.sessions.insert(0, realSession);
            }
          }
          _currentSession = realSession;
          if (defaultModel.isNotEmpty) {
            // [fix 2026-10-17] 默认模型按会话级注入：settings.yaml 的
            // agent-default-model 要重启 dsh web 引擎才被全局采用（代码注释
            // 实测记录过），而 session/selectModel RPC 立即生效（v1.24 验证）。
            // 创建成功后立刻注入一次，新会话的第一条消息就跑在用户设定的
            // 默认模型上。失败不阻塞建会话 —— 引擎侧兜底仍是全局默认。
            unawaited(selectSessionModel(defaultModel, sessionId: realSessionId)
                .then((_) => null, onError: (Object _) => null));
          }
          _messages = []; // Keep strictly empty!
          notifyListeners();
          _sendWsJson({'type': 'follow', 'sessionId': realSessionId});
        }
      }
    } catch (e) {
      debugPrint('[DshService] createNewSession error: $e');
    }
  }

  /// 发送一条消息。[attachments] 见 §4.2 上传图片/文件。
  ///
  /// 允许"只有附件、没有文字"：引擎的准入规则是"非空白文字**或**至少一个附件"，
  /// 所以这里不能沿用纯文本的必填判断 —— 否则用户传了一张截图却发不出去。
  Future<void> sendChatMessage(String text,
      {List<PendingAttachment> attachments = const []}) async {
    if (text.trim().isEmpty && attachments.isEmpty) return;

    final sessionId = _currentSession?.sessionId ?? 'default';
    // 草稿键在**发起发送时**定格。失败分支还草稿必须用它，而不是读当前的
    // _draftKey —— POST 在途的几秒里用户可能切到别的会话，用当前键会把
    // 正文塞进一个不相干会话的草稿里。
    final draftKeyAtSend = sessionId;

    // 1. Add user message to UI immediately
    //
    // 附件名只拼进**本地显示**用的这一段文本，不进 wire body。真正的附件由引擎
    // 在回合开始后通过 session/attachment 事件回传，届时消息才拿到服务端签发的
    // AttachmentRef（v1.4.1 的机制）并渲染出缩略图。若把文件名塞进再发出去，
    // 服务端回包后会变成"文件名 + 缩略图"两份，反而重复。
    final displayText = attachments.isEmpty
        ? text
        : (text.trim().isEmpty
            ? '📎 ${attachments.map((a) => a.name).join('、')}'
            : '$text\n\n📎 ${attachments.map((a) => a.name).join('、')}');
    // [feat 2026-10-17] 图片的字节就在本机，先渲染出来。
    //
    // 以前只把文件名拼进正文、等引擎的 attachment 事件回来才有缩略图 —— 而那条链路
    // 在"手机自己发的图"上根本没到达，用户看到的是发出去的图**完全不显示**。
    // 这里先给一份本地预览，等服务端历史到了（带服务端签发的 attachmentId）再把
    // 这条乐观消息换成带真附件的那条。
    final localPreviews = <Uint8List>[];
    for (final a in attachments) {
      if (a is PendingImage) {
        try {
          localPreviews.add(base64Decode(a.base64Data));
        } catch (_) {
          // 预览解不出来不影响发送本身；服务端版本到了照常显示
        }
      }
    }
    final userMsg = ChatMessage(
      id: _uuid.v4(),
      role: 'user',
      content: displayText,
      timestamp: DateTime.now(),
      localImagePreviews: localPreviews,
      clientRequestId: _uuid.v4(),
    );
    _messages.add(userMsg);

    // 2. Prepare streaming assistant placeholder with thinking state
    final assistantMsg = ChatMessage(
      id: _uuid.v4(),
      role: 'assistant',
      content: '',
      thinking:
          '', // initialize so ThinkingCard immediately displays active reasoning state
      isStreaming: true,
      timestamp: DateTime.now(),
    );
    _messages.add(assistantMsg);

    final int turnId = ++_activeTurnSeq;
    _advanceSessionEpoch(sessionId);
    _completedTurnEpochs.remove(_syncKey(sessionId));
    _setSending(true, sessionId: sessionId);
    _streamRevision++;
    // 新的一轮开始：上一次的失败横幅（若有）让位，别再挂着旧错误。
    _lastTurnFailure = null;
    notifyListeners();

    // Send follow event via WS
    _sendWsJson({'type': 'follow', 'sessionId': sessionId});

    // 同一次发送的自动重试必须沿用同一个 requestId。引擎会按它做幂等，
    // 网关也用它合并并发投递；每次重试换 ID 会让同一句话真正执行两遍。
    final requestId = userMsg.clientRequestId!;

    try {
      // Send via HTTP RPC with retry to tolerate reverse proxy Keep-Alive drops
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/sessions/prompt');
      http.Response? res;
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          res = await _httpClient
              .post(
                url,
                headers: _authHeaders,
                body: jsonEncode({
                  'sessionId': sessionId,
                  'requestId': requestId,
                  'text': text,
                  'model': currentModel,
                  // 附件（v1.10.0）。图片是内联 base64 的 image part，文件是上传后换到的
                  // receiptId。网关负责把它们并进引擎要求的 content 数组。
                  if (attachments.isNotEmpty)
                    'attachments':
                        attachments.map((a) => a.toWirePart()).toList(),
                }),
              )
              .timeout(const Duration(seconds: 20));
          break;
        } on http.ClientException catch (e) {
          if (attempt == 1) rethrow;
          debugPrint('[DshService] sendPrompt proxy drop, retrying: $e');
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }

      if (_isCanceling || turnId <= _cancelledTurnSeq) {
        debugPrint(
            '[DshService] sendPrompt finished but turn was canceled; ignoring response.');
        return;
      }

      if (res != null && _checkResponseAuth(res)) return;

      if (res != null && res.statusCode == 200) {
        // 3. Start fallback session polling
        _startSessionPolling(sessionId);
        // 只在真正被网关接受后清草稿。放在失败分支之前清，会让"重试"失去
        // 正文。用定格的键清：此刻 _draftKey 可能已指向别的会话。
        drafts.clear(draftKeyAtSend);
      } else {
        if (_isCanceling || turnId <= _cancelledTurnSeq) return;
        String errStr = '发送失败 (HTTP ${res?.statusCode})';
        try {
          if (res != null) {
            final data = jsonDecode(utf8.decode(res.bodyBytes));
            if (data['error'] != null) errStr = data['error'].toString();
          }
        } catch (_) {}
        _lastError = errStr;
        assistantMsg.content = '❌ 发送失败: $errStr';
        assistantMsg.isStreaming = false;
        _setSending(false);
        // 正文还回草稿：网关没收到，用户不该只能凭记忆重打。
        // 还回**发起会话**的草稿键，而不是当前的（用户可能已切走）。
        drafts.write(draftKeyAtSend, text);
        // [fix 2026-10-14] 失败≠引擎没收到（超时/代理断连最常见）。启动一次
        // 延迟 resync 兜底：若引擎其实已在跑，下次对账把状态接回来；若真没
        // 收到，快照不变、草稿还在，用户重发即可。不再启动轮询的话，用户
        // 只能切走再切回才能发现"其实发成功了"。
        _scheduleFailedSendResync(sessionId);
        notifyListeners();
      }
    } catch (e) {
      if (_isCanceling || turnId <= _cancelledTurnSeq) return;
      debugPrint('[DshService] sendPrompt error: $e');
      _lastError = '发送指令异常: $e';
      assistantMsg.content = '❌ 发送指令失败: $e';
      assistantMsg.isStreaming = false;
      _setSending(false);
      drafts.write(draftKeyAtSend, text);
      _scheduleFailedSendResync(sessionId);
      notifyListeners();
    }
  }

  /// [fix 2026-10-14] 发送失败后的延迟对账：5 秒后拉一次会话快照。若引擎其实
  /// 已受理（超时误判），_reconcileSessionMessages 会用服务端状态接回正轨；
  /// 若真失败，快照无变化，无副作用。幂等、一次性。
  void _scheduleFailedSendResync(String sessionId) {
    Future.delayed(const Duration(seconds: 5), () {
      if (_currentSession != null &&
          _currentSession!.matchesSessionId(sessionId)) {
        _resyncActiveSession(sessionId);
      }
    });
  }

  // Active Session Polling (Live Reasoning & Execution Sync)
  void _startSessionPolling(String sessionId) {
    _sessionPollTimer?.cancel();
    int ticks = 0;

    // 轮询是 WS 流式的**兜底**，不是主通道。原来恒定 700ms，与 WS 增量流
    // 重复拉同一份内容；2.5s 一次足够核对终态/补漏，省 3.5x 轮询流量。
    const interval = Duration(milliseconds: 2500);
    const maxTicks = 100; // max ~250s

    _sessionPollTimer = Timer.periodic(interval, (timer) async {
      ticks++;
      if (_isDisposed ||
          ticks > maxTicks ||
          _currentSession == null ||
          !_currentSession!.matchesSessionId(sessionId)) {
        timer.cancel();
        _sessionPollTimer = null;
        if (_currentSession != null &&
            _currentSession!.matchesSessionId(sessionId)) {
          _setSending(false);
          if (_messages.isNotEmpty && _messages.last.isStreaming) {
            _messages.last.isStreaming = false;
          }
          notifyListeners();
        }
        return;
      }

      if (_currentConfig == null) {
        timer.cancel();
        _sessionPollTimer = null;
        return;
      }

      // [fix 2026-10-17] 重叠保护：间隔 2.5s、超时 5s，慢网下两个 tick 并发
      // 打同一个网关且旧快照可能晚到覆盖新数据。上一个 tick 还在途时跳过本次。
      if (_sessionPollInFlight) return;
      _sessionPollInFlight = true;
      try {
        final url = Uri.parse(
            '${_currentConfig!.httpBaseUrl}/api/mobile/sessions/$sessionId');
        final res = await _httpClient
            .get(url, headers: _authHeaders)
            .timeout(const Duration(seconds: 5));
        if (_checkResponseAuth(res)) {
          timer.cancel();
          _sessionPollTimer = null;
          return;
        }

        // If user changed session or canceled while HTTP was in flight, abort!
        if (_isCanceling ||
            _sessionPollTimer == null ||
            _currentSession == null ||
            !_currentSession!.matchesSessionId(sessionId)) {
          timer.cancel();
          _sessionPollTimer = null;
          return;
        }

        if (res.statusCode == 200) {
          final data = jsonDecode(utf8.decode(res.bodyBytes));
          final sessionData = data['data'] as Map<String, dynamic>?;
          if (sessionData == null) return;

          final bool isRunning = sessionData['isRunning'] == true;
          final rawMessages = sessionData['messages'] as List<dynamic>? ?? [];

          _reconcileSessionMessages(rawMessages, isRunning, sessionId);
        }
      } catch (e) {
        debugPrint('[DshService] session poll tick error: $e');
      } finally {
        _sessionPollInFlight = false;
      }
    });
  }

  /// 轮询 tick 的在途标志（重叠保护，见 _startSessionPolling）。
  bool _sessionPollInFlight = false;

  // Active Session State & Pending Stream Chunks Resync (F3.3)
  final Map<String, Future<void>> _resyncFlights = {};
  Future<void> _resyncActiveSession(String sessionId) {
    final existing = _resyncFlights[sessionId];
    if (existing != null) return existing;
    final future = _performSessionResync(sessionId);
    _resyncFlights[sessionId] = future;
    return future.whenComplete(() {
      if (identical(_resyncFlights[sessionId], future)) {
        _resyncFlights.remove(sessionId);
      }
    });
  }

  Future<void> _performSessionResync(String sessionId) async {
    if (_isDisposed || _currentConfig == null || _currentSession == null) return;
    if (!_currentSession!.matchesSessionId(sessionId)) return;

    final targetSessionId = _currentSession!.sessionId;
    final epoch = _sessionEpoch(targetSessionId);
    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/sessions/$targetSessionId');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 5));
      if (_checkResponseAuth(res)) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final sessionData = data['data'] as Map<String, dynamic>?;
        if (sessionData == null) return;

        // Guard against mid-flight session navigation
        if (_currentSession == null ||
            !_currentSession!.matchesSessionId(targetSessionId) ||
            epoch != _sessionEpoch(targetSessionId)) return;

        final rawMessages = sessionData['messages'] as List<dynamic>? ?? [];
        final isServerRunning = sessionData['isRunning'] == true;
        final serverModel = sessionData['model'] as String?;
        if (serverModel != null && serverModel.isNotEmpty) {
          _currentSessionModel = serverModel;
        }

        _reconcileSessionMessages(
            rawMessages, isServerRunning, targetSessionId);
      }
    } catch (e) {
      debugPrint('[DshService] _resyncActiveSession error: $e');
    }
  }

  // Non-destructive 4-Way Stream Chunk & Session Reconciliation (F3.3)
  void _reconcileSessionMessages(
      List<dynamic> rawMessages, bool isServerRunning, String targetSessionId) {
    if (_currentSession == null ||
        !_currentSession!.matchesSessionId(targetSessionId)) return;

    final serverMessages = <ChatMessage>[];
    final seenMessageIds = <String>{};
    final seenMessageSeqs = <int>{};
    final seenRequestIds = <String>{};
    for (final raw in rawMessages) {
      // [fix 2026-10-17] 统一走 ChatMessage.fromWire：此前这里手写解析漏了
      // attachments/turnTokens/noticeKind 等 6 个字段，每 2.5s 轮询整体替换
      // 后历史图片消失、逐轮 token 回退。三处解析收敛到一个工厂。
      final message = ChatMessage.fromWire(
        Map<String, dynamic>.from(raw as Map),
        newId: _uuid.v4,
      );
      // 网关的实时占位和历史页可能落在同一份快照里。以引擎 requestId、
      // 事件 seq、稳定 id 为身份去重，不用正文猜；相同正文的两次发送仍保留。
      final duplicate = (message.clientRequestId != null &&
              seenRequestIds.contains(message.clientRequestId)) ||
          (message.seq != null && seenMessageSeqs.contains(message.seq)) ||
          seenMessageIds.contains(message.id);
      if (duplicate) continue;
      serverMessages.add(message);
      seenMessageIds.add(message.id);
      if (message.seq != null) seenMessageSeqs.add(message.seq!);
      if (message.clientRequestId != null) {
        seenRequestIds.add(message.clientRequestId!);
      }
    }

    // Turn cancellation sequence fence
    //
    // [fix 2026-10-17] 栅栏命中时还要看服务端是否已在新回合里：`_reconcileSessionMessages`
    // 拿到的 serverMessages 若已包含本地没见过的**新 user 消息**（电脑端发起的
    // 远端回合），说明取消后的会话已经前进了 —— 栅栏让路，否则远端回合在这里
    // 被强制 isRunning=false，轮询每 2.5s 都把 UI 拽回"空闲"。
    if (_isCanceling || _activeTurnSeq <= _cancelledTurnSeq) {
      final remoteNewTurn = serverMessages.any((m) =>
          m.role == 'user' && !_messages.any((local) => local.id == m.id));
      if (!remoteNewTurn) {
        isServerRunning = false;
      } else if (_cancelledTurnSeq >= _activeTurnSeq) {
        _cancelledTurnSeq = _activeTurnSeq - 1;
      }
    }

    if (isServerRunning) {
      _setSending(true, sessionId: targetSessionId);
      _remoteRunningSessions.add(_syncKey(targetSessionId));
      _completedTurnEpochs.remove(_syncKey(targetSessionId));
      for (final message in _messages) {
        if (message.isStreaming) message.isStreaming = false;
      }
      _startSessionPolling(targetSessionId);

      if (serverMessages.isNotEmpty && serverMessages.last.isAssistant) {
        final serverAssistant = serverMessages.last;
        serverAssistant.isStreaming = true;

        final localAssistant =
            _messages.isNotEmpty && _messages.last.isAssistant
                ? _messages.last
                : null;
        if (localAssistant != null) {
          // 先 flush：本地还在流式时，最后 100ms 的增量压在 buffer 里，
          // 下面两处"本地比服务端长就保留本地"的比较会漏算这段，把本应
          // 保留的领先量判成落后，进而用滞后的服务端文本盖掉较新的本地内容。
          localAssistant.flushStreamBuffers();
          // 1. Reconcile thinking: never discard in-flight local thoughts
          if ((localAssistant.thinking != null &&
                  localAssistant.thinking!.isNotEmpty) &&
              (serverAssistant.thinking == null ||
                  serverAssistant.thinking!.isEmpty ||
                  localAssistant.thinking!.length >
                      serverAssistant.thinking!.length)) {
            serverAssistant.thinking = localAssistant.thinking;
          }

          // 2. Reconcile text content: retain live WebSocket advances
          if (localAssistant.content.length > serverAssistant.content.length &&
              localAssistant.content.startsWith(serverAssistant.content)) {
            serverAssistant.content = localAssistant.content;
          }
        }
      } else {
        // Server has not emitted assistant turn yet; retain local optimistic assistant placeholder
        if (_messages.isNotEmpty &&
            _messages.last.isAssistant &&
            _messages.last.isStreaming) {
          serverMessages.add(_messages.last);
        }
      }
    } else {
      // Graceful transition to idle when turn finished on server while disconnected
      _setSending(false);
      _isCanceling = false;
      _sessionPollTimer?.cancel();
      _sessionPollTimer = null;

      if (serverMessages.isNotEmpty && serverMessages.last.isAssistant) {
        final serverAssistant = serverMessages.last;
        serverAssistant.isStreaming = false;
        for (final t in serverAssistant.tools) {
          t.isRunning = false;
        }

        // Preserve local thinking if server committed record omitted reasoning
        final localAssistant =
            _messages.isNotEmpty && _messages.last.isAssistant
                ? _messages.last
                : null;
        if (localAssistant != null &&
            (localAssistant.thinking != null &&
                localAssistant.thinking!.isNotEmpty) &&
            (serverAssistant.thinking == null ||
                serverAssistant.thinking!.isEmpty)) {
          serverAssistant.thinking = localAssistant.thinking;
        }
      }
    }

    // [fix 2026-10-17] 服务端这份快照只覆盖**最新一页**（引擎按消息数给的窗口），
    // 而用户在会话里往上翻时加载出来的更早消息**不在这份快照里**。原来下面整体替换
    // （`_messages = serverMessages`），于是每 2.5 秒一次的轮询/重连都会把翻出来的旧轮
    // 抹掉 —— 用户看到的就是"明明有五轮，只显示三轮"。
    //
    // 窗口边界先算出来，下面两处都要用：比它更早的消息一律按 seq 保留，并且**不再**
    // 走"最近本地提问"那条补插逻辑（否则同一条会被补插一次、被保留一次 → 重复两遍）。
    final oldestServerSeq = serverMessages
        .map((m) => m.seq)
        .whereType<int>()
        .fold<int?>(null, (min, s) => min == null || s < min ? s : min);

    // 3. 单次合并：服务端窗口替换旧窗口；尚未被快照确认的本地消息保留。
    // 先算 olderKept，再筛选本地尾部，避免同一条既被保留又被补插。
    final olderKept = oldestServerSeq == null
        ? const <ChatMessage>[]
        : _messages
            .where((m) => m.seq != null && m.seq! < oldestServerSeq)
            .toList();
    final olderIds = olderKept.map((m) => m.id).toSet();
    String stripAttachmentLabel(String s) {
      final idx = s.indexOf('\n\n📎 ');
      return idx >= 0 ? s.substring(0, idx) : s;
    }
    bool matchesServer(ChatMessage local) {
      return serverMessages.any((server) =>
          (local.clientRequestId != null &&
              server.clientRequestId == local.clientRequestId) ||
          (local.seq != null && server.seq == local.seq) ||
          server.id == local.id ||
          // 旧网关不带 rpcId 时才退回正文；双方都有 requestId 时，
          // 相同正文的两条真实消息也绝不合并。
          (local.clientRequestId == null &&
              server.clientRequestId == null &&
              server.role == local.role &&
              server.content == stripAttachmentLabel(local.content)));
    }
    final recentCutoff = DateTime.now().subtract(const Duration(minutes: 10));
    final pending = _messages.where((m) {
      if (olderIds.contains(m.id)) return false;
      if (m.seq != null && oldestServerSeq != null && m.seq! < oldestServerSeq) {
        return false;
      }
      if (matchesServer(m)) return false;
      return m.isStreaming || m.timestamp.isAfter(recentCutoff);
    }).toList();
    final firstServerTime = serverMessages.isEmpty
        ? null
        : serverMessages.first.timestamp;
    final firstServer = serverMessages.isEmpty ? null : serverMessages.first;
    // 只有旧网关（双方都没有 requestId）才用“同文首条 user”判定回合起点；
    // 新协议下带 requestId 的本地旧消息不能凭存在就开启新回合。
    final startsTurn = pending.any((m) =>
        m.isUser &&
        m.clientRequestId == null &&
        m.seq == null &&
        firstServer != null &&
        firstServer.isUser &&
        firstServer.clientRequestId == null &&
        firstServer.content == stripAttachmentLabel(m.content));
    final beforeServer = firstServerTime == null || startsTurn
        ? const <ChatMessage>[]
        : pending.where((m) => m.timestamp.isBefore(firstServerTime)).toList();
    final afterServer = firstServerTime == null || startsTurn
        ? pending
        : pending.where((m) => !m.timestamp.isBefore(firstServerTime)).toList();
    _messages = [...olderKept, ...beforeServer, ...serverMessages, ...afterServer];
    _cacheSessionHistory(targetSessionId, _historyExhausted);
    _streamRevision++;
    notifyListeners();
  }

  // Cancel Turn
  Future<void> cancelActiveTurn() async {
    // 1. Immediately terminate active polling
    _sessionPollTimer?.cancel();
    _sessionPollTimer = null;

    // 2. Synchronous client-side state transition
    _cancelledTurnSeq = _activeTurnSeq;
    _setSending(false);
    _isCanceling = true;

    // 3. Mark current session as not running locally
    if (_currentSession != null) {
      final sId = _currentSession!.sessionId;
      _currentSession = _currentSession!.copyWith(isRunning: false);
      for (final ws in _workspaces) {
        for (var i = 0; i < ws.sessions.length; i++) {
          if (ws.sessions[i].matchesSessionId(sId)) {
            ws.sessions[i] = ws.sessions[i].copyWith(isRunning: false);
          }
        }
      }
    }

    // 4. Zero orphaned stream states: finalize all active streams and running tools
    for (final msg in _messages.reversed) {
      if (msg.isStreaming) {
        msg.isStreaming = false;
        for (final tool in msg.tools) {
          tool.isRunning = false;
        }
        if (msg.content.isEmpty) {
          msg.content = (msg.thinking != null && msg.thinking!.isNotEmpty)
              ? '*(任务已被手动停止)*'
              : '*(已取消)*';
        } else if (!msg.content.endsWith('*(任务已被手动停止)*') &&
            !msg.content.endsWith('*(已取消)*')) {
          msg.content += '\n*(任务已被手动停止)*';
        }
      }
    }

    _streamRevision++;
    // 5. Instantly notify UI listeners for zero-perceived-latency transition
    notifyListeners();

    if (_currentSession == null || _currentConfig == null) {
      _isCanceling = false;
      notifyListeners();
      return;
    }

    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/sessions/cancel');
      await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({
              'sessionId': _currentSession!.sessionId,
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[DshService] cancelTurn error: $e');
    } finally {
      _isCanceling = false;
      _streamRevision++;
      notifyListeners();
      fetchWorkspaces();
    }
  }

  // Settings
  Future<void> fetchSettings() async {
    if (_currentConfig == null) return;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/settings');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final sData = (data['settings'] is Map<String, dynamic>)
            ? data['settings']
            : (data is Map<String, dynamic> ? data : null);
        if (sData != null) {
          _settings = DshSettings.fromJson(sData);
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('[DshService] fetchSettings error: $e');
    }
  }

  /// 切换**本会话**的模型（在聊天页做，立即生效）。
  ///
  /// 走网关的 `/api/mobile/sessions/model`，网关再调引擎的 RPC
  /// `session/selectModel`。
  ///
  /// ⚠️ 此前这个动作是"哑"的：网关只把 `{provider:'wb', model}` 写进投影缓存文件，
  /// 从不告诉引擎（投影缓存是引擎折叠日志的输出，手写等于断言一件没发生过的事）。
  /// 实测：在 App 里切换后 26 分钟内引擎侧没有任何 `model/selection` 事件，请求仍跑
  /// 旧模型。**同一操作还会顺带改掉全局默认模型**（见 [setDefaultModel]）——那既是
  /// 越界（改一个会话却影响所有会话），也是延迟生效（要重启 dsh web）。现在两件事
  /// 彻底分开，各由各自的入口触发。
  Future<bool> selectSessionModel(String modelId, {String? sessionId}) async {
    if (_currentConfig == null) return false;
    final targetSessionId = sessionId ?? _currentSession?.sessionId;
    if (targetSessionId == null ||
        targetSessionId.isEmpty ||
        targetSessionId == 'default') {
      _lastError = '没有可用于切换模型的会话';
      notifyListeners();
      return false;
    }

    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/model');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({'sessionId': targetSessionId, 'model': modelId}),
          )
          .timeout(const Duration(seconds: 8));
      if (_checkResponseAuth(res)) return false;
      if (res.statusCode != 200) {
        _lastError = _errorFromBody(res) ?? '切换模型失败 (HTTP ${res.statusCode})';
        notifyListeners();
        return false;
      }
    } catch (e) {
      debugPrint('[DshService] selectSessionModel failed: $e');
      _lastError = '切换模型失败: $e';
      notifyListeners();
      return false;
    }

    _currentSessionModel = modelId;
    if (_currentSession != null) {
      _currentSession = _currentSession!.copyWith(model: modelId);
    }
    for (final ws in _workspaces) {
      for (var i = 0; i < ws.sessions.length; i++) {
        if (ws.sessions[i].matchesSessionId(targetSessionId)) {
          ws.sessions[i] = ws.sessions[i].copyWith(model: modelId);
        }
      }
    }
    notifyListeners();
    return true;
  }

  /// 设置**全局默认模型**（在设置页做）。
  ///
  /// 写引擎的 `settings.yaml`（`agent-default-model`），影响所有会话与新建会话。
  /// ⚠️ 实测它对**已经在运行的会话**不是立即生效的：18:42:50 写入后，直到 20:09
  /// 重启 dsh web 引擎才采用。所以界面上必须写明这一点，不能让用户以为改完就换了。
  Future<bool> setDefaultModel(String modelId) async {
    if (_currentConfig == null) return false;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/settings/model');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({'model': modelId}),
          )
          .timeout(const Duration(seconds: 8));
      if (_checkResponseAuth(res)) return false;
      if (res.statusCode != 200) {
        _lastError = _errorFromBody(res) ?? '设置默认模型失败 (HTTP ${res.statusCode})';
        notifyListeners();
        return false;
      }
    } catch (e) {
      debugPrint('[DshService] setDefaultModel failed: $e');
      _lastError = '设置默认模型失败: $e';
      notifyListeners();
      return false;
    }
    await fetchSettings();
    notifyListeners();
    return true;
  }

  /// 从错误响应体里取网关/引擎给的原因（"模型目录里找不到 X"这类）。
  ///
  /// 只认 `error` 字段：网关的所有失败分支都写它，拿不到就返回 null 让调用方
  /// 退回到带状态码的通用文案，而不是显示一个空错误。
  String? _errorFromBody(http.Response res) {
    try {
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final err = data is Map ? data['error'] : null;
      if (err != null && err.toString().trim().isNotEmpty) {
        return err.toString();
      }
    } catch (_) {
      // 非 JSON 的响应体（代理错误页等）——按"没有可用原因"处理
    }
    return null;
  }

  // Delete Session
  Future<bool> deleteSession(String sessionId, [String? workspaceId]) async {
    if (_currentConfig == null) return false;
    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/sessions/delete');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({
              'sessionId': sessionId,
              'workspaceId':
                  workspaceId ?? _currentWorkspace?.workspaceId ?? '',
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (_checkResponseAuth(res)) return false;

      if (res.statusCode == 200) {
        for (final ws in _workspaces) {
          ws.sessions.removeWhere((s) => s.matchesSessionId(sessionId));
        }

        if (_currentSession?.matchesSessionId(sessionId) == true) {
          if (_currentWorkspace != null &&
              _currentWorkspace!.sessions.isNotEmpty) {
            await selectSession(_currentWorkspace!.sessions.first);
          } else {
            await createNewSession();
          }
        } else {
          notifyListeners();
        }
        return true;
      } else {
        String errStr = '删除会话失败';
        try {
          final data = jsonDecode(utf8.decode(res.bodyBytes));
          if (data['error'] != null) errStr = data['error'].toString();
        } catch (_) {}
        _lastError = errStr;
        notifyListeners();
        return false;
      }
    } catch (e) {
      debugPrint('[DshService] deleteSession error: $e');
      _lastError = '删除会话异常: $e';
      notifyListeners();
      return false;
    }
  }

  // Approvals
  Future<void> fetchApprovals() async {
    if (_currentConfig == null) return;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/approvals');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final list = data['approvals'] as List<dynamic>? ?? [];
        _pendingApprovals = list
            .map((a) => ApprovalRequest.fromJson(a as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DshService] fetchApprovals error: $e');
    }
  }

  /* ------------------------------------------------------------------ *
   * [v1.35 / 2.3] 锁屏通知一键裁决
   *
   * 通知栏上的 approve/deny 走的是网关的一次性令牌端点，不是设备 token：
   * 通知会被截图/投屏，它承载的权限必须只够这一条审批。
   * ------------------------------------------------------------------ */

  /// 通知动作回调（由构造时挂到 NotificationService 上）。
  Future<void> _handleNotificationAction(
      String actionId, String payload) async {
    final target = NotificationApprovalActions.decodePayload(payload);
    if (target == null) return;
    final approvalId = target.approvalId;
    final token = target.token;

    if (actionId == 'defer') {
      // 延后只收起通知，不答复网关：审批仍在等，用户回 App 里还能看到。
      return;
    }
    final decision = actionId == 'approve' ? 'approve' : 'deny';
    final result = await decideApprovalFromNotification(
      approvalId: approvalId,
      token: token,
      decision: decision,
    );
    final ok = result['ok'] == true;
    final already = result['alreadyApplied'] == true;
    final message = ok
        ? (already
            ? '这本就是你要的结果，无需重复操作'
            : (decision == 'approve' ? '已批准 · 会话继续' : '已拒绝 · 会话不会执行'))
        : approvalNoticeForResult(result);
    await notifications.show(
      title: ok ? '审批已处理' : '审批未生效',
      body: message,
      kind: NotificationKind.info,
      onlyWhenBackground: false,
    );
  }

  /// 是否给这条审批配「通知栏一键批准」按钮。
  ///
  /// 只有拿到一次性令牌的才配：完全访问策略（sensitive）网关刻意不铸令牌。
  @visibleForTesting
  static bool shouldOfferQuickActions(ApprovalRequest req) =>
      req.approvalToken != null && !req.sensitive;

  /// 把网关的结构化错误码翻成人话（2.1 的 expired/consumed/conflict/sensitive）。
  @visibleForTesting
  static String approvalNoticeForResult(Map<String, dynamic> result) {
    switch (result['code']?.toString() ?? '') {
      case 'expired':
        return '这条审批已过期（15 分钟），请打开 App 处理';
      case 'sensitive':
        return '敏感审批需要打开 App 确认';
      case 'conflict':
        return '这条审批已被相反决定处理过';
      case 'consumed':
        return '这条审批已处理过';
      case 'mismatch':
        return '审批令牌不匹配，请打开 App 处理';
      case 'engine-rejected':
        return '网关没能回传引擎：${result['error'] ?? '未知原因'}';
      case 'offline':
        return '尚未连接网关，请打开 App 处理';
      default:
        return result['error']?.toString() ?? '请打开 App 处理';
    }
  }

  /// POST /api/mobile/approvals/decide。永不抛异常，失败返回 `{ok:false, code}`。
  Future<Map<String, dynamic>> decideApprovalFromNotification({
    required String approvalId,
    required String token,
    required String decision,
  }) async {
    if (_currentConfig == null) {
      return {'ok': false, 'code': 'offline', 'error': '尚未连接网关'};
    }
    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/approvals/decide');
      final res = await _httpClient
          .post(
            url,
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode({
              'approvalId': approvalId,
              'approvalToken': token,
              'decision': decision,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) {
        return {'ok': false, 'code': 'auth', 'error': '认证失败，请重新配对'};
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is Map) return Map<String, dynamic>.from(data);
      return {'ok': false, 'code': 'bad-response'};
    } catch (e) {
      debugPrint('[DshService] decideApprovalFromNotification error: $e');
      return {'ok': false, 'code': 'network', 'error': '$e'};
    }
  }

  Future<void> respondApproval(ApprovalRequest req, String outcome,
      {String? reason}) async {
    if (_currentConfig == null) return;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/approval');
      final Map<String, dynamic> body = {
        'eventId': req.eventId,
        'approvalId': req.id.isNotEmpty ? req.id : req.eventId,
        'outcome': outcome, // 'allowed-once' or 'rejected'
      };
      if (reason != null && reason.trim().isNotEmpty) {
        body['reason'] = reason.trim();
      }

      // Also dispatch over live WebSocket if active
      if (_channel != null) {
        try {
          _channel!.sink.add(jsonEncode({
            'type': 'approval_response',
            'eventId': req.eventId,
            'approvalId': req.id.isNotEmpty ? req.id : req.eventId,
            'outcome': outcome,
            if (reason != null && reason.trim().isNotEmpty)
              'reason': reason.trim(),
          }));
        } catch (_) {}
      }

      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 8));
      if (_checkResponseAuth(res)) return;

      // 网关对"审批不存在(404)/回传引擎失败(502)"也回 HTTP 200（历史遗留，
      // body 里才有 ok:false）。只看状态码会把失败当成功：卡片被删、用户以为
      // 批过了，而引擎还在审批门前挂着。这里必须读 body 的 ok。
      if (res.statusCode == 200) {
        var ok = true;
        var errMsg = '';
        try {
          final data = jsonDecode(utf8.decode(res.bodyBytes));
          ok = data['ok'] != false;
          errMsg = data['error']?.toString() ?? '';
        } catch (_) {}
        if (ok) {
          _pendingApprovals
              .removeWhere((a) => a.eventId == req.eventId || a.id == req.id);
          _lastError = '';
        } else {
          // 失败保留卡片（网关同样保留了队列条目），用户还有重试入口。
          _lastError = errMsg.isNotEmpty ? '审批未生效: $errMsg' : '审批未生效，请重试';
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DshService] respondApproval error: $e');
    }
  }

  // Permissions
  Future<void> fetchPermissions() async {
    if (_currentConfig == null) return;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/permissions');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        if (data['permissions'] != null) {
          _permissions = PermissionConfig.fromJson(data['permissions']);
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('[DshService] fetchPermissions error: $e');
    }
  }

  Future<bool> updatePermissions(PermissionConfig newConfig) async {
    if (_currentConfig == null) return false;
    final oldConfig = _permissions;
    // 乐观更新本地状态，即时反映 UI
    _permissions = newConfig;
    notifyListeners();
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/permissions');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode(newConfig.toJson()),
          )
          .timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return false;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        if (data['permissions'] != null) {
          _permissions = PermissionConfig.fromJson(data['permissions']);
          notifyListeners();
          return true;
        }
        return true;
      }
      _permissions = oldConfig;
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('[DshService] updatePermissions error: $e');
      _permissions = oldConfig;
      notifyListeners();
      return false;
    }
  }

  Future<void> setSessionPermission(String sessionId, String policy) async {
    final updatedMap = Map<String, String>.from(_permissions.sessionPolicies);
    updatedMap[sessionId] = policy;
    final updated = _permissions.copyWith(sessionPolicies: updatedMap);
    await updatePermissions(updated);
  }

  String getSessionPermission(String sessionId) {
    return _permissions.getPolicyForSession(sessionId);
  }

  // Audit Logs
  Future<void> fetchAuditLogs() async {
    if (_currentConfig == null) return;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/audit-logs');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final list =
            (data['auditLogs'] ?? data['logs']) as List<dynamic>? ?? [];
        _auditLogs = list
            .map((a) => AuditLogItem.fromJson(a as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DshService] fetchAuditLogs error: $e');
    }
  }

  // Personas
  Future<void> fetchPersonas() async {
    if (_currentConfig == null) return;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/personas');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final list = data['personas'] as List<dynamic>? ?? [];
        _personas = list
            .map((p) => AgentPersona.fromJson(p as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DshService] fetchPersonas error: $e');
    }
  }

  Future<bool> savePersonas(List<AgentPersona> list) async {
    if (_currentConfig == null) return false;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/personas');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body:
                jsonEncode({'personas': list.map((p) => p.toJson()).toList()}),
          )
          .timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return false;
      if (res.statusCode == 200) {
        _personas = list;
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[DshService] savePersonas error: $e');
      return false;
    }
  }

  void setActivePersona(String? id) {
    _activePersonaId = id;
    notifyListeners();
  }

  // ---- 新功能 API（v1.11.0）：snippets / 版本检查 / 归档 / 重命名 / 搜索 ----

  Future<void> fetchSnippets() async {
    if (_currentConfig == null) return;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/snippets');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final list = data['snippets'] as List<dynamic>? ?? [];
        _snippets = list
            .whereType<Map>()
            .map((s) => Snippet.fromJson(Map<String, dynamic>.from(s)))
            .toList();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DshService] fetchSnippets error: $e');
    }
  }

  Future<bool> saveSnippets(List<Snippet> list) async {
    if (_currentConfig == null) return false;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/snippets');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body:
                jsonEncode({'snippets': list.map((s) => s.toJson()).toList()}),
          )
          .timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return false;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final saved = data['snippets'] as List<dynamic>? ?? [];
        _snippets = saved
            .whereType<Map>()
            .map((s) => Snippet.fromJson(Map<String, dynamic>.from(s)))
            .toList();
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[DshService] saveSnippets error: $e');
      return false;
    }
  }

  // 客户端更新不再走网关。
  //
  // 这里原先有 `checkForUpdate()`：调 `/api/mobile/version`，与网关侧环境变量
  // `DSH_LATEST_APP_VERSION`（以及手工放进盘里的 APK）比对。它有三个失败面 ——
  // 网关没设变量、APK 没放、变量写的是旧号 —— 而任一失败都会让界面言之凿凿地
  // 说"已是最新"。改为直接指向 GitHub Releases（见 `AppVersion.releasesUrl`），
  // 「有没有新版」由发布页本身回答，没有可漂移的中间状态。

  /// 新建工作区的目录选择器：起点清单（[feat 2026-10-22]）。
  ///
  /// 用户原话：「新建工作区目前是手写，这个要改成点选」。手写的真正问题是**路径
  /// 只能靠记忆**：手机上看不见电脑的目录树，记错一层就建到错的地方。
  ///
  /// 起点由网关算（主目录 / 已登记工作区的上级 / 工作区本身 / 用到的盘），客户端
  /// 不能自带参数扩面。老网关没有这个接口 → 返回 `ok:false`，弹层退回手动输入。
  Future<WorkspaceDirListing> fetchWorkspaceRoots() async {
    if (_currentConfig == null) {
      return const WorkspaceDirListing(ok: false, error: '还没连上网关');
    }
    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/workspaces/roots');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) {
        return const WorkspaceDirListing(ok: false, error: '登录状态已失效，请重新配对');
      }
      final body = res.bodyBytes.isEmpty
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
      final parsed = WorkspaceDirListing.fromJson(body);
      if (res.statusCode == 200 && parsed.ok) return parsed;
      return WorkspaceDirListing(
        ok: false,
        error: parsed.error.isNotEmpty
            ? parsed.error
            : '网关不支持目录选择（HTTP ${res.statusCode}）',
      );
    } catch (e) {
      debugPrint('[DshService] fetchWorkspaceRoots error: $e');
      return const WorkspaceDirListing(ok: false, error: '请求失败或超时');
    }
  }

  /// 列出一层子目录（只读；只有目录，没有文件）。
  Future<WorkspaceDirListing> browseWorkspaceDirs(String absPath) async {
    if (_currentConfig == null) {
      return const WorkspaceDirListing(ok: false, error: '还没连上网关');
    }
    try {
      final url = Uri.parse(
              '${_currentConfig!.httpBaseUrl}/api/mobile/workspaces/browse')
          .replace(queryParameters: {'path': absPath});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) {
        return const WorkspaceDirListing(ok: false, error: '登录状态已失效，请重新配对');
      }
      final body = res.bodyBytes.isEmpty
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
      final parsed = WorkspaceDirListing.fromJson(body);
      if (res.statusCode == 200 && parsed.ok) return parsed;
      return WorkspaceDirListing(
        ok: false,
        path: absPath,
        error: parsed.error.isNotEmpty
            ? parsed.error
            : '读不了这个目录（HTTP ${res.statusCode}）',
      );
    } catch (e) {
      debugPrint('[DshService] browseWorkspaceDirs error: $e');
      return WorkspaceDirListing(ok: false, path: absPath, error: '请求失败或超时');
    }
  }

  /// 新建工作区（[feat 2026-10-17]）。
  ///
  /// 返回 `null` 表示成功；否则是给用户看的失败说明（由调用方**内联**显示，
  /// 不用会自己消失的提示 —— 建工作区失败是个待办，不是通知）。
  ///
  /// 网关侧在 `workspace.json` 里加一行（已存在同一路径时幂等返回），目录不存在
  /// 会被一并创建。所以这个动作在服务端有副作用：调用前不需要再问一次
  /// "确定吗"，但要保证 path 是用户真的想建的那个。
  Future<String?> createWorkspace({required String path, String? title}) async {
    if (_currentConfig == null) return '还没连上网关';
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '路径不能为空';
    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/workspaces/create');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({
              'path': trimmed,
              if (title != null && title.trim().isNotEmpty)
                'title': title.trim(),
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return '登录状态已失效，请重新配对';
      if (res.statusCode == 200) {
        await fetchWorkspaces();
        return null;
      }
      // 网关会带一句人话（目录创建失败 / workspace.json 写入失败 …），原样透出，
      // 不要用"操作失败"把最有用的那句吃掉。
      try {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final msg = data is Map ? (data['error'] ?? data['message']) : null;
        if (msg is String && msg.trim().isNotEmpty) return msg.trim();
      } catch (_) {/* 落到下面的兜底 */}
      return '新建失败（HTTP ${res.statusCode}）';
    } catch (e) {
      debugPrint('[DshService] createWorkspace error: $e');
      return '网络异常，没建成功：$e';
    }
  }

  /// 归档 / 取消归档一个会话。
  Future<bool> setSessionArchived(String sessionId, bool archived) async {
    if (_currentConfig == null) return false;
    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/sessions/archive');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({'sessionId': sessionId, 'archive': archived}),
          )
          .timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return false;
      if (res.statusCode == 200) {
        // 本地同步翻转，列表立即反映（网关也会广播 session_archived，但
        // 自己操作自己听还要等一个来回，先改了再说）。
        for (final ws in _workspaces) {
          for (var i = 0; i < ws.sessions.length; i++) {
            if (ws.sessions[i].matchesSessionId(sessionId)) {
              ws.sessions[i] = ws.sessions[i].copyWith(archived: archived);
            }
          }
        }
        notifyListeners();
        // [fix 2026-10-17] 翻转本地标志**不足以**让列表正确：工作区视图渲染的是
        // 网关按 `archived` 过滤后的那份列表，而"未归档"视图里被归档的那一行还在
        // 手上的数组里，于是点了归档行照旧挂在那儿 —— 用户看到的就是"归档没生效"。
        // （实测网关侧是对的：归档后再查 exclude 清单里已经没有它、only/include 里有。）
        // 这里主动重拉一次，让列表回到服务端的事实。
        unawaited(fetchWorkspaces());
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[DshService] setSessionArchived error: $e');
      return false;
    }
  }

  /// 重命名一个会话。
  Future<bool> renameSession(String sessionId, String title) async {
    if (_currentConfig == null || title.trim().isEmpty) return false;
    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/sessions/rename');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({'sessionId': sessionId, 'title': title.trim()}),
          )
          .timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return false;
      if (res.statusCode == 200) {
        for (final ws in _workspaces) {
          for (var i = 0; i < ws.sessions.length; i++) {
            if (ws.sessions[i].matchesSessionId(sessionId)) {
              ws.sessions[i] = ws.sessions[i].copyWith(title: title.trim());
            }
          }
        }
        if (_currentSession?.matchesSessionId(sessionId) == true) {
          _currentSession = _currentSession!.copyWith(title: title.trim());
        }
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[DshService] renameSession error: $e');
      return false;
    }
  }

  /// 跨会话搜索（标题 + 首条 prompt）。
  Future<List<SessionSearchHit>> searchSessions(String query,
      {int limit = 30}) async {
    if (_currentConfig == null || query.trim().isEmpty) return const [];
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/search')
              .replace(queryParameters: {'q': query.trim(), 'limit': '$limit'});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return const [];
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final list = data['results'] as List<dynamic>? ?? [];
        return list
            .whereType<Map>()
            .map((s) => SessionSearchHit.fromJson(Map<String, dynamic>.from(s)))
            .toList();
      }
    } catch (e) {
      debugPrint('[DshService] searchSessions error: $e');
    }
    return const [];
  }

  /// 按 id 打开一个会话（搜索命中后跳转用）。
  ///
  /// 该会话可能不在当前工作区的列表里（搜索是全库的）：先在工作区表里找，
  /// 找不到就构造一个最小 SessionMeta 直接进 —— selectSession 走的是
  /// sessionId，列表成员资格只影响侧边栏显示。
  Future<void> openSessionById(String sessionId, {String title = ''}) async {
    for (final ws in _workspaces) {
      for (final s in ws.sessions) {
        if (s.matchesSessionId(sessionId)) {
          await selectSession(s);
          return;
        }
      }
    }
    final meta = SessionMeta(
      sessionId: sessionId,
      title: title.isEmpty ? '会话' : title,
    );
    await selectSession(meta);
  }

  // Ping
  Future<int> measurePing() async {
    if (_currentConfig == null) return -1;
    final start = DateTime.now().millisecondsSinceEpoch;
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/ping');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        _pingMs = DateTime.now().millisecondsSinceEpoch - start;
        notifyListeners();
        return _pingMs;
      }
    } catch (_) {}
    _pingMs = -1;
    notifyListeners();
    return -1;
  }

  // Workspace Memory & Instructions
  Future<String> fetchWorkspaceMemory(String workspacePath) async {
    if (_currentConfig == null) return '';
    try {
      final uri = Uri.parse(
              '${_currentConfig!.httpBaseUrl}/api/mobile/workspace/memory')
          .replace(
        queryParameters: {'path': workspacePath},
      );
      final res = await _httpClient
          .get(uri, headers: _authHeaders)
          .timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return '';
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        return data['content'] ?? '';
      }
    } catch (e) {
      debugPrint('[DshService] fetchWorkspaceMemory error: $e');
    }
    return '';
  }

  Future<bool> saveWorkspaceMemory(String workspacePath, String content) async {
    if (_currentConfig == null) return false;
    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/workspace/memory');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({'path': workspacePath, 'content': content}),
          )
          .timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return false;
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[DshService] saveWorkspaceMemory error: $e');
      return false;
    }
  }

  // ------------------------------------------------------------ 会话洞察 --
  //
  // 一个会话"正在等什么/改了什么/产出什么/烧了多少"的只读视图。
  // 所有读取都允许失败并保留上一次结果：手机在地铁里断网时，界面显示的是
  // 上一次的真值 + 一个错误提示，而不是一片空白。
  //
  // 三条贯穿这一块的不变量（改这里之前先读，它们都被测试钉住了）：
  //
  // 1. **未知 ≠ 零。** 每个"数量"都是可空的，`null` 表示读不到/还没拉过，
  //    界面据此**隐藏整段**。绝不回落成 0 —— `改动 0` 与 `改动 读不到` 在
  //    用户眼里是"工作区干净"与"我不知道"两件完全不同的事。
  // 2. **切会话必须丢弃在途响应。** 每个 fetch 都带 `_sessionLoadSeq` 守卫；
  //    没有它，快速切 A→B 会把 A 的交付物显示在 B 的会话里，用户会被指向
  //    错的下载项。
  // 3. **换会话必须清空上一个会话的读数。** [_resetSessionInsights] 负责这件事：
  //    否则新会话的状态条会显示旧会话的上下文压力/作业数。

  List<QueueItem> _queueItems = [];
  String _queueError = '';
  bool _queueLoading = false;

  /// 队列可见性三态（v1.14）。**必须区分"读不到"和"确实是空"**：
  ///
  ///   * `null`  —— 还没查过（冷启动）。界面不渲染队列区，避免首帧闪一条空壳。
  ///   * `true`  —— 服务端给了 `queue` 字段，哪怕是空数组；这才代表"确实没有排队消息"。
  ///   * `false` —— 读不到（HTTP 失败 / 响应体里没有 `queue`）。
  ///
  /// 为什么要三态：生产上 `GET /api/mobile/sessions/queue` 曾被通配路由当成
  /// `getSessionHistory("queue")` 吞掉，响应里根本没有 `queue` 字段。旧代码
  /// `data['queue'] as List? ?? []` 把它静默当成空队列，于是"路由坏了"和"真的没排队"
  /// 在界面上完全一样 —— 修好路由之前和之后无法分辨，用户看到的是一个永远空的队列。
  bool? _queueKnown;

  /// 后台作业是否只是"读不到"（网关 `degraded: 'jobs-unavailable'`）。
  ///
  /// 与队列同一个形态的问题：把"读不到"渲染成"没有作业"。这里只负责把标记
  /// 暴露出来（信息面板由 T3 消费），不去猜网关为什么降级。
  String _jobsDegraded = '';

  List<DeliverableItem> _deliverables = [];

  /// 交付物清单的可见性三态，与 [queueKnown] 同一套语义：
  /// `null` 还没拉过（状态条隐藏"产出"段）/ `true` 拉到了（含空清单，此时
  /// `产出 0` 是**真值**，要显示）/ `false` 读不到（隐藏，不装作 0 个）。
  bool? _deliverablesKnown;

  /// 本会话收到过多少次 `deliverables` 事件。
  ///
  /// 与"清单里有几项"刻意分开：消息流里的「本轮产出」卡片必须是**事件**的产物
  /// （"刚刚交付了"），而进会话时补拉到的旧产出属于**状态**（归状态条与信息面板）。
  /// 只看清单有没有内容，会把好几轮以前的产出渲染到消息流尾部冒充"刚刚交付"。
  int _deliverableEvents = 0;

  List<WorkspaceChange> _workspaceChanges = [];
  String _workspaceChangesReason = '';
  bool _workspaceChangesAvailable = false;

  /// [feat 2026-10-13] Where the change rows came from, and what git could not
  /// answer. The gateway distinguishes `git`, `git+tool-calls` and `tool-calls`;
  /// the panel needs that to explain a row with no line counts instead of
  /// rendering a fake "+0 −0".
  String _workspaceChangesSource = '';

  /// [feat 2026-10-13] Repositories adjacent to a non-repo workspace, so the
  /// panel can offer them rather than an empty screen. Empty when the cwd is a
  /// repository or nothing was found.
  List<RepoCandidate> _workspaceRepos = const <RepoCandidate>[];

  /// [feat 2026-10-13] The gateway's one-line explanation for an empty git view.
  String _workspaceChangesNote = '';

  /// 变更清单的可见性三态（同 [queueKnown] 语义）。
  bool? _changesKnown;

  /// 本轮结束时要重新取一次变更清单（收到过 `workspace_changes` 帧）。
  ///
  /// 事件只置脏、不立刻拉：那个事件在一轮里可能来好几次，而它每次都要起一个
  /// `git status` 子进程；更要紧的是轮内的 git 状态会随 agent 写文件中途抖动，
  /// 数字没有意义。统一在 `done` 拉一次，一轮最多一个子进程。
  bool _changesDirty = false;

  List<ScheduleItem> _schedules = [];
  List<JobItem> _jobs = [];
  SessionStats? _sessionStats;
  PushConfig? _pushConfig;

  // [feat 2026-10-12] 子代理列表 / 一键诊断。子代理是会话域数据（会话切换要清），
  // 诊断是网关域数据（跨会话有效，不清）。
  List<SubagentItem>? _subagents;
  bool _subagentsUnavailable = false;
  DiagnosticsReport? _diagnostics;
  bool _diagnosticsBusy = false;

  /// null = 还没拉过或引擎没有列出能力（UI 隐藏区块）。
  List<SubagentItem>? get subagents => _subagents;

  /// true = 拉取失败/引擎不可达（UI 显示"状态未知"而不是空表）。
  bool get subagentsUnavailable => _subagentsUnavailable;

  /// 智能体团队快照。 [feat 2026-10-16] 同为会话域数据，会话切换时清空。
  AgentTeam? _team;

  /// true = 拉取失败（区别于"这个会话本来就没有团队"）。
  bool _teamUnavailable = false;

  /// null = 还没拉过 / 拉取失败（UI 显示"状态未知"）。
  AgentTeam? get team => _team;
  bool get teamUnavailable => _teamUnavailable;

  DiagnosticsReport? get diagnostics => _diagnostics;
  bool get diagnosticsBusy => _diagnosticsBusy;

  /// 本轮消耗的基线：**回合开始那一刻**的累计 token 读数。
  int? _statsBaselineTokens;

  /// 是否已经观测到"这个回合开始跑了"——上升沿用，避免一个回合内的多次
  /// `session_status(isRunning:true)` 反复覆盖基线（那会把基线推进到回合中途，
  /// 算出来的"本轮消耗"偏小）。
  bool _turnRunningSeen = false;

  /// 最近一个**已结束**回合的消耗是否已经量到。
  bool _hasMeasuredTurn = false;
  int? _measuredTurnTokens;

  List<QueueItem> get queueItems => _queueItems;
  String get queueError => _queueError;
  bool get queueLoading => _queueLoading;
  bool? get queueKnown => _queueKnown;
  String get jobsDegraded => _jobsDegraded;
  List<DeliverableItem> get deliverables => _deliverables;
  bool? get deliverablesKnown => _deliverablesKnown;

  /// 本会话收到的 `deliverables` 事件数（见 [_deliverableEvents] 的说明）。
  int get deliverableEventCount => _deliverableEvents;

  /// 交付物数量：**只有在拉到时才有值**，否则 null（界面隐藏该段）。
  ///
  /// 给的是"可显示的值"而不是"拉过没有"：状态条需要的正是这个，写成
  /// `deliverablesFetched` 那种布尔，调用方还得自己再决定显示什么。
  int? get deliverableCount =>
      _deliverablesKnown == true ? _deliverables.length : null;

  List<WorkspaceChange> get workspaceChanges => _workspaceChanges;
  String get workspaceChangesReason => _workspaceChangesReason;
  bool get workspaceChangesAvailable => _workspaceChangesAvailable;

  /// 'git' | 'git+tool-calls' | 'tool-calls' | '' (unknown).
  String get workspaceChangesSource => _workspaceChangesSource;

  /// Adjacent repositories when the workspace is not itself one.
  List<RepoCandidate> get workspaceRepos => _workspaceRepos;

  /// Gateway prose explaining an empty or partial change list.
  String get workspaceChangesNote => _workspaceChangesNote;

  /// True when at least one row came from the session log rather than git, so
  /// its line counts are genuinely unknown (render "—", never "+0 −0").
  bool get changesIncludeToolCallRows =>
      _workspaceChangesSource == 'tool-calls' ||
      _workspaceChangesSource == 'git+tool-calls';

  /// 变更文件数：拉到了、且可列（git 仓库）时才有值，否则 null（隐藏）。
  int? get changeCount => (_changesKnown == true && _workspaceChangesAvailable)
      ? _workspaceChanges.length
      : null;

  /// 变更清单确实是"读不到"（而不是"还没拉过"）：非 git 仓库 / 网关报错。
  ///
  /// 与"未知"分开的原因：未知时状态条安静地不显示就够了；确实不可用时，
  /// 信息面板里要**说清为什么**，否则用户会以为工作区是干净的。
  bool get changesUnavailable =>
      _changesKnown == true && !_workspaceChangesAvailable;

  List<ScheduleItem> get schedules => _schedules;
  List<JobItem> get jobs => _jobs;
  SessionStats? get sessionStats => _sessionStats;
  PushConfig? get pushConfig => _pushConfig;

  /// 当前基线的累计读数（`null` = 没量到实时值）。
  int? get statsBaselineTokens => _statsBaselineTokens;

  /// 「本轮消耗」：回合结束（`done`）后由结束时的实时读数与回合开始前的基线
  /// 相减得到。
  ///
  /// **它要么是正数，要么是 null（面板显示「—」），永远不会是 0。** 三个原因：
  ///
  /// 1. 回合还没结束（或结束时的读数还没回来）→ 没有真值，显示「—」；
  /// 2. `tokenUsage` 是单调累计投影，结束时的读数若不是实时值（`cache` 快照，
  ///    可能是几小时前的），相减出来的不是"这一轮"；
  /// 3. `total - baseline == 0` 与"没量到"在界面上无法区分，而 0 会被读成
  ///    "这轮没花钱"——这是面板最不能显示的一个值，所以按未知处理。
  int? get lastTurnTokens {
    // [fix 2026-10-17] 先用引擎的**权威读数**：网关把该轮每个 step 的 usage 汇总到
    // 那一轮的 user 消息上（`ChatMessage.turnTokens`）。它不依赖"回合开始时 App 手里
    // 正好有一份实时基线"这个前提 —— 而那个前提一旦缺失（切会话、冷启动到一个正在
    // 跑的会话、轮末 App 不在前台），下面这套"两次读数相减"就永远出不来值，用户看到
    // 的是本轮消耗恒为 `—`。
    final authoritative = _authoritativeLastTurnTokens;
    if (authoritative != null && authoritative > 0) return authoritative;

    if (!_hasMeasuredTurn) return null;
    final burn = _measuredTurnTokens;
    if (burn == null || burn <= 0) return null;
    return burn;
  }

  /// 从消息里取最近一次**跑完的轮**的权威用量。
  ///
  /// 取最后一条带 `turnTokens` 的消息（不是"最后一条消息"）：当前这一轮还在跑时
  /// 没有值，面板该显示的是上一次跑完的读数，而不是一个中途的部分和。
  int? get _authoritativeLastTurnTokens {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final tokens = _messages[i].turnTokens;
      if (tokens != null) return tokens;
    }
    return null;
  }

  /// 回合开始时记下"开始前"的累计读数。
  void _captureStatsBaseline() {
    final stats = _sessionStats;
    // 只有实时读数才有资格当基线；`cache` 快照可能落后几个小时，拿它相减会
    // 算出一个凭空捏造的数字。
    _statsBaselineTokens =
        (stats != null && stats.isLive) ? stats.totalTokens : null;
  }

  /// 换会话时清掉上一个会话的全部读数。
  void _resetSessionInsights() {
    _deliverables = [];
    _deliverablesKnown = null;
    _deliverableEvents = 0;
    _workspaceChanges = [];
    _workspaceChangesReason = '';
    _workspaceChangesAvailable = false;
    _workspaceChangesSource = '';
    _workspaceChangesNote = '';
    _workspaceRepos = const <RepoCandidate>[];
    _changesKnown = null;
    _changesDirty = false;
    _schedules = [];
    _jobs = [];
    _jobsDegraded = '';
    _sessionStats = null;
    _statsBaselineTokens = null;
    _turnRunningSeen = false;
    _hasMeasuredTurn = false;
    _measuredTurnTokens = null;
    // [feat 2026-10-12] 子代理列表是会话域数据：切会话必须清，否则新会话的
    // 面板会短暂显示上一个会话的子代理（诊断是网关域的，故意不清）。
    _subagents = null;
    _subagentsUnavailable = false;
    // [feat 2026-10-16] 团队快照同理：它带着 Lead 和队友名字，留着会串会话。
    _team = null;
    _teamUnavailable = false;
  }

  /// 拉取当前会话的排队消息。
  ///
  /// 带 [_sessionLoadSeq] 守卫：切换会话后，旧会话的在途响应不得写回 —— 否则
  /// 用户在新会话里看到的是上一个会话的队列。
  Future<void> fetchQueue() async {
    final seq = _sessionLoadSeq;
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return;
    _queueLoading = true;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/queue')
              .replace(queryParameters: {'sessionId': sessionId});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 8));
      if (_checkResponseAuth(res)) return;
      if (seq != _sessionLoadSeq) return; // 会话已切换：丢弃这次响应
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final raw = data['queue'];
        if (raw is List) {
          _queueItems = raw
              .whereType<Map>()
              .map((e) => QueueItem.fromJson(Map<String, dynamic>.from(e)))
              .where((q) => q.id.isNotEmpty)
              .toList(growable: false);
          _queueError = '';
          _queueKnown = true;
        } else {
          // 200 但没有 queue 字段：路由/网关形态不对，不是"空队列"。
          _queueKnown = false;
          _queueError = '队列状态未知：服务端未返回 queue 字段';
        }
      } else {
        _queueKnown = false;
        _queueError = '读取排队消息失败 (HTTP ${res.statusCode})';
      }
    } catch (e) {
      debugPrint('[DshService] fetchQueue error: $e');
      if (seq == _sessionLoadSeq) {
        _queueKnown = false;
        _queueError = '读取排队消息失败: $e';
      }
    } finally {
      // 只清"加载中"这个纯装饰性的状态，不守卫：旧请求先返回时让它落下去，
      // 数据写入本身已经被 seq 守卫挡住，界面上宁可少转一会儿圈。
      _queueLoading = false;
      notifyListeners();
    }
  }

  /// 对一条排队消息执行 edit / remove / steer。
  ///
  /// **失败收敛（v1.14）**：动作失败后先 [fetchQueue] 对齐服务端真值，再看那条
  /// 消息还在不在队列里 ——
  ///
  ///   * 不在了 → 它已被引擎领走（正常时序），返回 [QueueActionOutcome.alreadyGone]，
  ///     由界面静默收敛（"这条已经发出去了"），**不报错**；
  ///   * 还在   → 真的失败（网络/权限/参数），返回 [QueueActionOutcome.failed]。
  ///
  /// 之所以不用引擎错误码判定：`session/steer-unavailable` / `session/queue-item-not-found`
  /// 在网关的 RPC 边界（`core.mjs` 的 `reject`）就被丢掉了，客户端拿不到；
  /// 禁止用错误文本做字符串匹配。等网关补上错误码透传后，这里可以升级成按码分支
  /// （行为不变，只是少一次多余的刷新）。
  Future<QueueActionOutcome> queueAction(String itemId, String kind,
      {String? text}) async {
    final injected = _debugQueueActionOutcome;
    if (injected != null) {
      // 测试注入：不打网关（见 debugSetQueueActionResult）。记下这一次调用，
      // 好让"第一次点击不该调它"成为可断言的。
      _debugLastQueueAction = '$kind:$itemId';
      return injected;
    }

    final seq = _sessionLoadSeq;
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null || itemId.isEmpty) {
      return QueueActionOutcome.failed;
    }
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/queue');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({
              'sessionId': sessionId,
              'itemId': itemId,
              'action': {
                'kind': kind,
                if (text != null) 'text': text,
              },
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return QueueActionOutcome.failed;
      if (res.statusCode == 200) {
        _queueError = '';
        await fetchQueue();
        return QueueActionOutcome.applied;
      }
      var msg = 'HTTP ${res.statusCode}';
      try {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        // 网关今天给的是字符串；不依赖它永远如此（对象直接 toString 会显示成
        // `[object Object]`，用户看不懂也排查不了）。
        final e = data['error'];
        if (e is String && e.isNotEmpty) {
          msg = e;
        } else if (e is Map && e['message'] is String) {
          msg = e['message'] as String;
        }
      } catch (_) {}
      return _settleFailedQueueAction(seq, itemId, '操作失败: $msg');
    } catch (e) {
      debugPrint('[DshService] queueAction error: $e');
      return _settleFailedQueueAction(seq, itemId, '操作失败: $e');
    }
  }

  /// 队列动作失败后的收敛判定：先对齐服务端真值，再决定这是不是真的失败。
  Future<QueueActionOutcome> _settleFailedQueueAction(
      int seq, String itemId, String fallbackError) async {
    // 切了会话就别再刷新了：fetchQueue 会去查新会话的队列，与这条动作无关。
    if (seq == _sessionLoadSeq) {
      await fetchQueue();
    }
    if (seq != _sessionLoadSeq) {
      // 会话已切换，无法判定这条消息的结局；不污染新会话的错误文案。
      return QueueActionOutcome.alreadyGone;
    }
    final stillQueued = _queueItems.any((q) => q.id == itemId);
    if (!stillQueued && _queueKnown == true) {
      // 刷新后它不在队列里 → 已被领走，属正常时序。
      _queueError = '';
      return QueueActionOutcome.alreadyGone;
    }
    _queueError = fallbackError;
    notifyListeners();
    return QueueActionOutcome.failed;
  }

  /// 运行中投递一条消息。
  ///
  /// **恒为排队**（`mode:'queue'`）：等这一轮跑完由引擎自动续发。要立刻插进
  /// 正在跑的回合，唯一的入口是队列条目上的「立即插话」（走 [queueAction] 的
  /// `steer`），并且要二次确认 —— 投递方式不再是一个能被记住的开关。
  ///
  /// 与 [sendChatMessage] 分开是刻意的：那条路径会乐观插入"用户气泡 + 助手
  /// 占位"，而排队消息属于 inbox，插入的气泡会和引擎回传的真值重复。这里只发、
  /// 然后以服务端的队列为准刷新界面。
  Future<bool> deliverWhileRunning(String text,
      {List<PendingAttachment> attachments = const []}) async {
    final injected = _debugDeliverResult;
    if (injected != null) {
      // 测试注入：不打网关（见 debugSetDeliverResult）。成功时按需补一条队列行，
      // 等价于"投递成功 → fetchQueue 后队列里多了一条"。
      if (injected && _debugDeliverAppendsRow != null) {
        _queueItems = [..._queueItems, _debugDeliverAppendsRow!];
        _queueKnown = true;
        notifyListeners();
      }
      return injected;
    }

    final seq = _sessionLoadSeq;
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return false;
    if (text.trim().isEmpty && attachments.isEmpty) return false;

    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/sessions/prompt');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({
              'sessionId': sessionId,
              'text': text,
              'model': currentModel,
              // 恒排队：运行中发出去的消息等本轮结束后自动发送。
              'mode': 'queue',
              if (attachments.isNotEmpty)
                'attachments': attachments.map((a) => a.toWirePart()).toList(),
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (_checkResponseAuth(res)) return false;
      if (res.statusCode == 200) {
        // 会话已切换：这条消息确实发出去了（返回 true 让调用方保留回执），
        // 但队列真值属于上一个会话，不能拿它刷新新会话的队列面板。
        if (seq == _sessionLoadSeq) await fetchQueue();
        return true;
      }
      _lastError = '发送失败 (HTTP ${res.statusCode})';
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('[DshService] deliverWhileRunning error: $e');
      _lastError = '发送失败: $e';
      notifyListeners();
      return false;
    }
  }

  /// 供下载类请求复用鉴权头（交付物下载走同一个令牌，不额外暴露任何东西）。
  Map<String, String> get authHeadersForDownload => _authHeaders;

  // ---- 测试注入点（会话洞察）----
  //
  // 这些字段只有 HTTP 一条写入路径，而单测里打真实网关会污染用户数据
  //（历史上正是这么累积出 1270 条空会话的）。所以给 UI 测试一个纯内存的
  // 注入口，让"页面渲染了什么"可以被钉住，而不必联网。
  @visibleForTesting
  void debugSetQueue(List<QueueItem> rows,
      {bool loading = false, String error = '', bool? known}) {
    _queueItems = rows;
    _queueLoading = loading;
    _queueError = error;
    // 未显式指定时按"有错误=读不到"推断，好让既有用例的语义不变
    // （`debugSetQueue([])` = 确实为空；`debugSetQueue([], error: …)` = 读不到）。
    _queueKnown = known ?? error.isEmpty;
    notifyListeners();
  }

  /// 摆布"当前会话在跑"这个状态（输入栏据此显示停止键）。
  @visibleForTesting
  void debugSetRunning(bool running) {
    _isSending = running;
    notifyListeners();
  }

  // ---- 运行中投递的测试注入口（v1.14）----
  //
  // 为什么必须有：`deliverWhileRunning` 与 `queueAction` 是仅有的两条"运行中
  // 投递"写路径，它们只有 HTTP 一个出口。要在 widget 测试里钉住"默认排队 / 二次
  // 确认才插话 / 失败回滚"这些交互，就得让它们可被摆布 —— 否则测试必然打真实网关、
  // 往用户的会话里塞消息（历史上正是这么累积出 1270 条空会话的）。
  // 置回 null 即恢复真实 HTTP 路径。

  bool? _debugDeliverResult;
  QueueItem? _debugDeliverAppendsRow;
  QueueActionOutcome? _debugQueueActionOutcome;
  String _debugLastQueueAction = '';

  /// 摆布 [deliverWhileRunning] 的返回值。`null` = 走真实请求。
  ///
  /// [appendsRow] 用来模拟"投递成功后重新拉队列，队列里多了一条" —— 没有它，
  /// 回执条上的「撤回」就没有可撤的目标，那条交互等于测不到。
  @visibleForTesting
  void debugSetDeliverResult(bool? ok, {QueueItem? appendsRow}) {
    _debugDeliverResult = ok;
    _debugDeliverAppendsRow = appendsRow;
    notifyListeners();
  }

  /// 摆布 [queueAction] 的返回值。`null` = 走真实请求。
  @visibleForTesting
  void debugSetQueueActionResult(QueueActionOutcome? outcome) {
    _debugQueueActionOutcome = outcome;
    notifyListeners();
  }

  /// 最后一次 [queueAction] 的 `kind:itemId`（空串 = 从未被调用）。
  ///
  /// 让"第一次点击只进入待确认态、不打网关"这类断言可以真正被验证，而不是
  /// 靠"没看到 toast"间接推断。
  @visibleForTesting
  String get debugLastQueueAction => _debugLastQueueAction;

  @visibleForTesting
  void debugSetTaskCenter({
    List<DeliverableItem>? deliverables,
    bool? deliverablesKnown,
    int? deliverableEvents,
    List<WorkspaceChange>? changes,
    bool? changesKnown,
    bool changesAvailable = false,
    String changesReason = '',
    List<ScheduleItem>? schedules,
    List<JobItem>? jobs,
    String jobsDegraded = '',
    SessionStats? stats,
    int? statsBaselineTokens,
    int? measuredTurnTokens,
    PushConfig? push,
  }) {
    if (deliverables != null) {
      _deliverables = deliverables;
      // 给了清单就默认"读到了"（这是绝大多数用例的意思），要测"读不到"显式传
      // deliverablesKnown: false / 只传 deliverablesKnown: null。
      _deliverablesKnown = deliverablesKnown ?? true;
    } else if (deliverablesKnown != null) {
      _deliverablesKnown = deliverablesKnown;
    }
    if (deliverableEvents != null) _deliverableEvents = deliverableEvents;
    if (changes != null) {
      _workspaceChanges = changes;
      _changesKnown = changesKnown ?? true;
    } else if (changesKnown != null) {
      _changesKnown = changesKnown;
    }
    _workspaceChangesAvailable = changesAvailable;
    _workspaceChangesReason = changesReason;
    if (schedules != null) _schedules = schedules;
    if (jobs != null) {
      _jobs = jobs;
      _jobsDegraded = jobsDegraded;
    }
    if (stats != null) _sessionStats = stats;
    if (statsBaselineTokens != null) _statsBaselineTokens = statsBaselineTokens;
    if (measuredTurnTokens != null) {
      _measuredTurnTokens = measuredTurnTokens;
      _hasMeasuredTurn = true;
    }
    if (push != null) _pushConfig = push;
    notifyListeners();
  }

  /// 交付物清单（Agent 用 present 声明的文件）。
  ///
  /// 带 [_sessionLoadSeq] 守卫：切会话后旧会话的响应不得写回。
  Future<void> fetchDeliverables() async {
    final seq = _sessionLoadSeq;
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/deliverables')
              .replace(queryParameters: {'sessionId': sessionId});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return;
      if (seq != _sessionLoadSeq) return; // 会话已切换：丢弃这次响应
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final raw = data['deliverables'];
        if (raw is List) {
          _deliverables = raw
              .whereType<Map>()
              .map(
                  (e) => DeliverableItem.fromJson(Map<String, dynamic>.from(e)))
              .where((d) => d.path.isNotEmpty)
              .toList(growable: false);
          _deliverablesKnown = true;
        } else {
          // 200 但没有这个字段：网关形态不对，不是"没有交付物"。
          _deliverablesKnown = false;
        }
        notifyListeners();
      } else {
        _deliverablesKnown = false;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DshService] fetchDeliverables error: $e');
      if (seq == _sessionLoadSeq) {
        _deliverablesKnown = false;
        notifyListeners();
      }
    }
  }

  /// 交付物下载地址（带鉴权头的请求由调用方发起）。
  Uri? deliverableUrl(DeliverableItem item) {
    if (_currentConfig == null || _currentSession == null) return null;
    return Uri.parse(
            '${_currentConfig!.httpBaseUrl}/api/mobile/deliverables/download')
        .replace(queryParameters: {
      'sessionId': _currentSession!.sessionId,
      'path': item.path,
    });
  }

  /// 本次任务改动的文件（git 工作树 + 本轮归属）。
  ///
  /// 清单本身仍是 `git status` 的**当前工作树**真值（累计未提交状态），但每行多了
  /// `thisTurn`：网关按「最新 `user/message` 之后的 `tool/call`」判定该文件是否属于
  /// 本轮，并把本轮的排在最前（[fix 2026-10-21]）。三态语义见 [WorkspaceChange
  /// .thisTurn]：`null` = 无法判定，界面不显示标记。
  ///
  /// 仍然拿不到的是**按轮拆分的历史**：引擎的 `workspace/changes` 事件只带轮号、
  /// 快照留在 Host 侧不可回放，所以变更清单不会像交付物那样挂到每轮消息后面。
  ///
  /// 带 [_sessionLoadSeq] 守卫。
  Future<void> fetchWorkspaceChanges() async {
    final seq = _sessionLoadSeq;
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return;
    try {
      final url = Uri.parse(
              '${_currentConfig!.httpBaseUrl}/api/mobile/workspace/changes')
          .replace(queryParameters: {'sessionId': sessionId});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
      if (_checkResponseAuth(res)) return;
      if (seq != _sessionLoadSeq) return; // 会话已切换：丢弃这次响应
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final raw = data['files'];
        _workspaceChanges = raw is List
            ? raw
                .whereType<Map>()
                .map((e) =>
                    WorkspaceChange.fromJson(Map<String, dynamic>.from(e)))
                .where((c) => c.path.isNotEmpty)
                .toList(growable: false)
            : const <WorkspaceChange>[];
        _workspaceChangesAvailable = data['available'] == true;
        _workspaceChangesReason = data['reason']?.toString() ?? '';
        // [feat 2026-10-13] Provenance + the reasons git could not answer.
        _workspaceChangesSource = data['source']?.toString() ?? '';
        _workspaceChangesNote = data['note']?.toString() ?? '';
        final repos = data['repoCandidates'];
        _workspaceRepos = repos is List
            ? repos
                .whereType<Map>()
                .map(
                    (e) => RepoCandidate.fromJson(Map<String, dynamic>.from(e)))
                .where((r) => r.name.isNotEmpty)
                .toList(growable: false)
            : const <RepoCandidate>[];
        // 只有真拿到 `files` 才算"读过"：否则"读不到"会被当成"工作区干净"。
        _changesKnown = raw is List;
        notifyListeners();
      } else {
        _changesKnown = false;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DshService] fetchWorkspaceChanges error: $e');
      if (seq == _sessionLoadSeq) {
        _changesKnown = false;
        notifyListeners();
      }
    }
  }

  /// 单个文件的 diff。返回空列表表示"无文本差异/二进制/读取失败"，
  /// 调用方据 [DiffResult.ok] 区分失败。
  Future<List<DiffHunk>> fetchDiff(String path) async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return const [];
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/workspace/diff')
              .replace(queryParameters: {'sessionId': sessionId, 'path': path});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
      if (_checkResponseAuth(res)) return const [];
      if (res.statusCode != 200) return const [];
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final raw = data['hunks'] as List<dynamic>? ?? [];
      return raw
          .whereType<Map>()
          .map((e) => DiffHunk.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    } catch (e) {
      debugPrint('[DshService] fetchDiff error: $e');
      return const [];
    }
  }

  /// 当前会话的定时任务。带 [_sessionLoadSeq] 守卫。
  Future<void> fetchSchedules() async {
    final seq = _sessionLoadSeq;
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/schedules')
              .replace(queryParameters: {'sessionId': sessionId});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return;
      if (seq != _sessionLoadSeq) return; // 会话已切换：丢弃这次响应
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final list = data['schedules'] as List<dynamic>? ?? [];
        _schedules = list
            .whereType<Map>()
            .map((e) => ScheduleItem.fromJson(Map<String, dynamic>.from(e)))
            .toList(growable: false);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DshService] fetchSchedules error: $e');
    }
  }

  Future<bool> deleteSchedule(String id) async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null || id.isEmpty) return false;
    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/schedules/delete');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({'sessionId': sessionId, 'id': id}),
          )
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return false;
      if (res.statusCode == 200) {
        await fetchSchedules();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[DshService] deleteSchedule error: $e');
      return false;
    }
  }

  /// 会话可见的后台作业。
  ///
  /// 网关在取不到作业流时会回 `degraded: 'jobs-unavailable'`（`features.mjs` 的
  /// jobs 路由读不到 `job/list` 帧时的降级）。旧代码只看 `jobs` 字段，于是"读不到"
  /// 和"没有后台作业"在界面上完全一样 —— 用户会以为真没作业在跑。这里把标记
  /// 原样暴露出去，由信息面板决定怎么说明。
  Future<void> fetchJobs() async {
    final seq = _sessionLoadSeq;
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return;
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/jobs')
          .replace(queryParameters: {'sessionId': sessionId});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 12));
      if (_checkResponseAuth(res)) return;
      if (seq != _sessionLoadSeq) return; // 会话已切换：丢弃这次响应
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final list = data['jobs'] as List<dynamic>? ?? [];
        _jobs = list
            .whereType<Map>()
            .map((e) => JobItem.fromJson(Map<String, dynamic>.from(e)))
            .where((j) => j.id.isNotEmpty)
            .toList(growable: false);
        _jobsDegraded = data['degraded']?.toString() ?? '';
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DshService] fetchJobs error: $e');
    }
  }

  /// 请求停止一个后台任务（v1.16 改：这是引擎的**真实**停止接口）。
  ///
  /// ⚠️ 更正（2026-10-13）：上一版把这个动作写成"交给 Agent 中介"，理由是据称
  /// 引擎没有停止作业的 Remote。该结论是错的 —— 它来自一个跳过了嵌套
  /// `node_modules` 的包扫描，因此漏掉了
  /// `@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-api-job-controller`：真实的
  /// `job/kill(request:{sessionId, jobId})` 就声明在那里，向运行中的引擎直接验证
  /// 也确认它确实被服务（会回真正的引擎错误 `unknown job …`）。所以中介逻辑已删除。
  ///
  /// 引擎回执 `requested` 是**已受理**而非**已终止**：生产者的 `cancel` 是异步的，
  /// 紧随其后的一次列表读取里任务仍可能是活的 —— 界面不能声称已经终止。
  /// `already-finished` 折成 [JobStopResult.alreadySettled]（无需停止，不是故障）。
  Future<JobStopResult> stopJob(String jobId) async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null || jobId.isEmpty) {
      return const JobStopResult(ok: false, error: '未连接');
    }
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/jobs/kill');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({'sessionId': sessionId, 'jobId': jobId}),
          )
          .timeout(const Duration(seconds: 20));
      if (_checkResponseAuth(res)) {
        return const JobStopResult(ok: false, error: '鉴权失败');
      }
      final body = res.bodyBytes.isEmpty
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
      if (res.statusCode == 200) {
        await fetchJobs();
        return JobStopResult(
            ok: true, outcome: body['outcome']?.toString() ?? 'requested');
      }
      if (res.statusCode == 409) {
        // 任务已经结束：刷新一次列表即可，不必报错。
        await fetchJobs();
        return JobStopResult(
          ok: false,
          outcome: 'already-finished',
          alreadySettled: true,
          error: body['error']?.toString() ?? '该任务已结束',
        );
      }
      if (res.statusCode == 404) {
        await fetchJobs();
        return JobStopResult(
          ok: false,
          notFound: true,
          error: body['error']?.toString() ?? '该任务不在本会话的可停止列表中',
        );
      }
      return JobStopResult(
          ok: false,
          error: body['error']?.toString() ?? 'HTTP ${res.statusCode}');
    } catch (e) {
      debugPrint('[DshService] stopJob error: $e');
      return const JobStopResult(ok: false, error: '请求失败或超时');
    }
  }

  /// 读取一个后台任务的输出（引擎 `job/follow` 流的一次轮询）。
  ///
  /// `from` 是续读游标：不传就从环里最早保留的字节开始，返回里的 `next` 供下一次
  /// 轮询使用。网关把它实现为受限帧收集（收到终结 `status` 帧、达到帧上限、或空闲
  /// 超时即返回），所以一个**仍在运行**的任务会立刻把"到目前为止"的输出交出来，
  /// 而不是把这个 HTTP 请求挂到任务结束 —— 那可能是几小时后。
  ///
  /// `lossy` 必须原样呈现：引擎可能已经丢弃了环的头部（或被保留策略裁掉），此时
  /// 界面必须说明"开头部分已丢失"，绝不能把不完整的日志当成完整日志展示。
  Future<JobOutputChunk> fetchJobOutput(String jobId, {int? from}) async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null || jobId.isEmpty) {
      return const JobOutputChunk(ok: false, error: '未连接');
    }
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/jobs/follow')
              .replace(
        queryParameters: {
          'sessionId': sessionId,
          'jobId': jobId,
          if (from != null) 'from': '$from',
        },
      );
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 25));
      if (_checkResponseAuth(res)) {
        return const JobOutputChunk(ok: false, error: '鉴权失败');
      }
      final body = res.bodyBytes.isEmpty
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
      if (res.statusCode == 200) return JobOutputChunk.fromJson(body);
      final parsed = JobOutputChunk.fromJson(body);
      return JobOutputChunk(
        ok: false,
        next: from,
        settled: parsed.settled,
        error: parsed.error.isEmpty ? 'HTTP ${res.statusCode}' : parsed.error,
      );
    } catch (e) {
      debugPrint('[DshService] fetchJobOutput error: $e');
      return const JobOutputChunk(ok: false, error: '请求失败或超时');
    }
  }

  // ---- [v1.35 / 3.1 + 3.3] Runbook 与告警 ----

  List<Map<String, dynamic>> _runbooks = const [];
  List<Map<String, dynamic>> _alerts = const [];
  int _alertUnread = 0;
  String? _runbookError;

  List<Map<String, dynamic>> get runbooks => _runbooks;
  List<Map<String, dynamic>> get alerts => _alerts;
  int get alertUnread => _alertUnread;
  String? get runbookError => _runbookError;

  /// 拉 Runbook 列表。返回错误文案（成功为 null）。
  Future<String?> refreshRunbooks() async {
    if (_currentConfig == null) return '尚未连接网关';
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/runbooks');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return '认证失败';
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final list = (data['runbooks'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
      _runbooks = list;
      _runbookError = data['error']?.toString();
      notifyListeners();
      return _runbookError;
    } catch (e) {
      debugPrint('[DshService] refreshRunbooks error: $e');
      _runbookError = '$e';
      notifyListeners();
      return _runbookError;
    }
  }

  /// 执行一条 Runbook。返回网关原始结果（含 outputTail / exitCode / code）。
  Future<Map<String, dynamic>?> runRunbookCommand(String id,
      {bool confirm = false, String? sessionId}) async {
    if (_currentConfig == null) return null;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/runbooks/run');
      final res = await _httpClient
          .post(
            url,
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode({
              'id': id,
              if (confirm) 'confirm': true,
              if (sessionId != null && sessionId.isNotEmpty)
                'sessionId': sessionId,
            }),
          )
          .timeout(const Duration(seconds: 40));
      if (_checkResponseAuth(res)) return {'ok': false, 'code': 'auth'};
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (e) {
      debugPrint('[DshService] runRunbookCommand error: $e');
      return {'ok': false, 'code': 'network', 'error': '$e'};
    }
  }

  Future<void> refreshAlerts() async {
    if (_currentConfig == null) return;
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/alerts');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return;
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      _alerts = (data['alerts'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
      _alertUnread = data['unread'] is int ? data['unread'] as int : 0;
      notifyListeners();
    } catch (e) {
      debugPrint('[DshService] refreshAlerts error: $e');
    }
  }

  Future<int> markAlertsRead(
      {List<String> ids = const [], bool all = false}) async {
    if (_currentConfig == null) return 0;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/alerts/read');
      final res = await _httpClient
          .post(
            url,
            headers: {..._authHeaders, 'Content-Type': 'application/json'},
            body: jsonEncode({'ids': ids, 'all': all}),
          )
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return 0;
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final changed = data['changed'] is int ? data['changed'] as int : 0;
      _alertUnread =
          data['unread'] is int ? data['unread'] as int : _alertUnread;
      notifyListeners();
      return changed;
    } catch (e) {
      debugPrint('[DshService] markAlertsRead error: $e');
      return 0;
    }
  }

  // ---- 一键诊断 / 子代理中断 / goal 控制 / slash 命令 [feat 2026-10-12] ----

  // ---- [refactor 2026-10-21] 远程接入（取代旧的「云隧道开关」）----
  //
  // NPS 与 cloudflared 是同一职责的两种 provider，严格互斥；启停由网关按配置
  // 自动处理（cloudflared 随网关启动拉起、退出回收）。客户端**没有**开关，
  // 只有状态 —— 上一版把隧道启停放在手机上是个死循环：隧道没开时手机根本
  // 连不上，那个按钮点不到。

  RemoteAccessState? _remoteAccess;

  /// 最近一次远程接入状态。null = 还没查过。
  RemoteAccessState? get remoteAccess => _remoteAccess;

  Future<RemoteAccessState?> refreshRemoteAccess() async {
    if (_currentConfig == null) return null;
    final url =
        Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/remote-access');
    try {
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return null;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        if (data is Map) {
          _remoteAccess =
              RemoteAccessState.fromJson(Map<String, dynamic>.from(data));
          notifyListeners();
          return _remoteAccess;
        }
      }
    } catch (e) {
      // 连不上网关时保留上一次的快照：这一页本身可能就是断网时打开的，
      // 清空只会让用户连"上次是什么状态"都看不到。
      debugPrint('[DshService] refreshRemoteAccess error: $e');
    }
    return _remoteAccess;
  }

  /// 一键连接诊断。永不抛异常：网关保证各项 check 都有答案（引擎挂掉只让
  /// `engine_rpc` 变 ok:false），这里再把网络层异常兜成一份最小失败报告。
  Future<DiagnosticsReport?> runDiagnostics() async {
    if (_currentConfig == null) return null;
    _diagnosticsBusy = true;
    notifyListeners();
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/diagnostics');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
      if (_checkResponseAuth(res)) return null;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        _diagnostics =
            DiagnosticsReport.fromJson(Map<String, dynamic>.from(data));
        return _diagnostics;
      }
    } catch (e) {
      debugPrint('[DshService] runDiagnostics error: $e');
    } finally {
      _diagnosticsBusy = false;
      notifyListeners();
    }
    return null;
  }

  /// 当前会话的子代理列表。引擎没有列出能力/失败时返回 null（界面隐藏该区块）。
  Future<List<SubagentItem>?> fetchSubagents() async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return null;
    try {
      final url = Uri.parse(
              '${_currentConfig!.httpBaseUrl}/api/mobile/sessions/subagents')
          .replace(queryParameters: {'sessionId': sessionId});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return null;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        // 键名兼容：网关回的是 `entries`（与历史 HTTP 契约一致），
        // 也接受 `subagents`（早期草稿的命名）—— 两边都认，避免又一次"字段名
        // 不一致 → 整块不显示"的静默失败。
        final raw = data['entries'] ?? data['subagents'];
        _subagents = raw is List
            ? raw
                .whereType<Map>()
                .map((e) => SubagentItem.fromJson(Map<String, dynamic>.from(e)))
                .where((s) => s.id.isNotEmpty)
                .toList(growable: false)
            : const <SubagentItem>[];
        _subagentsUnavailable = false;
        notifyListeners();
        return _subagents;
      }
      // 501/502：引擎没有列出能力或 RPC 失败 —— 明确"未知"，不落成假空表。
      _subagents = null;
      _subagentsUnavailable = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[DshService] fetchSubagents error: $e');
      _subagents = null;
      _subagentsUnavailable = true;
      notifyListeners();
    }
    return null;
  }

  /// 当前会话的智能体团队快照（Lead + 队友 + 共享任务板）。 [feat 2026-10-16]
  ///
  /// 与 [fetchSubagents] 的区别：子代理是「我派出去的一次委派」，团队是
  /// 「Lead + 多个有名有姓的队友 + 共享任务板」，且队友同时也会出现在
  /// 子代理列表里。两者都要显示，不能二选一。
  ///
  /// 返回 null 表示取不到（网络失败 / 网关未升级）；此时 UI 应显示"状态未知"
  /// 而不是空列表 —— 空列表会被读成"团队没了"。
  Future<AgentTeam?> fetchTeam() async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return null;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/team')
              .replace(queryParameters: {'sessionId': sessionId});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return null;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        if (data is! Map) return null;
        final team = AgentTeam.fromJson(Map<String, dynamic>.from(data));
        _team = team;
        _teamUnavailable = false;
        notifyListeners();
        return team;
      }
      _team = null;
      _teamUnavailable = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[DshService] fetchTeam error: $e');
      _team = null;
      _teamUnavailable = true;
      notifyListeners();
    }
    return null;
  }

  /// 中断一个 continuable 子代理（引擎对 one-shot 一律拒绝，App 端提前拦下）。
  Future<bool> interruptSubagent(String childSessionId) async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null || childSessionId.isEmpty) {
      return false;
    }
    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/sessions/subagents/interrupt');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({
              'parentSessionId': sessionId,
              'childSessionId': childSessionId
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return false;
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[DshService] interruptSubagent error: $e');
      return false;
    }
  }

  /// goal 操作：pause / resume / complete。ref 来自最近一次 session/stats。
  /// 引擎拒绝（502）时返回 false，由界面显示"引擎拒绝了这次操作"。
  Future<bool> controlGoal(String action,
      {required String goalId, required int revision}) async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return false;
    if (!const {'pause', 'resume', 'complete'}.contains(action)) return false;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/goals/$action');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({
              'sessionId': sessionId,
              'goalId': goalId,
              'revision': revision
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return false;
      if (res.statusCode == 200) {
        // 引擎的 goal 操作改了 revision：立刻重读 stats，让面板的 ref 和相位
        // 跟上，否则下一次操作会带着旧 revision 被拒。
        await fetchSessionStats();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[DshService] controlGoal error: $e');
      return false;
    }
  }

  // ---- v1.16 bridge extensions (P0/P1, 2026-10-13) ----
  //
  // Design note that governs every method below: unlike the v1.13 task-center
  // fetches, these do **not** write into service-wide fields. The v1.13 fetch
  // family stores into `_jobs` / `_workspaceChanges` / … and notifies listeners
  // on every poll, which was fine for one panel but would turn a file browser
  // into a rebuild storm — every directory tap would rebuild the whole chat
  // subtree. So each method here is a **stateless request** that returns its
  // result; the page that opened it owns the state. The three genuinely
  // session-scoped reads that already existed (deliverables, jobs, changes) keep
  // their fields and are simply extended.
  //
  // Every method also honours the auth-failure hook (`_checkResponseAuth`) and
  // returns the null/empty/`ok:false` shape of its type rather than throwing, so
  // a page can render a reason instead of an exception screen.

  /// Repositories the current session's workspace maps to (P0-1).
  ///
  /// Null means "could not ask" (no config, no session, transport failure) —
  /// which is deliberately different from `available: false`, i.e. "asked and
  /// there is no repository". The panel renders those two states differently.
  Future<WorkspaceRepos?> fetchWorkspaceRepos() async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return null;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/workspace/repos')
              .replace(queryParameters: {'sessionId': sessionId});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
      if (_checkResponseAuth(res)) return null;
      if (res.statusCode != 200) return null;
      return WorkspaceRepos.fromJson(
          Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes))));
    } catch (e) {
      debugPrint('[DshService] fetchWorkspaceRepos error: $e');
      return null;
    }
  }

  /// The whitelisted command catalog (P1-5).
  ///
  /// Not session-scoped: the catalog is a server-side constant, so it is fetched
  /// once per panel open rather than per session. An empty list is a real
  /// answer ("no commands configured"), so callers must not treat it as an error.
  Future<List<QuickCommandInfo>> fetchQuickCommands() async {
    if (_currentConfig == null) return const [];
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/quick-commands');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return const [];
      if (res.statusCode != 200) return const [];
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final raw = data['commands'];
      return raw is List
          ? raw
              .whereType<Map>()
              .map((e) =>
                  QuickCommandInfo.fromJson(Map<String, dynamic>.from(e)))
              .where((c) => c.id.isNotEmpty)
              .toList(growable: false)
          : const <QuickCommandInfo>[];
    } catch (e) {
      debugPrint('[DshService] fetchQuickCommands error: $e');
      return const [];
    }
  }

  /// Run one whitelisted command in the session workspace (P1-5).
  ///
  /// Only the catalogue id crosses the wire; the gateway resolves it to a fixed
  /// argv. There is no parameter to inject because none exists.
  Future<QuickCommandResult> runQuickCommand(
    String id, {
    Duration timeout = const Duration(seconds: 40),
  }) async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null || id.isEmpty) {
      return const QuickCommandResult(ok: false, error: '没有可用的会话');
    }
    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/quick-commands/run');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({'sessionId': sessionId, 'id': id}),
          )
          .timeout(timeout);
      if (_checkResponseAuth(res)) {
        return const QuickCommandResult(ok: false, error: '鉴权失败');
      }
      final body = res.bodyBytes.isEmpty
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
      final parsed = QuickCommandResult.fromJson(body);
      if (res.statusCode == 200) return parsed;
      // Non-200 keeps `ok:false` and surfaces the gateway's reason, which is
      // actionable ("该会话没有可用的工作目录") where a bare status is not.
      return QuickCommandResult(
          ok: false,
          id: id,
          error:
              parsed.error.isEmpty ? 'HTTP ${res.statusCode}' : parsed.error);
    } catch (e) {
      debugPrint('[DshService] runQuickCommand error: $e');
      return const QuickCommandResult(ok: false, error: '请求失败或超时');
    }
  }

  /// List one workspace directory (P1-9). Read-only by construction.
  Future<FsListing> fsList(String relPath) async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) {
      return const FsListing(ok: false, error: '没有可用的会话');
    }
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/fs/list')
          .replace(queryParameters: {
        'sessionId': sessionId,
        if (relPath.isNotEmpty) 'path': relPath
      });
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
      if (_checkResponseAuth(res)) {
        return const FsListing(ok: false, error: '鉴权失败');
      }
      final body = res.bodyBytes.isEmpty
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
      final parsed = FsListing.fromJson(body);
      if (res.statusCode == 200) return parsed;
      return FsListing(
          ok: false,
          path: relPath,
          error:
              parsed.error.isEmpty ? 'HTTP ${res.statusCode}' : parsed.error);
    } catch (e) {
      debugPrint('[DshService] fsList error: $e');
      return const FsListing(ok: false, error: '请求失败或超时');
    }
  }

  /// Read one workspace file, capped by the gateway (P1-9).
  Future<TextFileContent> fsRead(String relPath) async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) {
      return const TextFileContent(ok: false, error: '没有可用的会话');
    }
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/fs/read')
          .replace(queryParameters: {'sessionId': sessionId, 'path': relPath});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
      if (_checkResponseAuth(res)) {
        return const TextFileContent(ok: false, error: '鉴权失败');
      }
      final body = res.bodyBytes.isEmpty
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
      final parsed = TextFileContent.fromJson(body);
      if (res.statusCode == 200) return parsed;
      return TextFileContent(
          ok: false,
          path: relPath,
          error:
              parsed.error.isEmpty ? 'HTTP ${res.statusCode}' : parsed.error);
    } catch (e) {
      debugPrint('[DshService] fsRead error: $e');
      return const TextFileContent(ok: false, error: '请求失败或超时');
    }
  }

  /// Text preview of one declared deliverable (P0-4).
  ///
  /// Membership is enforced by the gateway against the same set the download
  /// route uses, so a path the session never presented is refused with 403
  /// rather than served.
  Future<TextFileContent> fetchDeliverableText(String path) async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null || path.isEmpty) {
      return const TextFileContent(ok: false, error: '没有可用的会话');
    }
    try {
      final url = Uri.parse(
              '${_currentConfig!.httpBaseUrl}/api/mobile/deliverables/text')
          .replace(queryParameters: {'sessionId': sessionId, 'path': path});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 20));
      if (_checkResponseAuth(res)) {
        return const TextFileContent(ok: false, error: '鉴权失败');
      }
      final body = res.bodyBytes.isEmpty
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
      final parsed = TextFileContent.fromJson(body);
      if (res.statusCode == 200) return parsed;
      return TextFileContent(
          ok: false,
          path: path,
          error:
              parsed.error.isEmpty ? 'HTTP ${res.statusCode}' : parsed.error);
    } catch (e) {
      debugPrint('[DshService] fetchDeliverableText error: $e');
      return const TextFileContent(ok: false, error: '请求失败或超时');
    }
  }

  /// Custom approval presets stored on the gateway (P0-2).
  ///
  /// Returns null on "could not ask". The built-in presets live in the App as a
  /// Dart enum and are merged by the caller, so this list is customs only.
  Future<List<ApprovalPresetInfo>?> fetchApprovalPresets() async {
    if (_currentConfig == null) return null;
    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/approval-presets');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return null;
      if (res.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final raw = data['presets'];
      return raw is List
          ? raw
              .whereType<Map>()
              .map((e) =>
                  ApprovalPresetInfo.fromJson(Map<String, dynamic>.from(e)))
              .where((p) => p.id.isNotEmpty)
              .toList(growable: false)
          : const <ApprovalPresetInfo>[];
    } catch (e) {
      debugPrint('[DshService] fetchApprovalPresets error: $e');
      return null;
    }
  }

  /// Create or update one custom preset. Returns the gateway's error text, or
  /// null on success — the editor shows the reason inline.
  Future<String?> saveApprovalPreset({
    String? id,
    required String label,
    required String summary,
    required PresetConfig config,
  }) async {
    if (_currentConfig == null) return '未连接';
    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/approval-presets/save');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({
              if (id != null && id.isNotEmpty) 'id': id,
              'label': label,
              'summary': summary,
              'config': config.toJson(),
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return '鉴权失败';
      if (res.statusCode == 200) return null;
      final body = res.bodyBytes.isEmpty
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
      return body['error']?.toString() ?? 'HTTP ${res.statusCode}';
    } catch (e) {
      debugPrint('[DshService] saveApprovalPreset error: $e');
      return '请求失败或超时';
    }
  }

  /// Delete one custom preset. Built-in ids are refused by the gateway.
  Future<String?> deleteApprovalPreset(String id) async {
    if (_currentConfig == null) return '未连接';
    try {
      final url = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/approval-presets/delete');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({'id': id}),
          )
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return '鉴权失败';
      if (res.statusCode == 200) return null;
      final body = res.bodyBytes.isEmpty
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
      return body['error']?.toString() ?? 'HTTP ${res.statusCode}';
    } catch (e) {
      debugPrint('[DshService] deleteApprovalPreset error: $e');
      return '请求失败或超时';
    }
  }

  /// Mint a fresh ntfy topic on the gateway and turn push on (P0-3).
  ///
  /// The topic is random by design: ntfy topics are public by name, so a
  /// memorable default would publish every approval prompt to whoever guessed
  /// it. Null means the call failed; the settings page then keeps the manual
  /// fields as the fallback path.
  Future<PushTopicResult?> autoConfigurePushTopic({String? url}) async {
    if (_currentConfig == null) return null;
    try {
      final target = Uri.parse(
          '${_currentConfig!.httpBaseUrl}/api/mobile/push/auto-topic');
      final res = await _httpClient
          .post(
            target,
            headers: _authHeaders,
            body: jsonEncode(
                {if (url != null && url.trim().isNotEmpty) 'url': url.trim()}),
          )
          .timeout(const Duration(seconds: 15));
      if (_checkResponseAuth(res)) return null;
      if (res.statusCode != 200) return null;
      final parsed = PushTopicResult.fromJson(
          Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes))));
      // Keep the cached config in step so the settings card redraws immediately.
      _pushConfig = PushConfig(
        enabled: parsed.enabled,
        url: parsed.url,
        topic: parsed.topic,
        hasToken: parsed.hasToken,
      );
      notifyListeners();
      return parsed;
    } catch (e) {
      debugPrint('[DshService] autoConfigurePushTopic error: $e');
      return null;
    }
  }

  /// Full goal board state for the current session (P1-7).
  Future<GoalBoard?> fetchGoalBoard() async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return null;
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/goals')
          .replace(queryParameters: {'sessionId': sessionId});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return null;
      if (res.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final goal = data['goal'];
      if (goal is! Map) return null;
      return GoalBoard.fromJson(Map<String, dynamic>.from(goal));
    } catch (e) {
      debugPrint('[DshService] fetchGoalBoard error: $e');
      return null;
    }
  }

  /// Create a goal from the phone (`goals/create`). Returns an error or null.
  Future<String?> createGoal(String objective, {int? maxGoalRounds}) async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return '未连接';
    final text = objective.trim();
    if (text.isEmpty) return '目标描述不能为空';
    if (text.length > 2000) return '目标描述过长（上限 2000 字）';
    if (maxGoalRounds != null && maxGoalRounds <= 0) return '轮数上限必须为正整数';
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/goals/create');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({
              'sessionId': sessionId,
              'objective': text,
              if (maxGoalRounds != null) 'maxGoalRounds': maxGoalRounds,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (_checkResponseAuth(res)) return '鉴权失败';
      if (res.statusCode == 200) {
        await fetchSessionStats();
        return null;
      }
      final body = res.bodyBytes.isEmpty
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
      return body['error']?.toString() ?? 'HTTP ${res.statusCode}';
    } catch (e) {
      debugPrint('[DshService] createGoal error: $e');
      return '请求失败或超时';
    }
  }

  /// Edit the current goal's objective and/or round cap (`goals/edit`).
  ///
  /// The CAS ref is mandatory: every durable mutation increments `revision`, so
  /// an edit sent with a stale one must fail rather than overwrite a newer goal.
  Future<String?> editGoal({
    required String goalId,
    required int revision,
    String? objective,
    int? maxGoalRounds,
  }) async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return '未连接';
    if (goalId.isEmpty || revision <= 0) return '缺少目标 ref（id/revision）';
    if ((objective == null || objective.trim().isEmpty) &&
        maxGoalRounds == null) {
      return '至少要改一项（目标描述或轮数上限）';
    }
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/goals/edit');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode({
              'sessionId': sessionId,
              'goalId': goalId,
              'revision': revision,
              if (objective != null && objective.trim().isNotEmpty)
                'objective': objective.trim(),
              if (maxGoalRounds != null) 'maxGoalRounds': maxGoalRounds,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (_checkResponseAuth(res)) return '鉴权失败';
      if (res.statusCode == 200) {
        await fetchSessionStats();
        return null;
      }
      final body = res.bodyBytes.isEmpty
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
      return body['error']?.toString() ?? 'HTTP ${res.statusCode}';
    } catch (e) {
      debugPrint('[DshService] editGoal error: $e');
      return '请求失败或超时';
    }
  }

  /// Turn boundaries the current session can be forked from (P1-8).
  Future<List<SessionCheckpoint>> fetchCheckpoints() async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return const [];
    try {
      final url = Uri.parse(
              '${_currentConfig!.httpBaseUrl}/api/mobile/sessions/checkpoints')
          .replace(queryParameters: {'sessionId': sessionId});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 30));
      if (_checkResponseAuth(res)) return const [];
      if (res.statusCode != 200) return const [];
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final raw = data['checkpoints'];
      return raw is List
          ? raw
              .whereType<Map>()
              .map((e) =>
                  SessionCheckpoint.fromJson(Map<String, dynamic>.from(e)))
              .where((c) => c.seq != null)
              .toList(growable: false)
          : const <SessionCheckpoint>[];
    } catch (e) {
      debugPrint('[DshService] fetchCheckpoints error: $e');
      return const [];
    }
  }

  /// Fork the current session from a completed turn (`session/fork`).
  ///
  /// Returns the new session id, or an error string. A null `atSeq` forks the
  /// whole session. `fork-unavailable` (409) means the referenced turn never
  /// completed; the picker prevents that case, and this surfaces it if it slips
  /// through.
  Future<ForkOutcome> forkSession({int? atSeq}) async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) {
      return const ForkOutcome(ok: false, error: '未连接');
    }
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/fork');
      final res = await _httpClient
          .post(
            url,
            headers: _authHeaders,
            body: jsonEncode(
                {'sessionId': sessionId, if (atSeq != null) 'atSeq': atSeq}),
          )
          .timeout(const Duration(seconds: 30));
      if (_checkResponseAuth(res)) {
        return const ForkOutcome(ok: false, error: '鉴权失败');
      }
      final body = res.bodyBytes.isEmpty
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)));
      if (res.statusCode == 200) {
        final newId = body['sessionId']?.toString() ?? '';
        if (newId.isEmpty) {
          return const ForkOutcome(ok: false, error: '引擎未返回新会话 id');
        }
        return ForkOutcome(ok: true, sessionId: newId);
      }
      return ForkOutcome(
        ok: false,
        error: body['error']?.toString() ?? 'HTTP ${res.statusCode}',
        unavailable: res.statusCode == 409,
      );
    } catch (e) {
      debugPrint('[DshService] forkSession error: $e');
      return const ForkOutcome(ok: false, error: '请求失败或超时');
    }
  }

  /// 会话可用的 slash 命令。失败/降级返回空列表（界面隐藏 "/" 入口）。
  Future<List<SlashCommand>> fetchCommands() async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return const [];
    try {
      final url = Uri.parse(
              '${_currentConfig!.httpBaseUrl}/api/mobile/sessions/commands')
          .replace(queryParameters: {'sessionId': sessionId});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return const [];
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final raw = data['commands'];
        return raw is List
            ? raw
                .whereType<Map>()
                .map((e) => SlashCommand.fromJson(Map<String, dynamic>.from(e)))
                .where((c) => c.name.isNotEmpty)
                .toList(growable: false)
            : const <SlashCommand>[];
      }
    } catch (e) {
      debugPrint('[DshService] fetchCommands error: $e');
    }
    return const [];
  }

  /// skill 目录（`GET /api/mobile/sessions/skills`）。[feat 2026-10-21]
  ///
  /// 与 [fetchCommands] 是**两路**数据：引擎的 `commands/list` 只给注册过的斜杠
  /// 命令，skill 走独立的 `skills/list`。web 端把两者合并成 `/` 菜单，手机端
  /// 此前只取了前者。取不到就返回空表（菜单里不塞假条目）。
  Future<List<SkillCatalogEntry>> fetchSkills() async {
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return const [];
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/skills')
              .replace(queryParameters: {'sessionId': sessionId});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return const [];
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final raw = data['skills'];
        return raw is List
            ? raw
                .whereType<Map>()
                .map((e) =>
                    SkillCatalogEntry.fromJson(Map<String, dynamic>.from(e)))
                .where((s) => s.name.isNotEmpty)
                .toList(growable: false)
            : const <SkillCatalogEntry>[];
      }
    } catch (e) {
      debugPrint('[DshService] fetchSkills error: $e');
    }
    return const [];
  }

  /// 用量 / 上下文压力 / goal。带 [_sessionLoadSeq] 守卫。
  ///
  /// [endOfTurn] 为 true 表示这是 `done` 之后为了量"本轮消耗"补的一次读：
  /// 拿到实时值后记下 `本轮 = 新值 − 回合开始前的基线`，并把基线**推进**到新值。
  ///
  /// 为什么基线不能在 `done` 那一帧就地设置：`done` 时手里还是**回合开始前**的
  /// 读数，拿它做基线再相减就是 `total - total = 0` —— 而 0 是面板最不能显示的
  /// 值（用户读成"这轮没花钱"）。所以基线只在**回合开始的上升沿**记，`done` 之后
  /// 再取一次终值来相减，量到的结果存进 [_measuredTurnTokens]。
  Future<void> fetchSessionStats({bool endOfTurn = false}) async {
    final seq = _sessionLoadSeq;
    final sessionId = _currentSession?.sessionId;
    if (_currentConfig == null || sessionId == null) return;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/session/stats')
              .replace(queryParameters: {'sessionId': sessionId});
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return;
      if (seq != _sessionLoadSeq) return; // 会话已切换：丢弃这次响应
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final stats = data['stats'];
        if (stats is Map) {
          final parsed =
              SessionStats.fromJson(Map<String, dynamic>.from(stats));
          _sessionStats = parsed;
          if (endOfTurn) {
            _measuredTurnTokens = SessionStats.turnDelta(
                baseline: _statsBaselineTokens, now: parsed);
            _hasMeasuredTurn = true;
            // 基线推进到本回合终值：下一次相减只覆盖下一个回合。
            if (parsed.isLive && parsed.totalTokens != null) {
              _statsBaselineTokens = parsed.totalTokens;
            }
          }
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('[DshService] fetchSessionStats error: $e');
    }
  }

  // ---- 会话洞察的三档加载 ----
  //
  // 分档的依据是**每一条请求的真实成本**（按服务端实现读出来的，不是猜的）：
  //
  //   本地投影读（不跨进程）          `session/stats`、`sessions/queue`
  //   一次 MUX RPC                    `deliverables`（session/page 200 条）、`schedules`
  //   一个 git 子进程                 `workspace/changes`
  //   流 RPC + 等首帧 + 5s 超时       `jobs`
  //
  // 旧实现是"进任务页就 `Future.wait` 全部六个"，等于把最贵的两个放在最频繁的
  // 动作上。现在：进会话拉便宜的，紧接补状态条要的两个，最贵的两个只在用户
  // 真的打开面板时才拉。**全程零 Timer**。

  /// 第一档：进会话立即。两个都是本地投影读。
  Future<void> fetchSessionOverview() async {
    await Future.wait([fetchSessionStats(), fetchQueue()]);
  }

  /// 第二档：进会话后紧接一次、可取消（会话切走就不继续为旧会话跑 git）。
  ///
  /// 这两个决定状态条上的 `产出 N` / `改动 N`，必须在进会话后不久就正确 ——
  /// 否则用户又得跳出去看。但它们比第一档贵，所以不参与首帧。
  Future<void> fetchSessionSecondary() async {
    final seq = _sessionLoadSeq;
    await fetchDeliverables();
    if (seq != _sessionLoadSeq) return;
    await fetchWorkspaceChanges();
  }

  /// 第三档：**只在信息面板打开时**拉（面板的 `onRefresh` 也用它）。
  Future<void> fetchSessionExtras() async {
    await Future.wait([
      fetchJobs(),
      fetchSchedules(),
      fetchSubagents(),
      fetchTeam()
    ]); // [feat 2026-10-12] 子代理随面板懒加载；[feat 2026-10-16] 团队同批
  }

  /// 下载交付物并交给系统应用打开。
  ///
  /// 返回空串表示成功，否则是给用户看的失败说明 —— 由卡片/面板**内联**显示，
  /// 不用会自己消失的 SnackBar。
  ///
  /// 走原生通道而不是"写入 App 私有目录再给个路径"：Android 上文件要被外部应用
  /// 打开必须过 FileProvider，而缓存目录只有原生侧知道。字节在这里读齐（带鉴权头），
  /// 原生只负责落盘 + 拉起 Intent。
  ///
  /// `item.path` 必须是 REST 返回的**绝对路径**：下载路由按绝对路径做精确成员
  /// 判定，用 WS 帧里的相对路径会被判 403。
  Future<String> openDeliverable(DeliverableItem item) async {
    final uri = deliverableUrl(item);
    if (uri == null) return '当前没有可用的网关配置';
    try {
      final res = await _httpClient
          .get(uri, headers: _authHeaders)
          .timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) return '下载失败 (HTTP ${res.statusCode})';
      final ok = await FileOpener.openBytes(item.fileName, res.bodyBytes);
      if (!ok) return '已下载，但没有应用能打开 ${item.fileName}';
      return '';
    } catch (e) {
      debugPrint('[DshService] openDeliverable error: $e');
      return '下载失败: $e';
    }
  }

  // ---- 离线推送（ntfy）配置 ----

  Future<void> fetchPushConfig() async {
    if (_currentConfig == null) return;
    try {
      final url =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/push/config');
      final res = await _httpClient
          .get(url, headers: _authHeaders)
          .timeout(const Duration(seconds: 8));
      if (_checkResponseAuth(res)) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final push = data['push'];
        if (push is Map) {
          _pushConfig = PushConfig.fromJson(Map<String, dynamic>.from(push));
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('[DshService] fetchPushConfig error: $e');
    }
  }

  Future<bool> savePushConfig({
    bool? enabled,
    String? url,
    String? topic,
    String? token,
  }) async {
    if (_currentConfig == null) return false;
    try {
      final uri =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/push/config');
      final res = await _httpClient
          .post(
            uri,
            headers: _authHeaders,
            body: jsonEncode({
              if (enabled != null) 'enabled': enabled,
              if (url != null) 'url': url,
              if (topic != null) 'topic': topic,
              if (token != null) 'token': token,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (_checkResponseAuth(res)) return false;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final push = data['push'];
        if (push is Map) {
          _pushConfig = PushConfig.fromJson(Map<String, dynamic>.from(push));
          notifyListeners();
        }
        return true;
      }
      _lastError = '保存推送配置失败 (HTTP ${res.statusCode})';
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('[DshService] savePushConfig error: $e');
      _lastError = '保存推送配置失败: $e';
      notifyListeners();
      return false;
    }
  }

  Future<bool> testPush() async {
    if (_currentConfig == null) return false;
    try {
      final uri =
          Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/push/test');
      final res = await _httpClient
          .post(uri, headers: _authHeaders, body: '{}')
          .timeout(const Duration(seconds: 12));
      if (_checkResponseAuth(res)) return false;
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[DshService] testPush error: $e');
      return false;
    }
  }

  // Incoming WebSocket Message Processing
  void _handleRawMessage(dynamic raw) {
    // 任何服务器帧都喂看门狗 —— pong、系统帧、数据帧都算"连接活着"的证据。
    _lastServerFrameAt = DateTime.now();
    _noteServerFrame();
    if (raw is! String) return;
    if (raw == 'pong') return;

    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return;

      final type = json['type'] ?? json['event'];
      if (type == 'pong') return;

      // Auth error check from WS frame
      if (json['code'] == 401 ||
          json['type'] == 'unauthorized' ||
          json['status'] == 401) {
        handleAuthFailure(json['error']?.toString() ??
            json['message']?.toString() ??
            '认证失败: Token无效');
        return;
      }

      // [feat 2026-10-12] 电脑端撤销设备的广播帧。广播发给**所有**在线客户端，
      // 只有本机 deviceId 命中才清凭据断连；deviceId 未知（旧配置）时退化为
      // 忽略广播 —— 等 HTTP 轮询的 401+device_revoked 再处理，避免误伤别的设备。
      if (type == 'device_revoked') {
        final myId = _currentConfig?.deviceId ?? '';
        final revokedId = json['deviceId']?.toString() ?? '';
        if (myId.isNotEmpty && revokedId == myId) {
          unawaited(handleDeviceRevoked());
        }
        return;
      }

      // 1. Initial pending approvals from server
      if (type == 'system' && json['pendingApprovals'] is List) {
        final list = json['pendingApprovals'] as List<dynamic>;
        _pendingApprovals = list
            .map((a) => ApprovalRequest.fromJson(a as Map<String, dynamic>))
            .toList();
        notifyListeners();
        return;
      }

      // 2. Real-time Approval Request
      if (type == 'approval_request' && json['approval'] != null) {
        final req =
            ApprovalRequest.fromJson(json['approval'] as Map<String, dynamic>);
        // Avoid duplicate
        if (!_pendingApprovals.any((a) => a.eventId == req.eventId)) {
          _pendingApprovals.add(req);
          notifyListeners();
          // 待授权是"agent 已经停下等你"的时刻，必须能打断 —— 静默处理等于
          // 让会话永远卡住。所以用高重要性渠道，会弹横幅。
          if (shouldNotify) {
            // [v1.35 / 2.3] 有一次性令牌才给动作按钮。完全访问策略的审批
            // 网关刻意不铸令牌（sensitive），这类必须进 App 看命令原文。
            final quickAct = shouldOfferQuickActions(req);
            notifications.show(
              title: '需要你授权',
              body: quickAct
                  ? '${req.toolName}：${req.reason}'
                  : '${req.toolName}：${req.reason}（敏感操作，请打开 App 确认）',
              kind: NotificationKind.actionRequired,
              payloadSessionId: req.sessionId,
              approval: quickAct
                  ? NotificationApprovalActions(
                      approvalId: req.eventId.isNotEmpty ? req.eventId : req.id,
                      token: req.approvalToken!,
                    )
                  : null,
            );
          }
        }
        return;
      }

      // 3. Approval Settled
      if (type == 'approval_settled') {
        final eventId = json['eventId'];
        _pendingApprovals
            .removeWhere((a) => a.eventId == eventId || a.id == eventId);
        notifyListeners();
        return;
      }

      // Real-time Permission Update Broadcast
      if (type == 'permission_updated' && json['permissions'] != null) {
        _permissions = PermissionConfig.fromJson(
            json['permissions'] as Map<String, dynamic>);
        notifyListeners();
        return;
      }

      // 4.b [feat 2026-10-17] 归档状态变化。
      //
      // 网关在归档成功后会广播这两帧（自己点的、或电脑端/另一台手机改的都算）。
      // 以前 App 完全不认识它们：自己点的时候靠本地翻转"看着像生效了"，可一旦
      // 电脑端改了归档状态，手机上的列表永远不会跟着变。
      if (type == 'session_archived' || type == 'session_unarchived') {
        final sId = json['sessionId']?.toString() ?? '';
        final archived = type == 'session_archived';
        bool changed = false;
        for (final ws in _workspaces) {
          for (var i = 0; i < ws.sessions.length; i++) {
            final s = ws.sessions[i];
            if (s.matchesSessionId(sId) && s.archived != archived) {
              ws.sessions[i] = s.copyWith(archived: archived);
              changed = true;
            }
          }
        }
        if (_currentSession != null && _currentSession!.matchesSessionId(sId)) {
          _currentSession = _currentSession!.copyWith(archived: archived);
          changed = true;
        }
        if (changed) notifyListeners();
        return;
      }

      // 4. Session Status Updates (Running / Idle)
      if (type == 'session_status') {
        final sId = json['sessionId']?.toString() ?? '';
        final isRunning = json['isRunning'] == true;
        bool changed = false;
        for (var ws in _workspaces) {
          for (var i = 0; i < ws.sessions.length; i++) {
            final s = ws.sessions[i];
            if (s.matchesSessionId(sId) && s.isRunning != isRunning) {
              ws.sessions[i] = s.copyWith(isRunning: isRunning);
              changed = true;
            }
          }
        }
        if (_currentSession != null && _currentSession!.matchesSessionId(sId)) {
          if (!isRunning) {
            _requestFinalResync(sId);
            _remoteRunningSessions.remove(_syncKey(sId));
            _setSending(false);
            _isCanceling = false;
            _sessionPollTimer?.cancel();
            _sessionPollTimer = null;
            _turnRunningSeen = false;
            if (_messages.isNotEmpty && _messages.last.isAssistant) {
              _messages.last.isStreaming = false;
              for (final t in _messages.last.tools) {
                t.isRunning = false;
              }
            }
          } else {
            final wasRemoteRunning = _remoteRunningSessions.contains(_syncKey(sId));
            if (!wasRemoteRunning && !_isSending) {
              _beginRemoteStream(sId);
            }
            if (!wasRemoteRunning) {
              unawaited(_resyncActiveSession(sId));
            }
            // [fix 2026-10-17] 远端新回合的上升沿要**解除本地取消栅栏**。
            //
            // 栅栏的语义是"丢弃本地已取消那一轮的残余帧"，不是"这个会话从此
            // 哑掉"：电脑端在同一会话发起的新回合，此前会被
            // `_activeTurnSeq <= _cancelledTurnSeq` 全部丢弃、
            // `_isSending` 无法点亮（L4491 同条件）、轮询对账又强制
            // isRunning=false —— 整个远端回合在手机上不可见。多客户端是本
            // 产品的核心场景，收到 isRunning:true 上升沿就意味着引擎在跑
            // 一轮我们没发起的回合，栅栏必须让路。
            if (_cancelledTurnSeq >= _activeTurnSeq) {
              _cancelledTurnSeq = _activeTurnSeq - 1;
            }
            if (!_isCanceling) {
              _setSending(true, sessionId: sId);
            }
            // 回合开始的**上升沿**：记下"开始前"的累计读数，作为本轮消耗的基线。
            //
            // 必须做上升沿判断：一个回合里 `session_status(isRunning:true)` 会被
            // 广播多次（每一步都可能重发），每次都覆盖基线会把基线推进到回合中途，
            // 算出来的"本轮消耗"偏小。也绝不在这里取"终止值"——那个值要等 `done`
            // 之后由 fetchSessionStats(endOfTurn: true) 去取。
            if (!_turnRunningSeen) {
              _turnRunningSeen = true;
              _captureStatsBaseline();
            }
          }
          changed = true;
        }
        if (changed) {
          notifyListeners();
        }
        return;
      }

      // 4.1 Session Deleted
      if (type == 'session_deleted') {
        final sId = json['sessionId']?.toString() ?? '';
        // [fix 2026-10-17] 会话没了，它的消息缓存必须一起删 —— 否则再用同一个
        // id 打开（或网关重建同 id 会话）会拿回一份"已经不存在"的旧内容。
        _dropHistoryCache(sId);
        for (final ws in _workspaces) {
          ws.sessions.removeWhere((s) => s.matchesSessionId(sId));
        }
        if (_currentSession?.matchesSessionId(sId) == true) {
          if (_currentWorkspace != null &&
              _currentWorkspace!.sessions.isNotEmpty) {
            selectSession(_currentWorkspace!.sessions.first);
          } else {
            createNewSession();
          }
        } else {
          notifyListeners();
        }
        return;
      }

      // 4.2 System Error Event
      if (type == 'error') {
        final sId = json['sessionId']?.toString();
        final errStr = json['error']?.toString() ?? '系统发生错误';
        final code = json['errorCode']?.toString() ?? '';
        // 回合级失败（turn/end.reason.kind=error）：网关会带 turnEnded=true。
        final turnEnded = json['turnEnded'] == true;
        _lastError = errStr;
        if (sId != null &&
            _currentSession != null &&
            _currentSession!.matchesSessionId(sId)) {
          if (_messages.isNotEmpty &&
              _messages.last.isAssistant &&
              _messages.last.isStreaming) {
            // ⚠️ 不能把已流出的正文覆盖掉 —— 模型出错前吐出的内容对用户仍然有用
            // （旧写法直接 content = '❌ …'，把半截回答整段抹掉了）。
            // 先 flush 再读：否则 buffer 里最后 100ms 的增量会漏出 partial，
            // 又被 setter 的 flush 追加到错误行之后，顺序整个错掉。
            _messages.last.flushStreamBuffers();
            final partial = _messages.last.content;
            _messages.last.content = partial.trim().isEmpty
                ? '❌ $errStr'
                : '$partial\n\n❌ 本轮以错误结束：$errStr';
            _messages.last.isStreaming = false;
          }
          if (turnEnded) {
            _applyTurnFailure(TurnEndInfo(
              kind: 'error',
              text: errStr,
              code: code,
              failed: true,
              time: DateTime.now().millisecondsSinceEpoch,
            ));
          }
          // 失败即终结：把"运行中"相关的所有状态一并收干净，否则转圈会一直转下去
          // （这是用户报的"报错了还一直显示运行中"）。
          _sessionPollTimer?.cancel();
          _sessionPollTimer = null;
          _setSending(false);
          _isCanceling = false;
          _streamRevision++;
        }
        notifyListeners();
        return;
      }

      // [fix 2026-10-14] stream_snapshot：网关在订阅/重连时补发的累积流式内容
      // 快照（delta 窗口期断线丢掉的那段）。按「服务端为准、本地只多不少」
      // 合并：本地已有的前缀不动，缺失的部分补齐。replay=true 表示回合已结束，
      // 补完后不再标 streaming。
      if (type == 'stream_snapshot') {
        final sId = json['sessionId']?.toString();
        if (sId == null ||
            _currentSession == null ||
            !_currentSession!.matchesSessionId(sId)) {
          return;
        }
        final snapText = json['text']?.toString() ?? '';
        final snapThinking = json['thinking']?.toString() ?? '';
        final isReplay = json['replay'] == true;
        if (snapText.isEmpty && snapThinking.isEmpty) return;

        if (_messages.isEmpty ||
            !_messages.last.isAssistant ||
            !_messages.last.isStreaming) {
          _messages.add(ChatMessage(
            id: _uuid.v4(),
            role: 'assistant',
            content: snapText,
            thinking: snapThinking,
            isStreaming: !isReplay,
            timestamp: DateTime.now(),
          ));
        } else {
          final current = _messages.last;
          // 只补不缩：本地内容若是快照的前缀（正常 delta 路径），补齐尾部；
          // 本地比快照长（本地收到过更多 delta），保持本地。
          // 先 flush 再比对：buffer 里可能还压着未成形的增量，拿半截 content 去
          // 做 startsWith 前缀判断会把"本来是前缀"判成"不是前缀"，于是快照
          // 整段被丢弃 —— 那正是这段补发机制要防的丢内容。
          current.flushStreamBuffers();
          if (snapText.length > current.content.length &&
              snapText.startsWith(current.content)) {
            current.content = snapText;
          }
          if (snapThinking.length > (current.thinking?.length ?? 0) &&
              snapThinking.startsWith(current.thinking ?? '')) {
            current.thinking = snapThinking;
          }
          if (isReplay) {
            current.isStreaming = false;
          }
        }
        _streamRevision++;
        notifyListeners();
        return;
      }

      // Web/App 任一端的新提问。实时消息与历史消息使用同一个 rpcId，
      // 重复 follow 回放和轮询对账都必须幂等。
      if (type == 'user_message') {
        final sId = json['sessionId']?.toString();
        final raw = json['message'];
        if (sId == null ||
            _currentSession == null ||
            !_currentSession!.matchesSessionId(sId) ||
            raw is! Map) {
          return;
        }
        final incoming = ChatMessage.fromWire(
          Map<String, dynamic>.from(raw),
          newId: _uuid.v4,
        );
        final duplicate = _messages.any((m) =>
            (incoming.clientRequestId != null &&
                m.clientRequestId == incoming.clientRequestId) ||
            (incoming.seq != null && m.seq == incoming.seq) ||
            m.id == incoming.id);
        if (duplicate) return;
        _beginRemoteStream(sId);
        if (_messages.isNotEmpty && _messages.last.isAssistant) {
          _messages.insert(_messages.length - 1, incoming);
        } else {
          _messages.add(incoming);
        }
        _streamRevision++;
        notifyListeners();
        return;
      }

      // 4.9 [fix 2026-10-25] 工具参数增量帧必须在正文增量判定之前截住。
      //
      // `tool_call` 帧的形状是 `{type:'tool_call', tool, delta}` —— 那个 `delta`
      // 是**工具参数**的增量，不是回复正文。而下面那段正文分支的判定条件是
      // `json.containsKey('delta')`，于是它先被命中：工具参数的碎片被当成正文
      // 拼进气泡（流式时正文里冒出 `{"path":"…` 这类残片），而这次工具调用
      // 就没有任何一条增量走到工具卡上。
      //
      // 参数本身不需要在这里合并：网关的 `tool_start` 已经带了**完整**参数
      // （它来自会话日志里的 `tool/call` 事件），所以这些增量直接丢弃即可 ——
      // 既不污染正文，也不会造出重复的工具条目。
      if (type == 'tool_call') return;

      // 5. Streaming tokens and chat chunks (thinking / delta / token)
      if (type == 'thinking' || type == 'delta' || type == 'token') {
        final sId = json['sessionId']?.toString();
        if (sId == null ||
            _currentSession == null ||
            !_currentSession!.matchesSessionId(sId)) {
          return;
        }

        // Drop lingering stream chunks if user canceled or this turn has ended.
        if (!_acceptStreamFrame(sId)) return;

        if (_messages.isEmpty ||
            !_messages.last.isAssistant ||
            (!_messages.last.isStreaming &&
                _remoteRunningSessions.contains(_syncKey(sId)))) {
          _messages.add(ChatMessage(
            id: _uuid.v4(),
            role: 'assistant',
            content: '',
            thinking: '',
            isStreaming: true,
            timestamp: DateTime.now(),
          ));
        }

        final current = _messages.last;
        current.isStreaming = true;
        _setSending(true, sessionId: sId);

        if (type == 'thinking' || json.containsKey('thinking')) {
          final text = json['delta'] ?? json['thinking'] ?? '';
          _ingestStreamDelta(current, thinking: text.toString());
        } else {
          final text = json['delta'] ?? json['content'] ?? json['text'] ?? '';
          _ingestStreamDelta(current, content: text.toString());
        }
        return;
      }

      // 6. Tool Executions
      if (type == 'tool_start' || type == 'tool_call') {
        final sId = json['sessionId']?.toString();
        if (sId == null ||
            _currentSession == null ||
            !_currentSession!.matchesSessionId(sId)) {
          return;
        }

        // Drop tool start if canceled or this turn has ended.
        if (!_acceptStreamFrame(sId)) return;

        if (_messages.isEmpty ||
            !_messages.last.isAssistant ||
            !_messages.last.isStreaming) {
          _messages.add(ChatMessage(
            id: _uuid.v4(),
            role: 'assistant',
            content: '',
            thinking: '',
            isStreaming: true,
            timestamp: DateTime.now(),
          ));
        }
        final toolName = json['tool'] ?? json['name'] ?? 'tool';
        final toolInput = _coerceToolInput(json['input'] ?? json['args']);
        _messages.last.tools.add(
            ToolExecution(name: toolName, input: toolInput, isRunning: true));
        _messages.last.isStreaming = true;
        _setSending(true, sessionId: sId);
        _streamRevision++;
        notifyListeners();
        return;
      }

      if (type == 'tool_result' || type == 'tool_end') {
        if (_isCanceling) return;
        if (_activeTurnSeq <= _cancelledTurnSeq) return;

        final sId = json['sessionId']?.toString();
        if (sId == null ||
            _currentSession == null ||
            !_currentSession!.matchesSessionId(sId)) {
          return;
        }

        if (_messages.isNotEmpty &&
            _messages.last.isAssistant &&
            _messages.last.tools.isNotEmpty) {
          final lastTool = _messages.last.tools.last;
          lastTool.isRunning = false;
          lastTool.output =
              _coerceToolInput(json['output'] ?? json['result'] ?? '完成');
          _streamRevision++;
          notifyListeners();
        }
        return;
      }

      // 8. user-questions (patch 0003)
      //
      // Opt-in: a phone that is only browsing the session list must not receive
      // prompts, or the gateway would hold requests it can never answer. The
      // gateway only offers questions to subscribers and relays the answer over
      // $events/result, so this side is pure bookkeeping plus one request.
      if (type == 'question_subscribed') {
        // Replay whatever the gateway is still holding. Without this a phone
        // that connects mid-question sees a session that just looks wedged.
        _questionsSubscribed = true;
        final pending = json['pending'];
        if (pending is List) {
          for (final raw in pending) {
            if (raw is! Map<String, dynamic>) continue;
            try {
              final q = PendingQuestion.fromJson(raw);
              // The gateway may have re-offered something we already answered
              // (e.g. a reconnect landed between its send and our reply).
              if (_pendingQuestions.any((p) => p.eventId == q.eventId)) {
                continue;
              }
              _pendingQuestions.add(q);
            } on FormatException catch (e) {
              // One malformed item must not cost us the rest of the replay.
              debugPrint('[DshService] question replay 丢弃不可解析项: $e');
            }
          }
        }
        notifyListeners();
        return;
      }

      if (type == 'question_request') {
        try {
          final q = PendingQuestion.fromJson(json);
          if (_pendingQuestions.any((p) => p.eventId == q.eventId)) return;
          _pendingQuestions.add(q);
          notifyListeners();
          // 同待授权：提问让 agent 挂起，必须能打断。
          // 用 shouldNotifyForSession：提问不在当前会话/不在眼前时，前台也要提醒
          // （它只在当前会话的输入框上方渲染，别处完全没有提示）。
          if (shouldNotifyForSession(q.sessionId)) {
            notifications.show(
              title: 'Agent 在等你回答',
              // 取第一道题的问题文本；有多道题时不逐条罗列 —— 通知栏放不下，
              // 而且点进去就能看到全部。
              body: q.questions.first.question,
              kind: NotificationKind.actionRequired,
              payloadSessionId: q.sessionId,
            );
          }
        } on FormatException catch (e) {
          debugPrint('[DshService] question_request 无法解析: $e');
        }
        return;
      }

      if (type == 'question_settled') {
        final eventId = json['eventId'];
        final ok = json['ok'] == true;
        _lastQuestionError =
            ok ? null : (json['reason']?.toString() ?? '提问未能送达');
        // removeWhere returns void, so "did anything change" needs the length
        // comparison rather than the return value.
        final before = _pendingQuestions.length;
        _pendingQuestions.removeWhere((p) => p.eventId == eventId);
        if (_pendingQuestions.length != before) {
          notifyListeners();
        }
        return;
      }

      // The gateway withdrew every open prompt (turn cancelled, subscriber went
      // away, upstream link dropped). Clear them rather than leaving cards on
      // screen that can no longer be answered.
      if (type == 'questions_invalidated') {
        if (_pendingQuestions.isNotEmpty) {
          _pendingQuestions.clear();
          _lastQuestionError =
              '提问已失效：${json['reason']?.toString() ?? '会话状态变化'}';
          notifyListeners();
        }
        return;
      }

      if (type == 'question_ack') {
        // The gateway already emits question_settled on success, so this is only
        // the failure report. Do NOT remove on ok:false — the engine may still
        // have the request open, and dropping the card would strand the user.
        if (json['ok'] == true) {
          _lastQuestionError = null;
          final before = _pendingQuestions.length;
          _pendingQuestions.removeWhere((p) => p.eventId == json['eventId']);
          if (_pendingQuestions.length != before) notifyListeners();
        } else {
          final err = json['error']?.toString();
          final retryable = json['retryable'] == true || err == 'rpc-failed';
          _lastQuestionError = err == 'unknown-question'
              ? '该提问已过期（可能已被其它设备回答）'
              : '提交失败：${json['error'] ?? '未知错误'}';
          // 只有**确认过期**（unknown-question）才收卡片。rpc-failed 时引擎侧
          // 请求还活着（网关也保留了它的 pending 记录），删卡片等于夺走用户
          // 唯一的重试入口 —— 这正是此前"点了没反应还把输入框收走"的成因。
          if (!retryable) {
            final before = _pendingQuestions.length;
            _pendingQuestions.removeWhere((p) => p.eventId == json['eventId']);
            if (_pendingQuestions.length != before) notifyListeners();
          } else {
            notifyListeners();
          }
        }
        return;
      }

      // 9. todo/write — whole-list replacement, broadcast to every client.
      if (type == 'todo_list') {
        final sId = json['sessionId']?.toString() ?? '';
        final rawTodos = json['todos'];
        if (rawTodos is! List) return;
        final items = <TodoItem>[];
        for (final raw in rawTodos) {
          if (raw is! Map<String, dynamic>) continue;
          try {
            items.add(TodoItem.fromJson(raw));
          } on FormatException {
            // Skip an unparseable row, keep the rest of the list.
          }
        }
        // Keyed by the bare id too: the gateway forwards whichever spelling the
        // engine used, and the open session may hold the prefixed one.
        final key = sId.replaceFirst(RegExp(r'^session-'), '');
        _todos.remove(sId);
        _todos.remove(key);
        if (items.isNotEmpty) _todos[key] = items;
        notifyListeners();
        return;
      }

      // 10. Attachment metadata (images). Bytes are NOT inlined: the phone
      // fetches them through the authenticated attachment route.
      if (type == 'attachment') {
        final sId = json['sessionId']?.toString() ?? '';
        final raw = json['attachment'];
        if (raw is! Map<String, dynamic>) return;
        try {
          final ref = AttachmentRef.fromJson(raw);
          if (!ref.isImage) return;
          final key = sId.replaceFirst(RegExp(r'^session-'), '');
          _attachments.putIfAbsent(key, () => <String, AttachmentRef>{});
          _attachments[key]![ref.id] = ref;
          notifyListeners();
        } on FormatException catch (e) {
          debugPrint('[DshService] attachment 无法解析: $e');
        }
        return;
      }

      // 10.5 交付物与工作区变更：网关只推一个信号，数据按需拉。
      //
      // 交付物里可能有几十 MB 的文件，绝不可能内联进 WS 帧；变更清单要跑 git，
      // 也不该由每次事件触发。所以事件只负责说"变了"，真正的读取走 REST。
      if (type == 'deliverables' || type == 'workspace_changes') {
        final sId = json['sessionId']?.toString() ?? '';
        if (_currentSession == null ||
            !_currentSession!.matchesSessionId(sId)) {
          return;
        }
        if (type == 'deliverables') {
          // 交付物必须**立刻**拉：用户此刻正等着文件，"产出 N" 和流内卡片都要它。
          // 同时记一次事件 —— 流内卡片只认这个计数，不认"清单非空"。
          _deliverableEvents++;
          notifyListeners();
          unawaited(fetchDeliverables());
        } else {
          // 变更只置脏，统一在 `done` 拉一次。
          //
          // 两个理由：① 这个事件在一轮里可能来好几次，而每次都要起一个 git
          // 子进程；② 更要紧的是轮内的 git 状态会随 agent 写文件中途抖动，
          // 此刻的数字没有意义。一轮一次，且发生在轮末 —— 正是"本次变更"有意义
          // 的时刻。
          _changesDirty = true;
        }
        return;
      }

      // 7. Completion
      if (type == 'done' || type == 'end') {
        final sId = json['sessionId']?.toString();

        // 通知放在"是否当前会话"的判断**之前**。
        //
        // 这一点很容易搞反：App 在后台时，用户可能正在看另一个会话，但这次请求
        // 是在**他刚才离开的那个会话**里跑的。如果按当前会话过滤掉，用户就永远
        // 收不到"你跑完了"—— 而这恰恰是通知最该发挥作用的地方。
        if (shouldNotify && sId != null) {
          notifications.show(
            title: '执行完成',
            body: _sessionDisplayTitle(sId),
            payloadSessionId: sId,
          );
        }

        if (sId == null ||
            _currentSession == null ||
            !_currentSession!.matchesSessionId(sId)) {
          return;
        }
        final doneText = json['text']?.toString() ?? '';
        final doneThinking = json['thinking']?.toString() ?? '';
        if (_messages.isEmpty ||
            !_messages.last.isAssistant ||
            !_messages.last.isStreaming) {
          if (doneText.isNotEmpty || doneThinking.isNotEmpty) {
            _messages.add(ChatMessage(
              id: _uuid.v4(),
              role: 'assistant',
              content: doneText,
              thinking: doneThinking,
            ));
          }
        } else {
          final current = _messages.last;
          current.flushStreamBuffers();
          if (doneText.isNotEmpty) {
            // 网关的 done 是这一轮的完整快照。正文可能因断线缺了中段，
            // 不能用 startsWith 把它当成只能追加的 delta 而丢掉整段。
            current.content = doneText;
          }
          if (doneThinking.isNotEmpty) {
            current.thinking = doneThinking;
          }
          current.isStreaming = false;
          for (var t in current.tools) {
            t.isRunning = false;
          }
        }
        _remoteRunningSessions.remove(_syncKey(sId));
        _requestFinalResync(sId);
        // done 现在带结束原因。若 error 帧丢了（弱网/刚好断线），这里仍能补上
        // 失败说明 —— 结束原因只有网关读得到，手机不能靠猜。
        // 失败说明 —— 结束原因只有网关读得到，手机不能靠猜。
        final endReason = json['reason']?.toString();
        if (endReason == 'error' ||
            endReason == 'interrupted' ||
            endReason == 'blocked') {
          _applyTurnFailure(TurnEndInfo(
            kind: endReason!,
            text: json['message']?.toString() ?? '',
            failed: true,
            time: DateTime.now().millisecondsSinceEpoch,
          ));
        } else if (endReason != null) {
          // 新一轮正常结束：上一轮的失败已经过时。横幅与"已关闭"抑制账一起清掉，
          // 否则那条旧账会让以后真正的新失败也弹不出来。
          _lastTurnFailure = null;
          final sid = _currentSession?.sessionId;
          if (sid != null &&
              _dismissedFailureSessions.remove(_failureKey(sid))) {
            unawaited(StorageService.saveDismissedTurnFailures(
                _dismissedFailureSessions.toList()));
          }
        }
        _sessionPollTimer?.cancel();
        _sessionPollTimer = null;
        _setSending(false);
        _isCanceling = false;
        _streamRevision++;
        // 回合结束了：本轮的基线使命结束（`_turnRunningSeen` 复位，等下一个回合
        // 的上升沿重新记基线）。
        _turnRunningSeen = false;
        notifyListeners();
        fetchWorkspaces();
        // 一轮结束会领取（claim）队首消息：队列真值变了，刷新它。
        unawaited(fetchQueue());
        // 本轮消耗要在**轮末**量：这里补一次 stats 的实时读，拿它与回合开始前的
        // 基线相减，结果存进 lastTurnTokens。不能在 done 这一帧就地设基线 ——
        // 那会算出 0（见 fetchSessionStats 的注释）。
        unawaited(fetchSessionStats(endOfTurn: true));
        // 本轮改过工作区的话，轮末补一次变更清单（一轮最多一个 git 子进程）。
        if (_changesDirty) {
          _changesDirty = false;
          unawaited(fetchWorkspaceChanges());
        }
        return;
      }
    } catch (e) {
      // [fix 2026-10-17] 日志措辞窄化：此前的 catch 包住整个消息处理（不只
      // jsonDecode），fromJson 的 TypeError、字段强转失败全被吞成"JSON parse
      // error"，误导排查。这里带帧首片段，至少能看出是哪一帧。
      final preview = raw.length > 120 ? '${raw.substring(0, 120)}…' : raw;
      debugPrint('[DshService] 帧处理失败（type 尚不可知）: $e | 帧: $preview');
    }
  }

  // Heartbeat
  void _startHeartbeat() {
    _stopHeartbeat();
    _lastServerFrameAt = DateTime.now();
    _lastPingSentAt = null;
    _missedPings = 0;
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      if (_isDisposed) {
        timer.cancel();
        return;
      }
      if (_status == ConnectionStatus.connected) {
        // 看门狗：连续 3 个周期（45s）发出去的 ping 收不到任何应答，判定为
        // 半死连接，立即重建。
        //
        // [fix 2026-10-16] 判据从"多久没收到服务器帧"改成"ping 有没有应答"。
        // 旧写法是纯静默超时：一个"偶尔漏几帧下来、但实际投递不了"的连接
        // （弱网半开、NAT 表项老化）永远满足不了 45s 静默，于是看门狗形同
        // 虚设，用户看到的是"还显示已连接，但什么都在转圈"。
        //
        // 写 ping 不报错同样不代表 socket 活着 —— TCP 写缓冲在连接半开时
        // 照样接受数据，错误要到重传耗尽才冒出来，那可能是几分钟后。
        final lastPing = _lastPingSentAt;
        if (lastPing != null) {
          _missedPings++;
          if (_missedPings >= _maxMissedPings) {
            debugPrint(
                '[DshService] 看门狗：${_missedPings * 15}s ping 无应答，判定半死连接，强制重连');
            _status = ConnectionStatus.disconnected;
            notifyListeners();
            _scheduleReconnect(immediate: true);
            return;
          }
        }
        try {
          _channel?.sink.add('ping');
          _lastPingSentAt = DateTime.now();
        } catch (_) {}
      }
    });
  }

  /// 收到任意服务器帧时调用：ping 应答计数归零。
  ///
  /// 不测具体 RTT 数值 —— 那是 `measurePing()` 的活，而且一次性抖动不该判死。
  /// 这里只回答"这条连接还在不在回话"这个是非题。
  void _noteServerFrame() {
    _missedPings = 0;
    _lastPingSentAt = null;
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  // Clean Socket Teardown (F4.4 / F3.1)
  /* ------------------------------------------------------------------ *
   * [v1.35 / 1.4] 自签证书 TOFU 校验
   *
   * 为什么必须在连接层做：网关的自签证书不在系统信任链里，Dart 默认会直接
   * 拒绝握手。要么一律放行（等于没有校验，同网段任何人都能中间人），要么按
   * 指纹记住它——后者就是 TOFU。策略实现在 services/cert_trust.dart。
   * ------------------------------------------------------------------ */

  HttpClient? _wsHttpClient;
  String _certGatewayId = '';
  CertTrustResult? _pendingCertChange;

  /// 最近一次被拦下的证书变更（null = 正常）。UI 据此决定是否弹告警。
  CertTrustResult? get pendingCertChange => _pendingCertChange;

  static String _gatewayIdOf(ServerConfig config) {
    final id = config.id.trim();
    return id.isNotEmpty ? id : '${config.cleanHost}:${config.cleanPort}';
  }

  /// 给一个 HttpClient 装上与 WSS 完全相同的证书判定。
  ///
  /// 公开 CA 证书（quick tunnel / 正式反代）不会触发 `badCertificateCallback`，
  /// 走系统信任链；这里只接管自签场景。gatewayId 显式传入，避免“测试一个尚未
  /// 保存的网关”时污染当前连接的信任条目。
  void _installCertValidation(
    HttpClient client, {
    required String gatewayId,
    required String channel,
  }) {
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) {
      final fp = CertTrust.fingerprintOfCertificate(cert);
      final result = CertTrust.decideSync(
        gatewayId: gatewayId,
        fingerprint: fp,
        channel: channel,
      );
      if (result.decision == CertTrustDecision.unavailable) {
        return false;
      }
      if (result.decision == CertTrustDecision.mismatch) {
        _pendingCertChange = result;
        return false;
      }
      if (result.decision == CertTrustDecision.firstUse) {
        unawaited(CertTrust.acceptChange(
          gatewayId: gatewayId,
          fingerprint: fp,
          channel: channel,
        ));
      }
      return true;
    };
  }

  Future<HttpClient> _makeTlsHttpClient(ServerConfig config) async {
    final gatewayId = _gatewayIdOf(config);
    await CertTrust.preload(gatewayId: gatewayId, channel: config.channel);
    final client = HttpClient();
    _installCertValidation(client,
        gatewayId: gatewayId, channel: config.channel);
    return client;
  }

  /// HTTP 客户端同样绑定连接代次：旧网关的迟到响应在读取正文后会被丢弃。
  Future<http.Client> _buildHttpClientFor(
    ServerConfig config, {
    int? generation,
  }) async {
    final gen = generation ?? _connectionGeneration;
    if (!config.effectiveUseHttps) {
      return _GenerationHttpClient(
        inner: http.Client(),
        generation: gen,
        isCurrent: _isGenerationCurrent,
      );
    }
    final raw = await _makeTlsHttpClient(config);
    return _GenerationHttpClient(
      inner: IOClient(raw),
      generation: gen,
      isCurrent: _isGenerationCurrent,
    );
  }

  Future<void> _replaceHttpClient(ServerConfig config, int generation) async {
    final next = await _buildHttpClientFor(config, generation: generation);
    if (!_isGenerationCurrent(generation)) {
      next.close();
      return;
    }
    final previous = _httpClient;
    _httpClient = next;
    try {
      previous.close();
    } catch (_) {
      // 旧客户端关闭失败不应阻断新连接。
    }
  }

  /// 装载同步信任视图并构造带指纹校验的 WebSocket HttpClient。
  Future<HttpClient> _prepareTlsClient(ServerConfig config) async {
    await CertTrust.preload(gatewayId: _certGatewayId, channel: config.channel);
    final client = HttpClient();
    _installCertValidation(
      client,
      gatewayId: _certGatewayId,
      channel: config.channel,
    );
    _wsHttpClient = client;
    return client;
  }

  /// 证书指纹变化：拦住连接并给出可解释的错误，**不进自动重连**。
  void _handleCertMismatch(CertTrustResult change) {
    _status = ConnectionStatus.error;
    _lastError = '网关证书指纹已变化，连接被阻止。'
        '如果这是你刚换网络/重装网关，请在「连接与诊断」里确认新指纹后重连；'
        '否则请停止连接并检查网络是否被劫持。';
    _isReconnecting = false;
    _stopHeartbeat();
    notifyListeners();
  }

  /// 用户在告警页点了「我认识这次变更」：写入信任库并重连。
  Future<void> trustPendingCertChange() async {
    final pending = _pendingCertChange;
    final config = _currentConfig;
    if (pending == null || config == null) return;
    await CertTrust.acceptChange(
      gatewayId: _certGatewayId,
      fingerprint: pending.fingerprint,
      channel: config.channel,
    );
    _pendingCertChange = null;
    _lastError = '';
    await connect(config);
  }

  /// 用户点「不信任」：清掉本次待确认状态，保持断开。
  void rejectPendingCertChange() {
    _pendingCertChange = null;
    _status = ConnectionStatus.disconnected;
    notifyListeners();
  }

  Future<void> _cleanTeardownSocket() async {
    _stopHeartbeat();
    await _channelSubscription?.cancel();
    _channelSubscription = null;
    if (_channel != null) {
      try {
        // 同 disconnect()：必须用 1000 normalClosure，不能用 goingAway(1001)。
        // 1001 是协议保留码，客户端发它会被底层直接拒绝并抛异常 —— 而这里是
        // 同步抛出，所以 await/timeout 都来不及生效，close 根本没开始。
        // 表现是"每次重连都只是把旧 socket 丢掉而不关闭它"，连接在两端泄漏。
        await _channel!.sink.close(ws_status.normalClosure).timeout(
              const Duration(milliseconds: 500),
              onTimeout: () {},
            );
      } catch (e) {
        debugPrint('[DshService] Socket teardown notice: $e');
      }
      _channel = null;
    }
    // [v1.35 / 1.4] 每次连接都会新建一个 HttpClient（指纹回调绑定当前网关），
    // 旧实例必须关掉：它的 keep-alive 连接不会自己消失，长跑会耗尽句柄。
    try {
      _wsHttpClient?.close(force: true);
    } catch (e) {
      debugPrint('[DshService] HttpClient close notice: $e');
    }
    _wsHttpClient = null;
  }

  // Automatic Reconnection Loop with Exponential Backoff & Jitter (F3.1)
  void _scheduleReconnect({bool immediate = false}) {
    // [v1.35 / 1.4] 证书指纹不一致时**不做自动重连**：指纹不变，重连必然再次
    // 失败，只会每 12 秒刷一次日志并耗电。等用户在告警页确认（trustPendingCertChange）
    // 或改成正确地址后再手动连。
    if (_pendingCertChange != null) return;
    if (_isExplicitlyDisconnected ||
        _isDisposed ||
        _isTokenInvalid ||
        _currentConfig == null) {
      return;
    }
    if (_reconnectExhausted) return;
    if (_isReconnecting ||
        (_reconnectTimer != null && _reconnectTimer!.isActive)) {
      return;
    }

    _reconnectTimer?.cancel();

    if (immediate) {
      _reconnectAttempts = 0;
      _executeReconnect();
      return;
    }

    // [fix 2026-10-16] 重连上限。旧逻辑退避封顶 12s 后无限重试，
    // 网关半夜重启能让手机在后台每隔 12 秒醒一次，天亮烧掉一块电量，
    // 而用户对此一无所知。到上限就停，等下一次用户主动操作重新武装。
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _reconnectExhausted = true;
      debugPrint('[DshService] 重连已达上限 $_maxReconnectAttempts 次，停止自动重试');
      notifyListeners();
      return;
    }

    final int delayMs;
    if (_reconnectAttempts == 0) {
      // First retry: fast turnaround (1000-1300ms) to guarantee <= 5s reconnection
      delayMs =
          _baseReconnectDelayMs + (DateTime.now().millisecondsSinceEpoch % 300);
    } else {
      final double calculated = (_baseReconnectDelayMs *
              math.pow(_backoffMultiplier, math.min(_reconnectAttempts, 6)))
          .toDouble();
      final int capped = math.min(calculated.toInt(), _maxReconnectDelayMs);
      final int jitter = (DateTime.now().millisecondsSinceEpoch % _maxJitterMs);
      delayMs = capped + jitter;
    }

    _reconnectAttempts++;
    debugPrint(
        '[DshService] Scheduling reconnect attempt #$_reconnectAttempts in ${delayMs}ms');

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _executeReconnect();
    });
  }

  /// 重连已耗尽时，由用户主动操作调用以重新武装。
  ///
  /// 覆盖：connect() / selectSession() / handleAppResumed() / 下拉刷新。
  /// 语义是"人又碰了一下手机，值得再试一轮"，所以计数器也一起归零。
  void armReconnectRetry() {
    if (!_reconnectExhausted) return;
    _reconnectExhausted = false;
    _reconnectAttempts = 0;
    debugPrint('[DshService] 用户主动操作，重新武装重连');
  }

  Future<void> _executeReconnect() async {
    if (_isExplicitlyDisconnected ||
        _isDisposed ||
        _isTokenInvalid ||
        _currentConfig == null) {
      return;
    }
    if (_isReconnecting) return;

    final config = _currentConfig!;
    final generation = ++_connectionGeneration;
    _fetchWorkspacesInFlight = null;
    _sessionPollInFlight = false;
    _isReconnecting = true;
    _status = ConnectionStatus.connecting;
    // 新连接：允许重新发一次订阅。
    _subscribeRequested = false;
    notifyListeners();

    try {
      await _cleanTeardownSocket();
      if (!_isGenerationCurrent(generation)) return;

      _certGatewayId = _gatewayIdOf(config);
      _pendingCertChange = null;
      // REST 与 WSS 一起换到当前证书信任状态。
      await _replaceHttpClient(config, generation);
      if (!_isGenerationCurrent(generation)) return;

      // [v1.35 / 1.4] 重连同样要装载信任视图：换网络后网关可能按新 SAN
      // 重签了证书，这时应该给出「指纹变了」而不是一句「连接失败」。
      final reconnectClient =
          config.effectiveUseHttps ? await _prepareTlsClient(config) : null;
      if (!_isGenerationCurrent(generation)) return;

      final uri = Uri.parse(config.wsUrl);
      // [fix 2026-10-17] connectTimeout：SYN 黑洞（网关掉线/防火墙丢包）时
      // 没有它 ready 会挂到 OS 级 TCP 超时（约 2 分钟），期间 _isReconnecting
      // 锁死一切重连调度。connect() 与本路径必须对称设值。
      final channel = IOWebSocketChannel.connect(
        uri,
        connectTimeout: const Duration(seconds: 10),
        customClient: reconnectClient,
        headers: {
          'Authorization': 'Bearer ${config.effectiveToken}',
          'x-dsh-token': config.effectiveToken,
        },
      );
      _channel = channel;

      _channelSubscription = channel.stream.listen(
        (data) {
          if (!_isGenerationCurrent(generation) ||
              !identical(_channel, channel)) return;
          if (_status != ConnectionStatus.connected) {
            _status = ConnectionStatus.connected;
            _reconnectAttempts = 0;
            _isReconnecting = false;
            _onReconnected();
            notifyListeners();
          }
          // 重连后必须重新声明愿意回答提问。网关按活的 socket 记录订阅，
          // 重连落在一个从没见过这台手机的新 socket 上 —— 不重新 subscribe
          // 就静默收不到任何提问（与 connect() 的 ready 路径同构，见
          // _onSocketReady 的注释）。_onSocketReady 幂等，重复调用无害。
          _onSocketReady();
          _handleRawMessage(data);
        },
        onError: (error) {
          if (!_isGenerationCurrent(generation) ||
              !identical(_channel, channel)) return;
          debugPrint('[DshService] Reconnect socket error: $error');
          final certChange = _pendingCertChange;
          if (certChange != null) {
            _handleCertMismatch(certChange);
            return;
          }
          final errStr = error.toString().toLowerCase();
          if (errStr.contains('401') || errStr.contains('unauthorized')) {
            handleAuthFailure('WebSocket认证失败: 访问令牌无效');
            return;
          }
          _status = ConnectionStatus.error;
          _lastError = error.toString();
          _isReconnecting = false;
          _stopHeartbeat();
          notifyListeners();
          _scheduleReconnect();
        },
        onDone: () {
          if (!_isGenerationCurrent(generation) ||
              !identical(_channel, channel)) return;
          debugPrint('[DshService] Reconnect socket onDone closed');
          final code = channel.closeCode;
          if (code == 4001 || code == 4401 || code == 1008) {
            handleAuthFailure('连接已关闭: 认证失败或Token过期 (Code: $code)');
            return;
          }
          _status = ConnectionStatus.disconnected;
          _isReconnecting = false;
          _stopHeartbeat();
          notifyListeners();
          _scheduleReconnect();
        },
      );

      // [fix 2026-10-17] 等连接真正打开再翻状态 —— 与 connect()（L954）对称。
      // 此前只靠"首条服务器帧"翻 connected，而下面的 ping 因 status 仍是
      // connecting 被 _sendWsJson 的守卫拦掉（no-op 死代码）；若网关建连后
      // 不主动推帧，状态永远停在 connecting 且 _isReconnecting=true，
      // _scheduleReconnect 从此永久阻塞，没有任何自愈路径。
      try {
        await channel.ready;
        if (!_isGenerationCurrent(generation) ||
            !identical(_channel, channel)) {
          return;
        }
        _status = ConnectionStatus.connected;
        _reconnectAttempts = 0;
        _isReconnecting = false;
        _onReconnected();
        notifyListeners();
      } catch (e) {
        // ready 失败会走 stream 的 onError/onDone，由它们负责重连；这里只记录，
        // 不重复触发，避免两条路径同时排重连。
        debugPrint('[DshService] Reconnect WS ready 失败: $e');
      }

      if (!_isGenerationCurrent(generation)) return;
      _startHeartbeat();
      // ready 之后再发 ping（此前这行是死代码：status=connecting 时被守卫拦掉）。
      _sendWsJson({'type': 'ping'});
    } catch (e) {
      if (!_isGenerationCurrent(generation)) return;
      debugPrint('[DshService] _executeReconnect failed: $e');
      _status = ConnectionStatus.error;
      _lastError = e.toString();
      _isReconnecting = false;
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void _onReconnected() {
    debugPrint(
        '[DshService] Reconnected successfully. Re-syncing session & state...');
    if (_currentSession != null) {
      _sendWsJson({'type': 'follow', 'sessionId': _currentSession!.sessionId});
      _resyncActiveSession(_currentSession!.sessionId);
    }
    fetchWorkspaces();
    fetchApprovals();
    fetchPermissions();
    fetchSettings();
    measurePing();
  }

  // App Lifecycle Handling (F3.2)
  void handleAppResumed() {
    final now = DateTime.now();
    if (_lastResumeCheck != null &&
        now.difference(_lastResumeCheck!).inMilliseconds < 500) {
      return; // Debounce
    }
    _lastResumeCheck = now;
    debugPrint('[DshService] App resumed to foreground');
    // [fix 2026-10-17] 回前台 = 用户主动操作，重新武装耗尽的重连（与
    // armReconnectRetry 文档承诺一致，此前从未兑现）。
    armReconnectRetry();

    if (_status != ConnectionStatus.connected || _channel == null) {
      debugPrint(
          '[DshService] Resumed while disconnected/error: triggering immediate reconnect');
      _scheduleReconnect(immediate: true);
    } else {
      debugPrint(
          '[DshService] Resumed while connected: checking socket liveness');
      // 后台期间 socket 可能已被系统/NAT 静默掐断，而本地写 ping 不报错、
      // onError/onDone 也不触发（半死连接）。判据用看门狗时钟：距离最近一次
      // **真正收到服务器帧**太久（>40s，即后台期间没收到过心跳 pong），就
      // 不能信任这条连接 —— 直接重建，重连后会重新订阅提问并重放 pending。
      final last = _lastServerFrameAt;
      final stale =
          last == null || DateTime.now().difference(last).inSeconds > 40;
      if (stale) {
        debugPrint('[DshService] 后台期间无服务器帧，判定连接半死，立即重建');
        _status = ConnectionStatus.disconnected;
        notifyListeners();
        _scheduleReconnect(immediate: true);
        return;
      }
      try {
        _channel?.sink.add('ping');
      } catch (_) {
        _scheduleReconnect(immediate: true);
        return;
      }
      fetchApprovals();
      fetchWorkspaces();
      resubscribeQuestions(); // 幂等补强：拿一次 pending 重放
      if (_currentSession != null) {
        _resyncActiveSession(_currentSession!.sessionId);
      }
    }
  }

  void handleAppPaused() {
    debugPrint('[DshService] App paused to background');
    _sessionPollTimer?.cancel();
    _sessionPollTimer = null;
    // 切后台是 Android 杀进程前的最后机会。草稿的防抖写盘可能还有几百毫秒
    // 才落盘，而这里的 flushNow 是同步的 —— 不 flush 就会丢掉用户刚打的字。
    drafts.flushNow();
  }

  void disconnect() {
    _isExplicitlyDisconnected = true;
    // 断开也是一种代次终止：在途 socket 回调与 REST 响应不得再改状态。
    _connectionGeneration++;
    _channelSubscription?.cancel();
    _channelSubscription = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _reconnectExhausted = false;
    _isReconnecting = false;
    _sessionPollTimer?.cancel();
    _sessionPollTimer = null;
    _stopHeartbeat();
    // [fix 2026-10-16] 流式 flush 定时器也必须停。它持有 Timer，且回调里
    // 会 notifyListeners() —— 断开后还留着，就是一条通往已 dispose 状态的
    // 定时回调。
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;

    // 先把状态落定、再关底层 socket。
    //
    // 顺序很重要：关闭码、socket 是否已半关，这些都取决于底层库，任何一种失败
    // 都不该让"已断开"这个状态写不上去。
    final closing = _channel;
    _channel = null;
    _status = ConnectionStatus.disconnected;
    notifyListeners();

    try {
      // 必须是 1000（正常关闭），**不能**用 ws_status.goingAway。
      //
      // goingAway 是 1001，属于协议保留码：客户端只允许发 1000 或 3000-4999，
      // 发 1001 会被底层直接拒绝并抛
      //   "Invalid argument: 1001, close code must be 1000 or in the range 3000-4999"。
      //
      // 这不是理论问题，是实测到的真实缺陷：那个异常会中断 disconnect()，使它
      // 后面的 _channel = null / _status = disconnected / notifyListeners() 全部
      // 不执行 —— 调用方以为断开了，实际状态仍是 connected、界面也不刷新；
      // dispose() 里的 super.dispose() 同样被跳过。由订阅集成测试暴露。
      closing?.sink.close(ws_status.normalClosure);
    } catch (e) {
      debugPrint('[DshService] 关闭 WS 失败（状态已更新，忽略）: $e');
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    disconnect();
    // [fix 2026-10-16] 补上两处漏掉的清理。
    //
    // ① 共享 http.Client（类顶部持有）从未被关闭：它的 keep-alive 连接会
    //    活到进程结束。DshService 目前是进程级单例，所以这是潜伏问题；
    //    但 hot restart / provider 重建时会真的漏 socket。
    // ② DraftStore 是单例，有防抖写盘。不 flush 就 dispose，最后一次输入
    //    （600ms 防抖窗口内）直接丢。
    _httpClient.close();
    drafts.flushNow();
    _historyCache.clear();
    super.dispose();
  }
}

/// 把 HTTP 响应完整读完后核对连接代次。
///
/// http.BaseClient.get/post 在 send 返回后还会继续读 body；只在 send 入口检查
/// 不足以阻止“A 网关的响应在切到 B 之后才读完并写进 UI”。因此这里统一缓冲
/// 响应体（手机端 REST 响应本来就不做增量消费），再在返回前复核一次代次。
class _GenerationHttpClient extends http.BaseClient {
  _GenerationHttpClient({
    required http.Client inner,
    required this.generation,
    required this.isCurrent,
  }) : _inner = inner;

  final http.Client _inner;
  final int generation;
  final bool Function(int generation) isCurrent;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!isCurrent(generation)) throw const _StaleConnectionException();
    final response = await _inner.send(request);
    final bytes = await response.stream.toBytes();
    if (!isCurrent(generation)) throw const _StaleConnectionException();
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

class _StaleConnectionException implements Exception {
  const _StaleConnectionException();

  @override
  String toString() => 'stale-connection';
}

/// 一次打开过的会话消息快照（供 DshService 的会话消息缓存首帧回填用）。
///
/// 只用于"再打开一次时先显示什么"，不是真相：网络结果回来后按对账合并覆盖
/// （见 selectSession 的缓存命中分支）。
class _SessionHistorySnapshot {
  const _SessionHistorySnapshot({
    required this.messages,
    required this.exhausted,
    required this.cachedAt,
  });

  final List<ChatMessage> messages;

  /// 当时是否已翻到会话开头（决定回填后还要不要继续补页）。
  final bool exhausted;
  final DateTime cachedAt;
}
