/// 引擎注入的通知：`role` 是 `user`，但**没有人打过这些字**。
///
/// ## 背景（2026-10-17 用户报"我什么时候发过这种消息"）
///
/// 子代理结束时 `dsh-subagent` 会把
/// `Background subagent <childId> finished and will do no further work unless you
/// send it more. Its closing message: <整段收尾>` 作为一条 **`user/message`** 写进
/// 会话事件日志 —— 它就是这么唤醒父 agent 的。于是手机上出现一个蓝色右对齐气泡，
/// 内容和用户亲手打的字长得一模一样，里面还塞着子代理的整段收尾。
///
/// ## 两层配合
///
/// * **权威**：网关（`core.mjs` 的 `classifyHarnessNotice`）能读到事件上的
///   `data.source`，会把结论挂在消息的 `noticeKind` / `noticeVariant` /
///   `noticeChildId` / `noticeBody` 上。
/// * **兜底**（这里）：网关没给标记时（老网关、本地乐观消息），按**锚定在开头的
///   已知文案**认一次。锚定是刻意的 —— 正文中间提到 `Background subagent` 的人类
///   消息不该被当成通知。
///
/// ⚠️ 两边的文案清单是同一份知识、两种语言（`core.mjs` 的 `SETTLEMENT_VARIANTS`
/// 与这里的 [_settlementVariants]）。改文案要两边一起改，两边都有测试钉着。
library;

/// 一条注入通知的语义。字段全部是可空的：网关认不出的种类也要能如实渲染。
class HarnessNotice {
  const HarnessNotice({
    required this.kind,
    this.variant,
    this.childId,
    this.body,
  });

  /// `subagent-settlement` / `plugin:<name>` / `agent-instructions` / …（网关给）。
  final String kind;

  /// 子代理结算的收尾种类：`completed` / `aborted` / `max-tokens` / `unknown`。
  final String? variant;

  /// 结算通知里的子代理 id（原文里那串 uuid）。
  final String? childId;

  /// 收尾正文（已从原文里切掉 `Its closing message:` 标记）。
  final String? body;

  bool get isSubagentSettlement => kind == 'subagent-settlement';

  /// 展示用短 id：`915eb2f4-…` → `915eb2f4`。
  String? get shortChildId {
    final id = childId;
    if (id == null || id.isEmpty) return null;
    return id.length <= 8 ? id : id.substring(0, 8);
  }

  /// 网关给的标记优先（权威），没有标记才按文案兜底。
  ///
  /// [kind] 非空即认为网关已经判定过；此时即使正文认不出来也照样是通知 ——
  /// 网关能读到 `source`，它比这边多一个信号。
  static HarnessNotice? resolve({
    String? kind,
    String? variant,
    String? childId,
    String? body,
    required String content,
    bool mayBeNotice = true,
  }) {
    if (kind != null && kind.isNotEmpty) {
      return HarnessNotice(kind: kind, variant: variant, childId: childId, body: body);
    }
    if (!mayBeNotice) return null;
    return tryParse(content);
  }

  /// 纯文案判定（兜底路径）。认不出返回 null。
  static HarnessNotice? tryParse(String content) {
    final value = content.trim();
    if (value.isEmpty) return null;

    final match = _subagentSettlementRe.firstMatch(value);
    if (match == null) return null;

    return HarnessNotice(
      kind: 'subagent-settlement',
      variant: _settlementVariantOf(value),
      childId: match.group(1),
      body: _closingBodyOf(value),
    );
  }

  /// 与网关 `core.mjs` 的 `SUBAGENT_SETTLEMENT_RE` 等价（锚定开头）。
  static final RegExp _subagentSettlementRe = RegExp(r'^Background subagent (\S+)');

  static const String closingMarker = 'Its closing message:';

  /// 收尾种类。与网关的 `SETTLEMENT_VARIANTS` 是同一份知识。
  static const List<List<String>> _settlementVariants = [
    ['completed', 'finished and will do no further work'],
    ['aborted', 'was stopped before it finished'],
    ['max-tokens', 'ran out of room before it finished'],
  ];

  static String _settlementVariantOf(String value) {
    for (final entry in _settlementVariants) {
      if (value.contains(entry[1])) return entry[0];
    }
    return 'unknown';
  }

  static String? _closingBodyOf(String value) {
    final idx = value.indexOf(closingMarker);
    if (idx == -1) return null;
    final body = value.substring(idx + closingMarker.length).trim();
    return body.isEmpty ? null : body;
  }
}
