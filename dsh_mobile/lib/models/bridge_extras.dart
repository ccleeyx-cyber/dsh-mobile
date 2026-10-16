/// Models for the bridge extensions (v1.16, 2026-10-13): git-repo discovery,
/// host-command panel, read-only workspace browser, deliverable text preview,
/// custom approval presets, one-tap push topics, the goal board, and session
/// fork checkpoints.
///
/// House rules, copied from `task_center.dart` on purpose: **every parser here
/// is total**. A malformed field degrades to null or an empty value instead of
/// throwing, because one unexpected shape must never take down the page that
/// renders the other nine good rows. A genuinely unknown value stays null so the
/// UI can render "—" rather than a fake zero.
library;

// `JobItem` is reused rather than re-declared: the gateway's `job/list` rows and
// the `job/follow` stream's embedded projection are the same engine `JobView`, so
// a second model would be a second place for the two parsers to drift apart.
import 'task_center.dart';

/// One repository the session's workspace maps to (P0-1).
class RepoCandidate {
  final String name;

  /// Workspace-relative name. The gateway deliberately never sends the absolute
  /// prefix, so this is a label to display, not a path to open.
  final String path;

  const RepoCandidate({required this.name, required this.path});

  factory RepoCandidate.fromJson(Map<String, dynamic> json) => RepoCandidate(
        name: json['name']?.toString() ?? '',
        path: json['path']?.toString() ?? '',
      );
}

/// Result of `GET /api/mobile/workspace/repos`.
class WorkspaceRepos {
  /// True when a repository was found at all (self, ancestor or child).
  final bool available;

  /// True when the session cwd IS a repository.
  final bool cwdIsRepo;

  /// Gateway reason when nothing was found (`not-a-git-repository` /
  /// `no-workspace`); empty when a repository exists.
  final String reason;

  /// Immediate child repositories, when the cwd itself is not one.
  final List<RepoCandidate> repos;

  /// How many ancestor levels carry a repository. Only a count: enough to say
  /// "上层有仓库" without leaking host layout.
  final int ancestorCount;

  /// Which entry the gateway would use (`"."`, a child name, or `..`).
  final String primary;

  const WorkspaceRepos({
    required this.available,
    required this.cwdIsRepo,
    required this.reason,
    required this.repos,
    required this.ancestorCount,
    required this.primary,
  });

  factory WorkspaceRepos.fromJson(Map<String, dynamic> json) {
    final raw = json['repos'];
    return WorkspaceRepos(
      available: json['available'] == true,
      cwdIsRepo: json['cwdIsRepo'] == true,
      reason: json['reason']?.toString() ?? '',
      repos: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => RepoCandidate.fromJson(Map<String, dynamic>.from(e)))
              .where((r) => r.name.isNotEmpty)
              .toList(growable: false)
          : const <RepoCandidate>[],
      ancestorCount: _int(json['ancestorCount']) ?? 0,
      primary: json['primary']?.toString() ?? '',
    );
  }
}

/// One file the session log shows the agent touching (P0-1 fallback).
class ToolCallFileHint {
  final String display;
  final String tool;
  final int? seq;

  const ToolCallFileHint({required this.display, required this.tool, this.seq});

  factory ToolCallFileHint.fromJson(Map<String, dynamic> json) => ToolCallFileHint(
        display: json['display']?.toString() ?? json['path']?.toString() ?? '',
        tool: json['tool']?.toString() ?? '',
        seq: _int(json['seq']),
      );
}

/// One entry in the whitelisted command panel (P1-5).
class QuickCommandInfo {
  final String id;
  final String label;
  final String group;
  final String description;

  /// True when the command mutates the workspace; the UI must confirm first.
  final bool danger;

  const QuickCommandInfo({
    required this.id,
    required this.label,
    required this.group,
    required this.description,
    required this.danger,
  });

  factory QuickCommandInfo.fromJson(Map<String, dynamic> json) => QuickCommandInfo(
        id: json['id']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        group: json['group']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        danger: json['danger'] == true,
      );

  /// Group heading; unknown groups pass through so a new server group still
  /// renders instead of vanishing.
  String get groupLabel => switch (group) {
        'git' => 'Git',
        'fs' => '文件',
        'host' => '主机',
        'mutate' => '修改操作',
        _ => group.isEmpty ? '其它' : group,
      };
}

