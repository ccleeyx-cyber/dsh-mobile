import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/user_question.dart';
import '../../theme/app_colors.dart';

/// 一张等待本机回答的提问卡片（§4.1-1「回答 Agent 提问」）。
///
/// 契约来自 `@deepseek-ai/dsh-user-questions` 的 `AskUserQuestionRequestEvent`，
/// 所以这里刻意不做任何"更友好"的简化：
///
/// - `intent.kind == 'plan-review'` 时，`intent.approve` 指名的那一项是**批准**，
///   其余全是**否决**。绝不能靠选项顺序推断结论 —— 引擎专门把它做成按名指定，
/// 就是为了防止 UI 猜错。
/// - `intent` 缺失时按普通单选题渲染。引擎文档明确说：认识不了这个 tag 的 UI
///   就走通用流程，**答案编码完全一样**。
/// - 多选题（`multiSelect`）必须允许选多个，也必须允许「都不选 + 自定义」。
/// 卡片自身的上下 margin 合计（8 + 4），限高时要扣掉它。
const double _kVerticalMargin = 12;

class QuestionCard extends StatefulWidget {
  final PendingQuestion pending;
  final bool canAnswer;
  /// 返回 true 表示**已成功发出**。卡片据此决定要不要恢复可提交状态 ——
  /// 所以它必须反映传输结果，而不是"用户点了"。
  final bool Function(Map<String, List<String>> selections, Map<String, String> customs) onSubmit;
  final VoidCallback onDismiss;

  /// [fix 2026-10-21] 卡片允许的最大高度，由调用方按**可用空间**给。
  ///
  /// 原来写死 420：真机上 dock（提问/审批区）的上限是 0.45 屏高（约 350dp），
  /// 卡片比它高，于是"提交回答"这一行落在可视区之外。而 dock 外层还有一层
  /// SingleChildScrollView，卡片内部又有自己的滚动区 —— 手指在选项上下拖时
  /// 滚的是内层，外层纹丝不动，用户看到的就是"提交按钮点不到"。
  final double maxHeight;

  const QuestionCard({
    super.key,
    required this.pending,
    required this.canAnswer,
    required this.onSubmit,
    required this.onDismiss,
    this.maxHeight = 420,
  });

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  /// questionId -> 选中的选项 label
  final Map<String, List<String>> _selections = {};
  /// questionId -> 自定义文本
  final Map<String, String> _customs = {};
  bool _submitting = false;

  /// [fix 2026-10-20] 提交后的兜底计时器，见 [_submit]。
  Timer? _submitTimeout;

  /// 超时没等到网关 `question_settled` 时置真，用于给出「可重试」的提示。
  bool _retryHint = false;

  bool _isAnswered(AskUserQuestionItem item) {
    if ((_selections[item.id] ?? const <String>[]).isNotEmpty) return true;
    return (_customs[item.id] ?? '').trim().isNotEmpty;
  }

  bool get _allAnswered => widget.pending.questions.every(_isAnswered);

  bool get _isPlanReview => widget.pending.questions.any((q) => q.intent?.kind == 'plan-review');

  void _toggle(AskUserQuestionItem item, String label) {
    setState(() {
      final cur = _selections[item.id] ?? <String>[];
      if (!item.multiSelect) {
        // 单选：再点一次 = 取消选择。允许取消是因为用户可能只是误触，
        // 而引擎允许"自定义"路径，不该逼用户去输入框才能表达"我都不选"。
        _selections[item.id] = cur.length == 1 && cur.first == label ? <String>[] : [label];
      } else {
        _selections[item.id] =
            cur.contains(label) ? cur.where((x) => x != label).toList() : [...cur, label];
      }
    });
  }

