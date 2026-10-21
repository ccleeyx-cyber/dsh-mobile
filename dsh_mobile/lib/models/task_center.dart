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

  /// [feat 2026-10-13] 这一行来自**会话日志里 Agent 的写文件调用**，而不是 git。
  ///
  /// 此时 `added`/`deleted` 一定为 null（没有 git 就没有行数），界面必须渲染
  /// "—" 并说明来源：把它显示成 "+0 −0" 等于声称"这个文件没变化"。
  final bool fromToolCall;

  /// 触发这行的工具名（`write` / `edit`），仅 [fromToolCall] 时有值。
  final String? tool;

  const WorkspaceChange({
    required this.path,
    required this.status,
    this.origPath,
    this.added,
    this.deleted,
    this.binary = false,
    this.fromToolCall = false,
    this.tool,
  });

  factory WorkspaceChange.fromJson(Map<String, dynamic> json) => WorkspaceChange(
        path: json['path']?.toString() ?? '',
        status: json['status']?.toString() ?? 'M',
        origPath: json['origPath']?.toString(),
        added: _int(json['added']),
        deleted: _int(json['deleted']),
        binary: json['binary'] == true,
        fromToolCall: json['fromToolCall'] == true,
        tool: json['tool']?.toString(),
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

  /// [feat 2026-10-13] 运行时长（毫秒），由网关按 `finishedAt ?? now - startedAt`
  /// 算出。为 null 表示网关没给起点 —— 界面渲染成 "—" 而不是 0 秒。
  final int? durationMs;

  /// [feat 2026-10-13] 网关的权威"还活着"标记，与 [isLive] 同义。
  ///
  /// 保留两者：旧网关没有这个字段（回落成按 status 判断），新网关给了就信它。
  final bool liveFlag;

  /// [feat 2026-10-13] 输出环的绝对坐标（来自引擎 `JobView.output`）。
  ///
  /// `outputTotal` 是下一个 chunk 的起始偏移（= 已写入的总字节数），
  /// `outputEarliest` 是最早仍保留的字节；后者大于 0 就说明保留策略把日志开头裁掉了，
  /// 界面据此提示"开头已丢失"而不是假装日志完整。
  final int? outputTotal;
  final int? outputEarliest;

  /// 引擎的进度行（`3/10`、当前阶段），结算时清空。
  final String? progressLine;

  const JobItem({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    this.progress,
    this.detail,
    this.durationMs,
    this.liveFlag = false,
    this.outputTotal,
    this.outputEarliest,
    this.progressLine,
  });

  factory JobItem.fromJson(Map<String, dynamic> json) => JobItem(
        id: json['id']?.toString() ?? '',
        kind: json['kind']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        status: json['status']?.toString() ?? 'running',
        progress: json['progress']?.toString(),
        detail: json['detail']?.toString(),
        durationMs: _int(json['durationMs']),
        liveFlag: json['live'] == true,
        outputTotal: _int(json['outputTotal']),
        outputEarliest: _int(json['outputEarliest']),
        progressLine: json['progress']?.toString(),
      );

  bool get isLive => liveFlag || status == 'running' || status == 'stopping';

  /// 日志开头已被裁掉（保留窗口之外），界面必须说明这一点。
  bool get outputHeadLost => (outputEarliest ?? 0) > 0;

  /// 是否有可读的输出（引擎报过 total 且大于 0）。
  bool get hasOutput => (outputTotal ?? 0) > 0;

  /// 已写入输出的可读体量；未知时 null（界面显示 "—"）。
  String? get outputSizeLabel {
    final total = outputTotal;
    if (total == null) return null;
    if (total < 1024) return '$total B';
    if (total < 1024 * 1024) return '${(total / 1024).toStringAsFixed(1)} KB';
    return '${(total / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 时长的人读形式；未知时 null（界面显示 "—"）。
  String? get durationLabel {
    final ms = durationMs;
    if (ms == null) return null;
    final total = ms ~/ 1000;
    final s = total % 60;
    final m = (total ~/ 60) % 60;
    final h = total ~/ 3600;
    if (h > 0) return '$h 小时 $m 分';
    if (m > 0) return '$m 分 $s 秒';
    return '$s 秒';
  }

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

  /// 引擎 `sessionStats` 投影（轮/步/耗时/解码速度）；见 [counters] 的说明。
  final SessionCounters? counters;

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
    this.counters,
  });

  factory SessionStats.fromJson(Map<String, dynamic> json) {
    final goal = json['goal'];
    final counters = json['sessionStats'];
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
      // [feat 2026-10-17] 引擎 `sessionStats` 投影（轮/步/耗时/解码速度）。
      // 老网关没有这个键 → 保持 null，界面按"读不到"隐藏，而不是显示 0 轮 0 步。
      counters: counters is Map
          ? SessionCounters.fromJson(Map<String, dynamic>.from(counters))
          : null,
    );
  }

  /// 电脑端状态条第一组：`N 轮 M 步 · X tok/s`。
  ///
  /// 轮/步来自引擎的**全日志**投影，所以它是对的整会话总量 —— 手机端只加载了
  /// 窗口内的消息，靠数消息自己算会算成"1 轮"。
  int? get turns => counters?.turns;

  int? get steps => counters?.steps;

  /// 解码速度（输出 token / 解码耗时）。分母为 0 或缺失时 null → 界面显示 `—`，
  /// 不显示 `0 tok/s`（那读起来像"卡住了"）。
  double? get tokensPerSecond => counters?.tokensPerSecond;

  /// 缓存命中率（%）：缓存读取 / (未缓存输入 + 缓存读取)。
  ///
  /// 与电脑端 `cacheHitPercent` 同一口径；分母未知/为 0 时返回 null。
  int? get cacheHitPercent {
    final cached = cacheReadTokens;
    final uncached = uncachedInputTokens;
    if (cached == null || uncached == null) return null;
    final denom = cached + uncached;
    if (denom <= 0) return null;
    return (cached * 100 / denom).round();
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

/// 会话统计：电脑端状态条第一组那几个数字（`6 轮 351 步 · 210 tok/s`）。
///
/// 数据源是引擎的 **`sessionStats` 投影**（全日志级，不是当前窗口）：手机端只加载了
/// 窗口内的消息，自己数消息会把一个 6 轮的会话算成"1 轮"。所以这几个数字必须由网关
/// 从投影里取来 —— 读不到时整组隐藏（`null`），不显示 `0 轮 0 步`。
///
/// 字段名与引擎投影一致（电脑端的 `deriveStats` 兜底函数就是照着投影字段名写的）。
class SessionCounters {
  final int? turns;
  final int? steps;
  final int? llmMs;
  final int? toolMs;
  final int? ttftMs;
  final int? ttftSteps;
  final int? decodeMs;
  final int? decodeTokens;

  const SessionCounters({
    this.turns,
    this.steps,
    this.llmMs,
    this.toolMs,
    this.ttftMs,
    this.ttftSteps,
    this.decodeMs,
    this.decodeTokens,
  });

  factory SessionCounters.fromJson(Map<String, dynamic> json) {
    int? asInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('${v ?? ''}');
    }

    return SessionCounters(
      turns: asInt(json['turns']),
      steps: asInt(json['steps']),
      llmMs: asInt(json['llmMs']),
      toolMs: asInt(json['toolMs']),
      ttftMs: asInt(json['ttftMs']),
      ttftSteps: asInt(json['ttftSteps']),
      decodeMs: asInt(json['decodeMs']),
      decodeTokens: asInt(json['decodeTokens']),
    );
  }

  /// 有没有任何可显示的计数（`steps == 0` 的合法空会话另算，见下）。
  bool get hasCounts => turns != null || steps != null;

  /// 解码速度（tok/s）：`decodeTokens / (decodeMs / 1000)`。
  ///
  /// 电脑端同一口径。分母 <= 0 或任一未知 → null（界面显示 `—`）。**不能**回落成 0：
  /// `0 tok/s` 会被读成"卡住了"，而真相是"这次没测到解码耗时"。
  double? get tokensPerSecond {
    final ms = decodeMs;
    final tokens = decodeTokens;
    if (ms == null || tokens == null || ms <= 0) return null;
    return tokens / (ms / 1000);
  }
}

