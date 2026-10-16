import 'package:flutter/material.dart';

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

  Widget _buildFooter(BuildContext context, Trajectory traj) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (traj.contextEventCount > 0)
            Row(
              children: [
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
