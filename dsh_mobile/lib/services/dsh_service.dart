import 'dart:async';
import 'dart:convert';
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

  // Getters
  ConnectionStatus get status => _status;
  String get lastError => _lastError;
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

  // Headers for HTTP
  Map<String, String> get _authHeaders => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_currentConfig?.token ?? ''}',
        'x-dsh-token': _currentConfig?.token ?? '',
      };

  // Test Connection
  Future<bool> testConnection(ServerConfig config) async {
    try {
      final url = Uri.parse('${config.httpBaseUrl}/health');
      final res = await http.get(url, headers: {
        'Authorization': 'Bearer ${config.token}',
        'x-dsh-token': config.token,
      }).timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return data['authenticated'] == true;
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
    _status = ConnectionStatus.connecting;
    notifyListeners();

    try {
      final uri = Uri.parse(config.wsUrl);
      _channel = WebSocketChannel.connect(uri);

      _channel!.stream.listen(
        (data) {
          if (_status != ConnectionStatus.connected) {
            _status = ConnectionStatus.connected;
            notifyListeners();
          }
          _handleRawMessage(data);
        },
        onError: (error) {
          _status = ConnectionStatus.error;
          _lastError = error.toString();
          _stopHeartbeat();
          notifyListeners();
        },
        onDone: () {
          _status = ConnectionStatus.disconnected;
          _stopHeartbeat();
          notifyListeners();
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
      notifyListeners();
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

        // Default to first workspace if not set
        if (_currentWorkspace == null && _workspaces.isNotEmpty) {
          _currentWorkspace = _workspaces.first;
          if (_currentWorkspace!.sessions.isNotEmpty) {
            await selectSession(_currentWorkspace!.sessions.first);
          }
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[DshService] fetchWorkspaces error: $e');
    }
  }

  void selectWorkspace(Workspace ws) {
    _currentWorkspace = ws;
    if (ws.sessions.isNotEmpty) {
      selectSession(ws.sessions.first);
    } else {
      _currentSession = null;
      _messages = [
        ChatMessage(
          id: _uuid.v4(),
          role: 'assistant',
          content: '当前工作区 [${ws.title}] 暂无会话。点击上方“新建对话”开始！',
        )
      ];
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
    _currentSession = session;
    _isLoadingHistory = true;
    _sessionPollTimer?.cancel();
    _sessionPollTimer = null;
    notifyListeners();

    // Notify server to follow this session for real-time streaming
    _sendWsJson({'type': 'follow', 'sessionId': session.sessionId});

    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/${session.sessionId}');
      final res = await http.get(url, headers: _authHeaders).timeout(const Duration(seconds: 8));

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final sessionData = data['data'] as Map<String, dynamic>?;
        final rawMessages = sessionData?['messages'] as List<dynamic>? ?? [];
        final isRunning = sessionData?['isRunning'] == true || session.isRunning;

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

        if (_messages.isEmpty) {
          _messages.add(ChatMessage(
            id: _uuid.v4(),
            role: 'assistant',
            content: '这是会话 [${session.title}]。你可以直接向 DSH 智能体下达指令。',
          ));
        }
      }
    } catch (e) {
      debugPrint('[DshService] selectSession error: $e');
    } finally {
      _isLoadingHistory = false;
      notifyListeners();
    }
  }

  Future<void> createNewSession() async {
    if (_currentWorkspace == null) {
      if (_workspaces.isEmpty) {
        await fetchWorkspaces();
      }
      if (_workspaces.isNotEmpty) {
        _currentWorkspace = _workspaces.first;
      }
    }
    if (_currentConfig == null || _currentWorkspace == null) return;

    _sessionPollTimer?.cancel();
    _sessionPollTimer = null;
    _isLoadingHistory = true;
    _messages = [];
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

      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final newSessionId = data['sessionId']?.toString() ?? data['session']?['sessionId']?.toString();

        if (newSessionId != null && newSessionId.isNotEmpty) {
          final newSessionMeta = SessionMeta(
            sessionId: newSessionId,
            title: '新对话',
            lastPromptAt: DateTime.now().millisecondsSinceEpoch,
          );

          _currentWorkspace!.sessions.insert(0, newSessionMeta);
          _currentSession = newSessionMeta;
          _messages = [
            ChatMessage(
              id: _uuid.v4(),
              role: 'assistant',
              content: '新对话已创建。你可以直接向 DSH 智能体下达指令。',
            )
          ];
          _isLoadingHistory = false;
          notifyListeners();

          _sendWsJson({'type': 'follow', 'sessionId': newSessionId});
          fetchWorkspaces();
          return;
        }
      }
    } catch (e) {
      debugPrint('[DshService] createNewSession error: $e');
    }

    _isLoadingHistory = false;
    notifyListeners();
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

    _isSending = true;
    notifyListeners();

    // Send follow event via WS
    _sendWsJson({'type': 'follow', 'sessionId': sessionId});

    try {
      // Send via HTTP RPC
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/prompt');
      await http.post(
        url,
        headers: _authHeaders,
        body: jsonEncode({
          'sessionId': sessionId,
          'text': text,
        }),
      ).timeout(const Duration(seconds: 15));

      // 3. Start fallback session polling
      _startSessionPolling(sessionId);
    } catch (e) {
      debugPrint('[DshService] sendPrompt error: $e');
      assistantMsg.content = '发送指令失败: $e';
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
      if (ticks > maxTicks) {
        timer.cancel();
        _sessionPollTimer = null;
        _isSending = false;
        if (_messages.isNotEmpty && _messages.last.isStreaming) {
          _messages.last.isStreaming = false;
        }
        notifyListeners();
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

        if (res.statusCode == 200) {
          final data = jsonDecode(utf8.decode(res.bodyBytes));
          final sessionData = data['data'] as Map<String, dynamic>?;
          if (sessionData == null) return;

          final bool isRunning = sessionData['isRunning'] == true;
          final rawMessages = sessionData['messages'] as List<dynamic>? ?? [];

          if (rawMessages.isNotEmpty && _currentSession != null && _currentSession!.matchesSessionId(sessionId)) {
            final parsedMessages = rawMessages.map((m) {
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

            final isActivelyWsStreaming = _status == ConnectionStatus.connected && _messages.isNotEmpty && _messages.last.isStreaming;
            if (!isActivelyWsStreaming || !isRunning) {
              if (isRunning && parsedMessages.isNotEmpty && parsedMessages.last.isAssistant) {
                parsedMessages.last.isStreaming = true;
              }

              // Preserve locally added user messages if server hasn't committed them yet
              final serverUserTexts = parsedMessages.where((m) => m.isUser).map((m) => m.content).toSet();
              for (final localMsg in _messages.where((m) => m.isUser)) {
                if (localMsg.content.isNotEmpty && !serverUserTexts.contains(localMsg.content)) {
                  if (localMsg.timestamp == null || DateTime.now().difference(localMsg.timestamp!).inSeconds < 30) {
                    parsedMessages.add(localMsg);
                  }
                }
              }

              _messages = parsedMessages;
              notifyListeners();
            }
          }

          if (!isRunning) {
            timer.cancel();
            _sessionPollTimer = null;
            _isSending = false;
            if (_messages.isNotEmpty && _messages.last.isStreaming) {
              _messages.last.isStreaming = false;
            }
            fetchWorkspaces();
            notifyListeners();
          }
        }
      } catch (e) {
        debugPrint('[DshService] session poll tick error: $e');
      }
    });
  }

  // Cancel Turn
  Future<void> cancelActiveTurn() async {
    _sessionPollTimer?.cancel();
    _sessionPollTimer = null;
    _isSending = false;
    if (_currentSession == null || _currentConfig == null) return;
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/sessions/cancel');
      await http.post(
        url,
        headers: _authHeaders,
        body: jsonEncode({
          'sessionId': _currentSession!.sessionId,
        }),
      );

      if (_messages.isNotEmpty && _messages.last.isStreaming) {
        _messages.last.isStreaming = false;
        _messages.last.content += '\n*(任务已被手动停止)*';
        notifyListeners();
      }
      fetchWorkspaces();
    } catch (e) {
      debugPrint('[DshService] cancelTurn error: $e');
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
        if (data['settings'] != null) {
          _settings = DshSettings.fromJson(data['settings']);
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('[DshService] fetchSettings error: $e');
    }
  }

  Future<bool> switchModel(String modelId) async {
    if (_currentConfig == null) return false;
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/settings/model');
      final res = await http.post(
        url,
        headers: _authHeaders,
        body: jsonEncode({'model': modelId}),
      ).timeout(const Duration(seconds: 6));

      if (res.statusCode == 200) {
        await fetchSettings();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[DshService] switchModel error: $e');
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

  Future<void> respondApproval(ApprovalRequest req, String outcome) async {
    if (_currentConfig == null) return;
    try {
      final url = Uri.parse('${_currentConfig!.httpBaseUrl}/api/mobile/approval');
      final res = await http.post(
        url,
        headers: _authHeaders,
        body: jsonEncode({
          'eventId': req.eventId,
          'outcome': outcome, // 'allowed-once' or 'rejected'
        }),
      ).timeout(const Duration(seconds: 8));

      if (res.statusCode == 200) {
        _pendingApprovals.removeWhere((a) => a.eventId == req.eventId);
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
      }
      return false;
    } catch (e) {
      debugPrint('[DshService] updatePermissions error: $e');
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
        final list = data['auditLogs'] as List<dynamic>? ?? [];
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
        _pendingApprovals.removeWhere((a) => a.eventId == eventId);
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
          _isSending = isRunning;
          if (!isRunning && _messages.isNotEmpty && _messages.last.isAssistant) {
            _messages.last.isStreaming = false;
          }
          changed = true;
        }
        if (changed) {
          notifyListeners();
        }
        return;
      }

      // 5. Streaming tokens and chat chunks (thinking / delta / token)
      if (type == 'thinking' || type == 'delta' || type == 'token' || json.containsKey('delta') || json.containsKey('thinking')) {
        final sId = json['sessionId']?.toString();
        if (sId != null && _currentSession != null && !_currentSession!.matchesSessionId(sId)) {
          return;
        }

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
          notifyListeners();
        } else {
          final text = json['delta'] ?? json['content'] ?? json['text'] ?? '';
          current.content += text.toString();
          notifyListeners();
        }
        return;
      }

      // 6. Tool Executions
      if (type == 'tool_start' || type == 'tool_call') {
        final sId = json['sessionId']?.toString();
        if (sId != null && _currentSession != null && !_currentSession!.matchesSessionId(sId)) {
          return;
        }
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
        notifyListeners();
        return;
      }

      if (type == 'tool_result' || type == 'tool_end') {
        final sId = json['sessionId']?.toString();
        if (sId != null && _currentSession != null && !_currentSession!.matchesSessionId(sId)) {
          return;
        }
        if (_messages.isNotEmpty && _messages.last.isAssistant && _messages.last.tools.isNotEmpty) {
          final lastTool = _messages.last.tools.last;
          lastTool.isRunning = false;
          lastTool.output = json['output']?.toString() ?? json['result']?.toString() ?? '完成';
          notifyListeners();
        }
        return;
      }

      // 7. Completion
      if (type == 'done' || type == 'end') {
        final sId = json['sessionId']?.toString();
        if (sId != null && _currentSession != null && !_currentSession!.matchesSessionId(sId)) {
          return;
        }
        if (_messages.isNotEmpty && _messages.last.isAssistant) {
          final current = _messages.last;
          current.isStreaming = false;
          for (var t in current.tools) {
            t.isRunning = false;
          }
        }
        _isSending = false;
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

  void disconnect() {
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
    disconnect();
    super.dispose();
  }
}
