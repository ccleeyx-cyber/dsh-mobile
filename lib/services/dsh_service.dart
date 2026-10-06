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
  DateTime? _lastResumeCheck;

  static const int _baseReconnectDelayMs = 1000;
  static const int _maxReconnectDelayMs = 12000;
  static const double _backoffMultiplier = 1.5;
  static const int _maxJitterMs = 400;

  // State
  List<Workspace> _workspaces = [];
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

  // Getters
  ConnectionStatus get status => _status;
  String get lastError => _lastError;
  void clearError() { _lastError = ''; notifyListeners(); }
  String get currentModel => _currentSessionModel ?? _settings?.currentModel ?? 'cn:deepseek-v4.1-flash';
  bool get isConnected => _status == ConnectionStatus.connected;
  ServerConfig? get currentConfig => _currentConfig;

  List<Workspace> get workspaces => _workspaces;
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

  /// 手动触发网络重连 (F3.4)
  Future<void> retryConnection() async {
    if (_currentConfig == null) return;
    _lastError = '';
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
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;

    _status = ConnectionStatus.connecting;
    notifyListeners();

    try {
      await _cleanTeardownSocket();

      final uri = Uri.parse(config.wsUrl);
      _channel = WebSocketChannel.connect(uri);

      _channel!.stream.listen(
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
          _status = ConnectionStatus.error;
          _lastError = error.toString();
          _isReconnecting = false;
          _stopHeartbeat();
          notifyListeners();
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint('[DshService] WebSocket onDone closed');
          _status = ConnectionStatus.disconnected;
          _isReconnecting = false;
          _stopHeartbeat();
          notifyListeners();
          _scheduleReconnect();
        },
      );

      _startHeartbeat();

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
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/workspaces');
      final res = await http.get(url, headers: _authHeaders).timeout(const Duration(seconds: 8));

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final list = data['workspaces'] as List<dynamic>? ?? [];
        _workspaces = list.map((w) => Workspace.fromJson(w as Map<String, dynamic>)).toList();

        if (_currentWorkspace != null) {
          final matched = _workspaces.firstWhere(
            (w) => w.workspaceId == _currentWorkspace!.workspaceId,
            orElse: () => _workspaces.first,
          );
          _currentWorkspace = matched;
          // Preserve unsaved/active new session in the workspace session list
          if (_currentSession != null && !_currentWorkspace!.sessions.any((s) => s.matchesSessionId(_currentSession!.sessionId))) {
            _currentWorkspace!.sessions.insert(0, _currentSession!);
          }
        } else if (_workspaces.isNotEmpty) {
          _currentWorkspace = _workspaces.first;
          if (_currentWorkspace!.sessions.isNotEmpty && _currentSession == null) {
            await selectSession(_currentWorkspace!.sessions.first);
          }
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DshService] fetchWorkspaces error: $e');
    }
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

  void _sendWsJson(Map<String, dynamic> data) {
    if (_status == ConnectionStatus.connected && _channel != null) {
      try {
        _channel?.sink.add(jsonEncode(data));
      } catch (e) {
        debugPrint('[DshService] _sendWsJson error: $e');
      }
    }
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
    _isSending = false; // Reset sending state immediately
    _isLoadingHistory = true;
    _lastError = '';
    notifyListeners();

    // Notify server to follow this session for real-time streaming
    _sendWsJson({'type': 'follow', 'sessionId': session.sessionId});

    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/${session.sessionId}');
      final res = await http.get(url, headers: _authHeaders).timeout(const Duration(seconds: 8));

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
              input: t['input'] ?? '',
              output: t['output'] ?? '',
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

  // Send Prompt
  Future<void> sendChatMessage(String text) async {
    if (text.trim().isEmpty) return;

    final sessionId = _currentSession?.sessionId ?? 'default';

    // 1. Add user message to UI immediately
    final userMsg = ChatMessage(
      id: _uuid.v4(),
      role: 'user',
      content: text,
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

      if (res != null && res.statusCode == 200) {
        // 3. Start fallback session polling
        _startSessionPolling(sessionId);
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
        notifyListeners();
      }
    } catch (e) {
      if (_isCanceling || turnId <= _cancelledTurnSeq) return;
      debugPrint('[DshService] sendPrompt error: $e');
      _lastError = '发送指令异常: $e';
      assistantMsg.content = '❌ 发送指令失败: $e';
      assistantMsg.isStreaming = false;
      _isSending = false;
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
      if (ticks > maxTicks || _currentSession == null || !_currentSession!.matchesSessionId(sessionId)) {
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
          input: t['input'] ?? '',
          output: t['output'] ?? '',
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
        if (localMsg.timestamp != null && DateTime.now().difference(localMsg.timestamp!).inSeconds < 45) {
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
        await http.post(
          sessionUrl,
          headers: _authHeaders,
          body: jsonEncode({
            'sessionId': targetSessionId,
            'model': modelId,
          }),
        ).timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint('[DshService] session model switch non-critical: $e');
      }
    }

    // 2. Also persist to global settings
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/settings/model');
      await http.post(
        url,
        headers: _authHeaders,
        body: jsonEncode({'model': modelId}),
      ).timeout(const Duration(seconds: 5));
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
        if (_isCanceling || _activeTurnSeq <= _cancelledTurnSeq) return;

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
        if (_isCanceling || _activeTurnSeq <= _cancelledTurnSeq) return;

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
        final toolInput = json['input'] ?? json['args']?.toString() ?? '';
        _messages.last.tools.add(ToolExecution(name: toolName, input: toolInput, isRunning: true));
        _messages.last.isStreaming = true;
        _isSending = true;
        _streamRevision++;
        notifyListeners();
        return;
      }

      if (type == 'tool_result' || type == 'tool_end') {
        final sId = json['sessionId']?.toString();
        if (sId == null || _currentSession == null || !_currentSession!.matchesSessionId(sId)) {
          return;
        }
        if (_messages.isNotEmpty && _messages.last.isAssistant && _messages.last.tools.isNotEmpty) {
          final lastTool = _messages.last.tools.last;
          lastTool.isRunning = false;
          lastTool.output = json['output']?.toString() ?? json['result']?.toString() ?? '完成';
          _streamRevision++;
          notifyListeners();
        }
        return;
      }

      // 7. Completion
      if (type == 'done' || type == 'end') {
        final sId = json['sessionId']?.toString();
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
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) {
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
    if (_isExplicitlyDisconnected || _isDisposed || _currentConfig == null) {
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
    if (_isExplicitlyDisconnected || _isDisposed || _currentConfig == null) {
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

      _channel!.stream.listen(
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
          _status = ConnectionStatus.error;
          _lastError = error.toString();
          _isReconnecting = false;
          _stopHeartbeat();
          notifyListeners();
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint('[DshService] Reconnect socket onDone closed');
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
  }

  void disconnect() {
    _isExplicitlyDisconnected = true;
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
