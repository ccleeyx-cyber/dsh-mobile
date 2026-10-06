import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

class _ContextMeta {
  final String title;
  final String tag;
  final IconData icon;
  final Color themeColor;

  const _ContextMeta({
    required this.title,
    required this.tag,
    required this.icon,
    required this.themeColor,
  });
}

class MemoryCard extends StatefulWidget {
  final String content;

  const MemoryCard({
    super.key,
    required this.content,
  });

  @override
  State<MemoryCard> createState() => _MemoryCardState();
}

typedef CollapsibleContextCard = MemoryCard;

class _MemoryCardState extends State<MemoryCard> {
  bool _expanded = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  _ContextMeta _extractMeta(String text) {
    final fileMatch = RegExp(r'Instructions from:\s*([^\r\n]+)').firstMatch(text) ??
        RegExp(r'<runtime-memory-file\s+name=["\x27]([^"\x27]+)["\x27]').firstMatch(text) ??
        RegExp(r'Contents of\s+([^\r\n(]+)').firstMatch(text);

    if (fileMatch != null) {
      final fname = fileMatch.group(1)?.trim() ?? '';
      final isUserMd = fname.toUpperCase().contains('USER.MD');
      return _ContextMeta(
        title: isUserMd ? '用户画像记忆 ($fname)' : '工作区文档: $fname',
        tag: fname,
        icon: isUserMd ? Icons.badge_outlined : Icons.description_outlined,
        themeColor: isUserMd ? const Color(0xFFA78BFA) : const Color(0xFF38BDF8),
      );
    }

    if (text.contains('<available_skills>') || text.contains('A skill is a reusable set')) {
      return const _ContextMeta(
        title: '可用技能列表 (Available Skills)',
        tag: 'Skills',
        icon: Icons.bolt_rounded,
        themeColor: Color(0xFFFBBF24),
      );
    }

    if (text.startsWith('Current runtime context.') || text.contains('DSH file policy:')) {
      return const _ContextMeta(
        title: '运行时环境与权限上下文',
        tag: 'Runtime',
        icon: Icons.tune_rounded,
        themeColor: Color(0xFF34D399),
      );
    }

    if (text.startsWith('MNEMON RUNTIME MEMORY SNAPSHOT') || text.startsWith('[MNEMON]')) {
      return const _ContextMeta(
        title: '长期记忆快照 (Mnemon)',
        tag: 'Mnemon',
        icon: Icons.psychology_outlined,
        themeColor: Color(0xFF60A5FA),
      );
    }

    if (text.contains('<system-reminder>')) {
      return const _ContextMeta(
        title: '系统上下文提醒 (System Reminder)',
        tag: 'Reminder',
        icon: Icons.info_outline_rounded,
        themeColor: Color(0xFFA78BFA),
      );
    }

    return const _ContextMeta(
      title: '携带上下文与参考信息',
      tag: 'Context',
      icon: Icons.layers_outlined,
      themeColor: Color(0xFF94A3B8),
    );
  }

  String _formatSize(int length) {
    if (length >= 1000) {
      return '${(length / 1000).toStringAsFixed(1)}k 字符';
    }
    return '$length 字符';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.content.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final meta = _extractMeta(widget.content);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: meta.themeColor.withOpacity(0.35),
          width: 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _expanded = !_expanded);
            },
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    meta.icon,
                    size: 15,
                    color: meta.themeColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${meta.title} · 点击${_expanded ? "折叠" : "展开"} (${_formatSize(widget.content.length)})',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF334155),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: meta.themeColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      meta.tag,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: meta.themeColor,
                      ),
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
            Container(
              constraints: const BoxConstraints(maxHeight: 320),
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        child: MarkdownBody(
                          data: widget.content,
                          selectable: true,
                          styleSheet: MarkdownStyleSheet(
                            p: const TextStyle(fontSize: 12.5, color: Color(0xFF334155), height: 1.45),
                            code: const TextStyle(
                              color: Color(0xFF0369A1),
                              backgroundColor: Color(0xFFF1F5F9),
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                            ),
                            codeblockDecoration: BoxDecoration(
                              color: const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: const Color(0xFFE2E8F0)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _expanded = false);
                    },
                    borderRadius: BorderRadius.circular(6),

                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.keyboard_arrow_up_rounded, size: 15, color: meta.themeColor),
                          const SizedBox(width: 4),
                          Text(
                            '收起上下文',
                            style: TextStyle(
                              fontSize: 11,
                              color: meta.themeColor,
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
