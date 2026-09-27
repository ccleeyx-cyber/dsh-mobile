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
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFBFDBFE),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.terminal,
                    size: 16,
                    color: Colors.blue[600],
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '执行工具: ${widget.tool.name}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.blue[200] : Colors.blue[900],
                    ),
                  ),
                  const Spacer(),
                  if (widget.tool.isRunning)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    const Icon(Icons.check_circle, size: 14, color: Colors.green),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 16,
                    color: Colors.grey,
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
                  Text('输入参数:', style: TextStyle(fontSize: 10, color: Colors.grey[600])),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(6),
                    margin: const EdgeInsets.only(top: 2, bottom: 4),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.black45 : Colors.white,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: SelectableText(
                      widget.tool.input,
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                  if (widget.tool.output.isNotEmpty) ...[
                    Text('执行输出:', style: TextStyle(fontSize: 10, color: Colors.grey[600])),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(6),
                      margin: const EdgeInsets.only(top: 2),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.black45 : Colors.white,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: SelectableText(
                        widget.tool.output,
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
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
