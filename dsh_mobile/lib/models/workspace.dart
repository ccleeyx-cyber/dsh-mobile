class SessionMeta {
  final String sessionId;
  final String title;
  final String firstPrompt;
  final int lastPromptAt;
  final String model;
  final int lastSeq;
  final bool isRunning;

  SessionMeta({
    required this.sessionId,
    required this.title,
    this.firstPrompt = '',
    this.lastPromptAt = 0,
    this.model = '',
    this.lastSeq = 0,
    this.isRunning = false,
  });

  bool matchesSessionId(String? otherId) {
    if (otherId == null || otherId.isEmpty) return false;
    final a = sessionId.replaceAll('session-', '').toLowerCase();
    final b = otherId.replaceAll('session-', '').toLowerCase();
    return a == b;
  }

  SessionMeta copyWith({
    String? sessionId,
    String? title,
    String? firstPrompt,
    int? lastPromptAt,
    String? model,
    int? lastSeq,
    bool? isRunning,
  }) {
    return SessionMeta(
      sessionId: sessionId ?? this.sessionId,
      title: title ?? this.title,
      firstPrompt: firstPrompt ?? this.firstPrompt,
      lastPromptAt: lastPromptAt ?? this.lastPromptAt,
      model: model ?? this.model,
      lastSeq: lastSeq ?? this.lastSeq,
      isRunning: isRunning ?? this.isRunning,
    );
  }

  factory SessionMeta.fromJson(Map<String, dynamic> json) {
    return SessionMeta(
      sessionId: json['sessionId'] ?? '',
      title: json['title'] ?? json['sessionId'] ?? '未命名对话',
      firstPrompt: json['firstPrompt'] ?? '',
      lastPromptAt: json['lastPromptAt'] is int ? json['lastPromptAt'] : 0,
      model: json['model'] ?? '',
      lastSeq: json['lastSeq'] is int ? json['lastSeq'] : 0,
      isRunning: json['isRunning'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'title': title,
        'firstPrompt': firstPrompt,
        'lastPromptAt': lastPromptAt,
        'model': model,
        'lastSeq': lastSeq,
        'isRunning': isRunning,
      };
}

class Workspace {
  final String workspaceId;
  final String title;
  final String path;
  final String createdAt;
  final String updatedAt;
  final int sessionCount;
  final List<SessionMeta> sessions;

  Workspace({
    required this.workspaceId,
    required this.title,
    required this.path,
    this.createdAt = '',
    this.updatedAt = '',
    this.sessionCount = 0,
    List<SessionMeta>? sessions,
  }) : sessions = sessions ?? [];

  factory Workspace.fromJson(Map<String, dynamic> json) {
    final rawSessions = json['sessions'] as List<dynamic>? ?? [];
    return Workspace(
      workspaceId: json['workspaceId'] ?? '',
      title: json['title'] ?? '默认工作区',
      path: json['path'] ?? '',
      createdAt: json['createdAt'] ?? '',
      updatedAt: json['updatedAt'] ?? '',
      sessionCount: json['sessionCount'] ?? rawSessions.length,
      sessions: rawSessions.map((s) => SessionMeta.fromJson(s as Map<String, dynamic>)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'workspaceId': workspaceId,
    'title': title,
    'path': path,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'sessionCount': sessionCount,
    'sessions': sessions.map((s) => s.toJson()).toList(),
  };
}
