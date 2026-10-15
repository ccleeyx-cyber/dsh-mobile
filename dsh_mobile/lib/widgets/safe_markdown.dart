import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../theme/app_colors.dart';

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

  /// 链接点击。
  ///
  /// 必须显式传：`flutter_markdown` 在 `onTapLink == null` 时**整段跳过**点击处理
  /// （见包内 `widget.dart`: `if (widget.onTapLink != null)`），它不会自己退回到
  /// `url_launcher`。也就是说"不传"的后果不是默认行为，而是正文里所有链接都点不动。
  final MarkdownTapLinkCallback? onTapLink;

  const SafeMarkdown({
    super.key,
    required this.data,
    this.styleSheet,
    this.selectable = true,
    this.fallbackTextStyle,
    this.onTapLink,
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
        onTapLink: onTapLink,
      );
    } catch (e, stack) {
      debugPrint('[SafeMarkdown] Fallback to raw text due to parsing error: $e\n$stack');
      return SelectableText(
        data,
        style: fallbackTextStyle ??
            TextStyle(
              fontSize: 14,
              color: context.c.textPrimary,
              height: 1.45,
            ),
      );
    }
  }
}
