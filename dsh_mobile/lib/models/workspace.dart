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

/// 目录选择器的一个**起点**（`GET /api/mobile/workspaces/roots`）。
///
/// [kind] 是来源，客户端据此分组显示与排序：`parent`（已登记工作区的上级）、
/// `home`（主目录）、`workspace`（已登记工作区本身）、`drive`（盘符根）。
/// 网关只开放这几类位置 —— 客户端拿不到"任意路径"的能力。
class WorkspaceRoot {
  final String path;
  final String label;
  final String kind;

  const WorkspaceRoot({required this.path, required this.label, required this.kind});

  factory WorkspaceRoot.fromJson(Map<String, dynamic> json) => WorkspaceRoot(
        path: json['path']?.toString() ?? '',
        label: json['label']?.toString() ?? json['path']?.toString() ?? '',
        kind: json['kind']?.toString() ?? '',
      );
}

/// 目录选择器里的一行子目录。
class WorkspaceDirEntry {
  final String name;
  final String path;

  const WorkspaceDirEntry({required this.name, required this.path});

  factory WorkspaceDirEntry.fromJson(Map<String, dynamic> json) {
    final p = json['path']?.toString() ?? '';
    return WorkspaceDirEntry(
      name: json['name']?.toString() ?? p,
      path: p,
    );
  }
}

/// 目录选择器的一层列表（`GET /api/mobile/workspaces/browse?path=`）。
///
/// 只有**子目录**（网关侧就不回文件）：选一个目录当工作区用不到文件名。
class WorkspaceDirListing {
  final bool ok;
  final String error;

  /// 服务端绝对路径。null 表示"这次只问了起点，没要列表"。
  final String? path;

  /// 上一级；已到根（或上一级不在可浏览范围内）时为 null。
  final String? parent;

  /// 当前目录名（面包屑尾段）。
  final String name;

  final List<WorkspaceRoot> roots;

  /// 子目录（只有目录：网关侧就不回文件）。
  final List<WorkspaceDirEntry> entries;

  final bool truncated;

  /// 这个目录**已经是**一个登记过的工作区时给出它的 id/标题，否则 null。
  final String? registeredWorkspaceId;
  final String? registeredTitle;

  const WorkspaceDirListing({
    required this.ok,
    this.error = '',
    this.path,
    this.parent,
    this.name = '',
    this.roots = const [],
    this.entries = const [],
    this.truncated = false,
    this.registeredWorkspaceId,
    this.registeredTitle,
  });

  /// 老网关没有这两个接口 → 404/失败时 [ok] 为 false，调用方退回手动输入。
  bool get hasListing => ok && path != null;

  factory WorkspaceDirListing.fromJson(Map<String, dynamic> json) {
    final rawRoots = json['roots'] as List<dynamic>? ?? [];
    final rawEntries = json['entries'] as List<dynamic>? ?? [];
    final registered = json['registered'];
    return WorkspaceDirListing(
      ok: json['ok'] == true || json['ok'] == 'true',
      error: json['error']?.toString() ?? '',
      path: json['path']?.toString(),
      parent: json['parent']?.toString(),
      name: json['name']?.toString() ?? '',
      roots: rawRoots
          .whereType<Map>()
          .map((r) => WorkspaceRoot.fromJson(Map<String, dynamic>.from(r)))
          .toList(),
      entries: rawEntries
          .whereType<Map>()
          .map((e) => WorkspaceDirEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      truncated: json['truncated'] == true,
      registeredWorkspaceId:
          registered is Map ? registered['workspaceId']?.toString() : null,
      registeredTitle: registered is Map ? registered['title']?.toString() : null,
    );
  }
}
