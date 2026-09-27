import 'package:flutter/material.dart';

class ThinkingCard extends StatefulWidget {
  final String content;
  final bool isThinking;

  const ThinkingCard({
    super.key,
    required this.content,
    this.isThinking = false,
  });

  @override
  State<ThinkingCard> createState() => _ThinkingCardState();
}

class _ThinkingCardState extends State<ThinkingCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.content.isEmpty && !widget.isThinking) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[900] : const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? Colors.grey[800]! : const Color(0xFFE5E7EB),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    widget.isThinking ? Icons.psychology : Icons.lightbulb_outline,
                    size: 18,
                    color: widget.isThinking ? Colors.orange : Colors.grey[600],
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.isThinking ? '深度思考中...' : '已完成思考',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.grey[300] : Colors.grey[700],
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 18,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: SelectableText(
                widget.content.isEmpty ? '等待思考内容...' : widget.content,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: isDark ? Colors.grey[400] : Colors.grey[700],
                  fontFamily: 'monospace',
                ),
              ),
            ),
        ],
      ),
    );
  }
}
