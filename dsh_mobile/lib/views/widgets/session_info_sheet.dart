import 'package:flutter/material.dart';

import '../../models/task_center.dart';
import '../../theme/app_colors.dart';
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
    this.jobs = const <JobItem>[],
    this.jobsUnavailable = false,
    this.schedules = const <ScheduleItem>[],
    this.busyDeliverablePath,
    this.initialSection = SessionInsightSection.usage,
    this.onOpenDeliverable,
    this.onLoadDiff,
    this.onKillJob,
    this.onDeleteSchedule,
    this.onRefresh,
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

  final List<JobItem> jobs;

  /// 作业状态**未知**（网关降级）。与"没有作业"是两件事。
  final bool jobsUnavailable;

  final List<ScheduleItem> schedules;

  final String? busyDeliverablePath;

  /// 打开时滚到哪一段（状态条哪一段被点的）。
  final SessionInsightSection initialSection;

  final ValueChanged<DeliverableItem>? onOpenDeliverable;

  /// 取单个文件的 diff。
  final Future<List<DiffHunk>> Function(String path)? onLoadDiff;

  final Future<void> Function(JobItem job)? onKillJob;

  final Future<void> Function(ScheduleItem schedule)? onDeleteSchedule;

  /// 打开面板时（以及点刷新时）拉取懒加载的那部分：后台作业 / 定时任务。
  ///
  /// 这两个是**最贵**的两个请求（`jobs` 是一次带 5s 超时的流 RPC，
  /// `schedules` 是一次 RPC），所以只在用户明确要看的时候拉，不在进会话时拉。
  final Future<void> Function()? onRefresh;

  @override
  State<SessionInfoSheet> createState() => _SessionInfoSheetState();
}

class _SessionInfoSheetState extends State<SessionInfoSheet> {
  final _usageKey = GlobalKey();
  final _deliverablesKey = GlobalKey();
  final _changesKey = GlobalKey();
  final _jobsKey = GlobalKey();
  final _schedulesKey = GlobalKey();
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollTo(widget.initialSection);
      _refresh();
    });
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

  Future<void> _confirmKillJob(JobItem job) async {
    final kill = widget.onKillJob;
    if (kill == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('终止这个后台作业？'),
        content: Text('将请求引擎终止「${job.label.isEmpty ? job.id : job.label}」。'
            '已经产生的结果不会回滚。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('终止')),
        ],
      ),
    );
    if (ok == true) await kill(job);
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
                    KeyedSubtree(key: _schedulesKey, child: _buildSchedules()),
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
          '上下文已用 ${stats.pressureTokens} / ${stats.contextWindow}'
          '${stats.projectedTokens != null ? ' · 下一轮预计 ${stats.projectedTokens}' : ''}',
          style: TextStyle(fontSize: 11.5, color: context.c.textSecondary),
        ));
      }

      children.add(const SizedBox(height: 10));
      // 常驻噪声（缓存读/写、未缓存输入、输出四格）已经砍掉——它们对手机上唯一
      // 的三个决策（继续 / 新开会话 / 放弃）没有可行动价值。这里只留三行。
      children.add(_metricRow('本轮消耗', _formatTurnBurn(widget.turnBurnTokens)));
      children.add(_metricRow('会话累计', stats.totalTokens == null ? '—' : _group(stats.totalTokens!)));
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
          ],
        ),
      ));
    }

    return _section(title: '用量与上下文', icon: Icons.data_usage_rounded, children: children);
  }

  String _formatTurnBurn(int? burn) => burn == null ? '—' : _group(burn);

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

  // --------------------------------------------------------- 交付物 ----

  Widget _buildDeliverables() {
    final groups = groupDeliverablesByTurn(widget.deliverables);
    return _section(
      title: '交付物',
      icon: Icons.folder_special_rounded,
      children: [
        if (groups.isEmpty)
          _hint('这次任务还没有声明交付文件。agent 交付 docx/xlsx/pdf 时会出现在这里。')
        else
          // 按轮倒序分组，**默认只展开最新一轮**：长会话可能声明过几十个文件，
          // 而用户要的是"刚给我的那批"。其余轮次折起来但不隐藏。
          for (var i = 0; i < groups.length; i++) _buildDeliverableGroup(groups[i], i == 0),
      ],
    );
  }

  Widget _buildDeliverableGroup(DeliverableGroup group, bool expanded) {
    final rows = <Widget>[
      for (final item in group.items)
        DeliverableRow(
          item: item,
          dense: true,
          busy: widget.busyDeliverablePath != null && widget.busyDeliverablePath == item.path,
          onOpen: widget.onOpenDeliverable == null ? null : () => widget.onOpenDeliverable!(item),
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
    if (!widget.changesAvailable) {
      // 不可用**不等于**干净。这里只说清楚为什么看不到。
      final reason = widget.changesReason == 'not-a-git-repository'
          ? '这个工作区不是 git 仓库，列不出改动（引擎侧的变更快照不通过 RPC 暴露）。'
          : (widget.changesReason.isNotEmpty ? '变更清单暂不可用：${widget.changesReason}' : '变更清单暂不可用。');
      return _section(
        title: '本次变更',
        icon: Icons.difference_rounded,
        children: [_hint(reason)],
      );
    }

    return _section(
      title: '本次变更',
      icon: Icons.difference_rounded,
      children: [
        if (widget.changes.isEmpty)
          _hint('工作区是干净的 —— 没有未提交改动。')
        else
          for (final change in widget.changes)
            InkWell(
              onTap: widget.onLoadDiff == null ? null : () => _openDiff(change),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 34,
                      child: Text(change.label,
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: context.c.warning)),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        change.path,
                        style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: context.c.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(change.delta, style: TextStyle(fontSize: 10.5, color: context.c.textTertiary)),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right_rounded, size: 16, color: context.c.textTertiary),
                  ],
                ),
              ),
            ),
      ],
    );
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
          for (final job in widget.jobs)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: (job.isLive ? context.c.accent : context.c.textTertiary).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: (job.isLive ? context.c.accent : context.c.border).withOpacity(0.5)),
                    ),
                    child: Text(
                      job.statusLabel,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: job.isLive ? context.c.accent : context.c.textSecondary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      job.label.isEmpty ? job.id : job.label,
                      style: TextStyle(fontSize: 12.5, color: context.c.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
            ),
      ],
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
