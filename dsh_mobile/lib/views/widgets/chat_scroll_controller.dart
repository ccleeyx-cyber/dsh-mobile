/// 消息流的滚动状态机与消息流本体。
///
/// Phase 0 结构拆分（纯剪切）：从 `chat_view.dart` 原样搬出，逻辑与样式一字未改。
///
/// 两块：
/// * [ChatScrollController] —— 原来的滚动字段与 `_onScroll` / `_onScrollNotification` /
///   `_jumpToBottom` / `_scrollToBottom` / `_scheduleAutoScroll` / `_maybeLoadOlder`，
///   以及 `build()` 顶部那段「键盘高度 / 消息条数 / 流式版本」diff 状态机。
/// * [ChatMessageStream] —— 消息列表壳：空态、上翻头部、尾部产出卡、回到最新消息浮钮。
///
/// 两者都刻意不认识 `_ChatViewState`：需要 State 的地方（setState、mounted、
/// 当前轮重算、会话切换时的界面重置）一律走构造参数里的回调，
/// 需要「一条消息长什么样」的地方走 builder。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../../services/dsh_service.dart';
import '../../theme/app_colors.dart';
import 'message_list_view.dart';

/// 消息流的滚动状态机。
///
/// 字段与原来 `_ChatViewState` 里的一一对应（名字只去掉了下划线），
/// 所以 diff 逻辑可以逐行对照原实现读。
class ChatScrollController {
  ChatScrollController({
    required this.controller,
    required this.onStateChanged,
    required this.isMounted,
    required this.onProbeVisibleTurn,
    required this.onResetVisibleTurn,
  });

  /// Flutter 的滚动控制器（消息列表直接用这一个）。
  final ScrollController controller;

  /// 需要把一次状态变化推回 State 时调用 —— 等价于原来的 `setState(() {})`。
  final VoidCallback onStateChanged;

  /// State 是否还挂着（原实现里的 `mounted`）。
  final bool Function() isMounted;

  /// 滚动后重算「当前是第几轮」（轮次刻度用）。
  final VoidCallback onProbeVisibleTurn;

  /// 滚回底部时清空「当前轮」：轮次刻度是会话级状态，切会话/回底必须重置。
  final VoidCallback onResetVisibleTurn;
  String? _lastSessionId;
  bool _showScrollToBottom = false;
  int _lastMessageCount = 0;
  bool _wasLoadingHistory = false;
  // ---- 会话历史无限上翻（v1.15）[feat 2026-10-12] ----
  bool _loadingOlder = false;
  /// 一次性的"这次长度增长来自 prepend"标记（见 build 里的浮钮抑制）。
  bool _suppressTailButtonOnce = false;
  // Keyboard & viewport avoidance state
  double _lastBottomInset = 0.0;
  bool _wasNearBottomBeforeKeyboard = true;

  // User interaction & streaming auto-scroll state
  bool _userScrolledUp = false;
  bool _isUserInteracting = false;
  bool _isAutoScrollScheduled = false;
  int _lastStreamRevision = 0;
  int _lastStreamContentLength = 0;

  /// 浮钮是否该出现（离底超过 160）。
  bool get showScrollToBottom => _showScrollToBottom;

  /// 用户是否主动往上翻了（流式自动滚动据此让位）。
  bool get userScrolledUp => _userScrolledUp;