/// Result of running one whitelisted command.
class QuickCommandResult {
  final bool ok;
  final String id;
  final String label;

  /// Process exit code. Non-null even when it is non-zero: the command RAN, and
  /// git's own message must reach the user instead of a bridge-invented failure.
  final int? exitCode;

  final String stdout;
  final String stderr;
  final bool truncated;

  /// True when the per-command timeout fired; the output is partial.
  final bool timedOut;

  final int? durationMs;

  /// Gateway error string when [ok] is false (`command-not-found`, …).
  final String error;

  const QuickCommandResult({
    required this.ok,
    this.id = '',
    this.label = '',
    this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.truncated = false,
    this.timedOut = false,
    this.durationMs,
    this.error = '',
  });

  factory QuickCommandResult.fromJson(Map<String, dynamic> json) => QuickCommandResult(
        ok: json['ok'] == true,
        id: json['id']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        exitCode: _int(json['exitCode']),
        stdout: json['stdout']?.toString() ?? '',
        stderr: json['stderr']?.toString() ?? '',
        truncated: json['truncated'] == true,
        timedOut: json['timedOut'] == true,
        durationMs: _int(json['durationMs']),
        error: json['error']?.toString() ?? '',
      );

  /// True when the process exited non-zero.
  bool get failed => ok && exitCode != null && exitCode != 0;

  /// Combined output for display, stderr last so an error reads last.
  String get combined {
    if (stderr.trim().isEmpty) return stdout;
    if (stdout.trim().isEmpty) return stderr;
    return '$stdout\n$stderr';
  }
}

/// One entry of a workspace directory (P1-9).
class FsEntry {
  final String name;

  /// 'dir' | 'file' | 'other'.
  final String kind;
  final int? size;
  final int? mtime;

  const FsEntry({required this.name, required this.kind, this.size, this.mtime});

  factory FsEntry.fromJson(Map<String, dynamic> json) => FsEntry(
        name: json['name']?.toString() ?? '',
        kind: json['kind']?.toString() ?? 'other',
        size: _int(json['size']),
        mtime: _int(json['mtime']),
      );

  bool get isDir => kind == 'dir';

  /// Human size; null for directories and unknown sizes.
  String get sizeLabel {
    final bytes = size;
    if (bytes == null || isDir) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// One directory listing.
class FsListing {
  final bool ok;

  /// Workspace-relative path that was listed; empty means the workspace root.
  final String path;

  /// Parent to go up to; null at the root (the UI hides "up" there).
  final String? parent;
  final List<FsEntry> entries;

  /// True when the gateway capped the list; `total` still reports the real count.
  final bool truncated;
  final int total;
  final String error;

  const FsListing({
    required this.ok,
    this.path = '',
    this.parent,
    this.entries = const <FsEntry>[],
    this.truncated = false,
    this.total = 0,
    this.error = '',
  });

  factory FsListing.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'];
    return FsListing(
      ok: json['ok'] == true,
      path: json['path']?.toString() ?? '',
      parent: json['parent']?.toString(),
      entries: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => FsEntry.fromJson(Map<String, dynamic>.from(e)))
              .where((e) => e.name.isNotEmpty)
              .toList(growable: false)
          : const <FsEntry>[],
      truncated: json['truncated'] == true,
      total: _int(json['total']) ?? 0,
      error: json['error']?.toString() ?? '',
    );
  }
}

/// One file read from the workspace (P1-9) or a deliverable preview (P0-4).
///
/// Shared by both because the two routes answer the same shape, and the preview
/// sheet renders them identically — a second model would only be a second place
/// for the binary/text decision to drift.
class TextFileContent {
  final bool ok;
  final String path;
  final String name;
  final bool binary;

  /// Null when [binary] is true.
  final String? content;
  final int? size;
  final bool truncated;
  final int? mtime;
  final String contentType;

  /// Gateway prose (e.g. why a binary deliverable cannot be previewed).
  final String note;
  final String error;

