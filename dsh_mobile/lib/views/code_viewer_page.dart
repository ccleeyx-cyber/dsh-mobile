/// 代码全屏阅读（Phase 5.1）。
///
/// ## 为什么需要它
///
/// 会话里的代码块被消息宽度（360dp 屏上再减去头像/竖线/气泡内边距）压到十来列就
/// 折行，读一份 60 列的实现基本靠猜。全屏页把这一层约束去掉：横向滚动不折行、
/// 行号固定、等宽字按代码的排版习惯铺开。
///
/// ## 为什么高亮走 `code_highlighter.dart` 而不是再写一套
///
/// Phase 4.2 的零依赖高亮器已经覆盖了这里的全部需求（`CodeLanguage` 按扩展名
/// 解析、`tokenize()` 出 token、颜色由调用方以 `CodePalette` 传入）。这个文件因此
/// **不含任何语言规则**，只负责三件事：从 Markdown 代码块的语言标注推出语言、
/// 把 token 拼成 `TextSpan`、以及与行号槽共用一套 strut 保证两列不错位。
///
/// ## 语言标注 → `CodeLanguage`
///
/// Markdown 里写的是 ```` ```python ```` / ```` ```sh ```` 这类**语言名**，而
/// `CodeLanguage.forFile` 认的是**扩展名**。中间必须有一层别名表：少这一层，
/// ```` ```python ```` 会静默回落成纯等宽（"没高亮"比"高亮错"安全，但这里明明
/// 认得出）。拿不到标注 / 认不出时一律回落纯等宽 —— 不猜。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

// markdown 是 flutter_markdown 的**传递依赖**，这里只为 `md.Element` 的类型签名
// 引用它。刻意不把它提升为 pubspec 的直接依赖：那会动到 pubspec.lock（多人并行
// 改造期间的高风险文件），而本文件不依赖它的任何行为，只依赖一个早已被钉住的
// 类型。等有人真的要写 markdown 扩展时，再一起提升。
// （这条 ignore 是**精确**的：只放行这一行 import，别处引用 markdown 仍然会被
//  `depend_on_referenced_packages` 拦下，所以不会把"悄悄依赖传递包"变成习惯。）
// ignore: depend_on_referenced_packages
import 'package:markdown/markdown.dart' as md;

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../widgets/code_highlighter.dart';

/// 语言名（Markdown 标注）→ 扩展名别名。
///
/// 只收"真实世界里常见、且 `CodeLanguage` 已经有规则"的那些；其余一律返回 null
/// 回落纯等宽。加一个别名之前先确认对应的 `CodeLanguage` 存在 —— 表里写着
/// `csharp` 但注册表没有它，用户得到的是"看起来支持"的假象。
const Map<String, String> _kLanguageAliases = {
  'python': 'py',
  'py3': 'py',
  'python3': 'py',
  'javascript': 'js',
  'jsx': 'js',
  'typescript': 'ts',
  'tsx': 'ts',
  'shell': 'sh',
  'bash': 'sh',
  'zsh': 'sh',
  'console': 'sh',
  'shell-session': 'sh',
  'yml': 'yaml',
  'md': 'markdown',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'text': '',
  'plaintext': '',
  'plain': '',
  'txt': '',
};

/// 把 Markdown 代码块的语言标注解析成 [CodeLanguage]；认不出返回 null。
///
/// [label] 可以是 `dart`、`python`，也可以是 flutter_markdown 透传过来的
/// `language-dart` 形式。大小写不敏感。
CodeLanguage? codeLanguageForLabel(String? label) {
  if (label == null) return null;
  var key = label.trim().toLowerCase();
  if (key.isEmpty) return null;
  if (key.startsWith('language-')) {
    key = key.substring('language-'.length);
  }
  if (key.isEmpty) return null;

  if (_kLanguageAliases.containsKey(key)) {
    final alias = _kLanguageAliases[key]!;
    // 空别名 = 明确"这是纯文本"（```text / ```console），不给高亮。
    if (alias.isEmpty) return null;
    return CodeLanguage.forFile('x.$alias');
  }
  // 标注本身就是扩展名（```dart / ```sql / ```json）时直接命中。
  return CodeLanguage.forFile('x.$key');
}