  Future<void> _submit() async {
    if (!_allAnswered || _submitting) return;
    setState(() {
      _submitting = true;
      _retryHint = false;
    });
    final ok = widget.onSubmit(Map.of(_selections), Map.of(_customs));
    // 不在这里清卡片：网关的 question_settled 才是权威信号。乐观移除会在提交
    // 失败时把唯一的重试入口也一起弄丢。
    if (!ok) {
      if (mounted) setState(() => _submitting = false);
      return;
    }

    // [fix 2026-10-20] 只依赖 settled 事件，等于把这张卡押在「事件一定送达」上。
    // 重连 / 切后台 / 网关重启都会丢事件，卡片就永久停在「发送中…」且按钮禁用：
    // 用户既不能重发也不能改答，而 agent 侧一直阻塞。
    //
    // 兜底 8 秒：到时卡片仍在本树里（说明没收到 settled）就恢复可点，并提示可重试。
    // 真正的成功路径不受影响 —— settled 到达后卡片会被移除，这个 timer 随 dispose 取消。
    _submitTimeout?.cancel();
    _submitTimeout = Timer(const Duration(seconds: 8), () {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _retryHint = true;
      });
    });
  }

  @override
  void dispose() {
    _submitTimeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.pending;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      // 卡片挂在输入框上方的固定区（不在消息 ListView 里），自身不可滚动。
      // 选项一多（多选题 + 每项带 description）整张卡被顶出屏幕，提交按钮
      // 根本够不着 —— 用户实测"最下面没法提交"。所以这里必须自己限高，
      // 让**题目区**滚动，提交按钮钉在卡片底部永远可见。
      //
      // [fix 2026-10-21] maxHeight 的语义是「这张卡**占用的总高度**上限」，
      // 所以要扣掉自己的上下 margin（8+4）。否则调用方按 dock 的可用高度传
      // 300，卡片实际占到 312，提交行仍然会被切掉一点点。
      constraints: BoxConstraints(
        maxHeight: (widget.maxHeight - _kVerticalMargin).clamp(160.0, 2000.0),
      ),
      decoration: BoxDecoration(
        color: context.c.questionSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.c.questionBorder, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // header
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
            child: Row(
              children: [
                Icon(Icons.help_outline_rounded, size: 17, color: context.c.orange),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _isPlanReview ? 'Agent 请你审阅一份计划' : 'Agent 有问题要问你',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.c.orange,
                    ),
                  ),
                ),
                // 收起不是"作答"。引擎侧这个请求仍然挂着，所以这里只隐藏界面，
                // 明确提示用户「可以到桌面端回答」，避免以为问题已经消失。
                InkWell(
                  onTap: () async {
                    final confirmed = await _confirmSheet(context);
                    if (confirmed == true) widget.onDismiss();
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close_rounded, size: 16, color: context.c.warning),
                  ),
                ),
              ],
            ),
          ),
          Divider(color: context.c.questionBorder, height: 1),

          // questions —— 可滚动区。Flexible 使其在卡片 maxHeight 内收缩，
          // 而不是把整张卡无限撑高。
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...q.questions.map(_buildQuestion),
                  if (!widget.canAnswer) _buildOfflineNotice(),
                ],
              ),
            ),
          ),

          // submit
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    // [fix 2026-10-20] 超时未收到确认时的出口提示（见 _submit 的兜底）。
                    _retryHint && _allAnswered && widget.canAnswer
                        ? '没收到确认，可再点一次提交'
                        : _allAnswered
                            ? '将把回答发送给 Agent'
                            // 旧文案只说「请回答上面每一道题」，但没告诉用户漏选时
                            // 怎么办 —— 结果就是按钮一直灰着、看不出出路。直接把
                            // 出路写出来。
                            : '每道题都要有答复：选项、或者下面那句话${q.questions.length > 1 ? '（共 ${q.questions.length} 道）' : ''}',
                    style: TextStyle(
                      fontSize: 11,
                      color: _retryHint && _allAnswered ? context.c.danger : context.c.orange,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: (_allAnswered && widget.canAnswer && !_submitting) ? _submit : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: context.c.orange,
                    disabledBackgroundColor: context.c.border,
                    disabledForegroundColor: context.c.textTertiary,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    _submitting ? '发送中…' : '提交回答',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmSheet(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('在手机上略过这个提问？'),
        content: const Text(
          '这不是拒绝回答。Agent 那边仍在等待，你可以到桌面端 Web 界面回答它；'
          '两边回答的是同一个请求。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('继续回答')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('在手机上收起'),
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineNotice() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: context.c.dangerSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.c.dangerBorder),
      ),
      child: Text(
        '当前未连接到网关，无法提交回答。Agent 仍在等待。',
        style: TextStyle(fontSize: 11, color: context.c.danger),
      ),
    );
  }

  Widget _buildQuestion(AskUserQuestionItem item) {
    final selected = _selections[item.id] ?? const <String>[];
    final custom = _customs[item.id] ?? '';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: context.c.questionBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item.header != null && item.header!.isNotEmpty) ...[
            Text(
              item.header!,
              style: TextStyle(fontSize: 10.5, color: context.c.warning, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 3),
          ],
          Text(
            item.question,
            style: TextStyle(fontSize: 13.5, color: context.c.textPrimary, height: 1.35),
          ),
          if (item.detail != null && item.detail!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 132),
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: context.c.surfaceMuted,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: context.c.border),
              ),
              child: SingleChildScrollView(
                child: Text(
                  item.detail!,
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: context.c.textPrimary),
                ),
              ),
            ),
          ],
          if (item.options.isNotEmpty) ...[
            const SizedBox(height: 9),
            // 按名指定批准项，绝不按顺序。
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: item.options.map((o) {
                final isSelected = selected.contains(o.label);
                final isApprove = item.approvesWith(o.label);
                return _OptionChip(
                  option: o,
                  selected: isSelected,
                  isApprove: isApprove,
                  onTap: () => _toggle(item, o.label),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 9),
          TextField(
            minLines: 1,
            maxLines: 4,
            // setState is required: filling the custom box is what makes an
            // option-less question answerable, and the submit button's enabled
            // state is derived from _allAnswered. Mutating _customs alone would
            // leave the button greyed out with no way to submit.
            onChanged: (v) => setState(() => _customs[item.id] = v),
            style: const TextStyle(fontSize: 12.5),
            decoration: InputDecoration(
              isDense: true,
              // 逃生口的说法要说清楚，不能只写「可选」：
              // _allAnswered 要求**每一题**都给出 selected 或 custom，而引擎的
              // isAnswered 契约同样不接受空答案 —— 所以多选题漏选时，用户唯一
              // 能走的路就是把这句话填出来（比如「跳过此题，先按你的方案执行」）。
              // 旧文案写成「可选」让人以为留空也算答了，于是提交按钮永远灰着，
              // 看起来像卡死。这句话必须写明它同时是「不选任何项」的唯一出口。
              hintText: item.options.isEmpty
                  ? '输入你的回答…'
                  : '不想选？在这里写一句也算回答（如「跳过此项，先按你的方案执行」）',
              hintStyle: TextStyle(fontSize: 12, color: context.c.textTertiary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: BorderSide(color: context.c.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: BorderSide(
                  color: custom.trim().isNotEmpty ? context.c.orange : context.c.border,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: BorderSide(color: context.c.orange, width: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionChip extends StatelessWidget {
  final AskUserQuestionOption option;
  final bool selected;
  final bool isApprove;
  final VoidCallback onTap;

  const _OptionChip({
    required this.option,
    required this.selected,
    required this.isApprove,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? context.c.warningBadgeSurface : context.c.surface,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: selected ? context.c.orange : context.c.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? Icons.check_circle_rounded : Icons.circle_outlined,
              size: 14,
              color: selected ? context.c.orange : context.c.textTertiary,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    option.label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                      color: selected ? context.c.orange : context.c.textPrimary,
                    ),
                  ),
                  if (option.description != null && option.description!.isNotEmpty)
                    Text(
                      option.description!,
                      style: TextStyle(fontSize: 10.5, color: context.c.textSecondary),
                    ),
                ],
              ),
            ),
            // 只在真的认得出批准项时才标"批准"。引擎会拒绝 approve 指向不存在
            // 选项的 intent，所以这里显示"批准"是安全的；反之若 intent 缺失，
            // 一律不标 —— 免得把任意一个选项误标成批准动作。
            if (isApprove) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: context.c.successSurface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFF86EFAC)),
                ),
                child: const Text(
                  '批准',
                  style: TextStyle(fontSize: 9.5, color: Color(0xFF15803D), fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 当前会话的 TODO 进度面板（§4.1-2）。
///
/// `todo/write` 是**整表替换**，所以这里不做增量合并：每次收到的都是全量快照，
/// 直接渲染。引擎的三个状态值只有 pending / in_progress / completed，其余一律
/// 当成 pending 显示，而不是抛异常 —— 一个不认识的状态不该让整个面板消失。
class TodoPanel extends StatelessWidget {
  final List<TodoItem> todos;

  const TodoPanel({super.key, required this.todos});

  int get _done => todos.where((t) => t.isDone).length;

  @override
  Widget build(BuildContext context) {
    if (todos.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: context.c.border),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 4, offset: const Offset(0, 1)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.checklist_rounded, size: 15, color: context.c.textSecondary),
              const SizedBox(width: 6),
              Text(
                '任务进度',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: context.c.textPrimary),
              ),
              const Spacer(),
              Text(
                '$_done/${todos.length}',
                style: TextStyle(fontSize: 11.5, color: context.c.textTertiary),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: todos.isEmpty ? 0 : _done / todos.length,
              minHeight: 4,
              backgroundColor: context.c.surfaceMuted,
              valueColor: AlwaysStoppedAnimation(context.c.success),
            ),
          ),
          const SizedBox(height: 10),
          ...todos.map((t) => _buildRow(context, t)),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, TodoItem t) {
    final done = t.isDone;
    final active = t.isActive;
    final color = done
        ? context.c.textTertiary
        : (active ? context.c.accent : context.c.textSecondary);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            done
                ? Icons.check_circle_rounded
                : (active ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded),
            size: 14,
            color: color,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              t.content,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: color,
                decoration: done ? TextDecoration.lineThrough : null,
                decorationColor: context.c.textTertiary,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}