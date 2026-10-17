// 会话轨迹：把一批 ChatMessage 重建成「轮 → 事件」的时间线。
//
// 为什么要有这一层，而不是在 widget 里直接遍历消息：
//
// 手机上的轨迹视图要回答三个问题：这一轮它做了什么、每步花了多久、结果在哪。
// 前两个问题都需要"时间"，而时间只能从消息上取（引擎在每条消息上带 `time`），
// 工具调用本身没有独立时间戳。所以这一层必须把"哪些时间是真的、哪些取不到"
// 显式表达出来，而不是在渲染时临时 `DateTime.now()` 凑一个好看的数字 —— 那正是
// 本项目在其它地方反复踩过的坑（把"读不到"渲染成"0"）。
//
// 三条诚实规则（有对应测试）：
//
// 1. 耗时只在同一轮内至少有两个带时间的不同事件时才给出；只有一个事件的轮
//    （用户刚发出去、还没有回复）一律 null，界面显示 `—`。一个事件的"首尾差"
//    恒为 0，把它显示成 `0s` 等于声称"这轮瞬间跑完了"。
// 2. token 只认有数据源的那一个：优先用引擎的权威值（网关把该轮各 step 的 usage
//    汇总到那条 user 消息上 → ChatMessage.turnTokens），只有当前正在跑的那一轮才退
//    回调用方传进来的 liveTurnTokens。两者都没有就是 null，界面显示 `—`，绝不补 0
//    —— 0 会被读成"这轮没花钱"。
// 3. 上下文/记忆块单独归类（TrajectoryEventKind.context）。它们不是用户
//    或 Agent 的动作，默认在时间线里隐藏，但要能被计数 —— 隐藏不等于不存在。

import 'chat_message.dart';

/// 事件类型。
///
/// `user` / `thinking` / `tool` / `reply` 是"动作"，`context` 是"输入材料的搬运"。
enum TrajectoryEventKind { user, thinking, tool, reply, context }

/// 时间线上的一个事件。
class TrajectoryEvent {
  TrajectoryEvent({
    required this.kind,
    required this.messageId,
    required this.label,
    this.seq,
    this.at,
    this.preview = '',
    this.detail = '',
    this.running = false,
  });

  final TrajectoryEventKind kind;

  /// 回到聊天流里那一条消息用的身份键（`ChatMessage.id`）。
  final String messageId;

  /// 行首标签：`你` / `思考` / 工具名 / `回复` / `上下文`。
  final String label;

  /// 引擎事件序号；老网关/本地乐观消息为 null。
  final int? seq;

  /// 引擎事件时间。null = 引擎没给，界面显示 `--:--:--`。
  final DateTime? at;

  /// 单行摘要（时间线上那一行）。
  final String preview;

  /// 展开后的全文；空串表示没有更多可展开的内容。
  final String detail;

  /// 工具仍在执行中（只在实时链路里为 true）。
  final bool running;

  bool get expandable => detail.trim().isNotEmpty;
  bool get isContext => kind == TrajectoryEventKind.context;

  /// 把任意文本压成适合单行显示的摘要。
  ///
  /// 换行/连续空白折叠成单个空格，超长截断并加省略号 —— 时间线里一行放不下，
  /// 但**不能**因此在模型层丢掉原文（原文在 [detail] 里）。
  static String summarise(String raw, {int max = 96}) {
    final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= max) return flat;
    return '${flat.substring(0, max)}…';
  }

  /// 取第一行非空文本：工具/回复的摘要更愿意显示"开头"而不是整段被折叠的全文。
  static String firstLine(String raw, {int max = 96}) {
    for (final line in raw.split('\n')) {
      if (line.trim().isNotEmpty) return summarise(line, max: max);
    }
    return '';
  }
}

/// 一轮（turn）：从一条用户消息开始，到下一轮开始之前。
class TrajectoryTurn {
  TrajectoryTurn({required this.index});

  /// 1 起的轮号。
  final int index;

  /// 本轮第一个事件的时间（引擎时间）。
  ///
  /// 会话开头的上下文块会先于任何用户消息出现，这时它是上下文块的时间 —— 也就是
  /// "本轮输入到达的时间"，与用户消息的时间语义一致。
  DateTime? startedAt;

  /// 本轮最后一个事件的时间。运行中的轮为 null（还没结束）。
  DateTime? endedAt;

  /// 正在跑（只有最后一轮可能为 true）。
  bool running = false;

  /// 本轮消耗的 token。只有"已知的那一轮"有值，其余为 null。
  int? tokens;

  final List<TrajectoryEvent> events = <TrajectoryEvent>[];