  /// 滑到顶部自动拉更早历史。列表是正序 ListView.builder（offset 0 = 最旧），
  /// prepend 之后必须把 offset 平移新增内容的实际高度，否则视觉位置会跳。
  ///
  /// 时序：loadOlderHistory 返回时 notifyListeners 已发出，但 Provider 的重建
  /// 发生在**下一帧**；whenComplete 此刻读到的 maxScrollExtent 仍是旧值 ——
  /// 正好把它当作"prepend 前"的基准。postFrame 回调在重建帧结束后执行，那时
  /// 的 maxScrollExtent 是新值，两者之差就是新增头部的总高度，把 offset 平移
  /// 同样的量即可保持视觉位置。
  void maybeLoadOlder(DshService dsh) {
    if (!dsh.hasMoreHistory || _loadingOlder) return;
    if (!controller.hasClients) return;
    if (controller.position.pixels > 120) return;
    _loadingOlder = true;
    _suppressTailButtonOnce = true;
    final beforeCount = dsh.messages.length;
    dsh.loadOlderHistory().whenComplete(() {
      _loadingOlder = false;
      if (!isMounted() || !controller.hasClients) return;
      final added = dsh.messages.length - beforeCount;
      if (added <= 0) return;
      final oldMax = controller.position.maxScrollExtent; // prepend 前
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!isMounted() || !controller.hasClients) return;
        final newMax = controller.position.maxScrollExtent; // prepend 后
        final delta = newMax - oldMax;
        if (delta > 0) {
          controller.jumpTo(
            (controller.offset + delta).clamp(0.0, newMax),
          );
        }
      });
    });
  }

  void onScroll() {
    if (!controller.hasClients) return;
    final maxScroll = controller.position.maxScrollExtent;
    final currentOffset = controller.offset;
    final distFromBottom = maxScroll - currentOffset;
    final show = distFromBottom > 160;
    if (show != _showScrollToBottom) {
      _showScrollToBottom = show;
      onStateChanged();
    }
    if (distFromBottom < 40 && _userScrolledUp) {
      _userScrolledUp = false;
    }
  }


  bool onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null) {
        _isUserInteracting = true;
      }
    } else if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails != null) {
        _isUserInteracting = true;
        final maxScroll = notification.metrics.maxScrollExtent;
        final currentOffset = notification.metrics.pixels;
        final distFromBottom = maxScroll - currentOffset;
        if (distFromBottom > 120) {
          _userScrolledUp = true;
        } else if (distFromBottom < 40) {
          _userScrolledUp = false;
          // 轮次刻度的"当前轮"是**会话级**状态：切会话必须清空，否则会沿用上一个
          // 会话的轮号（刻度会高亮到不存在的位置）。
          onResetVisibleTurn();
        }
      }
    } else if (notification is ScrollEndNotification) {
      _isUserInteracting = false;
      final maxScroll = notification.metrics.maxScrollExtent;
      final currentOffset = notification.metrics.pixels;
      if (maxScroll - currentOffset < 40) {
        _userScrolledUp = false;
      }
    } else if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.idle) {
        _isUserInteracting = false;
      } else {
        _isUserInteracting = true;
      }
    }
    // [feat 2026-10-17] 轮次刻度的"当前轮"跟着滚动更新。
    onProbeVisibleTurn();
    return false;
  }

  void jumpToBottom() {
    _userScrolledUp = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) {
        controller.jumpTo(controller.position.maxScrollExtent);
      }
    });
  }

  void scrollToBottom({Duration duration = const Duration(milliseconds: 300), Curve curve = Curves.easeOutCubic}) {
    _userScrolledUp = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) {
        controller.animateTo(
          controller.position.maxScrollExtent,
          duration: duration,
          curve: curve,
        );
      }
    });
  }

  void scheduleAutoScroll() {
    if (_isAutoScrollScheduled) return;
    _isAutoScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isAutoScrollScheduled = false;
      if (!isMounted()) return;
      if (_userScrolledUp || _isUserInteracting) return;
      if (!controller.hasClients) return;

      final maxScroll = controller.position.maxScrollExtent;
      final currentOffset = controller.offset;
      final diff = maxScroll - currentOffset;

      if (diff > 0) {
        if (diff > 250) {
          controller.animateTo(
            maxScroll,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
          );
        } else {
          controller.jumpTo(maxScroll);
        }
      }
    });
  }

  /// `build()` 顶部那段滚动 diff 状态机（键盘高度 / 流式增长 / 消息条数 / 会话切换）。
  ///
  /// 原实现直接写在 `build()` 里，靠副作用更新字段；搬出来之后调用点在
  /// `build()` 的第一行，语义完全一致：**仍在 build 期间执行**，因此那些
  /// `setState` 的时序怪癖（例如"用户在上方时点亮浮钮"）与原来逐字相同。
  ///
  /// [onSessionSwitched] 承接会话切换时属于 State 的那部分重置（队列展开态、
  /// 产出卡锚点、交付物未读计数、草稿换槽）—— 这些字段的持有者仍是 `_ChatViewState`。
  void syncBeforeBuild(
    DshService dsh,
    double currentBottomInset, {
    required void Function(String? previousSessionId) onSessionSwitched,
  }) {
    final currentSessionId = dsh.currentSession?.sessionId;
    // Keyboard height transitions
    if (currentBottomInset != _lastBottomInset) {
      final isKeyboardOpening = currentBottomInset > _lastBottomInset;
      if (isKeyboardOpening && _lastBottomInset == 0) {
        _wasNearBottomBeforeKeyboard = !_userScrolledUp;
      }
      if (isKeyboardOpening && _wasNearBottomBeforeKeyboard && !_userScrolledUp) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (controller.hasClients && !_userScrolledUp && !_isUserInteracting) {
            controller.jumpTo(controller.position.maxScrollExtent);
          }
        });
      }
      _lastBottomInset = currentBottomInset;
    }

    // Stream content growth detection (fallback alongside streamRevision)
    final lastMsg = dsh.messages.isNotEmpty ? dsh.messages.last : null;
    final isStreaming = lastMsg != null && lastMsg.isStreaming;
    final currentContentLen = (lastMsg?.content.length ?? 0) + (lastMsg?.thinking?.length ?? 0);
    final hasStreamContentGrowth = isStreaming && currentContentLen != _lastStreamContentLength;
    _lastStreamContentLength = currentContentLen;

    if (currentSessionId != _lastSessionId) {
      final previousSessionId = _lastSessionId;
      _lastSessionId = currentSessionId;
      _lastMessageCount = dsh.messages.length;
      _lastStreamRevision = dsh.streamRevision;
      // 会话级的界面状态跟着切：队列展开态、产出卡片锚点、失败提示、草稿换槽。
      // 这一段属于 State，交回给调用方（顺序与原来一致：先清界面态，再换草稿）。
      onSessionSwitched(previousSessionId);
      jumpToBottom();
    } else if (_wasLoadingHistory && !dsh.isLoadingHistory) {
      _lastStreamRevision = dsh.streamRevision;
      _userScrolledUp = false;
      jumpToBottom();
    } else if (dsh.messages.length != _lastMessageCount) {
      final wasNearBottom = !_userScrolledUp;
      // [feat 2026-10-12] prepend（上翻）也使长度增长，但它不是"尾部新消息"，
      // 不能点亮"回到最新消息"浮钮 —— _maybeLoadOlder 置一次抑制位。
      final fromPrepend = _suppressTailButtonOnce;
      _suppressTailButtonOnce = false;
      final appendedAtTail = dsh.messages.length > _lastMessageCount && !fromPrepend;
      _lastMessageCount = dsh.messages.length;
      _lastStreamRevision = dsh.streamRevision;
      if (wasNearBottom) {
        scrollToBottom();
      } else if (appendedAtTail) {
        // [feat 2026-10-12] 用户在上方、尾部来了新消息：确保"回到最新消息"
        // 浮钮出现（_onScroll 只在滚动时刷新它，新消息到达不滚动的话浮钮
        // 不会亮）。
        if (!_showScrollToBottom) {
          _showScrollToBottom = true;
          onStateChanged();
        }
      }
    } else if (dsh.streamRevision != _lastStreamRevision || hasStreamContentGrowth) {
      _lastStreamRevision = dsh.streamRevision;
      if (!_userScrolledUp && !_isUserInteracting) {
        scheduleAutoScroll();
      }
    }
    _wasLoadingHistory = dsh.isLoadingHistory;

    // [feat 2026-10-12] 顶部触发上翻：仅在用户真的滑到顶部（pixels<=120）且
    // 还有更早历史时拉取。放在会话切换块之后，避免切会话首帧误触发。
    if (!dsh.isLoadingHistory && dsh.messages.isNotEmpty) {
      maybeLoadOlder(dsh);
    }
  }
}

