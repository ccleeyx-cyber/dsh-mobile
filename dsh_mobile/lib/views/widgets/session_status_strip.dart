import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// 信息面板里可以被"点名跳过去"的小节。
///
/// 定义在事件带这一侧：带上的每一段点击后要打开面板并滚到对应小节，
/// 所以"有哪些小节"这件事的归属方是事件带（生产者），面板只是消费者。
enum SessionInsightSection { usage, deliverables, changes, jobs, schedules }

/// 与网关的长连接状态。
///
/// 三态各自对应一个**完全不同的用户处境**，所以不能合并成一个布尔：
/// * [connected]：正常，**整段隐藏** —— 它占着最显眼的位置却零信息量。
/// * [reconnecting]：正在自动重连（指数退避），用户此刻发什么都可能失败，
///   需要知道"不是我操作错了，是还在连"，所以给一个会呼吸的点。
/// * [disconnected]：已经放弃自动重试（或首次连接就失败）。**这里刻意不报** ——
///   那样会和 `ChatTopBanners` 的「网络连接已断开 + 点击重试」横幅把同一条事实
///   说两遍（真机截图里就是这么重复的）。横幅有完整的动作和解释，那句话该待在
///   那里；而"正在重连"是横幅表达不了的，所以留在带上。
enum SessionConnectionState { connected, reconnecting, disconnected }