/// The session's active goal, when one is set.
class GoalInfo {
  final String objective;
  final String phase;
  final int? roundsStarted;
  final int? maxGoalRounds;
  final String? blockedReason;

  /// [feat 2026-10-12] 引擎的 goal 操作 RPC（goals/pause 等）需要一个
  /// `{ id, revision }` 的 CAS ref。网关把投影行里的 id/revision 一并透出；
  /// 缺省时 App 端隐藏操作按钮（没有 ref 就没有可信的操作目标）。
  final String? goalId;
  final int? revision;

  const GoalInfo({
    required this.objective,
    required this.phase,
    this.roundsStarted,
    this.maxGoalRounds,
    this.blockedReason,
    this.goalId,
    this.revision,
  });

  factory GoalInfo.fromJson(Map<String, dynamic> json) => GoalInfo(
        objective: json['objective']?.toString() ?? '',
        phase: json['phase']?.toString() ?? 'active',
        roundsStarted: _int(json['roundsStarted']),
        maxGoalRounds: _int(json['maxGoalRounds']),
        blockedReason: json['blockedReason']?.toString(),
        goalId: json['goalId']?.toString(),
        revision: _int(json['revision']),
      );

  /// 暂停/继续/完成操作是否可用：必须同时有 ref 的两半。
  bool get operable => (goalId?.isNotEmpty ?? false) && (revision ?? 0) > 0;

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

/// One diagnostic check row returned by GET /api/mobile/diagnostics. [feat 2026-10-12]
class DiagnosticCheck {
  final String name;
  final bool? ok;
  final String? value;
  final String? detail;

