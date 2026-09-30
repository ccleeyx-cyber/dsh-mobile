class ApprovalRequest {
  final String id;
  final String eventId;
  final String? clientId;
  final String sessionId;
  final String toolName;
  final String reason;
  final String? callId;
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
    this.options,
    required this.createdAt,
  });

  factory ApprovalRequest.fromJson(Map<String, dynamic> json) {
    return ApprovalRequest(
      id: json['id'] ?? json['eventId'] ?? '',
      eventId: json['eventId'] ?? json['id'] ?? '',
      clientId: json['clientId'],
      sessionId: json['sessionId'] ?? json['agent'] ?? 'default',
      toolName: json['toolName'] ?? json['tool'] ?? '工具执行',
      reason: json['reason'] ?? '申请工具执行权限',
      callId: json['callId'],
      options: json['options'],
      createdAt: json['createdAt'] is int ? json['createdAt'] : DateTime.now().millisecondsSinceEpoch,
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
    'options': options,
    'createdAt': createdAt,
  };
}
