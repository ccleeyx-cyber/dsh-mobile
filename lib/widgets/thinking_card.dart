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
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.isThinking;
  }

  @override
  void didUpdateWidget(covariant ThinkingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isThinking && !_expanded) {
      _expanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.content.isEmpty && !widget.isThinking) {
      return const SizedBox.shrink();
    }

    final isThinking = widget.isThinking;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: isThinking ? const Color(0xFFF0F7FF) : const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isThinking ? const Color(0xFF0078D4).withOpacity(0.3) : const Color(0xFFE5E7EB),
          width: 1.0,
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
                  Icon(
                    isThinking ? Icons.psychology_rounded : Icons.lightbulb_outline_rounded,
                    size: 16,
                    color: isThinking ? const Color(0xFF0078D4) : const Color(0xFF4B5563),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isThinking ? '深度思考中...' : '已完成思考 (${widget.content.length} 字)',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isThinking ? const Color(0xFF0078D4) : const Color(0xFF374151),
                    ),
                  ),
                  if (isThinking) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Color(0xFF0078D4),
                      ),
                    ),
                  ],
                  const Spacer(),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: const Color(0xFF9CA3AF),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                child: SelectableText(
                  widget.content.isEmpty ? '正在分析上下文并规划步骤...' : widget.content,
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: Color(0xFF374151),
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
