import 'package:flutter/material.dart';
import '../models/chat_message.dart';

class ToolCallCard extends StatefulWidget {
  final ToolExecution tool;

  const ToolCallCard({super.key, required this.tool});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: widget.tool.isRunning ? const Color(0xFF0078D4).withOpacity(0.4) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  const Icon(
                    Icons.terminal_rounded,
                    size: 15,
                    color: Color(0xFF0078D4),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '工具调用: ${widget.tool.name}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1E293B),
                    ),
                  ),
                  const Spacer(),
                  if (widget.tool.isRunning)
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF0078D4)),
                    )
                  else
                    const Icon(Icons.check_circle_rounded, size: 14, color: Color(0xFF10B981)),
                  const SizedBox(width: 4),
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
                  const Text('输入参数:', style: TextStyle(fontSize: 10.5, color: Color(0xFF64748B), fontWeight: FontWeight.w500)),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(7),
                    margin: const EdgeInsets.only(top: 3, bottom: 6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: SelectableText(
                      widget.tool.input,
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Color(0xFF334155)),
                    ),
                  ),
                  if (widget.tool.output.isNotEmpty) ...[
                    const Text('执行输出:', style: TextStyle(fontSize: 10.5, color: Color(0xFF64748B), fontWeight: FontWeight.w500)),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(7),
                      margin: const EdgeInsets.only(top: 3),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: SelectableText(
                        widget.tool.output,
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Color(0xFF334155)),
                      ),
                    ),
                  ]
                ],
              ),
            ),
        ],
      ),
    );
  }
}
