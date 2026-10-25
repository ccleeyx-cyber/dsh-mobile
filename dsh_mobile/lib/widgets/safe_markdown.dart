import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../theme/app_colors.dart';
import 'genui/genui_form.dart';
import 'genui/genui_parse.dart';
import 'genui/genui_view.dart';

/// 按 CommonMark 行首围栏规则切出代码段：代码段内的 `<` **不做**转义
/// （[fix 2026-10-17] 此前对全文无差别转义，交付物预览里 `if (a < b)`
/// 被污染成 `if (a &lt; b)`）；闭合判定与 parseGenuiSegments 同步修为
/// 「长度 ≥ 开启长度」（CommonMark）。
List<bool> _fenceMask(String text) {
  final lines = text.split('\n');
  final mask = List<bool>.filled(lines.length, false);
  final open = RegExp(r'^\s{0,3}(`{3,}|~{3,})');
  String? fenceChar;
  int fenceLen = 0;
  for (var i = 0; i < lines.length; i++) {
    if (fenceChar == null) {
      final m = open.firstMatch(lines[i]);
      if (m != null) {
        fenceChar = m.group(1)![0];
        fenceLen = m.group(1)!.length;
        // 开启围栏那一行本身不转义（info string 可能含 `<>`）。
        mask[i] = true;
      }
    } else {
      final close =
          RegExp('^\\s{0,3}${RegExp.escape(fenceChar)}{$fenceLen,}\\s*\$')
              .firstMatch(lines[i]);
      mask[i] = true;
      if (close != null) {
        fenceChar = null;
        fenceLen = 0;
      }
    }
  }
  // 未闭合：剩下一直到结尾都算代码段（与"自动补围栏"语义一致）。
  return mask;
}

String _sanitizeMarkdownOnce(String raw) {
  // [fix 2026-10-21] 先把换行符归一成 `\n`。
  //
  // 本文件与 `genui_parse.dart` 的所有围栏正则都只认 `\n`：闭合围栏的模式是
  // `^[ \t]{0,3}`{3,}[ \t]*$`，而 CRLF 下这一行是 "```\r" —— 末尾那个 `\r`
  // 不在 `[ \t]` 里，匹配必然失败。后果是整段围栏被当成"没有闭合"的代码块，
  // ```dsh-ui 里的 JSON 于是原样显示出来（真机现象：本该是列表，屏幕上是一坨
  // JSON）。模型输出或 Windows 侧存储都可能带上 `\r\n`，所以在入口一次抹平。
  var text = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\u0000', '');

  // 1. Auto-close dangling code fences（按行首围栏计数，不数行中的 ```）。
  {
    final lines = text.split('\n');
    var openFences = 0;
    String? fenceChar;
    int fenceLen = 0;
    final open = RegExp(r'^\s{0,3}(`{3,}|~{3,})');
    for (final line in lines) {
      if (fenceChar == null) {
        final m = open.firstMatch(line);
        if (m != null) {
          fenceChar = m.group(1)![0];
          fenceLen = m.group(1)!.length;
          openFences++;
        }
      } else {
        final close =
            RegExp('^\\s{0,3}${RegExp.escape(fenceChar)}{$fenceLen,}\\s*\$')
                .firstMatch(line);
        if (close != null) {
          openFences--;
          fenceChar = null;
          fenceLen = 0;
        }
      }
    }
    if (openFences % 2 != 0) text = '$text\n```';
  }

  // 2. Escape isolated/unmatched angle brackets —— **只对非代码段**
  //（[fix 2026-10-17] 代码块内容在 markdown 里不做实体解码，转义会把
  // `if (a < b)` 显示成 `if (a &lt; b)`）。
  final mask = _fenceMask(text);
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (mask[i]) continue;
    lines[i] = lines[i].replaceAll(RegExp(r'<(?![a-zA-Z/!])'), '&lt;');
  }
  return lines.join('\n');
}

/// 按文本 memo 的 sanitize（[fix 2026-10-25] 扩大缓存容量）。
///
/// 原来 8 条上限在长会话滚动时频繁清空。改为 128 条：按平均 2KB/消息，
/// 缓存约 256KB，对手机内存无压力，且能覆盖大部分可见 + 临近消息。
final Map<String, String> _sanitizeCache = <String, String>{};
const int _sanitizeCacheLimit = 128;

String sanitizeMarkdown(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final cached = _sanitizeCache[raw];
  if (cached != null) return cached;
  final result = _sanitizeMarkdownOnce(raw);
  if (_sanitizeCache.length >= _sanitizeCacheLimit) {
    // LRU 淘汰：删除最早的 1/4，避免每次满了都删一条导致频繁操作。
    final toRemove = (_sanitizeCacheLimit * 0.25).toInt();
    final keys = _sanitizeCache.keys.toList();
    for (var i = 0; i < toRemove && i < keys.length; i++) {
      _sanitizeCache.remove(keys[i]);
    }
  }
  _sanitizeCache[raw] = result;
  return result;
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
///
/// 交互组件的 `[genui-action]` 由 [onGenuiAction] 回传；不传时表单一律禁用，
/// 只读预览场景不会假装能提交。
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

  /// 元素级自定义渲染钩子（原样透传给 `MarkdownBody.builders`）。
  ///
  /// 目前唯一的用户是**代码块**：`pre` 需要被替换成带「全屏阅读」按钮的版本
  /// （见 `views/code_viewer_page.dart` 的 `CodeBlockOpenBuilder`）。做成可选参数
  /// 而不是写死在这层，是因为 `widgets/` 不该反过来认识 `views/` 的页面，而且
  /// 其它调用方（交付物预览、运维面板、记忆卡）不需要这个钩子 —— 默认 null
  /// 时行为与改动前**逐字一致**。
  final Map<String, MarkdownElementBuilder> builders;

  /// GenUI 交互组件的 `[genui-action]` 回传。
  ///
  /// 只有聊天页需要（把动作作为一条用户消息送回模型）；交付物预览、记忆卡
  /// 等只读场景不传，表单会保持禁用而不是假装可操作。
  final GenuiActionCallback? onGenuiAction;

  const SafeMarkdown({
    super.key,
    required this.data,
    this.styleSheet,
    this.selectable = true,
    this.fallbackTextStyle,
    this.onTapLink,
    this.builders = const <String, MarkdownElementBuilder>{},
    this.onGenuiAction,
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
          children.add(GenuiSpecView(
            spec: spec,
            onLink: _openLink,
            onGenuiAction: onGenuiAction,
          ));
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
        builders: builders,
        // [fix 2026-10-21] 单个换行按硬换行渲染，与 dsh web 一致。
        //
        // flutter_markdown 默认 `softLineBreak: false`，包内实现是
        // `text.replaceAll(RegExp(r' ?\n *'), ' ')` —— 段内每个单换行都被替换成
        // 一个空格。而模型输出的正文习惯用**单换行**分句、空行分段，于是整段文字
        // 在手机上糊成一坨（Web 端用 GFM 的 breaks 语义，会正常换行）。
        // 置 true 后单换行变成 `<br>`，与网页端视觉一致。
        softLineBreak: true,
      );
    } catch (e, stack) {
      debugPrint(
          '[SafeMarkdown] Fallback to raw text due to parsing error: $e\n$stack');
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
