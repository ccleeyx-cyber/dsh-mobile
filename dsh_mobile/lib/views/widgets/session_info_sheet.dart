import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/bridge_extras.dart';
import '../../models/task_center.dart';
import '../../theme/app_colors.dart';
import 'deliverable_preview_sheet.dart';
import 'session_status_strip.dart';
import 'turn_output_card.dart';

/// 会话信息面板：状态条点开后的详情。
///
/// 它是"状态进头"那一半的展开态。选底部弹层而不是就地展开，是因为这里的
/// 内容长度不可控（一个长会话可能有几十个交付物和几十个改动文件），就地展开
/// 会把正在读的消息流顶走；弹层自带滚动，关掉即回到原来的滚动位置。
///
/// 组件是**自包含**的：数据全靠参数传进来，动作全靠回调传出去。它自己不读
/// `DshService`，所以在任何宿主里都能被单独渲染与断言（见
/// `test/widgets/session_insights_test.dart`）。
///
/// 三条与"诚实"有关的规则，都有对应测试：
/// 1. **作业"读不到"≠"没有"**：网关 `jobs` 路由降级时会回 `degraded:
///    'jobs-unavailable'`，这是"未知"，必须渲染成"状态未知"而不是"没有后台作业"。
/// 2. **本轮消耗取不到就显示 `—`**，绝不显示 0。
/// 3. **工作区不是 git 仓库 ≠ 没有改动**：不给空清单，给一条说明。
class SessionInfoSheet extends StatefulWidget {
  const SessionInfoSheet({
    super.key,
    this.stats,
    this.turnBurnTokens,
    this.deliverables = const <DeliverableItem>[],
    this.changes = const <WorkspaceChange>[],
    this.changesAvailable = false,
    this.changesReason = '',
    this.changesSource = '',
    this.changesNote = '',
    this.repoCandidates = const <RepoCandidate>[],
    this.jobs = const <JobItem>[],
    this.jobsUnavailable = false,
    this.schedules = const <ScheduleItem>[],
    this.busyDeliverablePath,
    this.initialSection = SessionInsightSection.usage,
    this.onOpenDeliverable,
    this.onPreviewDeliverable,
    this.onLoadDiff,
    this.onKillJob,
    this.onLoadJobOutput,
    this.onDeleteSchedule,
    this.onRefresh,
    this.subagents,
    this.subagentsUnavailable = false,
    this.onInterruptSubagent,
    this.team,
    this.teamUnavailable = false,
    this.onControlGoal,
    this.onRunDiagnostics,
    this.diagnostics,
    this.diagnosticsBusy = false,
  });

  /// 用量 / 上下文 / goal。`null` 表示还没取到。
  final SessionStats? stats;

  /// 本轮的 token 消耗（`SessionStats.turnDelta` 的结果）。`null` = 未知。
  final int? turnBurnTokens;

  final List<DeliverableItem> deliverables;

  final List<WorkspaceChange> changes;

  /// 变更清单是否可用（非 git 仓库时为 false）。
  final bool changesAvailable;

  /// 不可用的原因（网关的 `reason`）。
  final String changesReason;

  /// [feat 2026-10-13] 变更行的来源：`git` / `git+tool-calls` / `tool-calls`，
  /// 空串 = 老网关没给（此时不编来源，什么都不说）。
  ///
  /// 需要它是因为清单里可能混着两种行：git 的工作树状态（有行数）和会话日志里
  /// Agent 自己的 `write`/`edit`（**没有**行数）。不说来源，用户无法理解为什么
  /// 同一个列表里有的行有 "±行数"、有的只有一个 "—"。
  final String changesSource;

  /// [feat 2026-10-13] 网关给的一句话说明，解释"为什么 git 这里是空的"。
  ///
  /// 例：`当前工作区不是 git 仓库，但相邻有 2 个仓库；下方文件列表来自本轮
  /// Agent 的文件写入记录`。这是**解释性**的一句，永远优先于本地拼的通用文案
  /// —— 泛泛的"暂不可用"说不清"读不到"和"工作区干净"的区别。
  final String changesNote;

  /// [feat 2026-10-13] 会话工作区相邻的 git 仓库。
  ///
  /// **只能当标签渲染，没有任何可点的目标**：网关刻意不下发绝对路径（这是不
  /// 泄露主机目录结构的前提），所以这里既没有可打开的路径，也没有可切换的
  /// 工作区 —— 它只是在解释"git 明明有东西，只是不在这一层"。
  final List<RepoCandidate> repoCandidates;

  final List<JobItem> jobs;

  /// 作业状态**未知**（网关降级）。与"没有作业"是两件事。
  final bool jobsUnavailable;

  /// [feat 2026-10-13] 按字节偏移读取一个后台任务的输出（引擎 `job/follow`）。
  ///
  /// 为什么需要它：引擎的 job 输出是一个**可按偏移续读的环**，手机看日志的唯一
  /// 正确姿势就是拿着上一次的 `next` 继续读。为 null 时整块日志入口隐藏（老网关
  /// 没有这个路由），而不是给一个点了报错的按钮。
  final Future<JobOutputChunk> Function(JobItem job, int? from)? onLoadJobOutput;

  final List<ScheduleItem> schedules;

  final String? busyDeliverablePath;

  /// 打开时滚到哪一段（状态条哪一段被点的）。
  final SessionInsightSection initialSection;

  final ValueChanged<DeliverableItem>? onOpenDeliverable;

  /// [feat 2026-10-13] **就地预览**交付物的文本内容（P0-4）。
  ///
  /// 调用方（`chat_view.dart`）传的是 `(item) => dsh.fetchDeliverableText(item.path)`。
  /// 为 null 时**一点旧行为都不改**：点一行还是走"下载 + 拉起系统应用"那条链路。
  /// 非 null 时主点击改成预览，下载退到**长按**（见 [_buildDeliverableGroup] 的
  /// 注释说明为什么选长按而不是再加一个下载图标）。
  final Future<TextFileContent> Function(DeliverableItem item)? onPreviewDeliverable;

  /// 取单个文件的 diff。
  final Future<List<DiffHunk>> Function(String path)? onLoadDiff;

  /// 请求停止一个后台作业。
  ///
  /// 返回 [JobStopResult] 而不是 bool：引擎**没有任何**能停作业的 Remote（网关
  /// 过去调的 `job/kill` 在引擎的 74 个 Remote 里根本不存在，这就是这个列表过去
  /// 永远报 `degraded` 的同一条根因）。网关只能把请求转交给 Agent 自己的作业
  /// 工具，所以 `mediated == true` 时界面必须说"已请求 Agent 停止（会消耗一轮
  /// 对话）"，**不能**说"已终止" —— 那一刻作业还在跑。
  final Future<JobStopResult> Function(JobItem job)? onKillJob;

  final Future<void> Function(ScheduleItem schedule)? onDeleteSchedule;

  /// 打开面板时（以及点刷新时）拉取懒加载的那部分：后台作业 / 定时任务。
  ///
  /// 这两个是**最贵**的两个请求（`jobs` 是一次带 5s 超时的流 RPC，
  /// `schedules` 是一次 RPC），所以只在用户明确要看的时候拉，不在进会话时拉。
  final Future<void> Function()? onRefresh;

  // ---- [feat 2026-10-12] 子代理 / goal 操作 / 一键诊断 ----

  /// 子代理列表。`null` 表示引擎没有列出能力或读取失败（隐藏区块，不显示假空表）。
  final List<SubagentItem>? subagents;

  /// true = 还没拉到或拉取失败（与"确定没有子代理"区分开）。
  final bool subagentsUnavailable;

  /// 中断一个子代理（仅 continuable 行会显示按钮）。
  final Future<bool> Function(SubagentItem sub)? onInterruptSubagent;

