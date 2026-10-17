/// 聊天页的固定壳层（dock 与顶栏 / 横幅）。
///
/// Phase 0 结构拆分（纯剪切）：从 `chat_view.dart` 原样搬出，逻辑与样式一字未改。
///
/// 这里装的是三块**不属于消息流、也不属于输入区**的东西：
/// * `ChatAppBar` —— 顶栏（双行身份）+ 事件带 + 会话信息入口；
/// * `ChatTopBanners` —— 断线/错误/别处提问/待授权四条横幅；
/// * `ChatBlockerDock` —— 审批卡与提问卡的固定 dock（带显式限高）。
/// 它们的共同点：都是"要用户当场决策或当场知情"的固定层，位置与消息流的滚动无关。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/approval_request.dart';
import '../../models/task_center.dart';
import '../../models/workspace.dart';
import '../../services/dsh_service.dart';
import '../../services/notification_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/approval_card.dart';
import '../config_page.dart';
import 'attachment_tile.dart';
import 'question_card.dart';
import 'session_status_strip.dart';

/// dock（审批卡 / 提问卡 / TODO / 附件）最多占屏幕高度的多少。
///
/// 这些卡片会一起涨：多张审批、多个提问、几张附件，再乘上系统字号。超过这个
/// 比例就把剩余空间让回消息流和输入栏 —— 输入栏必须始终可见可点，那是唯一
/// 能发消息的地方。
///
/// [fix 2026-10-17] 从 0.55 收到 0.45。真机上（851dp 高）叠上顶栏 60 + 状态条 34
/// + 断线横幅 70 之后，0.55 会让消息流只剩不到 200dp —— 一张审批卡就把"我刚在
/// 看的那段回复"挤出屏幕，而审批恰恰是让你**边看边决定**的东西。0.45 仍然放得下
/// 一张完整审批卡，多出来的内容交给 dock 自己的滚动。
const double _dockMaxHeightFraction = 0.45;

