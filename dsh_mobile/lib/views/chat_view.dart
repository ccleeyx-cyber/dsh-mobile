import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/chat_message.dart';
import '../models/approval_request.dart';
import '../services/dsh_service.dart';
import '../widgets/thinking_card.dart';
import '../widgets/tool_call_card.dart';
import '../widgets/memory_card.dart';
import '../widgets/inline_file_links.dart';
import '../widgets/harness_notice_card.dart';
import '../widgets/safe_markdown.dart';
import '../widgets/top_toast.dart';
import 'widgets/attachment_tile.dart';
import 'widgets/turn_navigation_rail.dart';
import 'widgets/message_search.dart';
import 'widgets/message_search_panel.dart';
import 'widgets/session_status_strip.dart';
import 'widgets/deliverable_preview_sheet.dart';
import 'widgets/turn_output_card.dart';
import 'widgets/chat_dock.dart';
import 'widgets/chat_scroll_controller.dart';
import 'widgets/chat_sheets.dart';
import 'widgets/composer.dart';
import 'widgets/message_action_sheet.dart';
import 'code_viewer_page.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../services/platform_services.dart';
import '../models/pending_attachment.dart';
import '../models/user_question.dart' show AttachmentRef;
import '../models/task_center.dart';
import '../services/attachment_picker.dart';

class ChatView extends StatefulWidget {
  final VoidCallback? onOpenWorkspaces;

  /// 「去设置建一条快捷指令」——输入区模板面板空态里的出口。
  ///
  /// 只有 MainShell 能推设置里的二级页（它持有 Navigator 与 tab 状态），
  /// 所以这里只转发。为 null 时面板不画那个按钮。
  final VoidCallback? onOpenSnippets;

  // 这里曾经还有 `onOpenSecurity`：安全策略页在一级 tab 时代的跳转回调。
  // 它从未被任何一处 `widget.onOpenSecurity?.call()` 调用过（死参数），而且安全策略
  // 现在是设置里的推入页（见 main_shell / custom_settings_view），连语义也不再成立。

