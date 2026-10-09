import 'package:flutter/material.dart';

/// 语义色 token 层（v1.6.0 深色模式的地基）。
///
/// ## 为什么先做这一层
///
/// 改动前 `lib/` 下有 **592 处硬编码 `Color(0x...)`**，其中 29 个色值覆盖 523 处
/// （88%）。直接把 `const Color(0xFF0078D4)` 换成深色值是不行的 —— 那只会得到
/// 「深色底 + 深色字」。`main.dart` 里原本那段假 `darkTheme`（亮色主题的逐字
/// 副本）就是这么来的，它永远不会被使用，只让读代码的人以为存在深色主题。
///
/// 正确顺序：先 token 化 → 再建 darkTheme → 最后放开 `themeMode`。这一层就是
/// 第一步。
///
/// ## 用法
///
/// 替换硬编码色值时按语义选槽位，不要按"看起来接近"选：
///
/// - 卡片/输入框底 → `surface` / `surfaceMuted`
/// - 卡片之间的描边 → `border`
/// - 正文文字 → `textPrimary`
/// - 次要说明/时间戳 → `textSecondary` / `textTertiary`
/// - 品牌蓝（按钮、选中态）→ `accent`
/// - 危险红 → `danger`
/// - 成功绿 → `success`
/// - 警告橙 → `warning`
///
/// 拿不准就先用 `textPrimary` 之外的中性槽位，**不要**为了让某处"看起来对"
/// 而新增一个一次性色值 —— 那等于把硬编码换个地方继续。
///
/// ## 为什么用 InheritedWidget 而不是 GetIt / 全局单例
///
/// 依赖树里注入颜色，让 widget 测试可以直接包一个 `DarkModeScope` 来断言深色
/// 下的取值，不需要 singleton 或 mockito 技巧。
class AppColors {
  AppColors._();

  // ---- 品牌 ----
  /// 主品牌色。深色下略微提亮，纯深色底上的 #0078D4 对比度不足。
  static const Color accent = Color(0xFF0078D4);
  static const Color accentDark = Color(0xFF3B9EFF);

  // ---- 中性：文字 ----
  /// 主要文字（正文、标题）。
  static const Color textPrimary = Color(0xFF111827);
  static const Color textPrimaryDark = Color(0xFFE5E7EB);

  /// 次要文字（说明、标签）。
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color textSecondaryDark = Color(0xFF9CA3AF);

  /// 最低对比度文字（时间戳、占位符、禁用态）。
  static const Color textTertiary = Color(0xFF9CA3AF);
  static const Color textTertiaryDark = Color(0xFF6B7280);

  // ---- 中性：面 ----
  /// 页面底色。
  static const Color background = Color(0xFFF8FAFC);
  static const Color backgroundDark = Color(0xFF111827);

  /// 卡片/输入框底色。
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceDark = Color(0xFF1F2937);

  /// 次级面（代码块、内嵌区域、hover）。
  static const Color surfaceMuted = Color(0xFFF9FAFB);
  static const Color surfaceMutedDark = Color(0xFF374151);

  /// 描边 / 分隔线。
  static const Color border = Color(0xFFE5E7EB);
  static const Color borderDark = Color(0xFF4B5563);

  // ---- 状态 ----
  static const Color danger = Color(0xFFDC2626);
  static const Color dangerDark = Color(0xFFF87171);

  static const Color success = Color(0xFF10B981);
  static const Color successDark = Color(0xFF34D399);

  static const Color warning = Color(0xFFD97706);
  static const Color warningDark = Color(0xFFFBBF24);

  static const Color purple = Color(0xFF7C3AED);
  static const Color purpleDark = Color(0xFFA78BFA);

  static const Color orange = Color(0xFFEA580C);
  static const Color orangeDark = Color(0xFFFB923C);

  // ---- 带色底（tint）----
  //
  // 实测 lib/ 下有 151 处浅色 tint 底色，散落在审批卡、提问卡、徽章、选中态等
  // 位置。它们不是"某个中性色的浅版本"，而是有语义的底 —— 浅红=危险、浅黄=警告、
  // 浅绿=成功、浅蓝=选中。深色下没有"翻过来"的等价物：把 #FEF2F2 直接取反会
  // 变成刺眼的深红。所以每种语义给一对显式取值，深色侧压低明度并提高饱和度，
  // 保证在深底上仍是"提示色"而不是"发光的色块"。

  /// 危险提示底（浅红）。
  static const Color dangerSurface = Color(0xFFFEF2F2);
  static const Color dangerSurfaceDark = Color(0xFF3F1414);

  /// 危险提示描边（浅红边）。
  static const Color dangerBorder = Color(0xFFFECACA);
  static const Color dangerBorderDark = Color(0xFF7F1D1D);

  /// 警告提示底（浅黄/橙）。
  static const Color warningSurface = Color(0xFFFFFBEB);
  static const Color warningSurfaceDark = Color(0xFF3A2C10);

