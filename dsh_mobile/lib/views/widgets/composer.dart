/// 输入区（composer）：输入卡片到发送键的全部内容。
///
/// Phase 0 结构拆分（纯剪切）：从 `chat_view.dart` 原样搬出，逻辑与样式一字未改。
/// 长按说话的三态机（含看门狗/迟到 final 的收尾）与语音能力探测随这一块一起搬过来
/// —— 它们的生命周期本来就等于输入卡片的生命：手势层、录音面板、确认行都长在
/// 这张卡片里，拆开只会让「松手事件」多绕一道。
///
/// 跨块状态（输入控制器、焦点、待发附件、回执条、队列展开态、插话武装态）仍然由
/// `_ChatViewState` 持有并**显式传参**；父级动作（发送 / 选附件 / 选命令 / 换模型 /
/// 队列编辑删除插话 / 回执动作 / toast）以回调注入。这里不引入单例或 InheritedWidget。
///
/// ## v1.27：六层 → 状态胶囊行
///
/// 改造前这张卡片自上而下叠了六块常驻内容（上下文告警 / 运行提示 / 回执 / 队列 /
/// 附件 / 模板 chips）。每一块单独看都有理由，叠在一起的结果是：手机上键盘弹出后
/// 真正留给"我要打的那句话"的高度被压到不足一行。
///
/// 现在**常驻最多两行**：
///
/// 1. 状态胶囊行（高 32，横向可滚）：按优先级只显示**一个**待办 —— 待审批 >
///    上下文告警 > 待提问 > 排队 N 条 > 运行中提示；其余收进尾部「⋯」的弹层。
/// 2. 文本框。
///
/// 例外只有两处，都是**临时**的：发送回执（3 秒自动消失的瞬态反馈）与用户自己
/// 展开的队列列表。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/local_snippet.dart';
import '../../models/pending_attachment.dart';
import '../../models/task_center.dart';
import '../../services/dsh_service.dart';
import '../../services/storage_service.dart';
import '../../services/voice_input_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import 'session_status_strip.dart';
import 'snippet_param_dialog.dart';

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
enum NoticeAction {
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
class ComposerNotice {
  final String text;
  final bool ok;
  final NoticeAction action;
  final String? undoItemId;

  const ComposerNotice({
    required this.text,
    this.ok = true,
    this.action = NoticeAction.none,
    this.undoItemId,
  });
}

/// 提示总线的**单一所有者**（[fix 2026-10-17]）。
///
/// 此前父级（chat_view）与 composer 各持一个 Timer 共用同一个 ValueNotifier，
/// 互不知晓：先弹"已排队"（5s），1 秒后语音失败弹 4s 提示，第 5 秒排队的
/// Timer 到期把语音错误提前清空。现在 timer 收敛到总线自己 —— 任何一侧
/// 写入都会取消上一条，生命周期只有一份。
class ComposerNoticeBus {
  final ValueNotifier<ComposerNotice?> notice = ValueNotifier(null);
  Timer? _timer;

  /// [ok] 默认与"失败提示停留更久"的旧语义对齐：成功 5s、失败 4s 由调用方
  /// 显式给，这里统一成 4s 兜底（原两侧默认不一致：5s vs 4s）。
  void show(
    String text, {
    bool ok = false,
    NoticeAction action = NoticeAction.none,
    String? undoItemId,
    Duration duration = const Duration(seconds: 4),
  }) {
    _timer?.cancel();
    notice.value = ComposerNotice(
      text: text,
      ok: ok,
      action: action,
      undoItemId: undoItemId,
    );
    _timer = Timer(duration, () {
      notice.value = null;
    });
  }

  void clear() {
    _timer?.cancel();
    _timer = null;
    notice.value = null;
  }

  void dispose() {
    _timer?.cancel();
    notice.dispose();
  }
}

/// 状态胶囊行里可能出现的待办类型。
///
/// **枚举顺序就是优先级**（声明顺序 = 轮换顺序，见 `_statusRows`）：审批是唯一
/// 阻塞着 agent 的东西，排在最前；"本轮执行中"只是背景说明，排在最后。同一时刻
/// 只显示一个 —— 一排胶囊又会变回改造前那堆层。
enum _StatusKind { contextPressure, question, queue, running }

/// 状态胶囊行里的一条待办。
///
/// 它只描述"显示什么"，不粘任何状态：每次 build 由 `_statusRows` 现算，所以
/// 会话切走/队列清空之后不会留下一条幽灵胶囊。
class _StatusRow {
  const _StatusRow({
    required this.kind,
    required this.icon,
    required this.label,
    required this.tone,
    this.key,
    this.actionKey,
    this.actionLabel = '',
    this.onAction,
  });

  final _StatusKind kind;
  final IconData icon;
  final String label;

  /// 图标与动作按钮的语义色（danger / warning / accent / textSecondary）。
  final Color tone;

  /// 整枚胶囊的 key（只有需要被测试/外部定位的那几条带）。轮换到别条时 key
  /// 跟着消失，这是刻意的：key 表示"这一条现在在屏幕上"，不是"这个待办存在"。
  final Key? key;

  /// 胶囊右侧**动作按钮**的 key（例如 `queue-dock-toggle`）。
  ///
  /// 与 [key] 分开是必须的：点在胶囊本体上什么都没发生，动作在右边那个文字
  /// 按钮上 —— 把动作的 key 挂在整枚胶囊上，测试/无障碍点击都会落在"点了没反应"
  /// 的位置（实测踩过）。
  final Key? actionKey;