/// 顶栏：会话身份（名称 + 权限 + 工作区 + 上下文）+ 两个高频动作。
///
/// ## 2026-10-17 改版（方案 A）
///
/// 旧版是「56dp 单行标题（13pt）+ 34dp 状态数字条」，合计 91dp 常驻。真机上那条
/// 数字带**必然溢出**：360dp 屏被硬裁在「改动」处，只能靠一条 14dp 渐隐去遮掩。
/// 而会话名只比这些数字大 1.5pt —— 整个顶部没有主次，用户的第一反应是"看着不
/// 对劲"，却说不清哪里不对。
///
/// 现在换成**双行身份栏 52dp + 按需出现的事件带**：
///
/// * 第一行：会话名 15pt/w600（`AppText.heading`）—— 这才是这一页的主标识；
/// * 第二行：`●执行中 · 📁工作区 · 上下文 62%`（11.5pt），都是"这个会话是什么"
///   的一部分，常驻、不横滑、不换行（挤不下时优先省略工作区名）；
/// * 第三行（`bottom`）：事件带，只有需要当场反应的事才出现（见
///   `SessionStatusStrip`）。常态高度 1dp。
///
/// 高度账：常态 52 + 1 = 53dp（旧版 90dp，省 37dp）；执行中或有未读产出时
/// 52 + 36 = 88dp。
///
/// 数量类读数的去向也写死：轮/步、tok/s、累计 tok、缓存命中、改动数、产出总数
/// 全部进会话信息面板 —— 它们本来就是"翻明细"才看的东西。顶部只留**会变、且
/// 需要你反应**的那几样，否则永远是在 34dp 里塞 8 组数字。
class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatAppBar({
    super.key,
    required this.dsh,
    required this.currentSession,
    required this.policy,
    required this.isSessionRunning,
    required this.workspaceTitle,
    required this.searchOpen,
    required this.deliverablesUnread,
    required this.liveJobCount,
    required this.onOpenSessionInfo,
    required this.onToggleSearch,
    required this.onBackToWorkspaces,
  });

  final DshService dsh;
  final SessionMeta? currentSession;
  final String policy;
  final bool isSessionRunning;
  final String? workspaceTitle;
  final bool searchOpen;
  final bool deliverablesUnread;
  final int? liveJobCount;
  final ValueChanged<SessionInsightSection> onOpenSessionInfo;
  final VoidCallback onToggleSearch;

  /// 回到会话列表（工作区 tab）。
  ///
  /// 这个动作**早就存在**了：`main_shell.dart` 的 `PopScope` 把"对话页侧滑返回"
  /// 映射成切到工作区 tab。只是界面上从来没有可见入口 —— 用户能做的事，看不见。
  /// 现在它是顶栏左侧那个 48dp 按钮，与侧滑返回是同一件事。
  final VoidCallback onBackToWorkspaces;

  /// 工具栏高度。
  ///
  /// 52 = 两行身份（15pt 行 ≈ 19 + 2 间距 + 11.5pt 行 ≈ 15 = 36）上下各留 8。
  static const double toolbarHeight = 52;

  /// 事件带。`preferredSize` 与 `build` 用的必须是**同一套入参**，否则 Scaffold
  /// 给顶栏的高度会和实际渲染不一致（旧版正是把 `preferredSize` 写死成
  /// `kToolbarHeight`，而 `bottom` 另外又长了 34dp）。
  SessionStatusStrip _eventStrip(BuildContext? context) {
    return SessionStatusStrip(
      liveJobCount: liveJobCount,
      runningElsewhereCount: _runningElsewhere(dsh, currentSession?.sessionId),
      onTapSection: (section) => onOpenSessionInfo(section),
      onTapRunningElsewhere:
          context == null ? null : () => _showOtherRunningSheet(context, dsh),
      // 连接状态：连上时**不渲染**（沿用「未知即隐藏」的同一原则 —— "一切正常"
      // 不需要占一行像素）。只有真正在重连时才出现，因为那时用户发消息会石沉
      // 大海，而界面上此前没有任何提示。
      connection: dsh.isConnected
          ? SessionConnectionState.connected
          : (dsh.isReconnecting ||
                  (dsh.reconnectAttempts > 0 && !dsh.reconnectExhausted))
              ? SessionConnectionState.reconnecting
              : SessionConnectionState.disconnected,
    );
  }

  @override
  Size get preferredSize =>
      Size.fromHeight(toolbarHeight + _eventStrip(null).preferredSize.height);

  @override
  Widget build(BuildContext context) {
    final stats = dsh.sessionStats;

    return AppBar(
      backgroundColor: context.c.surface,
      toolbarHeight: toolbarHeight,
      elevation: 0,
      scrolledUnderElevation: 0,
      // 48 而不是默认 56：给标题再多 8dp，而 48 已经满足最小触控。
      leadingWidth: 48,
      leading: IconButton(
        key: const ValueKey('chat-back-to-sessions'),
        tooltip: '会话列表',
        iconSize: 22,
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.arrow_back_rounded),
        // 与 PopScope 同一条动线：离开会话 = 回工作区 tab。
        onPressed: onBackToWorkspaces,
      ),
      titleSpacing: 8,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // 权限状态。旧版是个 7px 实心点、只有三种颜色 —— 全权执行和每次
              // 询问在色觉障碍用户眼里是同一个点，而那两件事的后果天差地别。
              // 现在加了**形状**这一路编码（实心＝不再询问，空心＝还在问），
              // 颜色只是第二通道。
              _PolicyRing(policy: policy),
              const SizedBox(width: 7),
              // 会话名吃掉剩余宽度；挤不下时省略的是工作区名，不是它。
              Flexible(
                child: Text(
                  currentSession?.title ?? '新会话',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppText.heading,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                    color: context.c.textPrimary,
                  ),
                ),
              ),
              // [fix 2026-10-17 用户反馈] 产出从"事件带单独一行胶囊"改成标题行
              // 右端的一枚紧凑徽标：📦 N。它和会话名同一行、贴着右端，视觉上
              // 是标题的附属信息而不是一条横带。标题是 Flexible，挤不下时让位
              // 的是标题文字，绝不会有整行溢出。
              if ((dsh.deliverableCount ?? 0) > 0) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      onOpenSessionInfo(SessionInsightSection.deliverables),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: deliverablesUnread
                          ? context.c.accent.withOpacity(0.12)
                          : context.c.surfaceMuted,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.inventory_2_outlined,
                          size: 11,
                          color: deliverablesUnread
                              ? context.c.accent
                              : context.c.textTertiary,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '${dsh.deliverableCount}',
                          key: const ValueKey('chat-deliverable-count'),
                          style: TextStyle(
                            fontSize: AppText.caption,
                            fontWeight: deliverablesUnread
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: deliverablesUnread
                                ? context.c.accent
                                : context.c.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          _metaRow(context, stats),
        ],
      ),
      // 顶栏从「新建 / 查找 / 更多」收敛到「查找 / 信息面板」两个（2026-10-17）。
      //
      // 「新建对话」与其余会话域动作都在信息面板里：它们同属一类，且低频。
      // 图标从 `tune_rounded` 换成 `info_outline_rounded` —— 它打开的确实是
      // "会话现在是什么样"的面板，调节滑块的语义会让人以为要改什么设置。
      actions: [
        IconButton(
          tooltip: '在当前会话中查找',
          iconSize: 22,
          icon: Icon(
            searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
            color: searchOpen ? context.c.accent : context.c.textPrimary,
          ),
          onPressed: onToggleSearch,
        ),
        IconButton(
          key: const ValueKey('chat-open-session-info'),
          tooltip: '会话信息与操作',
          iconSize: 22,
          icon: Icon(Icons.info_outline_rounded, color: context.c.textPrimary),
          onPressed: () => onOpenSessionInfo(SessionInsightSection.usage),
        ),
      ],
      bottom: _eventStrip(context),
    );
  }

  /// 第二行：这个会话"是什么" —— 运行态 + 归属工作区 + 上下文占用。
  ///
  /// 为什么工作区必须常驻而不是收进面板：不同工作区可以有**同名会话**，
  /// 而从通知/深链接/搜索结果跳进来时（`openSessionById`），界面上原本完全看不出
  /// 这是哪个工作区的会话。查不到归属时**整段不渲染**（见
  /// `workspaceOfCurrentSession`）—— 宁可没有，也不能显示一个可能是"隔壁工作区"的名字。
  ///
  /// 为什么上下文放在这里而不是事件带：它天天在变，却不是"需要你反应"的事；
  /// 只有越过 70% / 85% 两档时才换色（橙 / 红），那时它自己会跳出来。
  Widget _metaRow(BuildContext context, SessionStats? stats) {
    final ctx = stats?.contextFraction;
    final base = TextStyle(
      fontSize: AppText.subhead,
      color: context.c.textTertiary,
      height: 1.3,
    );

    return Row(
      children: [
        if (isSessionRunning) ...[
          SizedBox(
            width: 7,
            height: 7,
            child: CircularProgressIndicator(
              strokeWidth: 1.4,
              color: context.c.accent,
            ),
          ),
          const SizedBox(width: 4),
          // 全页面**只有这一处**说"执行中"。旧版顶栏徽标和状态条各渲染一次，
          // 同一个事实说两遍（两条的样式还不一样）。
          Text(
            '执行中',
            key: const ValueKey('chat-running-badge'),
            style: base.copyWith(
              color: context.c.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (workspaceTitle != null || ctx != null) _metaDot(context),
        ],
        if (workspaceTitle != null) ...[
          Icon(Icons.folder_outlined, size: 10, color: context.c.textTertiary),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              workspaceTitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: base,
            ),
          ),
        ],
        if (ctx != null) ...[
          if (workspaceTitle != null) _metaDot(context),
          Text(
            '上下文 ${(ctx * 100).round()}%',
            key: const ValueKey('chat-context-usage'),
            style: base.copyWith(color: _contextColor(context, ctx)),
          ),
          if (stats?.isSnapshot ?? false) ...[
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
      ],
    );
  }

  Widget _metaDot(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Text('·',
          style: TextStyle(
            fontSize: AppText.subhead,
            color: context.c.textTertiary.withOpacity(0.55),
          )),
    );
  }

  /// 上下文占用越高越显眼：≥85% 危险红、>70% 警告橙、其余中性。
  Color _contextColor(BuildContext context, double fraction) {
    if (fraction >= SessionStatusStrip.pressureCriticalThreshold) {
      return context.c.danger;
    }
    if (fraction > SessionStatusStrip.pressureLineThreshold) {
      return context.c.warning;
    }
    return context.c.textTertiary;
  }

  /// 当前会话之外还有几个会话在跑；**未知返回 null**（工作区列表还没拉到）。
  ///
  /// 三条口径，别改：
  /// 1. `dsh.workspaces` 为空 = 还没拉过（不是"没有工作区"）→ `null`，调用方
  ///    据此整段隐藏。显示 `0` 会被读成"没有别的东西在跑"，那是编出来的结论。
  /// 2. 按 sessionId 去重：同一个会话可能同时出现在"当前工作区的 sessions"和
  ///    别处（工作区列表与当前会话是两条来源）。
  /// 3. 不含当前会话自己 —— 当前会话在跑由状态条左边那个「执行中」徽标负责，
  ///    两处都报一遍等于同一个事实说两次。
  static int? _runningElsewhere(DshService dsh, String? currentSessionId) {
    final workspaces = dsh.workspaces;
    if (workspaces.isEmpty) return null;
    final seen = <String>{};
    var count = 0;
    for (final w in workspaces) {
      for (final s in w.sessions) {
        if (!s.isRunning) continue;
        if (currentSessionId != null &&
            s.matchesSessionId(currentSessionId)) {
          continue;
        }
        if (seen.add(s.sessionId)) count++;
      }
    }
    return count;
  }

  /// 「另外 N 个会话执行中」的会话选择弹层。
  void _showOtherRunningSheet(BuildContext context, DshService dsh) {
    final currentSessionId = currentSession?.sessionId;
    final rows = <({SessionMeta session, String? workspaceTitle})>[];
    final seen = <String>{};
    for (final w in dsh.workspaces) {
      for (final s in w.sessions) {
        if (!s.isRunning) continue;
        if (currentSessionId != null &&
            s.matchesSessionId(currentSessionId)) {
          continue;
        }
        if (seen.add(s.sessionId)) {
          rows.add((session: s, workspaceTitle: w.title));
        }
      }
    }
    if (rows.isEmpty) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                '${rows.length} 个会话正在执行',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: sheetCtx.c.textPrimary,
                ),
              ),
            ),
            for (final row in rows)
              InkWell(
                key: ValueKey('other-running-${row.session.sessionId}'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  // 用 id 打开（不是标题）：不同工作区可以有同名会话。
                  dsh.openSessionById(
                    row.session.sessionId,
                    title: row.session.title,
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: sheetCtx.c.accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              row.session.title.isEmpty ? '未命名会话' : row.session.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                color: sheetCtx.c.textPrimary,
                              ),
                            ),
                            if (row.workspaceTitle != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  row.workspaceTitle!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: sheetCtx.c.textTertiary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: sheetCtx.c.textTertiary,
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// 当前权限状态：环 + 实心/空心双通道。
///
/// 旧版是 `_getPolicyColor` + 一个 7px **实心**圆点，只靠三种颜色区分
/// `danger-full-access` / `auto-read` / `ask`。问题不是好不好看：全权执行和
/// 每次询问在色觉障碍用户眼里是同一个点，而这两件事的后果天差地别。
/// 现在加了一路**形状**编码（实心＝不再询问，空心＝还在问），颜色退为第二通道；
/// Tooltip / Semantics 也给完整文案，不再需要用户猜。
class _PolicyRing extends StatelessWidget {
  const _PolicyRing({required this.policy});

  final String policy;

  @override
  Widget build(BuildContext context) {
    final color = switch (policy) {
      'danger-full-access' => context.c.success,
      'auto-read' => context.c.accent,
      _ => context.c.warning,
    };
    final label = switch (policy) {
      'danger-full-access' => '完全访问（不再询问）',
      'auto-read' => '只读自动执行',
      _ => '每次询问',
    };
    final filled = policy == 'danger-full-access';
    return Tooltip(
      message: '当前权限：$label',
      child: Semantics(
        label: '当前权限：$label',
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? color : Colors.transparent,
            border: Border.all(color: color, width: 2),
          ),
        ),
      ),
    );
  }
}

