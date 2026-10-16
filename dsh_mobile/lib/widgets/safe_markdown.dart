import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../theme/app_colors.dart';
import 'genui/genui_parse.dart';
import 'genui/genui_view.dart';

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

/// 消息正文的渲染入口：markdown + ```dsh-ui 组件。
///
/// ## 为什么这里要认识 `dsh-ui` 围栏
///
/// GenUI 的渲染器（插件 `@changfenhuang/dsh-genui`）是**浏览器侧**模块
/// （`dsh.client.platform = "web"`，入口 `window.__ModuleLoader__.load(...)`），
/// 只在 dsh web 客户端里运行。手机端拿不到它，于是围栏会走 markdown 的默认分支，
/// 把整份规格渲染成一坨裸 JSON 代码块。本 widget 是手机端自己的那一半：把围栏
/// 切出来交给 `genui_view.dart` 画成原生组件。
///
/// ## 两条路径
///
/// - **没有 dsh-ui 围栏**（绝大多数消息）：走原来的单次 `MarkdownBody`，行为与
///   改动前一致 —— 不为少数消息给所有消息加一层包装。
/// - **有围栏**：按段渲染，`Column` 里交替放 markdown 段与组件段。
///
/// 组件内部的文字不做 `selectable`（`Text.rich` 不支持）；围栏之外的正文仍按
/// 传入的 `selectable` 渲染，长按复制正文的行为不受影响。
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
  ///
  /// GenUI 组件里的链接也复用这一个回调（行内 `[文字](url)` 与 `link` 组件），
  /// 所以宿主只需要维护一条打开链接的路径。
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

    final segments = parseGenuiSegments(sanitized);
    final hasGenui = segments.any((s) => s is GenuiSpecSegment);
    if (!hasGenui) return _markdown(context, sanitized);

    final children = <Widget>[];
    for (final segment in segments) {
      switch (segment) {
        case MarkdownSegment(:final text):
          if (text.trim().isEmpty) continue;
          children.add(_markdown(context, text));
        case GenuiSpecSegment(:final spec):
          children.add(GenuiSpecView(spec: spec, onLink: _openLink));
      }
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          children[i],
        ],
      ],
    );
  }

  /// GenUI 组件内的链接 → 宿主那一个回调。
  ///
  /// `MarkdownTapLinkCallback` 要 `(text, href, title)` 三个参数，而组件只知道
  /// href；用 href 同时当文字、title 传空串 —— 宿主的实现只看 href
  /// （`chat_view._openMessageLink` 就是这么写的），所以这条适配不丢信息。
  void Function(String href)? get _openLink {
    final callback = onTapLink;
    if (callback == null) return null;
    return (href) => callback(href, href, '');
  }

  Widget _markdown(BuildContext context, String text) {
    try {
      return MarkdownBody(
        data: text,
        selectable: selectable,
        styleSheet: styleSheet,
        onTapLink: onTapLink,
      );
    } catch (e, stack) {
      debugPrint('[SafeMarkdown] Fallback to raw text due to parsing error: $e\n$stack');
      return SelectableText(
        text,
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
