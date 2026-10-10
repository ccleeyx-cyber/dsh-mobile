/// Task-center models: queue rows, deliverables, workspace changes, schedules,
/// background jobs, token usage and push configuration (v1.13).
///
/// Every parser here is total: a malformed field falls back to null or an empty
/// value instead of throwing, because a single unexpected shape must never take
/// down the page that renders the other nine good rows. Fields that are
/// genuinely unknown stay null — the UI renders "—" rather than a fake zero,
/// which matters for line counts and token totals.
library;

/// One queued message waiting for the agent (from the session inbox).
class QueueItem {
  final String id;
  final String text;
  final int attachments;

  const QueueItem({required this.id, required this.text, required this.attachments});

  factory QueueItem.fromJson(Map<String, dynamic> json) => QueueItem(
        id: json['id']?.toString() ?? '',
        text: json['text']?.toString() ?? '',
        attachments: _int(json['attachments']) ?? 0,
      );

  /// Label used when the row carries only an attachment.
  String get label => text.trim().isEmpty
      ? (attachments > 0 ? '（$attachments 个附件）' : '（空消息）')
      : text;
}

/// One file the agent declared with `present`.
class DeliverableItem {
  final String path;
  final String display;
  final String description;
  final int? turn;
  final int? seq;

  const DeliverableItem({
    required this.path,
    required this.display,
    required this.description,
    this.turn,
    this.seq,
  });

  factory DeliverableItem.fromJson(Map<String, dynamic> json) => DeliverableItem(
        path: json['path']?.toString() ?? '',
        display: json['display']?.toString() ?? json['path']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        turn: _int(json['turn']),
        seq: _int(json['seq']),
      );

  String get fileName {
    final cleaned = display.replaceAll('\\', '/');
    final i = cleaned.lastIndexOf('/');
    return i >= 0 ? cleaned.substring(i + 1) : cleaned;
  }

  String get extension {
    final name = fileName;
    final i = name.lastIndexOf('.');
    return i >= 0 && i < name.length - 1 ? name.substring(i + 1).toLowerCase() : '';
  }
}

/// One changed file in the session's workspace.
class WorkspaceChange {
  final String path;
  final String status;
  final String? origPath;
  final int? added;
  final int? deleted;
  final bool binary;

  const WorkspaceChange({
    required this.path,
    required this.status,
    this.origPath,
    this.added,
    this.deleted,
    this.binary = false,
  });

  factory WorkspaceChange.fromJson(Map<String, dynamic> json) => WorkspaceChange(
        path: json['path']?.toString() ?? '',
        status: json['status']?.toString() ?? 'M',
        origPath: json['origPath']?.toString(),
        added: _int(json['added']),
        deleted: _int(json['deleted']),
        binary: json['binary'] == true,
      );

  String get label {
    switch (status) {
      case '??':
        return '新增(未跟踪)';
      case 'A':
        return '新增';
      case 'D':
        return '删除';
      case 'R':
        return '重命名';
      case 'C':
        return '复制';
      case 'M':
        return '修改';
      default:
        // 组合状态（如 'MM'、'AM' 或 git 的未来写法）原样显示，不猜语义。
        return status.isEmpty ? '修改' : status;
    }
  }

  String get delta => binary
      ? '二进制'
      : (added == null && deleted == null)
          ? '—'
          : '+${added ?? 0} −${deleted ?? 0}';
}

/// One rendered line of a unified diff.
class DiffLine {
  /// 'add' | 'del' | 'context'
  final String kind;
  final String text;

  const DiffLine({required this.kind, required this.text});

  factory DiffLine.fromJson(Map<String, dynamic> json) => DiffLine(
        kind: json['kind']?.toString() ?? 'context',
        text: json['text']?.toString() ?? '',
      );
}

/// One hunk of a file diff.
class DiffHunk {
  final String header;
  final List<DiffLine> lines;

  const DiffHunk({required this.header, required this.lines});

  factory DiffHunk.fromJson(Map<String, dynamic> json) {
    final raw = json['lines'];
    return DiffHunk(
      header: json['header']?.toString() ?? '',
      lines: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => DiffLine.fromJson(Map<String, dynamic>.from(e)))
              .toList(growable: false)
          : const [],
    );
  }
}

/// One stored reminder for a session.
class ScheduleItem {
  final String id;
  final String kind;
  final String title;
  final String prompt;
  final String schedule;
  final String? scheduledAt;

