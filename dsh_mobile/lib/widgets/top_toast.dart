import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// 顶部浮出的轻提示（"本会话模型已切换为 …"这类瞬时反馈）。
///
/// ## 为什么不做到底部
///
/// Material 的 SnackBar 默认贴底。在这个 App 里底部是最拥挤的地方：输入卡片、
/// 状态胶囊、审批 dock 全在那儿，一条 SnackBar 会把用户**正在打的字**盖住 ——
/// 而且它紧贴输入框，很容易被读成"输入框的一部分"。顶部在此时是空的（会话名
/// 那一行 + 一片留白），同样的信息放在那里既不挡手也不引起误解。
///
/// ## 与 SnackBar 的分工（不要混用）
///
/// * **成功 / 已生效**（切换模型、切换权限、复制完成）→ 这里，1.8 秒自己走。
/// * **失败 / 需要用户处理**（发送失败、下载失败、断网）→ 不许自己消失，
///   走 `InlineErrorBar` 或页面内的固定提示。
///
/// 也就是说：**这里只放"不痛的消息"**。任何用户可能想要再看一眼的东西都不能走
/// 这条路径 —— 它会自己消失，而且不占位。
class TopToast {
  TopToast._();

  static OverlayEntry? _entry;
  static Timer? _timer;

  /// 顶栏之下多少 dp 开始画（AppBar 56 + 一点呼吸）。
  static const double _topGap = 62;

  static void show(
    BuildContext context,
    String message, {
    IconData icon = Icons.check_circle_outline_rounded,
    Color? accentColor,
  }) {
    TopToastHandle.capture(context).show(message, icon: icon, accentColor: accentColor);
  }

  static void _showIn(
    OverlayState overlay,
    bool isDark,
    double topInset,
    String message, {
    IconData icon = Icons.check_circle_outline_rounded,
    Color? accentColor,
  }) {
    // 单实例：连续切换模型时后一条顶掉前一条，而不是叠成一列。
    _dismiss();

    final accent = accentColor ?? (isDark ? AppColors.accentDark : AppColors.accent);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _TopToastView(
        message: message,
        icon: icon,
        accent: accent,
        isDark: isDark,
        topPadding: topInset + _topGap,
        onDismissed: () {
          if (identical(_entry, entry)) _dismiss();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    _timer = Timer(const Duration(milliseconds: 1800), _dismiss);
  }

  static void _dismiss() {
    _timer?.cancel();
    _timer = null;
    final entry = _entry;
    _entry = null;
    if (entry != null && entry.mounted) entry.remove();
  }
}

/// 提前"抓住"能弹 toast 的那两样东西：root overlay 与主题明暗。
///
/// ## 为什么需要它（而不是到处直接 `TopToast.show(context, …)`）
///
/// 这些提示几乎都出现在**异步动作之后**，而动作的第一步往往是
/// `Navigator.pop(ctx)` 把弹层关掉 —— 等 `await` 回来时，弹层的 `context` 已经
/// 卸载，`Overlay.of` 和 `ThemeScope.of` 都拿不到了（这正是仓库里那条
/// "after Navigator.pop the item context is unmounted, so the SnackBar here was
/// dead code" 注释踩过的坑）。
///
/// 所以在弹层还活着的时候先把 overlay 和明暗抓在手里，之后再 show 就与 context
/// 生命周期无关了。
class TopToastHandle {
  TopToastHandle._(this._overlay, this._isDark, this._topInset);

  factory TopToastHandle.capture(BuildContext context) => TopToastHandle._(
        Overlay.maybeOf(context, rootOverlay: true),
        ThemeScope.isDarkOf(context),
        MediaQuery.paddingOf(context).top,
      );

  final OverlayState? _overlay;
  final bool _isDark;
  final double _topInset;

  void show(
    String message, {
    IconData icon = Icons.check_circle_outline_rounded,
    Color? accentColor,
  }) {
    final overlay = _overlay;
    if (overlay == null || !overlay.mounted) return; // 页面还没挂 overlay：宁可不提示
    TopToast._showIn(overlay, _isDark, _topInset, message,
        icon: icon, accentColor: accentColor);
  }
}

class _TopToastView extends StatefulWidget {  const _TopToastView({
    required this.message,
    required this.icon,
    required this.accent,
    required this.isDark,
    required this.topPadding,
    required this.onDismissed,
  });

  final String message;
  final IconData icon;
  final Color accent;
  final bool isDark;
  final double topPadding;
  final VoidCallback onDismissed;

  @override
  State<_TopToastView> createState() => _TopToastViewState();
}

class _TopToastViewState extends State<_TopToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..forward();

  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOut,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    Color pick(Color light, Color dark) => isDark ? dark : light;
    return Positioned(
      top: widget.topPadding,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _fade,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.25),
              end: Offset.zero,
            ).animate(_fade),
            child: Material(
              color: pick(AppColors.surface, AppColors.surfaceDark),
              elevation: 6,
              shadowColor: Colors.black.withOpacity(0.18),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.l,
                  vertical: AppSpace.m,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: pick(AppColors.border, AppColors.borderDark)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, size: 16, color: widget.accent),
                    const SizedBox(width: AppSpace.s),
                    Flexible(
                      child: Text(
                        widget.message,
                        key: const ValueKey('top-toast-text'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: pick(AppColors.textPrimary, AppColors.textPrimaryDark),
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