  const DiagnosticCheck({
    required this.name,
    this.ok,
    this.value,
    this.detail,
  });

  factory DiagnosticCheck.fromJson(Map<String, dynamic> json) => DiagnosticCheck(
        name: json['name']?.toString() ?? '',
        // `ok` 真的缺省（例如 bridge_version 只报 value）时保持 null，
        // 界面渲染成中性而非假的通过/失败。
        ok: json['ok'] is bool ? json['ok'] as bool : null,
        value: json['value']?.toString(),
        detail: json['detail']?.toString(),
      );

  /// 中文标签；未知名字原样显示，不猜语义。
  String get label => switch (name) {
        'bridge_version' => '网关版本',
        'engine_rpc' => '引擎 RPC',
        'ws_clients' => '在线设备',
        'engine_events_stream' => '事件流',
        'devices' => '已配对设备',
        'disk' => '磁盘可写',
        _ => name,
      };
}

/// Full diagnostics report.
class DiagnosticsReport {
  final bool ok;
  final List<DiagnosticCheck> checks;
  final DateTime? generatedAt;

  const DiagnosticsReport({
    required this.ok,
    required this.checks,
    this.generatedAt,
  });

  factory DiagnosticsReport.fromJson(Map<String, dynamic> json) {
    final raw = json['checks'];
    return DiagnosticsReport(
      ok: json['ok'] == true,
      checks: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => DiagnosticCheck.fromJson(Map<String, dynamic>.from(e)))
              .where((c) => c.name.isNotEmpty)
              .toList(growable: false)
          : const <DiagnosticCheck>[],
      generatedAt: DateTime.tryParse(json['generatedAt']?.toString() ?? ''),
    );
  }

  /// 可复制的纯文本报告（脱敏后的 detail 原样带出）。
  String toPlainText() {
    final b = StringBuffer('DSH 连接诊断 ${generatedAt ?? ''}'.trim());
    for (final c in checks) {
      final mark = c.ok == null ? '•' : (c.ok! ? '✓' : '✗');
      final tail = [c.value, c.detail].where((e) => e != null && e.isNotEmpty).join(' · ');
      b.write('\n$mark ${c.label}${tail.isEmpty ? '' : '：$tail'}');
    }
    return b.toString();
  }
}