/// 全屏阅读一页代码。
///
/// 只有一个入口 [CodeViewerPage.open]：调用点有两处（消息里的代码块右上角、
/// 以后可能的产物预览），都走同一个路由构造，免得"同一种页面两种打开方式"。
class CodeViewerPage extends StatefulWidget {
  const CodeViewerPage({
    super.key,
    required this.code,
    this.languageLabel,
  });

  /// 完整代码（已去掉 Markdown 围栏末尾那一个换行）。
  final String code;

  /// Markdown 代码块上的语言标注原文（如 `python` / `language-dart`）。
  final String? languageLabel;

  /// 推入全屏阅读页。
  static Future<void> open(
    BuildContext context, {
    required String code,
    String? languageLabel,
  }) {
    return Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => CodeViewerPage(code: code, languageLabel: languageLabel),
    ));
  }

  @override
  State<CodeViewerPage> createState() => _CodeViewerPageState();
}

class _CodeViewerPageState extends State<CodeViewerPage> {
  /// 行号槽与正文**共用**的 strut。
  ///
  /// 这是"行号不错位"的唯一保证：两列都是 `Text`，行高必须先由同一套 strut 定死，
  /// 否则一列用了系统字体的默认行高、另一列用了等宽的默认行高，滚动几屏之后差半行
  /// 就变成"行号指向上一行"。`forceStrutHeight` 让空行也占同样高度。
  static const StrutStyle _codeStrut = StrutStyle(
    fontFamily: 'monospace',
    fontSize: AppText.body,
    height: 1.45,
    forceStrutHeight: true,
  );

  /// 高亮一次，之后滚动不再重算 —— `build` 会因为滚动回弹/主题变化重跑，而
  /// tokenize 是这段代码里唯一 O(n) 的活。
  late final String _code = widget.code.replaceAll(RegExp(r'\n+$'), '');

  CodeLanguage? get _language => codeLanguageForLabel(widget.languageLabel);

  /// 空白（含只有几个换行）一律按空处理：按钮禁用与"空的"说明必须同一个判定，
  /// 否则会出现"说是空的、复制按钮却能点"。
  bool get _isEmpty => widget.code.trim().isEmpty;

