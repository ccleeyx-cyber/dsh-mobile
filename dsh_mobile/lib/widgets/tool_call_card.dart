import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/chat_message.dart';

class ToolCallCard extends StatefulWidget {
  final ToolExecution tool;

  const ToolCallCard({super.key, required this.tool});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;
  final ScrollController _inputScrollController = ScrollController();
  final ScrollController _outputScrollController = ScrollController();

  @override
  void dispose() {
    _inputScrollController.dispose();
    _outputScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ToolCallCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Follow streaming output if expanded and user is near bottom
    if (_expanded && widget.tool.output.isNotEmpty && widget.tool.output != oldWidget.tool.output) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_outputScrollController.hasClients) {
          final pos = _outputScrollController.position;
          if (pos.maxScrollExtent - pos.pixels < 40) {
            _outputScrollController.jumpTo(pos.maxScrollExtent);
          }
        }
      });
    }
  }

  void _toggleExpanded() {
    HapticFeedback.selectionClick();
    setState(() => _expanded = !_expanded);
  }

  String _formatSummary(ToolExecution tool) {
    if (tool.isRunning) return '运行中...';
    if (tool.output.isEmpty) return '完成 (无输出)';
    final lines = tool.output.split('\n').length;
    final chars = tool.output.length;
    final sizeStr = chars >= 1024 ? '${(chars / 1024).toStringAsFixed(1)} KB' : '$chars B';
    return '$lines 行 · $sizeStr';
  }

  IconData _getToolIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('bash') || lower.contains('sh') || lower.contains('cmd') || lower.contains('terminal') || lower.contains('exec')) {
      return Icons.terminal_rounded;
    }
    if (lower.contains('read') || lower.contains('cat') || lower.contains('file')) {
      return Icons.description_outlined;
    }
    if (lower.contains('search') || lower.contains('grep') || lower.contains('find')) {
      return Icons.search_rounded;
    }
    if (lower.contains('edit') || lower.contains('write') || lower.contains('patch')) {
      return Icons.edit_note_rounded;
    }
    return Icons.build_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final isRunning = widget.tool.isRunning;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isRunning ? const Color(0xFF0078D4).withOpacity(0.4) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _toggleExpanded,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    _getToolIcon(widget.tool.name),
                    size: 15,
                    color: isRunning ? const Color(0xFF0078D4) : const Color(0xFF475569),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '工具调用: ${widget.tool.name}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1E293B),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isRunning
                          ? const Color(0xFF0078D4).withOpacity(0.1)
                          : const Color(0xFF10B981).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isRunning) ...[
                          const SizedBox(
                            width: 8,
                            height: 8,
                            child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF0078D4)),
                          ),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          _formatSummary(widget.tool),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: isRunning ? const Color(0xFF0078D4) : const Color(0xFF059669),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: const Color(0xFF94A3B8),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '输入参数:',
                        style: TextStyle(fontSize: 10.5, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                      ),
                      if (widget.tool.input.isNotEmpty)
                        InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: widget.tool.input));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('已复制输入参数'),
                                duration: Duration(seconds: 1),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            child: Row(
                              children: const [
                                Icon(Icons.copy_rounded, size: 11, color: Color(0xFF64748B)),
                                SizedBox(width: 3),
                                Text('复制', style: TextStyle(fontSize: 10.5, color: Color(0xFF64748B))),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 240),
                    padding: const EdgeInsets.all(7),
                    margin: const EdgeInsets.only(top: 3, bottom: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Scrollbar(
                      controller: _inputScrollController,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _inputScrollController,
                        child: SelectableText(
                          widget.tool.input,
                          style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Color(0xFF334155)),
                        ),
                      ),
                    ),
                  ),
                  if (widget.tool.output.isNotEmpty || isRunning) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '执行输出 (${widget.tool.output.split('\n').length} 行):',
                          style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                        ),
                        if (widget.tool.output.isNotEmpty)
                          InkWell(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: widget.tool.output));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已复制执行输出'),
                                  duration: Duration(seconds: 1),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              child: Row(
                                children: const [
                                  Icon(Icons.copy_rounded, size: 11, color: Color(0xFF64748B)),
                                  SizedBox(width: 3),
                                  Text('复制', style: TextStyle(fontSize: 10.5, color: Color(0xFF64748B))),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 240),
                      padding: const EdgeInsets.all(7),
                      margin: const EdgeInsets.only(top: 3, bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Scrollbar(
                        controller: _outputScrollController,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: _outputScrollController,
                          child: SelectableText(
                            widget.tool.output.isEmpty ? '等待执行结果输出...' : widget.tool.output,
                            style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Color(0xFF334155)),
                          ),
                        ),
                      ),
                    ),
                  ],
                  InkWell(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _expanded = false);
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.keyboard_arrow_up_rounded, size: 14, color: Color(0xFF64748B)),
                          SizedBox(width: 4),
                          Text(
                            '收起工具调用',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFF64748B),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
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