  /// 不带上下文块的事件（时间线默认只显示这些）。
  List<TrajectoryEvent> get actionEvents =>
      events.where((e) => !e.isContext).toList(growable: false);

  List<TrajectoryEvent> get contextEvents =>
      events.where((e) => e.isContext).toList(growable: false);

  int get toolCount => events.where((e) => e.kind == TrajectoryEventKind.tool).length;

  /// 可用的耗时。
  ///
  /// 见文件头的诚实规则 1：至少两个**时间不同**的事件才给值；否则 null。
  Duration? get duration {
    final s = startedAt;
    final e = endedAt;
    if (s == null || e == null) return null;
    if (timedEventCount < 2) return null;
    final d = e.difference(s);
    if (d.isNegative) return null;
    return d;
  }

  /// 本轮里带时间戳的事件的不同时刻数。
  int get timedEventCount {
    final seen = <int>{};
    for (final e in events) {
      final at = e.at;
      if (at != null) seen.add(at.millisecondsSinceEpoch);
    }
    return seen.length;
  }

  /// 运行中的轮"已经跑了多久"（打开面板那一刻的快照，不是实时跳秒）。
  ///
  /// 没有开始时间就返回 null —— 宁可显示 `—`，也不从"现在"开始倒数一个假的时长。
  Duration? elapsedAt(DateTime now) {
    final s = startedAt;
    if (s == null) return null;
    if (running) {
      final d = now.difference(s);
      return d.isNegative ? null : d;
    }
    return duration;
  }
}

/// 一整段会话的轨迹。
class Trajectory {
  Trajectory._(this.turns, this.contextEventCount);

  final List<TrajectoryTurn> turns;

  /// 被判为上下文/记忆块的事件总数（默认不显示，但要能告诉用户"藏了多少"）。
  final int contextEventCount;

  bool get isEmpty => turns.isEmpty;

  bool get hasRunningTurn => turns.any((t) => t.running);

  int get actionEventCount =>
      turns.fold(0, (n, t) => n + t.actionEvents.length);

  int get toolCount => turns.fold(0, (n, t) => n + t.toolCount);

  int get timedTurnCount => turns.where((t) => t.duration != null).length;

  /// 总耗时：**只有每一轮都有耗时**时才给出，否则 null。
  ///
  /// 部分求和会被读成"整段会话跑了这么久"，那是错的 —— 缺的那几轮可能正好是
  /// 最长的几轮。
  Duration? get totalDuration {
    if (turns.isEmpty) return null;
    var sum = Duration.zero;
    for (final t in turns) {
      final d = t.duration;
      if (d == null) return null;
      sum += d;
    }
    return sum;
  }

