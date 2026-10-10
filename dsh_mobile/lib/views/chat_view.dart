import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/chat_message.dart';
import '../models/dsh_settings.dart';
import '../services/dsh_service.dart';
import '../widgets/thinking_card.dart';
import '../widgets/tool_call_card.dart';
import '../widgets/approval_card.dart';
import '../widgets/memory_card.dart';
import '../widgets/safe_markdown.dart';
import 'widgets/question_card.dart';
import 'widgets/attachment_tile.dart';
import 'widgets/message_search.dart';
import 'widgets/message_search_panel.dart';
import 'widgets/session_status_strip.dart';
import 'widgets/session_info_sheet.dart';
import 'widgets/turn_output_card.dart';
import 'config_page.dart';
import '../theme/app_colors.dart';
import '../main.dart';
import '../services/voice_input_service.dart';
import '../services/platform_services.dart';
import '../models/pending_attachment.dart';
import '../models/task_center.dart';
import '../services/attachment_picker.dart';

/// 长按说话的三个状态（v1.12.0）。
enum _HoldTalkPhase {
  /// 平时：点按打字，长按开始说话。
  idle,

  /// 正在录音：整块输入区换成"正在聆听"，松手结束。
  recording,

  /// 已识别、等确认：文本在输入框里（可改），下方是「重录 / 发送」。
  confirm,
}

/// 输入卡片上方那条提示上附带的动作。
///
/// 只有"安全方向"的动作才在这里：撤回刚排进去的那条（一次点击即撤，不需要
/// 二次确认 —— 撤回是往回收，多余的一次确认只会让人撤回不掉）、以及失败后重试。
enum _NoticeAction {
  none,

  /// 「撤回」：把刚排队的那一条从队列里删掉。需要该提示的 `undoItemId`。
  undoQueue,

  /// 「重试」：正文已经被放回输入框，重试即再发一次。
  retrySend,
}

/// 输入卡片上方的一条提示（v1.14）。
///
/// 排队回执 / 插话结果 / 失败回滚说明共用这一处：它们表达的永远是同一件事
/// ——"刚才那次投递发生了什么"，同一时刻只可能有一件。放在输入卡片**顶部**
/// 而不是 SnackBar：失败时用户写的内容还在输入框里，提示必须和它挨着。
class _ComposerNotice {
  final String text;
  final bool ok;
  final _NoticeAction action;
  final String? undoItemId;

  const _ComposerNotice({
    required this.text,
    this.ok = true,
    this.action = _NoticeAction.none,
    this.undoItemId,
  });
}

class ChatView extends StatefulWidget {
  final VoidCallback? onOpenWorkspaces;
  final VoidCallback? onOpenSecurity;

