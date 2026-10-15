import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/bridge_extras.dart';
import '../../models/task_center.dart';
import '../../theme/app_colors.dart';
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
/// **不渲染字节**）、文本（Markdown 或等宽纯文本 + 截断横幅）。
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

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  Icon(deliverableIconFor(widget.item.extension), size: 18, color: context.c.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.item.fileName,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (widget.item.display.isNotEmpty && widget.item.display != widget.item.fileName)
                          Text(
                            widget.item.display,
                            style: TextStyle(fontSize: 10.5, fontFamily: 'monospace', color: context.c.textTertiary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: Icon(Icons.close_rounded, size: 20, color: context.c.textSecondary),
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
                        label: Text('复制', style: TextStyle(fontSize: 11.5, color: context.c.textSecondary)),
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
                        label: Text('下载 / 打开', style: TextStyle(fontSize: 11.5, color: context.c.accent)),
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
              style: TextStyle(fontSize: 12.5, color: context.c.danger, height: 1.35),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _retry,
              icon: Icon(Icons.refresh_rounded, size: 16, color: context.c.accent),
              label: Text('重试', style: TextStyle(fontSize: 12, color: context.c.accent)),
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
            const SizedBox(height: 8),
            Text(
              result.note.isNotEmpty ? result.note : '这是二进制文件，无法在手机上按文本预览。',
              key: const ValueKey('deliverable-preview-binary'),
              style: TextStyle(fontSize: 12.5, color: context.c.textSecondary, height: 1.4),
            ),
            if (result.size != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('文件大小 ${_bytes(result.size!)}',
                    style: TextStyle(fontSize: 11.5, color: context.c.textTertiary)),
              ),
            const SizedBox(height: 6),
            Text('用下载按钮在其它应用里打开。', style: TextStyle(fontSize: 11.5, color: context.c.textTertiary)),
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
                style: TextStyle(fontSize: 11.5, color: context.c.warning, height: 1.35),
              ),
            ),
          if (result.isMarkdown)
            // 交付物里 .md 很常见，而它是唯一"排版本身就是信息"的类型。
            SafeMarkdown(data: content)
          else
            // 其余按纯文本等宽渲染：csv/日志/源码的对齐在等宽下才读得出来。
            SelectableText(
              content,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                height: 1.45,
                color: context.c.textPrimary,
              ),
            ),
        ],
      ),
    );
  }
}
