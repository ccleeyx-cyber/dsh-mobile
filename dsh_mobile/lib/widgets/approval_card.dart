import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/approval_request.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

typedef ApprovalResponseCallback = void Function(
  ApprovalRequest req,
  String outcome, [
  String? reason,
]);

/// 是否为「高风险」审批 —— 全 App 唯一的判定源（审批卡提示 + dock 的批量批准）。
///
/// **它不是安全边界**。审批的权威判定在引擎侧；这里只是一个"该不该默认勾选"的
/// 预选依据，用来让用户在一屏里最先看到真正危险的那一条。
///
/// 规则刻意窄：只认「不可逆 / 提权 / 直写块设备 / 管道执行远端脚本」这几类，
/// 外加名字里明显带删除语义的工具。写文件、改代码**不算**高风险 —— 那是 agent
/// 的日常动作，把它们标红只会让红色失去意义（可用性上的"狼来了"）。
bool looksHighRiskApproval(ApprovalRequest request) {
  final command = (request.command ?? '').toLowerCase();
  final probe = command.isNotEmpty ? command : _flattenInput(request.input);

  const hardPatterns = [
    'rm -rf',
    'rm -fr',
    'rm -r ',
    'sudo ',
    'su -',
    'mkfs',
    'dd if=',
    'dd of=',
    ':(){',
    'chmod 777 /',
    'chown -r /',
    'git push --force',
    'git push -f',
    'git reset --hard',
    'git clean -f',
    'shutdown',
    'reboot',
    '| sh',
    '|sh',
    '| bash',
    '|bash',
    'curl -fssl',
    '> /dev/sd',
    '/etc/passwd',
    '/etc/shadow',
    'drop table',
  ];
  if (hardPatterns.any(probe.contains)) return true;

  final tool = request.toolName.toLowerCase();
  const destructiveTools = ['delete', 'remove', 'destroy', 'drop', 'purge', 'wipe'];
  return destructiveTools.any(tool.contains);
}

/// 审批载荷压成一段可搜索的小写文本。只用于高风险关键词匹配。
String _flattenInput(dynamic input) {
  if (input == null) return '';
  String raw;
  if (input is String) {
    raw = input;
  } else {
    try {
      raw = jsonEncode(input);
    } catch (_) {
      raw = input.toString();
    }
  }
  // 输入可能是几 MB 的文件内容 —— 关键词只可能出现在开头（命令/路径）。
  return raw.length > 4000 ? raw.substring(0, 4000).toLowerCase() : raw.toLowerCase();
}

/// 审批卡 —— 消息流里**唯一**保留卡片形态的元素（Phase 2.4）。
///
/// 其余消息元素（AI 正文、思考、工具调用）都退成了无底色无描边的文字层级，
/// 因为它们的共同特征是「已经发生、无需操作」。审批卡相反：agent 正停在这道
/// 门前等一个决定，用户不做任何事整条链路就不动。所以它必须在一屏灰色文字里
/// 一眼可见 —— warningSurface 底 + 1.5px warning 描边 + 顶部 4px 实心色条，
/// 这是全 App 唯一同时用了「底色 + 描边 + 强调条」三重提示的地方。
class ApprovalCard extends StatefulWidget {
  final ApprovalRequest request;
  final ApprovalResponseCallback onRespond;

  /// 「稍后处理」（Phase 5.5）：把这张卡暂时收起 15 分钟，**不改网关状态**。
  ///
  /// 为什么需要它：审批是打断式的（agent 停在这里等你），但"我现在不在电脑前、
  /// 十分钟后再看"是真实且高频的场景。以前只有"批准/拒绝"两个出口，用户只能
  /// 二选一：要么在没看清的情况下批准，要么拒绝掉一个其实该做的事。
  ///
  /// 为 null 时**不渲染这个按钮** —— 不给点了没反应的入口（本仓库硬规则）。
  /// 注意它和"拒绝"有本质区别：拒绝是**发给网关的决定**，稍后只是本地收起。
  final VoidCallback? onSnooze;

  const ApprovalCard({
    super.key,
    required this.request,
    required this.onRespond,
    this.onSnooze,
  });

  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  bool _isInputExpanded = false;