/// 消息流壳：空态 / 列表 / 上翻头部 / 尾部产出卡 / 回到最新消息浮钮。
class ChatMessageStream extends StatelessWidget {
  const ChatMessageStream({
    super.key,
    required this.dsh,
    required this.controller,
    required this.onScrollNotification,
    required this.turnRail,
    required this.showTurnOutput,
    required this.showEmptyState,
    required this.buildItem,
    required this.buildTrailer,
    required this.showScrollToBottom,
    required this.onScrollToBottom,
    required this.workspaceName,
    required this.onInsertSuggestion,
  });

  final DshService dsh;
  final ScrollController controller;
  final bool Function(ScrollNotification notification) onScrollNotification;

  /// 浮在列表右边缘的轮次刻度层（由调用方构造）。
  final Widget turnRail;
  final bool showTurnOutput;

  /// 空会话时展示欢迎页而不是列表。
  final bool showEmptyState;

  final Widget Function(BuildContext context, int index) buildItem;
  final Widget Function() buildTrailer;
  final bool showScrollToBottom;
  final VoidCallback onScrollToBottom;

  /// 空态里显示的当前工作区名。
  final String? workspaceName;

  /// 空态的推荐问题：点了把模板文字塞进输入框。
  final ValueChanged<String> onInsertSuggestion;

  // ---- 会话历史无限上翻（v1.15）[feat 2026-10-12] ----

  /// 上翻头部占几个槽位：还有更多历史、正在加载、或已到开头时占 1，
  /// （历史本来就一条不剩的短会话不占，避免空会话顶部挂一条"已到开头"）。
  int _historyHeaderItemCount() {
    if (dsh.messages.isEmpty) return 0;
    if (dsh.isLoadingOlder || dsh.hasMoreHistory || dsh.historyExhausted) return 1;
    return 0;
  }

