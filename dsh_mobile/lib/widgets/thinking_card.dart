import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _expanded = widget.isThinking;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ThinkingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Auto-expand only when transitioning into thinking state from non-thinking
    // state. Within a single thinking phase `isThinking` stays true, so this
    // does not fire again and a user's manual collapse is preserved for the
    // rest of the stream — which is exactly what the old `_userCollapsed` flag
    // was meant to express. That flag was written in four places and read in
    // none, so it has been removed instead of being left as dead state.
    if (!oldWidget.isThinking && widget.isThinking) {
      _expanded = true;
    }

    // Auto-scroll inside thinking box when new chunks arrive, if user is already near bottom
    if (widget.isThinking && _expanded && oldWidget.content != widget.content) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          final pos = _scrollController.position;
          if (pos.maxScrollExtent - pos.pixels < 50) {
            _scrollController.animateTo(
              pos.maxScrollExtent,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
            );
          }
        }
      });
    }
  }

  void _toggleExpanded() {
    HapticFeedback.selectionClick();
    setState(() {
      _expanded = !_expanded;
    });
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
            onTap: _toggleExpanded,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8.5),
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
                    size: 18,
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
                constraints: const BoxConstraints(maxHeight: 280),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Flexible(
                      child: Scrollbar(
                        controller: _scrollController,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: _scrollController,
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
                    ),
                    if (widget.content.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          InkWell(
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: widget.content));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已复制思考过程'),
                                  duration: Duration(seconds: 1),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Icon(Icons.copy_rounded, size: 12, color: Color(0xFF6B7280)),
                                  SizedBox(width: 4),
                                  Text('复制', style: TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () {
                              HapticFeedback.selectionClick();
                              setState(() {
                                _expanded = false;
                              });
                            },
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Icon(Icons.keyboard_arrow_up_rounded, size: 13, color: Color(0xFF6B7280)),
                                  SizedBox(width: 2),
                                  Text('收起', style: TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

