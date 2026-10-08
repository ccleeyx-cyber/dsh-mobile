class SessionMeta {
  final String sessionId;
  final String title;
  final String firstPrompt;
  final int lastPromptAt;
  final String model;
  final int lastSeq;
  final bool isRunning;
  final int pendingApprovals;

  /// 该会话是否在引擎的 `global.archivedSessionIds` 名单里。
  ///
  /// 网关在所有模式下都会带上这个字段，所以 `include` 的响应是自描述的。
  /// 旧网关不返回它 → 回落 false，但那只会发生在 `exclude` 模式下
  /// （见 [DshService.archivedFilterSupported] 的能力探测），语义仍然正确。
  final bool archived;

  SessionMeta({
    required this.sessionId,
    required this.title,
    this.firstPrompt = '',
    this.lastPromptAt = 0,
    this.model = '',
    this.lastSeq = 0,
    this.isRunning = false,
    this.pendingApprovals = 0,
    this.archived = false,
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
    int? pendingApprovals,
    bool? archived,
  }) {
    return SessionMeta(
      sessionId: sessionId ?? this.sessionId,
      title: title ?? this.title,
      firstPrompt: firstPrompt ?? this.firstPrompt,
      lastPromptAt: lastPromptAt ?? this.lastPromptAt,
      model: model ?? this.model,
      lastSeq: lastSeq ?? this.lastSeq,
      isRunning: isRunning ?? this.isRunning,
      pendingApprovals: pendingApprovals ?? this.pendingApprovals,
      archived: archived ?? this.archived,
    );
  }

  static int _parseInt(dynamic v, [int defaultValue = 0]) {
    if (v == null) return defaultValue;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? defaultValue;
    return defaultValue;
  }

  factory SessionMeta.fromJson(Map<String, dynamic> json) {
    return SessionMeta(
      sessionId: json['sessionId']?.toString() ?? '',
      title: json['title']?.toString() ?? json['sessionId']?.toString() ?? '未命名对话',
      firstPrompt: json['firstPrompt']?.toString() ?? '',
      lastPromptAt: _parseInt(json['lastPromptAt']),
      model: json['model']?.toString() ?? '',
      lastSeq: _parseInt(json['lastSeq']),
      isRunning: json['isRunning'] == true || json['isRunning'] == 'true',
      pendingApprovals: _parseInt(json['pendingApprovals']),
      archived: json['archived'] == true || json['archived'] == 'true',
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
        'pendingApprovals': pendingApprovals,
        'archived': archived,
      };
}

class Workspace {
  final String workspaceId;
  final String title;
  final String path;
  final String createdAt;
  final String updatedAt;
  final int sessionCount;
  final int pendingApprovals;
  final bool hasRunning;

  /// 本工作区在引擎归档名单里的会话总数，**与当前筛选模式无关**。
  /// 这样在「未归档」视图下也能直接显示「已归档 N 条」，不必再发一次请求。
  /// 旧网关不返回该字段 → 0。
  final int archivedCount;

  final List<SessionMeta> sessions;

  Workspace({
    required this.workspaceId,
    required this.title,
    required this.path,
    this.createdAt = '',
    this.updatedAt = '',
    this.sessionCount = 0,
    this.pendingApprovals = 0,
    this.hasRunning = false,
    this.archivedCount = 0,
    List<SessionMeta>? sessions,
  }) : sessions = sessions ?? [];

  factory Workspace.fromJson(Map<String, dynamic> json) {
    final rawSessions = json['sessions'] as List<dynamic>? ?? [];
    return Workspace(
      workspaceId: json['workspaceId']?.toString() ?? '',
      title: json['title']?.toString() ?? '默认工作区',
      path: json['path']?.toString() ?? '',
      createdAt: json['createdAt']?.toString() ?? '',
      updatedAt: json['updatedAt']?.toString() ?? '',
      sessionCount: SessionMeta._parseInt(json['sessionCount'], rawSessions.length),
      pendingApprovals: SessionMeta._parseInt(json['pendingApprovals']),
      hasRunning: json['hasRunning'] == true || json['hasRunning'] == 'true',
      archivedCount: SessionMeta._parseInt(json['archivedCount']),
      sessions: rawSessions
          .whereType<Map>()
          .map((s) => SessionMeta.fromJson(Map<String, dynamic>.from(s)))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'workspaceId': workspaceId,
    'title': title,
    'path': path,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'sessionCount': sessionCount,
    'pendingApprovals': pendingApprovals,
    'hasRunning': hasRunning,
    'archivedCount': archivedCount,
    'sessions': sessions.map((s) => s.toJson()).toList(),
  };
}
