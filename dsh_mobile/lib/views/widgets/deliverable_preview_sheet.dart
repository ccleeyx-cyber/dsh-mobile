import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/bridge_extras.dart';
import '../../models/task_center.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/code_highlighter.dart';
import '../../widgets/safe_markdown.dart';
import 'turn_output_card.dart';

/// 就地预览一个交付物 —— **全 App 唯一的预览入口**。
///
/// 抽成函数而不是让每个调用方自己写一遍 `showModalBottomSheet`：预览有三个入口
/// （消息流「本轮产出」卡片、消息正文里的产物链接、信息面板的交付物清单），三处
/// 各写一份的结果就是"同一个文件在三处行为不一样"，那正是这次改动要消灭的东西。
/// 三个入口共用这唯一的实现，差异只剩"谁传的 loader"。
///
/// [loader] 必须用 **REST 清单里的绝对路径**：`/api/mobile/deliverables/text` 的
/// 成员判定是 `path.resolve(requested)` 与已声明路径的精确比对，相对路径会被解析
/// 到网关进程自己的工作目录因而必然判 403。
Future<void> showDeliverablePreview(
  BuildContext context, {
  required DeliverableItem item,
  required Future<TextFileContent> Function() loader,
  VoidCallback? onDownload,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.c.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => DeliverablePreviewSheet(item: item, loader: loader, onDownload: onDownload),
  );
}

/// 交付物文本预览（P0-4）：不下载、不拉起外部应用，直接在这里看内容。
///
/// 为什么值得单独做一个弹层：绝大多数交付物（.md / .txt / .csv / 源码）用户想
/// 做的第一件事是**看一眼**，而"下载 + 切到别的应用 + 再切回来"对看一眼来说
/// 成本高得离谱。下载这条路仍然保留（长按列表行、产出卡片长按，或本弹层底部的
/// 按钮），因为它是二进制文件和"要拿去用"时的唯一出口。
///
/// 三种结局分开渲染，绝不混：读失败（原因 + 重试）、二进制（说明 + 下载出口，
/// **不渲染字节**）、文本（Markdown 或源码/等宽纯文本 + 截断横幅）。
///
/// 文本这一档又分两支（Phase 4.2）：
/// * 已知扩展名（dart/py/js/ts/json/yaml/sh/sql/java/kotlin，以及 md 的源码视图）
///   → 零依赖正则高亮 + 行号槽 + 横向滚动；
/// * 未知扩展名 → 纯等宽渲染（**只是换了承载的 widget**，颜色/字号与原实现一致），
///   行号仍可用。不猜语言：给 csv 上色会让数字列与文本列难以分辨。
class DeliverablePreviewSheet extends StatefulWidget {
  const DeliverablePreviewSheet({
    super.key,
    required this.item,
    required this.loader,
    this.onDownload,
  });

  final DeliverableItem item;

  /// 取内容的那次请求（调用方包好的 `dsh.fetchDeliverableText(path)`）。
  final Future<TextFileContent> Function() loader;

  /// 下载 / 用其它应用打开。二进制文件预览不了时它是唯一的出口。
  final VoidCallback? onDownload;

  @override
  State<DeliverablePreviewSheet> createState() => _DeliverablePreviewSheetState();
}

class _DeliverablePreviewSheetState extends State<DeliverablePreviewSheet> {
  /// 初值即"加载中"，所以 initState 里不需要先 setState 一次。
  bool _loading = true;
  TextFileContent? _result;

  /// 网络层抛出来的异常（与网关的 `ok:false` 分开存，但渲染在同一个出口）。
  String _error = '';

  /// 行号默认**开**：预览一份源码时，"第几行"是最常被引用的坐标（报错和 review
  /// 都按行说话）。关掉它就回到"普通阅读"模式：软换行、无槽位。
  bool _showLineNumbers = true;

  /// Markdown 默认走渲染视图（排版本身就是信息）；这个开关给"我要看原始 md"留出口。
  bool _markdownSource = false;

