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