/// One subagent row from GET /api/mobile/sessions/subagents. [feat 2026-10-12]
class SubagentItem {
  final String id;
  final String kind; // 'child' | 'diagnostic'
  final String activity; // 'running' | 'inactive' (child only)
  final String mode; // 'continuable' | 'one-shot' (child only)
  final String label;
  final String reason; // diagnostic only

  const SubagentItem({
    required this.id,
    required this.kind,
    this.activity = 'inactive',
    this.mode = 'one-shot',
    this.label = '',
    this.reason = '',
  });

  factory SubagentItem.fromJson(Map<String, dynamic> json) => SubagentItem(
        id: json['id']?.toString() ?? '',
        kind: json['kind']?.toString() ?? 'child',
        activity: json['activity']?.toString() ?? 'inactive',
        mode: json['mode']?.toString() ?? 'one-shot',
        label: json['label']?.toString() ?? '',
        reason: json['reason']?.toString() ?? '',
      );

  bool get isDiagnostic => kind == 'diagnostic';

  /// 只有 continuable 的子代理能被中断（引擎对 one-shot 一律拒绝）。
  bool get interruptible => !isDiagnostic && mode == 'continuable';

  bool get isRunning => !isDiagnostic && activity == 'running';

  String get displayLabel => label.isNotEmpty ? label : id;
}

/// Goal ref + operation result. [feat 2026-10-12]
///
/// 引擎没有 goal 读 RPC，ref（id + revision）必须由调用方带上 —— App 从
/// `session/stats` 的 goal 投影行拿到 objective，但 revision 只能由网关透出；
/// 这里保存最近一次 stats 返回的 goalId/revision 供操作使用。
class GoalAction {
  final String action; // pause | resume | complete
  final bool ok;
  final String? phase;

  const GoalAction({required this.action, required this.ok, this.phase});
}

/// One slash command from GET /api/mobile/sessions/commands. [feat 2026-10-12]
class SlashCommand {
  final String name;
  final String description;
  final String? hint;

  const SlashCommand({required this.name, required this.description, this.hint});

  factory SlashCommand.fromJson(Map<String, dynamic> json) => SlashCommand(
        name: json['name']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        hint: json['hint']?.toString(),
      );

  /// 插进输入框的文本：`/name `（带尾随空格，让用户直接接参数）。
  String get insertText => '/$name ';
}

/// 一条 skill，来自 `GET /api/mobile/sessions/skills`。[feat 2026-10-21]
///
/// 为什么单独一个模型而不是复用 [SlashCommand]：两者在界面上的**来源与语义**
/// 不同 —— 命令是引擎注册的斜杠命令（`commands/list`），技能是 skill 目录
/// （`skills/list`）。web 端的 `/` 菜单把两路合并展示，手机端此前只接了命令，
/// 于是打 `/` 看不到任何 skill（真机反馈）。
///
/// 插入文本与命令一致：`/name `。这条是照 web 的做法来的 —— 网页端从 `/` 菜单
/// 选中 skill 后插入的也是 `/<name>`，引擎侧按同一个斜杠语法解析。
class SkillCatalogEntry {
  final String name;
  final String description;

  /// 来源（filesystem / builtin / …），仅作展示分组用，可能为空。
  final String source;

  const SkillCatalogEntry({
    required this.name,
    required this.description,
    this.source = '',
  });

  factory SkillCatalogEntry.fromJson(Map<String, dynamic> json) => SkillCatalogEntry(
        name: json['name']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        source: json['source']?.toString() ?? '',
      );

  String get insertText => '/$name ';
}

