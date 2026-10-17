import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/trajectory.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// 会话轨迹面板：一条「轮 → 事件」时间线。
///
/// ## 它回答什么
///
/// * 这一轮它**做了什么**：思考 → 工具调用（按顺序）→ 回复，逐条列出来。
/// * 每步**什么时候**发生：用引擎在消息上带的时间；工具没有独立时间戳，就跟随
///   它所属消息的时间（界面底部会把这件事写出来，不装作每步都有精确时刻）。
/// * 这一轮**花了多久 / 烧了多少 token**：能取到才显示，取不到显示 `—`。
///
/// ## 组件的边界（与 `SessionInfoSheet` 一致）
///
/// 自包含：数据全靠参数传进来（一个已经建好的 [Trajectory]），动作全靠回调传出去。
/// 它**不读** `DshService`，所以可以在任何宿主里被单独渲染与断言。
///
/// ## 三条渲染规则
///
/// 1. **未知不渲染成 0**：耗时/token 取不到一律 `—`（颜色也降级为 tertiary）。
/// 2. **运行中的轮不封口**：显示"进行中 · 已 Ns"，而不是一个假的结束时间。
/// 3. **上下文块默认折叠**：它们不是动作；但底部给出"已隐藏 N 条"和开关 ——
///    隐藏不等于不存在。
class TrajectorySheet extends StatefulWidget {
  const TrajectorySheet({
    super.key,
    required this.trajectory,
    this.onJumpToMessage,
    this.showContext = false,
    this.now,
  });

  final Trajectory trajectory;

  /// 点"跳到消息"时回传 `ChatMessage.id` 的宿主。为 null 时整列跳转按钮隐藏
  /// （而不是给一个点了没反应的图标）。
  final ValueChanged<String>? onJumpToMessage;

  /// 初始是否展开上下文块。
  final bool showContext;

  /// 计算"进行中多久"的基准时刻。测试可以注入固定值；生产传 null 取当前时间。
  final DateTime? now;

  /// 底部「导出 Markdown」按钮的稳定句柄（测试用）。
  @visibleForTesting
  static const Key exportButtonKey = Key('trajectory-export');

  @override
  State<TrajectorySheet> createState() => _TrajectorySheetState();
}

class _TrajectorySheetState extends State<TrajectorySheet> {
  /// 展开的事件，键为 `轮号:事件下标`（事件身份在同一轮内稳定）。
  final Set<String> _expanded = <String>{};
  late bool _showContext = widget.showContext;

  @override
  void initState() {
    super.initState();
    _showContext = widget.showContext;
  }

