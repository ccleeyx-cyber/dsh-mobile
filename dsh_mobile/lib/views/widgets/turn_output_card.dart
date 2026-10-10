import 'package:flutter/material.dart';

import '../../models/task_center.dart';
import '../../theme/app_colors.dart';

/// 交付物图标的唯一映射。
///
/// 抽成顶层函数的理由：消息流里的「本轮产出」卡片和信息面板里的交付物清单
/// 必须给同一个文件同一个图标——两处各写一份 `switch` 就是下一次"同一个 docx
/// 在两处长得不一样"的来源。
IconData deliverableIconFor(String extension) {
  switch (extension) {
    case 'docx':
    case 'doc':
    case 'md':
      return Icons.description_rounded;
    case 'xlsx':
    case 'xls':
    case 'csv':
      return Icons.table_chart_rounded;
    case 'pptx':
    case 'ppt':
      return Icons.slideshow_rounded;
    case 'pdf':
      return Icons.picture_as_pdf_rounded;
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'webp':
    case 'gif':
      return Icons.image_rounded;
    case 'zip':
    case '7z':
    case 'tar':
    case 'gz':
      return Icons.folder_zip_rounded;
    default:
      return Icons.insert_drive_file_rounded;
  }
}

/// 一行交付物：图标 + 文件名 + 说明 + 尾部动作。
///
/// 「本轮产出」卡片和信息面板共用这一行；点它会走下载 + 拉起系统应用那条链路。
class DeliverableRow extends StatelessWidget {
  const DeliverableRow({
    super.key,
    required this.item,
    this.onOpen,
    this.busy = false,
    this.dense = false,
  });

  final DeliverableItem item;
  final VoidCallback? onOpen;

  /// 正在为这一行下载（显示转圈，避免用户重复点两次）。
  final bool busy;

  /// 面板里用紧凑间距（列表可能很长）。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    // 说明优先；没有说明时退回相对路径（比绝对路径可读）。两者都不比文件名多出
    // 任何信息时（例如文件就在工作区根目录，display == fileName）就不再画第二行
    // —— 同一个名字连着出现两遍是噪声，不是信息。
    final secondary = item.description.isNotEmpty ? item.description : item.display;
    final showSecondary = secondary.isNotEmpty && secondary != item.fileName;

    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: dense ? 5 : 7),
        child: Row(
          children: [
            Icon(deliverableIconFor(item.extension), size: 20, color: context.c.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.fileName,
                    style: TextStyle(fontSize: 12.5, color: context.c.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (showSecondary)
                    Text(
                      secondary,
                      style: TextStyle(fontSize: 10.5, color: context.c.textTertiary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (busy)
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            else
              Icon(Icons.download_rounded, size: 18, color: context.c.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// 消息流里的「本轮产出」卡片——挂在**交付它的那一轮**之后。
///
/// 这是"事件进流"那一半：用户在"agent 说做完了"的那一刻要的是文件，所以卡片
/// 出现在消息流的那个位置，而不是某个需要跳过去的页面。用户一旦发出下一条消息，
/// 它就不再是"刚刚发生的事"，由调用方把它摘掉（常驻记录在信息面板里）。
///
/// ⚠️ **必须传 REST 返回的行**（`GET /api/mobile/deliverables`）：那里的 `path`
/// 是网关解析后的**绝对路径**，也正是下载路由做成员判定时认的 key
/// （`resolveDeliverable`）。WS `deliverables` 帧里只有相对路径 + 说明，
/// 拿它去请求下载会被判 403 —— 帧只配用来触发"有新东西了"这个信号。
class TurnOutputCard extends StatelessWidget {
  const TurnOutputCard({
    super.key,
    required this.deliverables,
    this.maxRows = 5,
    this.busyPath,
    this.errorText,
    this.onOpen,
    this.onShowAll,
  });

  /// 本会话的完整交付物清单（已按 seq 倒序）。卡片自己只取最新一轮。
  final List<DeliverableItem> deliverables;

  /// 卡片里最多列几行——手机竖屏上这已经是极限，再多就把消息流挤走了。
  final int maxRows;

  /// 正在下载的那一个的 `path`。
  final String? busyPath;

  /// 下载失败的说明。**内联在卡片里**，不用 SnackBar：SnackBar 会在用户
  /// 视线之外消失，而卡片才是他此刻正在看的地方。
  final String? errorText;

  final ValueChanged<DeliverableItem>? onOpen;

  /// "查看全部"→ 打开信息面板（那里按轮分组列出所有产出）。
  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    final groups = groupDeliverablesByTurn(deliverables);
    if (groups.isEmpty) return const SizedBox.shrink();

    final latest = groups.first;
    final rows = latest.items;
    final shown = rows.take(maxRows).toList(growable: false);
    final hidden = rows.length - shown.length;
    // 全都没有轮号时不假装它们属于同一轮——降级成"最近交付"，只改文案不改事实。
    final title = latest.turnLabel == null
        ? '最近交付 · ${rows.length} 个文件'
        : '${latest.turnLabel}产出 · ${rows.length} 个文件';

    return Container(
      key: const ValueKey('turn-output-card'),
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.c.accent.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.inventory_2_outlined, size: 15, color: context.c.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: context.c.accent),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final item in shown)
            DeliverableRow(
              item: item,
              busy: busyPath != null && busyPath == item.path,
              onOpen: onOpen == null ? null : () => onOpen!(item),
            ),
          if (hidden > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: onShowAll,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  '还有 $hidden 个 · 查看全部',
                  style: TextStyle(fontSize: 11.5, color: context.c.accent),
                ),
              ),
            ),
          if (errorText != null && errorText!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                errorText!,
                key: const ValueKey('turn-output-error'),
                style: TextStyle(fontSize: 11.5, color: context.c.danger),
              ),
            ),
        ],
      ),
    );
  }
}