/// 四条横幅：断线重连 / 全局错误 / 别处提问 / 待授权。
class ChatTopBanners extends StatelessWidget {
  const ChatTopBanners({
    super.key,
    required this.dsh,
    required this.activeApprovals,
    required this.onScrollToBottom,
  });

  final DshService dsh;
  final List<ApprovalRequest> activeApprovals;
  final VoidCallback onScrollToBottom;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 1. Offline & Reconnecting Status Banner (F3.4)
        if (!dsh.isConnected)
          _buildOfflineBanner(context, dsh),

        // Global Error Alert Bar (Only when connected, preventing duplicate red alerts)
        if (dsh.lastError.isNotEmpty && dsh.isConnected)
          Container(
            margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: context.c.dangerSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.c.dangerBorder),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded, color: context.c.danger, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    dsh.lastError,
                    style: TextStyle(color: context.c.danger, fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                GestureDetector(
                  onTap: () => dsh.clearError(),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(Icons.close_rounded, color: context.c.textSecondary, size: 16),
                  ),
                ),
              ],
            ),
          ),

        // 其他会话的提问横幅（v1.11.4）。
        //
        // 提问卡片只渲染**当前会话**的（否则会把别的会话的问题挂到你面前）。
        // 但那带来一个死角：agent 在会话 B 停下来等你回答，而你在会话 A 或
        // 别的 tab —— 屏幕上什么都没有，也没有通知，你会以为它一直在跑
        // （用户实测到的"提问没显示、也没通知"就是这个死角）。
        // 这里补上一条可点击的提示，把"别处有人在等你"说出来。
        if (_otherSessionQuestionCount(dsh) > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: context.c.warningBadgeSurface,
              border: Border(bottom: BorderSide(color: context.c.warning, width: 1)),
            ),
            child: Row(
              children: [
                Icon(Icons.help_outline_rounded, size: 16, color: context.c.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '其他会话有 ${_otherSessionQuestionCount(dsh)} 个提问在等你回答',
                    style: TextStyle(color: context.c.warning, fontSize: 12.5, fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    backgroundColor: context.c.surface.withOpacity(0.8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: () => _jumpToQuestionSession(dsh),
                  icon: Icon(Icons.arrow_forward_rounded, size: 14, color: context.c.warning),
                  label: Text('去回答', style: TextStyle(color: context.c.warning, fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ],
            ),
          ),

        // Pending Tool Approvals Banner
        //
        // [fix 2026-10-17] 只在**审批不属于当前会话**时出现。
        //
        // 真机截图暴露的问题：当前会话的审批卡本来就钉在输入框上方的 dock 里、
        // 一直可见，而这条横幅又用几乎同样的文案再说一遍（还带一个"滚动查看"
        // 按钮）。于是一屏里同一件事出现三次：横幅、审批卡、输入框里的待办胶囊。
        // 横幅真正不可替代的场景是"别的会话在等你" —— 那批卡片不在这个屏上，
        // 不说用户就永远不知道。
        if (dsh.pendingApprovals.isNotEmpty && activeApprovals.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [context.c.warningBadgeSurface, context.c.warningBorder],
              ),
              border: Border(
                bottom: BorderSide(color: context.c.warning, width: 1.0),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: context.c.warning,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.priority_high_rounded, color: Colors.white, size: 14),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        // 走到这里时 activeApprovals 必为空（见上面那条 if），
                        // 所以文案固定是"其他会话"——当前会话的审批由 dock 里的
                        // 卡片本身表达，不需要第二份说明。
                        '其他会话有 ${dsh.pendingApprovals.length} 个工具操作等待授权',
                        style: TextStyle(
                          color: context.c.warning,
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    backgroundColor: context.c.surface.withOpacity(0.8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  // 审批属于其他会话时，直接跳到那个会话去处理 —— 此前是
                  // 跳去安全策略页，而安全页 v1.11.4 起只留摘要、其"去处理"
                  // 又跳回当前会话，形成谁也到不了审批卡片的死循环。
                  onPressed: () => _jumpToApprovalSession(dsh),
                  icon: Icon(Icons.shield_rounded, size: 14, color: context.c.warning),
                  label: Text(
                    '前往审核',
                    style: TextStyle(color: context.c.warning, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildOfflineBanner(BuildContext context, DshService dsh) {
    if (dsh.isTokenInvalid) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: context.c.dangerSurface,
          border: Border(bottom: BorderSide(color: context.c.dangerBorder, width: 1.0)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: context.c.danger.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.key_off_rounded, size: 15, color: context.c.danger),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '访问令牌已失效 (HTTP 401)',
                    style: TextStyle(color: context.c.danger, fontSize: 12.5, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '服务器拒绝访问，已暂停自动重连。请前往重新配置令牌。',
                    style: TextStyle(color: context.c.danger, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: () {
                HapticFeedback.lightImpact();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ConfigPage()),
                );
              },
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: context.c.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: context.c.dangerBorder),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.settings_outlined, size: 13, color: context.c.danger),
                    const SizedBox(width: 4),
                    Text('前往配置', style: TextStyle(fontSize: 11.5, color: context.c.danger, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final isConnecting = dsh.status == ConnectionStatus.connecting;

    final bgColor = isConnecting ? context.c.warningSurface : context.c.dangerSurface;
    final borderColor = isConnecting ? context.c.warningBorder : context.c.dangerBorder;
    final textColor = isConnecting ? context.c.warning : context.c.danger;
    final accentColor = isConnecting ? context.c.warning : context.c.danger;

    return Container(
      width: double.infinity,
      // [fix 2026-10-17] 从 `vertical: 8` + 双行文案收成单行 4dp。
      //
      // 这条横幅是**常驻**到重连成功为止的，而它上面还有顶栏(60)+状态条(34)、
      // 下面还有审批 dock 和输入区 —— 真机上四条固定带叠起来能吃掉近一半屏幕，
      // 消息区只剩一条缝。断线这件事一句话就能说完，不值得占 70dp。
      // 错误详情（`lastError`）改为进 title，不再单独占一行。
      padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          bottom: BorderSide(color: borderColor, width: 1.0),
        ),
      ),
      child: Row(
        children: [
          // Visual Status Indicator
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: isConnecting
                ? SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.0,
                      color: accentColor,
                    ),
                  )
                : Icon(
                    Icons.wifi_off_rounded,
                    size: 13,
                    color: accentColor,
                  ),
          ),
          const SizedBox(width: 8),

          // Status Information（单行：一句话 + 可选的错误摘要进 tooltip）
          Expanded(
            child: Tooltip(
              message: dsh.lastError.isEmpty ? '' : dsh.lastError,
              child: Text(
                isConnecting
                    ? '网络已断开，正在重连…'
                    : (dsh.lastError.isEmpty
                        ? '网络连接已断开'
                        : '网络连接已断开 · ${dsh.lastError}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),

          const SizedBox(width: 8),

          // Manual Retry Button ("点击重试")
          InkWell(
            onTap: () async {
              HapticFeedback.lightImpact();
              ScaffoldMessenger.of(context).removeCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('正在尝试重新连接服务器...'),
                  duration: Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
              await dsh.retryConnection();
            },
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: isConnecting ? Colors.white.withOpacity(0.7) : Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isConnecting ? context.c.warningBorder : context.c.dangerBorder,
                  width: 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.refresh_rounded,
                    size: 13,
                    color: accentColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isConnecting ? '重连中...' : '点击重试',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: accentColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 跳到"正在等你授权"的那个会话。
  ///
  /// 与提问的 _jumpToQuestionSession 对称：审批同样是"agent 停下来等你"，
  /// 卡片渲染在**它所属会话**的对话流末尾。之前 banner 把用户送进安全策略页
  /// 的死循环（安全页只剩摘要、"去处理"又跳回当前会话），这里补上真正的出口。
  Future<void> _jumpToApprovalSession(DshService dsh) async {
    final cur = dsh.currentSession;
    final target = dsh.pendingApprovals.firstWhere(
      (a) => cur == null || !cur.matchesSessionId(a.sessionId),
      orElse: () => dsh.pendingApprovals.first,
    );
    HapticFeedback.selectionClick();
    await dsh.openSessionById(target.sessionId);
  }

  /// 不属于当前会话的待答提问数量。
  int _otherSessionQuestionCount(DshService dsh) {
    final cur = dsh.currentSession;
    if (cur == null) return dsh.pendingQuestions.length;
    return dsh.pendingQuestions.where((q) => !cur.matchesSessionId(q.sessionId)).length;
  }

  /// 跳到"正在等你回答"的那个会话。
  Future<void> _jumpToQuestionSession(DshService dsh) async {
    final cur = dsh.currentSession;
    final target = dsh.pendingQuestions.firstWhere(
      (q) => cur == null || !cur.matchesSessionId(q.sessionId),
      orElse: () => dsh.pendingQuestions.first,
    );
    HapticFeedback.selectionClick();
    await dsh.openSessionById(target.sessionId);
  }

}

/// 上一轮失败横幅：把"这轮为什么断了"直接说清楚，并给一键"重试"的入口。
class ChatTurnFailureBanner extends StatelessWidget {
  const ChatTurnFailureBanner({super.key, required this.dsh});

  final DshService dsh;

  @override
  Widget build(BuildContext context) {
    final info = dsh.lastTurnFailure!;
    final label = switch (info.kind) {
      'error' => '本轮执行出错',
      'interrupted' => '本轮被中断',
      'blocked' => '本轮被阻止',
      _ => '本轮未正常结束',
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: context.c.dangerSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.c.danger.withOpacity(0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: context.c.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(color: context.c.danger, fontSize: 12.5, fontWeight: FontWeight.bold),
                ),
                if (info.text.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  SelectableText(
                    info.text,
                    style: TextStyle(color: context.c.textSecondary, fontSize: 12, height: 1.35),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded, size: 16, color: context.c.textTertiary),
            tooltip: '知道了',
            visualDensity: VisualDensity.compact,
            onPressed: dsh.dismissTurnFailure,
          ),
        ],
      ),
    );
  }
}

/// 审批卡 / 提问卡 / TODO / 本会话附件的固定 dock。
class ChatBlockerDock extends StatefulWidget {
  const ChatBlockerDock({super.key, required this.dsh, required this.approvals});

  final DshService dsh;
  final List<ApprovalRequest> approvals;

  @override
  State<ChatBlockerDock> createState() => _ChatBlockerDockState();
}

class _ChatBlockerDockState extends State<ChatBlockerDock> {
  /// 「稍后处理」的本地暂缓表：审批 id → 恢复时刻（Phase 5.5）。
  ///
  /// **为什么用本地表而不是让网关别显示它**：这张卡代表的是"agent 停在这里
  /// 等你"这个客观事实，网关侧该一直 pending。用户选择的是"我晚点再看"，
  /// 那是一个**界面层决定**，没有任何理由改变引擎状态 —— 改了反而会让
  /// agent 侧看见一个不存在的"用户已忽略"，或者让这条审批在别处消失。
  ///
  /// 所以：本地收起 + 到点自己长回来。网关怎么看这条审批，完全不受影响。
  final Map<String, DateTime> _snoozedUntil = {};

  /// 每个被延后的审批一个定时器。**必须逐个 cancel**：一个共享 Timer 只能叫醒
  /// 最早的那个，其余会永远卡在收起态。
  final Map<String, Timer> _timers = {};

  /// 「稍后」的时长。选 15 分钟而不是 5/30：5 分钟用户可能还在开会，30 分钟
  /// agent 已经空转了半小时；15 分钟是"处理完手头这点事回来看"的量级。
  static const Duration snoozeDuration = Duration(minutes: 15);

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ChatBlockerDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 审批在别处被处理掉了（另一个设备批准、或超时失效）→ 连同定时器一起清掉，
    // 否则 15 分钟后会为一个已经不存在的东西 setState 并弹通知。
    final liveIds = widget.approvals.map((a) => a.id).toSet();
    final gone = _snoozedUntil.keys.where((id) => !liveIds.contains(id)).toList();
    for (final id in gone) {
      _timers.remove(id)?.cancel();
      _snoozedUntil.remove(id);
    }
  }

  void _snooze(ApprovalRequest req) {
    final until = DateTime.now().add(snoozeDuration);
    _timers.remove(req.id)?.cancel();
    setState(() => _snoozedUntil[req.id] = until);
    _timers[req.id] = Timer(snoozeDuration, () {
      if (!mounted) return;
      _timers.remove(req.id);
      setState(() => _snoozedUntil.remove(req.id));
      // 到点提醒一次就走：通知发不出去（没权限/插件没就绪）也不影响恢复渲染，
      // NotificationService 自己会记录 _lastError，这里不重复处理。
      unawaited(NotificationService.instance.show(
        title: '有审批在等你',
        body: '${req.toolName}：你 15 分钟前选择了稍后',
        kind: NotificationKind.actionRequired,
        payloadSessionId: req.sessionId,
      ));
    });
  }

  void _unsnoozeAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    setState(_snoozedUntil.clear);
  }

  /// 这一段整体有上限 + 可滚动：dock 是 body Column 里的非 flex 子项，
  /// 高度会跟卡片数量、附件数量、系统字号一起涨。一旦超过剩余高度，整个
  /// body Column 就 OVERFLOWING —— 系统字号 1.3x + 一张审批 + 一个提问 +
  /// 几张附件即可复现（实测 RenderFlex 报错）。
  ///
  /// 这里必须用**显式高度上限**而不是 Flexible：Column 里的 Flexible 会把
  /// 子项按剩余空间撑满，于是输入栏被推上去 182px（实测底边 398 而非
  /// 580）—— 那正是 v1.9.0 修过的"输入框下方一条空白"缺陷。
  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * _dockMaxHeightFraction,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ..._buildApprovalBlocks(context, widget.approvals, widget.dsh),

            // 提问卡片 / TODO 面板 / 图片附件（patch 0003）。
            //
            // 顺序是有意的：提问在最上面，因为它阻塞着 agent 的下一步 —— 用户
            // 必须先看到并回答它，TODO 和图片都是背景信息。附件紧贴输入框，
            // 因为它是"这轮对话里出现的图"，不是一条独立消息。
            ..._buildInteractiveBlocks(widget.dsh),
          ],
        ),
      ),
    );
  }

  /// 被用户「稍后」掉的审批数量（仍在网关 pending，只是本地收起）。
  int _snoozedCount(List<ApprovalRequest> approvals) => approvals
      .where((a) => _snoozedUntil.containsKey(a.id))
      .length;

  List<Widget> _buildApprovalBlocks(
      BuildContext context, List<ApprovalRequest> approvals, DshService dsh) {
    if (approvals.isEmpty) return const [];

    // 收起态过滤：被延后的那张不渲染，但**留一行痕迹**（见下方 _snoozedHint）。
    // 不留痕迹等于审批凭空消失，用户会以为它被处理掉了。
    final visible =
        approvals.where((a) => !_snoozedUntil.containsKey(a.id)).toList();
    final snoozed = _snoozedCount(approvals);
    final blocks = <Widget>[];

    if (snoozed > 0) {
      blocks.add(Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Row(
          children: [
            Icon(Icons.snooze_rounded, size: 14, color: context.c.textTertiary),
            const SizedBox(width: AppSpace.s),
            Expanded(
              child: Text(
                '$snoozed 项审批已延后',
                style: TextStyle(
                  fontSize: AppText.caption,
                  color: context.c.textTertiary,
                ),
              ),
            ),
            InkWell(
              key: const ValueKey('approval-unsnooze-all'),
              borderRadius: BorderRadius.circular(6),
              onTap: _unsnoozeAll,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  '提前处理',
                  style: TextStyle(
                    fontSize: AppText.caption,
                    fontWeight: FontWeight.w600,
                    color: context.c.accent,
                  ),
                ),
              ),
            ),
          ],
        ),
      ));
    }

    // 全部被延后时，下面这几块（批量入口 / 卡片 / "还有 N 个"）都不该出现。
    if (visible.isEmpty) return blocks;

    // 多张可见审批时先给一个批量入口（Phase 4.1）。它排在卡片**之上**，因为
    // "一次性把这些处理掉"本来就是这批卡片出现之后用户的第一个合理动作。
    if (visible.length > 1) {
      blocks.add(_BatchApproveBar(dsh: dsh, approvals: visible));
    }
    blocks.add(
      // [fix 2026-10-17] 去掉了这里原先的 `maxHeight: 300 + 内部滚动`。
      //
      // 真机截图里它的表现是：审批卡在 300dp 处被硬切一刀，卡片的圆角和底部
      // 内边距都看不到，只剩内容悬在那里 —— 看起来像渲染坏了，而"批准/拒绝"
      // 两个按钮刚好落在切口上。外层 dock 本身已经有 0.55 屏高的上限和滚动，
      // 这里再套一层限高只会把一张卡切成两半。
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: ApprovalCard(
          request: visible.first,
          onRespond: (r, outcome, [reason]) => dsh.respondApproval(r, outcome, reason: reason),
          // 「稍后」：本地收起 15 分钟，**不**向网关表达任何决定。
          onSnooze: () => _snooze(visible.first),
        ),
      ),
    );
    if (visible.length > 1) {
      blocks.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Text(
            '还有 ${visible.length - 1} 个操作等待授权，处理完上面这个后依次显示',
            style: TextStyle(fontSize: 11, color: context.c.textTertiary),
          ),
        ),
      );
    }
    return blocks;
  }

  /// 提问 / TODO / 附件三块。抽出来是因为它们共享「只属于当前会话」这条约束，
  /// 放在一起比散在 build 里更容易看出这个约束。
  List<Widget> _buildInteractiveBlocks(DshService dsh) {
    final blocks = <Widget>[];
    final questions = dsh.currentSessionQuestions;

    for (final q in questions) {
      blocks.add(
        QuestionCard(
          key: ValueKey(q.eventId),
          pending: q,
          // 只有真的连着网关才允许提交：离线时 send 会静默失败，用户会对着一个
          // 按不动的按钮以为是自己没点到。
          canAnswer: dsh.isConnected,
          onSubmit: (selections, customs) => dsh.answerQuestion(
            q,
            selections: selections,
            customs: customs,
          ),
          onDismiss: () => dsh.dismissQuestion(q),
        ),
      );
    }

    final qErr = dsh.lastQuestionError;
    if (qErr != null && questions.isNotEmpty) {
      blocks.add(QuestionErrorBanner(message: qErr));
    }

    final todos = dsh.currentTodos;
    if (todos.isNotEmpty) {
      blocks.add(TodoPanel(todos: todos));
    }

    for (final att in dsh.currentAttachments) {
      blocks.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: AttachmentImageTile(ref: att, endpoint: dsh.attachmentUrl(att)),
        ),
      );
    }

    return blocks;
  }

  /// 消息里的附件：图片走缩略图，文件走一行文件条。
  ///
  /// [fix 2026-10-17] 起因：手机自己发出去的图片**完全不显示**（Web 端有）。两处缺口：
  /// 网关的历史转换把非 text part 整段丢了（已修），而这里从来没有渲染过消息级附件
  /// —— 附件只出现在输入框上方那条"本轮附件"里。两个来源都渲染：
  ///
  /// * [ChatMessage.attachments] —— 服务端签发的附件（历史与实时帧都带）；
  /// * [ChatMessage.localImagePreviews] —— 本机刚发出去那张图的字节（只有乐观消息有），
  ///   让图片在轮询回包之前就已经在屏幕上。
}