  /// 顶部状态：加载中转圈 / 已到会话开头。
  Widget _buildHistoryHeader(BuildContext context) {
    if (dsh.isLoadingOlder) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (dsh.historyExhausted) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Text('已到会话开头', style: TextStyle(color: context.c.textTertiary, fontSize: 12)),
        ),
      );
    }
    // 还有更多但未触发（等滑到顶部）：占位保持高度稳定，避免触发瞬间列表跳动。
    return const SizedBox(height: 1);
  }

  /// 空态的推荐问题 chip（点一下把模板文字接进输入框）。
  Widget _buildSuggestionChip(BuildContext context, String text, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: context.c.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.c.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Text(
          text,
          style: TextStyle(color: context.c.textPrimary, fontSize: 12.5, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }

  /// 空会话的欢迎页。
  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: context.c.selectedSurface,
                shape: BoxShape.circle,
                // 原来这里是硬编码 `Color(0xFFCCE4F7)`（对着旧浅色主题的浅蓝边）。
                // 深色下它是一个刺眼的浅蓝圈，且新 accent 换过色后已经不同族。
                // 改用 accent 的低透明度描边：两级主题同一个语义，且跟着品牌色走。
                border: Border.all(color: context.c.accent.withOpacity(0.35)),
              ),
              child: Icon(
                Icons.auto_awesome,
                color: context.c.accent,
                size: 30,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '今天想探索什么？',
              style: TextStyle(
                color: context.c.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '当前工作区: ${workspaceName ?? "默认工作区"}',
              style: TextStyle(
                color: context.c.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _buildSuggestionChip(context, '🛠️ 分析项目代码', () {
                  onInsertSuggestion('分析当前项目代码结构并概述核心功能');
                }),
                _buildSuggestionChip(context, '⚡ 检查潜在问题', () {
                  onInsertSuggestion('检查当前项目中的潜在 Bug 或异常');
                }),
                _buildSuggestionChip(context, '💡 生成测试建议', () {
                  onInsertSuggestion('为当前模块编写单元测试用例建议');
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (dsh.isLoadingHistory) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        if (showEmptyState)
          _buildEmptyState(context)
        else
          // [fix 2026-10-16] 用 Selector 把重建范围收到消息列表。
          //
          // 这里原来是内联的 ListView.builder，跟着整个 ChatView.build() 一起重建
          // —— 而 `Provider.of<DshService>(context)` 是 listen:true，每个流式增量
          // 都会通知一次，AppBar、横幅、输入框、搜索面板全都白重建一遍。
          //
          // 订阅 `streamRevision` 而不是 `messages`：后者返回的是同一个 List 实例
          // （`dsh.messages => _messages`），流式期间只原地改内容，Selector 的 `==`
          // 比较永远判等 → 列表根本不会重建。streamRevision 每个 flush 边界都自增，
          // 是这里唯一可靠的"内容变了"信号。
          Selector<DshService, int>(
            selector: (BuildContext ctx, DshService d) => d.streamRevision,
            builder: (BuildContext ctx, _, __) {
              final headerCount = _historyHeaderItemCount();
              return MessageListView(
                messages: dsh.messages,
                headerCount: headerCount,
                itemCount: dsh.messages.length + (showTurnOutput ? 1 : 0) + headerCount,
                controller: controller,
                onScrollNotification: onScrollNotification,
                // [feat 2026-10-17] 电脑端同款轮次刻度：右边缘一列短刻度，
                // 点某格直接跳到那一轮（十轮以上的会话靠滑是找不回来的）。
                overlay: turnRail,
                buildHeader: () => _buildHistoryHeader(context),
                buildItem: buildItem,
                buildTrailer: buildTrailer,
              );
            },
          ),
        if (showScrollToBottom)
          // [fix 2026-10-17] 从"文字胶囊"改成 36dp 圆形按钮。
          //
          // 原来是一枚带「回到最新消息」文字的蓝底胶囊（约 130×30），浮在右下角：
          // 真机上它直接压在最近一条气泡/工具卡上，把那一行的字盖掉 —— 一个
          // "帮你回到最新"的按钮反而挡住了最新的内容。圆形小按钮只占 36dp，
          // 文案移进 tooltip（长按可见），遮挡面积缩小到原来的 1/4。
          Positioned(
            right: 12,
            bottom: 12,
            child: Tooltip(
              message: '回到最新消息',
              child: Material(
                elevation: 3,
                color: context.c.accent,
                shape: const CircleBorder(),
                child: InkWell(
                  key: const ValueKey('chat-scroll-to-bottom'),
                  customBorder: const CircleBorder(),
                  onTap: onScrollToBottom,
                  child: const SizedBox(
                    width: 36,
                    height: 36,
                    child: Icon(
                      Icons.arrow_downward_rounded,
                      size: 19,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