/// Tolerant int parsing: accepts int, double and numeric strings.
int? _int(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// One teammate (or the synthetic Lead) from `GET /api/mobile/sessions/team`. [feat 2026-10-16]
///
/// 对应引擎 `agentTeam` 投影的 wire view（`teamMemberProjectionSchema`）。
/// [phase] 决定徽标颜色：active=进行中 / provisioning=创建中 / failed=失败。
class TeamMember {
  final String id;
  final String name;
  final String role; // 'lead' | 'teammate'
  final String phase; // 'provisioning' | 'active' | 'done' | 'failed'
  final String error;

  const TeamMember({
    required this.id,
    required this.name,
    this.role = 'teammate',
    this.phase = 'provisioning',
    this.error = '',
  });

  factory TeamMember.fromJson(Map<String, dynamic> json) => TeamMember(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        role: json['role']?.toString() ?? 'teammate',
        phase: json['phase']?.toString() ?? 'provisioning',
        error: json['error']?.toString() ?? '',
      );

  bool get isLead => role == 'lead';
  bool get isActive => phase == 'active';
  bool get isFailed => phase == 'failed';
  bool get isProvisioning => phase == 'provisioning';

  /// 回合已跑完（这个队友手上没有未闭合的回合）。
  ///
  /// 与 `isActive` 互斥：网关只会给出其中一个。存在的理由见 `phaseLabel`。
  bool get isDone => phase == 'done';

  String get phaseLabel {
    if (isLead) return '主导';
    if (isFailed) return '失败';
    if (isDone) return '已完成';
    if (isActive) return '进行中';
    return '创建中';
  }
}

/// One shared task-board row from `GET /api/mobile/sessions/team`. [feat 2026-10-16]
///
/// 对应 `teamTaskViewSchema`。已删除任务由网关过滤，不会出现在这里。
class TeamTask {
  final String id;
  final int revision;
  final String subject;
  final String description;
  final String status; // 'pending' | 'in_progress' | 'completed'
  final List<String> blockedBy;
  final String ownerName;
  final bool ready;

  const TeamTask({
    required this.id,
    this.revision = 1,
    this.subject = '',
    this.description = '',
    this.status = 'pending',
    this.blockedBy = const [],
    this.ownerName = '',
    this.ready = false,
  });

  factory TeamTask.fromJson(Map<String, dynamic> json) => TeamTask(
        id: json['id']?.toString() ?? '',
        revision: _int(json['revision']) ?? 1,
        subject: json['subject']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        status: json['status']?.toString() ?? 'pending',
        blockedBy: (json['blockedBy'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        ownerName: json['ownerName']?.toString() ?? '',
        ready: json['ready'] == true,
      );

  bool get isInProgress => status == 'in_progress';
  bool get isCompleted => status == 'completed';
  bool get isBlocked => blockedBy.isNotEmpty || !ready;

  String get statusLabel {
    if (isCompleted) return '已完成';
    if (isInProgress) return '进行中';
    return '待办';
  }
}

/// 一个会话的智能体团队快照。 [feat 2026-10-16]
///
/// [supported] 为 false 表示**引擎没装团队能力**，与「有团队但现在没人」是两种
/// 完全不同的情况，必须分开显示，否则用户会以为队友全挂了。
class AgentTeam {
  final List<TeamMember> members;
  final List<TeamTask> tasks;
  final String failure;
  final bool supported;
  final String source; // 'rpc' | 'cache'

  const AgentTeam({
    this.members = const [],
    this.tasks = const [],
    this.failure = '',
    this.supported = true,
    this.source = 'rpc',
  });

  factory AgentTeam.fromJson(Map<String, dynamic> json) => AgentTeam(
        members: (json['members'] as List?)
                ?.map((e) => TeamMember.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            const [],
        tasks: (json['tasks'] as List?)
                ?.map((e) => TeamTask.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            const [],
        failure: json['failure']?.toString() ?? '',
        supported: json['supported'] != false,
        source: json['source']?.toString() ?? 'rpc',
      );

  /// 队友（不含 Lead 自己）。
  List<TeamMember> get teammates => members.where((m) => !m.isLead).toList();

  bool get isEmpty => teammates.isEmpty && tasks.isEmpty;

  /// 有队友在跑，或有任务没做完 —— 决定面板上要不要显出「正在工作」。
  bool get isWorking =>
      members.any((m) => m.isActive && !m.isLead) || tasks.any((t) => t.isInProgress);
}
