import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// 设置区共用的一组小部件。
///
/// ## 为什么抽出来
///
/// 设置页从「一张超长表单」改成「入口式 hub + 若干二级页」之后，卡片装饰、
/// 分区标题、跳转行这三样在 hub 与每个二级页里都要出现。留在各家各写一份的话，
/// 下一轮视觉调整必然只改到其中两页 —— 同一屏里出现两种圆角、两种描边。
///
/// 这里只放**纯展示**的东西：不持有状态、不碰 DshService、不发请求。

/// 设置卡片的统一装饰（底 + 圆角 + 描边 + 极轻阴影）。
BoxDecoration settingsCardDecoration(BuildContext context) {
  return BoxDecoration(
    color: context.c.surface,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: context.c.border),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.02),
        blurRadius: 6,
        offset: const Offset(0, 2),
      ),
    ],
  );
}

/// 分区标题：**只有中文**。
///
/// 旧版是「中文主标题 + (English subtitle)」两行。它有两个真问题：英文是给
/// 开发者看的词（LLM & Reasoning / Connectivity & Diagnostics），对用户只是噪音；
/// 而且中英挤在一行时窄屏会在 `&` 处断行，看起来像排版坏了（为此还专门写过
/// 一段拆括号的逻辑）。入口式 hub 里每个分区只有 1~2 行，标题越短越好。
class SettingsSectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;

  const SettingsSectionHeader({
    super.key,
    required this.title,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: AppSpace.m),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: AppText.heading,
              fontWeight: FontWeight.bold,
              color: context.c.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

/// 「跳去另一个页面」的行卡片：图标 + 标题 + 摘要 + 箭头。
///
/// 与「显示当前值」的信息卡刻意区分：设置页里"看到一个值"和"去一个地方"是两类
/// 东西，混在同一张卡里最常见的问题就是用户不知道哪块能点。凡是能点的，一律用
/// 这个形状（带 chevron）；凡是只读的，一律不带。
class SettingsNavCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  /// 摘要行里那枚状态点的颜色。null 时不画点。
  final Color? dotColor;

  /// 摘要文字的颜色。默认次级灰；有状态时需要强调（如待处理橙色）。
  final Color? subtitleColor;

  /// 标题右侧的小徽标（例如「3 项待处理」）。null 时不画。
  final String? badge;

  final VoidCallback onTap;

  const SettingsNavCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.dotColor,
    this.subtitleColor,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: settingsCardDecoration(context),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: (dotColor ?? context.c.accent).withOpacity(0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: dotColor ?? context.c.accent, size: 21),
            ),
            const SizedBox(width: AppSpace.l),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: context.c.textPrimary,
                          ),
                        ),
                      ),
                      if (badge != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: context.c.warning.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badge!,
                            style: TextStyle(
                              fontSize: AppText.caption,
                              fontWeight: FontWeight.w600,
                              color: context.c.warning,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Row(
                    children: [
                      if (dotColor != null) ...[
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Expanded(
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppText.subhead,
                            color: subtitleColor ?? context.c.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: context.c.textTertiary, size: 20),
          ],
        ),
      ),
    );
  }
}

/// 二级页统一的 AppBar（与 hub 同一套颜色与 1px 底线）。
AppBar settingsAppBar(BuildContext context, String title) {
  return AppBar(
    backgroundColor: context.c.surface,
    foregroundColor: context.c.textPrimary,
    elevation: 0,
    surfaceTintColor: Colors.transparent,
    bottom: PreferredSize(
      preferredSize: const Size.fromHeight(1),
      child: Container(color: context.c.border, height: 1),
    ),
    title: Text(
      title,
      style: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.bold,
        color: context.c.textPrimary,
      ),
    ),
  );
}