/// 批量批准入口（Phase 4.1）。
///
/// 一次挂 5 张审批时，"一张一张点"是最慢的路径，而这 5 张里往往有 3 张是同一条
/// 流水线里的低风险步骤（列目录、读文件、跑测试）。
///
/// ## 为什么不是「一键静默跳过高风险」
///
/// 高危判定是**启发式**（`looksHighRiskApproval`：命令里有没有 `rm -rf` / `sudo` /
/// 管道执行远端脚本……）。启发式的两个失效方向都很糟：
///
/// 1. 误判 → 用户看不到"为什么这条没被批"，只会当成 bug；
/// 2. 漏判（`rm -rf` 写成变量拼接、路径从参数里来）→ 用户以为全批了，实际没批，
///    而屏幕上已经没有那张卡片了 —— 这比不做批量更危险。
///
/// 所以它的角色只有一个：**把低风险项预先勾上**。最终仍然是用户在弹层里看清
/// 每一条（工具名 + 命令首行）后，亲手按下"批准选中的 N 项"。启发式不构成任何
/// 安全边界，审批的真正权威判定在引擎侧。
class _BatchApproveBar extends StatefulWidget {
  const _BatchApproveBar({required this.dsh, required this.approvals});

  final DshService dsh;
  final List<ApprovalRequest> approvals;