/// 会话事件带（2026-10-17 改版，原「会话状态条」）。
///
/// ## 它为什么从"数字清单"变成"事件带"
///
/// 旧版把 8 组读数（轮/步、tok/s、累计 tok、缓存命中、产出、改动、上下文、
/// 别处执行中）串在一条 34dp 的横滑带里。真机上这条带**必然溢出**——360dp 屏
/// 会被硬裁在「改动」处，于是加了一条 14dp 渐隐去遮掩，那等于承认"有一半读数
/// 用户看不到"。同时会话名只有 13pt，比这些数字大 1.5pt，整个顶部没有主次。
///
/// 现在分工写死：
/// * **身份**（会话名 15pt + 工作区 + 上下文占用）→ `ChatAppBar` 标题第二行，
///   常驻、不横滑、不截断（工作区名挤不下时优先省略它自己）。
/// * **需要你当场反应的事** → 这条带，按阈值出现，`hasContent == false` 时
///   只留 1dp 分隔线。
/// * **数量类读数**（轮/步、tok/s、累计 tok、缓存命中、改动数、产出总数）→
///   会话信息面板。它们本来就是"翻明细"才看的东西。
///
/// ## 三条硬规则
///
/// 1. **未知即隐藏。** 每个字段可空，`null` 一律表示"读不到/还没拉过"，整段不渲染。
///    绝不把未知渲染成 `0`：`改动 0` 在用户眼里是"工作区是干净的"，而真相可能是
///    "网关没读出来"或"这不是 git 仓库"。
/// 2. **只放事件，不放状态。** "产出 3" 是状态，"产出 3（未读）" 才是事件 ——
///    读过的产出不该继续占领顶部。所以这里出现 `产出 N` 的唯一条件是未读。
/// 3. **顶部而非输入框上方。** 它挂在 `AppBar.bottom`，键盘弹起时不参与压缩，
///    所以打字时依然可读；输入框上方那块空间留给"我要发的话"和阈值触发的告警。
class SessionStatusStrip extends StatelessWidget
    implements PreferredSizeWidget {
  const SessionStatusStrip({
    super.key,
    this.liveJobCount,
    this.runningElsewhereCount,
    this.onTapSection,
    this.onTapRunningElsewhere,
    this.connection,
  });

  /// 仍在跑的后台作业数；`null` / `0` = 不渲染。
  final int? liveJobCount;

  /// 当前会话**之外**还有几个会话在跑；`null` / `0` = 不渲染。
  final int? runningElsewhereCount;

  /// 点了带上的某一段（按小节）。
  final ValueChanged<SessionInsightSection>? onTapSection;

  /// 点了「N 个在跑」：打开会话选择器。它与其它段的目的地不同，不能共用一个回调。
  final VoidCallback? onTapRunningElsewhere;

  /// 长连接状态；`null` = 还不知道。
  final SessionConnectionState? connection;

  /// 上下文压力线的阈值（百分比）。
  ///
  /// 数字本身已经不在这里显示了，但这两个阈值仍被输入框上方的告警
  /// （`composer.dart`）和信息面板（`session_info_sheet.dart`）共用，所以留在
  /// 本类上是"同一个口径只有一个出处"，不是遗留。
  static const double pressureLineThreshold = 0.70;

  /// 高风险阈值：与输入框上方那条告警共用同一个数。
  static const double pressureCriticalThreshold = 0.85;

  /// 带的高度。36 是"胶囊 24 + 上下各 6"的结果 —— 胶囊的整个 36dp 都是热区，
  /// 比旧实现（`InkWell` + 上下 2dp padding，实际约 20dp）翻了近一倍。
  static const double rowHeight = 36;

  /// 胶囊高度。
  static const double _pillHeight = 24;

  /// 右边缘渐隐带的宽度（见 build 里 ShaderMask 处的说明）。
  static const double _edgeFadeWidth = 14;

  /// 解码速度的显示口径（与电脑端一致）：10 以上取整，10 以下保留一位
  /// （`210` / `9.8`）。
  ///
  /// 顶部已经不显示 tok/s 了，但信息面板（`session_info_sheet.dart`）仍在用它，
  /// 口径只有一个出处：同一个会话在两块屏幕上不该出现两个数字。
  static String formatTokensPerSecond(double tps) {
    final clamped = tps < 0 ? 0.0 : tps;
    return clamped >= 10
        ? clamped.round().toString()
        : clamped.toStringAsFixed(1);
  }

  bool get _showConnection => connection == SessionConnectionState.reconnecting;

  bool get _showJobs => (liveJobCount ?? 0) > 0;

  bool get _showOthers => (runningElsewhereCount ?? 0) > 0;

  /// 有没有任何事件可报。没有就只留 1dp 分隔线，**不留一条空白带**。
  ///
  /// [fix 2026-10-17 用户反馈] 「产出 N」不再是这一带的一段：它曾被摆成顶栏下方
  /// 单独一行的胶囊，用户的原话是"产出单独一行太突兀"。现在它作为一枚紧凑徽标
  /// 挂在 `ChatAppBar` 的**标题行右端**，这条带只保留真正需要当场反应的临时事件。
  bool get hasContent => _showConnection || _showJobs || _showOthers;

  @override
  Size get preferredSize => Size.fromHeight(hasContent ? rowHeight : 1);

  /// 一颗胶囊。整个 36dp 高度都可点，视觉上只有 24dp 的底。
  Widget _pill(
    BuildContext context, {
    required Key key,
    required String label,
    required Color foreground,
    Color? background,
    Widget? leading,
    VoidCallback? onTap,
    FontWeight fontWeight = FontWeight.w600,
  }) {
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(_pillHeight / 2),
      onTap: onTap,
      child: Container(
        height: rowHeight,
        // 水平方向留一点外扩，让两枚相邻胶囊的点击区不粘连。
        padding: const EdgeInsets.symmetric(horizontal: 2),
        alignment: Alignment.center,
        child: Container(
          height: _pillHeight,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(_pillHeight / 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[
                leading,
                const SizedBox(width: 5),
              ],
              Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: AppText.subhead,
                  fontWeight: fontWeight,
                  color: foreground,
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
      // 没有任何事件：只保留那条分隔线，高度 1。
      return Container(
        key: const ValueKey('session-status-strip-empty'),
        color: context.c.surface,
        child: border,
      );
    }

    final chips = <Widget>[];
    void addChip(Widget chip) {
      if (chips.isNotEmpty) chips.add(const SizedBox(width: AppSpace.s));
      chips.add(chip);
    }

    if (_showConnection) {
      addChip(_pill(
        context,
        key: const ValueKey('strip-connection'),
        label: '连接中…',
        foreground: context.c.warning,
        background: context.c.warning.withOpacity(0.10),
        // 重连中是引擎自己在退避重试，再点一次只会多打请求 —— 不可点，但文案说清
        // "正在连"，用户不会以为它卡死了。
        onTap: null,
        leading: _ConnectingDot(color: context.c.warning),
      ));
    }

    if (_showJobs) {
      addChip(_pill(
        context,
        key: const ValueKey('strip-segment-jobs'),
        label: '运行中 $liveJobCount',
        foreground: context.c.accent,
        background: context.c.accent.withOpacity(0.12),
        onTap: onTapSection == null
            ? null
            : () => onTapSection!(SessionInsightSection.jobs),
      ));
    }

    if (_showOthers) {
      // 不用上面那个"打开信息面板"的回调：这一段要去的是会话选择器，两者是不同
      // 的目的地，共用一个回调只会互相抢状态。
      addChip(_pill(
        context,
        key: const ValueKey('strip-other-running'),
        label: '$runningElsewhereCount 个在跑',
        foreground: context.c.accent,
        background: context.c.accent.withOpacity(0.12),
        onTap: onTapRunningElsewhere,
        leading: Icon(Icons.bolt_rounded, size: 12, color: context.c.accent),
      ));
    }

    return Container(
      key: const ValueKey('session-status-strip'),
      // 分隔线画在容器自己的 decoration 上（不占布局高度）：这样胶囊可以正好
      // 拿到 36dp 的整高热区，而整条带的高度仍然是 rowHeight。
      decoration: BoxDecoration(
        color: context.c.surface,
        border: Border(bottom: BorderSide(color: context.c.border)),
      ),
      child: SizedBox(
        height: rowHeight,
        child: Row(
          children: [
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                // 右边缘渐隐：表达"后面还有内容、它是被卷走的，不是丢了"。
                // 内容装得下时这 14dp 落在尾部留白上，不会把真实内容变淡。
                child: ShaderMask(
                  shaderCallback: (rect) {
                    final w = rect.width;
                    final fadeStart =
                        w <= _edgeFadeWidth ? 0.0 : (w - _edgeFadeWidth) / w;
                    return LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: const [
                        Colors.black,
                        Colors.black,
                        Colors.transparent,
                      ],
                      stops: [0.0, fadeStart, 1.0],
                    ).createShader(rect);
                  },
                  blendMode: BlendMode.dstIn,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: chips),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「连接中…」前面那个会呼吸的小圆点。
///
/// 单独一个 StatefulWidget 而不是在 [SessionStatusStrip] 里开控制器：事件带是
/// `PreferredSizeWidget`、每次 build 都会被重建，把动画控制器挂在它上面会让
/// 圆点每帧重新开始呼吸。这里自己持有并**在 dispose 里释放** —— 一个没人看的
/// 无限动画在事件带被移除后继续跑，既是电也是"明明断开了还在跳"的假象。
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
