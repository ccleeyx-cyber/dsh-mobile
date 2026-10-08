import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

String sanitizeMarkdown(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  var text = raw.replaceAll('\u0000', '');

  // 1. Auto-close dangling code fences (odd count of ```)
  final fenceMatches = RegExp(r'```').allMatches(text);
  if (fenceMatches.length % 2 != 0) {
    text = '$text\n```';
  }

  // 2. Escape isolated/unmatched angle brackets that would crash XML/HTML tokenizers
  // Replaces '<' not followed by a letter, '/', or '!' with '&lt;'
  text = text.replaceAll(RegExp(r'<(?![a-zA-Z/!])'), '&lt;');

  return text;
}

class SafeMarkdown extends StatelessWidget {
  final String data;
  final MarkdownStyleSheet? styleSheet;
  final bool selectable;
  final TextStyle? fallbackTextStyle;

  const SafeMarkdown({
    super.key,
    required this.data,
    this.styleSheet,
    this.selectable = true,
    this.fallbackTextStyle,
  });

  @override
  Widget build(BuildContext context) {
    final sanitized = sanitizeMarkdown(data);
    if (sanitized.isEmpty) return const SizedBox.shrink();

    try {
      return MarkdownBody(
        data: sanitized,
        selectable: selectable,
        styleSheet: styleSheet,
      );
    } catch (e, stack) {
      debugPrint('[SafeMarkdown] Fallback to raw text due to parsing error: $e\n$stack');
      return SelectableText(
        data,
        style: fallbackTextStyle ??
            const TextStyle(
              fontSize: 14,
              color: Color(0xFF1F2937),
              height: 1.45,
            ),
      );
    }
  }
}
