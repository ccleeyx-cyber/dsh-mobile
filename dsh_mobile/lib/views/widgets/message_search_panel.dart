import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'message_search.dart';
import '../../theme/app_colors.dart';

/// The in-session search bar and result list (v1.4.2 会话内查找).
///
/// Two rules the tests hold this to:
///
/// * **Result count means rendered rows.** `Text('N 条结果')` is only truthful if
///   the list actually has N rows. The collapsed count is computed from the
///   hits and the row builder is driven by the same list, so they cannot drift.
/// * **Empty state distinguishes "no hits" from "not searched yet".** Showing
///   "没有找到" for an empty query is a small lie that reads as a broken feature.
class MessageSearchPanel extends StatefulWidget {
  final String query;

  /// Null until the user types something. An empty (non-null) string means
  /// "searched, found nothing".
  final List<({SearchHit first, int count})> results;
  final int totalHits;

  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClose;
  final void Function(SearchHit hit) onJumpTo;

  const MessageSearchPanel({
    super.key,
    required this.query,
    required this.results,
    required this.totalHits,
    required this.onQueryChanged,
    required this.onClose,
    required this.onJumpTo,
  });

  @override
  State<MessageSearchPanel> createState() => _MessageSearchPanelState();
}

class _MessageSearchPanelState extends State<MessageSearchPanel> {
  late final TextEditingController _controller = TextEditingController(text: '');
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Open with the keyboard up: the whole point is to type immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasQuery = widget.query.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: context.c.surface,
        border: Border(bottom: BorderSide(color: context.c.border)),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.search_rounded, size: 18, color: context.c.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      style: const TextStyle(fontSize: 13.5),
                      textInputAction: TextInputAction.search,
                      onChanged: widget.onQueryChanged,
                      decoration: InputDecoration(
                        hintText: '在当前会话中查找…',
                        hintStyle: TextStyle(fontSize: 13, color: context.c.textTertiary),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: widget.onClose,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.close_rounded, size: 18, color: context.c.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            if (hasQuery) _buildResults(),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (widget.results.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
        child: Text(
          '当前会话里没有包含「${widget.query}」的内容',
          style: TextStyle(fontSize: 11.5, color: context.c.textTertiary),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.c.surfaceMuted)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 7, 16, 5),
            child: Text(
              // One number, and it is the number of rows below.
              '${widget.results.length} 条结果'
              '${widget.totalHits > widget.results.length ? '（${widget.totalHits} 处匹配）' : ''}',
              style: TextStyle(fontSize: 11, color: context.c.textTertiary),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 230),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: widget.results.length,
              itemBuilder: (context, index) {
                final r = widget.results[index];
                return _ResultRow(
                  hit: r.first,
                  count: r.count,
                  query: widget.query,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    widget.onJumpTo(r.first);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  final SearchHit hit;
  final int count;
  final String query;
  final VoidCallback onTap;

  const _ResultRow({required this.hit, required this.count, required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: context.c.surfaceMuted,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    MessageSearch.fieldLabel(hit.field),
                    style: TextStyle(fontSize: 9.5, color: context.c.textSecondary),
                  ),
                ),
                const SizedBox(width: 6),
                if (count > 1)
                  Text(
                    '$count 处',
                    style: TextStyle(fontSize: 10, color: context.c.textTertiary),
                  ),
                const Spacer(),
                if (hit.timestamp != null)
                  Text(
                    _fmt(hit.timestamp!),
                    style: TextStyle(fontSize: 10, color: context.c.textTertiary),
                  ),
              ],
            ),
            const SizedBox(height: 3),
            _Highlighted(
              text: hit.context(),
              query: query,
              style: TextStyle(fontSize: 12, color: context.c.textPrimary, height: 1.4),
              highlightStyle: TextStyle(
                fontSize: 12,
                color: context.c.warning,
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}';
  }
}

/// Renders [text] with every case-insensitive occurrence of [query] emphasised.
///
/// Written as a plain split/round-trip rather than a regex so a query
/// containing regex metacharacters (`.`, `*`, `$`) cannot throw or mis-match —
/// users type those characters into search boxes constantly.
class _Highlighted extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle style;
  final TextStyle highlightStyle;

  const _Highlighted({
    required this.text,
    required this.query,
    required this.style,
    required this.highlightStyle,
  });

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) return Text(text, style: style, maxLines: 2, overflow: TextOverflow.ellipsis);

    final spans = <TextSpan>[];
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    var from = 0;
    while (true) {
      final at = lowerText.indexOf(lowerQuery, from);
      if (at < 0) break;
      if (at > from) spans.add(TextSpan(text: text.substring(from, at)));
      spans.add(TextSpan(text: text.substring(at, at + lowerQuery.length), style: highlightStyle));
      from = at + lowerQuery.length;
    }
    if (from < text.length) spans.add(TextSpan(text: text.substring(from)));
    if (spans.isEmpty) return Text(text, style: style);

    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}