  /// [feat 2026-10-16] 智能体团队快照（Lead + 队友 + 共享任务板）。
  ///
  /// 与 [subagents] 的分工：子代理 = 我派出去的一次委派；团队 = 有名有姓的
  /// 队友 + 共享任务板。队友同时也会出现在子代理列表里，两个区块都要显示。
  ///
  /// `null` = 拉取失败（显示"状态未知"）；`supported == false` = 引擎没装团队
  /// 能力；`isEmpty` = 这个会话确实不是团队会话。
  final AgentTeam? team;

  /// true = 拉取失败（区别于"确定没有团队"）。
  final bool teamUnavailable;

  /// goal 操作（pause/resume/complete）。引擎拒绝时返回 false，界面提示。
  final Future<bool> Function(String action, GoalInfo goal)? onControlGoal;

  /// 运行一键诊断。
  final Future<DiagnosticsReport?> Function()? onRunDiagnostics;

  /// 最近一次诊断报告。
  final DiagnosticsReport? diagnostics;

  final bool diagnosticsBusy;

  @override
  State<SessionInfoSheet> createState() => _SessionInfoSheetState();
}

class _SessionInfoSheetState extends State<SessionInfoSheet> {
  final _usageKey = GlobalKey();
  final _deliverablesKey = GlobalKey();
  final _changesKey = GlobalKey();
  final _jobsKey = GlobalKey();
  final _schedulesKey = GlobalKey();
  final _subagentsKey = GlobalKey();
  final _teamKey = GlobalKey();
  final _diagnosticsKey = GlobalKey();
  bool _refreshing = false;
  String? _interruptingId;
  String? _goalActionInProgress;

  /// [feat 2026-10-16] 展开的队友 id。团队可能十几个队友（实测 8 名），默认
  /// 折叠成一行摘要，按需展开 —— 不占满整屏把用量/作业挤下去。
  final Set<String> _expandedTeammates = {};

  /// [feat 2026-10-13] 作业列表里至少有一个"还活着"的作业时，用 1s 的 ticker 让
  /// 时长往前走。只在有活作业时开，自己 `dispose` 时一定取消 —— 一个没人看的
  /// 定时器在弹层关掉之后继续跑，既是电也是"关掉了还在刷新"的假象。
  Timer? _jobTicker;

  /// 行数据是"取数那一刻"的快照：`durationMs` 是网关算的 `now - startedAt`，
  /// 它自己不会长。跳动要在它**上面**加上"距离取数过了多久"，所以这里记下这份
  /// jobs 是什么时候拿到的（列表换一份就重置）。
  DateTime _jobsAnchor = DateTime.now();

  /// 上一次「停止作业」的结果。**内联渲染**，不用 SnackBar。
  ///
  /// 这个面板本身就是弹层，而 SnackBar 挂在宿主 Scaffold 上 —— 会被弹层盖住，
  /// 用户根本看不到自己刚按下去的那个按钮的结果（TurnOutputCard 里"错误内联在
  /// 卡片里"是同一个理由）。
  String? _jobStopNotice;
  bool _jobStopNoticeError = false;

