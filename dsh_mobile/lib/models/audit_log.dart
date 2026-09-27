class AuditLogItem {
  final String id;
  final int time;
  final String sessionId;
  final String toolName;
  final String command;
  final String outcome; // 'allowed-once' | 'rejected' | 'auto-approved' | 'pending'
  final String? reason;

  AuditLogItem({
    required this.id,
    required this.time,
    required this.sessionId,
    required this.toolName,
    required this.command,
    required this.outcome,
    this.reason,
  });

  factory AuditLogItem.fromJson(Map<String, dynamic> json) {
    return AuditLogItem(
      id: json['id'] ?? '',
      time: json['time'] is int ? json['time'] : DateTime.now().millisecondsSinceEpoch,
      sessionId: json['sessionId'] ?? 'default',
      toolName: json['toolName'] ?? 'tool',
      command: json['command'] ?? '',
      outcome: json['outcome'] ?? 'pending',
      reason: json['reason'],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'time': time,
        'sessionId': sessionId,
        'toolName': toolName,
        'command': command,
        'outcome': outcome,
        'reason': reason,
      };
}
