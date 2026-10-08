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
    int parseTime(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? DateTime.now().millisecondsSinceEpoch;
      return DateTime.now().millisecondsSinceEpoch;
    }

    return AuditLogItem(
      id: json['id']?.toString() ?? '',
      time: parseTime(json['time']),
      sessionId: json['sessionId']?.toString() ?? 'default',
      toolName: json['toolName']?.toString() ?? 'tool',
      command: json['command']?.toString() ?? '',
      outcome: json['outcome']?.toString() ?? 'pending',
      reason: json['reason']?.toString(),
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
