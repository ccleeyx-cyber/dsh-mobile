import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// 信息面板里可以被"点名跳过去"的小节。
///
/// 定义在状态条这一侧：状态条的每一段点击后要打开面板并滚到对应小节，
/// 所以"有哪些小节"这件事的归属方是状态条（生产者），面板只是消费者。
enum SessionInsightSection { usage, deliverables, changes, jobs, schedules }

/// 会话状态条：AppBar 下方一条常驻单行信息。
///
/// 它回答的是"这个会话**现在**是什么样"——所以它只放**状态**，不放事件；
/// 事件（例如刚刚交付了什么）走消息流里的卡片（见 `turn_output_card.dart`）。
///
/// 三条硬规则，改这个文件前请先读：
///
/// 1. **未知即隐藏。** 每个字段都是可空的，`null` 一律表示"读不到/还没拉过"，
///    这时**整段不渲染**。绝不把未知渲染成 `0`：`改动 0` 在用户眼里是
///    "工作区是干净的"，而真相可能是"网关没读出来"或"这不是 git 仓库"。
///    这一条是被真实缺陷教出来的——旧的任务页角标把"没拉过 jobs"显示成 `0`，
///    于是"有作业在跑"和"没有作业"在界面上完全一样。
/// 2. **顶部而非输入框上方。** 它挂在 `AppBar.bottom`，键盘弹起时不参与压缩，
///    所以打字时"执行中/产出/上下文"依然可读；输入框上方那块空间在键盘弹起时
///    是最紧的，只留给"我要发的话"和阈值触发的告警。
/// 3. **只放三个数字级别的信息。** 这里放不下的（用量明细、文件清单、作业列表）
///    一律进底部信息面板，本组件只负责"有没有、有几个、要不要点进去"。
class SessionStatusStrip extends StatelessWidget implements PreferredSizeWidget {
  const SessionStatusStrip({
    super.key,
    this.isRunning = false,
    this.deliverableCount,
    this.deliverablesUnread = false,
    this.changeCount,
    this.changesUnavailable = false,
    this.contextFraction,
    this.contextIsSnapshot = false,
    this.liveJobCount,
    this.onTapSection,
  });

  /// 当前会话是否正在跑一个回合。
  final bool isRunning;

  /// 本会话声明过的交付物数量；`null` = 未知（隐藏）。
  ///
  /// `0` 是**已知真值**，照常显示：对一次长任务来说，"它一个文件都没交付"
  /// 本身就是用户需要知道的事。
  final int? deliverableCount;

  /// 有尚未被用户看过的产出时高亮"产出"那一段。
  final bool deliverablesUnread;

  /// 工作区改动文件数；`null` = 未知（隐藏）。
  final int? changeCount;

  /// 工作区不是 git 仓库（网关 `available:false`）：整段隐藏。
  ///
  /// 这不是"改动 0"——"看不到改动"和"没有改动"必须长得不一样。
  final bool changesUnavailable;

  /// 上下文占用 0..1；`null` = 未知（隐藏）。
  final double? contextFraction;

  /// 上下文数值来自投影缓存快照（会话不在内存中），不是实时值。
  final bool contextIsSnapshot;

  /// 仍在跑的后台作业数；`null` = 未知（隐藏），`0` 同样隐藏（无需占位）。
  final int? liveJobCount;

  /// 点了某一段。`null` 时整条不可点。
  final ValueChanged<SessionInsightSection>? onTapSection;

  /// 低于这个比例不画进度线——常态下这一条要尽量安静。
  static const double pressureLineThreshold = 0.70;

  /// 高风险阈值：与 `chat_view` 输入框上方那条告警共用同一个数。
  static const double pressureCriticalThreshold = 0.85;

  static const double _rowHeight = 34;

  /// 有没有任何东西可显示。没有就只留 1px 分隔线，**不留一条空白带**。
  bool get hasContent =>
      isRunning ||
      deliverableCount != null ||
      (changeCount != null && !changesUnavailable) ||
      contextFraction != null ||
      (liveJobCount != null && liveJobCount! > 0);

  bool get _showPressureLine =>
      contextFraction != null && contextFraction! > pressureLineThreshold;

  @override
  Size get preferredSize => Size.fromHeight(hasContent ? _rowHeight : 1);