  const TextFileContent({
    required this.ok,
    this.path = '',
    this.name = '',
    this.binary = false,
    this.content,
    this.size,
    this.truncated = false,
    this.mtime,
    this.contentType = '',
    this.note = '',
    this.error = '',
  });

  factory TextFileContent.fromJson(Map<String, dynamic> json) => TextFileContent(
        ok: json['ok'] == true,
        path: json['path']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        binary: json['binary'] == true,
        content: json['content']?.toString(),
        size: _int(json['size']),
        truncated: json['truncated'] == true,
        mtime: _int(json['mtime']),
        contentType: json['contentType']?.toString() ?? '',
        note: json['note']?.toString() ?? '',
        error: json['error']?.toString() ?? '',
      );

  /// True when the payload can be rendered as Markdown.
  bool get isMarkdown {
    final n = (name.isNotEmpty ? name : path).toLowerCase();
    return n.endsWith('.md') || n.endsWith('.markdown');
  }

  /// True when the payload is an inline-renderable image.
  bool get isImage => contentType.startsWith('image/');
}

/// The knob a preset controls (P0-2).
///
/// Separate from the live `PermissionConfig` so applying a preset can never
/// rewrite per-session overrides by accident.
///
/// 只带 `defaultPolicy`：网关的预设 payload 里还有 `sandboxMode` / `maxSteps` /
/// `protectGit`，但那三个字段全链路无人消费（见 `PermissionConfig` 的说明）。
/// 旧版 App 存的预设里仍带着它们，解析时忽略即可 —— 这里不再建模，避免又出现
/// "读得到一个值、写入一个值、却没有任何效果"的死配置项。
class PresetConfig {
  final String defaultPolicy;

  const PresetConfig({required this.defaultPolicy});

  factory PresetConfig.fromJson(Map<String, dynamic> json) => PresetConfig(
        defaultPolicy: json['defaultPolicy']?.toString() ?? 'ask',
      );

  Map<String, dynamic> toJson() => {
        'defaultPolicy': defaultPolicy,
      };
}

/// One stored approval preset.
class ApprovalPresetInfo {
  final String id;
  final String label;
  final String summary;

  /// True for the presets the App itself ships. The host never stores those, so
  /// this is false for everything that came off the wire.
  final bool builtin;

  /// True when the preset relaxes the policy to `danger-full-access`; the UI
  /// must warn rather than present it as an ordinary choice.
  final bool dangerous;

  final PresetConfig config;
  final int? updatedAt;

  const ApprovalPresetInfo({
    required this.id,
    required this.label,
    required this.summary,
    required this.builtin,
    required this.dangerous,
    required this.config,
    this.updatedAt,
  });

  factory ApprovalPresetInfo.fromJson(Map<String, dynamic> json) {
    final cfg = json['config'];
    return ApprovalPresetInfo(
      id: json['id']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      builtin: json['builtin'] == true,
      dangerous: json['dangerous'] == true,
      config: cfg is Map
          ? PresetConfig.fromJson(Map<String, dynamic>.from(cfg))
          : const PresetConfig(defaultPolicy: 'ask'),
      updatedAt: _int(json['updatedAt']),
    );
  }
}

/// One-tap push topic result (P0-3).
class PushTopicResult {
  final bool enabled;
  final String url;
  final String topic;
  final bool hasToken;

  /// `ntfy://host/topic` deep link that opens the ntfy app.
  final String subscribeUrl;

  /// `https://host/topic` for a browser.
  final String webUrl;
  final String host;

  const PushTopicResult({
    required this.enabled,
    required this.url,
    required this.topic,
    required this.hasToken,
    required this.subscribeUrl,
    required this.webUrl,
    required this.host,
  });

  factory PushTopicResult.fromJson(Map<String, dynamic> json) {
    final push = json['push'];
    final links = json['links'];
    final p = push is Map ? Map<String, dynamic>.from(push) : const <String, dynamic>{};
    final l = links is Map ? Map<String, dynamic>.from(links) : const <String, dynamic>{};
    return PushTopicResult(
      enabled: p['enabled'] == true,
      url: p['url']?.toString() ?? '',
      topic: p['topic']?.toString() ?? '',
      hasToken: p['hasToken'] == true,
      subscribeUrl: l['subscribeUrl']?.toString() ?? '',
      webUrl: l['webUrl']?.toString() ?? '',
      host: l['host']?.toString() ?? '',
    );
  }
}