  @override
  Widget build(BuildContext context) {
    final language = _language;
    final tooLong = _code.length > CodeLanguage.maxHighlightLength;

    final base = TextStyle(
      // 规格写"等宽 12"。token 层没有 12 这一档，取最近的 `AppText.body`（12.5）
      // —— 不为了对一个数字凭空造一个新 token，那会让 token 表失去意义。
      fontSize: AppText.body,
      fontFamily: 'monospace',
      height: 1.45,
      color: context.c.textPrimary,
    );
    // 颜色全部来自 token 层，再作为参数交给高亮器（它刻意不认识 BuildContext）。
    final palette = CodePalette(
      plain: context.c.textPrimary,
      comment: context.c.textTertiary,
      string: context.c.terminalGreen,
      keyword: context.c.accent,
      number: context.c.orange,
      punctuation: context.c.textSecondary,
    );
    final spans =
        codeSpans(_code, language: language, palette: palette, base: base);

    return Scaffold(
      key: const ValueKey('code-viewer-page'),
      backgroundColor: context.c.background,
      appBar: AppBar(
        backgroundColor: context.c.surface,
        elevation: 0,
        titleSpacing: AppSpace.xl,
        // 标题 = 语言名。拿不到就写"代码"而不是把 ``` 或空串摆上去 —— 标题说谎
        // 比标题笼统更糟。
        title: Text(
          language?.label ??
              (widget.languageLabel != null &&
                      widget.languageLabel!.trim().isNotEmpty
                  ? widget.languageLabel!.trim()
                  : '代码'),
          style: TextStyle(
            fontSize: AppText.heading,
            fontWeight: FontWeight.w600,
            color: context.c.textPrimary,
          ),
        ),
        iconTheme: IconThemeData(color: context.c.textSecondary),
        actions: [
          IconButton(
            key: const ValueKey('code-viewer-copy'),
            tooltip: '复制全部',
            icon: Icon(Icons.copy_all_rounded, color: context.c.textSecondary),
            onPressed: _isEmpty ? null : _copyAll,
          ),
          IconButton(
            key: const ValueKey('code-viewer-share'),
            tooltip: '分享',
            icon: Icon(Icons.ios_share_rounded, color: context.c.textSecondary),
            onPressed: _isEmpty ? null : _share,
          ),
          const SizedBox(width: AppSpace.s),
        ],
      ),
      body: _isEmpty
          ? Center(
              child: Text(
                '这个代码块是空的',
                style: TextStyle(
                  fontSize: AppText.body,
                  color: context.c.textTertiary,
                ),
              ),
            )
          : SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (tooLong)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpace.xl, AppSpace.m, AppSpace.xl, 0),
                      child: Text(
                        '内容过长（${_code.length} 字符），已关闭语法高亮',
                        key: const ValueKey('code-viewer-too-long'),
                        style: TextStyle(
                          fontSize: AppText.caption,
                          color: context.c.warning,
                        ),
                      ),
                    ),
                  Expanded(
                    // 纵向滚动包住整行（行号 + 正文）：行号必须跟着代码一起上下滚，
                    // 否则滚两屏之后左边那列数字就完全对不上了。
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.xl, vertical: AppSpace.l),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 行号槽**不**参与横向滚动：横向滚动的是代码，行号必须固定。
                          _lineNumberGutter(context),
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SelectableText.rich(
                                TextSpan(children: spans, style: base),
                                style: base,
                                strutStyle: _codeStrut,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// 行号槽。
  ///
  /// 用**一个** `Text` 把 `1\n2\n3…` 拼起来，而不是 `Column` 里 N 个 Text：
  /// 行高由同一套 strut 决定，两列天然对齐；几千行也只多出一个段落对象。
  /// 与 `deliverable_preview_sheet.dart` 的预览行号同一套做法（同一个界面语言）。
  Widget _lineNumberGutter(BuildContext context) {
    final lines = '\n'.allMatches(_code).length + 1;
    final numbers = List<String>.generate(lines, (i) => '${i + 1}').join('\n');
    return Padding(
      padding: const EdgeInsets.only(right: AppSpace.l),
      child: Text(
        numbers,
        key: const ValueKey('code-viewer-gutter'),
        textAlign: TextAlign.right,
        strutStyle: _codeStrut,
        style: TextStyle(
          fontSize: AppText.body,
          fontFamily: 'monospace',
          height: 1.45,
          color: context.c.textTertiary,
        ),
      ),
    );
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _code));
    _toast('已复制全部代码');
  }

  /// 分享。
  ///
  /// ## 为什么它落地成"复制成 Markdown 代码块"
  ///
  /// 本工程的 Android 侧只有分享**接收**通道（`dsh_mobile/share` 的
  /// `consumePending`，见 `MainActivity.kt`），从来没有分享**出口**；`share_plus`
  /// 也不在 pubspec 里，而任务明确不许为此新增依赖。三条路里：
  ///
  /// * 加依赖 → 违反约束，且会把 Flutter 3.24.5 + `speech_to_text 6.6.2` 那个版本
  ///   钉一起动（见 pubspec 里的说明）；
  /// * 走 `FileOpener.openBytes` → 那是 **ACTION_VIEW**（"用其它应用打开"），
  ///   不是分享，语义是说谎；
  /// * **复制成 ```` ```lang … ``` ```` 围栏** → 粘到聊天/文档里就是一份带语言标注
  ///   的代码，是这条动线 90% 的真实去向。
  ///
  /// 所以选第三条，并在提示里**说清它做了什么** —— 按钮叫"分享"却悄悄只做了复制，
  /// 用户下次就不会再信这个按钮。
  Future<void> _share() async {
    final label = widget.languageLabel?.trim() ?? '';
    final fence = '```$label\n$_code\n```';
    await Clipboard.setData(ClipboardData(text: fence));
    _toast('已复制为 Markdown 代码块（本版本无系统分享出口）');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(milliseconds: 1800),
      behavior: SnackBarBehavior.floating,
    ));
  }
}

/// Markdown 代码块（`pre`）的渲染钩子：把代码块画出来，并在右上角放一个
/// 「全屏阅读」按钮。
///
/// ## 为什么必须连代码块一起画
///
/// `flutter_markdown` 对 `pre` 的块级 builder 是**替换**语义（
/// `builders[tag]?.visitElementAfterWithContext(...) ?? defaultChild()`），而且一旦
/// 注册了 builder，代码正文那一段 `visitText` 也会先问 builder 要（默认返回 null，
/// 于是不产出默认的 `SelectableText`）。所以"只加一个按钮"是做不到的 —— 本 builder
/// 必须自己把代码画出来，否则代码块会变成空白。
///
/// 复刻的正是默认路径的三件事，一样不少：
/// 1. 横向 `SingleChildScrollView`（长行不折行，这是代码块的默认行为）；
/// 2. `SelectableText.rich`（**长按选词必须保留** —— 见 `chat_view` 里 Phase 4.7
///    那段手势取舍说明）；
/// 3. 外层底色/描边由库里的 `pre` 分支继续包（`codeblockDecoration`），这里不重复画。
class CodeBlockOpenBuilder extends MarkdownElementBuilder {
  CodeBlockOpenBuilder({
    required this.codeStyle,
    required this.padding,
  });