  @override
  void initState() {
    super.initState();
    _syncJobTicker();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollTo(widget.initialSection);
      _refresh();
    });
  }

  @override
  void didUpdateWidget(covariant SessionInfoSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.jobs, widget.jobs)) {
      // 换了一份行数据 = 重新取过数：时长的锚点跟着重置。
      _jobsAnchor = DateTime.now();
    }
    _syncJobTicker();
  }

  @override
  void dispose() {
    _jobTicker?.cancel();
    _jobTicker = null;
    super.dispose();
  }

  /// 按"列表里还有没有活作业"开关 ticker。
  void _syncJobTicker() {
    final needsTick = widget.jobs.any((job) => job.isLive);
    if (needsTick && _jobTicker == null) {
      _jobTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!needsTick && _jobTicker != null) {
      _jobTicker!.cancel();
      _jobTicker = null;
    }
  }

  GlobalKey? _keyFor(SessionInsightSection section) {
    switch (section) {
      case SessionInsightSection.usage:
        return _usageKey;
      case SessionInsightSection.deliverables:
        return _deliverablesKey;
      case SessionInsightSection.changes:
        return _changesKey;
      case SessionInsightSection.jobs:
        return _jobsKey;
      case SessionInsightSection.schedules:
        return _schedulesKey;
    }
  }

  void _scrollTo(SessionInsightSection section) {
    // 目标小节不存在（例如非 git 仓库时变更清单不可用、或没有作业）时静默跳过，
    // 而不是抛异常或滚到一个不存在的锚点。
    final ctx = _keyFor(section)?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 240), alignment: 0.02);
  }

  Future<void> _refresh() async {
    final refresh = widget.onRefresh;
    if (refresh == null || _refreshing) return;
    setState(() => _refreshing = true);
    try {
      await refresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _openDiff(WorkspaceChange change) async {
    final loader = widget.onLoadDiff;
    if (loader == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _DiffSheet(change: change, loader: () => loader(change.path)),
    );
  }

  /// 就地预览一个交付物（P0-4）。
  ///
  /// 只在拿到了 `onPreviewDeliverable` 时才会被调到；没有它时行上走的仍是原来的
  /// 下载链路。预览弹层的下载出口复用同一个 `onOpenDeliverable`，所以两条路
  /// 永远是同一份实现（不会出现"预览里能下载、列表里下载不动"）。
  Future<void> _openDeliverablePreview(DeliverableItem item) async {
    final loader = widget.onPreviewDeliverable;
    if (loader == null) return;
    final open = widget.onOpenDeliverable;
    // 弹层本体挪到 `deliverable_preview_sheet.dart`：消息流那两个入口也要用它，
    // 三处共用一份实现才不会出现"同一个文件在三处行为不一样"。
    await showDeliverablePreview(
      context,
      item: item,
      loader: () => loader(item),
      onDownload: open == null ? null : () => open(item),
    );
  }

  /// 停止一个后台作业的确认与结果处理（P1-6）。
  ///
  /// 引擎**没有**停止作业的 Remote，所以这里发出去的是"请 Agent 去停"，结果以
  /// [JobStopResult] 回来 —— 三种结局必须分开说：已请求（mediated，作业还在跑，
  /// 且会消耗一轮对话）、已停止、已经结束了（409，是正常事态而不是错误）。
  Future<void> _confirmKillJob(JobItem job) async {
    final kill = widget.onKillJob;
    if (kill == null) return;
    final name = job.label.isEmpty ? job.id : job.label;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('终止这个后台作业？'),
        // 点之前就说清"这不是立刻生效的硬杀"，否则按钮的文字会承诺一件做不到的事。
        content: Text('引擎没有直接的停止接口，将请求 Agent 终止「$name」——'
            '这会占用一轮对话，作业不会立刻结束。已经产生的结果不会回滚。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('终止')),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;

    JobStopResult result;
    try {
      result = await kill(job);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _jobStopNoticeError = true;
        _jobStopNotice = '终止请求失败：$e';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      if (result.ok) {
        // ⚠️ `requested` 是引擎"已受理"，不是"已终止"：生产者的 cancel 是异步的，
        // 紧接着的一次列表读取里任务仍可能是活的。所以措辞是"已请求停止"，并且
        // 提示用户列表可能还会短暂显示它 —— 报"已终止"就是撒谎。
        _jobStopNoticeError = false;
        _jobStopNotice = result.outcome == 'requested'
            ? '已请求停止「$name」——停止是异步的，列表可能还会短暂显示它。'
            : '已终止「$name」。';
      } else if (result.alreadySettled) {
        // `already-finished`：这是"不用做"，不是失败，不该渲染成红色错误。
        _jobStopNoticeError = false;
        _jobStopNotice = '该后台任务已经结束，无需停止。';
      } else if (result.notFound) {
        // `job/not-found`：本会话的可停止列表里已经没有这一行了。
        _jobStopNoticeError = false;
        _jobStopNotice = '该后台任务已不在本会话的可停止列表中。';
      } else {
        _jobStopNoticeError = true;
        _jobStopNotice = result.error.isNotEmpty ? result.error : '停止请求被拒绝或未送达。';
      }
    });
  }

  Future<void> _confirmDeleteSchedule(ScheduleItem schedule) async {
    final del = widget.onDeleteSchedule;
    if (del == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除定时任务？'),
        content: Text('将删除「${schedule.title.isEmpty ? schedule.id : schedule.title}」。之后不会再触发提醒。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await del(schedule);
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.85;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 3,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      color: context.c.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '会话信息',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                    ),
                  ),
                  if (_refreshing)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (widget.onRefresh != null)
                    IconButton(
                      key: const ValueKey('session-info-refresh'),
                      tooltip: '刷新作业与定时',
                      icon: Icon(Icons.refresh_rounded, size: 20, color: context.c.textSecondary),
                      onPressed: _refresh,
                    ),
                  IconButton(
                    tooltip: '关闭',
                    icon: Icon(Icons.close_rounded, size: 20, color: context.c.textSecondary),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: context.c.border),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    KeyedSubtree(key: _usageKey, child: _buildUsage()),
                    KeyedSubtree(key: _deliverablesKey, child: _buildDeliverables()),
                    KeyedSubtree(key: _changesKey, child: _buildChanges()),
                    KeyedSubtree(key: _jobsKey, child: _buildJobs()),
                    // [feat 2026-10-16] 智能体团队。放在子代理**之前**：团队是更高
                    // 层的组织视图，用户先想知道"谁在干活"，再看具体委派。
                    if (widget.team != null || widget.teamUnavailable)
                      KeyedSubtree(key: _teamKey, child: _buildTeam()),
                    // [feat 2026-10-12] 子代理区块。引擎没有列出能力/读取失败时
                    // 返回 null —— 整块隐藏，绝不显示一张假空表。
                    if (widget.subagents != null)
                      KeyedSubtree(key: _subagentsKey, child: _buildSubagents()),
                    KeyedSubtree(key: _schedulesKey, child: _buildSchedules()),
                    // [feat 2026-10-12] 一键连接诊断。
                    KeyedSubtree(key: _diagnosticsKey, child: _buildDiagnostics()),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 用量 ----

  Widget _buildUsage() {
    final stats = widget.stats;
    final children = <Widget>[];

    if (stats == null || stats.source == 'none') {
      children.add(_hint('还没有用量记录 —— 这个会话还没跑过模型请求。'));
    } else {
      final fraction = stats.contextFraction;
      if (fraction != null) {
        children.add(ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 5,
            backgroundColor: context.c.surfaceMuted,
            valueColor: AlwaysStoppedAnimation(
              fraction >= SessionStatusStrip.pressureCriticalThreshold
                  ? context.c.danger
                  : (fraction > SessionStatusStrip.pressureLineThreshold ? context.c.warning : context.c.success),
            ),
          ),
        ));
        children.add(const SizedBox(height: 6));
        children.add(Text(
          // 千分位/M 都作用到这一行：它以前是整块面板里唯一剩下的裸整数，窗口直接
          // 显示成 `1000000`，而正确的读法就是 `1M`（用户点名要求的口径）。
          '上下文已用 ${_compact(stats.pressureTokens!)} / ${_compact(stats.contextWindow!)}'
          '${stats.projectedTokens != null ? ' · 下一轮预计 ${_compact(stats.projectedTokens!)}' : ''}',
          style: TextStyle(fontSize: 11.5, color: context.c.textSecondary),
        ));
      }

      children.add(const SizedBox(height: 10));
      // 常驻噪声（缓存读/写、未缓存输入、输出四格）已经砍掉——它们对手机上唯一
      // 的三个决策（继续 / 新开会话 / 放弃）没有可行动价值。这里只留三行。
      children.add(_metricRow('本轮消耗', _formatTurnBurn(widget.turnBurnTokens)));
      // 「消耗」= 未缓存输入 + 输出。**不能**用 totalTokens：它还包含缓存读，
      // 而缓存读是同一段上下文被反复重读，会把数字吹大一个量级（用户实测
      // 11.08M 输入 + 0.34M 输出 + 193.46M 缓存读），显示成 205M 完全不是消耗。
      final consumed = stats.consumedTokens;
      children.add(_metricRow('会话累计消耗', consumed == null ? '—' : _compact(consumed)));
      if (stats.hasCacheReuse) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 2),
          child: _hint('另有缓存复用 ${_compact(stats.cacheReadTokens ?? 0)}'
              '${(stats.cacheWriteTokens ?? 0) > 0 ? ' + 写入 ${_compact(stats.cacheWriteTokens!)}' : ''}'
              '${stats.cacheHitPercent != null ? '（命中 ${stats.cacheHitPercent}%）' : ''}'
              '（重复读取的上下文，不计入上面的消耗）。'),
        ));
      }
      // [feat 2026-10-17] 电脑端「会话统计」那组数字：轮/步、输出速度、模型/工具用时。
      //
      // 用户点名要"用量信息跟电脑端一样显示"。这几条以前只在电脑端有 —— 手机上既没有
      // 轮/步总量（只有窗口内那几轮，自己数会算成 1 轮），也没有速度与用时。
      // 读不到就整段不出现（老网关没有这个投影），绝不补 `0 轮 0 步`。
      final counters = stats.counters;
      if (counters != null && (counters.steps ?? 0) > 0) {
        // 与电脑端同一排版：`6 轮 351 步 · 210 tok/s` —— 轮与步之间是**空格**，
        // 速度才是 ` · ` 分隔的第二组。别用同一个分隔符把三段平铺（那是另一种读法）。
        final counts = <String>[
          if (counters.turns != null) '${counters.turns} 轮',
          if (counters.steps != null) '${counters.steps} 步',
        ].join(' ');
        final tps = stats.tokensPerSecond;
        children.add(const SizedBox(height: 4));
        children.add(_metricRow(
          '会话统计',
          tps == null ? counts : '$counts · ${SessionStatusStrip.formatTokensPerSecond(tps)} tok/s',
        ));

        final durations = <String>[
          if ((counters.llmMs ?? 0) > 0) '模型用时 ${_shortDuration(counters.llmMs!)}',
          if ((counters.toolMs ?? 0) > 0) '工具调用 ${_shortDuration(counters.toolMs!)}',
          // 首 token 平均：引擎给的是总量 + 步数，电脑端也是这么除的。
          if ((counters.ttftMs ?? 0) > 0 && (counters.ttftSteps ?? 0) > 0)
            '首 token 平均 ${_shortDuration(counters.ttftMs! ~/ counters.ttftSteps!)}',
        ];
        if (durations.isNotEmpty) {
          children.add(Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _hint(durations.join(' · ')),
          ));
        }
      }

      if (widget.turnBurnTokens == null) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 2),
          child: _hint('本轮消耗取不到实时读数时显示「—」而不是 0：0 会被读成"这轮没花钱"。'),
        ));
      }

      children.add(const SizedBox(height: 6));
      children.add(_hint(stats.isSnapshot
          ? '上下文数值来自投影缓存快照（会话当前不在内存中，是最后一次上报的值）。'
          : '数值来自引擎的 token 计量投影（提供方上报值）。'));
    }

    final goal = stats?.goal;
    if (goal != null) {
      children.add(const SizedBox(height: 12));
      children.add(Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: context.c.surfaceMuted,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.c.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.flag_rounded, size: 14, color: context.c.accent),
                const SizedBox(width: 6),
                Text('目标 · ${goal.phaseLabel}',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.c.textPrimary)),
                const Spacer(),
                if (goal.roundsStarted != null)
                  Text(
                    '第 ${goal.roundsStarted}${goal.maxGoalRounds != null ? '/${goal.maxGoalRounds}' : ''} 轮',
                    style: TextStyle(fontSize: 11, color: context.c.textTertiary),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(goal.objective, style: TextStyle(fontSize: 12, color: context.c.textSecondary, height: 1.35)),
            if (goal.blockedReason != null) ...[
              const SizedBox(height: 4),
              Text('受阻：${goal.blockedReason}', style: TextStyle(fontSize: 11.5, color: context.c.danger)),
            ],
            // [feat 2026-10-12] 暂停/继续/完成。只在拿得到引擎 CAS ref（id+revision）
            // 时出现：没有 ref 的按钮会带着猜测的目标发 RPC，宁可不显示。
            if (goal.operable && widget.onControlGoal != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (goal.phase == 'active')
                    _goalAction('暂停', 'pause', goal, key: const ValueKey('goal-pause'))
                  else if (goal.phase == 'paused' || goal.phase == 'blocked')
                    _goalAction('继续', 'resume', goal, key: const ValueKey('goal-resume')),
                  if (goal.phase != 'complete') ...[
                    const SizedBox(width: 8),
                    _goalAction('完成', 'complete', goal, key: const ValueKey('goal-complete')),
                  ],
                ],
              ),
            ],
          ],
        ),
      ));
    }

    return _section(title: '用量与上下文', icon: Icons.data_usage_rounded, children: children);
  }

  /// 一个 goal 操作按钮。执行中转圈；引擎拒绝给一条明确的失败说明。
  Widget _goalAction(String label, String action, GoalInfo goal, {Key? key}) {
    final busy = _goalActionInProgress == action;
    return TextButton(
      key: key,
      onPressed: busy ? null : () => _doGoalAction(action, goal),
      style: TextButton.styleFrom(
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        backgroundColor: context.c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: context.c.border),
        ),
      ),
      child: busy
          ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
          : Text(label, style: TextStyle(fontSize: 11.5, color: context.c.textPrimary)),
    );
  }

  Future<void> _doGoalAction(String action, GoalInfo goal) async {
    final handler = widget.onControlGoal;
    if (handler == null) return;
    setState(() => _goalActionInProgress = action);
    try {
      final ok = await handler(action, goal);
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('引擎拒绝了这次目标操作（$action）——目标可能已被模型侧修改，刷新后重试'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _goalActionInProgress = null);
    }
  }

  String _formatTurnBurn(int? burn) => burn == null ? '—' : _compact(burn);

  /// 短时长：`0.9s` / `45s` / `2m05s`。
  ///
  /// 与电脑端 `formatDuration` 同一口径（10 秒以下保留一位小数，分钟按 `m分s秒`）。
  /// 引擎给的是毫秒总量，所以先除法再格式化。
  static String _shortDuration(int ms) {
    final total = ms < 0 ? 0 : ms;
    if (total < 60000) {
      final seconds = total / 1000;
      return seconds >= 10 ? '${seconds.round()}s' : '${seconds.toStringAsFixed(1)}s';
    }
    final minutes = total ~/ 60000;
    final seconds = (total % 60000) ~/ 1000;
    return '${minutes}m${seconds.toString().padLeft(2, '0')}s';
  }

  /// 千分位。自己写四行而不是引 intl：这个包里没有这个依赖，也不值得为它加。
  static String _group(int value) {
    final digits = value.abs().toString();
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return value < 0 ? '-$out' : out.toString();
  }

  /// token 量级的显示单位：**一百万写作 `1M`**（用户明确指定的口径）。
  ///
  /// 用 M 而不是继续摊开长数字，是因为这一屏要回答的只有"离上限还有多远、这轮
  /// 贵不贵"——`1000000` 与 `1M` 是同一件事，但后者一眼可读。
  ///
  /// 阈值刻意只放在 1e6：小于一百万的量级继续给精确值 + 千分位。把 12,345 写成
  /// `0.0M` 纯粹是丢信息，而"30 万 / 90 万"这类差别用千分位反而更好读。
  static String _compact(int value) {
    if (value.abs() < 1000000) return _group(value);
    final millions = value / 1000000;
    var text = millions.toStringAsFixed(1);
    // `1.0M` → `1M`：整兆不必带那个 .0。
    if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
    return '${text}M';
  }

  // --------------------------------------------------------- 交付物 ----

  Widget _buildDeliverables() {
    final groups = groupDeliverablesByTurn(widget.deliverables);
    // 只有**两条路都通**时才需要教用户手势：只有预览没下载时说明不了什么，
    // 只有下载时更不需要（旧行为本来就是"点一下就下载"）。
    final needsHint = groups.isNotEmpty &&
        widget.onPreviewDeliverable != null &&
        widget.onOpenDeliverable != null;
    return _section(
      title: '交付物',
      icon: Icons.folder_special_rounded,
      children: [
        if (groups.isEmpty)
          _hint('这次任务还没有声明交付文件。agent 交付 docx/xlsx/pdf 时会出现在这里。')
        else ...[
          if (needsHint) _hint('点文件名就地预览内容；长按仍走下载 / 用其它应用打开。'),
          // 按轮倒序分组，**默认只展开最新一轮**：长会话可能声明过几十个文件，
          // 而用户要的是"刚给我的那批"。其余轮次折起来但不隐藏。
          for (var i = 0; i < groups.length; i++) _buildDeliverableGroup(groups[i], i == 0),
        ],
      ],
    );
  }

  Widget _buildDeliverableGroup(DeliverableGroup group, bool expanded) {
    final preview = widget.onPreviewDeliverable;
    final open = widget.onOpenDeliverable;
    final rows = <Widget>[
      for (final item in group.items)
        // 主点击 = 预览（拿到预览回调时），下载退到**长按**。
        //
        // 选长按而不是"再加一个小下载图标按钮"：DeliverableRow 尾部本来就画了
        // 一个下载图标，旁边再放一个可点的下载按钮，等于把同一个图标画两遍、
        // 其中只有一个能点 —— 那比手势难发现更糟。长按是这个行上唯一不与主
        // 点击冲突、也不新增视觉噪声的第二动作位。
        GestureDetector(
          onLongPress: (preview != null && open != null) ? () => open(item) : null,
          child: DeliverableRow(
            item: item,
            dense: true,
            busy: widget.busyDeliverablePath != null && widget.busyDeliverablePath == item.path,
            onOpen: preview != null
                ? () => _openDeliverablePreview(item)
                : (open == null ? null : () => open(item)),
          ),
        ),
    ];

    final label = group.turnLabel == null
        ? '轮次未记录 · ${group.items.length} 个文件'
        : '${group.turnLabel} · ${group.items.length} 个文件';

    if (!expanded) {
      return Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: ValueKey('deliverable-group-${group.turn}'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 4),
          title: Text(label, style: TextStyle(fontSize: 12, color: context.c.textSecondary)),
          children: rows,
        ),
      );
    }

    return Column(
      key: ValueKey('deliverable-group-${group.turn}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 2),
          child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.c.textPrimary)),
        ),
        ...rows,
      ],
    );
  }

  // --------------------------------------------------------- 变更 ----

  /// 本次变更**只能**按"当前工作区状态"处理，不能按轮拆分。
  ///
  /// 这是数据事实，不是取舍：`GET /api/mobile/workspace/changes` 返回的是
  /// `git status` 的**当前工作树**真值（整个工作区的累计状态），而引擎自己的
  /// `workspace/changes` 事件只带一个轮号、快照留在 Host 侧不可回放。也就是说
  /// "第 3 轮改了哪两个文件"这个数据在当前架构里**不存在**。所以变更清单只出现在
  /// 状态层（状态条计数 + 这里），不会像交付物那样拆到每轮消息后面 —— 那样做
  /// 等于编数据。
  Widget _buildChanges() {
    final note = widget.changesNote.trim();
    final children = <Widget>[];

    if (!widget.changesAvailable) {
      // 不可用**不等于**干净 —— 这两件事必须永远分得开。
      //
      // 优先说网关给的 note：它才是那句真正解释"为什么 git 这里是空的"的话
      // （例："当前工作区不是 git 仓库，但相邻有 2 个仓库；下方文件列表来自本轮
      // Agent 的文件写入记录"）。本地拼的通用文案只是 note 缺席时的兜底。
      children.add(_changesBanner(note.isNotEmpty ? note : _changesFallbackReason()));
    } else if (note.isNotEmpty) {
      // 有内容也可能带说明：清单里混了"没有行数的 Agent 写入行"时，note 就是
      // 用来解释这个的，必须显示在列表**上方**而不是折叠起来。
      children.add(_changesBanner(note));
    }

    if (widget.repoCandidates.isNotEmpty) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 8));
      children.add(_buildRepoCandidates());
    }

    if (widget.changesAvailable) {
      if (widget.changes.isEmpty) {
        children.add(_hint('工作区是干净的 —— 没有未提交改动。'));
      } else {
        if (children.isNotEmpty) children.add(const SizedBox(height: 8));
        final source = _changesSourceCaption();
        if (source != null) children.add(_hint(source));
        for (final change in widget.changes) { children.add(_buildChangeRow(change)); }
      }
    }

    return _section(title: '本次变更', icon: Icons.difference_rounded, children: children);
  }

  /// note 缺席时用来解释"读不到"的兜底文案。**只有**在这里才退回通用说法 ——
  /// 泛泛的"暂不可用"永远没有网关那句具体。
  String _changesFallbackReason() {
    if (widget.changesReason == 'not-a-git-repository') {
      return '这个工作区不是 git 仓库，列不出改动（引擎侧的变更快照不通过 RPC 暴露）。';
    }
    if (widget.changesReason.isNotEmpty) return '变更清单暂不可用：${widget.changesReason}';
    return '变更清单暂不可用。';
  }

  /// 这份清单的来源说明。老网关不给 `source` 时返回 null —— 宁可不说话，不猜。
  String? _changesSourceCaption() {
    switch (widget.changesSource) {
      case 'git':
        return '来源：git 工作区状态（未提交改动）。';
      case 'git+tool-calls':
        return '来源：git 工作区状态 + 本轮 Agent 的文件写入记录；标了「Agent 写入」的行没有行数。';
      case 'tool-calls':
        return '来源：本轮 Agent 的文件写入记录（这个工作区不是 git 仓库，所以没有行级行数）。';
      default:
        return null;
    }
  }

  /// 解释性横幅。用 warning 系而不是 danger：这既不是失败也不是错误，只是
  /// "这里为什么是空的/为什么不完整"。
  Widget _changesBanner(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.c.warningSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.c.warningBorder),
      ),
      child: Text(
        text,
        key: const ValueKey('changes-note'),
        style: TextStyle(fontSize: 11.5, color: context.c.warning, height: 1.35),
      ),
    );
  }

  /// 相邻仓库的芯片行。
  ///
  /// **纯展示，一个都不可点**：网关只下发仓库名（工作区相对名），刻意不下发
  /// 绝对路径 —— 这是不泄露主机目录结构的前提。所以这里既没有可打开的路径，
  /// 也没有可切换的工作区，它只是在回答"git 明明有东西，只是不在这一层"。
  Widget _buildRepoCandidates() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('相邻仓库', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: context.c.textSecondary)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final repo in widget.repoCandidates)
              Container(
                key: ValueKey('repo-chip-${repo.name}'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: context.c.surfaceMuted,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: context.c.border),
                ),
                child: Text(repo.name, style: TextStyle(fontSize: 11, color: context.c.textSecondary)),
              ),
          ],
        ),
      ],
    );
  }

  /// 一行变更。两种来源长得**必须不一样**：git 的行有行数，Agent 写入的行没有。
  Widget _buildChangeRow(WorkspaceChange change) {
    // `fromToolCall` 的行来自会话日志里 Agent 自己的 write/edit 调用，它**没有**
    // git 行数（也就没有旧版本可比）。所以这里硬写 "—"，不碰 `change.delta`：
    // 万一网关某天给它回一个 0，`change.delta` 就会算成 "+0 −0"，那是在声称
    // "这个文件没变化"，而真相是"我们不知道它改了几行"。
    final fromToolCall = change.fromToolCall;
    final delta = fromToolCall ? '—' : change.delta;
    final tool = change.tool ?? '';
    final sourceHint = fromToolCall
        ? '来源：Agent 写入${tool.isNotEmpty ? '（$tool）' : ''}，会话日志没有行级改动'
        : null;

    VoidCallback? onTap;
    if (fromToolCall) {
      // 这类行**不发** diff 请求：它本来就不是 git 的一条状态，`onLoadDiff` 只会
      // 拿到空 hunk，渲染出来像"这个文件没有改动"。
      onTap = _explainToolCallRow;
    } else if (widget.onLoadDiff != null) {
      onTap = () => _openDiff(change);
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 34,
              child: Text(change.label,
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: context.c.warning)),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    change.path,
                    style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: context.c.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // 为什么这一行没有行数：不说清，用户只能把它读成"没改"。
                  if (sourceHint != null)
                    Text(sourceHint, style: TextStyle(fontSize: 10, color: context.c.textTertiary, height: 1.3)),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Text(delta, style: TextStyle(fontSize: 10.5, color: context.c.textTertiary)),
            const SizedBox(width: 4),
            // 这类行没有可展开的 diff，所以不画"能点开"的 chevron —— 画了就骗人。
            Icon(fromToolCall ? Icons.info_outline_rounded : Icons.chevron_right_rounded,
                size: 16, color: context.c.textTertiary),
          ],
        ),
      ),
    );
  }

  /// 点到一条"Agent 写入"行时给出的解释（它没有 git diff 可看）。
  void _explainToolCallRow() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('这一行来自本轮 Agent 的文件写入记录，没有对应的 git diff：'
          '会话日志只记了「哪个文件被写过」，不记行级改动。'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  // --------------------------------------------------------- 作业 ----

  Widget _buildJobs() {
    return _section(
      title: '后台作业',
      icon: Icons.memory_rounded,
      children: [
        if (widget.jobsUnavailable)
          // 未知 ≠ 没有。网关读不到作业列表时必须说出来，否则用户会以为
          // "一个作业都没在跑"，然后关掉手机走人。
          Row(
            children: [
              Icon(Icons.help_outline_rounded, size: 15, color: context.c.warning),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '作业状态未知（网关暂时读不到作业列表，不代表没有作业在跑）。',
                  key: const ValueKey('jobs-unknown'),
                  style: TextStyle(fontSize: 12, color: context.c.warning),
                ),
              ),
            ],
          )
        else if (widget.jobs.isEmpty)
          _hint('没有后台作业。长时间命令与子代理会在这里出现。')
        else
          for (final job in widget.jobs) _buildJobRow(job),
        // 停止请求的结果内联在这里（见 [_jobStopNotice] 的说明）。
        if (_jobStopNotice != null) _buildJobStopNotice(),
      ],
    );
  }

  /// 打开一个后台任务的输出查看器。
  ///
  /// 用 `showModalBottomSheet` 而不是新页面：日志要和作业列表一起看（列表会随
  /// 事件刷新，用户需要对照"哪个任务"，而不是在两级页面之间来回跳）。
  Future<void> _openJobLog(JobItem job) async {
    final load = widget.onLoadJobOutput;
    if (load == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _JobLogSheet(job: job, load: load),
    );
  }

  Widget _buildJobRow(JobItem job) {
    final color = _jobStatusColor(job);
    // kind / detail 都是可选的；一个都没有时不留一行空白。
    final meta = <String>[
      if (job.kind.isNotEmpty) job.kind,
      if ((job.detail ?? '').isNotEmpty) job.detail!,
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(right: 8, top: 1),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: color.withOpacity(0.5)),
            ),
            child: Text(
              job.statusLabel,
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job.label.isEmpty ? job.id : job.label,
                  style: TextStyle(fontSize: 12.5, color: context.c.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (meta.isNotEmpty)
                  Text(
                    meta.join(' · '),
                    style: TextStyle(fontSize: 10.5, color: context.c.textTertiary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // [feat 2026-10-13] 日志入口。
          //
          // 只要回调存在就显示（不要求 `hasOutput`）：一个刚起的活作业此刻 total
          // 可能还是 0，但它马上就要写输出 —— 按"现在有没有输出"来决定要不要给
          // 入口，会让入口在用户最需要它的那一刻恰好消失。
          if (widget.onLoadJobOutput != null)
            InkWell(
              key: ValueKey('job-log-${job.id}'),
              onTap: () => _openJobLog(job),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Icon(Icons.article_outlined, size: 15, color: context.c.accent),
              ),
            ),
          const SizedBox(width: 4),
          // 时长：活着的作业按秒走，结束的显示网关给的最终值；**取不到就 "—"**，
          // 绝不写 "0 秒"（0 会被读成"这个作业瞬间就结束了"）。
          Text(
            _jobDurationLabel(job),
            key: ValueKey('job-duration-${job.id}'),
            style: TextStyle(fontSize: 10.5, color: job.isLive ? context.c.success : context.c.textTertiary),
          ),
          if (job.isLive && widget.onKillJob != null)
            TextButton(
              onPressed: () => _confirmKillJob(job),
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              child: Text('终止', style: TextStyle(fontSize: 12, color: context.c.danger)),
            ),
        ],
      ),
    );
  }

  /// 状态 → 颜色，照引擎自己的语义映射。
  ///
  /// 刻意不再用 `isLive ? accent : tertiary`：那会让 `stopping`（已经在停、不可
  /// 逆，但还没结束）看起来和 `running` 一模一样；同理 `killed` 不是失败，用
  /// danger 会和真失败的作业混成一片。
  Color _jobStatusColor(JobItem job) {
    switch (job.status) {
      case 'running':
        return context.c.success;
      case 'stopping':
        return context.c.warning;
      case 'completed':
        return context.c.textSecondary;
      case 'killed':
        return context.c.warning;
      case 'failed':
        return context.c.danger;
      default:
        return context.c.textSecondary;
    }
  }

  /// 行内时长文案。
  ///
  /// 活着的作业：网关给的 `durationMs` 是"取数那一刻的已跑时长"，它自己不会走，
  /// 所以用 ticker 在它上面加上"距离取数过了多久"。**网关没给起点时显示「计时中」**
  /// 而不是从 0 往上跳 —— 从一个假的 0 开始数比承认不知道更糟。
  ///
  /// 已结束的作业：用网关的 `durationLabel`；它也是 null 时显示 "—"。
  String _jobDurationLabel(JobItem job) {
    if (!job.isLive) return job.durationLabel ?? '—';
    final base = job.durationMs;
    if (base == null) return '计时中';
    final elapsed = base + DateTime.now().difference(_jobsAnchor).inMilliseconds;
    return _durationText(elapsed);
  }

  /// 与 [JobItem.durationLabel] 同口径的时长格式化。
  ///
  /// 模型那个 getter 吃的是自己的字段，而 ticker 要喂一个算出来的值，所以这里
  /// 必须有一份；两处口径必须一致，否则同一行会"运行中显示 1 分 5 秒、结束后
  /// 跳成另一种写法"。
  static String _durationText(int ms) {
    final total = ms ~/ 1000;
    final s = total % 60;
    final m = (total ~/ 60) % 60;
    final h = total ~/ 3600;
    if (h > 0) return '$h 小时 $m 分';
    if (m > 0) return '$m 分 $s 秒';
    return '$s 秒';
  }

  Widget _buildJobStopNotice() {
    final color = _jobStopNoticeError ? context.c.danger : context.c.textSecondary;
    return Padding(
      key: const ValueKey('job-stop-notice'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_jobStopNoticeError ? Icons.error_outline_rounded : Icons.info_outline_rounded, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text(_jobStopNotice!, style: TextStyle(fontSize: 11.5, color: color, height: 1.35))),
        ],
      ),
    );
  }

  // ------------------------------------------------------- 定时任务 ----

  Widget _buildSchedules() {
    // 默认折叠：定时任务与"当前会话此刻是什么样"无关，它是"以后会被触发的东西"，
    // 用户设完基本不再看。给它一个常驻开着的区块就是拿一个几乎永远是 0 的清单
    // 去挤别人的位置。
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const ValueKey('schedules-section'),
        tilePadding: EdgeInsets.zero,
        title: Text('定时任务 ${widget.schedules.length}',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: context.c.textPrimary)),
        childrenPadding: const EdgeInsets.only(bottom: 6),
        children: [
          if (widget.schedules.isEmpty)
            _hint('没有定时任务。')
          else
            for (final s in widget.schedules)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.title.isEmpty ? s.id : s.title,
                              style: TextStyle(fontSize: 12.5, color: context.c.textPrimary)),
                          Text(
                            [s.schedule, if (s.kind.isNotEmpty) s.kind].where((e) => e.isNotEmpty).join(' · '),
                            style: TextStyle(fontSize: 11, color: context.c.textTertiary),
                          ),
                        ],
                      ),
                    ),
                    if (widget.onDeleteSchedule != null)
                      TextButton(
                        onPressed: () => _confirmDeleteSchedule(s),
                        style: TextButton.styleFrom(
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        ),
                        child: Text('删除', style: TextStyle(fontSize: 12, color: context.c.danger)),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  // ------------------------------------------------- 子代理 [feat 2026-10-12] ----

  Widget _buildSubagents() {
    final subs = widget.subagents;
    return _section(
      title: '子代理',
      icon: Icons.account_tree_rounded,
      children: [
        if (widget.subagentsUnavailable)
          Row(
            children: [
              Icon(Icons.help_outline_rounded, size: 15, color: context.c.warning),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  '子代理状态未知（引擎暂不可达，不代表没有子代理在跑）。',
                  key: ValueKey('subagents-unknown'),
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          )
        else if (subs == null || subs.isEmpty)
          _hint('没有子代理记录。委派出去的子任务会出现在这里。')
        else
          for (final sub in subs)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: (sub.isDiagnostic ? context.c.textTertiary : sub.isRunning ? context.c.accent : context.c.border).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      sub.isDiagnostic ? '异常' : (sub.isRunning ? '运行中' : '已结束'),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: sub.isDiagnostic ? context.c.textSecondary : sub.isRunning ? context.c.accent : context.c.textSecondary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      sub.isDiagnostic ? '${sub.displayLabel}（${sub.reason}）' : sub.displayLabel,
                      style: TextStyle(fontSize: 12.5, color: context.c.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // 引擎只接受 continuable 子代理的中断；one-shot 是终态的，
                  // 发了必拒 —— 按钮从一开始就不出现。
                  if (sub.interruptible && widget.onInterruptSubagent != null)
                    TextButton(
                      onPressed: _interruptingId == null ? () => _confirmInterruptSubagent(sub) : null,
                      style: TextButton.styleFrom(
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      ),
                      child: _interruptingId == sub.id
                          ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text('中断', style: TextStyle(fontSize: 12, color: context.c.danger)),
                    ),
                ],
              ),
            ),
      ],
    );
  }

  // ------------------------------------------- 智能体团队 [feat 2026-10-16] ----

  /// 队友徽标颜色：进行中用主色、创建中用弱化灰、失败用 danger。
  Color _teamPhaseColor(TeamMember m) {
    if (m.isFailed) return context.c.danger;
    if (m.isActive) return context.c.accent;
    return context.c.textTertiary;
  }

  Widget _buildTeam() {
    final team = widget.team;
    final children = <Widget>[];

    // 三种"没有团队"必须说不同的话：
    //   1. 拉取失败      → 状态未知（引擎可能正在跑，别让人以为队友全挂了）
    //   2. 引擎没这能力  → 明确说不是"你没团队"
    //   3. 确实不是团队会话 → 一句话带过
    if (widget.teamUnavailable || team == null) {
      children.add(Row(
        key: const ValueKey('team-unknown'),
        children: [
          Icon(Icons.help_outline_rounded, size: 15, color: context.c.warning),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '团队状态未知（网关暂不可达，不代表团队已解散）。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ));
      return _section(
        title: '智能体团队',
        icon: Icons.groups_rounded,
        children: children,
      );
    }

    if (!team.supported) {
      children.add(_hint('当前引擎未启用智能体团队能力。'));
      return _section(title: '智能体团队', icon: Icons.groups_rounded, children: children);
    }

    if (team.failure.isNotEmpty) {
      children.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 15, color: context.c.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              team.failure,
              key: const ValueKey('team-failure'),
              style: TextStyle(fontSize: 12, color: context.c.danger),
            ),
          ),
        ],
      ));
    }

    if (team.isEmpty) {
      children.add(_hint('这个会话没有智能体团队。'));
      return _section(title: '智能体团队', icon: Icons.groups_rounded, children: children);
    }

    final mates = team.teammates;
    // 顶部一行计数：多少人 / 多少任务。手机上比逐条列更快看出"跑到哪了"。
    children.add(Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          _chip('${team.members.length} 名成员',
              color: team.isWorking ? context.c.accent : context.c.textSecondary),
          const SizedBox(width: 6),
          if (team.tasks.isNotEmpty)
            _chip('${team.tasks.length} 个任务', color: context.c.textSecondary),
          const Spacer(),
          // source 徽标说明这份快照是引擎实时投影还是磁盘检查点 —— 两者可能
          // 有分钟级时差，用户问"怎么进度不一样"时这是第一个要看的东西。
          if (team.source == 'cache')
            Text('离线快照', style: TextStyle(fontSize: 10, color: context.c.textTertiary)),
        ],
      ),
    ));

    for (final m in mates) {
      children.add(_buildTeamMemberRow(m));
    }

    if (team.tasks.isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Text('共享任务板',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.c.textSecondary)),
      ));
      for (final t in team.tasks) {
        children.add(_buildTeamTaskRow(t));
      }
    }

    return _section(title: '智能体团队', icon: Icons.groups_rounded, children: children);
  }

  Widget _chip(String label, {required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }

  Widget _buildTeamMemberRow(TeamMember m) {
    final expanded = _expandedTeammates.contains(m.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _chip(m.phaseLabel, color: _teamPhaseColor(m)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  m.name,
                  key: ValueKey('team-member-${m.id}'),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: m.isLead ? FontWeight.w600 : FontWeight.normal,
                    color: context.c.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Lead 是会话自己，没有"他的进度"可点；队友可以展开看失败原因。
              if (m.error.isNotEmpty || (!m.isLead && m.isFailed))
                IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  padding: EdgeInsets.zero,
                  tooltip: expanded ? '收起' : '展开',
                  icon: Icon(
                    expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 18,
                    color: context.c.textSecondary,
                  ),
                  onPressed: () => setState(() {
                    if (expanded) {
                      _expandedTeammates.remove(m.id);
                    } else {
                      _expandedTeammates.add(m.id);
                    }
                  }),
                ),
            ],
          ),
          if (expanded && m.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 2),
              child: Text(
                m.error,
                key: ValueKey('team-member-error-${m.id}'),
                style: TextStyle(fontSize: 11.5, color: context.c.danger),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTeamTaskRow(TeamTask t) {
    final color = t.isCompleted
        ? context.c.success
        : (t.isInProgress ? context.c.accent : context.c.textSecondary);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _chip(t.statusLabel, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.subject.isEmpty ? t.description : t.subject,
                  key: ValueKey('team-task-${t.id}'),
                  style: TextStyle(fontSize: 12.5, color: context.c.textPrimary),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (t.ownerName.isNotEmpty || t.isBlocked)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      [
                        if (t.ownerName.isNotEmpty) '负责：${t.ownerName}',
                        if (t.isBlocked) '被阻塞',
                      ].join(' · '),
                      style: TextStyle(fontSize: 11, color: context.c.textTertiary),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmInterruptSubagent(SubagentItem sub) async {
    final handler = widget.onInterruptSubagent;
    if (handler == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('中断这个子代理？'),
        content: Text('将请求引擎停止「${sub.displayLabel}」当前的回合。它已排队但未发送的消息会保留，'
            '稍后仍可继续对话。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('中断')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _interruptingId = sub.id);
    try {
      final done = await handler(sub);
      if (!mounted) return;
      if (!done) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('中断请求被引擎拒绝或未送达'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _interruptingId = null);
    }
  }

  // ------------------------------------------------- 一键诊断 [feat 2026-10-12] ----

  Widget _buildDiagnostics() {
    final report = widget.diagnostics;
    return _section(
      title: '连接诊断',
      icon: Icons.monitor_heart_rounded,
      children: [
        Row(
          children: [
            Expanded(
              child: _hint('逐项检查网关、引擎 RPC、事件流与磁盘。全程只读、不泄露令牌与路径。'),
            ),
            TextButton.icon(
              key: const ValueKey('run-diagnostics'),
              onPressed: widget.diagnosticsBusy ? null : _runDiagnostics,
              icon: widget.diagnosticsBusy
                  ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.play_arrow_rounded, size: 16, color: context.c.accent),
              label: Text(widget.diagnosticsBusy ? '检测中…' : (report == null ? '运行诊断' : '重新诊断'),
                  style: TextStyle(fontSize: 12, color: context.c.accent)),
            ),
          ],
        ),
        if (report != null) ...[
          const SizedBox(height: 8),
          for (final c in report.checks)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 18,
                    child: Text(
                      // ok 缺省（如 bridge_version）渲染成中性 •，不装作通过。
                      c.ok == null ? '•' : (c.ok! ? '✓' : '✗'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: c.ok == null
                            ? context.c.textTertiary
                            : (c.ok! ? context.c.success : context.c.danger),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        text: c.label,
                        style: TextStyle(fontSize: 12, color: context.c.textPrimary),
                        children: [
                          if (c.value != null && c.value!.isNotEmpty)
                            TextSpan(text: '  ${c.value}', style: TextStyle(fontSize: 11, color: context.c.textTertiary)),
                          if (c.detail != null && c.detail!.isNotEmpty && c.detail != 'ok')
                            TextSpan(text: '  ${c.detail}', style: TextStyle(fontSize: 11, color: context.c.textTertiary)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('copy-diagnostics'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: report.toPlainText()));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('诊断报告已复制'),
                    duration: Duration(milliseconds: 900),
                    behavior: SnackBarBehavior.floating,
                  ));
                }
              },
              icon: Icon(Icons.copy_rounded, size: 14, color: context.c.textSecondary),
              label: Text('复制报告', style: TextStyle(fontSize: 11.5, color: context.c.textSecondary)),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _runDiagnostics() async {
    final runner = widget.onRunDiagnostics;
    if (runner == null) return;
    final report = await runner();
    if (!mounted) return;
    if (report == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('诊断请求失败（网关不可达）'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // -------------------------------------------------------- 通用 ----

  Widget _section({required String title, required IconData icon, required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: context.c.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.c.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 15, color: context.c.textSecondary),
                const SizedBox(width: 6),
                Text(title,
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: context.c.textPrimary)),
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _metricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 12, color: context.c.textSecondary))),
          Text(value, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: context.c.textPrimary)),
        ],
      ),
    );
  }

  Widget _hint(String text) => Text(
        text,
        style: TextStyle(fontSize: 11.5, color: context.c.textTertiary, height: 1.35),
      );
}

/// diff 面板：先异步取 hunk，再逐行渲染。加载中/空/二进制都有明确文案。
///
/// 从旧的任务页原样迁移过来 —— 它是这一堆只读视图里唯一"内容一定很长"的地方，
/// 所以留在弹层里（再叠一层弹层），而不是塞进信息面板的行里。
class _DiffSheet extends StatefulWidget {
  final WorkspaceChange change;
  final Future<List<DiffHunk>> Function() loader;

  const _DiffSheet({required this.change, required this.loader});

  @override
  State<_DiffSheet> createState() => _DiffSheetState();
}

class _DiffSheetState extends State<_DiffSheet> {
  List<DiffHunk>? _hunks;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.loader().then((h) {
      if (mounted) setState(() => _hunks = h);
    }).catchError((Object e) {
      debugPrint('[SessionInfo] diff 加载失败: $e');
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.75;
    final hunks = _hunks;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.change.path,
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'monospace', color: context.c.textPrimary),
                      maxLines: 2,
                    ),
                  ),
                  Text(widget.change.delta, style: TextStyle(fontSize: 11, color: context.c.textTertiary)),
                ],
              ),
            ),
            Divider(height: 1, color: context.c.border),
            Flexible(
              child: _failed
                  ? Padding(padding: const EdgeInsets.all(20), child: Text('diff 读取失败', style: TextStyle(color: context.c.danger)))
                  : hunks == null
                      ? const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                      : hunks.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(
                                widget.change.status == '??'
                                    ? '未跟踪的新文件，git 没有可比对的旧版本。'
                                    : '没有文本差异（可能是二进制或仅权限变更）。',
                                style: TextStyle(fontSize: 12.5, color: context.c.textSecondary),
                              ),
                            )
                          : ListView(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                              children: [
                                for (final hunk in hunks) ...[
                                  Padding(
                                    padding: const EdgeInsets.only(top: 6, bottom: 4),
                                    child: Text(
                                      hunk.header,
                                      style: TextStyle(fontSize: 11, color: context.c.accent, fontFamily: 'monospace'),
                                    ),
                                  ),
                                  for (final line in hunk.lines)
                                    Container(
                                      width: double.infinity,
                                      color: line.kind == 'add'
                                          ? context.c.success.withOpacity(0.10)
                                          : line.kind == 'del'
                                              ? context.c.danger.withOpacity(0.10)
                                              : null,
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                      child: Text(
                                        '${line.kind == 'add' ? '+' : line.kind == 'del' ? '-' : ' '}${line.text}',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontFamily: 'monospace',
                                          height: 1.35,
                                          color: line.kind == 'add'
                                              ? context.c.success
                                              : line.kind == 'del'
                                                  ? context.c.danger
                                                  : context.c.textSecondary,
                                        ),
                                      ),
                                    ),
                                ],
                              ],
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一个后台任务的输出查看器（引擎 `job/follow` 流）。
///
/// 为什么是"轮询追加"而不是长连接：引擎的 `job/follow` 是一条流（`opened` →
/// 若干 `output` → 终结 `status`），而 App 到网关只有 HTTP 请求/响应。网关把一次
/// 轮询实现成受限帧收集，所以这里拿到的永远是"到目前为止的增量 + 下一个游标"。
///
/// 两条必须逐字遵守的诚实性约束（都来自引擎自己的语义）：
///   1. `settled` 只在**真的收到终结 `status` 帧**时为真。活着的任务没有那一帧，
///      所以"没动静"绝不能被读成"已结束"。
///   2. `lossy` 为真表示环的头部已被丢弃（生产者或保留策略）。此时日志是**不完整
///      的**，界面必须明说，不能把残片当成完整日志展示。
class _JobLogSheet extends StatefulWidget {
  final JobItem job;
  final Future<JobOutputChunk> Function(JobItem job, int? from) load;