  /// 警告徽章底（浅琥珀）。
  static const Color warningBadgeSurface = Color(0xFFFEF3C7);
  static const Color warningBadgeSurfaceDark = Color(0xFF422006);

  /// 警告描边（浅琥珀边）。
  static const Color warningBorder = Color(0xFFFDE68A);
  static const Color warningBorderDark = Color(0xFF854D0E);

  /// 成功提示底（浅绿）。
  static const Color successSurface = Color(0xFFDCFCE7);
  static const Color successSurfaceDark = Color(0xFF0F2E1C);

  /// 选中态底（浅蓝，选中行/选中工作区）。
  static const Color selectedSurface = Color(0xFFEFF6FC);
  static const Color selectedSurfaceDark = Color(0xFF10243A);

  /// 品牌浅蓝底（输入框 hover、强调区块）。
  static const Color accentSurface = Color(0xFFF0F7FF);
  static const Color accentSurfaceDark = Color(0xFF0B2036);

  /// 提问卡片底（浅橙，§4.1 提问）。
  static const Color questionSurface = Color(0xFFFFF7ED);
  static const Color questionSurfaceDark = Color(0xFF3A2410);

  /// 提问卡片描边（浅橙边）。
  static const Color questionBorder = Color(0xFFFED7AA);
  static const Color questionBorderDark = Color(0xFF9A5B13);
}

/// 深色模式作用域。
///
/// 用 InheritedWidget 而不是全局单例有两个理由：
/// 1. widget 测试可以直接包一层断言深色取值，不需要 singleton 技巧；
/// 2. 未来若支持"跟随系统"，可以在这一层做 per-subtree 覆盖。
class ThemeScope extends InheritedWidget {
  final bool isDark;

  const ThemeScope({super.key, required this.isDark, required super.child});

  /// Returns the nearest [ThemeScope], falling back to light when none is found.
  static ThemeScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeScope>() ??
      const ThemeScope(isDark: false, child: SizedBox());

  static bool isDarkOf(BuildContext context) => of(context).isDark;

  /// 当前主题下的语义色。做成实例方法，调用方式是 `context.c.surface`。
  Color get accent => isDark ? AppColors.accentDark : AppColors.accent;
  Color get textPrimary => isDark ? AppColors.textPrimaryDark : AppColors.textPrimary;
  Color get textSecondary => isDark ? AppColors.textSecondaryDark : AppColors.textSecondary;
  Color get textTertiary => isDark ? AppColors.textTertiaryDark : AppColors.textTertiary;
  Color get background => isDark ? AppColors.backgroundDark : AppColors.background;
  Color get surface => isDark ? AppColors.surfaceDark : AppColors.surface;
  Color get surfaceMuted => isDark ? AppColors.surfaceMutedDark : AppColors.surfaceMuted;
  Color get border => isDark ? AppColors.borderDark : AppColors.border;
  Color get danger => isDark ? AppColors.dangerDark : AppColors.danger;
  Color get success => isDark ? AppColors.successDark : AppColors.success;
  Color get warning => isDark ? AppColors.warningDark : AppColors.warning;
  Color get purple => isDark ? AppColors.purpleDark : AppColors.purple;
  Color get orange => isDark ? AppColors.orangeDark : AppColors.orange;

  // 带色底（tint）
  Color get dangerSurface => isDark ? AppColors.dangerSurfaceDark : AppColors.dangerSurface;
  Color get dangerBorder => isDark ? AppColors.dangerBorderDark : AppColors.dangerBorder;
  Color get warningSurface => isDark ? AppColors.warningSurfaceDark : AppColors.warningSurface;
  Color get warningBadgeSurface =>
      isDark ? AppColors.warningBadgeSurfaceDark : AppColors.warningBadgeSurface;
  Color get warningBorder => isDark ? AppColors.warningBorderDark : AppColors.warningBorder;
  Color get successSurface => isDark ? AppColors.successSurfaceDark : AppColors.successSurface;
  Color get selectedSurface => isDark ? AppColors.selectedSurfaceDark : AppColors.selectedSurface;
  Color get accentSurface => isDark ? AppColors.accentSurfaceDark : AppColors.accentSurface;
  Color get questionSurface => isDark ? AppColors.questionSurfaceDark : AppColors.questionSurface;
  Color get questionBorder => isDark ? AppColors.questionBorderDark : AppColors.questionBorder;

  @override
  bool updateShouldNotify(ThemeScope oldWidget) => oldWidget.isDark != isDark;
}

/// 便捷访问器：`context.c.textPrimary`。
///
/// 没有 ThemeScope 时回落浅色 —— widget 测试单独 pump 一个 widget 时不会因为
/// 缺少祖先而抛异常，而是拿到与生产环境亮色一致的取值。
extension ThemeContext on BuildContext {
  ThemeScope get c => ThemeScope.of(this);
}