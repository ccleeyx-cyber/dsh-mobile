import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
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
import 'notification_service.dart';
import '../models/audit_log.dart';
import '../models/persona.dart';

enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

class DshService extends ChangeNotifier {
  WebSocketChannel? _channel;
  Timer? _heartbeatTimer;
  Timer? _sessionPollTimer;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  String _lastError = '';
  ServerConfig? _currentConfig;
  final Uuid _uuid = const Uuid();

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
  int _reasoningBudget = 8000;
  double _temperature = 0.7;
  bool _isLoadingHistory = false;
  bool _isSending = false;
  bool _isCanceling = false;
  int _activeTurnSeq = 0;
  int _cancelledTurnSeq = 0;
  String? _currentSessionModel;
  int _sessionLoadSeq = 0;
  int _streamRevision = 0;

  /// 等待本机用户回答的提问（patch 0003）。
  ///
  /// 只有订阅者才会收到这些，所以这里非空就意味着「agent 正在等一个人回答」，
  /// 而这个人应当就是拿着这台手机的人。切换会话时必须清空，否则会把上一个会话
  /// 的提问卡片显示到新会话里。
  final List<PendingQuestion> _pendingQuestions = [];

  /// 是否已向网关声明本机可以回答提问。断线重连后要重新订阅。
  bool _questionsSubscribed = false;

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
          return t.isEmpty ? '会话 ${sessionId.substring(0, sessionId.length.clamp(0, 8))}' : t;
        }
      }
    }
    final short = sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;
    return '会话 $short';
  }

  /// 事件通知（§4.2 推送通知）。单例，便于 UI 直接开关与查询状态。
  final NotificationService notifications = NotificationService.instance;

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

  /// 开启后台通知能力（拉起前台保活服务）。
  ///
  /// 返回是否成功。**失败必须被如实告知用户**：Android 12+ 对后台启动前台服务
  /// 有限制，用户手动划掉通知也会让它失效。这个场景下"App 看起来能收通知但
  /// 其实收不到"是最糟的结果 —— 所以状态要暴露到 UI 上，而不是静默失败。
  Future<bool> enableBackgroundNotifications() => notifications.enableBackground();

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

  /// 发出成功后清草稿。**只在这里清** —— 见 [sendChatMessage] 的失败分支。
  void _clearDraftAfterSend() => drafts.clear(_draftKey);

  /// 离线 / 发送失败时把正文还回草稿。
  ///
  /// 这是草稿功能真正的价值：用户点发送 → 手机没信号 → 正文凭空消失，用户
  /// 只能凭记忆重打。所以失败时正文必须回到输入框。
  void restoreDraft(String text) => drafts.write(_draftKey, text);

  List<MapEntry<String, String>> get allDrafts => drafts.all();

  // Getters
  ConnectionStatus get status => _status;
  String get lastError => _lastError;
  void clearError() { _lastError = ''; notifyListeners(); }
  String get currentModel => _currentSessionModel ?? _settings?.currentModel ?? 'cn:deepseek-v4.1-flash';
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
    return _todos[s.sessionId.replaceFirst(RegExp(r'^session-'), '')] ?? const [];
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
  List<ChatMessage> get messages => _messages;
  List<ApprovalRequest> get pendingApprovals => _pendingApprovals;
  DshSettings? get settings => _settings;
  PermissionConfig get permissions => _permissions;
  List<AuditLogItem> get auditLogs => _auditLogs;
  List<AgentPersona> get personas => _personas;
  String? get activePersonaId => _activePersonaId;
  int get pingMs => _pingMs;
  int get reasoningBudget => _reasoningBudget;
  double get temperature => _temperature;
  bool get isLoadingHistory => _isLoadingHistory;
  bool get isSending => _isSending;
  bool get isCanceling => _isCanceling;
  int get streamRevision => _streamRevision;

  // Connection Status Helpers & Reconnect Info (F3.1, F3.4)
  int get reconnectAttempts => _reconnectAttempts;
  bool get isReconnecting => _isReconnecting;
  bool get isConnecting => _status == ConnectionStatus.connecting;
  bool get isDisconnected => _status == ConnectionStatus.disconnected;
  bool get hasError => _status == ConnectionStatus.error;
  bool get isTokenInvalid => _isTokenInvalid;
  bool get hasAuthError => _isTokenInvalid;

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
    notifyListeners();
  }

  void clearAuthError() {
    _isTokenInvalid = false;
    _lastError = '';
    notifyListeners();
  }

  bool _checkResponseAuth(http.Response res) {
    if (res.statusCode == 401 || res.statusCode == 403) {
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
      'Connection': 'close',
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
        'Connection': 'close',
      };

      final testEndpoints = [
        '${config.httpBaseUrl}/api/mobile/ping',
        '${config.httpBaseUrl}/api/mobile/health',
        '${config.httpBaseUrl}/health',
        '${config.httpBaseUrl}/api/mobile/workspaces',
        '${config.httpBaseUrl}/api/mobile/settings',
      ];

      for (final endpoint in testEndpoints) {
        try {
          final res = await http.get(Uri.parse(endpoint), headers: headers).timeout(const Duration(seconds: 4));
          if (res.statusCode >= 200 && res.statusCode < 300) {
            try {
              final body = jsonDecode(res.body);
              if (body is Map && (body['authenticated'] == false || body['code'] == 401)) {
                _lastError = '认证失败: 授权码错误或未提供有效令牌';
                return false;
              }
            } catch (_) {}
            return true;
          }
          if (res.statusCode == 401 || res.statusCode == 403) {
            _lastError = '认证失败 (HTTP ${res.statusCode}): 请核对访问令牌或授权码';
            return false;
          }
        } catch (_) {}
      }
      return false;
    } catch (e) {
      _lastError = e.toString();
      return false;
    }
  }

  // Connect
  Future<void> connect(ServerConfig config) async {
    _currentConfig = config;
    _isExplicitlyDisconnected = false;
    _isTokenInvalid = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;

    _status = ConnectionStatus.connecting;
    notifyListeners();

    try {
      await _cleanTeardownSocket();

      final uri = Uri.parse(config.wsUrl);
      _channel = WebSocketChannel.connect(uri);

      _channelSubscription = _channel!.stream.listen(
        (data) {
          if (_status != ConnectionStatus.connected) {
            _status = ConnectionStatus.connected;
            _reconnectAttempts = 0;
            _isReconnecting = false;
            notifyListeners();
          }
          _handleRawMessage(data);
        },
        onError: (error) {
          debugPrint('[DshService] WebSocket error: $error');
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
          debugPrint('[DshService] WebSocket onDone closed');
          final code = _channel?.closeCode;
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

      // Opt in to interactive prompts. Re-sent on every (re)connect because the
      // gateway keeps subscriptions per live socket: a reconnect lands on a new
      // socket that has never heard of this phone, and without this the user
      // would silently stop being able to answer questions.
      _questionsSubscribed = false;
      _sendWsJson({'type': 'subscribe_questions'});

      // Fetch initial data
      await fetchWorkspaces();
      await fetchSettings();
      await fetchApprovals();
      await fetchPermissions();
      await fetchAuditLogs();
      await fetchPersonas();
      await measurePing();
    } catch (e) {
      _status = ConnectionStatus.error;
      _lastError = e.toString();
      _isReconnecting = false;
      notifyListeners();
      _scheduleReconnect();
    }
  }

  // Workspaces Management
  Future<void> fetchWorkspaces() async {
    if (_currentConfig == null) return;
    try {
      // 归档过滤交给网关做，而不是拉全量回来在客户端筛：本机 2322 个会话里有
      // 1338 个已归档，全量传输会把一个定时轮询的响应放大到 2.4 倍。
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/workspaces')
          .replace(queryParameters: {'archived': _archivedFilter});
      final res = await http.get(url, headers: _authHeaders).timeout(const Duration(seconds: 8));
      if (_checkResponseAuth(res)) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final list = data['workspaces'] as List<dynamic>? ?? [];
        _workspaces = list.map((w) => Workspace.fromJson(w as Map<String, dynamic>)).toList();

        // 能力探测：只有网关如实回显了我们请求的模式，才算筛选真的生效了。
        _archivedFilterSupported = data['archivedMode']?.toString() == _archivedFilter;

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
            if (cur != null && !matched.sessions.any((s) => s.matchesSessionId(cur.sessionId))) {
              matched.sessions.insert(0, cur);
            }
          } else if (_workspaces.isNotEmpty) {
            _currentWorkspace = _workspaces.first;
            if (_currentWorkspace!.sessions.isNotEmpty && _currentSession == null) {
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
    if (archivedFilterSupported != null) _archivedFilterSupported = archivedFilterSupported;
    if (archivedFilter != null) _archivedFilter = archivedFilter;
    notifyListeners();
  }

  /// 测试用：直接设定连接状态。
  ///
  /// 存在的原因：一批 UI 路径只在"已连接"时才可达（附件入口、发送、语音上传等），
  /// 而真正建连要开 WebSocket 打真实网关 —— 单测里既做不到也不该做。没有这个缝，
  /// 那些路径就只能靠人眼看，等于没测。
  @visibleForTesting
  void debugSetConnection(bool connected) {
    _status = connected ? ConnectionStatus.connected : ConnectionStatus.disconnected;
    notifyListeners();
  }

  void selectWorkspace(Workspace ws, {bool autoSelectSession = true}) {
    _currentWorkspace = ws;
    _sessionPollTimer?.cancel();
    _sessionPollTimer = null;
    _sessionLoadSeq++; // Cancel any pending session loads
    _isSending = false;
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
      final answer = AskUserQuestionAnswerItem(id: item.id, selected: selected, custom: custom);
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
    if (cfg == null) throw const AttachmentError('尚未配置网关地址');
    final sid = sessionId ?? _currentSession?.sessionId;
    if (sid == null || sid.isEmpty) throw const AttachmentError('请先选择一个会话再上传文件');
    if (bytes.isEmpty) throw const AttachmentError('文件是空的');

    final uri = Uri.parse('${cfg.httpBaseUrl}/api/mobile/upload').replace(
      queryParameters: {'sessionId': sid, 'name': name},
    );

    http.Response res;
    try {
      res = await http.post(
        uri,
        headers: {
          ..._authHeaders,
          'Content-Type': 'application/octet-stream',
        },
        body: bytes,
      ).timeout(const Duration(seconds: 120));
    } catch (e) {
      throw AttachmentError('上传失败：${e is Exception ? e.toString().split(':').first : e}');
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
      throw AttachmentError(body['error']?.toString() ?? '上传失败 (HTTP ${res.statusCode})');
    }
    final receiptId = body['receiptId']?.toString() ?? '';
    if (receiptId.isEmpty) {
      throw const AttachmentError('上传成功但服务端没有返回凭据，请重试');
    }
    return receiptId;
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
    final currentSeq = ++_sessionLoadSeq;
    _sessionPollTimer?.cancel();
    _sessionPollTimer = null;
    _currentSession = session;
    _activeTurnSeq++;
    _cancelledTurnSeq = _activeTurnSeq;
    _messages = []; // Clear immediately to prevent cross-contamination
    // 提问是**会话级**的，不是全局的。切会话时丢掉旧提问，否则会把上一个会话的
    // 输入卡片挂到新会话的输入框上方 —— 用户会对着一个跟自己无关的问题作答。
    // TODO 与附件表相反：它们按会话分别存着，切过去直接就能显示。
    _pendingQuestions.clear();
    _lastQuestionError = null;
    _isSending = false; // Reset sending state immediately
    _isLoadingHistory = true;
    _lastError = '';
    notifyListeners();

    // Notify server to follow this session for real-time streaming
    _sendWsJson({'type': 'follow', 'sessionId': session.sessionId});

    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/${session.sessionId}');
      final res = await http.get(url, headers: _authHeaders).timeout(const Duration(seconds: 8));
      if (_checkResponseAuth(res)) return;

      // Guard: if user switched to another session while HTTP was in flight, discard!
      if (currentSeq != _sessionLoadSeq) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final sessionData = data['data'] as Map<String, dynamic>?;
        final rawMessages = sessionData?['messages'] as List<dynamic>? ?? [];
        final isRunning = sessionData?['isRunning'] == true;
        final sModel = sessionData?['model'] as String?;
        if (sModel != null && sModel.isNotEmpty) {
          _currentSessionModel = sModel;
        } else if (session.model.isNotEmpty) {
          _currentSessionModel = session.model;
        } else {
          _currentSessionModel = _settings?.currentModel;
        }

        _messages = rawMessages.map((m) {
          final rawTools = m['tools'] as List<dynamic>? ?? [];
          return ChatMessage(
            id: m['id'] ?? _uuid.v4(),
            role: m['role'] ?? 'assistant',
            content: m['content'] ?? '',
            thinking: m['thinking'],
            isMemory: m['isMemory'] == true || m['role'] == 'memory',
            isContext: m['isContext'] == true || m['role'] == 'context',
            tools: rawTools.map((t) => ToolExecution(
              name: t['name'] ?? '',
              input: _coerceToolInput(t['input']),
              output: _coerceToolInput(t['output']),
              isRunning: t['isRunning'] ?? false,
            )).toList(),
            timestamp: m['time'] != null ? DateTime.fromMillisecondsSinceEpoch(m['time']) : null,
          );
        }).toList();

        if (isRunning && _messages.isNotEmpty && _messages.last.isAssistant) {
          _messages.last.isStreaming = true;
          _isSending = true;
          _startSessionPolling(session.sessionId);
        } else {
          _isSending = false;
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
      }
    }
  }

  Future<void> createNewSession([String? workspaceId]) async {
    final currentSeq = ++_sessionLoadSeq; // Invalidate any in-flight session loads
    _sessionPollTimer?.cancel();
    _sessionPollTimer = null;
    _isSending = false;
    _activeTurnSeq++;
    _cancelledTurnSeq = _activeTurnSeq;
    _isLoadingHistory = false;
    _lastError = '';

    // Immediately empty out messages as requested: "点击新增会话之后应该是出现一个空的会话"
    _messages = [];

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
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/create');
      final res = await http.post(
        url,
        headers: _authHeaders,
        body: jsonEncode({
          'workspaceId': _currentWorkspace!.workspaceId,
        }),
      ).timeout(const Duration(seconds: 8));
      if (_checkResponseAuth(res)) return;

      // Guard: if user switched to another session while request was in-flight, discard
      if (currentSeq != _sessionLoadSeq) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final realSessionId = data['sessionId']?.toString() ?? data['session']?['sessionId']?.toString();
        if (realSessionId != null && realSessionId.isNotEmpty) {
          final realSession = SessionMeta(
            sessionId: realSessionId,
            title: '新对话',
            model: _currentSessionModel ?? _settings?.currentModel ?? '',
            lastPromptAt: DateTime.now().millisecondsSinceEpoch,
          );
          if (_currentWorkspace != null) {
            final idx = _currentWorkspace!.sessions.indexWhere((s) => s.sessionId == tempSessionId);
            if (idx != -1) {
              _currentWorkspace!.sessions[idx] = realSession;
            } else {
              _currentWorkspace!.sessions.insert(0, realSession);
            }
          }
          _currentSession = realSession;
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
  Future<void> sendChatMessage(String text, {List<PendingAttachment> attachments = const []}) async {
    if (text.trim().isEmpty && attachments.isEmpty) return;

    final sessionId = _currentSession?.sessionId ?? 'default';

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
    final userMsg = ChatMessage(
      id: _uuid.v4(),
      role: 'user',
      content: displayText,
      timestamp: DateTime.now(),
    );
    _messages.add(userMsg);

    // 2. Prepare streaming assistant placeholder with thinking state
    final assistantMsg = ChatMessage(
      id: _uuid.v4(),
      role: 'assistant',
      content: '',
      thinking: '', // initialize so ThinkingCard immediately displays active reasoning state
      isStreaming: true,
      timestamp: DateTime.now(),
    );
    _messages.add(assistantMsg);

    final int turnId = ++_activeTurnSeq;
    _isSending = true;
    _streamRevision++;
    notifyListeners();

    // Send follow event via WS
    _sendWsJson({'type': 'follow', 'sessionId': sessionId});

    try {
      // Send via HTTP RPC with retry to tolerate reverse proxy Keep-Alive drops
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/prompt');
      http.Response? res;
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          res = await http.post(
            url,
            headers: _authHeaders,
            body: jsonEncode({
              'sessionId': sessionId,
              'text': text,
              'model': currentModel,
              // 附件（v1.10.0）。图片是内联 base64 的 image part，文件是上传后换到的
              // receiptId。网关负责把它们并进引擎要求的 content 数组。
              if (attachments.isNotEmpty)
                'attachments': attachments.map((a) => a.toWirePart()).toList(),
            }),
          ).timeout(const Duration(seconds: 20));
          break;
        } on http.ClientException catch (e) {
          if (attempt == 1) rethrow;
          debugPrint('[DshService] sendPrompt proxy drop, retrying: $e');
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }

      if (_isCanceling || turnId <= _cancelledTurnSeq) {
        debugPrint('[DshService] sendPrompt finished but turn was canceled; ignoring response.');
        return;
      }

      if (res != null && _checkResponseAuth(res)) return;

      if (res != null && res.statusCode == 200) {
        // 3. Start fallback session polling
        _startSessionPolling(sessionId);
        // 只在真正被网关接受后清草稿。放在失败分支之前清，会让"重试"失去
        // 正文。
        _clearDraftAfterSend();
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
        _isSending = false;
        // 正文还回草稿：网关没收到，用户不该只能凭记忆重打。
        restoreDraft(text);
        notifyListeners();
      }
    } catch (e) {
      if (_isCanceling || turnId <= _cancelledTurnSeq) return;
      debugPrint('[DshService] sendPrompt error: $e');
      _lastError = '发送指令异常: $e';
      assistantMsg.content = '❌ 发送指令失败: $e';
      assistantMsg.isStreaming = false;
      _isSending = false;
      restoreDraft(text);
      notifyListeners();
    }
  }

  // Active Session Polling (Live Reasoning & Execution Sync)
  void _startSessionPolling(String sessionId) {
    _sessionPollTimer?.cancel();
    int ticks = 0;
    const maxTicks = 350; // max ~240s

    _sessionPollTimer = Timer.periodic(const Duration(milliseconds: 700), (timer) async {
      ticks++;
      if (_isDisposed || ticks > maxTicks || _currentSession == null || !_currentSession!.matchesSessionId(sessionId)) {
        timer.cancel();
        _sessionPollTimer = null;
        if (_currentSession != null && _currentSession!.matchesSessionId(sessionId)) {
          _isSending = false;
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

      try {
        final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/$sessionId');
        final res = await http.get(url, headers: _authHeaders).timeout(const Duration(seconds: 5));
        if (_checkResponseAuth(res)) {
          timer.cancel();
          _sessionPollTimer = null;
          return;
        }

        // If user changed session or canceled while HTTP was in flight, abort!
        if (_isCanceling || _sessionPollTimer == null || _currentSession == null || !_currentSession!.matchesSessionId(sessionId)) {
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
      }
    });
  }

  // Active Session State & Pending Stream Chunks Resync (F3.3)
  Future<void> _resyncActiveSession(String sessionId) async {
    if (_currentConfig == null || _currentSession == null) return;
    if (!_currentSession!.matchesSessionId(sessionId)) return;

    final targetSessionId = _currentSession!.sessionId;
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/$targetSessionId');
      final res = await http.get(url, headers: _authHeaders).timeout(const Duration(seconds: 5));
      if (_checkResponseAuth(res)) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final sessionData = data['data'] as Map<String, dynamic>?;
        if (sessionData == null) return;

        // Guard against mid-flight session navigation
        if (_currentSession == null || !_currentSession!.matchesSessionId(targetSessionId)) return;

        final rawMessages = sessionData['messages'] as List<dynamic>? ?? [];
        final isServerRunning = sessionData['isRunning'] == true;
        final serverModel = sessionData['model'] as String?;
        if (serverModel != null && serverModel.isNotEmpty) {
          _currentSessionModel = serverModel;
        }

        _reconcileSessionMessages(rawMessages, isServerRunning, targetSessionId);
      }
    } catch (e) {
      debugPrint('[DshService] _resyncActiveSession error: $e');
    }
  }

  // Non-destructive 4-Way Stream Chunk & Session Reconciliation (F3.3)
  void _reconcileSessionMessages(List<dynamic> rawMessages, bool isServerRunning, String targetSessionId) {
    if (_currentSession == null || !_currentSession!.matchesSessionId(targetSessionId)) return;

    final serverMessages = rawMessages.map((m) {
      final rawTools = m['tools'] as List<dynamic>? ?? [];
      return ChatMessage(
        id: m['id'] ?? _uuid.v4(),
        role: m['role'] ?? 'assistant',
        content: m['content'] ?? '',
        thinking: m['thinking'],
        isMemory: m['isMemory'] == true || m['role'] == 'memory',
        isContext: m['isContext'] == true || m['role'] == 'context',
        tools: rawTools.map((t) => ToolExecution(
          name: t['name'] ?? '',
          input: _coerceToolInput(t['input']),
          output: _coerceToolInput(t['output']),
          isRunning: t['isRunning'] ?? false,
        )).toList(),
        timestamp: m['time'] != null ? DateTime.fromMillisecondsSinceEpoch(m['time']) : null,
      );
    }).toList();

    // Turn cancellation sequence fence
    if (_isCanceling || _activeTurnSeq <= _cancelledTurnSeq) {
      isServerRunning = false;
    }

    if (isServerRunning) {
      _isSending = true;

      if (serverMessages.isNotEmpty && serverMessages.last.isAssistant) {
        final serverAssistant = serverMessages.last;
        serverAssistant.isStreaming = true;

        final localAssistant = _messages.isNotEmpty && _messages.last.isAssistant ? _messages.last : null;
        if (localAssistant != null) {
          // 1. Reconcile thinking: never discard in-flight local thoughts
          if ((localAssistant.thinking != null && localAssistant.thinking!.isNotEmpty) &&
              (serverAssistant.thinking == null || serverAssistant.thinking!.isEmpty ||
               localAssistant.thinking!.length > serverAssistant.thinking!.length)) {
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
        if (_messages.isNotEmpty && _messages.last.isAssistant && _messages.last.isStreaming) {
          serverMessages.add(_messages.last);
        }
      }
    } else {
      // Graceful transition to idle when turn finished on server while disconnected
      _isSending = false;
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
        final localAssistant = _messages.isNotEmpty && _messages.last.isAssistant ? _messages.last : null;
        if (localAssistant != null && (localAssistant.thinking != null && localAssistant.thinking!.isNotEmpty) &&
            (serverAssistant.thinking == null || serverAssistant.thinking!.isEmpty)) {
          serverAssistant.thinking = localAssistant.thinking;
        }
      }
    }

    // 3. Preserve recent local user prompts without duplicating or inversing order
    final serverUserTexts = serverMessages.where((m) => m.isUser).map((m) => m.content).toSet();
    for (final localMsg in _messages.where((m) => m.isUser)) {
      if (localMsg.content.isNotEmpty && !serverUserTexts.contains(localMsg.content)) {
        // ChatMessage.timestamp is a non-nullable DateTime (the constructor
        // defaults it to DateTime.now()), so the old `timestamp != null` guard
        // was dead code and the `!` was a no-op.
        if (DateTime.now().difference(localMsg.timestamp).inSeconds < 45) {
          final assistIdx = serverMessages.indexWhere((m) => m.isAssistant && m.isStreaming);
          if (assistIdx != -1) {
            serverMessages.insert(assistIdx, localMsg);
          } else {
            serverMessages.add(localMsg);
          }
        }
      }
    }

    _messages = serverMessages;
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
    _isSending = false;
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
        } else if (!msg.content.endsWith('*(任务已被手动停止)*') && !msg.content.endsWith('*(已取消)*')) {
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
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/cancel');
      await http.post(
        url,
        headers: _authHeaders,
        body: jsonEncode({
          'sessionId': _currentSession!.sessionId,
        }),
      ).timeout(const Duration(seconds: 5));
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
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/settings');
      final res = await http.get(url, headers: _authHeaders).timeout(const Duration(seconds: 6));
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

  Future<bool> switchModel(String modelId, {String? sessionId}) async {
    if (_currentConfig == null) return false;
    final targetSessionId = sessionId ?? _currentSession?.sessionId;

    // 1. If we have an active session, attempt session/model endpoint
    if (targetSessionId != null && targetSessionId.isNotEmpty && targetSessionId != 'default') {
      try {
        final sessionUrl = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/model');
        final res = await http.post(
          sessionUrl,
          headers: _authHeaders,
          body: jsonEncode({
            'sessionId': targetSessionId,
            'model': modelId,
          }),
        ).timeout(const Duration(seconds: 5));
        if (_checkResponseAuth(res)) return false;
      } catch (e) {
        debugPrint('[DshService] session model switch non-critical: $e');
      }
    }

    // 2. Also persist to global settings
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/settings/model');
      final res = await http.post(
        url,
        headers: _authHeaders,
        body: jsonEncode({'model': modelId}),
      ).timeout(const Duration(seconds: 5));
      if (_checkResponseAuth(res)) return false;
    } catch (e) {
      debugPrint('[DshService] global settings model switch non-critical: $e');
    }

    // 3. Always update local state so subsequent prompts use this model
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
    await fetchSettings();
    notifyListeners();
    return true;
  }

  // Delete Session
  Future<bool> deleteSession(String sessionId, [String? workspaceId]) async {
    if (_currentConfig == null) return false;
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/delete');
      final res = await http.post(
        url,
        headers: _authHeaders,
        body: jsonEncode({
          'sessionId': sessionId,
          'workspaceId': workspaceId ?? _currentWorkspace?.workspaceId ?? '',
        }),
      ).timeout(const Duration(seconds: 8));
      if (_checkResponseAuth(res)) return false;

      if (res.statusCode == 200) {
        for (final ws in _workspaces) {
          ws.sessions.removeWhere((s) => s.matchesSessionId(sessionId));
        }

        if (_currentSession?.matchesSessionId(sessionId) == true) {
          if (_currentWorkspace != null && _currentWorkspace!.sessions.isNotEmpty) {
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
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/approvals');
      final res = await http.get(url, headers: _authHeaders).timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final list = data['approvals'] as List<dynamic>? ?? [];
        _pendingApprovals = list.map((a) => ApprovalRequest.fromJson(a as Map<String, dynamic>)).toList();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DshService] fetchApprovals error: $e');
    }
  }

  Future<void> respondApproval(ApprovalRequest req, String outcome, {String? reason}) async {
    if (_currentConfig == null) return;
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/approval');
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
            if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
          }));
        } catch (_) {}
      }

      final res = await http.post(
        url,
        headers: _authHeaders,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 8));
      if (_checkResponseAuth(res)) return;

      if (res.statusCode == 200) {
        _pendingApprovals.removeWhere((a) => a.eventId == req.eventId || a.id == req.id);
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
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/permissions');
      final res = await http.get(url, headers: _authHeaders).timeout(const Duration(seconds: 6));
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
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/permissions');
      final res = await http.post(
        url,
        headers: _authHeaders,
        body: jsonEncode(newConfig.toJson()),
      ).timeout(const Duration(seconds: 6));
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
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/audit-logs');
      final res = await http.get(url, headers: _authHeaders).timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final list = (data['auditLogs'] ?? data['logs']) as List<dynamic>? ?? [];
        _auditLogs = list.map((a) => AuditLogItem.fromJson(a as Map<String, dynamic>)).toList();
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
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/personas');
      final res = await http.get(url, headers: _authHeaders).timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final list = data['personas'] as List<dynamic>? ?? [];
        _personas = list.map((p) => AgentPersona.fromJson(p as Map<String, dynamic>)).toList();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DshService] fetchPersonas error: $e');
    }
  }

  Future<bool> savePersonas(List<AgentPersona> list) async {
    if (_currentConfig == null) return false;
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/personas');
      final res = await http.post(
        url,
        headers: _authHeaders,
        body: jsonEncode({'personas': list.map((p) => p.toJson()).toList()}),
      ).timeout(const Duration(seconds: 6));
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

  void setReasoningBudget(int tokens) {
    _reasoningBudget = tokens;
    notifyListeners();
  }

  void setTemperature(double temp) {
    _temperature = temp;
    notifyListeners();
  }

  // Ping
  Future<int> measurePing() async {
    if (_currentConfig == null) return -1;
    final start = DateTime.now().millisecondsSinceEpoch;
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/ping');
      final res = await http.get(url, headers: _authHeaders).timeout(const Duration(seconds: 4));
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
      final uri = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/workspace/memory').replace(
        queryParameters: {'path': workspacePath},
      );
      final res = await http.get(uri, headers: _authHeaders).timeout(const Duration(seconds: 6));
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
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/workspace/memory');
      final res = await http.post(
        url,
        headers: _authHeaders,
        body: jsonEncode({'path': workspacePath, 'content': content}),
      ).timeout(const Duration(seconds: 6));
      if (_checkResponseAuth(res)) return false;
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[DshService] saveWorkspaceMemory error: $e');
      return false;
    }
  }

  // Incoming WebSocket Message Processing
  void _handleRawMessage(dynamic raw) {
    if (raw is! String) return;
    if (raw == 'pong') return;

    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return;

      final type = json['type'] ?? json['event'];
      if (type == 'pong') return;

      // Auth error check from WS frame
      if (json['code'] == 401 || json['type'] == 'unauthorized' || json['status'] == 401) {
        handleAuthFailure(json['error']?.toString() ?? json['message']?.toString() ?? '认证失败: Token无效');
        return;
      }

      // 1. Initial pending approvals from server
      if (type == 'system' && json['pendingApprovals'] is List) {
        final list = json['pendingApprovals'] as List<dynamic>;
        _pendingApprovals = list.map((a) => ApprovalRequest.fromJson(a as Map<String, dynamic>)).toList();
        notifyListeners();
        return;
      }

      // 2. Real-time Approval Request
      if (type == 'approval_request' && json['approval'] != null) {
        final req = ApprovalRequest.fromJson(json['approval'] as Map<String, dynamic>);
        // Avoid duplicate
        if (!_pendingApprovals.any((a) => a.eventId == req.eventId)) {
          _pendingApprovals.add(req);
          notifyListeners();
          // 待授权是"agent 已经停下等你"的时刻，必须能打断 —— 静默处理等于
          // 让会话永远卡住。所以用高重要性渠道，会弹横幅。
          if (shouldNotify) {
            notifications.show(
              title: '需要你授权',
              body: '${req.toolName}：${req.reason}',
              kind: NotificationKind.actionRequired,
            );
          }
        }
        return;
      }

      // 3. Approval Settled
      if (type == 'approval_settled') {
        final eventId = json['eventId'];
        _pendingApprovals.removeWhere((a) => a.eventId == eventId || a.id == eventId);
        notifyListeners();
        return;
      }

      // Real-time Permission Update Broadcast
      if (type == 'permission_updated' && json['permissions'] != null) {
        _permissions = PermissionConfig.fromJson(json['permissions'] as Map<String, dynamic>);
        notifyListeners();
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
            _isSending = false;
            _isCanceling = false;
            _sessionPollTimer?.cancel();
            _sessionPollTimer = null;
            if (_messages.isNotEmpty && _messages.last.isAssistant) {
              _messages.last.isStreaming = false;
              for (final t in _messages.last.tools) {
                t.isRunning = false;
              }
            }
          } else {
            if (_activeTurnSeq > _cancelledTurnSeq && !_isCanceling) {
              _isSending = true;
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
        for (final ws in _workspaces) {
          ws.sessions.removeWhere((s) => s.matchesSessionId(sId));
        }
        if (_currentSession?.matchesSessionId(sId) == true) {
          if (_currentWorkspace != null && _currentWorkspace!.sessions.isNotEmpty) {
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
        _lastError = errStr;
        if (sId != null && _currentSession != null && _currentSession!.matchesSessionId(sId)) {
          if (_messages.isNotEmpty && _messages.last.isAssistant && _messages.last.isStreaming) {
            _messages.last.content = '❌ 发生错误: $errStr';
            _messages.last.isStreaming = false;
          }
          _isSending = false;
        }
        notifyListeners();
        return;
      }

      // 5. Streaming tokens and chat chunks (thinking / delta / token)
      if (type == 'thinking' || type == 'delta' || type == 'token' || json.containsKey('delta') || json.containsKey('thinking')) {
        final sId = json['sessionId']?.toString();
        if (sId == null || _currentSession == null || !_currentSession!.matchesSessionId(sId)) {
          return;
        }

        // Drop lingering stream chunks if user canceled this turn or turn sequence mismatch
        if (_isCanceling) return;
        if (_activeTurnSeq <= _cancelledTurnSeq) return;

        if (_messages.isEmpty || !_messages.last.isAssistant) {
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
        _isSending = true;

        if (type == 'thinking' || json.containsKey('thinking')) {
          final text = json['delta'] ?? json['thinking'] ?? '';
          current.thinking = (current.thinking ?? '') + text.toString();
          _streamRevision++;
          notifyListeners();
        } else {
          final text = json['delta'] ?? json['content'] ?? json['text'] ?? '';
          current.content += text.toString();
          _streamRevision++;
          notifyListeners();
        }
        return;
      }

      // 6. Tool Executions
      if (type == 'tool_start' || type == 'tool_call') {
        final sId = json['sessionId']?.toString();
        if (sId == null || _currentSession == null || !_currentSession!.matchesSessionId(sId)) {
          return;
        }

        // Drop tool start if canceled or turn sequence mismatch
        if (_isCanceling) return;
        if (_activeTurnSeq <= _cancelledTurnSeq) return;

        if (_messages.isEmpty || !_messages.last.isAssistant) {
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
        _messages.last.tools.add(ToolExecution(name: toolName, input: toolInput, isRunning: true));
        _messages.last.isStreaming = true;
        _isSending = true;
        _streamRevision++;
        notifyListeners();
        return;
      }

      if (type == 'tool_result' || type == 'tool_end') {
        if (_isCanceling) return;
        if (_activeTurnSeq <= _cancelledTurnSeq) return;

        final sId = json['sessionId']?.toString();
        if (sId == null || _currentSession == null || !_currentSession!.matchesSessionId(sId)) {
          return;
        }

        if (_messages.isNotEmpty && _messages.last.isAssistant && _messages.last.tools.isNotEmpty) {


          final lastTool = _messages.last.tools.last;
          lastTool.isRunning = false;
          lastTool.output = _coerceToolInput(json['output'] ?? json['result'] ?? '完成');
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
              if (_pendingQuestions.any((p) => p.eventId == q.eventId)) continue;
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
          if (shouldNotify) {
            notifications.show(
              title: 'Agent 在等你回答',
              // 取第一道题的问题文本；有多道题时不逐条罗列 —— 通知栏放不下，
              // 而且点进去就能看到全部。
              body: q.questions.first.question,
              kind: NotificationKind.actionRequired,
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
        _lastQuestionError = ok ? null : (json['reason']?.toString() ?? '提问未能送达');
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
          _lastQuestionError = '提问已失效：${json['reason']?.toString() ?? '会话状态变化'}';
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
          _lastQuestionError = json['error']?.toString() == 'unknown-question'
              ? '该提问已过期（可能已被其它设备回答）'
              : '提交失败：${json['error'] ?? '未知错误'}';
          // Here the request is genuinely gone (unknown / not claimable), so
          // the card would otherwise stay forever with no way forward.
          final before = _pendingQuestions.length;
          _pendingQuestions.removeWhere((p) => p.eventId == json['eventId']);
          if (_pendingQuestions.length != before) notifyListeners();
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
          );
        }

        if (sId == null || _currentSession == null || !_currentSession!.matchesSessionId(sId)) {
          return;
        }
        if (_messages.isNotEmpty && _messages.last.isAssistant) {
          final current = _messages.last;
          current.isStreaming = false;
          for (var t in current.tools) {
            t.isRunning = false;
          }
        }
        _sessionPollTimer?.cancel();
        _sessionPollTimer = null;
        _isSending = false;
        _isCanceling = false;
        _streamRevision++;
        notifyListeners();
        fetchWorkspaces();
        return;
      }

    } catch (e) {
      debugPrint('[DshService] JSON parse error: $e');
    }
  }

  // Heartbeat
  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      if (_isDisposed) {
        timer.cancel();
        return;
      }
      if (_status == ConnectionStatus.connected) {
        try {
          _channel?.sink.add('ping');
        } catch (_) {}
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  // Clean Socket Teardown (F4.4 / F3.1)
  Future<void> _cleanTeardownSocket() async {
    _stopHeartbeat();
    await _channelSubscription?.cancel();
    _channelSubscription = null;
    if (_channel != null) {
      try {
        await _channel!.sink.close(ws_status.goingAway).timeout(
          const Duration(milliseconds: 500),
          onTimeout: () {},
        );
      } catch (e) {
        debugPrint('[DshService] Socket teardown notice: $e');
      }
      _channel = null;
    }
  }

  // Automatic Reconnection Loop with Exponential Backoff & Jitter (F3.1)
  void _scheduleReconnect({bool immediate = false}) {
    if (_isExplicitlyDisconnected || _isDisposed || _isTokenInvalid || _currentConfig == null) {
      return;
    }
    if (_isReconnecting || (_reconnectTimer != null && _reconnectTimer!.isActive)) {
      return;
    }

    _reconnectTimer?.cancel();

    if (immediate) {
      _reconnectAttempts = 0;
      _executeReconnect();
      return;
    }

    final int delayMs;
    if (_reconnectAttempts == 0) {
      // First retry: fast turnaround (1000-1300ms) to guarantee <= 5s reconnection
      delayMs = _baseReconnectDelayMs + (DateTime.now().millisecondsSinceEpoch % 300);
    } else {
      final double calculated = (_baseReconnectDelayMs * math.pow(_backoffMultiplier, math.min(_reconnectAttempts, 6))).toDouble();
      final int capped = math.min(calculated.toInt(), _maxReconnectDelayMs);
      final int jitter = (DateTime.now().millisecondsSinceEpoch % _maxJitterMs);
      delayMs = capped + jitter;
    }

    _reconnectAttempts++;
    debugPrint('[DshService] Scheduling reconnect attempt #$_reconnectAttempts in ${delayMs}ms');

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _executeReconnect();
    });
  }

  Future<void> _executeReconnect() async {
    if (_isExplicitlyDisconnected || _isDisposed || _isTokenInvalid || _currentConfig == null) {
      return;
    }
    if (_isReconnecting) return;

    _isReconnecting = true;
    _status = ConnectionStatus.connecting;
    notifyListeners();

    try {
      await _cleanTeardownSocket();

      final uri = Uri.parse(_currentConfig!.wsUrl);
      _channel = WebSocketChannel.connect(uri);

      _channelSubscription = _channel!.stream.listen(
        (data) {
          if (_status != ConnectionStatus.connected) {
            _status = ConnectionStatus.connected;
            _reconnectAttempts = 0;
            _isReconnecting = false;
            _onReconnected();
            notifyListeners();
          }
          _handleRawMessage(data);
        },
        onError: (error) {
          debugPrint('[DshService] Reconnect socket error: $error');
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
          debugPrint('[DshService] Reconnect socket onDone closed');
          final code = _channel?.closeCode;
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
      _sendWsJson({'type': 'ping'});
    } catch (e) {
      debugPrint('[DshService] _executeReconnect failed: $e');
      _status = ConnectionStatus.error;
      _lastError = e.toString();
      _isReconnecting = false;
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void _onReconnected() {
    debugPrint('[DshService] Reconnected successfully. Re-syncing session & state...');
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
    if (_lastResumeCheck != null && now.difference(_lastResumeCheck!).inMilliseconds < 500) {
      return; // Debounce
    }
    _lastResumeCheck = now;
    debugPrint('[DshService] App resumed to foreground');

    if (_status != ConnectionStatus.connected || _channel == null) {
      debugPrint('[DshService] Resumed while disconnected/error: triggering immediate reconnect');
      _scheduleReconnect(immediate: true);
    } else {
      debugPrint('[DshService] Resumed while connected: checking socket liveness');
      try {
        _channel?.sink.add('ping');
      } catch (_) {
        _scheduleReconnect(immediate: true);
        return;
      }
      fetchApprovals();
      fetchWorkspaces();
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
    _channelSubscription?.cancel();
    _channelSubscription = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _isReconnecting = false;
    _sessionPollTimer?.cancel();
    _sessionPollTimer = null;
    _stopHeartbeat();
    _channel?.sink.close(ws_status.goingAway);
    _channel = null;
    _status = ConnectionStatus.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    disconnect();
    super.dispose();
  }
}
