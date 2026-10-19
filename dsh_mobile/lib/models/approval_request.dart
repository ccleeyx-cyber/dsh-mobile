import 'dart:convert';

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

  /// 通知栏一键批准的一次性令牌（v1.35 / 2.1）。
  ///
  /// null 有两种含义：老网关不下发，或这条审批属于完全访问策略（网关刻意不铸）。
  /// 两者在 UI 上表现一致：不给一键批准按钮，必须回 App 里确认。
  final String? approvalToken;

  /// 网关标记的敏感审批（完全访问策略下）。
  final bool sensitive;

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
    this.approvalToken,
    this.sensitive = false,
  });

  factory ApprovalRequest.fromJson(Map<String, dynamic> json) {
    final rawInput = json['input'] ?? json['params'] ?? json['args'] ?? json['arguments'] ?? json['request'];

    // Extract command from direct property, input payload, or cmd aliases
    String? command = json['command']?.toString() ?? json['cmd']?.toString();
    if (command == null && rawInput is Map) {
      command = rawInput['command']?.toString() ?? rawInput['cmd']?.toString();
    }
    if (command == null && rawInput is String && rawInput.trim().isNotEmpty) {
      final trimmed = rawInput.trim();
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map) {
            command = decoded['command']?.toString() ?? decoded['cmd']?.toString();
          }
        } catch (_) {}
      }
      command ??= trimmed;
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
      // [v1.35 / 2.1] 老网关没有这两个字段：token 为 null 时通知不带动作按钮，
      // 行为与升级前一致（点通知进 App）。
      approvalToken: (json['approvalToken']?.toString().trim().isEmpty ?? true)
          ? null
          : json['approvalToken'].toString().trim(),
      sensitive: json['sensitive'] == true,
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