/// Full goal board state (P1-7).
class GoalBoard {
  /// False when the session has no goal; every other field is then meaningless.
  final bool present;

  /// 'live' | 'cache' | 'none'. `cache` means the numbers are a snapshot from a
  /// session that is no longer in memory — the board must say so rather than
  /// present them as current.
  final String source;

  final String goalId;
  final int? revision;
  final String objective;
  final String phase;
  final String? blockedReason;
  final String? blockedCode;
  final int? roundsStarted;
  final int? maxGoalRounds;
  final int? roundsRemaining;

  /// 0..1 fraction, or null when either side is unknown.
  final double? progress;
  final int? createdAt;
  final int? updatedAt;

  const GoalBoard({
    required this.present,
    required this.source,
    this.goalId = '',
    this.revision,
    this.objective = '',
    this.phase = 'active',
    this.blockedReason,
    this.blockedCode,
    this.roundsStarted,
    this.maxGoalRounds,
    this.roundsRemaining,
    this.progress,
    this.createdAt,
    this.updatedAt,
  });

  factory GoalBoard.fromJson(Map<String, dynamic> json) {
    final progress = json['progress'];
    return GoalBoard(
      present: json['present'] == true,
      source: json['source']?.toString() ?? 'none',
      goalId: json['goalId']?.toString() ?? '',
      revision: _int(json['revision']),
      objective: json['objective']?.toString() ?? '',
      phase: json['phase']?.toString() ?? 'active',
      blockedReason: json['blockedReason']?.toString(),
      blockedCode: json['blockedCode']?.toString(),
      roundsStarted: _int(json['roundsStarted']),
      maxGoalRounds: _int(json['maxGoalRounds']),
      roundsRemaining: _int(json['roundsRemaining']),
      progress: progress is num ? progress.toDouble().clamp(0.0, 1.0) : null,
      createdAt: _int(json['createdAt']),
      updatedAt: _int(json['updatedAt']),
    );
  }

  /// Pause/resume/complete/edit need both halves of the CAS ref. Without them
  /// the UI hides the controls: there is no trustworthy target to mutate.
  bool get operable => goalId.isNotEmpty && (revision ?? 0) > 0;

  bool get isSnapshot => source == 'cache';

  String get phaseLabel => switch (phase) {
        'active' => '进行中',
        'paused' => '已暂停',
        'blocked' => '受阻',
        'complete' => '已完成',
        _ => phase,
      };

  /// Rounds text, or null when the counts are unknown (render "—").
  String? get roundsLabel {
    if (roundsStarted == null) return null;
    if (maxGoalRounds == null) return '已跑 $roundsStarted 轮';
    return '$roundsStarted / $maxGoalRounds 轮';
  }
}

/// One fork point in a session (P1-8).
class SessionCheckpoint {
  final int? seq;
  final int? turn;
  final int? time;

  /// The `turn/end` reason kind; null for clean completions on older logs.
  final String? reason;

  /// False when the turn did not end normally (`error` / `interrupted` /
  /// `blocked`) — the engine refuses to fork from an unfinished turn, so the
  /// picker disables those instead of sending a request that must fail.
  final bool forkable;

  /// The user prompt that started this turn, so the picker is readable.
  final String label;

  const SessionCheckpoint({
    this.seq,
    this.turn,
    this.time,
    this.reason,
    this.forkable = true,
    this.label = '',
  });

  factory SessionCheckpoint.fromJson(Map<String, dynamic> json) => SessionCheckpoint(
        seq: _int(json['seq']),
        turn: _int(json['turn']),
        time: _int(json['time']),
        reason: json['reason']?.toString(),
        forkable: json['forkable'] != false,
        label: json['label']?.toString() ?? '',
      );

  String get title {
    final parts = <String>[
      if (turn != null) '第 $turn 轮',
      if (seq != null) 'seq $seq',
    ];
    return parts.isEmpty ? '检查点' : parts.join(' · ');
  }