  @override
  Widget build(BuildContext context) {
    final traj = widget.trajectory;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.86;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        key: const ValueKey('trajectory-sheet'),
        decoration: BoxDecoration(
          color: context.c.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          border: Border(top: BorderSide(color: context.c.border)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildGrabber(context),
              _buildHeader(context, traj),
              if (traj.timedTurnCount >= 2) _buildTimeBand(context, traj),
              Flexible(
                child: traj.isEmpty
                    ? _buildEmpty(context)
                    : ListView.builder(
                        key: const ValueKey('trajectory-timeline'),
                        padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                        itemCount: traj.turns.length,
                        itemBuilder: (ctx, i) => _buildTurn(context, traj.turns[i]),
                      ),
              ),
              _buildFooter(context, traj),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGrabber(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: context.c.border,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, Trajectory traj) {
    final total = traj.totalDuration;
    final parts = <String>[
      '${traj.turns.length} 轮',
      '${traj.actionEventCount} 个事件',
      if (traj.toolCount > 0) '${traj.toolCount} 次工具调用',
      // 总耗时只在每一轮都有数据时才出现 —— 部分求和会被读成整段会话的耗时。
      if (total != null) '共 ${formatDuration(total)}',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
      child: Row(
        children: [
          Icon(Icons.timeline_rounded, size: 20, color: context.c.accent),
          const SizedBox(width: AppSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '轨迹',
                  style: TextStyle(
                    fontSize: AppText.title,
                    fontWeight: FontWeight.w700,
                    color: context.c.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpace.xs),
                Text(
                  parts.join(' · '),
                  key: const ValueKey('trajectory-summary'),
                  style: TextStyle(fontSize: AppText.caption, color: context.c.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('trajectory-close'),
            tooltip: '关闭',
            icon: Icon(Icons.close_rounded, size: 20, color: context.c.textSecondary),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  /// 时间概览：每一轮一段，宽度与耗时成正比。
  ///
  /// 没有耗时的轮不参与比例（否则会凭空多出一段"看起来很快"的柱子），只做计数
  /// 提示。整段只有一轮或全部无耗时时干脆不画 —— 两根柱子的"占比图"没有信息量。
  Widget _buildTimeBand(BuildContext context, Trajectory traj) {
    final timed = traj.turns
        .map((t) => MapEntry(t, t.duration))
        .where((e) => e.value != null)
        .toList(growable: false);
    final unknown = traj.turns.length - timed.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        key: const ValueKey('trajectory-time-band'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 10,
              child: Row(
                children: [
                  for (final entry in timed)
                    Expanded(
                      // flex 用毫秒；至少给 1，避免极短的一轮被压成 0 宽而看不见。
                      flex: entry.value!.inMilliseconds.clamp(1, 1 << 30),
                      child: Container(
                        margin: const EdgeInsets.only(right: 2),
                        decoration: BoxDecoration(
                          color: entry.key.running
                              ? context.c.accent
                              : (entry.key.toolCount > 0
                                  ? context.c.textSecondary
                                  : context.c.border),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpace.s),
          Text(
            unknown == 0
                ? '时间概览：按每轮耗时占比'
                : '时间概览：$unknown 轮没有可用的时间数据，未计入',
            style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      child: Text(
        '这个会话还没有可以显示的事件。',
        key: const ValueKey('trajectory-empty'),
        style: TextStyle(fontSize: AppText.body, color: context.c.textSecondary),
      ),
    );
  }

  Widget _buildTurn(BuildContext context, TrajectoryTurn turn) {
    final visible = _showContext ? turn.events : turn.actionEvents;
    final elapsed = turn.elapsedAt(widget.now ?? DateTime.now());

    return Column(
      key: ValueKey('trajectory-turn-${turn.index}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTurnHeader(context, turn, elapsed),
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 22, bottom: AppSpace.m),
            child: Text(
              _showContext ? '本轮暂无事件' : '本轮只有上下文块（在底部打开开关可查看）',
              style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
            ),
          ),
        for (var i = 0; i < visible.length; i++)
          _buildEvent(context, turn, i, visible[i]),
        const SizedBox(height: AppSpace.s),
        Divider(height: 1, color: context.c.border),
        const SizedBox(height: AppSpace.m),
      ],
    );
  }

  Widget _buildTurnHeader(BuildContext context, TrajectoryTurn turn, Duration? elapsed) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.s),
      child: Row(
        children: [
          Text(
            '第 ${turn.index} 轮',
            style: TextStyle(
              fontSize: AppText.body,
              fontWeight: FontWeight.w700,
              color: context.c.textPrimary,
            ),
          ),
          if (turn.running) ...[
            const SizedBox(width: AppSpace.m),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: context.c.accentSurface,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '进行中',
                style: TextStyle(fontSize: AppText.caption, color: context.c.accent),
              ),
            ),
          ],
          const Spacer(),
          _buildMetric(
            context,
            icon: Icons.schedule_rounded,
            value: elapsed == null ? '—' : formatDuration(elapsed),
            tooltip: turn.running
                ? '进行中：从本轮第一个事件到现在'
                : (elapsed == null
                    ? '本轮没有两个以上带时间的事件，耗时无法计算'
                    : '本轮首个与最后一个引擎事件的时间差'),
            valueKey: ValueKey('trajectory-turn-${turn.index}-duration'),
          ),
          const SizedBox(width: AppSpace.l),
          _buildMetric(
            context,
            icon: Icons.local_fire_department_outlined,
            value: turn.tokens == null ? '—' : formatTokens(turn.tokens!),
            tooltip: turn.tokens == null
                ? '引擎只上报本轮的用量，这一轮没有数据'
                : '本轮消耗 token',
            valueKey: ValueKey('trajectory-turn-${turn.index}-tokens'),
          ),
        ],
      ),
    );
  }

  Widget _buildMetric(
    BuildContext context, {
    required IconData icon,
    required String value,
    required String tooltip,
    required Key valueKey,
  }) {
    // `—` 用 tertiary 色：它不是"0"，是"没有数据"。颜色必须把它和真实的 0 分开。
    final known = value != '—';
    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: known ? context.c.textSecondary : context.c.textTertiary),
          const SizedBox(width: 3),
          Text(
            value,
            key: valueKey,
            style: TextStyle(
              fontSize: AppText.caption,
              color: known ? context.c.textSecondary : context.c.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEvent(
    BuildContext context,
    TrajectoryTurn turn,
    int index,
    TrajectoryEvent event,
  ) {
    final stateKey = '${turn.index}:$index';
    final expanded = _expanded.contains(stateKey);
    final accent = _kindColor(context, event.kind);

    return InkWell(
      key: ValueKey('trajectory-event-${turn.index}-$index'),
      borderRadius: BorderRadius.circular(6),
      onTap: event.expandable
          ? () => setState(() {
                if (expanded) {
                  _expanded.remove(stateKey);
                } else {
                  _expanded.add(stateKey);
                }
              })
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_kindIcon(event.kind), size: 15, color: accent),
                const SizedBox(width: AppSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              event.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppText.caption,
                                fontWeight: FontWeight.w600,
                                color: accent,
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpace.m),
                          Text(
                            formatClock(event.at),
                            style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
                          ),
                          if (event.running) ...[
                            const SizedBox(width: AppSpace.m),
                            Text(
                              '运行中',
                              style: TextStyle(fontSize: AppText.caption, color: context.c.accent),
                            ),
                          ],
                        ],
                      ),
                      if (event.preview.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          event.preview,
                          maxLines: expanded ? 4 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppText.caption,
                            height: 1.35,
                            color: context.c.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (event.expandable)
                  Icon(
                    expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 16,
                    color: context.c.textTertiary,
                  ),
                if (widget.onJumpToMessage != null)
                  IconButton(
                    key: ValueKey('trajectory-jump-${turn.index}-$index'),
                    tooltip: '跳到消息',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.my_location_rounded, size: 15, color: context.c.textTertiary),
                    onPressed: () => widget.onJumpToMessage!(event.messageId),
                  ),
              ],
            ),
            if (expanded) ...[
              const SizedBox(height: AppSpace.s),
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(left: 23),
                padding: const EdgeInsets.all(AppSpace.m),
                decoration: BoxDecoration(
                  color: context.c.surfaceMuted,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: context.c.border),
                ),
                child: SelectableText(
                  event.detail,
                  key: ValueKey('trajectory-detail-${turn.index}-$index'),
                  style: TextStyle(
                    fontSize: AppText.caption,
                    height: 1.4,
                    fontFamily: 'monospace',
                    color: context.c.textPrimary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 底部：上下文开关 + 导出 Markdown + 一句"这些数据是怎么来的"。
  ///
  /// 导出**不在 build 里做**：几千行的轨迹序列化一次能占掉整帧，所以只在用户点
  /// 下去的那一刻才生成 md（见 [_exportMarkdown]）。
  Widget _buildFooter(BuildContext context, Trajectory traj) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (traj.contextEventCount > 0) ...[
                Switch(
                  key: const ValueKey('trajectory-context-toggle'),
                  value: _showContext,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) => setState(() => _showContext = v),
                ),
                const SizedBox(width: AppSpace.s),
                Expanded(
                  child: Text(
                    '显示上下文/记忆块/通知（${traj.contextEventCount} 条）',
                    style: TextStyle(fontSize: AppText.caption, color: context.c.textSecondary),
                  ),
                ),
              ] else
                // 没有上下文块时把按钮推到右侧，行高度不变 —— 有开关和没开关的
                // 两种面板不该出现两种底部节奏。
                const Spacer(),
              const SizedBox(width: AppSpace.s),
              OutlinedButton.icon(
                key: TrajectorySheet.exportButtonKey,
                onPressed: _exportMarkdown,
                icon: Icon(Icons.ios_share_rounded, size: 15, color: context.c.accent),
                label: Text(
                  '导出 Markdown',
                  style: TextStyle(fontSize: AppText.caption, color: context.c.accent),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  side: BorderSide(color: context.c.border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
          Text(
            '按引擎事件序号与消息结构重建；同一轮内的工具调用没有独立时间戳，'
            '时间跟随所属消息。',
            style: TextStyle(fontSize: AppText.caption, height: 1.3, color: context.c.textTertiary),
          ),
        ],
      ),
    );
  }

  /// 生成 Markdown 并复制到剪贴板。
  ///
  /// 为什么不走"系统分享"：这个工程的依赖里没有 `share_plus` / `url_launcher`
  /// （`pubspec.yaml` 也不许在这里动），自己搭一个分享 Intent 就得写平台通道，
  /// 而收益只是省一次粘贴。所以退一步：复制 + 明确回执。回执文案只说"已复制"，
  /// 不说"已分享" —— 后者会让人以为已经发出去了。
  Future<void> _exportMarkdown() async {
    final markdown = trajectoryToMarkdown(
      widget.trajectory,
      now: widget.now,
      includeContext: _showContext,
    );
    await Clipboard.setData(ClipboardData(text: markdown));
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制 Markdown'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  static IconData _kindIcon(TrajectoryEventKind kind) {
    switch (kind) {
      case TrajectoryEventKind.user:
        return Icons.person_outline_rounded;
      case TrajectoryEventKind.thinking:
        return Icons.psychology_outlined;
      case TrajectoryEventKind.tool:
        return Icons.build_outlined;
      case TrajectoryEventKind.reply:
        return Icons.chat_bubble_outline_rounded;
      case TrajectoryEventKind.context:
        return Icons.inventory_2_outlined;
    }
  }

  static Color _kindColor(BuildContext context, TrajectoryEventKind kind) {
    switch (kind) {
      case TrajectoryEventKind.user:
        return context.c.accent;
      case TrajectoryEventKind.thinking:
        return context.c.purple;
      case TrajectoryEventKind.tool:
        return context.c.orange;
      case TrajectoryEventKind.reply:
        return context.c.textPrimary;
      case TrajectoryEventKind.context:
        return context.c.textTertiary;
    }
  }
}

/// 把一段轨迹序列化成 Markdown（Phase 5.3）。
///
/// 只在用户点「导出 Markdown」时调用 —— 几千行的轨迹在 `build` 里序列化会直接
/// 掉帧，而绝大多数人根本不导出。
///
/// ## 诚实规则（与面板一致，不许漂移）
///
/// * 取不到的耗时 / token 写 `—`，**不写 0**，也不按"现在"补一个数：`0s` 会被
///   读成"这轮瞬间跑完了"，`0 token` 会被读成"没花钱"；
/// * 运行中的轮写"进行中（截至导出时刻）"，而不是编一个结束时间；
/// * 上下文/记忆块默认不进正文，但**必须在头部写明省略了多少条** —— 隐藏不等于
///   不存在。面板里打开「显示上下文」再导出，它们就会带上。
///
/// ## 结构
///
/// ```text
/// # 会话轨迹
/// - 概览：2 轮 · 5 个事件 · 1 次工具调用
/// - 导出时间：2026-10-17 11:59:00
///
/// ## 第 1 轮
/// - 时间：22:00:00 → 22:01:02 · 耗时：1m02s · Token：—
///
/// #### 输入 · 22:00:00
/// #### 思考 · 22:01:02
/// #### 工具调用 · bash · 22:01:02   （参数 / 输出各一个围栏代码块）
/// #### 回复 · 22:01:02
/// ```
String trajectoryToMarkdown(
  Trajectory trajectory, {
  DateTime? now,
  bool includeContext = false,
}) {
  final at = now ?? DateTime.now();
  final b = StringBuffer();

  b.writeln('# 会话轨迹');
  b.writeln();
  final total = trajectory.totalDuration;
  final head = <String>[
    '${trajectory.turns.length} 轮',
    '${trajectory.actionEventCount} 个事件',
    if (trajectory.toolCount > 0) '${trajectory.toolCount} 次工具调用',
    // 总耗时只在每一轮都有数据时才出现（与面板同一条规则：部分求和会被读成
    // 整段会话的耗时，而缺的那几轮可能正是最长的）。
    if (total != null) '共 ${formatDuration(total)}',
  ];
  b.writeln('- 概览：${head.join(' · ')}');
  b.writeln('- 导出时间：${_mdStamp(at)}');
  if (!includeContext && trajectory.contextEventCount > 0) {
    b.writeln('- 已省略 ${trajectory.contextEventCount} 条上下文/记忆块/通知（它们不是 '
        'Agent 的动作；在面板里打开「显示上下文」再导出就会带上）');
  }
  b.writeln();
  b.writeln('> 按引擎事件序号与消息结构重建。同一轮内的工具调用没有独立时间戳，'
      '时间跟随它所属的消息。`—` 表示取不到该数据，不是 0。');
  b.writeln();

  if (trajectory.isEmpty) {
    b.writeln('（这段会话还没有可以导出的轮。）');
    return b.toString();
  }

  for (final turn in trajectory.turns) {
    _writeTurn(b, turn, at: at, includeContext: includeContext);
  }
  return b.toString();
}

void _writeTurn(
  StringBuffer b,
  TrajectoryTurn turn, {
  required DateTime at,
  required bool includeContext,
}) {
  b.writeln('## 第 ${turn.index} 轮');
  b.writeln();

  // ---- 一行摘要：时间 / 耗时 / token ----
  final started = turn.startedAt;
  final ended = turn.endedAt;
  final String span;
  if (started == null) {
    span = '—';
  } else if (turn.running) {
    span = '${formatClock(started)} → 进行中';
  } else if (ended == null) {
    span = '${formatClock(started)} → —';
  } else if (ended == started) {
    // 首尾同一时刻（整轮只有一个事件）不写成 "22:03:00 → 22:03:00"：那看起来像
    // 一段零长度的时间，而实际含义是"没有第二个时刻可用于划区间"。
    span = formatClock(started);
  } else {
    span = '${formatClock(started)} → ${formatClock(ended)}';
  }

  final elapsed = turn.elapsedAt(at);
  final String duration;
  if (elapsed == null) {
    duration = '—';
  } else if (turn.running) {
    duration = '${formatDuration(elapsed)}（进行中，截至导出时刻）';
  } else {
    duration = formatDuration(elapsed);
  }

  // token 写精确值而不是面板上的 5.5k：导出的 md 是拿来分析的，四舍五入会丢信息。
  final tokens = turn.tokens == null ? '—' : '${turn.tokens}';
  b.writeln('- 时间：$span · 耗时：$duration · Token：$tokens');
  b.writeln();

  final visible = includeContext ? turn.events : turn.actionEvents;
  if (visible.isEmpty) {
    b.writeln(includeContext ? '（本轮暂无事件）' : '（本轮只有上下文块，已省略）');
    b.writeln();
    return;
  }

  // 组内保持模型给的顺序（思考 → 工具按调用顺序 → 回复），不按时间重排：
  // 同一轮里工具没有独立时间戳，按时间排等于假装它们有先后。
  for (final event in visible) {
    _writeEvent(b, event);
  }
}

void _writeEvent(StringBuffer b, TrajectoryEvent event) {
  final clock = event.at == null ? '—' : formatClock(event.at);
  final title = _mdKindTitle(event.kind);

  if (event.kind != TrajectoryEventKind.tool) {
    b.writeln('#### $title · $clock');
    b.writeln();
    final body = event.detail.trim().isEmpty ? event.preview.trim() : event.detail.trim();
    b.writeln(_mdClip(body.isEmpty ? '（空）' : body));
    b.writeln();
    return;
  }

  final name = event.label.trim().isEmpty ? '工具' : event.label.trim();
  b.writeln('#### $title · $name · $clock');
  b.writeln();
  if (event.running) {
    b.writeln('- 状态：运行中（导出时还没结束）');
    b.writeln();
  }
  final body = event.detail.trim();
  if (body.isEmpty) {
    final fallback = event.preview.trim();
    b.writeln(fallback.isEmpty ? '（没有可显示的参数与输出）' : _mdClip(fallback));
    b.writeln();
    return;
  }

  final parts = _splitToolDetail(body);
  if (parts.args.isNotEmpty) {
    b.writeln('**参数**');
    b.writeln();
    _writeFence(b, _mdClip(parts.args));
    b.writeln();
  }
  if (parts.output.isNotEmpty) {
    b.writeln('**输出**');
    b.writeln();
    _writeFence(b, _mdClip(parts.output));
    b.writeln();
  }
  if (parts.args.isEmpty && parts.output.isEmpty) {
    // 形状对不上（未来的模型改了 detail 格式）：宁可原样贴出来，也不能因为切不开
    // 就把内容丢掉。
    _writeFence(b, _mdClip(body));
    b.writeln();
  }
}

/// 把工具事件的 detail 切回「参数 / 输出」两段。
///
/// 形状来自 `Trajectory.build` 的拼装：`参数\n<input>\n\n结果\n<output>`。
/// 切不开时整段当参数（多显示一点永远好过少显示）。
({String args, String output}) _splitToolDetail(String detail) {
  const marker = '\n\n结果\n';
  final i = detail.indexOf(marker);
  if (i < 0) {
    return (args: _stripPrefix(detail, '参数\n'), output: '');
  }
  return (
    args: _stripPrefix(detail.substring(0, i), '参数\n'),
    output: detail.substring(i + marker.length).trim(),
  );
}

String _stripPrefix(String text, String prefix) =>
    text.startsWith(prefix) ? text.substring(prefix.length).trim() : text.trim();

/// 围栏代码块。围栏长度取"比内容里最长的一段反引号再长一个"，否则内容自带
/// ``` 的模板（md 片段、代码块）会被提前闭合，导出文件后半段全变成正文。
void _writeFence(StringBuffer b, String body) {
  var longest = 0;
  for (final m in RegExp(r'`+').allMatches(body)) {
    final n = (m.group(0) ?? '').length;
    if (n > longest) longest = n;
  }
  final fence = '`' * (longest < 3 ? 3 : longest + 1);
  b.writeln(fence);
  b.writeln(body);
  b.writeln(fence);
}

String _mdKindTitle(TrajectoryEventKind kind) {
  switch (kind) {
    case TrajectoryEventKind.user:
      return '输入';
    case TrajectoryEventKind.thinking:
      return '思考';
    case TrajectoryEventKind.tool:
      return '工具调用';
    case TrajectoryEventKind.reply:
      return '回复';
    case TrajectoryEventKind.context:
      return '上下文';
  }
}

/// 单个文本块的上限。截断**必须写明**截了多少，否则导出文件看起来像是原文就
/// 只有这么长。
String _mdClip(String text, {int max = 20000}) {
  if (text.length <= max) return text;
  return '${text.substring(0, max)}\n\n…（已截断：原文 ${text.length} 字符，'
      '此处只保留前 $max 字符）';
}

String _mdStamp(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
}

/// `HH:mm:ss`；没有时间戳时给 `--:--:--`（不是 `00:00:00`）。
String formatClock(DateTime? at) {
  if (at == null) return '--:--:--';
  final h = at.hour.toString().padLeft(2, '0');
  final m = at.minute.toString().padLeft(2, '0');
  final s = at.second.toString().padLeft(2, '0');
  return '$h:$m:$s';
}

/// 人类可读时长。刻意保留一位小数到秒级：一轮几十毫秒级的回合显示成 `0s`
/// 会让人以为"没跑"。
String formatDuration(Duration d) {
  if (d.inSeconds < 60) return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
  if (d.inMinutes < 60) {
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '${d.inMinutes}m${s}s';
  }
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  return '${d.inHours}h${m}m';
}

String formatTokens(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
