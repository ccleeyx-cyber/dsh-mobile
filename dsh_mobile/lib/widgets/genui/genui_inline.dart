import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// GenUI 文字字段里的行内富文本 → TextSpan。
///
/// 规范里文字类字段（`text.content`、list 项、table 单元格、keyvalue 值、
/// callout 正文）支持四种行内标记，且**不嵌套、不解析 HTML**：
///
/// | 写法 | 渲染 |
/// |---|---|
/// | `` `code` `` | 行内代码胶囊 |
/// | `**加粗**` | 强调 |
/// | `==高亮==` | 极淡底色 |
/// | `[文字](https://…)` | 行内链接（http/https/mailto） |
///
/// 标记没闭合时原样显示 —— 与 Web 端一致：宁可让用户看到 `**`，也不要吞掉内容。
class GenuiInlineText extends StatelessWidget {
  const GenuiInlineText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.onLink,
    this.codeBackground,
    this.highlightBackground,
    this.linkColor,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;

  /// 链接点击。null 时链接按普通文字渲染（不假装可点）。
  final void Function(String href)? onLink;

  /// 行内元素的配色。默认值偏中性，调用方通常传宿主主题的 token。
  final Color? codeBackground;
  final Color? highlightBackground;
  final Color? linkColor;

  @override
  Widget build(BuildContext context) {
    final base = style ?? const TextStyle(fontSize: 13, height: 1.45);
    return Text.rich(
      TextSpan(
        children: parseGenuiInline(
          text,
          base: base,
          onLink: onLink,
          codeBackground: codeBackground,
          highlightBackground: highlightBackground,
          linkColor: linkColor,
        ),
      ),
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
    );
  }
}

/// 纯函数版本：给定基样式，产出行内 span 列表。抽出来是为了能单测。
List<InlineSpan> parseGenuiInline(
  String text, {
  required TextStyle base,
  void Function(String href)? onLink,
  Color? codeBackground,
  Color? highlightBackground,
  Color? linkColor,
}) {
  if (text.isEmpty) return const [];
  final spans = <InlineSpan>[];
  final buffer = StringBuffer();

  void flush() {
    if (buffer.isEmpty) return;
    spans.add(TextSpan(text: buffer.toString(), style: base));
    buffer.clear();
  }

  var i = 0;
  while (i < text.length) {
    // 1. 行内代码
    if (text[i] == '`') {
      final end = text.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        spans.add(TextSpan(
          text: text.substring(i + 1, end),
          style: base.copyWith(
            fontFamily: 'monospace',
            backgroundColor: codeBackground ?? const Color(0x14000000),
          ),
        ));
        i = end + 1;
        continue;
      }
    }
    // 2. 加粗
    if (text.startsWith('**', i)) {
      final end = text.indexOf('**', i + 2);
      if (end > i + 2) {
        flush();
        spans.add(TextSpan(
          text: text.substring(i + 2, end),
          style: base.copyWith(fontWeight: FontWeight.w700),
        ));
        i = end + 2;
        continue;
      }
    }
    // 3. 高亮
    if (text.startsWith('==', i)) {
      final end = text.indexOf('==', i + 2);
      if (end > i + 2) {
        flush();
        spans.add(TextSpan(
          text: text.substring(i + 2, end),
          style: base.copyWith(backgroundColor: highlightBackground ?? const Color(0x33FFD166)),
        ));
        i = end + 2;
        continue;
      }
    }
    // 4. 链接 [文字](url)
    if (text[i] == '[') {
      final close = text.indexOf(']', i + 1);
      if (close > i + 1 && close + 1 < text.length && text[close + 1] == '(') {
        final paren = text.indexOf(')', close + 2);
        if (paren > close + 2) {
          final label = text.substring(i + 1, close);
          final href = text.substring(close + 2, paren);
          flush();
          final linkStyle = base.copyWith(
            color: linkColor ?? base.color,
            decoration: TextDecoration.underline,
            decorationColor: linkColor ?? base.color,
          );
          final callback = onLink;
          final tappable = callback != null && _isLinkable(href);
          spans.add(TextSpan(
            text: label,
            style: linkStyle,
            recognizer: tappable ? (TapGestureRecognizer()..onTap = () => callback(href)) : null,
          ));
          i = paren + 1;
          continue;
        }
      }
    }
    buffer.write(text[i]);
    i++;
  }
  flush();
  return spans;
}

/// 只有 http(s) 与 mailto 可点 —— 与规范的 link 组件同一口径。
bool _isLinkable(String href) {
  final s = href.toLowerCase();
  return s.startsWith('http://') || s.startsWith('https://') || s.startsWith('mailto:');
}
