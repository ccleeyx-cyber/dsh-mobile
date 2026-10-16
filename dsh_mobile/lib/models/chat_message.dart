import 'dart:convert';

class ToolExecution {
  final String name;
  final String input;
  String output;
  bool isRunning;

  ToolExecution({
    required this.name,
    dynamic input = '',
    dynamic output = '',
    this.isRunning = true,
  })  : input = _safeFormat(input),
        output = _safeFormat(output);

  static String _safeFormat(dynamic val) {
    if (val == null) return '';
    if (val is String) return val;
    if (val is Map || val is List) {
      try {
        return const JsonEncoder.withIndent('  ').convert(val);
      } catch (_) {
        return val.toString();
      }
    }
    return val.toString();
  }
}

class ChatMessage {
  final String id;
  final String role; // 'user', 'assistant', 'system', 'memory', 'context'
  String content;
  String? thinking; // 深度思考/思维链内容
  List<ToolExecution> tools;
  bool get isStreaming => _isStreaming;

  /// 写入时先 flush 累积槽。
  ///
  /// 流式增量先进 buffer（见 [appendStreamDelta]），靠这个 setter 保证
  /// 「streaming 结束」的所有路径 —— done / error / 取消 / 轮询超时兜底 /
  /// reconcile / stream_snapshot replay —— 都会把最后一段增量写回成品字段。
  /// 少了这一步，取消或弱网兜底时最后 100ms 内的内容会凭空消失。
  set isStreaming(bool value) {
    if (_isStreaming == value) return;
    _isStreaming = value;
    if (!value) flushStreamBuffers();
  }
  bool _isStreaming = false;
  final DateTime timestamp;
  final bool isMemory;
  final bool isContext;

  /// [feat 2026-10-12] 引擎事件序号：反向翻页的 beforeSeq 游标 + 与实时流
  /// 去重的身份键。网关从 1.14.x 起在历史消息上带 seq；本地乐观消息和旧网关
  /// 没有时为 null（这类消息不参与翻页与去重，只留在尾部）。
  final int? seq;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.thinking,
    List<ToolExecution>? tools,
    bool isStreaming = false,
    DateTime? timestamp,
    this.isMemory = false,
    this.isContext = false,
    this.seq,
  })  : tools = tools ?? [],
        timestamp = timestamp ?? DateTime.now(),
        _isStreaming = isStreaming;

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isSystem => role == 'system';
  bool get isContextRole => role == 'context';
  bool get isMemoryRole => role == 'memory';

  /// 流式增量累积槽。`content` / `thinking` 是渲染层读的**成品**字段，
  /// 但增量到达时不能直接 `content += text` —— Dart 的 String 不可变，
  /// 每次拼接都整体拷贝一次，一条 20 万字符的回复按 4 字符一片进来就是
  /// O(n²) 次拷贝（实测长回复下流式越来越卡的主因）。
  ///
  /// 所以 delta 一律进 buffer，只在 flush 边界写回成品字段。非流式消息
  /// 永远不碰这两个 buffer。
  final StringBuffer _contentBuffer = StringBuffer();
  final StringBuffer _thinkingBuffer = StringBuffer();
  bool _buffering = false;

  /// 追加一段增量。调用方负责在合适的时机调 [flushStreamBuffers]。
  void appendStreamDelta({String? content, String? thinking}) {
    if (content != null && content.isNotEmpty) {
      _contentBuffer.write(content);
      _buffering = true;
    }
    if (thinking != null && thinking.isNotEmpty) {
      _thinkingBuffer.write(thinking);
      _buffering = true;
    }
  }

  /// 把累积槽写回 `content` / `thinking`。幂等：没有未 flush 的增量时是 no-op。
  void flushStreamBuffers() {
    if (!_buffering) return;
    if (_contentBuffer.isNotEmpty) {
      content += _contentBuffer.toString();
      _contentBuffer.clear();
    }
    if (_thinkingBuffer.isNotEmpty) {
      thinking = (thinking ?? '') + _thinkingBuffer.toString();
      _thinkingBuffer.clear();
    }
    _buffering = false;
  }

  /// Returns true if the message is a carried context, workspace document, runtime instructions, or memory snapshot
  bool get isContextOrMemory {
    if (isMemory || isContext || role == 'memory' || role == 'context' || role == 'system') {
      return true;
    }
    final trimmed = content.trim();
    if (trimmed.startsWith('MNEMON RUNTIME MEMORY SNAPSHOT') ||
        trimmed.startsWith('[MNEMON]') ||
        trimmed.contains('<runtime-memory-file') ||
        trimmed.contains('<system-reminder>') ||
        trimmed.startsWith('Current runtime context.') ||
        trimmed.contains('DSH file policy:') ||
        trimmed.contains('Instructions from:') ||
        trimmed.contains('<available_skills>') ||
        trimmed.contains('A skill is a reusable set') ||
        (trimmed.contains('Contents of ') && (trimmed.contains('.md') || trimmed.contains('<runtime-memory-file'))) ||
        RegExp(r'<(workspace|project|environment|file)_context>', caseSensitive: false).hasMatch(trimmed)) {
      return true;
    }
    return false;
  }

  bool get isMemoryRecall => isContextOrMemory;
}