  const ChatView({
    super.key,
    this.onOpenWorkspaces,
    this.onOpenSecurity,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  String? _lastSessionId;
  bool _showScrollToBottom = false;
  int _lastMessageCount = 0;
  bool _wasLoadingHistory = false;

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

  /// 当前被高亮的命中消息 id。高亮只保留一条 —— 一次跳到第一条就够用户确认
  /// "查找能用了"，剩下的自己点；全部高亮反而让页面变成一片黄。
  final Set<String> _highlightedMessageIds = {};

  // ---- 离线草稿 (v1.4.2) ----

  // ---- 语音输入 (v1.8.0) ----
  // null = 尚未探测；探测结果决定按钮是可用还是禁用。
  bool? _voiceSupported;
  bool _voiceListening = false;

  // ---- 长按说话 (v1.12.0) ----
  //
  // 交互：**长按输入框**开始说话 → **松开**停止并把识别文本填进输入框 →
  // 出现「重录 / 发送」两个按钮等你确认。**点按输入框**仍是原来的打字。
  // 为什么要有"确认"这一步：语音识别在嘈杂环境/口音下会出错，直接发出去的
  // 代价是 agent 立刻按错误指令动手（可能是删除或部署）。多一次确认，
  // 用户有机会看一眼、改一下。
  _HoldTalkPhase _holdPhase = _HoldTalkPhase.idle;
  /// 识别中的当前文本（累积的，整段替换 —— 见 VoiceInputService.start 的注释）。
  String _holdText = '';
  DateTime? _holdStartedAt;
  Timer? _holdTick;
  /// 松手后的收尾保护：stop() 之后 onFinal 可能还会到，用来把最终文本补进输入框。
  bool _holdAwaitingFinal = false;
  /// 录音态兜底超时：语音服务挂死（listen 超时、平台不回调）时 _holdPhase
  /// 会卡在 recording，手势层吞掉一切点击 —— 表现为"输入框点不动"。
  /// 30s 强制回 idle；正常说话远短于这个上限，到点即视为异常。
  Timer? _holdWatchdog;

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
  late final ValueNotifier<_ComposerNotice?> _notice = ValueNotifier(null);
  Timer? _noticeTimer;

  /// 已武装（等第二次点击确认）的队列条目 id。非空 = 该行按钮显示「确认插话？」。
  String? _armedSteerItemId;
  Timer? _steerArmTimer;

  /// 「立即插话」的第二次点击等待时长。
  ///
  /// 2.5 秒：够完成"看一眼按钮变了、再点一次"的确认动作，又短到不会一直挂着
  /// 一个危险状态。超时自动还原，不产生任何副作用。
  static const Duration _steerConfirmWindow = Duration(milliseconds: 2500);

  void _showNotice(
    String text, {
    bool ok = true,
    _NoticeAction action = _NoticeAction.none,
    String? undoItemId,
    Duration duration = const Duration(seconds: 5),
  }) {
    _noticeTimer?.cancel();
    _notice.value = _ComposerNotice(
      text: text,
      ok: ok,
      action: action,
      undoItemId: undoItemId,
    );
    _noticeTimer = Timer(duration, () {
      if (mounted) _notice.value = null;
    });
  }

  void _clearNotice() {
    _noticeTimer?.cancel();
    _noticeTimer = null;
    _notice.value = null;
  }

  /// 退出"待确认插话"状态（超时、点了别处、或已真正执行）。
  void _disarmSteer() {
    _steerArmTimer?.cancel();
    _steerArmTimer = null;
    if (_armedSteerItemId != null) {
      setState(() => _armedSteerItemId = null);
    }
  }

  /// 测试用：直接挂一个附件，绕开原生选择器（单测里调不起来）。
  @visibleForTesting
  void debugAddPendingAttachment(PendingAttachment attachment) {
    setState(() => _pendingAttachments.add(attachment));
  }

  /// 测试用：读取输入卡片上方那条提示的文案（没有提示时为 null）。
  @visibleForTesting
  String? get debugNoticeText => _notice.value?.text;

  /// 测试用：当前处于"待确认插话"的条目 id。
  @visibleForTesting
  String? get debugArmedSteerItemId => _armedSteerItemId;

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
    final msg = hit.messageIndex < dsh.messages.length ? dsh.messages[hit.messageIndex] : null;
    if (msg == null) return;
    setState(() {
      _highlightedMessageIds
        ..clear()
        ..add(msg.id);
    });
    final key = _messageKeys[msg.id];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.28,
      );
    }
    // 高亮会淡出，所以不必永久留在 _highlightedMessageIds 里。
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightedMessageIds.remove(msg.id));
    });
  }

  GlobalKey _keyForMessage(String id) => _messageKeys.putIfAbsent(id, () => GlobalKey());

  // Keyboard & viewport avoidance state
  double _lastBottomInset = 0.0;
  bool _wasNearBottomBeforeKeyboard = true;

  // User interaction & streaming auto-scroll state
  bool _userScrolledUp = false;
  bool _isUserInteracting = false;
  bool _isAutoScrollScheduled = false;
  int _lastStreamRevision = 0;
  int _lastStreamContentLength = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _inputFocusNode.addListener(_onInputFocusChange);

    // 探测语音识别能力（含麦克风权限）。放在 initState 而不是 build：这是
    // 一次性异步探测，挂在 build 上会每次重建都重跑一遍。
    //
    // 刻意**不阻塞界面**：探测慢或失败都不该挡住聊天，失败时按钮显示为禁用。
    VoiceInputService.instance.init().then((ok) {
      if (mounted) setState(() => _voiceSupported = ok);
    });

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
      _inputController.text = cur.isEmpty ? shared.text : '$cur\n${shared.text}';
      setState(() {});
      _jumpToBottom();
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
      final name = shared.imageName.isNotEmpty ? shared.imageName : file.uri.pathSegments.last;
      final media = PickedMedia(
        bytes: bytes,
        name: name.toLowerCase().endsWith('.jpg') || name.toLowerCase().endsWith('.jpeg')
            ? name
            : '$name.jpg',
        mimeType: 'image/jpeg',
      );
      final pending = _prepareImageAttachment(media);
      if (!mounted) return;
      setState(() => _pendingAttachments.add(pending));
      _toast('已从分享挂上 1 张图片');
      _jumpToBottom();
    } on AttachmentError catch (e) {
      if (mounted) _toast(e.message);
    } catch (e) {
      if (mounted) _toast('分享的图片挂载失败: $e');
    }
  }

  @override
  void dispose() {
    _inputFocusNode.removeListener(_onInputFocusChange);
    _scrollController.removeListener(_onScroll);
    _holdTick?.cancel();
    _holdWatchdog?.cancel();
    _noticeTimer?.cancel();
    _steerArmTimer?.cancel();
    _notice.dispose();
    _deliverableBusy.dispose();
    // 正在录音时被销毁（切会话/返回）：必须主动取消识别，否则麦克风会被一直
    // 占着，下一次识别会以"被其他应用占用"失败。
    if (_holdPhase != _HoldTalkPhase.idle) {
      VoiceInputService.instance.cancel();
    }
    _inputFocusNode.dispose();
    _inputController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onInputFocusChange() {
    if (_inputFocusNode.hasFocus && !_userScrolledUp) {
      _scrollToBottom();
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentOffset = _scrollController.offset;
    final distFromBottom = maxScroll - currentOffset;
    final show = distFromBottom > 160;
    if (show != _showScrollToBottom) {
      setState(() {
        _showScrollToBottom = show;
      });
    }
    if (distFromBottom < 40 && _userScrolledUp) {
      _userScrolledUp = false;
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
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
    return false;
  }

  void _jumpToBottom() {
    _userScrolledUp = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _scrollToBottom({Duration duration = const Duration(milliseconds: 300), Curve curve = Curves.easeOutCubic}) {
    _userScrolledUp = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: duration,
          curve: curve,
        );
      }
    });
  }

  void _scheduleAutoScroll() {
    if (_isAutoScrollScheduled) return;
    _isAutoScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isAutoScrollScheduled = false;
      if (!mounted) return;
      if (_userScrolledUp || _isUserInteracting) return;
      if (!_scrollController.hasClients) return;

      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentOffset = _scrollController.offset;
      final diff = maxScroll - currentOffset;

      if (diff > 0) {
        if (diff > 250) {
          _scrollController.animateTo(
            maxScroll,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
          );
        } else {
          _scrollController.jumpTo(maxScroll);
        }
      }
    });
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
            textColor: const Color(0xFF60A5FA),
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
    _scrollToBottom();
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
      final added = dsh.queueItems.where((q) => !before.contains(q.id)).toList();
      _showNotice(
        '已排队 · 本轮结束后自动发送',
        action: added.isEmpty ? _NoticeAction.none : _NoticeAction.undoQueue,
        undoItemId: added.isEmpty ? null : added.last.id,
      );
      _scrollToBottom();
      return;
    }
    _inputController.text = text;
    _inputController.selection = TextSelection.collapsed(offset: text.length);
    setState(() => _pendingAttachments
      ..clear()
      ..addAll(attachments));
    _showNotice('排队失败，内容已放回输入框', ok: false, action: _NoticeAction.retrySend);
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
        final receiptId = await dsh.uploadAttachment(name: media.name, bytes: media.bytes);
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
  Future<void> _showAttachSheet(DshService dsh) async {
    if (!dsh.isConnected) {
      _toast('网络已断开，请先重试连接');
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.image_outlined, color: context.c.accent),
              title: Text('图片', style: TextStyle(color: context.c.textPrimary, fontSize: 14)),
              subtitle: Text('自动压缩到 1600px，agent 能直接看到',
                  style: TextStyle(color: context.c.textTertiary, fontSize: 11.5)),
              onTap: () => Navigator.pop(ctx, 'image'),
            ),
            ListTile(
              leading: Icon(Icons.attach_file_rounded, color: context.c.accent),
              title: Text('文件', style: TextStyle(color: context.c.textPrimary, fontSize: 14)),
              subtitle: Text('任意文件，上限 32MB',
                  style: TextStyle(color: context.c.textTertiary, fontSize: 11.5)),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await _attach(dsh, asFile: choice == 'file');
  }


  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return DateFormat('HH:mm').format(dt);
    }
    return DateFormat('MM-dd HH:mm').format(dt);
  }

  // Session Permission Dialog / BottomSheet
  void _showSessionPermissionSheet(BuildContext context, DshService dsh) {
    final currentSession = dsh.currentSession;
    final sessionId = currentSession?.sessionId ?? 'default';
    final currentPolicy = dsh.getSessionPermission(sessionId);
    String selectedPolicy = currentPolicy;
    // NOTE: `dsh.permissions.sandboxMode` used to be read into a local here and
    // then never rendered — the session sheet only ever let the user pick an
    // execution policy. Surfacing sandboxMode/maxSteps in this sheet is a real
    // UI gap (tracked in ANALYSIS-优化与新增功能.md §1.13), not something to
    // silently reintroduce as another dead local.
    int maxSteps = dsh.permissions.maxSteps;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: context.c.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: context.c.accent.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: context.c.accent.withOpacity(0.2)),
                          ),
                          child: Icon(Icons.shield_outlined, color: context.c.accent, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '对话权限与执行策略',
                                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                              ),
                              Text(
                                '当前对话: ${currentSession?.title ?? sessionId}',
                                style: TextStyle(fontSize: 12, color: context.c.textSecondary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '终端命令执行策略 (Execution Policy)',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                    ),
                    const SizedBox(height: 10),

                    // Policy Option: Ask
                    _buildPolicyOption(
                      title: '🛡️ 每次询问 (Ask Every Time)',
                      subtitle: '最安全。任何 Shell / 脚本执行都需在手机端审批确认',
                      value: 'ask',
                      groupValue: selectedPolicy,
                      onChanged: (val) {
                        setModalState(() => selectedPolicy = val!);
                      },
                    ),

                    // Policy Option: Auto Read-Only
                    _buildPolicyOption(
                      title: '🔍 自动放行只读 (Auto Read-Only)',
                      subtitle: '推荐。ls, grep, cat, git status 等只读指令直接运行，写操作拦截确认',
                      value: 'auto-read',
                      groupValue: selectedPolicy,
                      onChanged: (val) {
                        setModalState(() => selectedPolicy = val!);
                      },
                    ),

                    // Policy Option: Danger Full Access
                    _buildPolicyOption(
                      title: '⚡ 完全信任模式 (Danger Full Access)',
                      subtitle: '全自动无阻塞运行。所有命令免审批执行，适合无人值守任务',
                      value: 'danger-full-access',
                      groupValue: selectedPolicy,
                      onChanged: (val) {
                        setModalState(() => selectedPolicy = val!);
                      },
                    ),

                    const SizedBox(height: 16),
                    Text(
                      '单轮迭代步数上限 (Max Steps)',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: maxSteps.toDouble(),
                            min: 10,
                            max: 60,
                            divisions: 10,
                            activeColor: context.c.accent,
                            label: '$maxSteps 步',
                            onChanged: (v) {
                              setModalState(() => maxSteps = v.round());
                            },
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: context.c.surfaceMuted,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: context.c.border),
                          ),
                          child: Text('$maxSteps 步', style: TextStyle(color: context.c.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: context.c.accent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          elevation: 0,
                        ),
                        onPressed: () async {
                          // 危险档（完全信任）二次确认：与安全页的危险预设保持
                          // 一致。它会让本会话的工具调用**全部免审批**，而这在
                          // 聊天流里只是一次点击的距离 —— 值得多问一句。
                          if (selectedPolicy == 'danger-full-access') {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                backgroundColor: context.c.surface,
                                title: Row(
                                  children: [
                                    Icon(Icons.warning_amber_rounded, color: context.c.danger, size: 22),
                                    const SizedBox(width: 8),
                                    Text('确认开启完全信任？', style: TextStyle(color: context.c.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                                content: Text(
                                  '本会话后续的工具调用将不再逐条请求你的授权，包括删除文件、执行脚本等写操作。\n\n只在无人值守、且你清楚后果时使用。',
                                  style: TextStyle(color: context.c.textSecondary, fontSize: 13, height: 1.5),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: Text('取消', style: TextStyle(color: context.c.textSecondary)),
                                  ),
                                  FilledButton(
                                    style: FilledButton.styleFrom(backgroundColor: context.c.danger),
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('仍要开启', style: TextStyle(fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed != true || !context.mounted) return;
                          }
                          final currentSessions = Map<String, String>.from(dsh.permissions.sessionPolicies);
                          currentSessions[sessionId] = selectedPolicy;
                          final updatedPerms = dsh.permissions.copyWith(
                            sessionPolicies: currentSessions,
                            maxSteps: maxSteps,
                          );
                          if (context.mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('已更新会话权限策略: ${_getPolicyLabel(selectedPolicy)}'),
                                duration: const Duration(seconds: 2),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                          await dsh.updatePermissions(updatedPerms);
                        },
                        child: const Text('保存权限策略', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
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
  }

  Widget _buildPolicyOption({
    required String title,
    required String subtitle,
    required String value,
    required String groupValue,
    required ValueChanged<String?> onChanged,
  }) {
    final isSelected = value == groupValue;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? context.c.accent.withOpacity(0.08) : context.c.surface,
          border: Border.all(
            color: isSelected ? context.c.accent : context.c.border,
            width: isSelected ? 1.5 : 1.0,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Radio<String>(
              value: value,
              groupValue: groupValue,
              onChanged: onChanged,
              activeColor: context.c.accent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? context.c.accent : context.c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: context.c.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getPolicyLabel(String policy) {
    switch (policy) {
      case 'danger-full-access':
        return '⚡ 完全放行';
      case 'auto-read':
        return '🔍 只读放行';
      case 'ask':
      default:
        return '🛡️ 每次询问';
    }
  }

  Color _getPolicyColor(String policy) {
    switch (policy) {
      case 'danger-full-access':
        return context.c.success;
      case 'auto-read':
        return context.c.accent;
      case 'ask':
      default:
        return context.c.warning;
    }
  }

  // Quick Model Selector Sheet
  void _showModelSwitchSheet(BuildContext context, DshService dsh) {
    if (dsh.settings == null || dsh.settings!.availableModels.isEmpty) {
      dsh.fetchSettings();
    }
    final settings = dsh.settings;
    final currentSession = dsh.currentSession;
    final activeModel = dsh.currentModel;
    final modelList = (settings != null && settings.availableModels.isNotEmpty)
        ? settings.availableModels
        : [
            ModelItem(id: 'cn:deepseek-v4.1-flash', name: 'DeepSeek V4.1 Flash', contextWindow: 1000000, maxTokens: 16384),
            ModelItem(id: 'cn:deepseek-v4-pro', name: 'DeepSeek V4 Pro', contextWindow: 1000000, maxTokens: 32768),
            ModelItem(id: 'cn:kimi-k3-1', name: 'Kimi K3.1', contextWindow: 1000000, maxTokens: 32768),
          ];

    String filter = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: context.c.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: context.c.accent.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.smart_toy_outlined, color: context.c.accent, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '切换大语言模型',
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                          ),
                          Text(
                            '选择要在此会话中使用的 AI 模型',
                            style: TextStyle(fontSize: 12, color: context.c.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (currentSession != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: context.c.surfaceMuted,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '当前生效会话: ${currentSession.title}',
                        style: TextStyle(fontSize: 12, color: context.c.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                StatefulBuilder(
                  builder: (context, setModalState) {
                    final filtered = modelList.where((m) {
                      if (filter.isEmpty) return true;
                      return m.name.toLowerCase().contains(filter) || m.id.toLowerCase().contains(filter);
                    }).toList();

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                          decoration: InputDecoration(
                            hintText: '搜索模型 (如 deepseek, glm, gpt, qwen...)',
                            hintStyle: TextStyle(fontSize: 13, color: context.c.textTertiary),
                            prefixIcon: Icon(Icons.search, size: 20, color: context.c.textSecondary),
                            filled: true,
                            fillColor: context.c.surfaceMuted,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          onChanged: (val) {
                            setModalState(() {
                              filter = val.trim().toLowerCase();
                            });
                          },
                        ),
                        const SizedBox(height: 10),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
                          child: filtered.isEmpty
                              ? Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 24),
                                  child: Center(
                                    child: Text('未找到匹配的模型', style: TextStyle(color: context.c.textTertiary)),
                                  ),
                                )
                              : ListView.separated(
                                  shrinkWrap: true,
                                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                                  itemCount: filtered.length,
                                  itemBuilder: (context, index) {
                                    final m = filtered[index];
                      final isSelected = m.id == activeModel || (m.id.replaceFirst('cn:', '') == activeModel.replaceFirst('cn:', ''));
                      return InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () async {
                          Navigator.pop(ctx);
                          HapticFeedback.selectionClick();
                          final ok = await dsh.switchModel(m.id, sessionId: currentSession?.sessionId);
                          if (context.mounted) {
                            if (ok) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('已成功切换模型为: ${m.name}'),
                                  backgroundColor: context.c.success,
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('模型切换失败: ${dsh.lastError.isNotEmpty ? dsh.lastError : "请检查网络或授权码"}'),
                                  backgroundColor: context.c.danger,
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: isSelected ? context.c.accent.withOpacity(0.08) : context.c.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected ? context.c.accent : context.c.border,
                              width: isSelected ? 1.5 : 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                                color: isSelected ? context.c.accent : context.c.textTertiary,
                                size: 18,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      m.name,
                                      style: TextStyle(
                                        color: isSelected ? context.c.accent : context.c.textPrimary,
                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${m.id} | 上下文: ${(m.contextWindow ?? 0) ~/ 1000}k',
                                      style: TextStyle(fontSize: 11.5, color: context.c.textSecondary),
                                    ),
                                  ],
                                ),
                              ),
                              if (isSelected)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: context.c.accent.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text('使用中', style: TextStyle(color: context.c.accent, fontSize: 11, fontWeight: FontWeight.w600)),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ],
            ),
          ),
        );
      },
    );
  }

  // Delete Current Session Dialog
  void _showDeleteCurrentSessionDialog(BuildContext context, DshService dsh) {
    final currentSession = dsh.currentSession;
    if (currentSession == null) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.c.border),
        ),
        title: Row(
          children: [
            Icon(Icons.delete_outline_rounded, color: context.c.danger, size: 22),
            const SizedBox(width: 8),
            Text('删除当前会话', style: TextStyle(color: context.c.textPrimary, fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '确定要删除会话「${currentSession.title}」吗？\n删除后该会话的历史记录和上下文将不可恢复。',
          style: TextStyle(color: context.c.textPrimary, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: context.c.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: context.c.danger,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              elevation: 0,
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              final ok = await dsh.deleteSession(
                currentSession.sessionId,
                dsh.currentWorkspace?.workspaceId,
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).clearSnackBars();
                if (ok) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('已删除会话: ${currentSession.title}'),
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('删除会话失败: ${dsh.lastError}'),
                      backgroundColor: context.c.danger,
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 3),
                    ),
                  );
                }
              }
            },
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
  }

  // Quick Workspace Switcher Sheet
  void _showWorkspaceSwitchSheet(BuildContext context, DshService dsh) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: context.c.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(Icons.folder_open_rounded, color: context.c.accent, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '选择工作区 (Select Workspace)',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: dsh.workspaces.length,
                    itemBuilder: (context, index) {
                      final ws = dsh.workspaces[index];
                      final isSelected = ws.workspaceId == dsh.currentWorkspace?.workspaceId;
                      return ListTile(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        tileColor: isSelected ? context.c.accent.withOpacity(0.08) : null,
                        title: Text(
                          ws.title,
                          style: TextStyle(
                            color: isSelected ? context.c.accent : context.c.textPrimary,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          ws.path,
                          style: TextStyle(fontSize: 11, color: context.c.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          '${ws.sessionCount} 会话',
                          style: TextStyle(color: context.c.textTertiary, fontSize: 12),
                        ),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          Navigator.pop(ctx);
                          dsh.selectWorkspace(ws);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 离线 / 正在重连状态横幅 (F3.4, F4.3)
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
                  border: Border.all(color: const Color(0xFFFCA5A5)),
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: isConnecting
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.0,
                      color: accentColor,
                    ),
                  )
                : Icon(
                    Icons.wifi_off_rounded,
                    size: 15,
                    color: accentColor,
                  ),
          ),
          const SizedBox(width: 10),

          // Status Information
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isConnecting ? '网络已断开，正在尝试重连...' : '网络连接已断开',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!isConnecting && dsh.lastError.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      dsh.lastError,
                      style: TextStyle(
                        color: textColor.withOpacity(0.85),
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
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
                  color: isConnecting ? context.c.warningBorder : const Color(0xFFFCA5A5),
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
    final isSessionRunning = (currentSession?.isRunning ?? false) ||
        (dsh.isSending && (currentSession?.matchesSessionId(dsh.currentSession?.sessionId) ?? false));
    final activeApprovals = dsh.pendingApprovals.where((a) {
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

    // Keyboard height transitions
    final currentBottomInset = MediaQuery.of(context).viewInsets.bottom;
    if (currentBottomInset != _lastBottomInset) {
      final isKeyboardOpening = currentBottomInset > _lastBottomInset;
      if (isKeyboardOpening && _lastBottomInset == 0) {
        _wasNearBottomBeforeKeyboard = !_userScrolledUp;
      }
      if (isKeyboardOpening && _wasNearBottomBeforeKeyboard && !_userScrolledUp) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients && !_userScrolledUp && !_isUserInteracting) {
            _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
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
      _userScrolledUp = false;
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
      // 2) **首次进入不能写**。`_lastSessionId` 从 null 变成首个会话时，输入框
      //    必然是空的，写进去等于把这个会话已存的草稿用空串清掉（`DraftStore.write`
      //    收到空串就是删除）。
      if (previousSessionId != null && previousSessionId != currentSessionId) {
        dsh.drafts.write(previousSessionId, _inputController.text);
      }
      final restored = dsh.currentDraft;
      _inputController.text = restored;
      _inputController.selection = TextSelection.collapsed(offset: restored.length);
      _jumpToBottom();
    } else if (_wasLoadingHistory && !dsh.isLoadingHistory) {
      _lastStreamRevision = dsh.streamRevision;
      _userScrolledUp = false;
      _jumpToBottom();
    } else if (dsh.messages.length != _lastMessageCount) {
      final wasNearBottom = !_userScrolledUp;
      _lastMessageCount = dsh.messages.length;
      _lastStreamRevision = dsh.streamRevision;
      if (wasNearBottom) {
        _scrollToBottom();
      }
    } else if (dsh.streamRevision != _lastStreamRevision || hasStreamContentGrowth) {
      _lastStreamRevision = dsh.streamRevision;
      if (!_userScrolledUp && !_isUserInteracting) {
        _scheduleAutoScroll();
      }
    }
    _wasLoadingHistory = dsh.isLoadingHistory;

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
      _outputCardAnchorIndex = dsh.messages.isEmpty ? -1 : dsh.messages.length - 1;
    }
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
      appBar: AppBar(
        backgroundColor: context.c.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        // 顶部那两行（1px 分隔线）整体换成会话状态条（v1.14）。
        //
        // 它自己实现 `PreferredSizeWidget`，所以高度由它内部算：有内容 34dp、
        // 什么都不显示时只留那条 1px 分隔线 —— 不需要这里手工算高度，也就不会
        // 出现"顶部留了一条空白带"这种布局残留。
        //
        // 为什么状态放**顶部**而不是输入框上方：键盘弹起时输入框上方那块空间被
        // 压到最紧，而这里不参与压缩，打字时"执行中 / 产出 / 上下文"依然可读。
        bottom: SessionStatusStrip(
          isRunning: isSessionRunning,
          deliverableCount: dsh.deliverableCount,
          deliverablesUnread: _deliverablesUnread(dsh),
          changeCount: dsh.changeCount,
          changesUnavailable: dsh.changesUnavailable,
          contextFraction: dsh.sessionStats?.contextFraction,
          contextIsSnapshot: dsh.sessionStats?.isSnapshot ?? false,
          liveJobCount: _liveJobCount(dsh),
          onTapSection: (section) => _openSessionInfo(dsh, section: section),
        ),
        titleSpacing: 12,
        // 会话标题 + 它所属的工作区（两行）。
        //
        // 为什么需要工作区这一行：不同工作区可以有**同名会话**，而从通知/深链接/
        // 搜索结果跳进来时（`openSessionById`），界面上原本完全看不出这是哪个工作区
        // 的会话。放在顶栏标题的第二行而不是状态条里 —— 状态条回答的是"现在在干
        // 什么"（产出/改动/上下文），工作区回答的是"这个会话在哪"，混在一起会把
        // "点某一段展开对应信息"的语义弄浑。
        //
        // 工作区判定不出来时**整行隐藏**（见 `workspaceOfCurrentSession`）：
        // 那一行宁可没有，也不能显示一个可能是"隔壁工作区"的名字。
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                // 当前权限状态色点。它原本是顶栏那个盾牌按钮的一部分；盾牌移进
                // 「更多」菜单后，用这个 7px 的点保住「当前是什么权限」的一眼信息，
                // 否则用户必须打开菜单才知道。
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 5),
                  decoration: BoxDecoration(color: _getPolicyColor(policy), shape: BoxShape.circle),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    currentSession?.title ?? '新会话',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: context.c.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isSessionRunning) ...[
                  const SizedBox(width: 6),
                  Container(
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
                          width: 8,
                          height: 8,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: context.c.accent),
                        ),
                        const SizedBox(width: 4),
                        Text('执行中', style: TextStyle(color: context.c.accent, fontSize: 9.5, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            if (workspaceTitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 1.5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_outlined, size: 10.5, color: context.c.textTertiary),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        workspaceTitle,
                        style: TextStyle(fontSize: 10.5, color: context.c.textTertiary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        // 顶栏只保留 3 个高频按钮（新建 / 查找 / 更多）。
        //
        // 原先有 5 个：权限、新建、主题、查找、更多。再叠加两行标题（句柄选择 +
        // 模型胶囊 / 会话名 + 执行中徽标），在 360dp 宽的手机上必然挤成一团。
        // 而且其中两个功能本来就是重复的 ——「对话权限」在「更多」菜单里已有
        // 同名项，「切换模型」既在标题的胶囊上、又在菜单里。
        //
        // 处理：权限与主题移进「更多」菜单；权限状态改用会话名旁边的一个小色点
        // 表示，这样「当前是什么权限」这个一眼信息没有丢。
        actions: [
          // New Session Button
          IconButton(
            tooltip: '新建对话',
            icon: Icon(Icons.add_comment_outlined, color: context.c.textPrimary, size: 22),
            onPressed: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('正在新建对话...'),
                  duration: Duration(milliseconds: 1000),
                  behavior: SnackBarBehavior.floating,
                ),
              );
              await dsh.createNewSession();
              _scrollToBottom();
            },
          ),

          // 会话内查找
          IconButton(
            tooltip: '在当前会话中查找',
            icon: Icon(
              _searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
              color: _searchOpen ? context.c.accent : context.c.textPrimary,
              size: 22,
            ),
            onPressed: _toggleSearch,
          ),

          // More Options Popup Menu
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded, color: context.c.textPrimary),
            color: context.c.surface,
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: context.c.border),
            ),
            onSelected: (value) {
              switch (value) {
                case 'model':
                  _showModelSwitchSheet(context, dsh);
                  break;
                case 'permission':
                  _showSessionPermissionSheet(context, dsh);
                  break;
                case 'theme':
                  // 从顶栏移进菜单后，必须回显切换结果 —— 原先按钮的颜色/图标
                  // 本身就是反馈，菜单项点击后菜单就关了，不给提示会让人不确定。
                  final theme = context.read<ThemeController>();
                  theme.cycle();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('主题：${theme.label}'),
                      duration: const Duration(seconds: 1),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                  break;
                case 'switchWorkspace':
                  // 顶栏那个工作区胶囊被去掉后（它占了约 156px，而 AppBar 只有
                  // 188px 可用），这里必须保留同一个能力 —— 否则用户就没法在
                  // 对话过程中切换工作区了。只是把入口从"常驻胶囊"换成"菜单项"。
                  _showWorkspaceSwitchSheet(context, dsh);
                  break;
                case 'workspaces':
                  widget.onOpenWorkspaces?.call();
                  break;
                case 'clear':
                  dsh.createNewSession();
                  break;
                case 'delete':
                  _showDeleteCurrentSessionDialog(context, dsh);
                  break;
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'model',
                child: Row(
                  children: [
                    Icon(Icons.smart_toy_outlined, color: context.c.accent, size: 18),
                    const SizedBox(width: 10),
                    Text('切换模型', style: TextStyle(color: context.c.textPrimary, fontSize: 13)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'permission',
                child: Row(
                  children: [
                    Icon(Icons.shield_outlined, color: context.c.accent, size: 18),
                    const SizedBox(width: 10),
                    Text('对话权限', style: TextStyle(color: context.c.textPrimary, fontSize: 13)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'switchWorkspace',
                child: Row(
                  children: [
                    Icon(Icons.swap_horiz_rounded, color: context.c.accent, size: 18),
                    const SizedBox(width: 10),
                    Text('切换工作区', style: TextStyle(color: context.c.textPrimary, fontSize: 13)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'workspaces',
                child: Row(
                  children: [
                    Icon(Icons.folder_outlined, color: context.c.accent, size: 18),
                    const SizedBox(width: 10),
                    Text('工作区与会话', style: TextStyle(color: context.c.textPrimary, fontSize: 13)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'theme',
                child: Row(
                  children: [
                    Icon(Icons.brightness_6_outlined, color: context.c.accent, size: 18),
                    const SizedBox(width: 10),
                    Text('切换主题', style: TextStyle(color: context.c.textPrimary, fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline_rounded, color: context.c.danger, size: 18),
                    const SizedBox(width: 10),
                    Text('删除当前会话', style: TextStyle(color: context.c.danger, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
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
                border: Border.all(color: const Color(0xFFFCA5A5)),
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
          if (otherSessionQuestionCount(dsh) > 0)
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
                      '其他会话有 ${otherSessionQuestionCount(dsh)} 个提问在等你回答',
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
          if (dsh.pendingApprovals.isNotEmpty)
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
                          activeApprovals.isNotEmpty
                              ? '当前会话有 ${activeApprovals.length} 个工具操作等待授权'
                              : '其他会话有 ${dsh.pendingApprovals.length} 个工具操作等待授权',
                          style: TextStyle(
                            color: context.c.warning,
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (activeApprovals.isNotEmpty)
                          Text(
                            '工具: ${activeApprovals.first.toolName}',
                            style: TextStyle(color: context.c.warning, fontSize: 11),
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
                    onPressed: activeApprovals.isNotEmpty
                        ? _scrollToBottom
                        : () => _jumpToApprovalSession(dsh),
                    icon: Icon(
                      activeApprovals.isNotEmpty ? Icons.arrow_downward_rounded : Icons.shield_rounded,
                      size: 14,
                      color: context.c.warning,
                    ),
                    label: Text(
                      activeApprovals.isNotEmpty ? '滚动查看' : '前往审核',
                      style: TextStyle(color: context.c.warning, fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),

          // Chat Body with Floating Jump to Latest Button
          Expanded(
            child: dsh.isLoadingHistory
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      if (dsh.messages.isEmpty && activeApprovals.isEmpty)
                        Center(
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
                                    border: Border.all(color: const Color(0xFFCCE4F7)),
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
                                  '当前工作区: ${currentWs?.title ?? "默认工作区"}',
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
                                    _buildSuggestionChip('🛠️ 分析项目代码', () {
                                      _inputController.text = '分析当前项目代码结构并概述核心功能';
                                    }),
                                    _buildSuggestionChip('⚡ 检查潜在问题', () {
                                      _inputController.text = '检查当前项目中的潜在 Bug 或异常';
                                    }),
                                    _buildSuggestionChip('💡 生成测试建议', () {
                                      _inputController.text = '为当前模块编写单元测试用例建议';
                                    }),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        NotificationListener<ScrollNotification>(
                          onNotification: _onScrollNotification,
                          child: ListView.builder(
                            controller: _scrollController,
                            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            itemCount: dsh.messages.length + activeApprovals.length + (showTurnOutput ? 1 : 0),
                            itemBuilder: (context, index) {
                              // 1. Messages first (historical and streaming assistant response)
                              if (index < dsh.messages.length) {
                                final m = dsh.messages[index];
                                // 附 GlobalKey：会话内查找要靠 ensureVisible 精确滚到
                                // 命中的那条消息。没有 key 只能按索引估算 offset，而
                                // 消息高度是可变的，估算必然滚偏。
                                final highlighted = _highlightedMessageIds.contains(m.id);
                                Widget built = _buildMessageItem(m);
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
                              }

                              // 2. Pending approvals appended at the end of active chat stream
                              final approvalIndex = index - dsh.messages.length;
                              if (approvalIndex < activeApprovals.length) {
                                final req = activeApprovals[approvalIndex];
                                return Padding(
                                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                                  child: ApprovalCard(
                                    request: req,
                                    onRespond: (r, outcome, [reason]) => dsh.respondApproval(r, outcome, reason: reason),
                                  ),
                                );
                              }

                              // 3. 「本轮产出」卡片：事件进流那一半 —— 交付物出现在
                              // 交付它的那一轮之后（见 build 里锚点的说明）。
                              return TurnOutputCard(
                                deliverables: dsh.deliverables,
                                busyPath: _deliverableBusy.value,
                                errorText: _deliverableError,
                                onOpen: (item) => _openDeliverable(dsh, item),
                                onShowAll: () => _openSessionInfo(dsh, section: SessionInsightSection.deliverables),
                              );
                            },
                          ),
                        ),

                      if (_showScrollToBottom)
                        Positioned(
                          right: 16,
                          bottom: 12,
                          child: Material(
                            elevation: 2,
                            color: context.c.accent,
                            borderRadius: BorderRadius.circular(8),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: _scrollToBottom,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.arrow_downward_rounded, size: 15, color: Colors.white),
                                    SizedBox(width: 4),
                                    Text(
                                      '回到最新消息',
                                      style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),

          // 会话内查找面板（v1.4.2）。位置在交互块之上、输入框之下：查找是会话级
          // 操作，不该被某个提问卡片挤到屏幕外。
          if (_searchOpen)
            MessageSearchPanel(
              query: _searchQuery,
              results: _searchQuery.trim().isEmpty
                  ? const []
                  : MessageSearch.collapse(MessageSearch.search(dsh.messages, _searchQuery)),
              totalHits: _searchQuery.trim().isEmpty
                  ? 0
                  : MessageSearch.search(dsh.messages, _searchQuery).length,
              onQueryChanged: _onSearchChanged,
              onClose: _toggleSearch,
              onJumpTo: (hit) => _jumpToHit(hit, dsh),
            ),

          // 提问卡片 / TODO 面板 / 图片附件（patch 0003）。
          //
          // 顺序是有意的：提问在最上面，因为它阻塞着 agent 的下一步 —— 用户
          // 必须先看到并回答它，TODO 和图片都是背景信息。附件紧贴输入框，因为
          // 它是"这轮对话里出现的图"，不是一条独立消息。
          ..._buildInteractiveBlocks(dsh),

          // 上一轮失败说明（回合级）。放在输入框正上方：它解释的是"为什么刚才
          // 那一轮断了"，紧挨着用户接下来要输入的地方，且不遮挡历史消息。
          if (dsh.lastTurnFailure != null) _buildTurnFailureBanner(dsh),

          // Modern Clean Input Bar
          _buildInputBar(dsh),
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
  int otherSessionQuestionCount(DshService dsh) {
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

  /// 上一轮失败横幅：把"这轮为什么断了"直接说清楚，并给一键"重试"的入口。
  Widget _buildTurnFailureBanner(DshService dsh) {
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

  Widget _buildSuggestionChip(String text, VoidCallback onTap) {
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

  Widget _buildMessageItem(ChatMessage msg) {
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

    int earliestMarkerIndex = -1;
    for (final marker in contextMarkers) {
      final idx = msg.content.indexOf(marker);
      if (idx != -1) {
        if (earliestMarkerIndex == -1 || idx < earliestMarkerIndex) {
          earliestMarkerIndex = idx;
        }
      }
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

    if (displayContent.isEmpty && (embeddedContext != null && embeddedContext.isNotEmpty)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: MemoryCard(content: embeddedContext),
      );
    }

    final isUser = msg.role == 'user';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: context.c.selectedSurface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFCCE4F7)),
              ),
              child: Icon(Icons.auto_awesome, color: context.c.accent, size: 16),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                // Thinking Fold Card
                if ((msg.thinking != null && msg.thinking!.isNotEmpty) || (msg.isStreaming && msg.content.isEmpty))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ThinkingCard(
                      content: msg.thinking ?? '',
                      isThinking: msg.isStreaming,
                    ),
                  ),

                // Tool Executions
                for (final tool in msg.tools)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ToolCallCard(tool: tool),
                  ),

                // Content Bubble
                if (displayContent.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                    decoration: BoxDecoration(
                      color: isUser ? context.c.accent : context.c.surface,
                      borderRadius: isUser
                          ? const BorderRadius.only(
                              topLeft: Radius.circular(10),
                              bottomLeft: Radius.circular(10),
                              bottomRight: Radius.circular(10),
                              topRight: Radius.circular(3),
                            )
                          : const BorderRadius.only(
                              topRight: Radius.circular(10),
                              bottomLeft: Radius.circular(10),
                              bottomRight: Radius.circular(10),
                              topLeft: Radius.circular(3),
                            ),
                      border: Border.all(
                        color: isUser
                            ? context.c.accent
                            : context.c.border,
                        width: 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.02),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: SafeMarkdown(
                      data: displayContent,
                      selectable: true,
                      fallbackTextStyle: TextStyle(
                        fontSize: 14,
                        color: isUser ? Colors.white : context.c.textPrimary,
                        height: 1.45,
                      ),
                      styleSheet: MarkdownStyleSheet(
                        p: TextStyle(fontSize: 14, color: isUser ? Colors.white : context.c.textPrimary, height: 1.45),
                        code: TextStyle(
                          color: isUser ? Colors.white : const Color(0xFF0369A1),
                          backgroundColor: isUser ? const Color(0x33FFFFFF) : context.c.background,
                          fontFamily: 'monospace',
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: isUser ? const Color(0x1A000000) : context.c.background,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: isUser ? const Color(0x33FFFFFF) : context.c.border),
                        ),
                      ),
                    ),
                  ),

                // Embedded Context Card if present
                if (embeddedContext != null && embeddedContext.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: MemoryCard(content: embeddedContext),
                  ),

                // Streaming Indicator
                if (msg.isStreaming)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2, color: context.c.accent),
                        ),
                        const SizedBox(width: 6),
                        Text('AI 正在思考并执行操作...', style: TextStyle(color: context.c.textSecondary, fontSize: 11)),
                      ],
                    ),
                  ),

                // Timestamp — ChatMessage.timestamp is a non-nullable DateTime
                // (the constructor defaults it to DateTime.now()), so the old
                // `if (msg.timestamp != null)` guard was always true and the
                // timestamp always rendered. Behaviour is unchanged.
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _formatTime(msg.timestamp),
                    style: TextStyle(color: context.c.textTertiary, fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: context.c.accent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.person_rounded, color: Colors.white, size: 17),
            ),
          ],
        ],
      ),
    );
  }

  /// 麦克风按钮：点一下开始识别，再点一下停止。
  ///
  /// 三处刻意的行为：
  /// * **识别中按钮变色**，用户能一眼看出还在听 —— 语音最反直觉的问题就是
  ///   「不知道它有没有在听」，不给出视觉反馈会让人反复点。
  /// * **识别结果替换整个输入框**而不是追加。流式识别的中间结果是累积的，
  ///   追加会得到「你好你好你好世界世界」这种叠字。
  /// * **永远可点**，且在不可用时说明具体原因（见下）。
  ///
  /// ## 这里修的是一个真实缺陷
  ///
  /// 上一版在「未探测完成」时返回空白 SizedBox、在「不可用」时返回**不带 onTap
  /// 的图标**。后果是：按钮要么看不见，要么看着是个按钮、点下去毫无反应，
  /// 而麦克风权限弹窗也永远不会出现 —— 用户描述的就是「有按钮但没法点击，
  /// 也没弹出什么权限设置」。
  ///
  /// 根因是把「申请权限」和「探测能力」合并成了一次性的初始化，且失败后永久
  /// 记为不可用。现在无论什么状态都保持可点：点下去会重新探测并触发权限申请；
  /// 确实不行时用 SnackBar 说清是哪种原因，给出可执行的下一步。
  /// 待发附件条。每个附件显示名字与体积，可单项删除。
  Widget _buildPendingAttachments() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final a in _pendingAttachments)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    a is PendingImage ? Icons.image_outlined : Icons.insert_drive_file_outlined,
                    size: 15,
                    color: a is PendingImage ? context.c.accent : context.c.purple,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      a.name,
                      style: TextStyle(fontSize: 12, color: context.c.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    a.sizeLabel,
                    style: TextStyle(fontSize: 10.5, color: context.c.textTertiary),
                  ),
                  const SizedBox(width: 2),
                  InkWell(
                    onTap: () => setState(() => _pendingAttachments.remove(a)),
                    borderRadius: BorderRadius.circular(11),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(Icons.close_rounded, size: 15, color: context.c.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMicButton(DshService dsh) {
    final listening = _voiceListening;
    // 只有"已探测且确定不可用"才显示划掉的麦克风。未探测完成时显示正常图标 ——
    // 用空白会让功能看起来不存在。
    final unavailable = _voiceSupported == false;

    return Tooltip(
      message: unavailable ? '语音输入不可用（长按查看诊断）' : '语音输入（长按查看诊断）',
      child: InkWell(
        onTap: () => listening ? _stopVoice(dsh) : _startVoice(dsh),
        // 长按出诊断报告。
        //
        // 存在的理由：语音失败有四五种彼此无关的原因（没有识别引擎、权限被拒且
        // 系统不再弹窗、插件卡在权限回调上、缺中文语言包、上次会话没释放），而
        // 它们在用户眼里**都只是"点了没反应"**。让 App 把自己每一步的实测结果
        // 直接说出来，比一轮轮猜快得多。
        onLongPress: _showVoiceDiagnose,
        borderRadius: BorderRadius.circular(20),
        // 44x44：Material 推荐的最小可触达尺寸。36px 在手机上确实偏小，
        // 语音又是个高频入口（用户报"按钮有点小"）。
        child: SizedBox(
          width: 44,
          height: 44,
          child: listening
              ? Padding(
                  padding: const EdgeInsets.all(10),
                  child: CircularProgressIndicator(strokeWidth: 2.2, color: context.c.danger),
                )
              : Center(
                  child: Icon(
                    unavailable ? Icons.mic_off_rounded : Icons.mic_rounded,
                    size: 24,
                    color: listening
                        ? context.c.danger
                        : (unavailable ? context.c.textTertiary : context.c.textSecondary),
                  ),
                ),
        ),
      ),
    );
  }

  /// 长按麦克风：弹出语音状态诊断。
  ///
  /// 用途见调用点注释 —— 把"点了没反应"拆成可判读的几条实测结果，用户截屏即可
  /// 定位。文案刻意不用"错误"开头：多数情况不是缺陷，而是设备确实缺识别引擎。
  Future<void> _showVoiceDiagnose() async {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: const Text('语音输入诊断'),
        content: _VoiceDiagnoseBody(),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _startVoice(DshService dsh) async {    final ok = await VoiceInputService.instance.start(
      // 中间结果是累积的，必须整段替换。
      onPartial: (text, _) => _applyVoiceText(text, dsh),
      onFinal: (text) => _applyVoiceText(text, dsh),
      onError: (msg) {
        _toast(msg);
        if (mounted) setState(() => _voiceListening = false);
      },
    );
    if (mounted) {
      setState(() {
        _voiceListening = ok;
        // 成功说明设备可用（可能用户刚在系统设置里开了麦克风权限），把状态纠正
        // 回来，否则图标会一直停在"划掉的麦克风"上，看起来仍然不可用。
        if (ok) _voiceSupported = true;
      });
    }
  }

  Future<void> _stopVoice(DshService dsh) async {
    await VoiceInputService.instance.stop();
    if (mounted) setState(() => _voiceListening = false);
  }

  void _applyVoiceText(String text, DshService dsh) {
    if (text.trim().isEmpty) return;
    _inputController.text = text;
    _inputController.selection = TextSelection.collapsed(offset: text.length);
    // 语音内容同样要进草稿，否则进程被杀后说的这段话会丢。
    dsh.updateDraft(text);
  }

  // ---------------------------------------------------------- 长按说话 --
  //
  // 长按生效的**唯一**条件：输入框为空（见下方 builder 里的 holdEnabled）。
  // 一旦有文字，长按必须还给系统原本的"选中/粘贴"——抢走它会让编辑长文本
  // 变得很难用。已有文字时想继续用语音，右边的麦克风按钮（点按）仍然在。

  Future<void> _beginHoldTalk(DshService dsh) async {
    if (_holdPhase != _HoldTalkPhase.idle) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _holdPhase = _HoldTalkPhase.recording;
      _holdText = '';
      _holdStartedAt = DateTime.now();
    });
    // 录音时长显示：1 秒一跳就够了，别用逐帧动画去拖主线程。
    _holdTick?.cancel();
    _holdTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _holdPhase == _HoldTalkPhase.recording) setState(() {});
    });
    // 兜底看门狗：语音服务挂死时 _endHoldTalk（依赖松手）可能永远不来，
    // 也可能来了但 stop() 挂在平台回调上。30s 后强制收尾，把输入框还回去。
    _holdWatchdog?.cancel();
    _holdWatchdog = Timer(const Duration(seconds: 30), () {
      if (!mounted || _holdPhase != _HoldTalkPhase.recording) return;
      _cancelHoldTalk();
      if (mounted) _toast('录音异常结束，已恢复输入框');
    });

    final ok = await VoiceInputService.instance.start(
      onPartial: (text, _) {
        if (!mounted) return;
        setState(() {
          _holdText = text;
          _holdAwaitingFinal = false;
        });
      },
      onFinal: (text) {
        if (!mounted) return;
        setState(() {
          _holdText = text;
          // 松手后才到的 final：把它补进输入框（前提是用户没改过内容）。
          if (_holdAwaitingFinal && _inputController.text == _holdText) {
            _inputController.text = text;
          }
          _holdAwaitingFinal = false;
        });
      },
      onError: (msg) {
        if (!mounted) return;
        _holdTick?.cancel();
        setState(() {
          _holdPhase = _HoldTalkPhase.idle;
          _holdText = '';
        });
        _toast(msg);
      },
    );
    if (!mounted) return;
    if (!ok) {
      // 启动失败的原因已由 onError 说明；这里只负责收状态。
      _holdTick?.cancel();
      setState(() => _holdPhase = _HoldTalkPhase.idle);
      return;
    }
    setState(() => _voiceSupported = true);
  }

  /// 松手：停止识别，转录本进输入框，进入"重录 / 发送"确认态。
  Future<void> _endHoldTalk(DshService dsh) async {
    if (_holdPhase != _HoldTalkPhase.recording) return;
    _holdTick?.cancel();
    _holdWatchdog?.cancel();
    _holdAwaitingFinal = true;
    await VoiceInputService.instance.stop();
    if (!mounted) return;

    final text = _holdText.trim();
    if (text.isEmpty) {
      setState(() {
        _holdPhase = _HoldTalkPhase.idle;
        _holdText = '';
      });
      _toast('没有听清，再长按说一次');
      return;
    }
    setState(() {
      _holdPhase = _HoldTalkPhase.confirm;
      _inputController.text = text;
      _inputController.selection = TextSelection.collapsed(offset: text.length);
    });
    dsh.updateDraft(text);
  }

  /// 手势被系统打断（来电、手势冲突等）：直接放弃这次录音。
  void _cancelHoldTalk() {
    if (_holdPhase != _HoldTalkPhase.recording) return;
    _holdTick?.cancel();
    _holdWatchdog?.cancel();
    _holdAwaitingFinal = false;
    VoiceInputService.instance.cancel();
    if (!mounted) return;
    setState(() {
      _holdPhase = _HoldTalkPhase.idle;
      _holdText = '';
    });
  }

  /// 「重录」：清掉这次结果，立刻重新开始说话（不用再长按一次）。
  Future<void> _redoHoldTalk(DshService dsh) async {
    _inputController.clear();
    dsh.updateDraft('');
    setState(() {
      _holdPhase = _HoldTalkPhase.idle;
      _holdText = '';
    });
    await _beginHoldTalk(dsh);
  }

  /// 「发送」：把识别到的文本按正常消息发出去。
  Future<void> _sendHoldTalk(DshService dsh) async {
    final text = _inputController.text;
    setState(() => _holdPhase = _HoldTalkPhase.idle);
    if (text.trim().isEmpty) return;
    _sendMessage(dsh); // 返回 void，别 await
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        // 「去系统设置里开麦克风」这类指引必须能读完，2 秒不够；短提示保持轻快。
        duration: Duration(seconds: msg.length > 24 ? 6 : 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
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

  /// 上下文压力告警（**只在跨过阈值时**才占空间）。
  ///
  /// 触发条件里带 `isLive`：投影缓存快照可能落后几个小时，拿它去催用户
  /// "该新开会话了"是在用旧数据催一个不可逆的决定。
  Widget _buildContextPressureRow(DshService dsh) {
    final stats = dsh.sessionStats;
    final fraction = stats?.contextFraction;
    if (stats == null || !stats.isLive || fraction == null) return const SizedBox.shrink();
    if (fraction < SessionStatusStrip.pressureCriticalThreshold) return const SizedBox.shrink();

    final pct = (fraction * 100).round();
    return Container(
      key: const ValueKey('context-pressure-row'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        color: context.c.dangerSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.c.dangerBorder),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 15, color: context.c.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '上下文已用 $pct%，继续下去可能被截断',
              style: TextStyle(fontSize: 11.5, color: context.c.danger),
            ),
          ),
          TextButton(
            onPressed: () => dsh.createNewSession(),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text('新开会话', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: context.c.danger)),
          ),
        ],
      ),
    );
  }

  /// 打开会话信息面板：状态条的任意一段、卡片的"查看全部"、以及输入框上方的
  /// 上下文告警都走这里。
  ///
  /// 打开时先发一次第三档加载（`jobs` + `schedules` —— 全链路最贵的两个请求，
  /// 只在用户明确要看的时候拉）；面板自己也会在首帧后调一次 `onRefresh`，
  /// 所以这里不重复发，只负责把"看过产出"这件事记下来。
  Future<void> _openSessionInfo(DshService dsh, {SessionInsightSection section = SessionInsightSection.usage}) async {
    _deliverablesAck[_ackKey(dsh)] = dsh.deliverableCount ?? 0;
    if (mounted) setState(() {});

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      // 面板里的数据是**会话域**的，随时可能被事件刷新（例如作业列表刚拉回来），
      // 所以让它在自己的路由里订阅一次 DshService —— 否则弹层会冻结在打开那一刻
      // 的快照上，懒加载的结果永远看不见。
      builder: (_) => Consumer<DshService>(
        builder: (_, d, __) => ValueListenableBuilder<String?>(
          valueListenable: _deliverableBusy,
          builder: (_, busyPath, __) => SessionInfoSheet(
            stats: d.sessionStats,
            turnBurnTokens: d.lastTurnTokens,
            deliverables: d.deliverables,
            changes: d.workspaceChanges,
            changesAvailable: d.workspaceChangesAvailable,
            changesReason: d.workspaceChangesReason,
            jobs: d.jobs,
            jobsUnavailable: d.jobsDegraded.isNotEmpty,
            schedules: d.schedules,
            busyDeliverablePath: busyPath,
            initialSection: section,
            onOpenDeliverable: (item) => _openDeliverable(d, item),
            onLoadDiff: d.fetchDiff,
            onKillJob: (job) => d.killJob(job.id),
            onDeleteSchedule: (s) => d.deleteSchedule(s.id),
            onRefresh: d.fetchSessionExtras,
          ),
        ),
      ),
    );
  }

  /// 下载交付物并交给系统打开；失败说明**内联**在卡片/面板里。
  ///
  /// `item.path` 必须是 REST 返回的绝对路径（下载路由按绝对路径做成员判定）。
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

  Widget _buildInputBar(DshService dsh) {
    return Container(
      // 测试用来量输入栏的实际位置：键盘弹出后它的底边必须紧贴键盘顶边，
      // 中间不允许出现空白（这正是用户报的那个问题）。
      key: const ValueKey('chat-input-bar'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: context.c.surface,
        border: Border(top: BorderSide(color: context.c.border)),
      ),
      child: SafeArea(
        child: Container(
          decoration: BoxDecoration(
            color: context.c.surfaceMuted,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: context.c.border),
          ),
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 上下文告警（v1.14）：**只在跨过阈值时**出现。
              //
              // 输入框上方是"我要行动"的位置，而"上下文快满了"正是一个必须当场
              // 做的决策（继续会被截断 / 该新开会话）。平时一行都不占 —— 常驻在
              // 这里的信息会被键盘弹起时的压缩挤掉，也会挤掉真正要打字的空间。
              _buildContextPressureRow(dsh),
              // 运行中说明（v1.14）：把"你发的消息会排队"讲在**打字之前**。
              // 放在提示条/队列面板之上 —— 它描述的是"这个输入框现在是什么含义"。
              _buildRunningHint(dsh),
              // 上一条排队消息的回执（可撤回）。放在队列面板之上：它讲的是
              // "刚刚那一下发生了什么"，而队列讲的是"现在攒了些什么"。
              _buildNotice(dsh),
              // 排队消息（v1.13）：agent 正在跑时你发出去的话先在这里等。
              // 放在输入卡片**内部**最上方：它是"这条队列属于这个输入框"，
              // 而不是另一块独立面板。
              _buildQueueDock(dsh),
              // 待发附件也放进卡片内 —— 它与"这条消息要发什么"是同一件事，
              // 摆在卡片外会显得是两个不相干的东西。
              if (_pendingAttachments.isNotEmpty) _buildPendingAttachments(),
              // 提示词模板（v1.11.0）：点一下把模板文字接进输入框。
              // 没有模板时不占任何空间。
              if (dsh.snippets.isNotEmpty) _buildSnippetChips(dsh),

              // 录音态的"正在聆听"面板由手势层内部渲染（见下方注释 2）——
              // 这里**不能**把整块换成别的 widget，否则承载长按识别器的那一层
              // 会被销毁、松手事件永远不来。
              //
              // ⚠️ 两个坑，都踩过，别退回去：
              //
              // 1) 为什么是"盖一层"而不是给 TextField 套 GestureDetector：
                //    EditableText **内部**也有一个长按识别器（选词 + 弹工具条），
                //    在手势竞技场里它比外层先注册、会赢 —— 实测长按有时能录音、
                //    有时毫无反应，关掉 enableInteractiveSelection 也压不住。
                //    盖一层不透明的层，指针根本到不了下面的 EditableText。
                //
                // 2) 为什么录音态**不换掉这一层**、只换它的内容：
                //    长按开始后如果把承载识别器的 widget 从树上摘掉，识别器会被
                //    一起销毁 —— `onLongPressEnd` 永远不会触发，于是松手之后
                //    一直卡在"正在聆听"（这条在真机上同样会发生）。
                //    所以这一层在整个手势期间必须保持存活；三个回调也**始终非空**
                //    （在回调内部判状态），中途把回调置 null 同样会销毁识别器。
                //
                // 为什么不妨碍打字：系统文字输入走 EditableText 的 text input
                // connection，不经过命中测试；而且一旦有内容这一层立刻消失，
                // 光标/选择/长按选词全部恢复原样。
                //
                // 用 ValueListenableBuilder 只重建这一小块：可见性依赖输入内容，
                // 用 setState 会每敲一个字重建整个 ChatView（含消息列表）。
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _inputController,
                  builder: (context, value, _) {
                    final empty = value.text.isEmpty;
                    final recording = _holdPhase == _HoldTalkPhase.recording;
                    // 空框时覆盖，直到松手进入确认态（那时要让用户能改字/点按钮）。
                    final showGestureLayer = (empty || recording) &&
                        _holdPhase != _HoldTalkPhase.confirm;
                    // 录音面板比输入框高（麦克风圆点 + 两行文字）。Stack 的高度由
                    // 第一个孩子决定，所以录音时要显式给足空间，否则面板会被压在
                    // 输入框那一行的高度里、报 RenderFlex overflow。
                    // SizedBox 始终存在（只在高度上变），保证树的形状稳定 ——
                    // 形状一变就可能重建承载长按识别器的元素，松手就收不到了。
                    return SizedBox(
                      height: recording ? 54 : null,
                      child: Stack(
                        children: [
                          TextField(
                            key: const ValueKey('chat-input-field'),
                            controller: _inputController,
                            focusNode: _inputFocusNode,
                            style: TextStyle(color: context.c.textPrimary, fontSize: 14.5),
                            maxLines: 5,
                            minLines: 1,
                            decoration: const InputDecoration(
                              // 空框的提示由手势层负责（它才是那段交互的说明），
                              // 这里留空，避免两层文案叠在一起。
                              hintText: '',
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.fromLTRB(6, 4, 6, 8),
                            ),
                            onChanged: (v) => dsh.updateDraft(v),
                            onSubmitted: (_) => _sendMessage(dsh),
                          ),
                          if (showGestureLayer)
                            Positioned.fill(
                              child: GestureDetector(
                                key: const ValueKey('chat-hold-layer'),
                                behavior: HitTestBehavior.opaque,
                                // 录音中不接受点按。**注意不要让这个回调变 null**：
                                // 中途改动 GestureDetector 的识别器集合会牵动识别器
                                // 生命周期，这里一律保持非空、在内部判状态。
                                onTap: () {
                                  if (_holdPhase == _HoldTalkPhase.recording) {
                                    // 录音态下点按 = 自救出口。语音服务偶发挂死
                                    //（listen 超时/平台不回调）时 _holdPhase 会被
                                    // 卡在 recording，手势层吞掉一切点击且不再放行
                                    // —— 用户表现为"输入框点不动、键盘弹不出来"。
                                    // 点按直接放弃这次录音，把输入框还回去。
                                    _cancelHoldTalk();
                                    _toast('已取消录音');
                                    return;
                                  }
                                  // requestFocus 只拿焦点，不保证唤起输入法：
                                  // 指针被这层 opaque 手势层吃掉时，EditableText
                                  // 自己的 tap→IME 请求不会发生。显式补一次
                                  // requestImeFocus，让键盘一定弹出来。
                                  _inputFocusNode.requestFocus();
                                  FocusScope.of(context).requestFocus(_inputFocusNode);
                                },
                                onLongPressStart: (_) => _beginHoldTalk(dsh),
                                onLongPressEnd: (_) => _endHoldTalk(dsh),
                                onLongPressCancel: () => _cancelHoldTalk(),
                                child: recording
                                    ? _buildHoldRecordingPanel()
                                    // 指令只在还没聚焦时显示：已经点了、键盘都弹出来了，
                                    // 再挂着"点按打字"是多余的噪音。用 ListenableBuilder
                                    // 只听焦点，避免为这点变化重建整个页面。
                                    : ListenableBuilder(
                                        listenable: _inputFocusNode,
                                        builder: (context, _) {
                                          if (_inputFocusNode.hasFocus) {
                                            return const SizedBox.shrink();
                                          }
                                          return Align(
                                            alignment: Alignment.centerLeft,
                                            child: Padding(
                                              padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
                                              child: Text(
                                                '点按打字，长按说话',
                                                style: TextStyle(color: context.c.textTertiary, fontSize: 13.5),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),

              if (_holdPhase == _HoldTalkPhase.confirm)
                // 确认态：识别结果已经在输入框里（可直接改字），这里给两个动作。
                _buildHoldConfirmRow(dsh)
              else if (_holdPhase == _HoldTalkPhase.idle)
                LayoutBuilder(
                  builder: (context, box) {
                    // 这一行的横向空间永远是紧的：在 360dp 宽的手机上，固定宽度
                    // 的模型胶囊会把整行顶出去（实测 317 > 316，溢出 1px）。
                    // 所以胶囊的可读宽度按**剩余空间**算，而不是钉死一个常量。
                    //
                    // 预留：停止键 36（不显示时 0）+ 附件键 36 + 麦克风 44 +
                    // 发送键 44 + 三处间隔 6 + 胶囊自身装饰（内边距/图标/箭头）
                    // 47 + 4 的安全余量。
                    final stopWidth = (dsh.isSending || dsh.isCanceling) ? 36.0 : 0.0;
                    final reserved = 36.0 + 44.0 + 44.0 + 6.0 + 47.0 + 4.0;
                    final textCap = (box.maxWidth - stopWidth - reserved).clamp(40.0, 104.0);
                    return Row(
                      children: [
                        // 停止键固定在**最左**（v1.14）：它曾经和发送键抢同一个位置，
                        // 于是"输入框被清空"（切会话、重录、草稿恢复）会在用户毫无输入
                        // 动作的情况下把发送键变成停止键 —— 手一抖就取消掉自己正在跑的
                        // 回合。位置分开之后，任何状态变化都不会改变任何按钮的含义。
                        _buildStopButton(dsh),
                        _buildComposerIcon(
                          icon: Icons.add_rounded,
                          tooltip: '添加图片或文件',
                          highlighted: _pendingAttachments.isNotEmpty,
                          onTap: () => _showAttachSheet(dsh),
                        ),
                        const Spacer(),
                        _buildModelPill(dsh, maxTextWidth: textCap),
                        const SizedBox(width: 2),
                        _buildMicButton(dsh),
                        const SizedBox(width: 4),
                        _buildSendButton(dsh),
                      ],
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 录音中的面板：麦克风 + 已说的内容 + 时长，并明确写"松开结束"。
  ///
  /// 交互提示必须写出来：长按说话是"看不见的手势"，没有文案用户不会知道
  /// 什么时候可以松手、松手会发生什么。
  Widget _buildHoldRecordingPanel() {
    final elapsed = _holdStartedAt == null
        ? 0
        : DateTime.now().difference(_holdStartedAt!).inSeconds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: context.c.dangerSurface,
              shape: BoxShape.circle,
              border: Border.all(color: context.c.danger.withOpacity(0.5)),
            ),
            child: Icon(Icons.mic_rounded, size: 17, color: context.c.danger),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _holdText.isEmpty ? '正在聆听…' : _holdText,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _holdText.isEmpty ? context.c.textSecondary : context.c.textPrimary,
                    fontSize: 14,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '松开结束 · ${elapsed}s',
                  style: TextStyle(color: context.c.textTertiary, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 松手后的确认行：重录 / 发送。
  Widget _buildHoldConfirmRow(DshService dsh) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: context.c.textSecondary,
                side: BorderSide(color: context.c.border),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onPressed: () => _redoHoldTalk(dsh),
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: const Text('重录', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: context.c.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onPressed: () => _sendHoldTalk(dsh),
              icon: const Icon(Icons.arrow_upward_rounded, size: 17),
              label: const Text('发送', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  /// 提示词模板 chips：横向滚动，点按把模板文字**追加**到输入框（不覆盖
  /// 已有内容 —— 用户可能已经打了半句）。
  Widget _buildSnippetChips(DshService dsh) {
    return SizedBox(
      height: 30,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: dsh.snippets.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (ctx, i) {
          final snip = dsh.snippets[i];
          return ActionChip(
            label: Text(snip.label, style: TextStyle(fontSize: 11.5, color: context.c.textSecondary)),
            backgroundColor: context.c.surface,
            side: BorderSide(color: context.c.border),
            visualDensity: VisualDensity.compact,
            onPressed: () {
              final cur = _inputController.text;
              _inputController.text = cur.isEmpty
                  ? snip.text
                  : '$cur\n${snip.text}';
              _inputController.selection = TextSelection.fromPosition(
                TextPosition(offset: _inputController.text.length),
              );
              dsh.updateDraft(_inputController.text);
            },
          );
        },
      ),
    );
  }

  /// 运行中说明（v1.14）：把"这条消息的含义变了"讲在用户打字**之前**。
  ///
  /// 为什么必须有：上一版靠一枚"排队/插话"开关表达这件事，而开关只在回合跑起来
  /// 之后才出现 —— 用户打字时看不到它，按发送时也未必看它，于是"这一条到底会排队
  /// 还是插话"完全靠记忆。这里改成一句常驻说明：含义是不变的（永远排队），
  /// 所以可以一直讲同一句话。
  Widget _buildRunningHint(DshService dsh) {
    if (!dsh.isSessionRunning) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 2, right: 2),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 12, color: context.c.textTertiary),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              '本轮执行中 · 你发的消息会在本轮结束后自动发送',
              style: TextStyle(fontSize: 11, color: context.c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  /// 输入卡片上方的原地提示条（v1.14）：排队回执 / 插话结果 / 失败回滚说明。
  ///
  /// 与 `_toast` 的分工：`_toast` 用 SnackBar，适合"知道了"这类说完就算的消息；
  /// 这条提示承载的是"你刚写的东西去哪了"，必须留在原地、可撤回、可重试。
  Widget _buildNotice(DshService dsh) {
    return ValueListenableBuilder<_ComposerNotice?>(
      valueListenable: _notice,
      builder: (context, notice, _) {
        if (notice == null) return const SizedBox.shrink();
        final tone = notice.ok ? context.c.textSecondary : context.c.danger;
        return Container(
          key: const ValueKey('chat-notice'),
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
          decoration: BoxDecoration(
            color: notice.ok ? context.c.surface : context.c.dangerSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: notice.ok ? context.c.border : context.c.danger),
          ),
          child: Row(
            children: [
              Icon(
                notice.ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                size: 14,
                color: tone,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  notice.text,
                  style: TextStyle(fontSize: 11.5, color: notice.ok ? context.c.textSecondary : context.c.danger),
                ),
              ),
              if (notice.action != _NoticeAction.none)
                _queueTextButton(
                  key: const ValueKey('chat-notice-action'),
                  label: notice.action == _NoticeAction.undoQueue ? '撤回' : '重试',
                  onTap: () => _onNoticeAction(dsh, notice),
                ),
            ],
          ),
        );
      },
    );
  }

  void _onNoticeAction(DshService dsh, _ComposerNotice notice) {
    switch (notice.action) {
      case _NoticeAction.undoQueue:
        final id = notice.undoItemId;
        _clearNotice();
        if (id != null) unawaited(_removeQueued(dsh, id, appliedText: '已撤回'));
        break;
      case _NoticeAction.retrySend:
        _clearNotice();
        _sendMessage(dsh);
        break;
      case _NoticeAction.none:
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
  Widget _buildQueueDock(DshService dsh) {
    final rows = dsh.queueItems;
    // 队列可见性三态：读不到（已知失败）也要渲染，否则"路由坏了"会被静默当成
    // "没有排队消息"（生产上真的发生过：GET queue 被通配路由吞掉）。
    final unknown = dsh.queueKnown == false;
    if (rows.isEmpty && dsh.queueError.isEmpty && !unknown) return const SizedBox.shrink();

    final header = rows.isEmpty
        ? (unknown ? '队列状态未知' : '排队消息')
        : '${rows.length} 条排队中 · 本轮结束后自动发送';

    // 展开态的上限：输入卡片是这条 Column 里唯一 Expanded（消息列表）的兄弟，
    // 且**自身高度无上限** —— 20 条排队 × 约 66px 会直接把输入卡片顶出屏幕
    // （RenderFlex 溢出）。所以就地展开必须限高 + 内部自己滚。
    const double collapsedMax = 3 * 66.0;
    const double expandedMax = 220;

    return Container(
      key: const ValueKey('queue-dock'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
      decoration: BoxDecoration(
        color: context.c.surfaceMuted,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.queue_rounded, size: 14, color: context.c.textSecondary),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  header,
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: context.c.textSecondary),
                ),
              ),
              if (dsh.queueLoading)
                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: context.c.textTertiary)),
            ],
          ),
          if (dsh.queueError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(dsh.queueError, style: TextStyle(fontSize: 11, color: context.c.danger)),
            ),
          // 折叠时最多列 3 条：队列可能有十几条，全画出来会把输入框挤出屏幕 ——
          // 而输入框才是这一块的主角。
          //
          // 溢出不再跳转到别的页面（那个页面已经删除）：**点一下就地把这个面板
          // 展开**，仍然限高（220）+ 内部滚动，所以既看得到全部，又不会把输入框
          // 顶出屏幕。
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: _queueExpanded ? expandedMax : collapsedMax),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final row in (_queueExpanded ? rows : rows.take(3))) _buildQueueRow(dsh, row),
                ],
              ),
            ),
          ),
          if (rows.length > 3)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('queue-dock-toggle'),
                onPressed: () => setState(() => _queueExpanded = !_queueExpanded),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  _queueExpanded ? '收起' : '还有 ${rows.length - 3} 条 · 展开全部',
                  style: TextStyle(fontSize: 11, color: context.c.accent),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildQueueRow(DshService dsh, QueueItem row) {
    final armed = _armedSteerItemId == row.id;
    return Padding(
      key: ValueKey('queue-row-${row.id}'),
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  row.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: context.c.textPrimary),
                ),
              ),
              const SizedBox(width: 8),
              // 触摸区 36×36（旧版是 16px 图标 + 4px padding = 24px，与紧邻的
              // 「删除」中心距只有 28px，误触会直接改掉正在跑的任务上下文）。
              _queueIconButton(Icons.edit_outlined, '编辑', () => _editQueueRow(dsh, row), key: ValueKey('queue-edit-${row.id}')),
              const SizedBox(width: 4),
              _queueIconButton(Icons.close_rounded, '删除', () => _removeQueueRow(dsh, row), key: ValueKey('queue-remove-${row.id}')),
            ],
          ),
          const SizedBox(height: 2),
          if (dsh.isSessionRunning)
            Row(
              children: [
                _queueTextButton(
                  key: ValueKey('queue-steer-${row.id}'),
                  label: armed ? '确认插话？' : '立即插话',
                  // 第一次点击只"武装"，第二次才真的插进正在跑的回合。这条路径
                  // 会改变 agent 当前的执行上下文，一次误触的代价是一整轮跑偏。
                  onTap: () => _steerQueueRow(dsh, row),
                  tone: armed ? context.c.warning : context.c.accent,
                  filled: armed,
                ),
                if (armed) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      // 引擎的 steer 是插进**最近的步骤**（agent.steer），不会取消
                      // 这一轮 —— 文案必须与真实语义一致，否则用户会以为任务要重跑。
                      '会插进当前步骤，本轮不会重来',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: context.c.warning),
                    ),
                  ),
                ],
              ],
            )
          else
            // 不可用时**给原因**，而不是一个点了没反应的死按钮。
            Text(
              '仅本轮运行中可插话发送',
              style: TextStyle(fontSize: 10.5, color: context.c.textTertiary),
            ),
        ],
      ),
    );
  }

  Widget _queueIconButton(IconData icon, String tooltip, VoidCallback? onTap, {Key? key}) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 36,
          height: 36,
          child: Center(
            child: Icon(
              icon,
              size: 17,
              color: onTap == null ? context.c.textTertiary : context.c.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  /// 队列条目上的文字按钮（v1.14）。
  ///
  /// 用文字而不是图标：⚡ 这种图标没有语义，而且同一个图标在发送键上已经被用过
  /// 一次（两个含义）；文字按钮的触摸区天然达标，也不用靠 Tooltip 解释自己。
  Widget _queueTextButton({
    required String label,
    required VoidCallback onTap,
    Color? tone,
    bool filled = false,
    Key? key,
  }) {
    final color = tone ?? context.c.accent;
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: filled ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(filled ? 1.0 : 0.5)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: filled ? Colors.white : color,
          ),
        ),
      ),
    );
  }

  /// 队列动作结束后的统一收敛。
  ///
  /// [QueueActionOutcome.alreadyGone] 必须**静默收敛**：那条消息已经被引擎领走，
  /// 是正常时序（比如你点「立即插话」的同时这一轮刚好结束），报红错等于把本来
  /// 就该发生的事说成故障。
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
        _showNotice(dsh.queueError.isEmpty ? failedText : dsh.queueError, ok: false);
        break;
    }
  }

  Future<void> _removeQueueRow(DshService dsh, QueueItem row) async {
    HapticFeedback.selectionClick();
    await _removeQueued(dsh, row.id, appliedText: '已删除');
  }

  /// 按 id 删除一条排队消息（删除按钮与回执条的「撤回」共用）。
  Future<void> _removeQueued(DshService dsh, String itemId, {required String appliedText}) async {
    final outcome = await dsh.queueAction(itemId, 'remove');
    if (!mounted) return;
    _settleQueueAction(dsh, outcome, appliedText: appliedText, failedText: '删除失败');
  }

  /// 「立即插话」：第一次点击只进入待确认态，第二次才真的插话。
  Future<void> _steerQueueRow(DshService dsh, QueueItem row) async {
    if (_armedSteerItemId != row.id) {
      HapticFeedback.selectionClick();
      _steerArmTimer?.cancel();
      setState(() => _armedSteerItemId = row.id);
      _steerArmTimer = Timer(_steerConfirmWindow, () {
        _steerArmTimer = null;
        if (!mounted) return;
        if (_armedSteerItemId == row.id) setState(() => _armedSteerItemId = null);
      });
      return;
    }
    _disarmSteer();
    HapticFeedback.mediumImpact();
    final outcome = await dsh.queueAction(row.id, 'steer');
    if (!mounted) return;
    _settleQueueAction(dsh, outcome, appliedText: '已插话发送', failedText: '插话失败');
  }

  Future<void> _editQueueRow(DshService dsh, QueueItem row) async {
    _disarmSteer();
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
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

  /// 操作行里的图标按钮。
  ///
  /// 刻意**不画圆圈边框**：这一行里已经有一个模型胶囊和一个实心发送键，再套三个
  /// 圆圈就又回到"一堆控件并列"的碎感。图标本身足够表达功能，触摸区仍给足 36px。
  Widget _buildComposerIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool highlighted = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: 36,
          height: 36,
          child: Center(
            child: Icon(
              icon,
              size: 22,
              color: highlighted ? context.c.accent : context.c.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  /// 输入卡片里的模型选择。
  ///
  /// 从顶栏移到这里：它是"这条消息要发给谁"的设定，和输入内容属于同一个决策
  /// 单元，放在手边更顺手，也省掉顶栏一整行。顶栏那个胶囊随之去掉 —— 同一件事
  /// 不该在两处各显示一份。
  ///
  /// [maxTextWidth] 由操作行按剩余空间算出来（见 `_buildInputBar`）：手机上横向
  /// 空间不足时先压缩模型名，而不是把整行顶出屏幕。
  Widget _buildModelPill(DshService dsh, {double maxTextWidth = 104}) {
    final name = dsh.currentModel.replaceFirst('cn:', '');
    return InkWell(
      onTap: () => _showModelSwitchSheet(context, dsh),
      borderRadius: BorderRadius.circular(9),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smart_toy_outlined, size: 14, color: context.c.textSecondary),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxTextWidth),
              child: Text(
                name,
                style: TextStyle(fontSize: 12, color: context.c.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: context.c.textTertiary),
          ],
        ),
      ),
    );
  }

  /// 停止键（v1.14 起与发送键**彻底分家**）。
  ///
  /// 只在本机**正在跑**这一轮时出现，并且固定在操作行最左端 —— 它曾经和发送键
  /// 抢同一个位置（空输入框 = 停止、有内容 = 发送），后果是：任何"输入框被清空"
  /// 的路径（切会话恢复草稿、重录、恢复草稿）都会在用户毫无输入动作的情况下
  /// 把发送键变成停止键，手一抖就取消掉自己正在跑的回合，还丢掉一整轮进度。
  /// 位置分开之后，任何状态变化都不会改变任何按钮的含义。
  ///
  /// 判据必须是 `isSending`（本机发起），**不是** `isSessionRunning`：会话可能是
  /// 电脑端发起、手机只是旁观，那时给一个停止键等于让手机去停别人的活。
  Widget _buildStopButton(DshService dsh) {
    if (dsh.isCanceling) {
      return const SizedBox(
        width: 36,
        height: 36,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (!dsh.isSending) return const SizedBox.shrink();
    return Tooltip(
      message: '停止本轮',
      child: InkWell(
        key: const ValueKey('chat-stop-button'),
        onTap: () {
          HapticFeedback.mediumImpact();
          dsh.cancelActiveTurn();
        },
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: context.c.dangerSurface,
            shape: BoxShape.circle,
            border: Border.all(color: context.c.danger),
          ),
          child: Icon(Icons.stop_rounded, color: context.c.danger, size: 18),
        ),
      ),
    );
  }

  /// 发送键。
  ///
  /// * 没有可发的内容时**置灰且不可点** —— 上一版无论有没有文字都是亮着的，
  ///   点下去没反应，用户会以为卡住了。
  /// * 运行中它**还是发送键**（含义变成"排队"），不再变成停止键；角标上的数字
  ///   是"已经排了几条"。含义的改变由输入框上方的常驻说明讲清楚，不靠按钮变脸。
  ///
  /// ⚠️ 整个判断必须包在 ValueListenableBuilder 里。最初把 `hasDraft` 写在
  /// 函数开头，而调用它的输入栏只在 DshService 通知时才重建 —— 用户敲字只
  /// 触发 ValueListenableBuilder 这一小块重建，于是"敲了字按钮还是置灰"。
  Widget _buildSendButton(DshService dsh) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _inputController,
      builder: (context, value, _) {
        final canSend = value.text.trim().isNotEmpty || _pendingAttachments.isNotEmpty;
        final queued = dsh.isSessionRunning ? dsh.queueItems.length : 0;
        return SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: InkWell(
                  key: const ValueKey('chat-send-button'),
                  onTap: canSend ? () => _sendMessage(dsh) : null,
                  borderRadius: BorderRadius.circular(22),
                  child: Container(
                    decoration: BoxDecoration(
                      color: canSend ? context.c.accent : context.c.border,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.arrow_upward_rounded,
                      size: 22,
                      color: canSend ? Colors.white : context.c.textTertiary,
                    ),
                  ),
                ),
              ),
              // 队列数角标：运行中按发送 = 排队，用户需要知道已经攒了几条。
              // 刻意不用 ⚡ 之类的另一套图标 —— 同一个位置换图标会让人以为
              // "发送键变成了别的东西"，而这正是上一版的问题。
              if (queued > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    constraints: const BoxConstraints(minWidth: 15),
                    decoration: BoxDecoration(
                      color: context.c.warning,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: context.c.surface, width: 1.5),
                    ),
                    child: Text(
                      '$queued',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 「语音输入诊断」对话框的内容体。
///
/// 独立成一个 StatefulWidget 而不是在调用处内联：诊断要 await 四五次平台查询，
/// 需要一个自己的加载态；塞进 ChatView 的 dialog builder 里会让那边没法 setState。
class _VoiceDiagnoseBody extends StatefulWidget {
  @override
  State<_VoiceDiagnoseBody> createState() => _VoiceDiagnoseBodyState();
}

class _VoiceDiagnoseBodyState extends State<_VoiceDiagnoseBody> {
  String? _report;

  @override
  void initState() {
    super.initState();
    // 超时兜底：诊断本身也不能变成"打不开"。
    VoiceInputService.instance
        .diagnose()
        .timeout(const Duration(seconds: 20), onTimeout: () => '诊断超时：平台没有响应')
        .then((r) {
      if (mounted) setState(() => _report = r);
    }).catchError((Object e) {
      if (mounted) setState(() => _report = '诊断失败: $e');
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      width: 320,
      child: _report == null
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(
                    _report!,
                    style: TextStyle(fontSize: 12.5, height: 1.7, color: c.textPrimary),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '若「服务可用」为否且「中文语言包」为空，说明这台设备没有语音识别'
                    '服务，App 侧无法解决。',
                    style: TextStyle(fontSize: 11.5, height: 1.6, color: c.textTertiary),
                  ),
                ],
              ),
            ),
    );
  }
}
