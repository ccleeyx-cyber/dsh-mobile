import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/approval_request.dart';
import '../theme/app_colors.dart';

typedef ApprovalResponseCallback = void Function(
  ApprovalRequest req,
  String outcome, [
  String? reason,
]);

class ApprovalCard extends StatefulWidget {
  final ApprovalRequest request;
  final ApprovalResponseCallback onRespond;

  const ApprovalCard({
    super.key,
    required this.request,
    required this.onRespond,
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
                        const SizedBox(width: 8),
                        Text(
                          '拒绝工具执行 (Reject Tool Call)',
                          style: TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.bold,
                            color: context.c.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '工具: ${widget.request.toolName} • 会话: ${widget.request.sessionId}',
                      style: TextStyle(fontSize: 12, color: context.c.textSecondary),
                    ),
                    const SizedBox(height: 14),

                    // Quick Chips
                    Text(
                      '快速选择拒绝原因 (可直接点击):',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: quickReasons.map((chip) {
                        return ActionChip(
                          label: Text(chip, style: const TextStyle(fontSize: 11.5)),
                          backgroundColor: context.c.surfaceMuted,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
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
                    const SizedBox(height: 12),

                    // Optional TextField
                    TextField(
                      controller: textController,
                      maxLines: 2,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: '输入具体拒绝理由（可选），智能体会根据说明调整后续方案...',
                        hintStyle: TextStyle(fontSize: 12, color: context.c.textTertiary),
                        filled: true,
                        fillColor: context.c.surfaceMuted,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: context.c.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: context.c.danger),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Action buttons
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: context.c.border),
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: () {
                              HapticFeedback.mediumImpact();
                              Navigator.pop(ctx);
                              widget.onRespond(widget.request, 'rejected', null);
                            },
                            child: Text('直接拒绝 (无理由)', style: TextStyle(color: context.c.textPrimary, fontSize: 13)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: context.c.danger,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: () {
                              HapticFeedback.heavyImpact();
                              final reason = textController.text.trim();
                              Navigator.pop(ctx);
                              widget.onRespond(widget.request, 'rejected', reason.isNotEmpty ? reason : null);
                            },
                            child: const Text('确认拒绝', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
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

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
      decoration: BoxDecoration(
        color: context.c.warningSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: context.c.warningBorder,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header strip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: context.c.warningBadgeSurface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.security_rounded,
                  color: context.c.warning,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '执行权限申请 (Tool Approval)',
                    style: TextStyle(
                      color: context.c.warning,
                      fontWeight: FontWeight.bold,
                      fontSize: 13.5,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: context.c.warning,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.terminal_rounded, size: 12, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(
                        req.toolName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
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
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Description/Reason
                Text(
                  req.reason.isNotEmpty ? req.reason : '智能体申请调用 ${req.toolName} 执行任务',
                  style: TextStyle(
                    color: context.c.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),

                // Command Preview Box
                if (hasCommand) ...[
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: context.c.textPrimary,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: context.c.textPrimary),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Command header bar
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          child: Row(
                            children: [
                              const Icon(Icons.code_rounded, size: 14, color: Color(0xFF38BDF8)),
                              const SizedBox(width: 6),
                              Text(
                                '执行指令',
                                style: TextStyle(
                                  color: context.c.textSecondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Spacer(),
                              InkWell(
                                onTap: () => _copyToClipboard(context, req.command!, '执行指令'),
                                borderRadius: BorderRadius.circular(4),
                                child: Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                  child: Row(
                                    children: [
                                      Icon(Icons.copy_rounded, size: 12, color: context.c.textSecondary),
                                      SizedBox(width: 3),
                                      Text('复制', style: TextStyle(color: context.c.textSecondary, fontSize: 11)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: context.c.textPrimary),
                        // Command snippet with scroll
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 140),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(10),
                            child: SelectableText.rich(
                              TextSpan(
                                children: [
                                  const TextSpan(
                                    text: '\$ ',
                                    style: TextStyle(
                                      color: Color(0xFF34D399),
                                      fontWeight: FontWeight.bold,
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                    ),
                                  ),
                                  TextSpan(
                                    text: req.command!,
                                    style: TextStyle(
                                      color: context.c.background,
                                      fontFamily: 'monospace',
                                      fontSize: 12,
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
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: context.c.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: context.c.border),
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
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            child: Row(
                              children: [
                                Icon(Icons.data_object_rounded, size: 14, color: context.c.textSecondary),
                                const SizedBox(width: 6),
                                Text(
                                  '参数载荷 (Arguments)',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.c.textSecondary),
                                ),
                                const Spacer(),
                                Icon(
                                  _isInputExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
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
                              padding: const EdgeInsets.all(10),
                              child: SelectableText(
                                _formatInput(req.input),
                                style: TextStyle(
                                  fontSize: 11,
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
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.tag_rounded, size: 12, color: context.c.textTertiary),
                      const SizedBox(width: 4),
                      Text(
                        '调用编号: ${req.callId}',
                        style: TextStyle(
                          fontSize: 11,
                          color: context.c.textSecondary,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          // Actions Bar
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 14, bottom: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Reject Button with Sheet on tap and instant reject on long-press
                Tooltip(
                  message: '轻触打开拒绝选项，长按直接拒绝',
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
                    icon: Icon(Icons.close_rounded, size: 16, color: context.c.danger),
                    label: Text('拒绝 (Reject)', style: TextStyle(color: context.c.danger)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFFFCA5A5)),
                      backgroundColor: context.c.surface,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Allow Once Button
                ElevatedButton.icon(
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    widget.onRespond(req, 'allowed-once', null);
                  },
                  icon: const Icon(Icons.check_rounded, size: 16, color: Colors.white),
                  label: const Text('允许一次 (Allow)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: context.c.success,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
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