  /// 从消息列表重建轨迹。
  ///
  /// [liveTurnTokens] 传当前会话"本轮已消耗"的读数（`DshService.lastTurnTokens`），
  /// 用来补**最后一轮**的 token —— 只在它还没有引擎权威值时才补（正在跑的那轮网关
  /// 给不出值，已经跑完的那轮有）。为 null 时各轮按各自的数据源显示。
  ///
  /// [running] 表示最后一轮仍在执行 —— 这时它不封口，界面显示"进行中"。
  static Trajectory build(
    List<ChatMessage> messages, {
    int? liveTurnTokens,
    bool running = false,
  }) {
    final turns = <TrajectoryTurn>[];
    final seenIds = <String>{};
    var contextCount = 0;
    TrajectoryTurn? current;

    TrajectoryTurn ensureTurn() {
      if (current != null) return current!;
      final t = TrajectoryTurn(index: turns.length + 1);
      turns.add(t);
      current = t;
      return t;
    }

    void add(TrajectoryEvent event) {
      final t = ensureTurn();
      t.events.add(event);
      t.startedAt ??= event.at;
      t.endedAt = event.at ?? t.endedAt;
    }

    for (final m in messages) {
      // 同一条消息可能被 reconcile / 历史翻页重复搬运（列表身份不变、内容相同），
      // 时间线上重复出现同一件事比漏掉它更像 bug。
      if (!seenIds.add(m.id)) continue;

      // [feat 2026-10-17] 引擎注入的通知（role 是 user，但没人打过这些字）不是用户
      // 输入、也不是 agent 的动作：如果按 role 走，它会凭空开一轮"第 N 轮"，把整条
      // 时间线的轮号全带偏。归到折叠那一档，默认不可见但能被计数。
      if (m.isHarnessNotice) {
        contextCount++;
        final body = m.notice?.body;
        add(TrajectoryEvent(
          kind: TrajectoryEventKind.context,
          messageId: m.id,
          label: '通知',
          seq: m.seq,
          at: m.timestamp,
          preview: TrajectoryEvent.firstLine(
            (body != null && body.trim().isNotEmpty) ? body : m.content,
            max: 72,
          ),
          detail: m.content,
        ));
        continue;
      }

      if (m.isContextOrMemory) {
        contextCount++;
        add(TrajectoryEvent(
          kind: TrajectoryEventKind.context,
          messageId: m.id,
          label: '上下文',
          seq: m.seq,
          at: m.timestamp,
          preview: TrajectoryEvent.firstLine(m.content, max: 72),
          detail: m.content,
        ));
        continue;
      }

      if (m.isUser) {
        // 用户消息开新一轮：上一轮到此封口。
        //
        // 例外：如果当前轮里**只有上下文块**（会话开头的记忆/环境快照就是这种形态，
        // 它先于任何用户消息到达），就不是"新起一轮"，而是把这条用户消息放进同一轮
        // —— 否则开头那段上下文会被算成一个只有上下文的"第 1 轮"，轮号也会整体错位。
        final onlyContext =
            current != null && current!.events.every((e) => e.isContext);
        final t = onlyContext ? current! : TrajectoryTurn(index: turns.length + 1);
        if (!onlyContext) {
          turns.add(t);
          current = t;
        }
        final e = TrajectoryEvent(
          kind: TrajectoryEventKind.user,
          messageId: m.id,
          label: '你',
          seq: m.seq,
          at: m.timestamp,
          preview: TrajectoryEvent.firstLine(m.content, max: 88),
          detail: m.content,
        );
        t.events.add(e);
        t.startedAt = e.at;
        t.endedAt = e.at;
        // [feat 2026-10-17] 引擎的权威逐轮用量（网关把该轮各 step 的 usage 汇总到
        // 这条 user 消息上）。有它就不必再靠"本机两次读数相减"，历史轮也能显示真值。
        if (m.turnTokens != null) t.tokens = m.turnTokens;
        continue;
      }

      // 助手侧：思考 → 工具（按发生顺序）→ 正文。
      //
      // 工具没有独立时间戳，所以同一轮里它们的相对时间**不可知**；这里保留的是
      // 消息结构里的顺序（引擎按调用顺序写入 tools 数组），界面上的说明也这么写。
      final at = m.timestamp;
      final thinking = (m.thinking ?? '').trim();
      if (thinking.isNotEmpty) {
        add(TrajectoryEvent(
          kind: TrajectoryEventKind.thinking,
          messageId: m.id,
          label: '思考',
          seq: m.seq,
          at: at,
          preview: TrajectoryEvent.firstLine(thinking, max: 88),
          detail: m.thinking ?? '',
        ));
      }

      for (final tool in m.tools) {
        final input = tool.input.trim();
        final output = tool.output.trim();
        final detail = StringBuffer();
        if (input.isNotEmpty) detail.writeln('参数\n$input');
        if (output.isNotEmpty) {
          if (detail.isNotEmpty) detail.writeln();
          detail.writeln('结果\n$output');
        }
        add(TrajectoryEvent(
          kind: TrajectoryEventKind.tool,
          messageId: m.id,
          label: tool.name.isEmpty ? '工具' : tool.name,
          seq: m.seq,
          at: at,
          preview: tool.isRunning
              ? '运行中…'
              : (TrajectoryEvent.firstLine(input.isNotEmpty ? input : output, max: 88)),
          detail: detail.toString().trimRight(),
          running: tool.isRunning,
        ));
      }

      final content = m.content.trim();
      if (content.isNotEmpty) {
        add(TrajectoryEvent(
          kind: TrajectoryEventKind.reply,
          messageId: m.id,
          label: '回复',
          seq: m.seq,
          at: at,
          preview: TrajectoryEvent.firstLine(content, max: 88),
          detail: m.content,
        ));
      }
    }

    if (turns.isNotEmpty) {
      final last = turns.last;
      last.running = running;
      if (running) last.endedAt = null;
      // [fix 2026-10-17] 本机读数**只补空**，不覆盖引擎的权威值：最后一轮已经跑完
      // 时它必然带着网关汇总的 `tokens`，而 `liveTurnTokens` 是"两次 stats 读数相减"，
      // 精度更差。以前这里无条件覆盖，等于把更准的那个扔掉。
      if (last.tokens == null && liveTurnTokens != null && liveTurnTokens > 0) {
        last.tokens = liveTurnTokens;
      }
    }

    return Trajectory._(turns, contextCount);
  }
}