  @override
  State<_BatchApproveBar> createState() => _BatchApproveBarState();
}

class _BatchApproveBarState extends State<_BatchApproveBar> {
  /// 上一轮批量批准里**没生效**的项（网关没回 ok，卡片仍在 pending 里）。
  ///
  /// 不用 SnackBar 报错：失败是"这一批没做完"的状态，不是一次性的提示 —— 它得
  /// 一直摆在这里直到用户重试成功，否则用户会以为已经处理完了。
  List<ApprovalRequest> _failed = const [];

  bool _busy = false;

  Future<void> _showBatchApproveSheet() async {
    // 预选状态用**下标**而不是 eventId：旧网关的 eventId 可能是空串或重复，
    // 用 id 当 Map key 会让几条审批共用同一个勾选状态。
    final selected = <bool>[
      for (final r in widget.approvals) !looksHighRiskApproval(r),
    ];

    final confirmed = await showModalBottomSheet<List<ApprovalRequest>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            final chosen = <ApprovalRequest>[
              for (var i = 0; i < widget.approvals.length; i++)
                if (selected[i]) widget.approvals[i],
            ];

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 12,
                  bottom: MediaQuery.of(modalCtx).viewInsets.bottom + 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: context.c.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Icon(
                          Icons.checklist_rounded,
                          size: 20,
                          color: context.c.accent,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '批量批准',
                            style: TextStyle(
                              fontSize: AppText.heading,
                              fontWeight: FontWeight.bold,
                              color: context.c.textPrimary,
                            ),
                          ),
                        ),
                        Text(
                          '${widget.approvals.length} 项',
                          style: TextStyle(
                            fontSize: AppText.body,
                            color: context.c.textTertiary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '高风险项默认不勾选，需要你单独确认。',
                      style: TextStyle(
                        fontSize: AppText.body,
                        color: context.c.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < widget.approvals.length; i++)
                              _batchRow(modalCtx, i, selected, setModalState),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      onPressed: chosen.isEmpty
                          ? null
                          : () => Navigator.pop(ctx, chosen),
                      style: FilledButton.styleFrom(
                        backgroundColor: context.c.accent,
                        foregroundColor: context.c.surface,
                        minimumSize: const Size.fromHeight(44),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9),
                        ),
                      ),
                      child: Text(
                        chosen.isEmpty
                            ? '没有选中任何项'
                            : '批准选中的 ${chosen.length} 项',
                        style: const TextStyle(
                          fontSize: AppText.title,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    // 选完就立刻逐条提交。失败项留在 pending 里（服务端同样保留队列条目），
    // 这里把它们记下来在 dock 顶部报出，给一个"重试"入口。
    if (confirmed == null || confirmed.isEmpty || !mounted) return;

    setState(() => _busy = true);
    for (final req in confirmed) {
      await widget.dsh.respondApproval(req, 'allowed-once');
    }
    if (!mounted) return;

    final stillPending = <String>{
      for (final a in widget.dsh.pendingApprovals) a.eventId,
    };
    setState(() {
      _busy = false;
      _failed = confirmed
          .where((r) => stillPending.contains(r.eventId))
          .toList(growable: false);
    });
  }

  Widget _batchRow(
    BuildContext context,
    int index,
    List<bool> selected,
    void Function(void Function()) setModalState,
  ) {
    final req = widget.approvals[index];
    final risky = looksHighRiskApproval(req);
    final command = (req.command ?? '').trim();
    final subtitle = command.isNotEmpty ? command : req.reason;

    return CheckboxListTile(
      value: selected[index],
      onChanged: (v) {
        HapticFeedback.selectionClick();
        setModalState(() => selected[index] = v ?? false);
      },
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Row(
        children: [
          Flexible(
            child: Text(
              req.toolName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppText.title,
                fontWeight: FontWeight.w600,
                color: risky ? context.c.danger : context.c.textPrimary,
              ),
            ),
          ),
          if (risky) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: context.c.dangerSurface,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: context.c.dangerBorder),
              ),
              child: Text(
                '高风险',
                style: TextStyle(
                  fontSize: AppText.caption,
                  fontWeight: FontWeight.bold,
                  color: context.c.danger,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        subtitle,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppText.subhead,
          fontFamily: 'monospace',
          color: context.c.textSecondary,
          height: 1.35,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final failedCount = _failed.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (failedCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 14,
                    color: context.c.danger,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '$failedCount 项批准失败 · 重试',
                      style: TextStyle(
                        fontSize: AppText.body,
                        fontWeight: FontWeight.w600,
                        color: context.c.danger,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _showBatchApproveSheet,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(
                      '重试',
                      style: TextStyle(fontSize: AppText.body, color: context.c.danger),
                    ),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('approval-batch-approve'),
              onPressed: _busy ? null : _showBatchApproveSheet,
              icon: Icon(
                Icons.done_all_rounded,
                size: 16,
                color: context.c.accent,
              ),
              label: Text(
                _busy ? '正在批准…' : '全部批准（仅低风险）',
                style: TextStyle(fontSize: AppText.body, color: context.c.accent),
              ),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