  /// 右侧动作文案。空串 = 不带按钮（例如"运行中"只是说明，没有可执行的动作）。
  final String actionLabel;
  final VoidCallback? onAction;
}

/// 输入区。父级状态全部走构造参数，动作全部走回调。
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.dsh,
    required this.inputController,
    required this.inputFocusNode,
    required this.pendingAttachments,
    required this.noticeBus,
    required this.queueExpanded,
    required this.onToast,
    required this.onSend,
    required this.onRemoveAttachment,
    required this.onPickAttach,
    required this.onPickCommand,
    required this.onPickModel,
    required this.onToggleQueueExpanded,
    required this.onEditQueueRow,
    required this.onRemoveQueueRow,
    required this.onSteerQueueRow,
    required this.onNoticeAction,
    this.onRevealBlocked,
    this.policyLabel,
    this.onPickPermission,
    this.onOpenSnippets,
  });

  final DshService dsh;
  final TextEditingController inputController;
  final FocusNode inputFocusNode;
  final List<PendingAttachment> pendingAttachments;
  /// [fix 2026-10-17] 从裸 ValueNotifier 改为总线：timer 归总线所有，
  /// 父级与 composer 两侧写入不再互踩（双 Timer 竞态修复）。
  final ComposerNoticeBus noticeBus;
  final bool queueExpanded;
  final void Function(String message) onToast;
  final VoidCallback onSend;
  final void Function(PendingAttachment attachment) onRemoveAttachment;
  final VoidCallback onPickAttach;
  final VoidCallback onPickCommand;
  final VoidCallback onPickModel;
  final VoidCallback onToggleQueueExpanded;
  final void Function(QueueItem row) onEditQueueRow;
  final void Function(QueueItem row) onRemoveQueueRow;
  final void Function(QueueItem row) onSteerQueueRow;
  final void Function(ComposerNotice notice) onNoticeAction;

  /// 「待审批 / 待提问」胶囊右侧的动作：把用户带到真正能处理的地方（输入框上方
  /// 那个固定 dock）。
  ///
  /// **为 null 时胶囊只显示计数、不画按钮。** 这个组件不知道宿主是怎么把 dock
  /// 露出来的（滚动、展开、切 tab 都可能），画一个点了没反应的按钮比不画更糟。
  final VoidCallback? onRevealBlocked;

  /// 当前会话的执行策略短名（「每次询问」/「自动只读」/「全信任」）。
  ///
  /// [feat 2026-10-17] 对话权限从会话信息面板搬到输入栏，和模型胶囊并排 ——
  /// 两件事都是"发出去之前我想确认/切换一下"的即时设置，放在离输入框最近的地方
  /// 才有意义；埋在信息面板的两层里，用户根本不会想到去那儿切。
  ///
  /// 为 null 时**不渲染这个胶囊**（宿主没给能力就不画死按钮）。
  final String? policyLabel;

  /// 点权限胶囊。为 null 时同样不渲染。
  final VoidCallback? onPickPermission;

  /// 「去设置建一条」——面板空态里的逃生口。
  ///
  /// 为什么需要：快捷指令面板以前在"本地和网关都空"时直接退化成只有斜杠命令的
  /// 老面板，一句解释都没有。用户建完指令回到对话页看不到它（缓存没刷新），
  /// 打开面板又只有一堆 `/命令`，结论自然是"这功能没地方用"。
  /// 为 null 时不画这个按钮（不让用户点一个没反应的入口）。
  final VoidCallback? onOpenSnippets;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  // ---- 父级状态：同名私有 getter，让搬过来的代码可以一字不改 ----
  TextEditingController get _inputController => widget.inputController;
  FocusNode get _inputFocusNode => widget.inputFocusNode;
  List<PendingAttachment> get _pendingAttachments => widget.pendingAttachments;
  ComposerNoticeBus get _noticeBus => widget.noticeBus;
  bool get _queueExpanded => widget.queueExpanded;

  // ---- 父级动作：保持原签名转调，让搬过来的调用点一字不改 ----
  void _toast(String msg) => widget.onToast(msg);
  void _sendMessage(DshService dsh) => widget.onSend();
  void _showAttachSheet(DshService dsh) => widget.onPickAttach();
  void _showCommandSheet(DshService dsh) => widget.onPickCommand();
  void _showModelSwitchSheet(BuildContext context, DshService dsh) =>
      widget.onPickModel();
  void _toggleQueueExpanded() => widget.onToggleQueueExpanded();
  void _removePendingAttachment(PendingAttachment attachment) =>
      widget.onRemoveAttachment(attachment);
  void _editQueueRow(DshService dsh, QueueItem row) =>
      widget.onEditQueueRow(row);
  void _removeQueueRow(DshService dsh, QueueItem row) =>
      widget.onRemoveQueueRow(row);
  void _steerQueueRow(DshService dsh, QueueItem row) =>
      widget.onSteerQueueRow(row);
  void _onNoticeAction(DshService dsh, ComposerNotice notice) =>
      widget.onNoticeAction(notice);

  /// 输入卡片那条提示（`ComposerNotice`）的**本地**写入器（Phase 4.5）。
  ///
  /// [fix 2026-10-17] timer 已收敛到 [ComposerNoticeBus]：父级与 composer 共用
  /// 同一条总线，任何一侧 show() 都取消上一条的定时器 —— 双 Timer 竞态
  /// （排队回执把语音错误提前抹掉）不再可能。
  ///
  /// 语义统一在这一处：会话链路里的**业务失败**（语音起不来、录音被引擎掐断、
  /// 没听清）全部改走这里 —— 它挨着输入框，用户写的东西还在，失败必须和它并排
  /// 待 3~5 秒，而不是从屏幕底部滑过一条 2 秒就消失的 SnackBar。
  void _showNotice(
    String text, {
    bool ok = false,
    NoticeAction action = NoticeAction.none,
    String? undoItemId,
    Duration duration = const Duration(seconds: 4),
  }) {
    // ⚠️ mounted 守卫保留：语音的迟到回调仍会在本 widget dispose 之后到达，
    // 但 noticeBus 由父级所有，父级 dispose 时总线也随之销毁 —— 守卫仍然必要。
    if (!mounted) return;
    _noticeBus.show(
      text,
      ok: ok,
      action: action,
      undoItemId: undoItemId,
      duration: duration,
    );
  }

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

  // ---- 一次性引导：长按输入框不再录音（Phase 4.6 收尾）----
  //
  // v1.27 把长按说话的入口收窄到麦克风按钮之后，老用户最顺手的那个动作
  // （空框里按住输入区）变成"什么都没发生"。不讲一句，他们会以为语音坏了。
  // 这条引导只弹一次，之后永不再提 —— 目标是纠正一次误解，不是每次长按都唠叨。

  /// 持久化键：`true` = 已经弹过。缺失/false = 还没弹。
  static const String _holdHintPrefsKey = 'dsh_hint_hold_mic_v1';

  /// 进程内"已弹过"标记。
  ///
  /// `SharedPreferences` 拿不到（纯 Dart 测试、平台通道缺失）时它是唯一防线；
  /// 即便拿得到，它也省掉"每次长按都异步读一次盘"。
  static bool _holdHintShown = false;

  /// 长按判定阈值。比 `kLongPressTimeout`（500ms）稍长：宁可和系统的选词晚一点
  /// 并存，也不要在"点按"的边界上误弹。
  static const Duration _fieldLongPressThreshold = Duration(milliseconds: 600);

  /// 手指移动超过这个距离就不算长按（拖选、滑动翻页）。
  static const double _fieldLongPressSlop = 18;

  /// 输入框上的长按探针。
  ///
  /// ⚠️ 用 `Listener` 的**原始指针事件**，不是 `GestureDetector.onLongPress`：
  /// 后者会进手势竞技场，而这个竞技场里已经坐着 EditableText 的选词/粘贴识别器
  /// —— 本文件的历史教训就是"跟它抢长按"抢不过、还两败俱伤（见 `_buildTextArea`
  /// 上方那段历史）。`Listener` 不参加竞技场、不消费事件，纯旁观：计时到了提示
  /// 一句，一个指针事件都不改道，所以这次长按照样能给到系统做选词。
  Timer? _fieldLongPressProbe;
  Offset? _fieldDownAt;

  /// 长按探针命中：说一句"麦克风在右边"。
  Future<void> _onFieldLongPress() async {
    _fieldLongPressProbe = null;
    if (_holdHintShown) return;
    // 录音/确认态说明用户已经找对了入口（确认态里长按输入框是在选词改字），
    // 别再教一遍 —— 也**不要**把唯一的那次机会用掉。
    if (!mounted || _holdPhase != _HoldTalkPhase.idle) return;
    if (_inputController.text.trim().isNotEmpty) return;
    _holdHintShown = true;
    final prefs = await _prefsOrNull();
    if (!mounted) return;
    if (prefs?.getBool(_holdHintPrefsKey) ?? false) return;
    // 轻提示（说完就算），刻意**不**走 `_showNotice`：那条是给"你刚写的那段话
    // 去哪了"这类需要用户处理的结果用的，一条教学文案占着它会把真正的失败挤掉。
    _toast('按住右下角 🎤 说话');
    final write = prefs?.setBool(_holdHintPrefsKey, true);
    if (write != null) unawaited(write);
  }

  /// 取 `SharedPreferences`，取不到就用 null 降级。
  ///
  /// 刻意不复用 `StorageService`：那个文件正被并行改造，而这里只需要一个布尔
  /// 开关 —— 为一行引导去碰别人正在动的 API 不划算（也不需要它的加密/迁移逻辑）。
  Future<SharedPreferences?> _prefsOrNull() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  void _onFieldPointerDown(PointerDownEvent event) {
    _fieldLongPressProbe?.cancel();
    _fieldDownAt = event.position;
    // 有内容时长按是选词/粘贴 —— 会用到那个手势的人已经知道怎么输入了。
    if (_holdHintShown || _inputController.text.trim().isNotEmpty) return;
    _fieldLongPressProbe = Timer(_fieldLongPressThreshold, _onFieldLongPress);
  }

  void _onFieldPointerMove(PointerMoveEvent event) {
    final start = _fieldDownAt;
    if (start == null) return;
    if ((event.position - start).distance > _fieldLongPressSlop) {
      _fieldLongPressProbe?.cancel();
      _fieldLongPressProbe = null;
    }
  }

  void _onFieldPointerEnd(PointerEvent event) {
    _fieldLongPressProbe?.cancel();
    _fieldLongPressProbe = null;
    _fieldDownAt = null;
  }

  @override
  void initState() {
    super.initState();
    // 探测语音识别能力（含麦克风权限）。放在 initState 而不是 build：这是
    // 一次性异步探测，挂在 build 上会每次重建都重跑一遍。
    //
    // 刻意**不阻塞界面**：探测慢或失败都不该挡住聊天，失败时按钮显示为禁用。
    VoiceInputService.instance.init().then((ok) {
      if (mounted) setState(() => _voiceSupported = ok);
    });
    unawaited(_loadLocalSnippets());
  }

  // ---- 本地快捷指令 (Phase 5.4) ----
  //
  // 手机上的、不经过网关的提示词模板（设置页里维护）。它们和 `dsh.snippets`
  // （网关下发、只读）是**两个来源**，刻意不同步；合并展示时本地的排前面 ——
  // 自己写的那几条几乎总是更常用。
  //
  // 在 initState 里异步加载一次，**绝不在 build 里 await**：输入卡片每一帧都要
  // 重建（流式消息推进时尤其频繁），一次 await 就等于把打字区挂起一帧。
  List<LocalSnippet> _localSnippets = const [];

  /// 模板/命令面板是否已经打开（防止连续按键把弹层叠起来）。
  bool _snippetSheetOpen = false;

  /// 从本地存储读一份快捷指令。
  ///
  /// **[fix 2026-10-18] 必须在面板打开时再读一次，不能只靠 initState 那一次。**
  /// 真实缺陷：本组件常驻在 IndexedStack 里（`main_shell` 的三个一级页都保活），
  /// State 永不复建，于是 initState 读到的是**App 启动那一刻**的快照。用户在
  /// 「设置 → 快捷指令」里新建/删除之后回到对话页，面板里看到的还是旧列表 ——
  /// 新建的看不到、删掉的还在。用户的原话是"快捷指令没地方使用"，根因就在这里。
  ///
  /// 读失败时**保留现有列表**（不清空）：一次瞬时 IO 失败不该让用户以为自己的
  /// 指令没了。
  Future<void> _loadLocalSnippets() async {
    List<LocalSnippet> list;
    try {
      list = await StorageService.loadLocalSnippets();
    } catch (_) {
      // 读不出来就维持现状：本地条目是**增量**能力，它读不出来不该影响网关下发
      // 的那批模板与斜杠命令，也不该在输入区弹一个用户无法处理的错误。
      return;
    }
    if (!mounted) return;
    setState(() => _localSnippets = list);
  }

  @override
  void dispose() {
    _holdTick?.cancel();
    _holdWatchdog?.cancel();
    // notice 的 timer 归总线（父级所有）—— 这里不再持有一个本地副本。
    _fieldLongPressProbe?.cancel();
    // 正在录音时被销毁（切会话/返回）：必须主动取消识别，否则麦克风会被一直
    // 占着，下一次识别会以"被其他应用占用"失败。
    if (_holdPhase != _HoldTalkPhase.idle) {
      VoiceInputService.instance.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _buildInputBar(widget.dsh);
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
                    a is PendingImage
                        ? Icons.image_outlined
                        : Icons.insert_drive_file_outlined,
                    size: 15,
                    color:
                        a is PendingImage ? context.c.accent : context.c.purple,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      a.name,
                      style:
                          TextStyle(fontSize: 12, color: context.c.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    a.sizeLabel,
                    style: TextStyle(
                        fontSize: 10.5, color: context.c.textTertiary),
                  ),
                  const SizedBox(width: 2),
                  InkWell(
                    onTap: () => _removePendingAttachment(a),
                    borderRadius: BorderRadius.circular(11),
                    // [fix 2026-10-17] 删除是破坏性动作，命中区补到 32px
                    //（此前 ≈21px，误触率高；再大会挤压附件行布局，
                    // 44dp 由整行高度兜底）。
                    child: SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(
                        child: Icon(Icons.close_rounded,
                            size: 15, color: context.c.textTertiary),
                      ),
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
    final holding = _holdPhase == _HoldTalkPhase.recording;

    // ---- 长按说话的唯一入口（v1.27）----
    //
    // 以前是"空框时整块输入区 = 长按热区"，现在收窄到这枚按钮上：
    //   * 文本区恢复标准 TextField 行为（长按选词、系统工具条）；
    //   * 麦克风按钮**不在** EditableText 的命中路径里，长按识别器与它不冲突，
    //     所以这里可以放心用 GestureDetector + onLongPressStart/End/Cancel
    //     （InkWell 只有 onLongPress，拿不到"松手"和"被打断"两个时机）。
    //   * 三个回调**始终非空**、在内部判状态：手势进行中把回调置 null 会牵动
    //     识别器生命周期，等于把松手事件自己弄丢（老版本踩过一次）。
    return Tooltip(
      message:
          unavailable ? '语音输入不可用（长按查看诊断）' : (holding ? '松开结束录音' : '点按听写，按住说话'),
      child: GestureDetector(
        // 这个 key 原来在"整块输入区的长按层"上，现在标在真正承载长按识别器的
        // 那枚按钮上 —— 语义从"输入区可长按"变成"麦克风可长按"。
        key: const ValueKey('chat-hold-layer'),
        behavior: HitTestBehavior.opaque,
        // 不可用时长按 = 诊断：那种状态下录音本来就不可能成功，把"点了没反应"
        // 拆成可判读的几条实测结果更有价值。
        onLongPressStart: (_) {
          if (unavailable) {
            // 不可用时长按 = 诊断：那种状态下录音本来就不可能成功，把"点了没
            // 反应"拆成可判读的几条实测结果更有价值。
            _showVoiceDiagnose();
          } else {
            _beginHoldTalk(dsh);
          }
        },
        onLongPressEnd: (_) {
          if (_holdPhase == _HoldTalkPhase.recording) _endHoldTalk(dsh);
        },
        onLongPressCancel: () {
          if (_holdPhase == _HoldTalkPhase.recording) _cancelHoldTalk();
        },
        child: InkWell(
          // 点按仍保留"点一下听写、再点一下停"的老行为（InkWell 的 tap 与上面
          // 的长按在竞技场里互斥：按住超过阈值就走长按，快速点走 tap）。
          onTap: () => listening ? _stopVoice(dsh) : _startVoice(dsh),
          borderRadius: BorderRadius.circular(20),
          // 44x44：Material 推荐的最小可触达尺寸。36px 在手机上确实偏小，
          // 语音又是个高频入口（用户报"按钮有点小"）。
          child: SizedBox(
            width: 44,
            height: 44,
            child: listening
                ? Padding(
                    padding: const EdgeInsets.all(10),
                    child: CircularProgressIndicator(
                        strokeWidth: 2.2, color: context.c.danger),
                  )
                : Center(
                    child: Icon(
                      unavailable ? Icons.mic_off_rounded : Icons.mic_rounded,
                      size: 24,
                      color: holding || listening
                          ? context.c.danger
                          : (unavailable
                              ? context.c.textTertiary
                              : context.c.textSecondary),
                    ),
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

  Future<void> _startVoice(DshService dsh) async {
    final ok = await VoiceInputService.instance.start(
      // 中间结果是累积的，必须整段替换。
      onPartial: (text, _) => _applyVoiceText(text, dsh),
      onFinal: (text) => _applyVoiceText(text, dsh),
      // [fix 2026-10-12] 引擎自动结束（时长上限/静音）：立刻灭掉聆听态，
      // 以前按钮会一直亮着"聆听中"但引擎早已停了，说的内容也不会再进来。
      onAutoStopped: mounted
          ? (_) {
              if (mounted) setState(() => _voiceListening = false);
            }
          : null,
      onError: (msg) {
        if (mounted) setState(() => _voiceListening = false);
        // 业务失败 → 输入卡片那条提示（Phase 4.5）。重试入口就是右边那枚麦克风
        // 本身，所以不带动作按钮 —— 画一个"重试"按钮只会和它并排重复同一件事。
        _showNotice(msg);
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
    // 听写回调也是异步回链：切走页面后平台仍可能补一条 final，写 controller 会
    // 命中"notifyListeners after dispose"。
    if (!mounted) return;
    if (text.trim().isEmpty) return;
    // [fix 2026-10-17] 不再无条件整段替换：用户先打了半句再点听写，草稿不能
    // 被识别结果静默覆盖。已有内容时以"空格分隔追加"，与长按说话的追加语义
    // 一致；识别结果为空时什么都不动。
    final existing = _inputController.text;
    final merged = existing.trim().isEmpty ? text : '${existing.trimRight()} ${text.trim()}';
    _inputController.text = merged;
    _inputController.selection = TextSelection.collapsed(offset: merged.length);
    // 语音内容同样要进草稿，否则进程被杀后说的这段话会丢。
    dsh.updateDraft(merged);
  }

  // ---------------------------------------------------------- 长按说话 --
  //
  // 长按生效的**唯一**条件：输入框为空（见下方 builder 里的 holdEnabled）。
  // 一旦有文字，长按必须还给系统原本的"选中/粘贴"——抢走它会让编辑长文本
  // 变得很难用。已有文字时想继续用语音，右边的麦克风按钮（点按）仍然在。

  Future<void> _beginHoldTalk(DshService dsh) async {
    if (_holdPhase != _HoldTalkPhase.idle) return;
    // 进录音立刻收键盘：确认态里点「重录」时键盘是弹着的，而接下来那块高度要
    // 给"正在聆听"，键盘留着只会把面板顶出去。
    _inputFocusNode.unfocus();
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
    // 也可能来了但 stop() 挂在平台回调上。30s 内毫无动静才强制收尾，把输入框
    // 还回去。[fix 2026-10-17] 收到 partial 时顺延（重挂 30s）：正常的长句
    // 识别会持续吐 partial —— 恒定 30s 会把说到一半的正常录音强切并误报
    // "没有回应"。看门狗现在只拦"彻底没动静"的服务。
    void armWatchdog() {
      _holdWatchdog?.cancel();
      _holdWatchdog = Timer(const Duration(seconds: 30), () {
        if (!mounted || _holdPhase != _HoldTalkPhase.recording) return;
        _cancelHoldTalk();
        if (mounted) {
          // 异常收尾也是失败：留在输入区那条提示里（用户此刻正盯着输入框）。
          _showNotice('录音 30 秒没有回应，已恢复输入框 · 请再按住 🎤 说一次');
        }
      });
    }
    armWatchdog();

    final ok = await VoiceInputService.instance.start(
      // [fix 2026-10-12] 引擎自动结束（时长上限/静音超时/内部断句）：长按模式
      // 下立刻进入确认态，用已有的 partial 文本收尾。以前这条路径没有任何
      // 通知 —— 引擎停了 UI 还在"聆听"，用户松手时收到"没有听清"，说过的话
      // 全部丢失。这正是"说一大段 → 未识别到"的根源。
      onAutoStopped: mounted
          ? (reason) => _finishHoldTalk(dsh, autoStopped: reason)
          : null,
      onPartial: (text, _) {
        if (!mounted) return;
        armWatchdog(); // [fix 2026-10-17] 有动静就顺延看门狗
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
        // 录音起不来是业务失败（Phase 4.5）：贴着输入框说，别让它从底部滑走。
        _showNotice(msg);
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
    _holdAwaitingFinal = true;
    // [fix 2026-10-11] The watchdog must outlive stop(): if stop() hangs on a
    // platform callback (the exact bug c810842 fixed), cancelling it here
    // leaves _holdPhase stuck at recording with nothing to fire — gestures are
    // swallowed and the composer becomes untappable again. Timeout-stop first,
    // and only then release the watchdog.
    try {
      await VoiceInputService.instance
          .stop()
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // stop() failed or timed out — force-cancel recognition and fall through
      // so the UI never stays stuck in the recording phase.
      VoiceInputService.instance.cancel();
    }
    _holdWatchdog?.cancel();
    if (!mounted) return;
    await _finishHoldTalk(dsh);
  }

  /// [fix 2026-10-12] 录音收尾的统一出口：把已识别文本送进"重录/发送"确认态。
  ///
  /// 两条路径共用：用户松手（_endHoldTalk）与引擎自动结束（onAutoStopped，
  /// 时长上限/静音超时）。autoStopped 非空时 toast 说明原因 —— 用户需要知道
  /// "引擎替我停了"，而不是对着还亮着的聆听界面发呆。
  ///
  /// 关键语义：**只要有 partial 文本就进确认态，不再报"没有听清"**。引擎被
  /// 掐断时已识别的部分比一句"重来"有价值得多；真正一个字都没有才回 idle。
  ///
  /// ⚠️ 这里刻意**不做任何 sleep/延迟等待**：迟到的 final 由既有的
  /// `_holdAwaitingFinal` 机制补写进输入框（onFinal 分支），不需要在这里等它。
  /// 之前试过"空文本先等 300ms 再放弃"，但在 widget 测试的 fake clock 里
  /// pumpAndSettle 推不动无 frame 调度的 timer，启动失败用例会卡在录音态。
  Future<void> _finishHoldTalk(DshService dsh, {String? autoStopped}) async {
    // 本方法由两条**异步回链**调用（松手后 await stop()、以及引擎的
    // onAutoStopped），两者都可能在 dispose 之后才到 —— 下面第一句就是 setState。
    if (!mounted) return;
    if (_holdPhase != _HoldTalkPhase.recording) return;
    _holdTick?.cancel();
    _holdWatchdog?.cancel();

    final text = _holdText.trim();
    if (text.isEmpty) {
      // 一个字都没有：直接回 idle。松手后若引擎的 final 迟到，onFinal 分支
      // 会因为 _holdAwaitingFinal 仍为 true 而把它补进输入框 —— 文本不丢。
      setState(() {
        _holdPhase = _HoldTalkPhase.idle;
        _holdText = '';
      });
      // 「没听清」是业务失败：走输入卡片那条提示（贴着想说的那句话）。
      _showNotice(autoStopped != null
          ? '引擎提前结束且没有识别到内容（$autoStopped）· 请再按住 🎤 说一次'
          : '没有听清 · 请再按住 🎤 说一次');
      return;
    }

    setState(() {
      _holdPhase = _HoldTalkPhase.confirm;
      _inputController.text = text;
      _inputController.selection = TextSelection.collapsed(offset: text.length);
    });
    // Phase 4.6：确认态 =「你刚说的这段话可以改」。直接把键盘叫起来，光标已经
    // 停在文末（上面那句 selection），用户不必再点一下输入框才开始改字。
    _focusConfirmInput();
    dsh.updateDraft(text);
    if (autoStopped != null && mounted) {
      // 信息类（内容是好的，只是引擎替用户停了）：走成功态的提示，颜色不报警。
      _showNotice('引擎到达时长上限自动停止 · 内容已保留，可直接改或发送',
          ok: true, duration: const Duration(seconds: 5));
    }
  }

  /// 确认态自动聚焦（Phase 4.6）。
  ///
  /// 两段式是必须的，不是保险起见：
  ///
  /// * **同步那一次**覆盖"焦点节点已经挂在树上"的常规路径（比如手动再进确认态）。
  /// * **post-frame 那一次**覆盖真正的新路径：录音态期间文本框是被"正在聆听"面板
  ///   整块替换掉的（见 `_buildTextArea`），切回 confirm 的那一帧 TextField 是全新
  ///   构建的，FocusNode 还没 attach。直接 `requestFocus()` 在这种时刻不可靠 ——
  ///   表现就是"重录/发送按钮出来了，但键盘没弹"。
  ///
  /// ⚠️ 这里**不用** `Future.delayed`/sleep：本文件上方的长按收尾注释记着同一个
  /// 教训（fake clock 里 `pumpAndSettle` 推不动无 frame 调度的 timer）。post-frame
  /// callback 是跟着帧走的，测试里一次 pump 就会执行。
  void _focusConfirmInput() {
    _collapseSelectionToEnd();
    _inputFocusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _holdPhase != _HoldTalkPhase.confirm) return;
      if (_inputFocusNode.hasFocus) return;
      // 只有"还没拿到焦点"才重设光标：用户若已经开始改字，不动他的选区。
      _collapseSelectionToEnd();
      _inputFocusNode.requestFocus();
    });
  }

  void _collapseSelectionToEnd() {
    final text = _inputController.text;
    _inputController.selection = TextSelection.collapsed(offset: text.length);
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
    // 发送后必须收键盘：输入框随即被清空，键盘还杵在那里会让人以为卡住了
    // （这是 Phase 4.6 明确的验收项）。
    _inputFocusNode.unfocus();
    setState(() => _holdPhase = _HoldTalkPhase.idle);
    if (text.trim().isEmpty) return;
    _sendMessage(dsh); // 返回 void，别 await
  }

  // -------------------------------------------------------- 状态胶囊行 --

  /// 按优先级算出当前所有待办（**顺序即优先级**）。
  ///
  /// 空列表 = 输入卡片上方一行都不占（正常态就该是安静的）。
  List<_StatusRow> _statusRows(DshService dsh) {
    final rows = <_StatusRow>[];

    // 1) 待审批：**不再进胶囊行**（[fix 2026-10-17]）。
    //
    //    审批卡是钉在输入框正上方的固定 dock，它本来就一直可见；胶囊再报一遍
    //    "有 1 个操作在等你批准 · 去处理"，加上（已删掉的）顶部横幅，同一件事
    //    在一屏里出现了三次。真机截图里那排红色胶囊看起来像输入框的一部分，
    //    反而让人以为输入框坏了。
    //
    //    审批的可见性交给卡片本身；胶囊行留给**不会常驻在屏幕上**的东西：
    //    上下文告警、待回答提问、排队消息、以及"正在跑"。

    // 2) 上下文告警：**只在跨过阈值、且是实时读数时**出现。
    //
    //    快照读数（会话不在内存里）不催用户做不可逆的决定 —— "新开会话"是不可
    //    撤销的，拿几小时前的数字去催它是错的。
    final stats = dsh.sessionStats;
    final fraction = stats?.contextFraction;
    if (stats != null &&
        stats.isLive &&
        fraction != null &&
        fraction >= SessionStatusStrip.pressureCriticalThreshold) {
      final pct = (fraction * 100).round();
      rows.add(_StatusRow(
        kind: _StatusKind.contextPressure,
        // 这个 key 被 `session_insights_test` 用来钉"≥85% 才出现"。
        key: const ValueKey('context-pressure-row'),
        icon: Icons.warning_amber_rounded,
        label: '上下文已用 $pct%，继续下去可能被截断',
        tone: context.c.danger,
        actionLabel: '新开会话',
        onAction: () => dsh.createNewSession(),
      ));
    }

    // 3) 待提问：同样是阻塞，但它是"可以稍后答"的那种，所以是 warning。
    final questions = dsh.currentSessionQuestions.length;
    if (questions > 0) {
      rows.add(_StatusRow(
        kind: _StatusKind.question,
        icon: Icons.help_outline_rounded,
        label: questions == 1 ? '有 1 个问题等你回答' : '有 $questions 个问题等你回答',
        tone: context.c.warning,
        actionLabel: widget.onRevealBlocked == null ? '' : '去回答',
        onAction: widget.onRevealBlocked,
      ));
    }

    // 4) 排队 N 条。三种状态都必须能区分（空 / 未知 / 读失败），否则"路由坏了"
    //    会被静默当成"没有排队消息"（生产上真的发生过）。
    final queued = dsh.queueItems.length;
    if (queued > 0) {
      rows.add(_StatusRow(
        kind: _StatusKind.queue,
        icon: Icons.queue_rounded,
        label: '$queued 条排队中',
        tone: context.c.accent,
        actionLabel: _queueExpanded ? '收起' : '展开',
        // 展开/收起是这张卡片自己的状态，所以由这里直接切换。
        actionKey: const ValueKey('queue-dock-toggle'),
        onAction: _toggleQueueExpanded,
      ));
    } else if (dsh.queueKnown == false) {
      rows.add(_StatusRow(
        kind: _StatusKind.queue,
        icon: Icons.queue_rounded,
        label: dsh.queueError.isEmpty ? '队列状态未知' : dsh.queueError,
        tone:
            dsh.queueError.isEmpty ? context.c.textSecondary : context.c.danger,
        actionLabel: '重试',
        onAction: dsh.fetchQueue,
      ));
    } else if (dsh.queueError.isNotEmpty) {
      rows.add(_StatusRow(
        kind: _StatusKind.queue,
        icon: Icons.queue_rounded,
        label: dsh.queueError,
        tone: context.c.danger,
        actionLabel: '重试',
        onAction: dsh.fetchQueue,
      ));
    }

    // 5) 运行中说明：把"你发的消息会在本轮结束后自动发送"讲在打字之前。
    //    没有按钮 —— 它不是待办，是背景说明；排在最后正因为它最不重要。
    if (dsh.isSessionRunning) {
      rows.add(_StatusRow(
        kind: _StatusKind.running,
        icon: Icons.info_outline_rounded,
        label: '本轮执行中 · 你发的消息会在本轮结束后自动发送',
        tone: context.c.textSecondary,
      ));
    }

    // 用户手动展开了队列时，把队列提到第一位：否则一旦有审批/告警插队，
    // "收起"按钮会被轮换走，展开的列表就再也收不回去了。
    if (_queueExpanded) {
      final idx = rows.indexWhere((r) => r.kind == _StatusKind.queue);
      if (idx > 0) rows.insert(0, rows.removeAt(idx));
    }
    return rows;
  }

  /// 状态胶囊行：高 32、横向可滚、**同一时刻只显示一条**。
  Widget _buildStatusBar(DshService dsh, List<_StatusRow> rows) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.s),
      child: Row(
        children: [
          // 横向滚动而不是省略号截断：手机上横向空间永远不够，而"上下文已用
          // 94%，继续下去可能被截断"砍掉后半句就没有信息了。
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: _buildStatusPill(rows.first),
            ),
          ),
          if (rows.length > 1) _buildStatusMoreButton(dsh),
        ],
      ),
    );
  }

  Widget _buildStatusPill(_StatusRow row) {
    return Container(
      key: row.key,
      // 高度 32 是**下限**而不是固定值：系统字号 1.3x 时文字会顶出去，那时宁可
      // 让这一行变成 36 高，也不能让它报 overflow。
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
      decoration: BoxDecoration(
        color: context.c.surfaceMuted,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: row.tone.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(row.icon, size: 13, color: row.tone),
          const SizedBox(width: AppSpace.s),
          Text(
            row.label,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
                fontSize: AppText.caption, color: context.c.textSecondary),
          ),
          if (row.actionLabel.isNotEmpty) ...[
            const SizedBox(width: AppSpace.s),
            InkWell(
              key: row.actionKey,
              onTap: row.onAction,
              borderRadius: BorderRadius.circular(12),
              // [fix 2026-10-17] 触控目标补到 ≥32px 视觉 / 44dp 命中区：
              // 此前 vertical 4 ≈21px 高，「新开会话」还是不可逆动作。
              child: Container(
                constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  row.actionLabel,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: AppText.caption,
                    fontWeight: FontWeight.w700,
                    color: row.onAction == null
                        ? context.c.textTertiary
                        : row.tone,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 尾部「⋯」：把被轮换掉的那些待办一次性列出来。
  Widget _buildStatusMoreButton(DshService dsh) {
    return Tooltip(
      message: '全部待办',
      child: InkWell(
        key: const ValueKey('composer-status-more'),
        onTap: () => _showStatusSheet(dsh),
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 30,
          height: 32,
          child: Center(
            child: Icon(Icons.more_horiz_rounded,
                size: 18, color: context.c.textTertiary),
          ),
        ),
      ),
    );
  }

  /// 「⋯」弹层：列出全部待办，每条一行、右侧带各自的动作。
  Future<void> _showStatusSheet(DshService dsh) async {
    final rows = _statusRows(dsh);
    if (rows.isEmpty) return;
    await showModalBottomSheet<void>(
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
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text(
                '全部待办',
                style: TextStyle(
                  fontSize: AppText.heading,
                  fontWeight: FontWeight.bold,
                  color: sheetCtx.c.textPrimary,
                ),
              ),
            ),
            for (final row in rows)
              ListTile(
                dense: true,
                leading: Icon(row.icon, size: 18, color: row.tone),
                title: Text(
                  row.label,
                  style: TextStyle(
                      fontSize: AppText.body, color: sheetCtx.c.textPrimary),
                ),
                trailing: row.actionLabel.isEmpty
                    ? null
                    : TextButton(
                        onPressed: () {
                          Navigator.of(sheetCtx).pop();
                          row.onAction?.call();
                        },
                        child: Text(
                          row.actionLabel,
                          style: TextStyle(
                              fontSize: AppText.body, color: row.tone),
                        ),
                      ),
              ),
            const SizedBox(height: AppSpace.m),
          ],
        ),
      ),
    );
  }

  /// 打开会话信息面板：状态条的任意一段、卡片的"查看全部"、以及输入框上方的
  /// 上下文告警都走这里。
  ///
  /// 打开时先发一次第三档加载（`jobs` + `schedules` —— 全链路最贵的两个请求，
  /// 只在用户明确要看的时候拉）；面板自己也会在首帧后调一次 `onRefresh`，
  /// 所以这里不重复发，只负责把"看过产出"这件事记下来。
  /// 打开本会话的轨迹面板（v1.22）：轮 → 事件的时间线。
  ///
  /// 数据从 `dsh.messages` **当场重建**，并且让弹层在自己的路由里订阅一次
  /// DshService —— 正在跑的那一轮会随流式事件推进。这和 `_openSessionInfo`
  /// 是同一条理由：会话域的数据随时在变，冻住打开那一刻的快照只会让人以为卡死了。
  ///
  /// token 传的是 `lastTurnTokens`：引擎只上报**本轮**的增量，历史轮没有数据源，
  /// 面板对拿不到的那些轮显示 `—`（见 `models/trajectory.dart` 的诚实规则 2）。

  Widget _buildInputBar(DshService dsh) {
    // 待办在 build 期算一次：胶囊行和「⋯」弹层用的是同一份快照，避免两处给出
    // 不一致的条数。
    final statusRows = _statusRows(dsh);
    // [v1.27] 键盘抬升由这里负责：`ChatView` 的 Scaffold 显式关掉了
    // `resizeToAvoidBottomInset`，所以 viewInsets 不会被框架自动消化 ——
    // 内层再抬一次就会与 `main_shell` 那一层相互博弈，输入框下方空出一条导航栏
    // 高度的白带（用户报的就是这个）。
    //
    // ⚠️ `chat-input-bar` 这个 key 必须留在**内层** Container 上：测试量的是
    // "它的底边紧贴键盘顶边"，也就是这个 Padding 之后的位置。
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
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
                // ⚠️ 这几个槽位用 KeyedSubtree **固定存在**（没内容时塞 SizedBox.shrink）。
                //
                // 不是为了省一点布局开销，而是为了让整棵子树的形状在长按录音期间
                // 保持不变：如果某个槽位中途出现/消失，下面的麦克风按钮在 Column 里
                // 的索引就会变，Flutter 会把它当成新元素重建 —— 承载长按识别器的
                // GestureDetector 随之销毁，`onLongPressEnd` 永远不会来，松手之后
                // 一直卡在"正在聆听"。老版本用一层常驻手势层绕过了这个问题，
                // 新版本靠"槽位固定 + key 稳定"解决。
                KeyedSubtree(
                  key: const ValueKey('composer-slot-notice'),
                  // 发送回执（瞬态，3 秒自动消失）：**保留独立一行**，不进胶囊轮换。
                  // 它讲的是"刚刚那一下发生了什么"，胶囊讲的是"现在攒了些什么"，
                  // 两者并存在语义上不冲突。
                  child: _buildNotice(dsh),
                ),
                KeyedSubtree(
                  key: const ValueKey('composer-slot-status'),
                  // 状态胶囊行（v1.27）：原来这里的六层常驻内容（上下文告警 / 运行
                  // 提示 / 队列 dock / 模板 chips）全部收进这一行，按优先级只显示
                  // 一条，其余进尾部「⋯」。见 `_statusRows` 的优先级说明。
                  child: statusRows.isEmpty
                      ? const SizedBox.shrink()
                      : _buildStatusBar(dsh, statusRows),
                ),
                KeyedSubtree(
                  key: const ValueKey('composer-slot-queue'),
                  // 用户手动展开的队列列表。**只在展开时占位** —— 折叠态就是胶囊
                  // 那一行，这也是"常驻最多两行"能成立的原因。
                  child: _queueExpanded
                      ? _buildQueueDock(dsh)
                      : const SizedBox.shrink(),
                ),
                KeyedSubtree(
                  key: const ValueKey('composer-slot-attach'),
                  // 待发附件也放进卡片内 —— 它与"这条消息要发什么"是同一件事，
                  // 摆在卡片外会显得是两个不相干的东西。
                  child: _pendingAttachments.isEmpty
                      ? const SizedBox.shrink()
                      : _buildPendingAttachments(),
                ),

                // 输入区（v1.27）：标准 TextField。**长按选词、系统工具条全部回来**
                // —— 以前这里是"空框时整块盖一层 opaque 手势层用来录音"，代价是
                // 文本区永远拿不到长按（选词/粘贴），而且触发点也不符合直觉：
                // 谁会想到"按住输入框"是录音？
                //
                // ⚠️ 历史坑，保留以免有人改回去：
                //
                // 1) 为什么当初是"盖一层"而不是给 TextField 套 GestureDetector：
                //    EditableText **内部**也有一个长按识别器（选词 + 弹工具条），
                //    在手势竞技场里它比外层先注册、会赢 —— 实测长按有时能录音、
                //    有时毫无反应，关掉 enableInteractiveSelection 也压不住。
                //    盖一层不透明的层，指针根本到不了下面的 EditableText。
                //
                // 2) 为什么录音态当初**不换掉这一层**、只换它的内容：
                //    长按开始后如果把承载识别器的 widget 从树上摘掉，识别器会被
                //    一起销毁 —— `onLongPressEnd` 永远不会触发，于是松手之后一直
                //    卡在"正在聆听"（真机上同样会发生）。
                //
                // 🆕 v1.27 起：**只挂在麦克风按钮**上（见 `_buildMicButton`），
                //    上面两条都不再适用 —— 麦克风按钮不在 EditableText 的命中路径
                //    里，两个识别器不会进同一个竞技场，TextField 的长按可以完整地
                //    还给系统。录音态把文本框整块换成"正在聆听"面板也是安全的：
                //    承载识别器的是那枚按钮（它一直在树上），不是文本框。
                //    **请不要改回"整块输入区可长按"** —— 那会让第 1 条的缺陷原样复发。
                _buildTextArea(dsh),

                if (_holdPhase == _HoldTalkPhase.confirm)
                  // 确认态：识别结果已经在输入框里（可直接改字），这里给两个动作。
                  _buildHoldConfirmRow(dsh)
                else
                  // ⚠️ 录音中**也必须**保留这一行，不能写成 `else if (idle)`。
                  // 麦克风按钮就在这一行里，而它正是承载长按识别器的那一层 ——
                  // 录音时把它从树上摘掉，识别器会一起销毁，`onLongPressEnd`
                  // 永远不会来，于是松手之后一直卡在"正在聆听"（实测踩过）。
                  // 旧实现靠"整块输入区的常驻手势层"绕过这个问题，新实现靠
                  // "这枚按钮从一开始到松手都在"。
                  KeyedSubtree(
                      key: const ValueKey('composer-action-row'),
                      child: _buildActionRow(dsh)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 文本框 / 录音态面板。
  ///
  /// 两者互斥：录音时把整块换掉是这个版本才**安全**的做法 —— 承载长按识别器的
  /// 是麦克风按钮（见 `_buildMicButton`），它不在这块里，所以替换不会打断手势。
  Widget _buildTextArea(DshService dsh) {
    if (_holdPhase == _HoldTalkPhase.recording) {
      // 录音态点按面板任意处 = 取消（自救出口）。语音服务偶发挂死（listen 超时 /
      // 平台不回调）时 _holdPhase 会被卡在 recording —— 30s 看门狗之外还必须
      // 有一个当场能按到的出口，否则用户表面上"输入框点不动、键盘弹不出来"。
      return GestureDetector(
        key: const ValueKey('chat-hold-cancel-layer'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _cancelHoldTalk();
          // Phase 4.5 审计保留：这是**用户自己按的取消**，不是失败，也不是
          // "你刚写的字去哪了"。轻提示走 SnackBar（父级已设 floating + 2s），
          // 不必占用输入区那条提示的位置。
          _toast('已取消录音');
        },
        child: _buildHoldRecordingPanel(),
      );
    }
    // Phase 4.6 收尾：老用户会习惯"空框里长按说话"，而 v1.27 之后那个动作什么
    // 都不发生（长按已还给系统的选词）。这里挂一个**纯旁观**的指针监听，第一次
    // 长按时提示一句"麦克风在右边"。
    //
    // ⚠️ `Listener` 不参加手势竞技场、不改道任何指针事件 —— 下面的 TextField
    // 照旧拿到完整的点按/长按/拖选。这正是它比 `GestureDetector` 安全的地方
    // （见本文件里那段"跟 EditableText 抢长按"的历史）。引导本身也不挡键盘：
    // 提示走的是 SnackBar，不在这棵子树上。
    return Listener(
      onPointerDown: _onFieldPointerDown,
      onPointerMove: _onFieldPointerMove,
      onPointerUp: _onFieldPointerEnd,
      onPointerCancel: _onFieldPointerEnd,
      child: TextField(
        key: const ValueKey('chat-input-field'),
        controller: _inputController,
        focusNode: _inputFocusNode,
        style: TextStyle(color: context.c.textPrimary, fontSize: 14.5),
        maxLines: 5,
        // [feat 2026-10-18] 默认两行（用户反馈：一行看起来太窄）。
        // 只改 minLines：maxLines 仍是 5，超过才滚动，输入卡片不会无限长高。
        minLines: 2,
        decoration: InputDecoration(
          // [fix 2026-10-17] 真机截图里 placeholder 是深色、还比正文大一号，
          // 看起来像"已经输入了内容"。原因是没有给 hintStyle，Flutter 就回落到
          // textTheme.titleMedium（≈16sp + onSurface）—— 空输入框于是长得像满的。
          //
          // 另外去掉了文案里的 🎤 emoji：紧挨着就有一个 Material 麦克风按钮，
          // emoji 既重复又和图标风格打架。"按住麦克风说话"这件事交给两条正式
          // 通道：按钮 tooltip + 首次长按输入框的一次性引导（`dsh_hint_hold_mic_v1`）。
          hintText: '发消息…',
          hintStyle: TextStyle(
            color: context.c.textTertiary,
            fontSize: 13.5,
            fontWeight: FontWeight.w400,
          ),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
        ),
        onChanged: (v) {
          dsh.updateDraft(v);
          // [feat 2026-10-18] 打一个 `/` 就等于点了斜杠按钮：面板自己弹出来。
          //
          // 那个 ⚡ 图标没有文字，是这套功能唯一的入口 —— 用户找不到入口，
          // 就等于功能不存在。斜杠是用户本来就有的习惯（Slack/Discord/命令
          // 行），用它把面板带出来，比再加一行 chips 便宜得多。
          if (v == '/') _maybeOpenSheetOnSlash(dsh);
        },
        onSubmitted: (_) => _sendMessage(dsh),
      ),
    );
  }

  /// 输入卡片底部那一排按钮（停止 / 斜杠 / 附件 / 模型 / 麦克风 / 发送）。
  Widget _buildActionRow(DshService dsh) {
    return LayoutBuilder(
      builder: (context, box) {
        // 这一行的横向空间永远是紧的：在 360dp 宽的手机上，固定宽度
        // 的模型胶囊会把整行顶出去（实测 317 > 316，溢出 1px）。
        // 所以胶囊的可读宽度按**剩余空间**算，而不是钉死一个常量。
        //
        // 预留：停止键 36（不显示时 0）+ 斜杠 36 + 附件 36 + 麦克风 44 +
        // 发送键 44 + 两处间隔 6 + 模型胶囊自身装饰 47 + 安全余量 4。
        //
        // [feat 2026-10-17] 权限胶囊（80dp）**只在实际放得下时才出现**：
        // 360dp 屏上再叠一条队列状态时这一行是真的没空间了，硬塞会把整行顶溢出
        // （`queue_steer_impl_test` 的 360×640 用例量到 16px）。宁可少一个胶囊，
        // 也不能让输入框那一行破版 —— 权限还能从会话信息面板的旧入口进。
        final stopWidth = (dsh.isSending || dsh.isCanceling) ? 36.0 : 0.0;
        const baseReserved = 36.0 + 36.0 + 44.0 + 44.0 + 6.0 + 47.0 + 4.0;
        final wantsPolicy =
            widget.policyLabel != null && widget.onPickPermission != null;
        const policyWidth = 64.0;
        final showPolicy = wantsPolicy &&
            (box.maxWidth - stopWidth - baseReserved - policyWidth) >= 40.0;
        final reserved = baseReserved + (showPolicy ? policyWidth : 0.0);
        // 下限取 0 而不是 40：空间实在不够时让模型名整段省略（胶囊只剩图标），
        // 强行保留 40dp 文字就是上面那个 16px 溢出的来源。
        final textCap = (box.maxWidth - stopWidth - reserved).clamp(0.0, 104.0);
        return Row(
          children: [
            // 停止键固定在**最左**（v1.14）：它曾经和发送键抢同一个位置，
            // 于是"输入框被清空"（切会话、重录、草稿恢复）会在用户毫无输入
            // 动作的情况下把发送键变成停止键 —— 手一抖就取消掉自己正在跑的
            // 回合。位置分开之后，任何状态变化都不会改变任何按钮的含义。
            _buildStopButton(dsh),
            // [feat 2026-10-12] "/" 命令菜单入口。输入框已有 / 开头草稿时高亮。
            //
            // v1.27：提示词模板不再占输入区一整行，改为接进这个面板的下半段
            // （见 `_openCommandOrSnippetSheet`）—— 模板是"想起来才会用"的东西，
            // 不值得为它常驻一行。
            _buildComposerIcon(
              key: const ValueKey('composer-slash-button'),
              icon: Icons.bolt_rounded,
              tooltip: '斜杠命令与提示词模板',
              highlighted: _inputController.text.startsWith('/'),
              onTap: () => _openCommandOrSnippetSheet(dsh),
            ),
            _buildComposerIcon(
              icon: Icons.add_rounded,
              tooltip: '添加图片或文件',
              highlighted: _pendingAttachments.isNotEmpty,
              onTap: () => _showAttachSheet(dsh),
            ),
            const Spacer(),
            // [feat 2026-10-17] 对话权限胶囊：与模型胶囊并排、在它左边。
            //
            // 为什么搬到这里：切换模型和切换权限是同一类动作 —— "发出去之前先确认
            // 这一轮按什么规则跑"。它们埋在会话信息面板里时，用户根本想不起来去那
            // 儿改；而误发的代价（全信任模式下直接执行）比换模型大得多。
            if (showPolicy) ...[
              _buildPolicyPill(),
              const SizedBox(width: 2),
            ],
            _buildModelPill(dsh, maxTextWidth: textCap),
            const SizedBox(width: 2),
            _buildMicButton(dsh),
            const SizedBox(width: 4),
            _buildSendButton(dsh),
          ],
        );
      },
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
                    color: _holdText.isEmpty
                        ? context.c.textSecondary
                        : context.c.textPrimary,
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
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9)),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onPressed: () => _redoHoldTalk(dsh),
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: const Text('重录',
                  style:
                      TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: context.c.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9)),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onPressed: () => _sendHoldTalk(dsh),
              icon: const Icon(Icons.arrow_upward_rounded, size: 17),
              label: const Text('发送',
                  style:
                      TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  /// 斜杠命令面板（v1.27：提示词模板并入这里）。
  ///
  /// 分工：
  /// * 没有模板时**完全走原来的命令面板**（`chat_sheets.dart` 的
  ///   `showChatCommandSheet`）—— 一条旧路径都不改写，行为零变化。
  /// * 有模板时在同一个弹层里分两段：上半斜杠命令、下半提示词模板。
  ///   模板以前是输入区下方一整条常驻 chips 行，而它属于"想起来才会用"的功能，
  ///   不值得为它常驻一行（那正是改造前打字区被压扁的原因之一）。
  Future<void> _openCommandOrSnippetSheet(DshService dsh) async {
    // 弹层不可重入：`_snippetSheetOpen` 挡住"打斜杠自动弹 + 立刻再点按钮"
    // 这种叠层（叠起来的样子是遮罩变深、用户以为界面卡了）。
    if (_snippetSheetOpen) return;
    _snippetSheetOpen = true;
    try {
      await _openCommandOrSnippetSheetImpl(dsh);
    } finally {
      _snippetSheetOpen = false;
    }
  }

  /// 输入框里刚打出一个 `/`：把同一个面板带出来。
  ///
  /// 放在 postFrame 里是为了不打断这一帧的文本编辑（directly opening a modal
  /// route mid-onChanged 会让 iOS 输入法状态错乱）。
  void _maybeOpenSheetOnSlash(DshService dsh) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_openCommandOrSnippetSheet(dsh));
    });
  }

  Future<void> _openCommandOrSnippetSheetImpl(DshService dsh) async {
    // [fix 2026-10-18] 每次打开都重读一次本地条目。
    //
    // 这里多花的是一次本地 IO（毫秒级），换来的是"设置里改完，回对话页立刻
    // 可用"。此前只在 initState 读一次，本 State 又常驻不重建 —— 于是新建的
    // 指令要重启 App 才出现在面板里（用户反馈的"没地方使用"）。
    await _loadLocalSnippets();
    if (!mounted) return;
    // 两个来源都空时完全走原来的命令面板（行为零变化）；只要有一个有内容，
    // 就进这个合并面板。
    if (dsh.snippets.isEmpty && _localSnippets.isEmpty) {
      _showCommandSheet(dsh);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetCtx).size.height * 0.6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
                child: Text(
                  '命令与模板',
                  style: TextStyle(
                    fontSize: AppText.heading,
                    fontWeight: FontWeight.bold,
                    color: sheetCtx.c.textPrimary,
                  ),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    _sheetGroupLabel(sheetCtx, '斜杠命令'),
                    FutureBuilder<List<SlashCommand>>(
                      future: dsh.fetchCommands(),
                      builder: (ctx, snap) {
                        if (snap.connectionState != ConnectionState.done) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        }
                        final commands = snap.data ?? const <SlashCommand>[];
                        if (commands.isEmpty) {
                          // 引擎没给就不要伪造菜单：菜单里出现引擎不认的名字
                          // 等于教用户输错命令。
                          return _sheetHint(ctx, '当前会话没有可用的斜杠命令');
                        }
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final c in commands)
                              ListTile(
                                dense: true,
                                title: Text(
                                  '/${c.name}',
                                  style: TextStyle(
                                    fontSize: AppText.title,
                                    fontWeight: FontWeight.w600,
                                    color: ctx.c.textPrimary,
                                  ),
                                ),
                                subtitle: c.description.isEmpty
                                    ? null
                                    : Text(
                                        c.description,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: AppText.subhead,
                                            color: ctx.c.textTertiary),
                                      ),
                                onTap: () {
                                  Navigator.of(sheetCtx).pop();
                                  _insertSlashCommand(dsh, c.name);
                                },
                              ),
                          ],
                        );
                      },
                    ),
                    // 本地快捷指令排在最前（Phase 5.4）：自己写的那几条几乎总是
                    // 比网关下发的通用模板更常用。两者同名也不去重 —— 它们本来就是
                    // 两个来源，各自演化（见 `models/local_snippet.dart` 的文件头）。
                    //
                    // [fix 2026-10-18] 分组标题**只在两组都有内容时才画**。
                    // 此前「提示词模板」是无条件渲染的标题：网关没下发模板（很常见）
                    // 时，弹层最底部就吊着一行孤零零的字，看起来像界面坏了。
                    // 只有一组时标题也是多余的 —— 它只说明来源，而这个弹层本身
                    // 已经叫「命令与模板」。
                    if (_localSnippets.isEmpty)
                      // 本地一条都没有时**不能静默跳过这一组**：用户会以为这个
                      // 面板里根本没有他的东西。这里给一句解释 + 一个能去建条目的
                      // 出口（键名供测试定位）。
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '还没有本地快捷指令（只在这台手机上）。',
                                style: TextStyle(
                                    fontSize: AppText.caption, color: sheetCtx.c.textTertiary),
                              ),
                            ),
                            if (widget.onOpenSnippets != null)
                              TextButton(
                                key: const ValueKey('snippet-sheet-open-settings'),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                onPressed: () {
                                  Navigator.of(sheetCtx).pop();
                                  widget.onOpenSnippets?.call();
                                },
                                child: Text(
                                  '去新建',
                                  style: TextStyle(
                                      fontSize: AppText.body, color: sheetCtx.c.accent),
                                ),
                              ),
                          ],
                        ),
                      )
                    else ...[
                      if (dsh.snippets.isNotEmpty)
                        _sheetGroupLabel(sheetCtx, '本地快捷指令'),
                      for (final snip in _localSnippets)
                        ListTile(
                          dense: true,
                          title: Text(
                            snip.label.isEmpty
                                ? LocalSnippet.autoLabel(snip.text)
                                : snip.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: AppText.title,
                                color: sheetCtx.c.textPrimary),
                          ),
                          subtitle: Text(
                            // 有分类标签时把标签也带上：同名的几条靠它区分。
                            snip.tag.isEmpty
                                ? snip.text
                                : '${snip.tag} · ${snip.text}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: AppText.subhead,
                                color: sheetCtx.c.textTertiary),
                          ),
                          trailing: Icon(
                            // 带占位符的会先弹一屏填写，图标随之不同 —— 免得用户
                            // 点了一个"看起来直接插入"的条目却突然被要参数。
                            snip.placeholders.isEmpty
                                ? Icons.add_rounded
                                : Icons.edit_note_rounded,
                            size: 18,
                            color: sheetCtx.c.textTertiary,
                          ),
                          onTap: () {
                            Navigator.of(sheetCtx).pop();
                            _insertLocalSnippet(dsh, snip);
                          },
                        ),
                    ],
                    // 网关模板：**有才画标题**。空的时候什么都别留 —— 一行动词
                    // 下面是空的，用户只会以为加载失败。
                    if (dsh.snippets.isNotEmpty) ...[
                      if (_localSnippets.isNotEmpty)
                        _sheetGroupLabel(sheetCtx, '网关模板'),
                      for (final snip in dsh.snippets)
                        ListTile(
                          dense: true,
                          title: Text(
                            snip.label,
                            style: TextStyle(
                                fontSize: AppText.title,
                                color: sheetCtx.c.textPrimary),
                          ),
                          subtitle: Text(
                            snip.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: AppText.subhead,
                                color: sheetCtx.c.textTertiary),
                          ),
                          trailing: Icon(Icons.add_rounded,
                              size: 18, color: sheetCtx.c.textTertiary),
                          onTap: () {
                            Navigator.of(sheetCtx).pop();
                            _appendSnippetTemplate(dsh, snip.text);
                          },
                        ),
                    ],
                    const SizedBox(height: AppSpace.m),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetGroupLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Text(
          text,
          style: TextStyle(
            fontSize: AppText.caption,
            fontWeight: FontWeight.w700,
            color: context.c.textTertiary,
          ),
        ),
      );

  Widget _sheetHint(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
        child: Text(
          text,
          style: TextStyle(
              fontSize: AppText.caption, color: context.c.textTertiary),
        ),
      );

  /// 把 `/name ` 插进输入框（保留既有草稿）。
  ///
  /// ⚠️ 与 `chat_sheets.dart` 的 `showChatCommandSheet` 末尾那段是**同一套规则**：
  /// 已经以 `/` 开头时替换命令名而不是叠加，否则会得到 `/a /b`。改一处必须改另一处。
  void _insertSlashCommand(DshService dsh, String name) {
    final current = _inputController.text;
    // [fix 2026-10-17] 以 `/` 开头但**没有空格**时 indexOf(' ')==-1，
    // substring(0) 会取回全文，拼出 `/name /ab` 双斜杠残留 —— 无空格时
    // 整段就是命令名，直接替换。
    final spaceIdx = current.indexOf(' ');
    _inputController.text = current.startsWith('/')
        ? '/$name ${spaceIdx == -1 ? '' : current.substring(spaceIdx + 1)}'
        : '$current/$name ';
    _inputController.selection =
        TextSelection.collapsed(offset: _inputController.text.length);
    dsh.updateDraft(_inputController.text);
    _inputFocusNode.requestFocus();
  }

  /// 把一条**本地**快捷指令插进输入框（Phase 5.4）。
  ///
  /// 带 `{param}` 的模板先弹一屏填写（`showSnippetParamDialog` 在没有占位符时
  /// 直接返回原文，所以这里不必分支）。用户取消（null）就什么都不做 —— 取消
  /// 不是失败，不该再弹一条提示去解释"你没插进去"。
  ///
  /// ⚠️ 插入走的是既有的 `_appendSnippetTemplate`（**追加**而非覆盖）：用户可能
  /// 已经打了半句，覆盖等于替他把那句话删了。
  Future<void> _insertLocalSnippet(DshService dsh, LocalSnippet snip) async {
    final title =
        snip.label.isEmpty ? LocalSnippet.autoLabel(snip.text) : snip.label;
    final text = await showSnippetParamDialog(context,
        title: title, template: snip.text);
    // 弹框期间用户可能切走会话（本组件随之 dispose）。
    if (!mounted || text == null) return;
    _appendSnippetTemplate(dsh, text);
  }

  /// 把模板文字 **追加**到输入框（不覆盖已有内容 —— 用户可能已经打了半句）。
  void _appendSnippetTemplate(DshService dsh, String text) {
    final cur = _inputController.text;
    _inputController.text = cur.isEmpty ? text : '$cur\n$text';
    _inputController.selection = TextSelection.fromPosition(
      TextPosition(offset: _inputController.text.length),
    );
    dsh.updateDraft(_inputController.text);
    _inputFocusNode.requestFocus();
  }

  /// 输入卡片上方的原地提示条（v1.14）：排队回执 / 插话结果 / 失败回滚说明。
  ///
  /// 与 `_toast` 的分工：`_toast` 用 SnackBar，适合"知道了"这类说完就算的消息；
  /// 这条提示承载的是"你刚写的东西去哪了"，必须留在原地、可撤回、可重试。
  Widget _buildNotice(DshService dsh) {
    return ValueListenableBuilder<ComposerNotice?>(
      valueListenable: _noticeBus.notice,
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
            border: Border.all(
                color: notice.ok ? context.c.border : context.c.danger),
          ),
          child: Row(
            children: [
              Icon(
                notice.ok
                    ? Icons.check_circle_outline_rounded
                    : Icons.error_outline_rounded,
                size: 14,
                color: tone,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  notice.text,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: notice.ok
                          ? context.c.textSecondary
                          : context.c.danger),
                ),
              ),
              if (notice.action != NoticeAction.none)
                _queueTextButton(
                  key: const ValueKey('chat-notice-action'),
                  label: notice.action == NoticeAction.undoQueue ? '撤回' : '重试',
                  onTap: () => _onNoticeAction(dsh, notice),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 展开态的排队列表。
  ///
  /// v1.27 起这里**只在用户手动展开时**才渲染：折叠态由状态胶囊行那一行承担
  /// （「N 条排队中 · 展开」），所以"常驻最多两行"才成立。展开/收起的按钮在胶囊
  /// 上（key `queue-dock-toggle`），不在这个面板里 —— 两个入口会让"收起"出现两次。
  Widget _buildQueueDock(DshService dsh) {
    final rows = dsh.queueItems;
    // 展开着的时候队列被引擎领空（全部发送完）：直接不渲染，胶囊行会自己收敛。
    if (rows.isEmpty) return const SizedBox.shrink();

    final header = '${rows.length} 条排队中 · 本轮结束后自动发送';

    // 展开态的上限：输入卡片是这条 Column 里唯一 Expanded（消息列表）的兄弟，
    // 且**自身高度无上限** —— 20 条排队 × 约 66px 会直接把输入卡片顶出屏幕
    // （RenderFlex 溢出）。所以展开必须限高 + 内部自己滚。
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
              Icon(Icons.queue_rounded,
                  size: 14, color: context.c.textSecondary),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  header,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: context.c.textSecondary),
                ),
              ),
              if (dsh.queueLoading)
                SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.6, color: context.c.textTertiary)),
            ],
          ),
          if (dsh.queueError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(dsh.queueError,
                  style: TextStyle(fontSize: 11, color: context.c.danger)),
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: expandedMax),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final row in rows) _buildQueueRow(dsh, row),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQueueRow(DshService dsh, QueueItem row) {
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
                  style:
                      TextStyle(fontSize: 12.5, color: context.c.textPrimary),
                ),
              ),
              const SizedBox(width: 8),
              // 触摸区 36×36（旧版是 16px 图标 + 4px padding = 24px，与紧邻的
              // 「删除」中心距只有 28px，误触会直接改掉正在跑的任务上下文）。
              _queueIconButton(
                  Icons.edit_outlined, '编辑', () => _editQueueRow(dsh, row),
                  key: ValueKey('queue-edit-${row.id}')),
              const SizedBox(width: 4),
              _queueIconButton(
                  Icons.close_rounded, '删除', () => _removeQueueRow(dsh, row),
                  key: ValueKey('queue-remove-${row.id}')),
            ],
          ),
          const SizedBox(height: 2),
          if (dsh.isSessionRunning)
            Row(
              children: [
                _queueTextButton(
                  key: ValueKey('queue-steer-${row.id}'),
                  // v1.27：点一下就插队，安全网换到**事后**（回执条上的「撤回」）。
                  // 原来这里是"第一次点击只武装、第二次才真插"的两段式，实测只让人
                  // 反复试 —— 按钮文字 2.5 秒后还会自己还原，状态完全不可见。
                  label: '立即插话',
                  onTap: () => _steerQueueRow(dsh, row),
                  tone: context.c.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    // 引擎的 steer 是插进**最近的步骤**（agent.steer），不会取消
                    // 这一轮 —— 文案必须与真实语义一致，否则用户会以为任务要重跑。
                    '会插进当前步骤，本轮不会重来',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10.5, color: context.c.textTertiary),
                  ),
                ),
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

  Widget _queueIconButton(IconData icon, String tooltip, VoidCallback? onTap,
      {Key? key}) {
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
              color: onTap == null
                  ? context.c.textTertiary
                  : context.c.textSecondary,
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
  ///
  /// （原来还有一个 `filled` 参数给"已武装"态画实心底 —— v1.27 改成点一下就执行
  /// 之后不再有武装态，那个参数也没有调用方了，直接去掉。）
  Widget _queueTextButton({
    required String label,
    required VoidCallback onTap,
    Color? tone,
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
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color,
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

  Widget _buildComposerIcon({
    Key? key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool highlighted = false,
  }) {
    return Tooltip(
      key: key,
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
  /// 对话权限胶囊（[feat 2026-10-17] 从会话信息面板搬来）。
  ///
  /// 只显示**短名**（每次询问 / 自动只读 / 全信任）：这一行在 360dp 上要和
  /// 斜杠、附件、模型、麦克风、发送共用，长文案会把模型胶囊挤没。
  /// 颜色按"松紧"分级 —— 全信任是危险色，自动只读是品牌色，每次询问是警告色，
  /// 让"我现在是不是把闸门开到最大"在余光里也能看出来。
  Widget _buildPolicyPill() {
    final label = widget.policyLabel!;
    final risky = label.contains('全信任');
    final readable = label.contains('只读');
    final color = risky
        ? context.c.danger
        : (readable ? context.c.accent : context.c.warning);
    return Tooltip(
      message: '对话权限：$label（点按切换）',
      child: InkWell(
        key: const ValueKey('composer-policy-pill'),
        onTap: widget.onPickPermission,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shield_outlined, size: 14, color: color),
              const SizedBox(width: 4),
              // Flexible + 48dp 上限：窄屏（360dp）上这一行本来就没有多少余量，
              // 硬宽的胶囊会把整行顶溢出（`queue_steer_impl_test` 锁的就是这条）。
              // [fix 2026-10-17] 34 → 46：3 个 11.5px 汉字 ≈34.5px，34dp 下
              // 「全信任」常态截成「全信…」—— 而这个胶囊的全部意义就是让用户
              // 看出当前权限档位。46dp 装得下三字 + 余量，仍留 Flexible 兜溢出。
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 46),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModelPill(DshService dsh, {double maxTextWidth = 104}) {
    final full = dsh.currentModel.replaceFirst('cn:', '');
    // [fix 2026-10-17] 真机上这个胶囊显示成 `deepseek-v4.1-...` —— 被截断的
    // 恰好是唯一有信息量的那半截（flash / pro）。`deepseek-` 是全部模型共有的
    // 前缀，占位却不区分任何东西，所以显示层去掉它；完整名放进 tooltip。
    final name = full.startsWith('deepseek-') ? full.substring('deepseek-'.length) : full;
    return Tooltip(
      message: full,
      child: InkWell(
      onTap: () => _showModelSwitchSheet(context, dsh),
      borderRadius: BorderRadius.circular(9),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smart_toy_outlined,
                size: 14, color: context.c.textSecondary),
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
            Icon(Icons.keyboard_arrow_down_rounded,
                size: 16, color: context.c.textTertiary),
          ],
        ),
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
    // [fix 2026-10-17] isSending 现在带会话归属（sendingSessionId）：只在本
    // 会话真的在本机跑着时才出现停止键，别的会话在跑不再点亮。
    if (!dsh.isSending) return const SizedBox.shrink();
    final runningId = dsh.sendingSessionId;
    final sessionId = dsh.currentSession?.sessionId;
    if (runningId != null &&
        sessionId != null &&
        !dsh.currentSession!.matchesSessionId(runningId)) {
      return const SizedBox.shrink();
    }
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
        final canSend =
            value.text.trim().isNotEmpty || _pendingAttachments.isNotEmpty;
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    constraints: const BoxConstraints(minWidth: 15),
                    decoration: BoxDecoration(
                      color: context.c.warning,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: context.c.surface, width: 1.5),
                    ),
                    child: Text(
                      '$queued',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                          color: Colors.white),
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
                    style: TextStyle(
                        fontSize: 12.5, height: 1.7, color: c.textPrimary),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '若「服务可用」为否且「中文语言包」为空，说明这台设备没有语音识别'
                    '服务，App 侧无法解决。',
                    style: TextStyle(
                        fontSize: 11.5, height: 1.6, color: c.textTertiary),
                  ),
                ],
              ),
            ),
    );
  }
}