  const ChatView({
    super.key,
    this.onOpenWorkspaces,
    this.onOpenSnippets,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  /// 消息流的滚动状态机（键盘 diff / 流式自动滚 / 上翻历史 / 浮钮可见性）。
  ///
  /// 字段与逻辑都在 `chat_scroll_controller.dart`；这里只把"需要 State 做的事"
  /// 以回调形式接进来 —— `setState`、`mounted`、当前轮重算、会话切换时属于
  /// State 的那部分重置。
  late final ChatScrollController _scroll = ChatScrollController(
    controller: _scrollController,
    onStateChanged: () => setState(() {}),
    isMounted: () => mounted,
    onProbeVisibleTurn: _probeVisibleTurn,
    onResetVisibleTurn: () {
      _visibleTurn = null;
      _lastTurnProbe = DateTime.fromMillisecondsSinceEpoch(0);
    },
  );

  // ---- 会话洞察（v1.14）：状态条 / 信息面板 / 本轮产出卡片 ----

  /// 队列 dock 是否已被用户就地展开（超过 3 条时才用得上）。
  bool _queueExpanded = false;

  /// 已经为哪些会话"看过"交付物（会话 id → 当时的交付物数量）。
  ///
  /// 状态条上的"产出"在有新东西且用户还没打开面板时用强调色。只放内存、
  /// 不落盘：重开 App 后再强调一次无害，而落盘会引入一个需要清理的持久状态。
  final Map<String, int> _deliverablesAck = {};

  /// 上一次观察到的"交付物事件"计数。用它判断"**刚刚**交付了"——
  /// 进会话时补拉到的旧产出不算刚刚（那属于状态，去信息面板看）。
  int _lastSeenDeliverableEvents = 0;

  /// 「本轮产出」卡片锚定的消息索引：事件到达那一刻最后一条消息的位置。
  /// -1 = 没有可显示的卡片。
  int _outputCardAnchorIndex = -1;

  /// 正在下载的交付物路径（内联转圈）与失败说明（内联红字，不用 SnackBar）。
  ///
  /// 用 `ValueNotifier` 而不是普通字段：同一个"正在下载的是哪一个"要同时驱动
  /// 消息流里的卡片和**信息面板那一层模态**（模态是另一棵子树，不会跟着
  /// ChatView 的 setState 重建）。
  String? _deliverableError;
  final ValueNotifier<String?> _deliverableBusy = ValueNotifier<String?>(null);

  // ---- 会话内查找 (v1.4.2) ----
  final TextEditingController _searchController = TextEditingController();
  final Map<String, GlobalKey> _messageKeys = {};
  bool _searchOpen = false;
  String _searchQuery = '';

  /// [fix 2026-10-16] `contextMarkers` 扫描结果的记忆化缓存。
  /// key = `'<message id>@<content length>'`。见 `_buildMessageItem` 里的说明。
  final Map<String, int> _contextMarkerCache = {};

  /// 当前被高亮的命中消息 id。高亮只保留一条 —— 一次跳到第一条就够用户确认
  /// "查找能用了"，剩下的自己点；全部高亮反而让页面变成一片黄。
  final Set<String> _highlightedMessageIds = {};

  // ---- 离线草稿 (v1.4.2) ----

  // ---- 附件 (v1.10.0) ----
  /// 已挂载、等待随下一条消息发出去的附件。
  final List<PendingAttachment> _pendingAttachments = [];
  int _attachSeq = 0;

  /// 本地标识，只用于列表 key 与删除定位，不发给服务端 —— 所以不需要 UUID，
  /// 一个递增计数在单个页面生命周期内就足够唯一。
  String _nextAttachmentId() => 'att-${++_attachSeq}';

  // ---- 运行中投递（v1.14）----
  //
  // 语义：**会话进行中发消息 = 默认排队**，由引擎在这一轮跑完后自动发送；
  // 要立刻插进正在跑的回合，唯一的入口是队列条目上的「立即插话」，并且要
  // **再点一次**确认。投递方式不再是能被记住的开关 —— 一个能被记住的开关
  // 会让"默认"在下次变成插话（用户不会记得它停在哪一格）。

  /// 输入卡片上方那一条提示（排队回执 / 插话结果 / 失败说明）。
  ///
  /// 与 `_toast` 分开：`_toast` 走 SnackBar，会被下一条 toast 顶掉且 2 秒消失，
  /// 而"你刚写的一大段话没发出去"这种事必须留在原地让用户看见。
  ///
  /// [fix 2026-10-17] 从裸 ValueNotifier + 本地 Timer 改为 [ComposerNoticeBus]：
  /// 此前父级（5s）与 composer（4s）各持一个 Timer 共用同一个 notifier、互不知晓
  /// —— 先弹排队回执再弹语音失败，第 5 秒排队的 Timer 会把语音错误提前清空。
  /// timer 收敛到总线后，任何一侧写入都取消上一条，生命周期只有一份。
  final ComposerNoticeBus _noticeBus = ComposerNoticeBus();

  /// 最近一次「立即插话」成功的那一条（v1.27：3 秒回执里的撤销靠它）。
  ///
  /// 为什么需要记着它：插队成功后条目会被引擎**立刻领走**，队列里已经没有这条了
  /// —— 光靠回执上的 `itemId` 无法还原它的正文，而"放回输入框"正是唯一的降级
  /// 撤销手段（见 `_onNoticeAction` 里那段说明）。
  QueueItem? _lastSteered;

  void _showNotice(
    String text, {
    bool ok = true,
    NoticeAction action = NoticeAction.none,
    String? undoItemId,
    Duration duration = const Duration(seconds: 5),
  }) {
    _noticeBus.show(
      text,
      ok: ok,
      action: action,
      undoItemId: undoItemId,
      duration: duration,
    );
  }

  void _clearNotice() {
    _noticeBus.clear();
  }

  /// 测试用：直接挂一个附件，绕开原生选择器（单测里调不起来）。
  @visibleForTesting
  void debugAddPendingAttachment(PendingAttachment attachment) {
    setState(() => _pendingAttachments.add(attachment));
  }

  /// 测试用：读取输入卡片上方那条提示的文案（没有提示时为 null）。
  @visibleForTesting
  String? get debugNoticeText => _noticeBus.notice.value?.text;

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        // 只清文本，不 dispose：controller 在 State 生命周期内复用，关闭再打开
        // 是常态，dispose 后再用会抛。
        _searchController.clear();
        _searchQuery = '';
        _highlightedMessageIds.clear();
      }
    });
    if (!_searchOpen) {
      _inputFocusNode.requestFocus();
    }
  }

  void _onSearchChanged(String q) {
    setState(() {
      _searchQuery = q;
      _highlightedMessageIds.clear();
    });
  }

  /// 跳到命中的消息并短暂高亮。
  void _jumpToHit(SearchHit hit, DshService dsh) {
    final msg = hit.messageIndex < dsh.messages.length
        ? dsh.messages[hit.messageIndex]
        : null;
    if (msg == null) return;
    _highlightAndScrollToMessage(msg.id,
        index: hit.messageIndex, total: dsh.messages.length);
  }

  /// 高亮某条消息并滚到它。
  ///
  /// 搜索命中与「轨迹」面板的"跳到消息"**共用这一条路径**：两处各写一份的话，
  /// 任何一处改了滚动对齐或高亮时长，另一处会悄悄不一致，而用户看到的只是
  /// "有时候跳得准、有时候不准"。
  void _highlightAndScrollToMessage(String messageId,
      {int? index, int? total}) {
    if (!mounted) return;
    setState(() {
      _highlightedMessageIds
        ..clear()
        ..add(messageId);
    });
    _scrollToMessageKey(messageId);

    // 消息列表是懒构建的：目标不在当前视野里时，它的 GlobalKey 还没有 context，
    // `ensureVisible` 会静默什么都不做 —— 用户点了"跳到消息"却停在原地，还以为
    // 按钮坏了。退一步先按序号比例粗滚一次，下一帧目标被构建出来后再精确定位。
    //
    // [fix 2026-10-18] 列表已 reverse：offset 0 = 最新，越旧 offset 越大。
    // 正序时代 `maxScrollExtent * ratio`（ratio 按 index/total）滚向的是"旧"
    // 的一端，翻转后同一个 ratio 要用 `max * (1 - ratio)` 才指向同一条消息。
    if (_messageKeys[messageId]?.currentContext == null &&
        index != null &&
        total != null &&
        total > 1 &&
        _scrollController.hasClients) {
      final ratio = (index / (total - 1)).clamp(0.0, 1.0);
      _scrollController.jumpTo(
          _scrollController.position.maxScrollExtent * (1 - ratio));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToMessageKey(messageId);
      });
    }

    // 高亮会淡出，所以不必永久留在 _highlightedMessageIds 里。
    // [fix 2026-10-17] 记 token 防互踩：连续两次跳同一条消息时，第一次的
    // 3s Timer 到期会把第二次刚设的高亮提前清掉。只有"仍是本次高亮"才清。
    final highlightToken = ++_highlightToken;
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted || highlightToken != _highlightToken) return;
      setState(() => _highlightedMessageIds.remove(messageId));
    });
  }

  int _highlightToken = 0;

  // ---- 会话内查找的记忆化（[fix 2026-10-17]）----
  String _searchCacheKey = '';
  List<({SearchHit first, int count})> _searchCacheHits = const [];
  int _searchCacheTotal = 0;

  /// 展开态命中总数：折叠只在记忆化 miss 时算一次，原始命中数随 miss 一并缓存。
  int get _searchTotalCount => _searchCacheTotal;

  void _scrollToMessageKey(String messageId) {
    final ctx = _messageKeys[messageId]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: 0.28,
    );
  }

  GlobalKey _keyForMessage(String id) {
    _messageIdsInCurrentBuild.add(id);
    return _messageKeys.putIfAbsent(id, () => GlobalKey());
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scroll.onScroll);
    _inputFocusNode.addListener(_onInputFocusChange);

    // 分享接收：从系统分享（SEND intent）进来的内容。文字填进输入框，
    // 图片挂成附件（原生侧已经把 content:// 流抄进缓存、必要时缩小过 ——
    // 那个 URI 的读权限只属于原进程，Dart 侧打不开）。
    _consumePendingShare();
  }

  Future<void> _consumePendingShare() async {
    final shared = await ShareReceiver.consumePending();
    if (shared == null || !mounted) return;

    if (shared.text.isNotEmpty) {
      final cur = _inputController.text;
      _inputController.text =
          cur.isEmpty ? shared.text : '$cur\n${shared.text}';
      setState(() {});
      _scroll.jumpToBottom();
    }

    if (shared.imagePath.isNotEmpty) {
      await _attachSharedImage(shared);
    }
  }

  /// 把分享进来的图片挂成附件。
  ///
  /// 失败必须说清楚原因（太大/读不了），而不是静默不挂 —— 用户以为发出去了
  /// 一张图、agent 却什么都没收到，是最坏的结果。
  Future<void> _attachSharedImage(SharedContent shared) async {
    try {
      final file = File(shared.imagePath);
      if (!await file.exists()) {
        _toast('分享的图片读不到了');
        return;
      }
      final bytes = await file.readAsBytes();
      final name = shared.imageName.isNotEmpty
          ? shared.imageName
          : file.uri.pathSegments.last;
      final media = PickedMedia(
        bytes: bytes,
        name: name.toLowerCase().endsWith('.jpg') ||
                name.toLowerCase().endsWith('.jpeg')
            ? name
            : '$name.jpg',
        mimeType: 'image/jpeg',
      );
      final pending = _prepareImageAttachment(media);
      if (!mounted) return;
      setState(() => _pendingAttachments.add(pending));
      _toast('已从分享挂上 1 张图片');
      _scroll.jumpToBottom();
    } on AttachmentError catch (e) {
      if (mounted) _toast(e.message);
    } catch (e) {
      if (mounted) _toast('分享的图片挂载失败: $e');
    }
  }

  @override
  void dispose() {
    _inputFocusNode.removeListener(_onInputFocusChange);
    _scrollController.removeListener(_scroll.onScroll);

    _noticeBus.dispose();
    _deliverableBusy.dispose();

    _inputFocusNode.dispose();
    _inputController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onInputFocusChange() {
    if (_inputFocusNode.hasFocus && !_scroll.userScrolledUp) {
      _scroll.scrollToBottom();
    }
  }

  // ---- 轮次导航刻度（电脑端同款，v1.26.0）----
  //
  // 右边缘一列短刻度：一轮一格，当前那轮更深更长，点某格跳到那一轮。
  // 电脑端有这个东西，手机上以前只能靠滑 —— 十轮的会话要滑好几屏才回得到某一轮。

  /// 当前可见的是第几轮（1 起）；null = 还没算出来（此时刻度都不高亮）。
  int? _visibleTurn;

  /// 上次算"当前轮"的时刻，用于节流：滚动通知每帧都有，而这里要遍历一遍消息。
  DateTime _lastTurnProbe = DateTime.fromMillisecondsSinceEpoch(0);

  /// 轮次刻度的锚点：**每位真人回话一格**。
  ///
  /// 与状态条 `N 轮` 同一口径（注入通知、上下文/记忆块都不算），否则"第 6 轮"在
  /// 两个地方会指不同的东西。
  List<TurnMark> _turnMarks(DshService dsh) {
    final marks = <TurnMark>[];
    for (final m in dsh.messages) {
      if (!m.isUser || m.isHarnessNotice || m.isContextOrMemory) continue;
      marks.add(TurnMark(turn: marks.length + 1, messageId: m.id));
    }
    return marks;
  }

  /// 用 GlobalKey 的**全局位置**判断当前轮，而不是按滚动比例估算。
  ///
  /// 消息高度差别巨大（一张工具卡能顶十屏），按比例算出来的"第几轮"经常错一两轮 ——
  /// 而这条刻度的全部意义就是"我现在在第几轮"。
  void _probeVisibleTurn() {
    if (!mounted) return;
    final now = DateTime.now();
    if (now.difference(_lastTurnProbe).inMilliseconds < 120) return;
    _lastTurnProbe = now;

    final dsh = context.read<DshService>();
    // 判定的锚点是**视口中心**，不是顶边。
    //
    // [fix 2026-10-17] 之前是"找最后一条越过顶边的真人消息"，于是有两个抖动源：
    //   1. 懒列表里视口上方的消息经常没被构建（GlobalKey 拿不到 context），
    //      循环看不到它们，`current` 会退回默认值 1 —— 用户看到的"乱跳"就是这个；
    //   2. 一条消息恰好贴在顶边时，±1 像素的滚动就会让它在"越过/没越过"之间来回。
    // 改成"离视口中心最近的那一轮"之后，距离是连续量，滚过一轮只会切换一次，
    // 不会来回翻。拿不到任何锚点时**保持现状**，绝不重置。
    final screenH = MediaQuery.sizeOf(context).height;
    final anchorY = screenH * 0.42;

    int? best;
    var bestDistance = double.infinity;
    var turn = 0;
    for (final m in dsh.messages) {
      if (!m.isUser || m.isHarnessNotice || m.isContextOrMemory) continue;
      turn++;
      final ctx = _messageKeys[m.id]?.currentContext;
      if (ctx == null) continue; // 懒列表：这一条还没被构建
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final dy = box.localToGlobal(Offset.zero).dy;
      final distance = (dy - anchorY).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = turn;
      }
    }
    if (best == null) return; // 一个锚点都没有：保持当前高亮，别跳回第 1 轮
    if (best != _visibleTurn) setState(() => _visibleTurn = best);
  }

  /// 跳到第 [turn] 轮：滚到那一轮的第一条真人消息并短暂高亮。
  ///
  /// 复用搜索命中/轨迹面板那条路径（`_highlightAndScrollToMessage`），三处行为一致；
  /// 目标没被构建时它会先按比例粗滚一次，下一帧再精确对齐。
  void _jumpToTurn(DshService dsh, int turn) {
    final marks = _turnMarks(dsh);
    final idx = marks.indexWhere((m) => m.turn == turn);
    if (idx < 0) return;
    final mark = marks[idx];
    final messageIndex = dsh.messages.indexWhere((m) => m.id == mark.messageId);
    _highlightAndScrollToMessage(
      mark.messageId,
      index: messageIndex >= 0 ? messageIndex : null,
      total: dsh.messages.length,
    );
    setState(() => _visibleTurn = turn);
  }

  /// 浮在消息流右边缘的刻度层。
  ///
  /// [fix 2026-10-17] 门槛从 8 轮改为**只要有轮就显示**。
  ///
  /// 之前提 8 轮的理由是"4 轮会话里这列刻度就是一竖串小点，与 AI 消息左侧那条
  /// 2px 竖线叠在同一边距上像杂质"。但那个取舍的代价是**用户根本不知道这个功能
  /// 存在**：绝大多数会话都在 8 轮以内，于是刻度时有时无、看起来像渲染坏了，
  /// 用户的原话是"为什么有的会话有有的没有显示轮次滑块"。
  ///
  /// 现在按用户要求无条件常驻（只要有真人回话）。视觉冲突改用"当前轮是 3×14
  /// 竖条、其余是 3×3 圆点"来区分，而不是靠"干脆不画"。
  Widget _buildTurnRail(DshService dsh) {
    final marks = _turnMarks(dsh);
    // 一条真人消息都没有（空会话 / 只有系统注入）时没有可跳的目标 —— 这是
    // "没有内容"，不是"轮数不够"，所以仍然整层不画。
    if (marks.isEmpty) return const SizedBox.shrink();

    // [fix 2026-10-17] 首次进入会话时 `_visibleTurn` 还是 null（它只在滚动通知里
    // 算出来），于是整条刻度全是灰点 —— 看不出"我现在在第几轮"，而"我在哪"正是
    // 这列刻度的一半价值。这里补一次首帧后的探测：算出来后 `_visibleTurn` 非空，
    // 条件不再成立，不会反复触发。
    if (_visibleTurn == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _probeVisibleTurn();
      });
    }

    return TurnNavigationRail(
      marks: marks,
      currentTurn: _visibleTurn,
      onSelect: (turn) => _jumpToTurn(dsh, turn),
    );
  }

  void _sendMessage(DshService dsh) {
    final text = _inputController.text.trim();
    // 允许"只有附件、没有文字"（引擎的准入规则是"文字或附件"）。
    if (text.isEmpty && _pendingAttachments.isEmpty) return;

    // Graceful offline degradation guard (F3.4)
    if (!dsh.isConnected) {
      HapticFeedback.heavyImpact();
      ScaffoldMessenger.of(context).removeCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('网络已断开，请先重试连接'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: '点击重试',
            // 这里要的是"深底上的强调色"，不能直接用 `context.c.accent`：
            // SnackBar 在两种主题下都是深底，而浅色主题的 accent 是深蓝
            // （#3F5AF0），压在深灰 SnackBar 上对比度比原来的浅蓝更低。
            // `colorScheme.inversePrimary` 正是 Flutter 为"反色场景"预留的
            // 槽位（浅色方案下它是 primary 的提亮版），两套主题都成立，
            // 也就不需要再写一个硬编码色值字面量。
            textColor: Theme.of(context).colorScheme.inversePrimary,
            onPressed: () => dsh.retryConnection(),
          ),
        ),
      );
      return;
    }

    HapticFeedback.lightImpact();
    // 先把附件交给发送、再清空 —— 顺序反过来会让 sendChatMessage 收到空列表。
    final outgoing = List<PendingAttachment>.from(_pendingAttachments);
    _inputController.clear();
    setState(() => _pendingAttachments.clear());

    if (dsh.isSessionRunning) {
      // agent 正在跑：这条消息**排队**（等本轮结束后由引擎自动续发），且**不**
      // 插入本地乐观气泡 —— 队列与回合真值都以服务端为准，插一份本地副本只会
      // 在引擎回传后变成两条。
      //
      // 要立刻插进正在跑的回合，入口只有队列条目上的「立即插话」，那里要再点
      // 一次确认。这里没有第二含义（v1.14 删掉了"排队/插话"开关）。
      unawaited(_deliverWhileRunning(dsh, text, outgoing));
    } else {
      dsh.sendChatMessage(text, attachments: outgoing);
    }
    _scroll.scrollToBottom();
  }

  /// 运行中投递（恒为排队）：失败必须把内容还回来。
  ///
  /// 输入框已经清空了（乐观清空是为了让连续发送手感正常），所以失败时要把
  /// 正文和附件放回输入框，否则用户写的东西直接消失。
  ///
  /// 成功/失败都用输入卡片上方的**原地提示条**而不是 `_toast`：失败时提示
  /// 必须和"还回来的正文"待在一起，而 SnackBar 会被下一条 toast 顶掉、2 秒后
  /// 消失 —— 用户可能完全没看见就丢了内容。
  Future<void> _deliverWhileRunning(
    DshService dsh,
    String text,
    List<PendingAttachment> attachments,
  ) async {
    // 队列快照：用它算出"这次调用新增的那一条"，撤回才有准确目标。
    final before = dsh.queueItems.map((q) => q.id).toSet();
    final ok = await dsh.deliverWhileRunning(text, attachments: attachments);
    if (!mounted) return;
    if (ok) {
      // 新增的那一条就是刚落进队列的这条消息。取不到（比如它已被瞬间领取、
      // 或队列暂时读不到）就不显示「撤回」—— 宁可不给这个按钮，也不能让用户
      // 撤回掉另一条别人的消息。
      final added =
          dsh.queueItems.where((q) => !before.contains(q.id)).toList();
      _showNotice(
        '已排队 · 本轮结束后自动发送',
        action: added.isEmpty ? NoticeAction.none : NoticeAction.undoQueue,
        undoItemId: added.isEmpty ? null : added.last.id,
      );
      _scroll.scrollToBottom();
      return;
    }
    _inputController.text = text;
    _inputController.selection = TextSelection.collapsed(offset: text.length);
    setState(() => _pendingAttachments
      ..clear()
      ..addAll(attachments));
    _showNotice('排队失败，内容已放回输入框', ok: false, action: NoticeAction.retrySend);
  }

  /// 选取并挂载附件（§4.2）。
  ///
  /// 图片在挂载时就压好、编码好、验过大小；文件在挂载时就已经上传完、拿到凭据。
  /// 之所以都前移到"挂载"这一步而不是等发送：失败必须当场说清。用户挂上一张 8MB
  /// 的图、写了一大段话、点发送，才发现图没传上去 —— 那是最差的失败方式。
  Future<void> _attach(DshService dsh, {required bool asFile}) async {
    try {
      final media = asFile
          ? await AttachmentPicker.instance.pickFile()
          : await AttachmentPicker.instance.pickImage();
      if (media == null) return; // 用户取消

      if (media.bytes.length > AttachmentPicker.maxUploadBytes && asFile) {
        final mb = (media.bytes.length / (1024 * 1024)).toStringAsFixed(1);
        _toast('文件 ${mb}MB 超过上限 32MB');
        return;
      }

      PendingAttachment? attachment;
      if (asFile || !media.isImage) {
        // 文件：先上传换凭据。这一步可能耗时，给个进度提示。
        _toast('正在上传 ${media.name}…');
        final receiptId =
            await dsh.uploadAttachment(name: media.name, bytes: media.bytes);
        attachment = PendingFile(
          localId: _nextAttachmentId(),
          name: media.name,
          byteLength: media.bytes.length,
          receiptId: receiptId,
        );
      } else {
        // 图片：直接在本地编码成 image part，不发网络请求。
        attachment = _prepareImageAttachment(media);
      }

      if (!mounted) return;
      setState(() => _pendingAttachments.add(attachment!));
      ScaffoldMessenger.of(context).clearSnackBars();
    } on AttachmentError catch (e) {
      // 面向用户的原因（太大 / 空文件 / 上传被拒），直接展示。
      _toast(e.message);
    } catch (e) {
      debugPrint('[ChatView] 附件处理失败: $e');
      _toast('附件处理失败，请重试');
    }
  }

  /// 把一张已就位的图片变成可发送的附件（含 base64 编码与上限校验）。
  ///
  /// 抽出来是因为现在有两条入口：相册选取、系统分享进来的图片。两条都必须
  /// 走同一套校验 —— 否则分享那条能绕过 1.4MB 内联上限，直到发出去才被网关拒。
  PendingAttachment _prepareImageAttachment(PickedMedia media) =>
      PendingImage.fromPicked(media, localId: _nextAttachmentId());

  /// 选择入口：图片 / 文件。做成底部弹窗而不是两个按钮，是因为输入栏的横向
  /// 空间已经很紧（输入框 + 麦克风 + 发送），再加两个图标会挤。
  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return DateFormat('HH:mm').format(dt);
    }
    return DateFormat('MM-dd HH:mm').format(dt);
  }

  // Session Permission Dialog / BottomSheet

  @override
  Widget build(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final currentSession = dsh.currentSession;
    final currentWs = dsh.currentWorkspace;
    // 顶栏第二行显示的工作区名。取自**当前会话反查**的归属，而不是 currentWs ——
    // 从搜索结果/通知按 id 打开的会话可能不属于任何已加载工作区，那样会显示一个
    // 相邻工作区的名字（不同工作区可以有同名会话，用户无从察觉）。查不到就是 null，
    // 这一行整行不渲染。
    final workspaceTitle = dsh.workspaceOfCurrentSession?.title;
    final sessionId = currentSession?.sessionId ?? 'default';
    final policy = dsh.getSessionPermission(sessionId);
    final currentSessionId = currentSession?.sessionId;
    // [fix 2026-10-11 → 2026-10-17 真修] 此前 dshRunningId 取自
    // dsh.currentSession —— 与 currentSession 自比恒真，修复是空操作：只要
    // isSending 全局为真，别的会话在跑时本会话也点亮停止键。现在用服务侧
    // 真正记录的"正在发送的会话 id"（所有 _isSending 置 true 的写入点都会
    // 在 _setSending 里登记归属）。
    final dshRunningId = dsh.sendingSessionId;
    final isSessionRunning = (currentSession?.isRunning ?? false) ||
        (dsh.isSending &&
            dshRunningId != null &&
            currentSessionId != null &&
            (currentSession?.matchesSessionId(dshRunningId) ?? false));
    final activeApprovals = dsh.pendingApprovals.where((ApprovalRequest a) {
      if (currentSessionId == null) return false;
      // 会话归属不明的审批（网关侧 sessionId 解析失败落了 'default'）不进
      // 对话流 —— 原来的 `|| a.sessionId == 'default'` 把它塞进**每一个**
      // 会话里，同一张审批卡满屏重复。这类审批统一由安全页的计数摘要
      // 承接（那里按总数显示，且 banner 有"跳到所属会话"出口）。
      if (a.sessionId.isEmpty || a.sessionId == 'default') return false;
      final cleanCurrent = currentSessionId.replaceFirst('session-', '');
      final cleanReq = a.sessionId.replaceFirst('session-', '');
      return a.sessionId == currentSessionId || cleanReq == cleanCurrent;
    }).toList();

    // 滚动 diff 状态机（键盘高度 / 流式增长 / 消息条数 / 会话切换）整体在
    // `ChatScrollController` 里；这里只剩调用。它必须在 build 期间跑完 —— 原因见
    // 那边的说明（有几处 setState 的时序与老实现逐字相同）。
    _scroll.syncBeforeBuild(
      dsh,
      MediaQuery.of(context).viewInsets.bottom,
      onSessionSwitched: (previousSessionId) =>
          _onScrollSessionSwitched(dsh, previousSessionId),
    );

    // 「本轮产出」卡片（v1.14）：**由事件驱动**，不是由"清单里有东西"驱动。
    //
    // 差别是实质性的：进会话时补拉到的旧交付物属于**状态**（它该出现在状态条的
    // "产出 N"和信息面板里），若把这份清单直接渲染到消息流尾部，它会冒充"刚刚
    // 交付"，而它可能来自好几轮以前。所以锚点在**收到 deliverables 事件**那一刻
    // 才设置；随后 REST 结果回来就把卡片渲染出来。
    //
    // 位置放在会话切换判断**之后**：否则"切会话"与"事件到达"落在同一帧时，
    // 会话切换块会把刚设好的锚点清掉 —— 顺序反过来的话就是一帧的随机性。
    final deliverableEvents = dsh.deliverableEventCount;
    if (deliverableEvents != _lastSeenDeliverableEvents) {
      _lastSeenDeliverableEvents = deliverableEvents;
      _outputCardAnchorIndex =
          dsh.messages.isEmpty ? -1 : dsh.messages.length - 1;
    }
    final lastMsg = dsh.messages.isNotEmpty ? dsh.messages.last : null;
    final isStreaming = lastMsg != null && lastMsg.isStreaming;
    // 卡片只在"那条 assistant 消息仍然是最后一条"时显示：用户一旦发出下一条
    // 消息（乐观插入用户气泡），锚点就对不上，卡片自动消失 —— 那时它已经不是
    // "刚刚发生的事"，常驻记录在信息面板里。
    final showTurnOutput = _outputCardAnchorIndex >= 0 &&
        dsh.messages.isNotEmpty &&
        dsh.messages.length - 1 == _outputCardAnchorIndex &&
        dsh.deliverables.isNotEmpty &&
        !isStreaming;

    return Scaffold(
      backgroundColor: context.c.surfaceMuted,
      // [v1.27] 键盘 inset 只由**输入栏自己**抬升（见 composer 的
      // `_buildInputBar`：外层 `Padding(bottom: viewInsets.bottom)`）。
      //
      // 关掉 Scaffold 的自动 resize 是因为内外两层 Scaffold 各抬一次会相互博弈
      // （外层 `main_shell` 已经按 `keyboardOpen ? null : bottomNavigationBar` 让位）：
      // 内层再按完整键盘高度抬一次，输入框下方就会空出一条与导航栏等高的空白。
      resizeToAvoidBottomInset: false,
      appBar: ChatAppBar(
        dsh: dsh,
        currentSession: currentSession,
        policy: policy,
        isSessionRunning: isSessionRunning,
        workspaceTitle: workspaceTitle,
        searchOpen: _searchOpen,
        deliverablesUnread: _deliverablesUnread(dsh),
        liveJobCount: _liveJobCount(dsh),
        onOpenSessionInfo: (section) => _openSessionInfo(dsh, section: section),
        onToggleSearch: _toggleSearch,
        // 与 `main_shell` 里 PopScope 的侧滑返回同一条动线：离开会话 = 回工作区 tab。
        // 之前这条路径只存在于手势里，界面上没有可见入口。
        onBackToWorkspaces: () => widget.onOpenWorkspaces?.call(),
      ),
      body: Column(
        children: [
          ChatTopBanners(
            dsh: dsh,
            activeApprovals: activeApprovals,
            onScrollToBottom: _scroll.scrollToBottom,
          ),

          // Chat Body with Floating Jump to Latest Button
          Expanded(
            child: ChatMessageStream(
              dsh: dsh,
              controller: _scrollController,
              onScrollNotification: _scroll.onScrollNotification,
              turnRail: _buildTurnRail(dsh),
              showTurnOutput: showTurnOutput,
              showEmptyState: dsh.messages.isEmpty && activeApprovals.isEmpty,
              buildItem: (ctx, msgIndex) {
                final m = dsh.messages[msgIndex];
                // 附 GlobalKey：会话内查找要靠 ensureVisible 精确滚到
                // 命中的那条消息。没有 key 只能按索引估算 offset，而
                // 消息高度是可变的，估算必然滚偏。
                final highlighted = _highlightedMessageIds.contains(m.id);
                Widget built = _buildMessageItem(
                  m,
                  dsh,
                  isTurnStart: _isTurnStartOf(dsh.messages, msgIndex),
                );
                // [fix 2026-10-16] 只给正在流式的那条加
                // RepaintBoundary。它是唯一逐 chunk 重绘的气泡，
                // 里面是 MarkdownBody 重新解析 + 链接化扫描；
                // 不给它单独一层，每帧的光栅化会连带波及列表里
                // 已经稳定的历史气泡。历史消息包了反而是浪费
                // （它们不重绘，多一层 saveLayer）。
                if (m.isStreaming) {
                  built = RepaintBoundary(child: built);
                }
                if (highlighted) {
                  // 高亮放在这里而不是 _buildMessageItem 内部：这样
                  // 记忆卡、工具卡等所有分支都被同一层覆盖，不必逐个
                  // 分支记得包一次（漏一个就是"某些消息不高亮"）。
                  built = DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.c.warningBadgeSurface.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: context.c.warning,
                        width: 1.2,
                      ),
                    ),
                    child: built,
                  );
                }
                return KeyedSubtree(
                  key: _keyForMessage(m.id),
                  child: built,
                );
              },
              buildTrailer: () {
                // 审批卡片不再挂在消息流末尾（详见 ChatBlockerDock 里 _buildApprovalBlocks 的注释）。
                // 这里只剩消息和本轮产出卡。

                // 「本轮产出」卡片：事件进流那一半 —— 交付物出现在
                // 交付它的那一轮之后（见 build 里锚点的说明）。
                //
                // 主点击 = 就地预览，长按 = 下载 / 用其它应用打开 ——
                // 与信息面板逐字同一套手势。这两处曾经不一致：会话里
                // 点一下要下载 + 切应用，面板里点一下只是看一眼。
                return TurnOutputCard(
                  deliverables: dsh.deliverables,
                  busyPath: _deliverableBusy.value,
                  errorText: _deliverableError,
                  onOpen: (item) => _previewDeliverable(dsh, item),
                  // Phase 4.7：长按不再直接下载，而是弹**统一**的 action sheet
                  // （打开预览 / 下载并打开 / 复制路径）。卡片上的说明文字仍写
                  // "长按下载"—— 那句描述的是"长按能得到下载"，弹层里确实有它，
                  // 而多出来的两个动作是白送的。
                  onDownload: (item) => _showDeliverableActions(dsh, item),
                  onShowAll: () => _openSessionInfo(dsh,
                      section: SessionInsightSection.deliverables),
                );
              },
              showScrollToBottom: _scroll.showScrollToBottom,
              onScrollToBottom: _scroll.scrollToBottom,
              workspaceName: currentWs?.title,
              onInsertSuggestion: (text) => _inputController.text = text,
            ),
          ),

          // 会话内查找面板（v1.4.2）。位置在交互块之上、输入框之下：查找是会话级
          // 操作，不该被某个提问卡片挤到屏幕外。
          //
          // [fix 2026-10-11] Run the full-text scan exactly once per build.
          // Calling MessageSearch.search twice here meant every streaming
          // rebuild scanned all messages two more times (O(n·len) × 2).
          //
          // [fix 2026-10-17] 记忆化：查询与消息条数都没变时沿用上次结果。
          // 流式期间每个 tick 都重建，而 O(n·len) 全文扫描在长会话 + 打开搜索
          // 时是最重的路径 —— 输入框打一个字都跟着卡。
          if (_searchOpen)
            Builder(builder: (searchCtx) {
              final q = _searchQuery.trim();
              final cacheKey = '$q\u0000${dsh.messages.length}\u0000${dsh.streamRevision}';
              if (q.isNotEmpty && cacheKey != _searchCacheKey) {
                _searchCacheKey = cacheKey;
                final raw = MessageSearch.search(dsh.messages, q);
                _searchCacheTotal = raw.length;
                _searchCacheHits = MessageSearch.collapse(raw);
              }
              final collapsed = q.isEmpty
                  ? const <({SearchHit first, int count})>[]
                  : _searchCacheHits;
              return MessageSearchPanel(
                query: _searchQuery,
                results: collapsed,
                totalHits: q.isEmpty ? 0 : _searchTotalCount,
                onQueryChanged: _onSearchChanged,
                onClose: _toggleSearch,
                onJumpTo: (hit) => _jumpToHit(hit, dsh),
              );
            }),

          // 审批卡片 —— 与提问卡同处输入框上方的固定 dock，不再是消息流里的一项。
          //
          // 放在这里而不是 ListView 尾部：审批是阻塞动作，agent 停下等的就是它。
          // 作为尾部消息时，任何一条长回复都能把它顶出屏幕（用户得先滚到底才能
          // 点「允许一次」），而提问卡早就是固定区 + 限高 + 操作栏钉底。两个卡片
          // 必须一致，否则用户学到的心智模型取决于 Agent 最后说了多长。
          //
          // 限高 + 可滚动的理由见 `ChatBlockerDock` 的文档（显式高度上限，不用 Flexible）。
          ChatBlockerDock(dsh: dsh, approvals: activeApprovals),

          if (dsh.lastTurnFailure != null) ChatTurnFailureBanner(dsh: dsh),

          // Modern Clean Input Bar
          ChatComposer(
            dsh: dsh,
            inputController: _inputController,
            inputFocusNode: _inputFocusNode,
            pendingAttachments: _pendingAttachments,
            noticeBus: _noticeBus,
            queueExpanded: _queueExpanded,
            onToast: _toast,
            onSend: () => _sendMessage(dsh),
            onRemoveAttachment: (attachment) =>
                setState(() => _pendingAttachments.remove(attachment)),
            onPickAttach: () => _showAttachSheet(dsh),
            onPickCommand: () => _showCommandSheet(dsh),
            onPickModel: () => showChatModelSwitchSheet(context, dsh),
            // 模板面板空态里的「去新建」：设置页的快捷指令二级页。
            onOpenSnippets: widget.onOpenSnippets,
            // [feat 2026-10-17] 对话权限搬进输入栏（与模型胶囊并排），
            // 会话信息面板的「会话操作」里不再重复它。
            policyLabel: _policyShortLabel(policy),
            onPickPermission: () => showChatPermissionSheet(context, dsh),
            onToggleQueueExpanded: () =>
                setState(() => _queueExpanded = !_queueExpanded),
            onEditQueueRow: (row) => _editQueueRow(dsh, row),
            onRemoveQueueRow: (row) => _removeQueueRow(dsh, row),
            onSteerQueueRow: (row) => _steerQueueRow(dsh, row),
            onNoticeAction: (notice) => _onNoticeAction(dsh, notice),
            // 状态胶囊行（v1.27）里「待审批 / 待提问」那一枚的右侧按钮。
            // 审批/提问的 dock 就在输入框正上方（`ChatBlockerDock`），所以
            // "去处理"= 滚到底：长回答会把 dock 顶出视野，这一步就是把它露出来。
            onRevealBlocked: () => _scroll.scrollToBottom(),
          ),
        ],
      ),
    );
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
  Widget _buildMessageAttachments(
      ChatMessage msg, DshService dsh, bool isUser) {
    if (!msg.hasAttachments) return const SizedBox.shrink();

    final blocks = <Widget>[
      for (final bytes in msg.localImagePreviews)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220, maxHeight: 320),
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                // 与 AttachmentImageTile 同一个理由：按显示尺寸解码，别把整张原图
                // 解进内存（一张 12MP 照片几十 MB，滚几条消息就能把 App 顶 OOM）。
                cacheWidth: (220 * MediaQuery.devicePixelRatioOf(context))
                    .round()
                    .clamp(1, 4096),
                errorBuilder: (_, __, ___) => Container(
                  width: 180,
                  height: 90,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: context.c.warningSurface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: context.c.warningBorder),
                  ),
                  child: Text(
                    '图片预览不可用',
                    style: TextStyle(fontSize: 11, color: context.c.warning),
                  ),
                ),
              ),
            ),
          ),
        ),
      for (final ref in msg.attachments)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          // Phase 4.7：附件长按 → **同一个** action sheet（动作集按上下文裁剪，
          // 见 `_showAttachmentActions`）。包在这里而不是改 `attachment_tile.dart`：
          // 那个组件是纯展示的，长按属于"这条消息的交互"，归会话页。
          child: GestureDetector(
            onLongPress: () => _showAttachmentActions(dsh, ref),
            child: ref.isImage
                ? AttachmentImageTile(
                    ref: ref,
                    // 字节留在宿主机：必须带 Authorization 头去取（见 AttachmentImageTile）。
                    endpoint: dsh.attachmentUrl(ref),
                    maxWidth: 220,
                  )
                : _attachmentFileRow(ref),
          ),
        ),
    ];

    return Column(
      crossAxisAlignment:
          isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: blocks,
    );
  }

  /// 文件附件的一行：图标 + 文件名 + MIME/体积。
  ///
  /// 刻意**不做**点击打开：下载 + 拉起外部应用那条链路目前只服务于交付物
  /// （`deliverable_preview_sheet` 里有完整实现）。这里先把"这条消息带了什么文件"
  /// 如实显示出来，而不是给一个点了报错的按钮。
  Widget _attachmentFileRow(AttachmentRef ref) {
    final kb = ref.byteSize == null
        ? null
        : '${(ref.byteSize! / 1024).toStringAsFixed(0)} KB';
    final meta = [ref.mimeType, if (kb != null) kb].join(' · ');

    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.attach_file_rounded,
              size: 15, color: context.c.textSecondary),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ref.filename ?? ref.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.c.textPrimary,
                  ),
                ),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 10.5, color: context.c.textTertiary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 渲染一条消息气泡。
  ///
  /// [dsh] 是必需的：正文里的产物引用要链接化（靠会话的交付物清单做白名单），
  /// 而点开那些链接又要回到同一个 `DshService` 去取内容。
  ///
  /// [isTurnStart] 表示这条消息是一轮的开头（见 `_isTurnStartOf`）：用户消息恒为
  /// true，assistant 消息只在前面不是 assistant 时成立。它决定两件事 ——
  /// `AI · HH:mm` 标签行是否渲染，以及这条消息上方是轮间 16dp 还是轮内 4dp。
  Widget _buildMessageItem(
    ChatMessage msg,
    DshService dsh, {
    bool isTurnStart = false,
  }) {
    // 0. [feat 2026-10-17] 引擎注入的通知（role 是 user，但没人打过这些字）。
    //
    // 必须是**第一条**分支：它的 role 就是 'user'，一旦落到下面的用户气泡分支就会
    // 渲染成蓝色右对齐气泡 —— 那正是用户报的"我什么时候发过这种消息"。判定放在
    // ChatMessage 里（网关标记优先、锚定文案兜底），见 HarnessNotice。
    if (msg.isHarnessNotice) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        child: HarnessNoticeCard(notice: msg.notice!),
      );
    }

    // 1. Standalone context or memory snapshot message -> Collapsed MemoryCard
    if (msg.isContextOrMemory) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: MemoryCard(content: msg.content),
      );
    }

    // 2. Embedded context markers in message -> Split prompt and collapse context part
    const contextMarkers = [
      '<system-reminder>',
      '<runtime-memory-file',
      'MNEMON RUNTIME MEMORY SNAPSHOT',
      '[MNEMON]',
      'Current runtime context.',
      'Instructions from:',
      '<available_skills>',
      'Contents of ',
    ];

    // [fix 2026-10-16] marker 扫描按 (id, content.length) 记忆化。
    //
    // 这 9 个 indexOf 是对**整条正文**做的，而 build 每个 flush 边界跑一次。
    // 流式消息一条回复能到几千字符，等于每个 100ms 窗口白扫 9 × 几千字符。
    // marker 的位置在内容变长后只会前移或不变（它是正文里的固定字面量），
    // 所以缓存是安全的：key 里带 content.length，内容一长就重算。
    //
    // 用 message id 而不是 index 作 key：翻页 / 删除会让索引错位。
    final markerCacheKey = '${msg.id}@${msg.content.length}';
    final cached = _contextMarkerCache[markerCacheKey];
    int earliestMarkerIndex;
    if (cached != null) {
      earliestMarkerIndex = cached;
    } else {
      earliestMarkerIndex = -1;
      for (final marker in contextMarkers) {
        final idx = msg.content.indexOf(marker);
        if (idx != -1) {
          if (earliestMarkerIndex == -1 || idx < earliestMarkerIndex) {
            earliestMarkerIndex = idx;
          }
        }
      }
      // 只保留最近若干条，避免长时间挂机的会话把缓存撑大。
      if (_contextMarkerCache.length > 64) _contextMarkerCache.clear();
      _contextMarkerCache[markerCacheKey] = earliestMarkerIndex;
    }

    String displayContent = msg.content;
    String? embeddedContext;
    if (earliestMarkerIndex == 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: MemoryCard(content: msg.content),
      );
    } else if (earliestMarkerIndex > 0) {
      displayContent = msg.content.substring(0, earliestMarkerIndex).trim();
      embeddedContext = msg.content.substring(earliestMarkerIndex).trim();
    }

    if (displayContent.isEmpty &&
        (embeddedContext != null && embeddedContext.isNotEmpty)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: MemoryCard(content: embeddedContext),
      );
    }

    final isUser = msg.role == 'user';
    final topGap = isTurnStart ? AppSpace.xl : AppSpace.s;

    // ---- 用户消息：消息流里唯一保留实心气泡的角色 ----
    if (isUser) {
      // 长按触发器的取舍见 `_buildMessageItem` 上方「Phase 4.7」那段总说明：
      // 正文里的长按仍然是系统选词（SelectableText 在命中区内先赢手势竞技场），
      // 这条 onLongPress 只在按住气泡内边距 / 附件行 / 时间戳行时触发。
      final userMarkdownStyle = _userMarkdownStyle;
      return Padding(
        padding: EdgeInsets.only(top: topGap, bottom: AppSpace.m),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(
              child: GestureDetector(
                onLongPress: () => _showMessageActions(dsh, msg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _buildMessageAttachments(msg, dsh, true),
                    if (displayContent.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.l,
                          vertical: AppSpace.m,
                        ),
                        decoration: BoxDecoration(
                          color: context.c.userBubble,
                          // 圆角统一 12：以前右上角是 3 的小圆角当"气泡尾巴"。
                          // 那套拟物语言与现在的扁平层级冲突，而且 3px 的小角在
                          // 深色下看起来像缺了一块。
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SafeMarkdown(
                          data: linkifyDeliverableRefs(
                              displayContent, dsh.deliverables),
                          selectable: true,
                          onTapLink: (text, href, title) =>
                              _openMessageLink(dsh, href),
                          fallbackTextStyle: TextStyle(
                            fontSize: AppText.title,
                            color: _onSolidBubble,
                            height: 1.5,
                          ),
                          styleSheet: userMarkdownStyle,
                          // 代码块右上角「全屏阅读」（Phase 5.1）。
                          builders: _codeBlockBuilders(userMarkdownStyle.code),
                        ),
                      ),
                    if (embeddedContext != null && embeddedContext.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpace.s),
                        child: MemoryCard(content: embeddedContext),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpace.xs),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _formatTime(msg.timestamp),
                            style: TextStyle(
                              color: context.c.textTertiary,
                              fontSize: AppText.caption,
                            ),
                          ),
                          // 长按是**不可发现**的手势，所以每条消息都留一个显式的
                          // 「⋯」入口（点一下就是同一个 sheet）。放在时间戳旁边
                          // 而不是气泡角上：那里不会跟正文的任何字形抢位置。
                          _messageMoreButton(
                              msg.id, () => _showMessageActions(dsh, msg)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppSpace.m),
            // [fix 2026-10-17] 用户头像已删除。真机上它是一个 30×30 的**实心
            // accent 方块 + 白色人形**，紧贴在彩色气泡右侧：既和气泡抢视觉重量，
            // 又在"AI 消息没有头像"的对照下显得只对用户特殊。右对齐 + 填色气泡
            // 本身已经足够说明"这是我说的"。
          ],
        ),
      );
    }

    // ---- AI 消息：裸排版（Phase 2.1）----
    //
    // 改动前：surface 底 + 1px border + radius 10/3 的气泡，外加每条消息前面一个
    // 30×30 的 auto_awesome 头像方块。一条 AI 回复只要被拆成 5 条流式消息，屏幕上
    // 就是 5 个一样的头像 + 5 个一样的卡片边框 —— 视觉噪音几乎全部来自这些"每条
    // 消息都重复一次"的装饰，而不是内容本身。
    //
    // 现在：**没有容器底色、没有描边、没有头像**。唯一的身份标识是左侧 2px 的
    // accent 竖线（35% 不透明），且竖线纵向覆盖这条消息的全部内容（思考 / 工具 /
    // 正文）—— 连续几条 assistant 消息因此会拼成一段连续的引文，那才是"一轮回答"
    // 的形状。身份信息补偿到轮首那一行 caption：「AI · HH:mm」。
    final assistantMarkdownStyle = _assistantMarkdownStyle;
    return Padding(
      padding: EdgeInsets.only(
        top: topGap,
        bottom: isTurnStart ? AppSpace.m : AppSpace.s,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isTurnStart)
            // 轮首那行 caption 也接长按：它属于"气泡外框"，是最容易被按住的一块
            // 非正文区域（正文里的长按留给系统选词）。
            GestureDetector(
              onLongPress: () => _showMessageActions(dsh, msg),
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.s),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'AI · ${_formatTime(msg.timestamp)}',
                      style: TextStyle(
                        fontSize: AppText.caption,
                        color: context.c.textTertiary,
                        height: 1.2,
                      ),
                    ),
                    // 显式的「⋯」入口只挂在**轮首**那一条上：流式回复被拆成十几条
                    // assistant 消息，每条挂一个就等于在屏幕上撒十几个省略号。轮首
                    // 那一条足够发现这套交互，其余的靠长按外框（同 `_showMessageActions`）。
                    _messageMoreButton(
                        msg.id, () => _showMessageActions(dsh, msg)),
                  ],
                ),
              ),
            ),
          // Phase 4.7：长按外框（左侧竖线区 / 边缘内边距 / 工具卡）弹统一 sheet；
          // 正文里的长按仍是系统选词。理由见 `_showMessageActions` 上方的总说明。
          GestureDetector(
            onLongPress: () => _showMessageActions(dsh, msg),
            child: Container(
              decoration: BoxDecoration(
                // aiBubble 在两种主题下都是透明 —— 显式写出来是为了让"AI 气泡
                // 无底色"成为一段可读的声明，而不是靠省略参数来表达。
                color: context.c.aiBubble,
                border: Border(
                  left: BorderSide(
                    color: context.c.accent.withOpacity(0.35),
                    width: 2,
                  ),
                ),
              ),
              padding: const EdgeInsets.only(left: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 思考过程：引用块，无底色（见 thinking_card.dart）。
                  if ((msg.thinking != null && msg.thinking!.isNotEmpty) ||
                      (msg.isStreaming && msg.content.isEmpty))
                    ThinkingCard(
                      content: msg.thinking ?? '',
                      isThinking: msg.isStreaming,
                    ),

                  // 工具调用：同一消息内 ≥3 个聚合成一行（阈值在
                  // AggregatedToolCalls 里），<3 个逐条渲染。
                  if (msg.tools.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.s),
                      child: AggregatedToolCalls(tools: msg.tools),
                    ),

                  _buildMessageAttachments(msg, dsh, false),

                  if (displayContent.isNotEmpty)
                    SafeMarkdown(
                      // 正文里提到本会话声明过的产物时，把它变成可点链接（长按
                      // 复制原文仍然可用）。只认清单白名单，所以正文里的示例路径、
                      // 别人的目录都不会被误变成一个点开就报错的链接。
                      data: linkifyDeliverableRefs(
                          displayContent, dsh.deliverables),
                      selectable: true,
                      onTapLink: (text, href, title) =>
                          _openMessageLink(dsh, href),
                      fallbackTextStyle: TextStyle(
                        fontSize: AppText.title,
                        color: context.c.textPrimary,
                        height: 1.5,
                      ),
                      styleSheet: assistantMarkdownStyle,
                      // 代码块右上角「全屏阅读」（Phase 5.1）。
                      builders: _codeBlockBuilders(assistantMarkdownStyle.code),
                    ),

                  if (embeddedContext != null && embeddedContext.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpace.s),
                      child: MemoryCard(content: embeddedContext),
                    ),

                  if (msg.isStreaming)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpace.s),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: context.c.accent,
                            ),
                          ),
                          const SizedBox(width: AppSpace.s),
                          Text(
                            'AI 正在思考并执行操作...',
                            style: TextStyle(
                              color: context.c.textSecondary,
                              fontSize: AppText.caption,
                            ),
                          ),
                        ],
                      ),
                    ),

                  // 时间戳只出现在轮首那行「AI · HH:mm」里。
                  // 流式回复会被拆成十几条 assistant 消息，逐条带一个时间戳等于在
                  // 同一段回复里显示十几个相隔几秒的时刻 —— 信息量为零的噪音。
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 这条消息是不是「一轮」的开头。
  ///
  /// 用户消息永远开启新一轮；assistant 消息只有前面不是 assistant 时才算轮首
  /// （它的时间戳和身份标签就渲染在那里）。用它同时决定两件事：AI 标签行 +
  /// 轮内 4dp / 轮间 16dp 的垂直节奏。
  bool _isTurnStartOf(List<ChatMessage> messages, int index) {
    if (index < 0 || index >= messages.length) return false;
    final msg = messages[index];
    if (msg.role == 'user') return true;
    if (msg.role != 'assistant') return false;
    if (index == 0) return true;
    return messages[index - 1].role != 'assistant';
  }

  /// 权限策略的**短名**（输入栏胶囊用；完整说明在权限弹层里）。
  ///
  /// 只有两个字：这一行在 360dp 上要和斜杠、附件、模型、麦克风、发送共用，
  /// 多一个字就会把模型名挤成 `v4.1-fla…`（用户上一轮刚抱怨过这种截断）。
  String _policyShortLabel(String policy) {
    switch (policy) {
      case 'danger-full-access':
        return '全信任';
      case 'auto-read':
        return '只读';
      case 'ask':
      default:
        return '询问';
    }
  }

  /// 用户气泡里的前景色。  ///
  /// [fix 2026-10-17] 气泡底不再是实心 accent，而是 accent 的浅色 tint
  /// （见 `AppColors.userBubble`），所以前景改用 `textPrimary` —— 深字压浅底，
  /// 同时让**选区高亮**（accent 半透明）真正看得出来。之前白字压实心蓝时，
  /// 选中文字几乎无视觉反馈，用户只能靠"复制"按钮猜。
  Color get _onSolidBubble => context.c.textPrimary;

  /// 用户气泡内的 Markdown 样式。
  ///
  /// 正文 14 → 13.5（`AppText.title`）、行高 1.45 → 1.5。缩一点字号是为了让
  /// 13.5/1.5 的正文在两套主题下都能撑住对比度：气泡底色本身已经是品牌色，
  /// 字号再大就变成"色块里塞满字"。
  MarkdownStyleSheet get _userMarkdownStyle {
    final fg = _onSolidBubble;
    return MarkdownStyleSheet(
      p: TextStyle(fontSize: AppText.title, color: fg, height: 1.5),
      code: TextStyle(
        color: fg,
        backgroundColor: fg.withOpacity(0.2),
        fontFamily: 'monospace',
        fontSize: AppText.subhead,
      ),
      codeblockDecoration: BoxDecoration(
        color: fg.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: fg.withOpacity(0.2)),
      ),
    );
  }

  /// AI 正文的 Markdown 样式。
  ///
  /// 两处关键替换：行内代码的前景色从硬编码的 `0xFF0369A1`（一个只适合浅色底的
  /// 深青蓝）换成 `accent`，底色从 `background` 换成独立的 `codeBackground`
  /// —— 代码块现在和页面底同色，只有一层极淡的描边把它和正文分开。
  MarkdownStyleSheet get _assistantMarkdownStyle {
    return MarkdownStyleSheet(
      p: TextStyle(
        fontSize: AppText.title,
        color: context.c.textPrimary,
        height: 1.5,
      ),
      code: TextStyle(
        color: context.c.accent,
        backgroundColor: context.c.codeBackground,
        fontFamily: 'monospace',
        fontSize: AppText.subhead,
      ),
      codeblockDecoration: BoxDecoration(
        color: context.c.codeBackground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: context.c.border),
      ),
      // [fix 2026-10-17] 标题/表格的默认尺度是给桌面端宽屏准备的：h3 默认 20sp+
      // 比正文（13.5）大一档半，一屏里出现两个小标题就把正文压成注脚；表格默认
      // 单元格内边距 8，三行表格能吃掉半屏。这里按"手机上一屏要看完一段"重新定。
      h1: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: context.c.textPrimary, height: 1.4),
      h2: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: context.c.textPrimary, height: 1.4),
      h3: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: context.c.textPrimary, height: 1.4),
      h4: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: context.c.textPrimary, height: 1.4),
      h5: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: context.c.textPrimary, height: 1.4),
      h6: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: context.c.textTertiary, height: 1.4),
      // 段落之间的呼吸：默认 blockSpacing 是 8，但标题上下没有额外留白，
      // 于是一个标题会和它上面的正文粘在一起。14 让"标题开始新的一段"可读。
      blockSpacing: 14,
      listIndent: 18,
      listBullet: TextStyle(fontSize: AppText.title, color: context.c.textPrimary, height: 1.5),
      // 表格：细边框 + 紧凑单元格。手机宽度下表格本来就挤，单元格内边距必须小，
      // 否则两列就会有一列被压成每行两个字。
      tableHead: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.textPrimary),
      tableBody: TextStyle(fontSize: 13, color: context.c.textPrimary, height: 1.45),
      tableBorder: TableBorder.all(color: context.c.border, width: 0.8),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      tablePadding: const EdgeInsets.only(top: AppSpace.s, bottom: AppSpace.s),
    );
  }

  /// 弹层入口都搬进了 `chat_sheets.dart`；这里是薄转调，保留原调用形态。
  Future<void> _showAttachSheet(DshService dsh) => showChatAttachSheet(
        context,
        dsh,
        toast: _toast,
        onAttach: ({required bool asFile}) => _attach(dsh, asFile: asFile),
      );

  Future<void> _showCommandSheet(DshService dsh) => showChatCommandSheet(
        context,
        dsh,
        inputController: _inputController,
        focusNode: _inputFocusNode,
        toast: _toast,
      );

  // [feat 2026-10-17] 这里原有四个一行转发壳：`_showSessionPermissionSheet` /
  // `_showModelSwitchSheet` / `_showDeleteCurrentSessionDialog` /
  // `_showWorkspaceSwitchSheet`。它们存在的唯一理由是「顶栏 8 项菜单」需要一个
  // `VoidCallback`；菜单收敛进会话信息面板之后，那四项改由 `chat_sheets.dart`
  // 在面板内部直接调用同名函数（那里本来就有 `DshService`），转发壳失去调用方，
  // 于是删掉 —— 留着就是四段永远不会执行的代码。

  Future<void> _openTrajectory(DshService dsh) => showChatTrajectorySheet(
        context,
        dsh,
        onJumpToMessage: (id, index, total) =>
            _highlightAndScrollToMessage(id, index: index, total: total),
      );

  // ======================================================================
  // Phase 4.7：统一的长按 action sheet
  // ======================================================================
  //
  // ## 选了哪个方案：C（正文内长按 = 选词；长按非文本区 = sheet）+ 显式「⋯」
  //
  // 规格给的三个方案里：
  //
  // * **A（长按 = sheet，选词改双击/手柄）不可行**。`SafeMarkdown(selectable:true)`
  //   在 flutter_markdown 0.7.7 里渲染成**每段一个 `SelectableText`**（见包内
  //   `builder.dart` 的 `_buildRichText`），不是整块 `SelectionArea`：
  //   `SelectableText` 的长按 = "选中一个词 + 弹系统工具条"，是 `EditableText`
  //   内部行为，没有任何公开开关能把长按让出去而只留手柄。想做到 A 只能自己
  //   造一套选择实现 —— 那是把系统的复制/全选/分享工具条整条换掉。
  // * **B（长按彻底不作 sheet）太保守**：任务要的是"长按统一 action sheet"，
  //   B 只剩一个按钮可点，长按这条动线就没了。
  // * **C 是事实上的边界**：`SelectableText` 的 `LongPressGestureRecognizer`
  //   在命中区内比外层 `GestureDetector` **更深、先加入手势竞技场**，长按识别器
  //   同时到点时先 resolve accepted——所以正文上方按住 = 选词（系统行为原样），
  //   而按住气泡内边距 / 左侧竖线 / 附件行 / 时间戳行 = 我们这条 `onLongPress`。
  //   这正是 C 描述的切法，而且**不需要给 SafeMarkdown 关 selectable**。
  //
  // 这条边界不是靠读源码断言就算数的，测试里钉了两端
  // （`test/widgets/message_action_sheet_test.dart`）：
  //   * `长按正文不会弹 sheet`（正文长按必须留给系统选词）；
  //   * `长按气泡外框 / 点「⋯」会弹 sheet`。
  //
  // ## 为什么还要一个「⋯」按钮
  //
  // 长按完全不可发现（turn_output_card 里那句"长按下载"的提示就是为了这一点）。
  // 加一个 15dp、textTertiary 的省略号，成本是一行像素，换来的是"这套交互能被
  // 看见"。它和长按走**同一个** `_showMessageActions`，不存在第二条通路。

  /// 消息的「⋯」入口（点一下 = 同一个 action sheet）。
  Widget _messageMoreButton(String messageId, VoidCallback onTap) {
    return InkResponse(
      key: ValueKey('message-more-$messageId'),
      onTap: onTap,
      radius: 16,
      // [fix 2026-10-17] 命中区补到 32px（此前 ≈24px 含 padding）。
      child: SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: Icon(
            Icons.more_horiz_rounded,
            size: 15,
            color: context.c.textTertiary,
          ),
        ),
      ),
    );
  }

  /// 代码块渲染钩子（Phase 5.1）：只替换 `pre`，其余元素走默认渲染。
  ///
  /// 传的是**同一份** `MarkdownStyleSheet.code`：代码块在消息里和全屏页上因此是
  /// 同一套等宽/字号，不存在"点开之后字变了"。
  Map<String, MarkdownElementBuilder> _codeBlockBuilders(TextStyle? codeStyle) {
    return {
      'pre': CodeBlockOpenBuilder(
        codeStyle: codeStyle ??
            TextStyle(
              fontSize: AppText.subhead,
              fontFamily: 'monospace',
              color: context.c.textPrimary,
            ),
        padding: const EdgeInsets.all(AppSpace.l),
      ),
    };
  }

  /// 弹消息的统一 action sheet，动作按上下文裁剪：
  ///
  /// | 动作 | 出现条件 |
  /// |---|---|
  /// | 复制原文 | 有正文 |
  /// | 引用 | 有正文 |
  /// | 重新发送 | 有正文**且**是自己发的 |
  /// | 查看本轮轨迹 | AI 消息（轨迹是**会话级**的，所以不看是否有正文） |
  Future<void> _showMessageActions(DshService dsh, ChatMessage msg) async {
    final text = msg.content.trim();
    final actions = <MessageActionSpec>[
      if (text.isNotEmpty) ...const [
        MessageActionSpec(
          id: 'copy',
          label: '复制原文',
          icon: Icons.copy_rounded,
        ),
        MessageActionSpec(
          id: 'quote',
          label: '引用',
          icon: Icons.format_quote_rounded,
          hint: '以 > 缩进放进输入框',
        ),
      ],
      if (msg.isUser && text.isNotEmpty)
        const MessageActionSpec(
          id: 'resend',
          label: '重新发送',
          icon: Icons.refresh_rounded,
          hint: '输入框里有草稿时不会覆盖它',
        ),
      if (msg.isAssistant)
        const MessageActionSpec(
          id: 'trajectory',
          label: '查看本轮轨迹',
          icon: Icons.timeline_rounded,
        ),
    ];
    if (actions.isEmpty) return; // 纯附件/空消息：没有可做的，别弹空壳

    final picked = await showMessageActionSheet(
      context,
      title: msg.isUser ? '我的消息' : 'AI 消息',
      subtitle: messageActionSnippet(text),
      actions: actions,
    );
    if (picked == null || !mounted) return;

    switch (picked) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: text));
        if (!mounted) return;
        _toast('已复制原文');
      case 'quote':
        _quoteMessage(dsh, text);
      case 'resend':
        _resendMessage(dsh, msg);
      case 'trajectory':
        await _openTrajectory(dsh);
    }
  }

  /// 「引用」：把正文以 `> 内容` 的形式塞进输入框，光标停在引用块之后。
  ///
  /// 三个细节都是刻意的：
  /// * **逐行加 `>`**：一段多行引用如果只给第一行加，后面几行在 Markdown 里就
  ///   掉出了引用块，重发出去的内容与原意不符；
  /// * **插在光标处**（有选区则替换选区）而不是覆盖整个输入框 —— 用户可能正在
  ///   写回复，引用是"补一句"而不是"重来"；
  /// * **同步草稿**：输入框内容会随会话切换被换掉，不同步就等于切一次会话丢一次。
  void _quoteMessage(DshService dsh, String content) {
    final text = content.trim();
    if (text.isEmpty) return;

    final quoted = text
        .split('\n')
        .map((line) => line.trim().isEmpty ? '>' : '> $line')
        .join('\n');
    final insert = '$quoted\n\n';

    final value = _inputController.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final next = value.text.replaceRange(start, end, insert);

    _inputController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    dsh.updateDraft(next);
    _inputFocusNode.requestFocus();
    _toast('已引用到输入框');
  }

  /// 「重新发送」：原样再发一次这条消息。
  ///
  /// **不**静默覆盖输入框里未发出的草稿。原因：重发是用户自己发起的破坏性动作，
  /// 而草稿是他刚写完还没交出去的字 —— 悄悄丢掉后者比"这次重发没成功"糟得多。
  /// 所以有草稿时把焦点交回输入框并说明，让他先决定草稿怎么办。
  void _resendMessage(DshService dsh, ChatMessage msg) {
    final text = msg.content.trim();
    if (text.isEmpty) return;
    if (_inputController.text.trim().isNotEmpty) {
      _inputFocusNode.requestFocus();
      _toast('输入框里还有没发出去的内容，先清空再重发');
      return;
    }
    _inputController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _sendMessage(dsh);
  }

  /// 附件长按：同一个 sheet，附件专属动作。
  ///
  /// 附件没有"路径"可复制（字节留在宿主机，网关只给 id + 元数据），所以动作集是
  /// 打开图片（仅图片）/ 复制文件名 / 复制附件 ID —— 最后一个是排障时唯一稳定的
  /// 句柄（`sha256:…` 就是网关侧的 key）。
  Future<void> _showAttachmentActions(DshService dsh, AttachmentRef ref) async {
    final name = (ref.filename != null && ref.filename!.trim().isNotEmpty)
        ? ref.filename!.trim()
        : ref.id;
    final meta = [
      ref.mimeType,
      if (ref.byteSize != null)
        '${(ref.byteSize! / 1024).toStringAsFixed(0)} KB',
    ].join(' · ');

    final picked = await showMessageActionSheet(
      context,
      title: name,
      subtitle: meta,
      actions: [
        if (ref.isImage)
          const MessageActionSpec(
            id: 'open-image',
            label: '打开图片',
            icon: Icons.open_in_full_rounded,
            hint: '全屏查看，可双指缩放',
          ),
        const MessageActionSpec(
          id: 'copy-filename',
          label: '复制文件名',
          icon: Icons.copy_rounded,
        ),
        const MessageActionSpec(
          id: 'copy-attachment-id',
          label: '复制附件 ID',
          icon: Icons.fingerprint_rounded,
          hint: '排障时用它定位这个附件',
        ),
      ],
    );
    if (picked == null || !mounted) return;

    switch (picked) {
      case 'open-image':
        await _showAttachmentImage(dsh, ref);
      case 'copy-filename':
        await Clipboard.setData(ClipboardData(text: name));
        if (!mounted) return;
        _toast('已复制文件名');
      case 'copy-attachment-id':
        await Clipboard.setData(ClipboardData(text: ref.id));
        if (!mounted) return;
        _toast('已复制附件 ID');
    }
  }

  /// 全屏看一张消息里的图片。
  ///
  /// 复用 `dsh.attachmentUrl(ref)`（同一份 Authorization 头）：裸 `Image.network`
  /// 会 401，而图片字节留在宿主机、必须带 token 去取。
  Future<void> _showAttachmentImage(DshService dsh, AttachmentRef ref) async {
    final endpoint = dsh.attachmentUrl(ref);
    if (endpoint == null) {
      _toast('未连接网关，取不到这张图');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => Dialog(
        key: const ValueKey('attachment-image-viewer'),
        insetPadding: const EdgeInsets.all(AppSpace.l),
        backgroundColor: dialogCtx.c.background,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 4,
                child: Image.network(
                  endpoint.url,
                  headers: endpoint.headers,
                  fit: BoxFit.contain,
                  // 缩略图已经解码过一次；这里不能再用 cacheWidth —— 全屏看的就是
                  // 细节，按显示尺寸降采样等于"点开之后更糊"。
                  errorBuilder: (_, __, ___) => Center(
                    child: Text(
                      '图片加载失败',
                      style: TextStyle(
                        fontSize: AppText.body,
                        color: dialogCtx.c.danger,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: AppSpace.xs,
              right: AppSpace.xs,
              child: IconButton(
                key: const ValueKey('attachment-image-close'),
                icon:
                    Icon(Icons.close_rounded, color: dialogCtx.c.textSecondary),
                onPressed: () => Navigator.pop(dialogCtx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 产出卡长按：同一个 sheet，交付物专属动作（打开 / 下载 / 复制路径）。
  ///
  /// 与信息面板、正文产物链接**共用同一批实现**（`_previewDeliverable` /
  /// `_openDeliverable`）：三个入口一套行为，不存在"同一个文件在三处不一样"。
  Future<void> _showDeliverableActions(
      DshService dsh, DeliverableItem item) async {
    final picked = await showMessageActionSheet(
      context,
      title: item.fileName,
      subtitle: item.description.isNotEmpty ? item.description : item.path,
      actions: const [
        MessageActionSpec(
          id: 'open',
          label: '打开预览',
          icon: Icons.visibility_rounded,
          hint: '只读，不落文件',
        ),
        MessageActionSpec(
          id: 'download',
          label: '下载并打开',
          icon: Icons.download_rounded,
          hint: '落一份到手机上，交给系统应用',
        ),
        MessageActionSpec(
          id: 'copy-path',
          label: '复制路径',
          icon: Icons.content_copy_rounded,
          hint: '绝对路径，可直接粘到聊天里',
        ),
      ],
    );
    if (picked == null || !mounted) return;

    switch (picked) {
      case 'open':
        await _previewDeliverable(dsh, item);
      case 'download':
        await _openDeliverable(dsh, item);
      case 'copy-path':
        await Clipboard.setData(ClipboardData(text: item.path));
        if (!mounted) return;
        _toast('已复制路径');
    }
  }

  /// 滚动状态机检到"会话换了"时，属于 State 的那部分重置。
  ///
  /// 顺序与原来 build() 里的那段逐行一致：先清界面态，再换草稿。
  void _onScrollSessionSwitched(DshService dsh, String? previousSessionId) {
    // 会话级的界面状态跟着切：队列展开态、产出卡片锚点、失败提示。
    _queueExpanded = false;
    _outputCardAnchorIndex = -1;
    _lastSeenDeliverableEvents = dsh.deliverableEventCount;
    _deliverableBusy.value = null;
    _deliverableError = null;
    // 切会话时换草稿（v1.4.2）。
    //
    // ⚠️ 两个坑，改动前都真实存在（v1.14 修）：
    //
    // 1) **不能**在这里调 `dsh.updateDraft(...)`。它的键是"当前会话"，而此刻
    //    `_currentSession` 已经是**新**会话了 —— 等于把旧会话的正文写进新会话的
    //    草稿槽。后果是：切回旧会话时输入框被它自己的旧草稿（往往是空的）覆盖，
    //    用户刚打的字凭空消失；而那半句话则悄悄出现在新会话的输入框里。
    //    所以这里按**上一个会话的 id** 显式写回它自己的槽位。
    // 2) **首次进入不能写**。上一个会话 id 为 null 时（首个会话），输入框必然
    //    是空的，写进去等于把这个会话已存的草稿用空串清掉（`DraftStore.write`
    //    收到空串就是删除）。
    if (previousSessionId != null &&
        previousSessionId != dsh.currentSession?.sessionId) {
      dsh.drafts.write(previousSessionId, _inputController.text);
    }
    final restored = dsh.currentDraft;
    _inputController.text = restored;
    _inputController.selection =
        TextSelection.collapsed(offset: restored.length);
    // [fix 2026-10-17] 跨会话缓存清理：每条历史消息一个 GlobalKey（注册表
    // 常驻）、产出已读标记按会话累积 —— 此前只增不减，长会话/频繁切换下
    // 慢性内存增长。切走时把**上一个会话**的条目清掉（当前会话的消息键由
    // build 期间的 putIfAbsent 重新登记）。
    if (previousSessionId != null) {
      _messageKeys.removeWhere((id, _) => id.startsWith('$previousSessionId#'));
    }
    _messageKeys.removeWhere((id, _) => !_messageIdsInCurrentBuild.contains(id));
    _deliverablesAck.removeWhere((key, _) => !key.contains(dsh.currentSession?.sessionId ?? '\u0000'));
  }

  /// 当前 build 中实际注册过 key 的消息 id（跨会话清理的保留名单，
  /// 由 `_keyForMessage` 维护）。
  final Set<String> _messageIdsInCurrentBuild = {};

  void _toast(String msg) {
    if (!mounted) return;
    // [feat 2026-10-17] 瞬时提示统一走**顶部**浮层（见 TopToast 的说明）：
    // 底部被输入卡片 / 状态胶囊 / 审批 dock 占满，贴底的 SnackBar 会盖住用户
    // 正在打的字，而且紧挨输入框会被读成"输入框的一部分"。
    //
    // 注意分工：这里只放**不痛的消息**（1.8 秒自己走）。失败类提示一律走
    // `ComposerNotice` / `InlineErrorBar` 那种留在原地的形态。
    TopToast.show(context, msg);
  }

  /// 输入栏：**一个卡片装下全部**（文本区 + 操作行）。
  ///
  /// 上一版是"胶囊输入框 + 三个独立圆形按钮"横向并排。在 360dp 宽的手机上留给
  /// 输入框的只有 170px（约 12 个汉字就满），而且三个圆圈加一个胶囊并列，视觉上
  /// 很碎。改成卡片式后横向只剩一个容器：文本在上、操作在下，输入区反而更宽，
  /// 操作区也不再和文字抢横向空间。
  ///
  /// 操作行的顺序按使用频率从右往左递减：发送最右（拇指最容易够到），
  /// 然后语音、模型、添加。
  /// 会话洞察的会话键（去掉 `session-` 前缀，读写两侧用同一个形态）。
  String _ackKey(DshService dsh) {
    final sid = dsh.currentSession?.sessionId ?? '';
    return sid.replaceFirst('session-', '');
  }

  /// 有"还没被看过"的新产出 → 状态条那一段用强调色。
  ///
  /// 未知（`deliverableCount == null`，还没拉到）不算未读：不能因为"不知道"
  /// 就把用户的注意力吸走。
  bool _deliverablesUnread(DshService dsh) {
    final total = dsh.deliverableCount;
    if (total == null || total == 0) return false;
    final acked = _deliverablesAck[_ackKey(dsh)];
    return acked == null || total > acked;
  }

  /// 还在跑的后台作业数。
  ///
  /// 网关降级（读不到作业列表）时返回 null —— 状态条据此**隐藏**这一段，而不是
  /// 显示"0 个作业"（那会被读成"没有作业在跑"）。
  int? _liveJobCount(DshService dsh) {
    if (dsh.jobsDegraded.isNotEmpty) return null;
    return dsh.jobs.where((j) => j.isLive).length;
  }

  /// 打开会话信息面板（弹层实现见 `chat_sheets.dart` 的 `showChatSessionInfoSheet`）。
  ///
  /// 这里只负责把「看过产出」记下来 —— 其余（第三档懒加载、面板订阅）都在弹层里。
  Future<void> _openSessionInfo(
    DshService dsh, {
    SessionInsightSection section = SessionInsightSection.usage,
  }) {
    _deliverablesAck[_ackKey(dsh)] = dsh.deliverableCount ?? 0;
    if (mounted) setState(() {});
    return showChatSessionInfoSheet(
      context,
      section: section,
      deliverableBusy: _deliverableBusy,
      openDeliverable: (d, item) => _openDeliverable(d, item),
      // [fix 2026-10-17] 面板不再有「会话操作」分区（工作区里都能点，且这里要
      // 多两步），所以 workspaceLabel 与旧的 onOpenTrajectory 出口都不再需要：
      // 轨迹是本面板的 tab。
      //
      // 信息面板里的「轨迹」tab 用同一条跳转路径（与搜索、刻度跳转完全一致）。
      onJumpToMessage: (id, index, total) =>
          _highlightAndScrollToMessage(id, index: index, total: total),
    );
  }

  /// 就地预览一个交付物 —— 产出卡片主点击用的就是它。
  ///
  /// 和信息面板走的是**同一个** `showDeliverablePreview`：三个入口（卡片、正文
  /// 链接、面板）共用一份实现与一套手势，所以不存在"同一个文件在三处行为不同"。
  Future<void> _previewDeliverable(DshService dsh, DeliverableItem item) async {
    if (!mounted) return;
    await showDeliverablePreview(
      context,
      item: item,
      loader: () => dsh.fetchDeliverableText(item.path),
      onDownload: () => _openDeliverable(dsh, item),
    );
  }

  /// 消息正文里点了一个链接。
  ///
  /// 分三类，且**只有两类能开**：产物链接（本 App 自己插的 `dsh-file:`）与
  /// http(s) 链接。其余的给一句说明而不是静默失败 —— "点了没反应"和"这个链接
  /// 打不开"是两件不同的事，用户至少该知道该换个办法。
  Future<void> _openMessageLink(DshService dsh, String? href) async {
    if (href == null || href.isEmpty) return;

    // 1. 产物链接。解码出的绝对路径仍要在清单里复核一次：这条消息渲染之后清单
    //    可能已经刷新过（切了会话、重新拉了 REST），拿旧路径去请求只会得到 403。
    final refPath = decodeDshFileHref(href);
    final item = matchDeliverableByRef(dsh.deliverables, refPath ?? href);
    if (item != null) {
      await _previewDeliverable(dsh, item);
      return;
    }
    if (refPath != null) {
      _showLinkNotice('这个产物已经不在当前会话的清单里了');
      return;
    }

    // 2. 普通网页链接。
    final scheme = Uri.tryParse(href)?.scheme.toLowerCase() ?? '';
    if (scheme == 'http' || scheme == 'https') {
      final opened = await UrlOpener.open(href);
      if (!opened) _showLinkNotice('没有可用的浏览器打开这个链接');
      return;
    }

    _showLinkNotice('这个链接不是本会话的产物，App 打不开');
  }

  void _showLinkNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(milliseconds: 1600),
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// 下载交付物并交给系统打开；失败说明**内联**在卡片/面板里。
  ///
  /// 这是行上的**第二动作**（长按），不是主点击：主点击是预览。`item.path` 必须
  /// 是 REST 返回的绝对路径（下载路由按绝对路径做成员判定）。
  Future<void> _openDeliverable(DshService dsh, DeliverableItem item) async {
    if (_deliverableBusy.value != null) return; // 防重复点
    setState(() {
      _deliverableError = null;
      _deliverableBusy.value = item.path;
    });
    final err = await dsh.openDeliverable(item);
    if (!mounted) return;
    setState(() {
      _deliverableBusy.value = null;
      _deliverableError = err.isEmpty ? null : err;
    });
  }

  void _onNoticeAction(DshService dsh, ComposerNotice notice) {
    switch (notice.action) {
      case NoticeAction.undoQueue:
        final id = notice.undoItemId;
        final steered = _lastSteered;
        _clearNotice();
        if (id == null) break;
        if (steered != null && steered.id == id) {
          // ---- 「撤回插队」的降级实现（v1.27）----
          //
          // 网关**没有** unsteer：`queueAction` 只是把 `action.kind` 透传给网关，
          // 已知可用的 kind 只有 edit / remove / steer（全仓 grep
          // "unsteer|requeue" = 0）。而且被 steer 的条目已被引擎当场领走，
          // 队列里再没有它 —— remove / edit 都无从下手。
          //
          // 所以唯一的诚实做法是：**把这句话原样放回输入框**，让用户自己决定
          // 要不要再发一次。三处与"真撤销"的不等价，别对外说成"已撤销":
          //   1) 引擎可能**已经执行过**那条 steer（它插进的是"最近的步骤"），
          //      放回输入框不代表那条指令没有生效；
          //   2) 不重新投递、也不进队列 —— 用户必须自己再点发送；
          //   3) 回执 3 秒后消失，`_lastSteered` 并不清空（清空没意义），
          //      所以别把它当"还能撤销"的依据。
          //
          // [fix 2026-10-17] 补草稿保护（与 _resendMessage 同一套标准）：
          // 用户点撤回时可能正在写新草稿 —— 悄悄替换掉比"撤回不彻底"更糟。
          // 有草稿时改走追加，既保住新草稿也不丢插队内容。
          if (_inputController.text.trim().isNotEmpty) {
            final merged = '${_inputController.text.trimRight()}\n${steered.text}';
            _inputController.value = TextEditingValue(
              text: merged,
              selection: TextSelection.collapsed(offset: merged.length),
            );
            dsh.updateDraft(merged);
            _toast('输入框里已有内容，插队文本已追加在后面（不会自动重发）');
          } else {
            _inputController.text = steered.text;
            _inputController.selection =
                TextSelection.collapsed(offset: _inputController.text.length);
            dsh.updateDraft(_inputController.text);
            _toast('网关不支持撤销插队，已把这句话放回输入框（不会自动重发）');
          }
          break;
        }
        unawaited(_removeQueued(dsh, id, appliedText: '已撤回'));
        break;
      case NoticeAction.retrySend:
        _clearNotice();
        _sendMessage(dsh);
        break;
      case NoticeAction.none:
        break;
    }
  }

  /// 排队消息面板（v1.13；v1.14 改交互）。
  ///
  /// 两个动作（编辑 / 删除）+ 插话入口，全部以服务端为准：每次动作后重新拉队列，
  /// 绝不本地乐观删除 —— 网关失败时条目仍在队列里等待执行，界面上却把它抹掉，
  /// 用户会以为已经撤回了。
  ///
  /// 「立即插话」的位置是这一版的关键：它**只在队列条目上**，不在发送前。发送前
  /// 要提供插话就只能靠一枚提前预设的开关（因为按下之前没有别的办法表达"我要插话"），
  /// 而那正是"用户忘了开关停在哪"的根源。消息先排队、用户看见它排在队列里、
  /// 再决定要不要让它插进去 —— 这是唯一顺序。
  void _settleQueueAction(
    DshService dsh,
    QueueActionOutcome outcome, {
    required String appliedText,
    required String failedText,
  }) {
    switch (outcome) {
      case QueueActionOutcome.applied:
        _showNotice(appliedText, duration: const Duration(seconds: 2));
        break;
      case QueueActionOutcome.alreadyGone:
        _showNotice('这条已经发出去了', duration: const Duration(seconds: 2));
        break;
      case QueueActionOutcome.failed:
        _showNotice(dsh.queueError.isEmpty ? failedText : dsh.queueError,
            ok: false);
        break;
    }
  }

  Future<void> _removeQueueRow(DshService dsh, QueueItem row) async {
    HapticFeedback.selectionClick();
    await _removeQueued(dsh, row.id, appliedText: '已删除');
  }

  /// 按 id 删除一条排队消息（删除按钮与回执条的「撤回」共用）。
  Future<void> _removeQueued(DshService dsh, String itemId,
      {required String appliedText}) async {
    final outcome = await dsh.queueAction(itemId, 'remove');
    if (!mounted) return;
    _settleQueueAction(dsh, outcome,
        appliedText: appliedText, failedText: '删除失败');
  }

  /// 「立即插话」（v1.27）：**点一下就插**，随后给 3 秒可撤回的回执。
  ///
  /// 为什么改掉"两次点击确认"：那个交互要用户先看一眼按钮文字变成「确认插话？」、
  /// 再点第二次，而 2.5 秒的窗口一过又悄悄还原 —— 时间压力 + 状态不可见，实测
  /// 只会让人反复试。现在把安全网换到**事后**：立即执行，回执条上直接给「撤回」。
  ///
  /// 撤回的语义见 `_onNoticeAction` 里那段注释 —— 网关没有 unsteer，所谓"撤回"
  /// 是把正文放回输入框，不是把已经插进回合的指令拿回来。
  Future<void> _steerQueueRow(DshService dsh, QueueItem row) async {
    HapticFeedback.mediumImpact();
    final outcome = await dsh.queueAction(row.id, 'steer');
    if (!mounted) return;
    switch (outcome) {
      case QueueActionOutcome.applied:
        // 记下这一条：插队成功后它已被引擎领走，队列里再没有它，回执上的
        // itemId 本身还原不出正文。
        _lastSteered = row;
        _showNotice(
          '已插队到当前步骤',
          action: NoticeAction.undoQueue,
          undoItemId: row.id,
          duration: const Duration(seconds: 3),
        );
        break;
      case QueueActionOutcome.alreadyGone:
        // 正常时序（点的同时这一轮刚好把它领走），不报红错。
        _showNotice('这条已经发出去了', duration: const Duration(seconds: 2));
        break;
      case QueueActionOutcome.failed:
        _showNotice(dsh.queueError.isEmpty ? '插话失败' : dsh.queueError,
            ok: false);
        break;
    }
  }

  Future<void> _editQueueRow(DshService dsh, QueueItem row) async {
    final controller = TextEditingController(text: row.text);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑排队消息'),
        content: TextField(
          controller: controller,
          minLines: 2,
          maxLines: 5,
          autofocus: true,
          decoration: const InputDecoration(hintText: '只能编辑文字内容'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (next == null || !mounted) return;
    if (next.trim().isEmpty) {
      _toast('内容不能为空');
      return;
    }
    final outcome = await dsh.queueAction(row.id, 'edit', text: next);
    if (!mounted) return;
    _settleQueueAction(dsh, outcome, appliedText: '已保存', failedText: '保存失败');
  }
}