  /// Why a checkpoint cannot be branched from, or null when it can.
  String? get blockReason => forkable
      ? null
      : switch (reason) {
          'error' => '该轮以错误结束',
          'interrupted' => '该轮被引擎中断',
          'blocked' => '该轮被策略阻止',
          _ => '该轮未正常结束',
        };
}

/// Outcome of a job stop (P1-6).
///
/// The engine has a real stop Remote — `job/kill(request:{sessionId, jobId})` →
/// `{ outcome: 'requested' | 'already-finished' }`. An earlier revision of this
/// app modelled it as an Agent-mediated request because a faulty package scan
/// suggested no such Remote existed; that was wrong, and the mediation is gone.
class JobStopResult {
  final bool ok;

  /// The engine's own receipt. `requested` means the registry accepted the stop;
  /// `already-finished` means there was nothing left to stop.
  ///
  /// ⚠️ `requested` is a REQUEST, not a completed kill: the producer's `cancel`
  /// is asynchronous, so the job may still read as live on the next list fetch.
  /// The UI must not claim it is already terminated.
  final String outcome;

  final String error;

  /// True when the job had already settled — a no-op, not a failure.
  final bool alreadySettled;

  /// True when the engine no longer carries a killable row under that id.
  final bool notFound;

  const JobStopResult({
    required this.ok,
    this.outcome = '',
    this.error = '',
    this.alreadySettled = false,
    this.notFound = false,
  });
}

/// One chunk of a background job's output ring.
///
/// [at] is the chunk's absolute byte offset and never moves once assigned, which
/// is what makes the viewer resumable. [gapBefore] means the bytes immediately
/// before this chunk were lost at the producer or to retention.
class JobLogLine {
  final int at;
  final String text;

  /// 'stdout' | 'stderr' | 'log' | '' (the producer supplied no label).
  final String channel;
  final bool gapBefore;

  const JobLogLine({
    required this.at,
    required this.text,
    this.channel = '',
    this.gapBefore = false,
  });

  factory JobLogLine.fromJson(Map<String, dynamic> json) => JobLogLine(
        at: _int(json['at']) ?? 0,
        text: json['text']?.toString() ?? '',
        channel: json['channel']?.toString() ?? '',
        gapBefore: json['gapBefore'] == true,
      );
}

/// One poll of a background job's output (engine stream `job/follow`).
class JobOutputChunk {
  final bool ok;
  final List<JobLogLine> lines;

  /// The cursor for the next poll. Null means the engine never reported an
  /// offset, so the viewer must restart rather than send a bogus `from`.
  final int? next;

  /// True when ANY frame reported lost bytes — the log is incomplete somewhere,
  /// so the viewer must not present itself as complete.
  final bool lossy;

  /// True only when the terminal `status` frame arrived. A live job has none, so
  /// this stays false instead of reading "no status" as "finished".
  final bool settled;

  /// The job's projection, when the stream carried an `opened`/`status` anchor.
  final JobItem? job;
  final String error;

  const JobOutputChunk({
    required this.ok,
    this.lines = const <JobLogLine>[],
    this.next,
    this.lossy = false,
    this.settled = false,
    this.job,
    this.error = '',
  });

  factory JobOutputChunk.fromJson(Map<String, dynamic> json) {
    final raw = json['lines'];
    final job = json['job'];
    return JobOutputChunk(
      ok: json['ok'] == true,
      lines: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => JobLogLine.fromJson(Map<String, dynamic>.from(e)))
              .toList(growable: false)
          : const <JobLogLine>[],
      next: _int(json['next']),
      lossy: json['lossy'] == true,
      settled: json['settled'] == true,
      job: job is Map ? JobItem.fromJson(Map<String, dynamic>.from(job)) : null,
      error: json['error']?.toString() ?? '',
    );
  }
}

/// Outcome of a session fork (P1-8).
class ForkOutcome {
  final bool ok;

  /// The newly created session id, when [ok].
  final String sessionId;
  final String error;

  /// True for the engine's 409 `fork-unavailable`: the anchor's turn never
  /// completed. The picker avoids it, so this is a race, not a user error.
  final bool unavailable;

  const ForkOutcome({
    required this.ok,
    this.sessionId = '',
    this.error = '',
    this.unavailable = false,
  });
}

/// Tolerant int parsing: accepts int, double and numeric strings.
int? _int(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}
