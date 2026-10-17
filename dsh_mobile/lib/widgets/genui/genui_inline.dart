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
class GenuiInlineText extends StatefulWidget {
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
  State<GenuiInlineText> createState() => _GenuiInlineTextState();
}

class _GenuiInlineTextState extends State<GenuiInlineText> {
  List<InlineSpan>? _parsed;

  @override
  void didUpdateWidget(covariant GenuiInlineText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text ||
        old.onLink != widget.onLink ||
        old.style != widget.style ||
        old.codeBackground != widget.codeBackground ||
        old.highlightBackground != widget.highlightBackground ||
        old.linkColor != widget.linkColor) {
      _disposeParsed();
      _parsed = null;
    }
  }

  void _disposeParsed() {
    final p = _parsed;
    if (p != null) disposeSpanRecognizers(p);
    _parsed = null;
  }

  @override
  void dispose() {
    _disposeParsed();
    super.dispose();
  }

  List<InlineSpan> _buildSpans() {
    final cached = _parsed;
    if (cached != null) return cached;
    final spans = parseGenuiInline(
      widget.text,
      base: widget.style ?? const TextStyle(fontSize: 13, height: 1.45),
      onLink: widget.onLink,
      codeBackground: widget.codeBackground,
      highlightBackground: widget.highlightBackground,
      linkColor: widget.linkColor,
    );
    _parsed = spans;
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(children: _buildSpans()),
      maxLines: widget.maxLines,
      overflow:
          widget.maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
    );
  }
}

/// 纯函数版本：给定基样式，产出行内 span 列表。抽出来是为了能单测。
///
/// ⚠️ [fix 2026-10-17] 返回的 span 里可能带着 [TapGestureRecognizer]（链接），
/// recognizer 由**本函数**创建、随 span 交给 `Text.rich`。调用方必须持有结果
/// 并在丢弃时对每个 span 调 `disposeSpanRecognizers`（见下）—— StatelessWidget
/// 每帧 build 都 new 一批 recognizer 而从不释放，是持续泄漏（手势竞技场注册）。
/// 组件侧已改为 StatefulWidget 持有 + dispose。
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

/// 递归释放 span 树里由 [parseGenuiInline] 创建的 recognizer。
///
/// 只对 `TapGestureRecognizer` 负责：其余 span 是纯文本/纯样式，没有需要
/// 释放的资源。
void disposeSpanRecognizers(List<InlineSpan> spans) {
  for (final span in spans) {
    if (span is TextSpan) {
      final recognizer = span.recognizer;
      if (recognizer is TapGestureRecognizer) recognizer.dispose();
      final children = span.children;
      if (children != null) disposeSpanRecognizers(children);
    }
  }
}

/// 只有 http(s) 与 mailto 可点 —— 与规范的 link 组件同一口径。
bool _isLinkable(String href) {
  final s = href.toLowerCase();
  return s.startsWith('http://') || s.startsWith('https://') || s.startsWith('mailto:');
}