  String _formatInput(dynamic input) {
    if (input == null) return '';
    if (input is String) return input;
    if (input is Map || input is List) {
      try {
        return const JsonEncoder.withIndent('  ').convert(input);
      } catch (_) {
        return input.toString();
      }
    }
    return input.toString();
  }

  void _copyToClipboard(BuildContext context, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制 $label 到剪贴板'),
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showRejectReasonSheet(BuildContext context) {
    final textController = TextEditingController();
    final quickReasons = [
      '⚠️ 包含高危/越权指令',
      '❌ 命令或参数错误',
      '⏭️ 跳过此步骤',
      '🛑 手动终止会话',
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 14,
                  bottom: MediaQuery.of(modalCtx).viewInsets.bottom + 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Drag pill
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

                    // Sheet Header
                    Row(
                      children: [
                        Icon(Icons.gpp_bad_rounded, color: context.c.danger, size: 22),
                        const SizedBox(width: AppSpace.m),
                        Expanded(
                          child: Text(
                            '拒绝工具执行 (Reject Tool Call)',
                            style: TextStyle(
                              fontSize: AppText.heading,
                              fontWeight: FontWeight.bold,
                              color: context.c.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '工具: ${widget.request.toolName} • 会话: ${widget.request.sessionId}',
                      style: TextStyle(
                        fontSize: AppText.body,
                        color: context.c.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Quick Chips
                    Text(
                      '快速选择拒绝原因 (可直接点击):',
                      style: TextStyle(
                        fontSize: AppText.body,
                        fontWeight: FontWeight.w600,
                        color: context.c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: AppSpace.m),
                    Wrap(
                      spacing: AppSpace.m,
                      runSpacing: 6,
                      children: quickReasons.map((chip) {
                        return ActionChip(
                          label: Text(chip, style: const TextStyle(fontSize: AppText.subhead)),
                          backgroundColor: context.c.surfaceMuted,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppSpace.m),
                            side: BorderSide(color: context.c.border),
                          ),
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            setModalState(() {
                              textController.text = chip;
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: AppSpace.l),

                    // Optional TextField
                    TextField(
                      controller: textController,
                      maxLines: 2,
                      style: const TextStyle(fontSize: AppText.title),
                      decoration: InputDecoration(
                        hintText: '输入具体拒绝理由（可选），智能体会根据说明调整后续方案...',
                        hintStyle: TextStyle(
                          fontSize: AppText.body,
                          color: context.c.textTertiary,
                        ),
                        filled: true,
                        fillColor: context.c.surfaceMuted,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.l,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppSpace.m),
                          borderSide: BorderSide(color: context.c.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppSpace.m),
                          borderSide: BorderSide(color: context.c.danger),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpace.xl),

                    // Action buttons
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: context.c.border),
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(AppSpace.m),
                              ),
                            ),
                            onPressed: () {
                              HapticFeedback.mediumImpact();
                              Navigator.pop(ctx);
                              widget.onRespond(widget.request, 'rejected', null);
                            },
                            child: Text(
                              '直接拒绝 (无理由)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: context.c.textPrimary,
                                fontSize: AppText.title,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpace.l),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: context.c.danger,
                              foregroundColor: context.c.surface,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(AppSpace.m),
                              ),
                            ),
                            onPressed: () {
                              HapticFeedback.heavyImpact();
                              final reason = textController.text.trim();
                              Navigator.pop(ctx);
                              widget.onRespond(
                                widget.request,
                                'rejected',
                                reason.isNotEmpty ? reason : null,
                              );
                            },
                            child: Text(
                              '确认拒绝',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: AppText.title,
                                color: context.c.surface,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
      // The controller is a local to this method, so nothing else can dispose
      // it. The sheet's Future completes once the route is popped and its
      // widget tree torn down, making this the correct release point —
      // previously it leaked one TextEditingController per sheet open.
    ).whenComplete(textController.dispose);
  }

  @override
  Widget build(BuildContext context) {
    final req = widget.request;
    final hasCommand = req.command != null && req.command!.trim().isNotEmpty;
    final hasInput = req.input != null;
    final highRisk = looksHighRiskApproval(req);

    // 实心 accent / warning 底上的前景色。
    //
    // 用 `surface` 而不是 `Colors.white`：深色主题的品牌色是提亮过的 #6E8BFF，
    // 白字压在它上面只有约 3:1（低于正文 AA 4.5:1），而 `surface` 在深色下是近黑
    // 的 #161B22 —— 同一个 token 在亮色下是纯白、深色下是近黑，恰好都是 accent 的
    // 正确前景色。写死白色会在深色模式下变成"浅底浅字"。
    final onAccent = context.c.surface;

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpace.l,
        vertical: AppSpace.m,
      ),
      // 顶部 4px 色条要跟着圆角走，所以整卡 clip 而不是给色条单独设圆角 ——
      // 单独设圆角时描边会从色条外侧露出来 1.5px，看起来像没对齐。
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: context.c.warningSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.c.warning, width: 1.5),
        // 去掉了改动前的 boxShadow（black 4% + blur 8）：滚动容器里每个带阴影的
        // item 每帧一次 saveLayer，而 4% 的黑影在两种主题下都看不出来。
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部 4px 强调条
          Container(height: 4, color: context.c.warning),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.l,
              AppSpace.m,
              AppSpace.l,
              AppSpace.m,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: context.c.warning,
                  size: 18,
                ),
                const SizedBox(width: AppSpace.s),
                Expanded(
                  child: Text(
                    '需要你的批准',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.c.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: AppText.title,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.s),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.m, vertical: 3),
                  decoration: BoxDecoration(
                    color: context.c.warning,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.terminal_rounded, size: 12, color: onAccent),
                      const SizedBox(width: AppSpace.s),
                      Text(
                        req.toolName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: onAccent,
                          fontSize: AppText.subhead,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Body content
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.l,
              0,
              AppSpace.l,
              AppSpace.m,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Description/Reason
                Text(
                  req.reason.isNotEmpty
                      ? req.reason
                      : '智能体申请调用 ${req.toolName} 执行任务',
                  style: TextStyle(
                    color: context.c.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: AppText.title,
                    height: 1.4,
                  ),
                ),

                // Command Preview Box
                if (hasCommand) ...[
                  const SizedBox(height: AppSpace.m),
                  Container(
                    decoration: BoxDecoration(
                      color: context.c.codeBackground,
                      borderRadius: BorderRadius.circular(AppSpace.m),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpace.m,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.code_rounded,
                                size: 14,
                                color: context.c.accent,
                              ),
                              const SizedBox(width: AppSpace.s),
                              Expanded(
                                child: Text(
                                  '执行指令',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: context.c.textSecondary,
                                    fontSize: AppText.caption,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () =>
                                    _copyToClipboard(context, req.command!, '执行指令'),
                                borderRadius: BorderRadius.circular(AppSpace.s),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 2,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.copy_rounded,
                                        size: 12,
                                        color: context.c.textSecondary,
                                      ),
                                      const SizedBox(width: AppSpace.xs),
                                      Text(
                                        '复制',
                                        style: TextStyle(
                                          color: context.c.textSecondary,
                                          fontSize: AppText.caption,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: context.c.border),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 140),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(AppSpace.m),
                            child: SelectableText.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '\$ ',
                                    style: TextStyle(
                                      color: context.c.terminalGreen,
                                      fontWeight: FontWeight.bold,
                                      fontFamily: 'monospace',
                                      fontSize: AppText.subhead,
                                    ),
                                  ),
                                  TextSpan(
                                    text: req.command!,
                                    style: TextStyle(
                                      color: context.c.textPrimary,
                                      fontFamily: 'monospace',
                                      fontSize: AppText.subhead,
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Tool Payload / Arguments Inspection Box
                if (hasInput && !hasCommand) ...[
                  const SizedBox(height: AppSpace.m),
                  Container(
                    decoration: BoxDecoration(
                      color: context.c.codeBackground,
                      borderRadius: BorderRadius.circular(AppSpace.m),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        InkWell(
                          onTap: () {
                            setState(() {
                              _isInputExpanded = !_isInputExpanded;
                            });
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpace.m,
                              vertical: 7,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.data_object_rounded,
                                  size: 14,
                                  color: context.c.textSecondary,
                                ),
                                const SizedBox(width: AppSpace.s),
                                Expanded(
                                  child: Text(
                                    '参数载荷 (Arguments)',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: AppText.caption,
                                      fontWeight: FontWeight.bold,
                                      color: context.c.textSecondary,
                                    ),
                                  ),
                                ),
                                Icon(
                                  _isInputExpanded
                                      ? Icons.expand_less_rounded
                                      : Icons.expand_more_rounded,
                                  size: 16,
                                  color: context.c.textSecondary,
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_isInputExpanded) ...[
                          Divider(height: 1, color: context.c.border),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 160),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(AppSpace.m),
                              child: SelectableText(
                                _formatInput(req.input),
                                style: TextStyle(
                                  fontSize: AppText.subhead,
                                  fontFamily: 'monospace',
                                  color: context.c.textPrimary,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],

                // CallId chip
                if (req.callId != null && req.callId!.isNotEmpty) ...[
                  const SizedBox(height: AppSpace.m),
                  Row(
                    children: [
                      Icon(Icons.tag_rounded, size: 12, color: context.c.textTertiary),
                      const SizedBox(width: AppSpace.s),
                      Expanded(
                        child: Text(
                          '调用编号: ${req.callId}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppText.caption,
                            color: context.c.textSecondary,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          // Actions Bar
          //
          // 等宽双按钮（Expanded ×2）而不是 Wrap：审批是全 App 唯一一处
          //「阻塞型动作」，两个按钮的点击面积必须一样大、位置必须稳定。标签
          // 从「允许一次 (Allow) / 拒绝 (Reject)」收短成「批准 / 拒绝」是为了
          // 让 1.3x 系统字号下两个按钮都还塞得下 —— 中英并列那是给对着引擎日志
          // 核对的开发场景用的，不该压在手机上唯一一处必须点的按钮上。
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.l,
              0,
              AppSpace.l,
              AppSpace.l,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 高风险行。这一行只在高风险时出现 —— 它的作用是给"批准"按下
                // 之前最后一个反悔理由，不是常驻装饰。
                if (highRisk) ...[
                  Row(
                    children: [
                      Icon(
                        Icons.report_gmailerrorred_rounded,
                        size: 13,
                        color: context.c.danger,
                      ),
                      const SizedBox(width: AppSpace.s),
                      Expanded(
                        child: Text(
                          '高风险操作，请确认命令与路径',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppText.caption,
                            color: context.c.danger,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.m),
                ],
                Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: '轻触选择拒绝理由，长按直接拒绝',
                        child: OutlinedButton.icon(
                          onPressed: () => _showRejectReasonSheet(context),
                          onLongPress: () {
                            HapticFeedback.heavyImpact();
                            widget.onRespond(req, 'rejected', null);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('已直接拒绝工具执行'),
                                duration: Duration(milliseconds: 1500),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                          icon: Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: context.c.danger,
                          ),
                          label: Text(
                            '拒绝',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.c.danger,
                              fontWeight: FontWeight.w600,
                              fontSize: AppText.title,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: context.c.danger),
                            // minimumSize 而不是固定 height：1.3x 系统字号下文字
                            // 高度会超过 44，写死高度就是 RenderFlex 溢出。
                            minimumSize: const Size.fromHeight(44),
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(9),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpace.l),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          widget.onRespond(req, 'allowed-once', null);
                        },
                        icon: Icon(Icons.check_rounded, size: 16, color: onAccent),
                        label: Text(
                          '批准',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: onAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: AppText.title,
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: context.c.accent,
                          foregroundColor: onAccent,
                          minimumSize: const Size.fromHeight(44),
                          padding: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(9),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                // 第三出口：「稍后」。视觉上刻意弱于双主按钮 —— 它是"推迟决定"，
                // 不是"做决定"，不该和批准/拒绝抢同一档权重。
                if (widget.onSnooze != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.m),
                    child: Align(
                      alignment: Alignment.center,
                      child: TextButton.icon(
                        key: const ValueKey('approval-snooze'),
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          widget.onSnooze!();
                        },
                        icon: Icon(
                          Icons.snooze_rounded,
                          size: 15,
                          color: context.c.textSecondary,
                        ),
                        label: Text(
                          '稍后（15 分钟后提醒）',
                          style: TextStyle(
                            fontSize: AppText.body,
                            color: context.c.textSecondary,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          minimumSize: const Size.fromHeight(36),
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
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
}
