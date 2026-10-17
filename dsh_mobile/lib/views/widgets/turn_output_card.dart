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
/// 「本轮产出」卡片和信息面板共用这一行。行上有**两个**动作位，这是刻意的：
/// 主点击是"看一眼"（就地预览），长按才是"拿去用"（下载 / 拉起系统应用）。
/// 把下载放在主点击上就等于说"每次想看一眼都要先落一份文件到手机里"，而
/// 长按是这个行上唯一不与主点击冲突、也不新增视觉噪声的第二动作位。
class DeliverableRow extends StatelessWidget {
  const DeliverableRow({
    super.key,
    required this.item,
    this.onOpen,
    this.onLongPress,
    this.trailingIcon,
    this.busy = false,
    this.dense = false,
  });

  final DeliverableItem item;
  final VoidCallback? onOpen;

  /// 第二动作（下载 / 用其它应用打开）。为 null 时长按无动作。
  final VoidCallback? onLongPress;

  /// 尾部图标。默认画下载箭头；主点击已经是预览时，调用方应换成眼睛——尾部画着
  /// 下载箭头却在点下去时开预览，图标就在说假话。
  final IconData? trailingIcon;

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
      onLongPress: onLongPress,
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
              Icon(trailingIcon ?? Icons.download_rounded, size: 18, color: context.c.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// 消息流里的「本轮产出」条——挂在**交付它的那一轮**之后。
///
/// [fix 2026-10-17 用户反馈] 视觉形态从"独立卡片"降为**行内紧凑条**：无边框、
/// 无独立背景，标题弱色小字，交付物行紧凑排列 —— 它是消息流的一部分，不是
/// 一个插进来的块。
///
/// 这是"事件进流"那一半：用户在"agent 说做完了"的那一刻要的是文件，所以它
/// 出现在消息流的那个位置，而不是某个需要跳过去的页面。用户一旦发出下一条消息，
/// 它就不再是"刚刚发生的事"，由调用方把它摘掉（常驻记录在信息面板里）。
///
/// 两个动作位与信息面板**逐字对齐**（主点击 = 就地预览，长按 = 下载 / 用其它
/// 应用打开）：同一个东西在会话里点一下是预览、在面板里点一下变成下载，是这次
/// 改动之前真实存在的错位，用户没法从界面上学到任何一种。
///
/// ⚠️ **必须传 REST 返回的行**（`GET /api/mobile/deliverables`）：那里的 `path`
/// 是网关解析后的**绝对路径**，也正是下载路由与预览路由做成员判定时认的 key
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
    this.onDownload,
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

  /// 主点击：就地预览内容。
  final ValueChanged<DeliverableItem>? onOpen;

  /// 长按：下载 / 用其它应用打开。
  ///
  /// 传了它就意味着主点击已经被预览占住，所以卡片会自动换成眼睛图标并加一行
  /// 手势说明 —— 长按是完全不可发现的，不写出来就等于没有这个功能。
  final ValueChanged<DeliverableItem>? onDownload;

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
    final download = onDownload;
    final hasSecondAction = download != null && onOpen != null;

    // [fix 2026-10-17 用户反馈] 卡片降为**行内紧凑条**：此前是带边框、带
    // 背景的独立卡片横在消息流末尾，视觉上像一个突兀的消息气泡 —— 用户点名
    // "单独一行太突兀"。现在无卡片边框、无独立背景，标题行缩为一枚小图标 +
    // 弱色标题，交付物行去掉卡片式间距，整体像消息流的一部分而不是一个块。
    return Container(
      key: const ValueKey('turn-output-card'),
      margin: const EdgeInsets.only(top: 2, bottom: 2),
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.inventory_2_outlined, size: 13, color: context.c.textTertiary),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.c.textTertiary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onShowAll != null)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onShowAll,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Text('查看全部',
                        style: TextStyle(fontSize: 11, color: context.c.accent)),
                  ),
                ),
            ],
          ),
          for (final item in shown)
            DeliverableRow(
              item: item,
              dense: true,
              busy: busyPath != null && busyPath == item.path,
              trailingIcon: hasSecondAction ? Icons.visibility_rounded : null,
              onOpen: onOpen == null ? null : () => onOpen!(item),
              onLongPress: hasSecondAction ? () => download(item) : null,
            ),
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '还有 $hidden 个',
                style: TextStyle(fontSize: 10.5, color: context.c.textTertiary),
              ),
            ),
          if (hasSecondAction)
            Padding(
              padding: const EdgeInsets.only(top: 1, left: 4),
              child: Text(
                '点一下预览 · 长按下载',
                key: const ValueKey('turn-output-hint'),
                style: TextStyle(fontSize: 10, color: context.c.textTertiary),
              ),
            ),
          if (errorText != null && errorText!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3, left: 4),
              child: Text(
                errorText!,
                key: const ValueKey('turn-output-error'),
                style: TextStyle(fontSize: 11, color: context.c.danger),
              ),
            ),
        ],
      ),
    );
  }
}
