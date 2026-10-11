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
  bool isStreaming;
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
    this.isStreaming = false,
    DateTime? timestamp,
    this.isMemory = false,
    this.isContext = false,
    this.seq,
  })  : tools = tools ?? [],
        timestamp = timestamp ?? DateTime.now();

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isSystem => role == 'system';
  bool get isContextRole => role == 'context';
  bool get isMemoryRole => role == 'memory';

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
