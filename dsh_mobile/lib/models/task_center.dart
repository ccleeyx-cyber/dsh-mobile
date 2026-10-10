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

  /// 声明时刻（epoch 毫秒）。网关 `extractDeliverables` 一直在回传 `time`，
  /// 只是模型没接 —— 它在"这条产出是什么时候给的"上比 `seq` 更可读。
  final int? time;

  const DeliverableItem({
    required this.path,
    required this.display,
    required this.description,
    this.turn,
    this.seq,
    this.time,
  });

  factory DeliverableItem.fromJson(Map<String, dynamic> json) => DeliverableItem(
        path: json['path']?.toString() ?? '',
        display: json['display']?.toString() ?? json['path']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        turn: _int(json['turn']),
        seq: _int(json['seq']),
        time: _int(json['time']),
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

/// 一轮里声明过的交付物。
///
/// 网关的 `extractDeliverables` 按 `seq` **倒序**返回（最新声明的排最前），
/// 这里只分组、不重排组内顺序 —— 组内顺序就是网关给的顺序。
class DeliverableGroup {
  /// 轮号；`null` 表示网关没回传轮号（老记录，或事件里缺 turn）。
  final int? turn;
  final List<DeliverableItem> items;

  const DeliverableGroup({required this.turn, required this.items});

  /// 这一组的轮次标签，未知时为 null（界面据此降级文案，而不是编一个轮号）。
  String? get turnLabel => turn == null ? null : '第 $turn 轮';
}

/// 按轮次分组，**轮号大的在前**；没有轮号的记录自成一组建在最后。
///
/// 为什么需要分组而不是只排序：一个长会话可能声明过几十个文件，而手机上一次
/// 只看得下 5~8 行。用户 99% 要的是"刚给我的那批"，所以"按轮分组 + 默认只
/// 展开最新一轮"是交付物列表的基本形态，不是可选的排序优化。
List<DeliverableGroup> groupDeliverablesByTurn(List<DeliverableItem> rows) {
  final numbered = <int, List<DeliverableItem>>{};
  final unnumbered = <DeliverableItem>[];
  for (final row in rows) {
    final turn = row.turn;
    if (turn == null) {
      unnumbered.add(row);
    } else {
      numbered.putIfAbsent(turn, () => <DeliverableItem>[]).add(row);
    }
  }
  final turns = numbered.keys.toList()..sort((a, b) => b.compareTo(a));
  return <DeliverableGroup>[
    for (final turn in turns) DeliverableGroup(turn: turn, items: numbered[turn]!),
    if (unnumbered.isNotEmpty) DeliverableGroup(turn: null, items: unnumbered),
  ];
}

/// 最新一轮的交付物（流内「本轮产出」卡片用）；没有记录时是空列表。
///
/// 若所有记录都没有轮号，返回的是**整份清单**（它已经按 seq 倒序，即"最近声明
/// 的在前"），因为此时"哪一轮"无从判断 —— 卡片会把标题降级成「最近交付」，
/// 而不是假装这些都属于同一轮。
List<DeliverableItem> latestDeliverableTurn(List<DeliverableItem> rows) {
  final groups = groupDeliverablesByTurn(rows);
  return groups.isEmpty ? const <DeliverableItem>[] : groups.first.items;
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

  /// Tokens this session actually consumed: uncached input + output.
  ///
  /// Deliberately **not** [totalTokens], which also adds the cache buckets. On a
  /// live session the cache-read bucket is the same context re-read every turn,
  /// so it dwarfs everything else (measured on the user's own session: 11.08M
  /// input + 0.34M output + 193.46M cache read). Showing that sum as
  /// "consumption" claimed 205M tokens had been burned when they had not, and
  /// the user reasonably read the figure as nonsense. Cache traffic is reported
  /// on its own line and is not part of what was consumed.
  ///
  /// null when neither core number is known, so the UI shows "—" rather than
  /// inventing a zero.
  int? get consumedTokens {
    if (uncachedInputTokens == null && outputTokens == null) return null;
    return (uncachedInputTokens ?? 0) + (outputTokens ?? 0);
  }

  /// True when the provider reported cache reuse worth mentioning.
  bool get hasCacheReuse => (cacheReadTokens ?? 0) > 0 || (cacheWriteTokens ?? 0) > 0;

  /// Context occupancy as a 0..1 fraction, or null when either side is unknown.
  double? get contextFraction {
    final used = pressureTokens;
    final window = contextWindow;
    if (used == null || window == null || window <= 0) return null;
    return (used / window).clamp(0.0, 1.0);
  }

  /// 数值来自引擎的实时投影（会话此刻在内存里）。
  bool get isLive => source == 'live';

  /// 数值来自投影缓存快照：会话当前不在内存中，这**不是**实时值。
  ///
  /// 必须与 [isLive] 区分渲染 —— 把几小时前的快照当实时值展示，会让用户
  /// 据此做出错误的"还能不能继续"判断。
  bool get isSnapshot => source == 'cache';

  /// 本轮消耗 = 两次「实时」总 token 读数之差。
  ///
  /// 返回 `null` 的一切情形都必须由调用方渲染成「—」：基线未知、当前读数未知、
  /// 或当前读数不是实时值（`cache` 快照可能是很久以前的）。**绝不允许回落成
  /// 0** —— 0 在用户眼里是"这轮免费"，而真相是"不知道"，这是两件事。
  ///
  /// `tokenUsage` 是单调累计的会话投影，所以"两次读数之差"确实等于这段时间
  /// 里跑掉的量；调用方在每个 `done` 更新基线即可得到"这一轮"。
  static int? turnDelta({int? baseline, SessionStats? now}) {
    if (baseline == null || now == null || !now.isLive) return null;
    final total = now.totalTokens;
    if (total == null || total < baseline) return null;
    return total - baseline;
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
