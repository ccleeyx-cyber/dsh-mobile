import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// 页面内的常驻错误条（Phase 4.5）。
///
/// ## 为什么不是 SnackBar
///
/// SnackBar 的问题是**它会自己消失**。对于"保存失败""切换策略失败""引擎拒绝"
/// 这类失败，用户往往正在看别处、或刚好低头看键盘 —— 等抬头时提示已经飘走了，
/// 屏幕上只剩一个看起来成功了的旧状态。更糟的是下一屏会读到一个"其实没生效"
/// 的开关，用户会以为是自己记错了。
///
/// 所以这里的原则是：**错误留在屏幕上，直到用户处理它，或重试成功**。
///
/// ## 和"成功提示"的分工
///
/// 成功是一过性事实（"已保存"），飘走没关系；失败是一个**待办**，不能飘走。
/// 所以成功继续用 SnackBar，失败改用这个条。
///
/// ## 为什么不做成红色大横幅
///
/// 失败条如果比页面内容更抢眼，用户会本能地先关掉它而不是处理它。这里用
/// `dangerSurface` 底 + 1px 边 + 一行 caption 级文字：看得见、但不喧宾夺主。
class InlineErrorBar extends StatelessWidget {
  const InlineErrorBar({
    super.key,
    required this.message,
    this.onRetry,
    this.onDismiss,
    this.retryLabel = '重试',
    this.dense = false,
  });

  /// 已经面向用户措辞过的失败原因（不要塞异常栈）。
  final String message;

  /// 为 null 时不渲染重试按钮 —— 不给点了没反应的入口。
  final VoidCallback? onRetry;

  /// 为 null 时不渲染关闭按钮（有些失败必须看到，不该被关掉）。
  final VoidCallback? onDismiss;

  final String retryLabel;

  /// 紧凑模式：用在列表行内或卡片内部，去掉外上下的留白。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(top: dense ? 0 : AppSpace.m, bottom: dense ? 0 : AppSpace.m),
      padding: const EdgeInsets.fromLTRB(AppSpace.l, AppSpace.m, AppSpace.s, AppSpace.m),
      decoration: BoxDecoration(
        color: context.c.dangerSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.c.dangerBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.error_outline_rounded, size: 14, color: context.c.danger),
          ),
          const SizedBox(width: AppSpace.m),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: AppText.caption,
                height: 1.4,
                color: context.c.textPrimary,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.m),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: context.c.danger,
              ),
              child: Text(
                retryLabel,
                style: TextStyle(
                  fontSize: AppText.caption,
                  fontWeight: FontWeight.w600,
                  color: context.c.danger,
                ),
              ),
            ),
          if (onDismiss != null)
            InkWell(
              onTap: onDismiss,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.s),
                child: Icon(Icons.close_rounded, size: 14, color: context.c.textTertiary),
              ),
            ),
        ],
      ),
    );
  }
}
