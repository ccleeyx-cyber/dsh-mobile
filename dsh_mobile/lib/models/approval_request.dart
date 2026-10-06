class ApprovalRequest {
  final String id;
  final String eventId;
  final String? clientId;
  final String sessionId;
  final String toolName;
  final String reason;
  final String? callId;
  final String? command;
  final dynamic input;
  final List<dynamic>? options;
  final int createdAt;

  ApprovalRequest({
    required this.id,
    required this.eventId,
    this.clientId,
    required this.sessionId,
    required this.toolName,
    required this.reason,
    this.callId,
    this.command,
    this.input,
    this.options,
    required this.createdAt,
  });

  factory ApprovalRequest.fromJson(Map<String, dynamic> json) {
    final rawInput = json['input'] ?? json['params'] ?? json['args'] ?? json['arguments'] ?? json['request'];

    // Extract command from direct property, input payload, or cmd aliases
    String? command = json['command']?.toString() ?? json['cmd']?.toString();
    if (command == null && rawInput is Map) {
      command = rawInput['command']?.toString() ?? rawInput['cmd']?.toString();
    }
    if (command == null && rawInput is String && rawInput.trim().isNotEmpty) {
      command = rawInput.trim();
    }

    return ApprovalRequest(
      id: json['id']?.toString() ?? json['eventId']?.toString() ?? json['approvalId']?.toString() ?? '',
      eventId: json['eventId']?.toString() ?? json['id']?.toString() ?? json['approvalId']?.toString() ?? '',
      clientId: json['clientId']?.toString(),
      sessionId: json['sessionId']?.toString() ?? json['agent']?.toString() ?? 'default',
      toolName: json['toolName']?.toString() ?? json['action']?.toString() ?? json['tool']?.toString() ?? '工具执行',
      reason: json['reason']?.toString() ?? (command != null ? '申请执行: $command' : '申请工具执行权限'),
      callId: json['callId']?.toString() ?? json['toolCallId']?.toString(),
      command: command,
      input: rawInput,
      options: json['options'] is List ? json['options'] as List<dynamic> : null,
      createdAt: json['createdAt'] is int ? json['createdAt'] as int : DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'eventId': eventId,
    'clientId': clientId,
    'sessionId': sessionId,
    'toolName': toolName,
    'reason': reason,
    'callId': callId,
    'command': command,
    'input': input,
    'options': options,
    'createdAt': createdAt,
  };
}