  const _JobLogSheet({required this.job, required this.load});

  @override
  State<_JobLogSheet> createState() => _JobLogSheetState();
}

class _JobLogSheetState extends State<_JobLogSheet> {
  final List<JobLogLine> _lines = [];
  final ScrollController _scroll = ScrollController();
  Timer? _poll;

  bool _loading = true;
  bool _busy = false;
  bool _lossy = false;
  bool _settled = false;
  int? _next;
  String _error = '';
  JobItem _job;

  _JobLogSheetState() : _job = const JobItem(id: '', kind: '', label: '', status: 'running');

  @override
  void initState() {
    super.initState();
    _job = widget.job;
    _refresh(initial: true);
    // 活着的任务每 2 秒追一次增量；结束的任务没有新输出可追，不浪费请求。
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_settled || _busy || !mounted) return;
      _refresh();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool initial = false}) async {
    if (_busy) return;
    _busy = true;
    try {
      // 首次不带 `from`（从环里最早保留的字节开始）；此后带上一次的 `next`。
      // `_next` 为 null 时（引擎没报偏移）不敢编一个，退回从头读。
      final chunk = await widget.load(_job, initial ? null : _next);
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!chunk.ok) {
          _error = chunk.error.isEmpty ? '读取失败' : chunk.error;
          return;
        }
        _error = '';
        if (chunk.lines.isNotEmpty) _lines.addAll(chunk.lines);
        if (chunk.next != null) _next = chunk.next;
        if (chunk.lossy) _lossy = true;
        if (chunk.settled) _settled = true;
        if (chunk.job != null) _job = chunk.job!;
      });
      if (_settled) _poll?.cancel();
      _autoScroll();
    } finally {
      _busy = false;
    }
  }

  void _autoScroll() {
    if (!_scroll.hasClients) return;
    // 追加后滚到底：看日志的人关心的是最新一行（历史可以往上翻）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Color _channelColor(BuildContext context, String channel) {
    switch (channel) {
      case 'stderr':
        return context.c.danger;
      case 'log':
        return context.c.textSecondary;
      default:
        return context.c.textPrimary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _job.label.isEmpty ? _job.id : _job.label;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (_job.kind.isNotEmpty) _job.kind,
                            _job.statusLabel,
                            // 未结束就明说"跟随中"，避免用户以为日志到此为止。
                            if (!_settled) '跟随中（每 2 秒追加）',
                          ].join(' · '),
                          style: TextStyle(fontSize: 10.5, color: context.c.textTertiary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '立即刷新',
                    onPressed: _busy ? null : () => _refresh(),
                    icon: Icon(Icons.refresh_rounded, size: 20, color: context.c.accent),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded, size: 20, color: context.c.textSecondary),
                  ),
                ],
              ),
            ),
            // lossy 横幅：日志不完整这一事实必须一直在视野里，而不是只在某一帧闪现。
            if (_lossy)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: context.c.warningSurface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: context.c.warningBorder),
                ),
                child: Text(
                  '日志开头部分已被丢弃（超出保留窗口），下面是仍保留的片段 —— 这不是完整日志。',
                  style: TextStyle(fontSize: 11, color: context.c.warning, height: 1.35),
                ),
              ),
            if (_job.outputHeadLost && !_lossy)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  '引擎报告最早可读偏移为 ${_job.outputEarliest}，之前的内容已不在环内。',
                  style: TextStyle(fontSize: 10.5, color: context.c.textTertiary),
                ),
              ),
            const SizedBox(height: 6),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty && _lines.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error, style: TextStyle(fontSize: 12.5, color: context.c.danger)),
            const SizedBox(height: 10),
            OutlinedButton(onPressed: () => _refresh(), child: const Text('重试')),
          ],
        ),
      );
    }
    if (_lines.isEmpty) {
      // 空 ≠ 失败，也 ≠ 完成：分别说清。
      return Center(
        child: Text(
          _settled ? '该任务没有产生输出。' : '暂时还没有输出。',
          style: TextStyle(fontSize: 12.5, color: context.c.textSecondary),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: _lines.length + (_error.isNotEmpty ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == _lines.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('追加失败：$_error', style: TextStyle(fontSize: 11, color: context.c.danger)),
          );
        }
        final line = _lines[i];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // gapBefore：这一行之前的字节丢了。画一条明确的断口，而不是让两段
            // 不相邻的输出看起来是接着的。
            if (line.gapBefore)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '—— 此处有丢失的字节 ——',
                  style: TextStyle(fontSize: 10, color: context.c.warning, fontStyle: FontStyle.italic),
                ),
              ),
            SelectableText(
              line.text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                height: 1.35,
                color: _channelColor(context, line.channel),
              ),
            ),
          ],
        );
      },
    );
  }
}
