import 'package:flutter/material.dart';

import '../models/harness_notice.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// 引擎注入通知的卡片。
///
/// 它**不是聊天气泡**：左对齐/右对齐都表示"谁在说话"，而这条消息根本没有人说话
/// —— 是引擎把子代理的结算通知以 `user/message` 的形式写进了会话（见
/// [HarnessNotice] 的说明）。所以这里刻意做成居中的灰色块，并在底部写明
/// "引擎注入的通知（不是你说的话）"，让"我什么时候发过这种消息"这个疑问自答。
///
/// 自包含：数据全靠参数传进来，不读 `DshService`，可以在任何宿主里单独渲染与断言。
class HarnessNoticeCard extends StatefulWidget {
  const HarnessNoticeCard({
    super.key,
    required this.notice,
    this.maxBodyLines = 3,
  });

  final HarnessNotice notice;

  /// 折叠时收尾正文显示几行。默认 3：一条子代理收尾实测能占满两屏。
  final int maxBodyLines;

  @override
  State<HarnessNoticeCard> createState() => _HarnessNoticeCardState();
}

class _HarnessNoticeCardState extends State<HarnessNoticeCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final notice = widget.notice;
    final accent = _accentColor(context, notice);
    final body = notice.body;
    final shortId = notice.shortChildId;

    return Center(
      child: ConstrainedBox(
        // 居中之后必须限宽：不限宽的话这条通知会在平板上被拉成一整行，读起来比
        // 气泡还费劲。（气泡天然只占内容宽度，居中块没有这个约束。）
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          key: const ValueKey('harness-notice-card'),
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 7),
          decoration: BoxDecoration(
            color: context.c.surfaceMuted,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: context.c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_icon(notice), size: 15, color: accent),
                  const SizedBox(width: AppSpace.m),
                  Expanded(
                    child: Text(
                      noticeTitle(notice),
                      key: const ValueKey('harness-notice-title'),
                      style: TextStyle(
                        fontSize: AppText.body,
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                  ),
                  if (shortId != null) ...[
                    const SizedBox(width: AppSpace.s),
                    Text(
                      '#$shortId',
                      style: TextStyle(
                        fontSize: AppText.caption,
                        fontFamily: 'monospace',
                        color: context.c.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
              if (body != null) ...[
                const SizedBox(height: AppSpace.m),
                SelectableText(
                  body,
                  key: const ValueKey('harness-notice-body'),
                  maxLines: _expanded ? null : widget.maxBodyLines,
                  style: TextStyle(
                    fontSize: AppText.caption,
                    height: 1.4,
                    color: context.c.textSecondary,
                  ),
                ),
                const SizedBox(height: AppSpace.xs),
                InkWell(
                  key: const ValueKey('harness-notice-toggle'),
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _expanded ? '收起' : '展开收尾内容（${body.length} 字）',
                          style: TextStyle(fontSize: AppText.caption, color: context.c.accent),
                        ),
                        Icon(
                          _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                          size: 15,
                          color: context.c.accent,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: AppSpace.xs),
              Text(
                '引擎注入的通知（不是你说的话）',
                style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 标题按种类给。认不出的种类宁可说"引擎通知"，也不要编一个像是功能名的词。
  static String noticeTitle(HarnessNotice notice) {
    if (notice.isSubagentSettlement) {
      switch (notice.variant) {
        case 'completed':
          return '子代理完成';
        case 'aborted':
          return '子代理被中止';
        case 'max-tokens':
          return '子代理 token 用尽';
        default:
          return '子代理通知';
      }
    }
    if (notice.kind.startsWith('plugin:')) return '插件通知';
    switch (notice.kind) {
      case 'agent-instructions':
        return '系统指令';
      default:
        return '引擎通知';
    }
  }

  static IconData _icon(HarnessNotice notice) {
    if (notice.isSubagentSettlement) return Icons.hub_outlined;
    if (notice.kind.startsWith('plugin:')) return Icons.shield_outlined;
    return Icons.info_outline_rounded;
  }

  static Color _accentColor(BuildContext context, HarnessNotice notice) {
    if (notice.isSubagentSettlement) return context.c.accent;
    if (notice.kind.startsWith('plugin:')) return context.c.warning;
    return context.c.textSecondary;
  }
}
