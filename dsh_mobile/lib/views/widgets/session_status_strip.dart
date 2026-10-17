import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// 信息面板里可以被"点名跳过去"的小节。
///
/// 定义在状态条这一侧：状态条的每一段点击后要打开面板并滚到对应小节，
/// 所以"有哪些小节"这件事的归属方是状态条（生产者），面板只是消费者。
enum SessionInsightSection { usage, deliverables, changes, jobs, schedules }

/// 与网关的长连接状态（v1.27 新增的最左一段）。
///
/// 三态各自对应一个**完全不同的用户处境**，所以不能合并成一个布尔：
/// * [connected]：正常，**整段隐藏** —— 它占着最显眼的左端却零信息量。
/// * [reconnecting]：正在自动重连（指数退避），用户此刻发什么都可能失败，
///   需要知道"不是我操作错了，是还在连"，所以给一个会呼吸的点。
/// * [disconnected]：已经放弃自动重试（或首次连接就失败），必须给一个**可点**
///   的出口 —— 只报"已断开"而不给重连入口，等于把人关在门外。
enum SessionConnectionState { connected, reconnecting, disconnected }

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
class SessionStatusStrip extends StatelessWidget
    implements PreferredSizeWidget {
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
    this.turns,
    this.steps,
    this.tokensPerSecond,
    this.totalTokens,
    this.cacheHitPercent,
    this.onTapSection,
    this.connection,
    this.onReconnect,
    this.runningElsewhereCount,
    this.onTapRunningElsewhere,
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

  /// 整会话的轮数 / 步数（引擎 `sessionStats` 投影）。`null` = 读不到 → 整段隐藏。
  ///
  /// [feat 2026-10-17] 电脑端状态条第一组就是 `6 轮 351 步 · 210 tok/s`。手机端
  /// 以前没有这几个数字，只有"产出/改动/上下文"。
  ///
  /// **为什么不能自己数**：手机只加载了窗口内的消息（一页≈一两轮），数出来会是一个
  /// 严重偏小的值（"6 轮"被算成"1 轮"）。轮/步必须来自引擎的全日志投影。
  final int? turns;
  final int? steps;

  /// 解码速度 tok/s；`null` = 没测到（显示时整段省略，**不写 `0 tok/s`**）。
  final double? tokensPerSecond;

  /// 会话累计 token（含缓存读取，与电脑端 `113M tok` 同一口径）；`null` = 未知。
  final int? totalTokens;

  /// 缓存命中率（%）；`null` = 未知 → 省略。
  final int? cacheHitPercent;

  /// 点了某一段。`null` 时整条不可点。
  final ValueChanged<SessionInsightSection>? onTapSection;

  /// 长连接状态。`null` = **还不知道**（沿用本文件的"未知即隐藏"规则）；
  /// [SessionConnectionState.connected] 同样隐藏 —— 一切正常时不占位置。
  ///
  /// 与 `isRunning` 分开：那个说的是"这一轮在跑"，这个说的是"我还能不能把话
  /// 发出去"。两者同时为真很常见（回合在跑，同时连接在抖）。
  final SessionConnectionState? connection;

  /// 断开状态下点这一段时调用的重连动作。为 null 时这一段不可点 ——
  /// 但文案仍然是"已断开"，不会退化成一句不可点的死标签却不说明原因。
  final VoidCallback? onReconnect;

  /// 当前会话**之外**还有几个会话在跑（Phase 5.2）。
  ///
  /// 为什么这个数字放在状态条而不是 AppBar 再加一行：状态条是"这个 App 现在
  /// 什么样"的唯一常驻读数位，而"还有别的会话在跑"正是同一类事实；更重要的是
  /// 它挂在 `AppBar.bottom`，键盘弹起时不参与压缩 —— 加一行标题会挤掉会话名。
  ///
  /// `null` = 未知（工作区列表还没拉到）→ 整段隐藏。绝不显示 `0`：`0` 在用户
  /// 眼里是"没有别的会话在跑"，而真相可能是"我根本没拉过工作区列表"。
  final int? runningElsewhereCount;

  /// 点"另外 N 个会话执行中"时打开会话选择。为 null 时该段不可点（但仍显示，
  /// 因为"还有别的东西在跑"这个事实本身有价值）。
  final VoidCallback? onTapRunningElsewhere;

  /// 低于这个比例不画进度线——常态下这一条要尽量安静。
  static const double pressureLineThreshold = 0.70;

  /// 高风险阈值：与 `chat_view` 输入框上方那条告警共用同一个数。
  static const double pressureCriticalThreshold = 0.85;

  static const double _rowHeight = 34;

  /// 有没有任何东西可显示。没有就只留 1px 分隔线，**不留一条空白带**。
  bool get hasContent =>
      isRunning ||
      _showConnection ||
      (runningElsewhereCount ?? 0) > 0 ||
      deliverableCount != null ||
      (changeCount != null && !changesUnavailable) ||
      contextFraction != null ||
      turns != null ||
      steps != null ||
      totalTokens != null ||
      (liveJobCount != null && liveJobCount! > 0);

  /// 连接状态段只在"非正常"时出现：连上 = 隐藏，未知 = 隐藏。
  bool get _showConnection =>
      connection != null && connection != SessionConnectionState.connected;

  /// 紧凑数字：与电脑端一致（`113M tok` / `12.4k`）。
  ///
  /// 六位数以上**截断**而不是四舍五入：电脑端把 113,704,827 显示成 `113M`，四舍五入
  /// 会得到 `114M` —— 同一个数字在两块屏幕上不一样，用户会以为是两个会话。
  static String compactTokens(int value) {
    if (value >= 1000000) {
      final millions = value / 1000000;
      return '${millions >= 10 ? millions.floor() : millions.toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      final thousands = value / 1000;
      return '${thousands >= 10 ? thousands.floor() : thousands.toStringAsFixed(1)}k';
    }
    return '$value';
  }

  /// 解码速度的显示口径与电脑端 `formatTokensPerSecond` 一致：
  /// 10 以上取整，10 以下保留一位（`210` / `9.8`）。
  static String formatTokensPerSecond(double tps) {
    final clamped = tps < 0 ? 0.0 : tps;
    return clamped >= 10
        ? clamped.round().toString()
        : clamped.toStringAsFixed(1);
  }

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

  /// 连接状态段：重连中 = warning + 呼吸点；断开 = danger + 可点重连。
  Widget _buildConnectionSegment(BuildContext context) {
    final reconnecting = connection == SessionConnectionState.reconnecting;
    final color = reconnecting ? context.c.warning : context.c.danger;
    final label = reconnecting ? '连接中…' : '已断开 · 点击重连';
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        key: const ValueKey('strip-connection'),
        borderRadius: BorderRadius.circular(6),
        // 重连中是引擎自己在退避重试，再点一次只会多打一个请求 —— 按钮保持
        // 不可点，但文案说清"正在连"，用户不会以为它卡死了。
        onTap: reconnecting ? null : onReconnect,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (reconnecting)
                _ConnectingDot(color: color)
              else
                Container(
                  width: 6,
                  height: 6,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
              const SizedBox(width: 4),
              Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

    // [feat 2026-10-17] Phase 5.2：当前会话之外还有会话在跑。
    //
    // 放在**最左**：它是"这台手机之外还有人/还有活在跑"的警示，比用量明细更该
    // 先被看到。用 accent 而不是 danger —— 别处有活在跑不是错误，只是用户可能
    // 想切过去看一眼（尤其是等结果的时候）。
    //
    // 数字来源是工作区列表里的 isRunning 聚合（见 `chat_dock.dart`）。那是个
    // 可能过期的快照，所以这里只做"有/没有 + 几个"的粗粒度提示，不做精确进度。
    final others = runningElsewhereCount;
    if (others != null && others > 0) {
      segments.add(InkWell(
        key: const ValueKey('strip-other-running'),
        borderRadius: BorderRadius.circular(6),
        onTap: onTapRunningElsewhere,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bolt_rounded, size: 12, color: context.c.accent),
              const SizedBox(width: 2),
              Text(
                '另外 $others 个会话执行中',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: context.c.accent,
                ),
              ),
            ],
          ),
        ),
      ));
    }

    void addSegment(
        {required Key key,
        required Widget child,
        required SessionInsightSection section}) {
      if (segments.isNotEmpty) {
        segments.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('·',
              style: TextStyle(fontSize: 11, color: context.c.textTertiary)),
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

    // 电脑端状态条第一组：`6 轮 351 步 · 210 tok/s`。
    //
    // 只在 steps > 0 时显示：全新会话显示 `0 轮 0 步` 没有任何信息量（电脑端也是
    // 同一个门槛）。但 `0` 本身是**已知真值**，所以门槛是"有没有跑过"，不是"读没读到"。
    if ((steps ?? 0) > 0) {
      final counts = [
        if (turns != null) '$turns 轮',
        if (steps != null) '$steps 步',
      ].join(' ');
      final tps = tokensPerSecond;
      addSegment(
        key: const ValueKey('strip-segment-counts'),
        section: SessionInsightSection.usage,
        child: Text(
          tps == null
              ? counts
              : '$counts · ${formatTokensPerSecond(tps)} tok/s',
          style: TextStyle(fontSize: 11.5, color: context.c.textSecondary),
        ),
      );
    }

    // 第二组：`113M tok · 缓存命中 99%`。
    //
    // 口径与电脑端一致：这里的"累计"**含缓存读取**，因为电脑端那个 pill 就是
    // `未缓存输入 + 缓存读取 + 输出` = 网关的 `totalTokens`。而"消耗"是另一个口径
    // （未缓存输入 + 输出），那个在信息面板里，两者不能混。
    if ((totalTokens ?? 0) > 0) {
      final hit = cacheHitPercent;
      addSegment(
        key: const ValueKey('strip-segment-tokens'),
        section: SessionInsightSection.usage,
        child: Text(
          hit == null
              ? '${compactTokens(totalTokens!)} tok'
              : '${compactTokens(totalTokens!)} tok · 缓存命中 $hit%',
          style: TextStyle(fontSize: 11.5, color: context.c.textSecondary),
        ),
      );
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
                : (count > 0
                    ? context.c.textSecondary
                    : context.c.textTertiary),
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
            Text('上下文 $pct%',
                style:
                    TextStyle(fontSize: 11.5, color: _contextColor(context))),
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
                // 最左端：连接状态（v1.27）。连上/未知时**整段不渲染**，所以正常
                // 使用下这一行的左端和以前一模一样。
                if (_showConnection) _buildConnectionSegment(context),
                if (isRunning)
                  Container(
                    key: const ValueKey('strip-running'),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: context.c.accent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                      border:
                          Border.all(color: context.c.accent.withOpacity(0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 7,
                          height: 7,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.4, color: context.c.accent),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '执行中',
                          style: TextStyle(
                              color: context.c.accent,
                              fontSize: 9.5,
                              fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                // 空白区域也可点：用户想看的细节就在面板里，不必非得点中某个数字。
                Expanded(
                  child: InkWell(
                    onTap: onTapSection == null
                        ? null
                        : () => onTapSection!(SessionInsightSection.usage),
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

/// 「连接中…」前面那个会呼吸的小圆点。
///
/// 单独一个 StatefulWidget 而不是在 [SessionStatusStrip] 里开控制器：状态条是
/// `PreferredSizeWidget`、每次 build 都会被重建，把动画控制器挂在它上面会让
/// 圆点每帧重新开始呼吸。这里自己持有并**在 dispose 里释放** —— 一个没人看的
/// 无限动画在状态条被移除后继续跑，既是电也是"明明断开了还在跳"的假象。
class _ConnectingDot extends StatefulWidget {
  const _ConnectingDot({required this.color});

  final Color color;

  @override
  State<_ConnectingDot> createState() => _ConnectingDotState();
}

class _ConnectingDotState extends State<_ConnectingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) {
        // 三角波（0→1→0）：没有 TweenSequence 那么花，但"在动"这件事一眼就够。
        final wave = 1 - (2 * _controller.value - 1).abs();
        return Container(
          key: const ValueKey('strip-connection-dot'),
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: widget.color.withOpacity(0.35 + 0.65 * wave),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}
