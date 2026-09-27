class ToolExecution {
  final String name;
  final String input;
  String output;
  bool isRunning;

  ToolExecution({
    required this.name,
    required this.input,
    this.output = '',
    this.isRunning = true,
  });
}

class ChatMessage {
  final String id;
  final String role; // 'user' or 'assistant' or 'system'
  String content;
  String? thinking; // 深度思考/思维链内容
  List<ToolExecution> tools;
  bool isStreaming;
  final DateTime timestamp;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.thinking,
    List<ToolExecution>? tools,
    this.isStreaming = false,
    DateTime? timestamp,
  })  : tools = tools ?? [],
        timestamp = timestamp ?? DateTime.now();

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isSystem => role == 'system';
}
