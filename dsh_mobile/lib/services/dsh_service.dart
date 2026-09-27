import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import '../models/server_config.dart';

enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

class DshService extends ChangeNotifier {
  WebSocketChannel? _channel;
  Timer? _heartbeatTimer;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  String _lastError = '';
  ServerConfig? _currentConfig;

  ConnectionStatus get status => _status;
  String get lastError => _lastError;
  bool get isConnected => _status == ConnectionStatus.connected;

  // 消息流控制器
  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  // 测试与服务端的 HTTP 连通性和鉴权
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

  // 建立 WebSocket 连接
  Future<void> connect(ServerConfig config) async {
    _currentConfig = config;
    _status = ConnectionStatus.connecting;
    notifyListeners();

    try {
      final uri = Uri.parse(config.wsUrl);
      _channel = WebSocketChannel.connect(uri);

      // 等待并监听流
      _channel!.stream.listen(
        (data) {
          _status = ConnectionStatus.connected;
          notifyListeners();
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
    } catch (e) {
      _status = ConnectionStatus.error;
      _lastError = e.toString();
      notifyListeners();
    }
  }

  // 发送消息
  void sendPrompt(String text, {String sessionId = 'default'}) {
    if (_channel == null || _status != ConnectionStatus.connected) return;

    final payload = {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'type': 'chat',
      'method': 'session/send',
      'params': {
        'sessionId': sessionId,
        'content': text,
        'message': text,
      }
    };

    _channel!.sink.add(jsonEncode(payload));
  }

  // 发送原始数据
  void sendRaw(String data) {
    if (_channel != null && _status == ConnectionStatus.connected) {
      _channel!.sink.add(data);
    }
  }

  void _handleRawMessage(dynamic data) {
    if (data is String) {
      if (data == 'pong') return; // 心跳回复
      try {
        final json = jsonDecode(data);
        if (json is Map<String, dynamic>) {
          _messageController.add(json);
        }
      } catch (e) {
        debugPrint('[DshService] JSON parse error: $e');
      }
    }
  }

  // 心跳维持保活
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

  // 断开连接
  void disconnect() {
    _stopHeartbeat();
    _channel?.sink.close(ws_status.goingAway);
    _channel = null;
    _status = ConnectionStatus.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopHeartbeat();
    _channel?.sink.close();
    _messageController.close();
    super.dispose();
  }
}