  /// 代码正文样式（由调用方的 `MarkdownStyleSheet.code` 传入，深浅主题各自成立）。
  final TextStyle codeStyle;

  /// 代码块内边距（用调用方的间距 token 构造，不在这里硬编码数字）。
  final EdgeInsets padding;

  /// 代码正文的内联节点：返回一个**零尺寸占位**，而不是 null。
  ///
  /// ⚠️ 这是这个 builder 唯一"反直觉但必须"的一处。`flutter_markdown` 的
  /// `_addAnonymousBlockIfNeeded` 只在**内联子节点非空**时才执行 `_inlines.clear()`，
  /// 而 `build()` 结尾有一条 `assert(_inlines.isEmpty)`。如果这里返回 null（"我不
  /// 需要内联 widget"），那一段代码的内联栈就永远收不干 —— 调试模式下直接抛
  /// `Failed assertion: '_inlines.isEmpty'`，整条消息渲染失败。
  ///
  /// 占位符本身不会被看见：真正画代码的是 [visitElementAfterWithContext] 返回的
  /// 组件，它会把这一层默认内容整体替换掉（`builders[tag]?… ?? defaultChild()`）。
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) =>
      const SizedBox.shrink();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final raw = element.textContent;
    if (raw.trim().isEmpty) return null; // 空围栏：保持"什么都没有"，别画一个空按钮
    final code = raw.replaceAll(RegExp(r'\n$'), '');
    final label = _languageLabelOf(element);

    return Stack(
      children: [
        Padding(
          // [fix 2026-10-17] 右侧给"全屏阅读"按钮留出 30dp：按钮是盖在代码块上的
          // 浮层，不留位的话代码第一行会被它压住（真机截图里 `--no-fatal-inf…`
          // 正好被那枚 ↗ 盖掉）。这里让**视口**提前收窄，而不是给内容加 padding
          // —— 内容仍然可以横向滚到按钮下面，但默认位置不会重叠。
          padding: EdgeInsets.only(
            left: padding.left,
            top: padding.top,
            bottom: padding.bottom,
            right: padding.right + 30,
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText.rich(
              TextSpan(text: code, style: codeStyle),
              style: codeStyle,
            ),
          ),
        ),
        Positioned(
          top: AppSpace.s,
          right: AppSpace.s,
          child: _CodeBlockOpenButton(
            label: label,
            onTap: () => CodeViewerPage.open(
              context,
              code: code,
              languageLabel: label,
            ),
          ),
        ),
      ],
    );
  }

  /// 语言标注藏在 `<pre><code class="language-dart">` 的 class 上，不在 `pre` 上。
  String? _languageLabelOf(md.Element pre) {
    for (final child in pre.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'code') {
        final cls = child.attributes['class'];
        if (cls != null && cls.trim().isNotEmpty) return cls;
      }
    }
    // 没有 class 的围栏（```）+ 没有标注：交给调用方回落纯等宽。
    return null;
  }
}

/// 代码块右上角那枚按钮。
///
/// 刻意做成 24dp 的小方块而不是 `IconButton`：`IconButton` 的最小点击区是 48dp，
/// 压在代码块上会盖住整整一行的右侧。这里靠 `InkResponse` 的 `radius` 保证
/// 命中判定仍然宽裕，同时视觉上只占一小块。
class _CodeBlockOpenButton extends StatelessWidget {
  const _CodeBlockOpenButton({required this.onTap, this.label});

  final VoidCallback onTap;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label == null ? '全屏阅读这段代码' : '全屏阅读这段 $label 代码',
      child: Material(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          key: const ValueKey('code-block-open'),
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(AppSpace.s),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: context.c.border),
            ),
            child: Icon(
              Icons.open_in_full_rounded,
              size: 13,
              color: context.c.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