  /// 行号槽与正文必须共用同一套行盒，否则两列会随行高逐渐错开。
  ///
  /// `forceStrutHeight` 把每行高度钉死成 fontMetrics 算出来的那个值：行号里只有
  /// 数字、正文里可能混着中文回退字体，不钉死的行高会一行一行漂。
  static const StrutStyle _codeStrut = StrutStyle(
    fontFamily: 'monospace',
    fontSize: AppText.subhead,
    height: 1.45,
    forceStrutHeight: true,
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.loader();
      if (!mounted) return;
      setState(() {
        _result = r;
        _error = '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _retry() {
    setState(() {
      _loading = true;
      _result = null;
      _error = '';
    });
    _load();
  }

  /// 复制**全文**（不是屏幕上那份可能被截断的预览）：用户按"复制"是想拿走内容，
  /// 拿到的是"我以为复制的其实是半截"最糟。
  Future<void> _copy() async {
    final text = _result?.content ?? '';
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('内容已复制'),
      duration: Duration(milliseconds: 900),
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// 字节数：与信息面板别处的口径一致（B / KB / MB）。
  static String _bytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final maxHeight = MediaQuery.of(context).size.height * 0.8;
    // 有内容可复制 / 可下载时才画底部动作条：读失败时只有"重试"是有意义的动作。
    final hasText = result != null && result.ok && !result.binary;
    final isMarkdown = result != null && result.ok && !result.binary && result.isMarkdown;
    // 渲染视图下"行号"没有意义 —— 那就不画这个开关（不给点了没反应的按钮）。
    final showLineNumberToggle = hasText && !(isMarkdown && !_markdownSource);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 4, 8),
              child: Row(
                children: [
                  Icon(deliverableIconFor(widget.item.extension), size: 18, color: context.c.accent),
                  const SizedBox(width: AppSpace.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.item.fileName,
                          style: TextStyle(
                            fontSize: AppText.title,
                            fontWeight: FontWeight.bold,
                            color: context.c.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (widget.item.display.isNotEmpty && widget.item.display != widget.item.fileName)
                          Text(
                            widget.item.display,
                            style: TextStyle(
                              fontSize: AppText.caption,
                              fontFamily: 'monospace',
                              color: context.c.textTertiary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (hasText)
                    _toolbarIcon(
                      key: const ValueKey('deliverable-preview-copy-all'),
                      tooltip: '复制全部',
                      icon: Icons.copy_all_rounded,
                      color: context.c.textSecondary,
                      onPressed: _copy,
                    ),
                  if (showLineNumberToggle)
                    _toolbarIcon(
                      key: const ValueKey('deliverable-preview-linenumbers'),
                      tooltip: _showLineNumbers ? '隐藏行号' : '显示行号',
                      icon: _showLineNumbers
                          ? Icons.format_list_numbered_rounded
                          : Icons.format_list_numbered_outlined,
                      color: _showLineNumbers ? context.c.accent : context.c.textSecondary,
                      onPressed: () => setState(() => _showLineNumbers = !_showLineNumbers),
                    ),
                  if (isMarkdown)
                    _toolbarIcon(
                      key: const ValueKey('deliverable-preview-md-source'),
                      tooltip: _markdownSource ? '看渲染后的样子' : '看 Markdown 源码',
                      icon: _markdownSource ? Icons.visibility_rounded : Icons.code_rounded,
                      color: _markdownSource ? context.c.accent : context.c.textSecondary,
                      onPressed: () => setState(() => _markdownSource = !_markdownSource),
                    ),
                  _toolbarIcon(
                    tooltip: '关闭',
                    icon: Icons.close_rounded,
                    color: context.c.textSecondary,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: context.c.border),
            Flexible(child: _buildBody(result)),
            if (result != null && result.ok) ...[
              Divider(height: 1, color: context.c.border),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Row(
                  children: [
                    if (hasText)
                      TextButton.icon(
                        key: const ValueKey('deliverable-preview-copy'),
                        onPressed: _copy,
                        icon: Icon(Icons.copy_rounded, size: 14, color: context.c.textSecondary),
                        label: Text('复制',
                            style: TextStyle(fontSize: AppText.subhead, color: context.c.textSecondary)),
                      ),
                    const Spacer(),
                    if (widget.onDownload != null)
                      TextButton.icon(
                        key: const ValueKey('deliverable-preview-download'),
                        onPressed: () {
                          Navigator.of(context).maybePop();
                          widget.onDownload!();
                        },
                        icon: Icon(Icons.download_rounded, size: 14, color: context.c.accent),
                        label: Text('下载 / 打开',
                            style: TextStyle(fontSize: AppText.subhead, color: context.c.accent)),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 顶部工具条按钮：固定 32×32 而不是 IconButton 默认的 48 —— 标题行里挤四个
  /// 48dp 的点击区会把文件名压成一条省略号。
  Widget _toolbarIcon({
    Key? key,
    required String tooltip,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 18, color: color),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 34, height: 32),
    );
  }

  Widget _buildBody(TextFileContent? result) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(28),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    // 异常与网关的 ok:false 走同一个出口：都只是"这次没读到"，给原因 + 重试。
    if (_error.isNotEmpty || result == null || !result.ok) {
      final reason = _error.isNotEmpty
          ? _error
          : (result!.error.isNotEmpty ? result.error : '预览失败');
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '读取失败：$reason',
              key: const ValueKey('deliverable-preview-error'),
              style: TextStyle(fontSize: AppText.body, color: context.c.danger, height: 1.35),
            ),
            const SizedBox(height: AppSpace.m),
            TextButton.icon(
              onPressed: _retry,
              icon: Icon(Icons.refresh_rounded, size: 16, color: context.c.accent),
              label: Text('重试', style: TextStyle(fontSize: AppText.body, color: context.c.accent)),
            ),
          ],
        ),
      );
    }

    if (result.binary) {
      // **不渲染字节**：把 PNG/xlsx 的字节塞进文本视图只会得到一屏乱码，它对
      // 用户零信息，还会让人以为"文件坏了"。给一句说明 + 底部的下载出口。
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.description_outlined, size: 26, color: context.c.textTertiary),
            const SizedBox(height: AppSpace.m),
            Text(
              result.note.isNotEmpty ? result.note : '这是二进制文件，无法在手机上按文本预览。',
              key: const ValueKey('deliverable-preview-binary'),
              style: TextStyle(fontSize: AppText.body, color: context.c.textSecondary, height: 1.4),
            ),
            if (result.size != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.s),
                child: Text('文件大小 ${_bytes(result.size!)}',
                    style: TextStyle(fontSize: AppText.subhead, color: context.c.textTertiary)),
              ),
            const SizedBox(height: AppSpace.m),
            Text('用下载按钮在其它应用里打开。',
                style: TextStyle(fontSize: AppText.subhead, color: context.c.textTertiary)),
          ],
        ),
      );
    }

    final content = result.content ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (result.truncated)
            // 截断必须说在前面：用户会把预览当成全文来下判断，而它只是前一段。
            Container(
              key: const ValueKey('deliverable-preview-truncated'),
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: context.c.warningSurface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: context.c.warningBorder),
              ),
              child: Text(
                '只显示开头的一部分${result.size != null ? '（文件共 ${_bytes(result.size!)}）' : ''}，'
                '完整内容请下载后用其它应用打开。',
                style: TextStyle(fontSize: AppText.subhead, color: context.c.warning, height: 1.35),
              ),
            ),
          if (result.isMarkdown && !_markdownSource)
            // 交付物里 .md 很常见，而它是唯一"排版本身就是信息"的类型。
            //
            // **为什么 .md 默认走渲染视图、而不是默认高亮源码**（这不是漏做）：
            // 规格书里"扩展名映射语言"说的是**功能覆盖**，不是默认行为。对 .md 而
            // 言，渲染出来的标题层级/列表/表格本身就在传递结构，而源码行号只对
            // "我要核对这一行的原始写法"有用 —— 那是少数场景，所以把它放在工具条
            // 的 `源码` 开关后面（`_markdown` 的分词规则就是为它准备的）。反过来
            // 默认给源码，等于让最常见的 .md 交付物失去它唯一的优势。
            SafeMarkdown(data: content)
          else
            _buildSource(content, result),
        ],
      ),
    );
  }

  /// 源码 / 纯文本：等宽 + 可选高亮 + 可选行号。
  ///
  /// 两种模式刻意不同，不是"同一段代码少个槽位"：
  /// * **行号开**：不软换行（内容在横向滚动里按固有宽度铺开），行号槽才不会因为
  ///   某一行折行而与正文错开；看代码时"几行就是几行"也比折行更重要。
  /// * **行号关**：回到原来的阅读体验 —— 软换行、竖向一滚到底（.txt/.csv 的长段落
  ///   横向拖动是很难受的）。
  Widget _buildSource(String content, TextFileContent result) {
    final name = result.name.isNotEmpty ? result.name : widget.item.fileName;
    final language = CodeLanguage.forFile(name.isNotEmpty ? name : widget.item.path);

    // 颜色全部来自 token 层，再作为参数交给高亮器 —— 高亮器自己不认识 context。
    final palette = CodePalette(
      plain: context.c.textPrimary,
      comment: context.c.textTertiary,
      string: context.c.terminalGreen,
      keyword: context.c.accent,
      number: context.c.orange,
      punctuation: context.c.textSecondary,
    );
    final base = TextStyle(
      fontSize: AppText.subhead,
      fontFamily: 'monospace',
      height: 1.45,
      color: context.c.textPrimary,
    );
    final spans = codeSpans(content, language: language, palette: palette, base: base);

    final body = SelectableText.rich(
      TextSpan(children: spans, style: base),
      style: base,
      strutStyle: _codeStrut,
    );

    final Widget view = _showLineNumbers
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _lineNumberGutter(content),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: body,
                ),
              ),
            ],
          )
        : body;

    if (language == null) {
      // 未知类型：不改底色、不加框，就是原来那段等宽文本（只是换成了 rich 承载，
      // 这样行号槽和高亮都能走同一条布局）。
      return view;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.l, vertical: AppSpace.m),
      decoration: BoxDecoration(
        color: context.c.codeBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.c.border),
      ),
      child: view,
    );
  }

  /// 行号槽。
  ///
  /// 刻意用**一个** `Text` 把 `1\n2\n3…` 拼起来，而不是 `Column` 里 N 个 Text：
  /// 行高由同一套 strut 决定，两列天然对齐；同时几千行的文件也只多出一个段落
  /// 对象，不会把预览页变成"几千个 Text 的 Column"。
  Widget _lineNumberGutter(String content) {
    final lines = '\n'.allMatches(content).length + 1;
    final numbers = List<String>.generate(lines, (i) => '${i + 1}'.padLeft(4)).join('\n');
    return Padding(
      padding: const EdgeInsets.only(right: AppSpace.m),
      child: Text(
        numbers,
        textAlign: TextAlign.right,
        strutStyle: _codeStrut,
        style: TextStyle(
          fontSize: AppText.subhead,
          fontFamily: 'monospace',
          height: 1.45,
          color: context.c.textTertiary,
        ),
      ),
    );
  }
}