  const ScheduleItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.prompt,
    required this.schedule,
    this.scheduledAt,
  });

  factory ScheduleItem.fromJson(Map<String, dynamic> json) => ScheduleItem(
        id: json['id']?.toString() ?? '',
        kind: json['kind']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        prompt: json['prompt']?.toString() ?? '',
        schedule: json['schedule']?.toString() ?? '',
        scheduledAt: json['scheduledAt']?.toString(),
      );
}

/// One background job visible to the session.
class JobItem {
  final String id;
  final String kind;
  final String label;
  final String status;
  final String? progress;
  final String? detail;

  const JobItem({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    this.progress,
    this.detail,
  });

  factory JobItem.fromJson(Map<String, dynamic> json) => JobItem(
        id: json['id']?.toString() ?? '',
        kind: json['kind']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        status: json['status']?.toString() ?? 'running',
        progress: json['progress']?.toString(),
        detail: json['detail']?.toString(),
      );

  bool get isLive => status == 'running' || status == 'stopping';

  String get statusLabel {
    switch (status) {
      case 'running':
        return '运行中';
      case 'stopping':
        return '停止中';
      case 'completed':
        return '已完成';
      case 'killed':
        return '已终止';
      case 'failed':
        return '失败';
      default:
        return status;
    }
  }
}

/// Provider-reported usage and context pressure for one session.
class SessionStats {
  final String source;
  final int? uncachedInputTokens;
  final int? outputTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final int? totalTokens;
  final int? pressureTokens;
  final int? projectedTokens;
  final int? contextWindow;
  final GoalInfo? goal;

  const SessionStats({
    required this.source,
    this.uncachedInputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.totalTokens,
    this.pressureTokens,
    this.projectedTokens,
    this.contextWindow,
    this.goal,
  });

  factory SessionStats.fromJson(Map<String, dynamic> json) {
    final goal = json['goal'];
    return SessionStats(
      source: json['source']?.toString() ?? 'none',
      uncachedInputTokens: _int(json['uncachedInputTokens']),
      outputTokens: _int(json['outputTokens']),
      cacheReadTokens: _int(json['cacheReadTokens']),
      cacheWriteTokens: _int(json['cacheWriteTokens']),
      totalTokens: _int(json['totalTokens']),
      pressureTokens: _int(json['pressureTokens']),
      projectedTokens: _int(json['projectedTokens']),
      contextWindow: _int(json['contextWindow']),
      goal: goal is Map ? GoalInfo.fromJson(Map<String, dynamic>.from(goal)) : null,
    );
  }

  bool get hasUsage => totalTokens != null;

  /// Context occupancy as a 0..1 fraction, or null when either side is unknown.
  double? get contextFraction {
    final used = pressureTokens;
    final window = contextWindow;
    if (used == null || window == null || window <= 0) return null;
    return (used / window).clamp(0.0, 1.0);
  }
}

/// The session's active goal, when one is set.
class GoalInfo {
  final String objective;
  final String phase;
  final int? roundsStarted;
  final int? maxGoalRounds;
  final String? blockedReason;

  const GoalInfo({
    required this.objective,
    required this.phase,
    this.roundsStarted,
    this.maxGoalRounds,
    this.blockedReason,
  });

  factory GoalInfo.fromJson(Map<String, dynamic> json) => GoalInfo(
        objective: json['objective']?.toString() ?? '',
        phase: json['phase']?.toString() ?? 'active',
        roundsStarted: _int(json['roundsStarted']),
        maxGoalRounds: _int(json['maxGoalRounds']),
        blockedReason: json['blockedReason']?.toString(),
      );

  String get phaseLabel {
    switch (phase) {
      case 'active':
        return '进行中';
      case 'paused':
        return '已暂停';
      case 'blocked':
        return '受阻';
      case 'complete':
        return '已完成';
      default:
        return phase;
    }
  }
}

/// ntfy push configuration as the gateway reports it (never includes the token).
class PushConfig {
  final bool enabled;
  final String url;
  final String topic;
  final bool hasToken;

  const PushConfig({
    required this.enabled,
    required this.url,
    required this.topic,
    required this.hasToken,
  });

  factory PushConfig.fromJson(Map<String, dynamic> json) => PushConfig(
        enabled: json['enabled'] == true,
        url: json['url']?.toString() ?? '',
        topic: json['topic']?.toString() ?? '',
        hasToken: json['hasToken'] == true,
      );

  bool get configured => enabled && url.trim().isNotEmpty && topic.trim().isNotEmpty;
}

/// Tolerant int parsing: accepts int, double and numeric strings.
int? _int(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}