  Color _contextColor(BuildContext context) {
    final f = contextFraction ?? 0;
    if (f >= pressureCriticalThreshold) return context.c.danger;
    if (f > SessionStatusStrip.pressureLineThreshold) return context.c.warning;
    return context.c.textSecondary;
  }

  @override
  Widget build(BuildContext context) {
    final border = Container(color: context.c.border, height: 1);

    if (!hasContent) {
      // 没有可显示的状态：只保留那条分隔线，高度 1。
      return Container(
        key: const ValueKey('session-status-strip-empty'),
        color: context.c.surface,
        child: border,
      );
    }

    final segments = <Widget>[];

    void addSegment({required Key key, required Widget child, required SessionInsightSection section}) {
      if (segments.isNotEmpty) {
        segments.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('·', style: TextStyle(fontSize: 11, color: context.c.textTertiary)),
        ));
      }
      segments.add(InkWell(
        key: key,
        borderRadius: BorderRadius.circular(6),
        onTap: onTapSection == null ? null : () => onTapSection!(section),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: child,
        ),
      ));
    }

    if (deliverableCount != null) {
      final count = deliverableCount!;
      final highlight = deliverablesUnread && count > 0;
      addSegment(
        key: const ValueKey('strip-segment-deliverables'),
        section: SessionInsightSection.deliverables,
        child: Text(
          '产出 $count',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
            color: highlight
                ? context.c.accent
                : (count > 0 ? context.c.textSecondary : context.c.textTertiary),
          ),
        ),
      );
    }

    if (changeCount != null && !changesUnavailable) {
      addSegment(
        key: const ValueKey('strip-segment-changes'),
        section: SessionInsightSection.changes,
        child: Text(
          '改动 $changeCount',
          style: TextStyle(fontSize: 11.5, color: context.c.textSecondary),
        ),
      );
    }

    if (contextFraction != null) {
      final pct = (contextFraction! * 100).round();
      addSegment(
        key: const ValueKey('strip-segment-context'),
        section: SessionInsightSection.usage,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('上下文 $pct%', style: TextStyle(fontSize: 11.5, color: _contextColor(context))),
            if (contextIsSnapshot) ...[
              const SizedBox(width: 3),
              // 快照必须看得出来：把几小时前的读数当实时值，用户会据此做出
              // "还能不能接着跑"的错误判断。
              Tooltip(
                message: '会话不在内存中，这是最后一次上报的快照',
                child: Icon(
                  Icons.history_rounded,
                  key: const ValueKey('strip-context-snapshot'),
                  size: 12,
                  color: context.c.textTertiary,
                ),
              ),
            ],
          ],
        ),
      );
    }

    if (liveJobCount != null && liveJobCount! > 0) {
      addSegment(
        key: const ValueKey('strip-segment-jobs'),
        section: SessionInsightSection.jobs,
        child: Text(
          '运行中 $liveJobCount',
          style: TextStyle(fontSize: 11.5, color: context.c.accent),
        ),
      );
    }

    return Container(
      key: const ValueKey('session-status-strip'),
      color: context.c.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: _rowHeight - (_showPressureLine ? 2 : 0) - 1,
            child: Row(
              children: [
                const SizedBox(width: 12),
                if (isRunning)
                  Container(
                    key: const ValueKey('strip-running'),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: context.c.accent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: context.c.accent.withOpacity(0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 7,
                          height: 7,
                          child: CircularProgressIndicator(strokeWidth: 1.4, color: context.c.accent),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '执行中',
                          style: TextStyle(color: context.c.accent, fontSize: 9.5, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                // 空白区域也可点：用户想看的细节就在面板里，不必非得点中某个数字。
                Expanded(
                  child: InkWell(
                    onTap: onTapSection == null ? null : () => onTapSection!(SessionInsightSection.usage),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, right: 10),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: segments),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_showPressureLine)
            // 2px 进度线：这是"离上下文上限还有多远"的一眼可读化。只有超过阈值
            // 才出现——常态下它安静，出事时它显眼。
            ClipRRect(
              child: LinearProgressIndicator(
                key: const ValueKey('strip-context-bar'),
                value: contextFraction,
                minHeight: 2,
                backgroundColor: context.c.surfaceMuted,
                valueColor: AlwaysStoppedAnimation(_contextColor(context)),
              ),
            ),
          border,
        ],
      ),
    );
  }
}
