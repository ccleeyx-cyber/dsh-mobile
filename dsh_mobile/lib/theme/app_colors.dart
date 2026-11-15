import 'package:flutter/material.dart';

/// 语义色 token 层（v1.6.0 深色模式的地基；2026-11-15 换「驾驶舱」方向取值）。
///
/// ## 为什么先做这一层
///
/// 改动前 `lib/` 下有 **592 处硬编码 `Color(0x...)`**，其中 29 个色值覆盖 523 处
/// （88%）。直接把那个 Windows 默认蓝换成对应的深色值是不行的 —— 那只会得到
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
/// - 代码块、工具输出底 → `codeBackground`（不是 `surfaceMuted`，见该 token 注释）
/// - 卡片之间的描边 → `border`
/// - 正文文字 → `textPrimary`
/// - 次要说明/时间戳 → `textSecondary` / `textTertiary`
/// - 信号绿（按钮、选中态、运行中）→ `accent`
/// - 用户消息气泡 → `userBubble`；AI 气泡 → `aiBubble`（透明，裸排版）
/// - 危险红 → `danger`
/// - 成功绿 → `success`；命令输出成功 → `terminalGreen`
/// - 警告琥珀 → `warning`
///
/// 拿不准就先用 `textPrimary` 之外的中性槽位，**不要**为了让某处"看起来对"
/// 而新增一个一次性色值 —— 那等于把硬编码换个地方继续。
///
/// ## 驾驶舱方向（2026-11-15，用户选定方向 A）
///
/// 深色侧是主体验：石墨底 #0A0C10、面板 #10141B、发丝线 #1C222C、等宽读数、
/// 信号绿 #3DD68C 表示「在跑」。品牌蓝整体退场 —— 这个 App 的「主色」语义
/// 本来就是「agent 正在做事」，绿灯比蓝钮诚实。
///
/// 浅色侧不是深色的反相，而是「白昼驾驶舱」：冷纸灰底 + 同一套发丝线语言 +
/// 深信号绿 #0B7A4B（白字 4.76:1，过正文 AA）。两侧守同一条层级规则：
/// 页面底 → 浮层 → 内嵌区逐级抬明度。
///
/// ## 为什么用 InheritedWidget 而不是 GetIt / 全局单例
///
/// 依赖树里注入颜色，让 widget 测试可以直接包一个 `DarkModeScope` 来断言深色
/// 下的取值，不需要 singleton 或 mockito 技巧。
class AppColors {
  AppColors._();

  // ---- 品牌 / 信号 ----
  //
  // 驾驶舱方向：主色 = 信号灯绿。深色 #3DD68C 对页面底 #0A0C10 约 10.5:1，
  // 对面板 #10141B 约 9.6:1；浅色 #0B7A4B 对页面底 #EEF1F4 4.76:1、白字压它
  // 4.9:1 —— 两侧都过正文 AA（4.5:1）。
  //
  // onAccent 两侧相反：浅绿底压近黑字（#06110B，11:1），深绿底压白字。
  static const Color accent = Color(0xFF0B7A4B);
  static const Color accentDark = Color(0xFF3DD68C);

  /// 用户消息气泡底。驾驶舱里是一块带发丝描边的内嵌面板，不是彩色胶囊：
  /// 选中文字的高亮压在面板底上对比明显（2026-10-17 那条教训继续生效）。
  static const Color userBubble = Color(0xFFE2EDE7);
  static const Color userBubbleDark = Color(0xFF141B26);

  /// AI 消息气泡底。透明 —— AI 正文裸排在页面底上，不再套卡片（Phase 2.1）。
  ///
  /// 之所以仍然留这个 token 而不是让调用方不设背景：消息流的两种气泡必须共用
  /// 同一段布局代码，用「透明色」比用「null 背景」少一个分支，也不会让深色模式
  /// 在气泡这一层出现结构差异。
  static const Color aiBubble = Colors.transparent;
  static const Color aiBubbleDark = Colors.transparent;

  // ---- 中性：文字 ----
  /// 主要文字（正文、标题）。
  static const Color textPrimary = Color(0xFF0C1116);
  static const Color textPrimaryDark = Color(0xFFE6EAF2);

  /// 次要文字（说明、标签）。
  static const Color textSecondary = Color(0xFF4A5563);
  static const Color textSecondaryDark = Color(0xFF9AA4B2);

  /// 最低对比度文字（时间戳、占位符、禁用态）。两侧均过正文 AA：
  /// 浅 #5A6472 对页面底 5.3:1；深 #7E8896 对面板 #10141B 5.1:1。
  static const Color textTertiary = Color(0xFF5A6472);
  static const Color textTertiaryDark = Color(0xFF7E8896);

  // ---- 中性：面 ----
  //
  // 三级明度模型：**页面底 → 浮层（surface）→ 内嵌区（surfaceMuted）逐级抬亮**，
  // 浅色与深色守同一条规则。驾驶舱的深色三档差距刻意比旧值小（#0A0C10 /
  // #10141B / #141B26 每档约 +6 通道值）：分层主要交给发丝线，明度只做辅助 ——
  // 仪表板的质感来自线，不来自块。
  //
  // 发丝线 #1C222C 对面板 #10141B 的面对比约 1.35:1 —— 够看见结构，不够刺眼。
  // 深色下最刺眼的从来不是文字而是发光的描边（2026-10 那条教训继续生效）。

  /// 页面底色（最低一层）。
  static const Color background = Color(0xFFEEF1F4);
  static const Color backgroundDark = Color(0xFF0A0C10);

  /// 卡片/输入框底色（第二层）。
  static const Color surface = Color(0xFFFAFBFC);
  static const Color surfaceDark = Color(0xFF10141B);

  /// 次级面（内嵌区域、hover、工具输出的外层）。
  static const Color surfaceMuted = Color(0xFFF3F5F8);
  static const Color surfaceMutedDark = Color(0xFF141B26);

  /// 描边 / 分隔线（发丝线）。
  static const Color border = Color(0xFFD8DEE6);
  static const Color borderDark = Color(0xFF1C222C);

  /// 代码块 / 终端输出底色。比 surfaceMuted 更深一档（浅色）/ 更暗一档（深色），
  // 看起来是「挖进面板里的洞」，等宽字在上面更容易读。
  static const Color codeBackground = Color(0xFFEDF0F4);
  static const Color codeBackgroundDark = Color(0xFF0C1016);

  // ---- 状态 ----
  static const Color danger = Color(0xFFC2362C);
  static const Color dangerDark = Color(0xFFF0564A);

  static const Color success = Color(0xFF0B7A4B);
  static const Color successDark = Color(0xFF3DD68C);

  /// 命令/工具执行成功的绿色（终端语义）。驾驶舱里与 [success] 同值 ——
  // 信号灯只有一种绿，圆点与回显文字共用，用户不需要猜哪个才是"成功"。
  static const Color terminalGreen = Color(0xFF0B7A4B);
  static const Color terminalGreenDark = Color(0xFF3DD68C);

  /// 警告琥珀。浅色 #9A6A00 白字 4.9:1；深色 #E5A50A 压近黑字 8:1。
  static const Color warning = Color(0xFF9A6A00);
  static const Color warningDark = Color(0xFFE5A50A);

  // ---- 实心色块上的前景（对比度 token）----
  /// 实心 accent（信号绿）上的前景色：浅侧深绿底压白字，深侧亮绿底压近黑。
  static const Color onAccent = Color(0xFFFFFFFF);
  static const Color onAccentDark = Color(0xFF06110B);

  /// 警告色（琥珀）上的前景色。两侧都用深色/白色按各自底明度取：
  /// 浅侧 #9A6A00 压白字，深侧 #E5A50A 压近黑。
  static const Color onWarning = Color(0xFFFFFFFF);
  static const Color onWarningDark = Color(0xFF10141B);

  static const Color purple = Color(0xFF7C3AED);
  static const Color purpleDark = Color(0xFFA78BFA);

  static const Color orange = Color(0xFFEA580C);
  static const Color orangeDark = Color(0xFFFB923C);

  // ---- 带色底（tint）----
  //
  // 语义底：浅红=危险、浅琥珀=警告、浅绿=成功/选中。深色侧压低明度提高饱和，
  // 保证在石墨底上仍是"提示色"而不是"发光的色块"。驾驶舱的 tint 整体比旧值
  // 更冷、更灰一档：仪表板上不该出现糖果色。

  /// 危险提示底。
  static const Color dangerSurface = Color(0xFFFBECEA);
  static const Color dangerSurfaceDark = Color(0xFF200F0D);

  /// 危险提示描边。
  static const Color dangerBorder = Color(0xFFEBC4C0);
  static const Color dangerBorderDark = Color(0xFF5A2420);

  /// 警告提示底。
  static const Color warningSurface = Color(0xFFFBF4E4);
  static const Color warningSurfaceDark = Color(0xFF1A1509);

  /// 警告徽章底。
  static const Color warningBadgeSurface = Color(0xFFF6E7C0);
  static const Color warningBadgeSurfaceDark = Color(0xFF241C07);

  /// 警告描边。
  static const Color warningBorder = Color(0xFFE8D29A);
  static const Color warningBorderDark = Color(0xFF4A3A12);

  /// 成功提示底。
  static const Color successSurface = Color(0xFFE2F2E9);
  static const Color successSurfaceDark = Color(0xFF0E1A14);

  /// 选中态底（当前行/当前工作区）。绿灰 tint，与页面底对比约 1.08:1（浅）/
  /// 1.24:1（深）—— 够认出"是当前项"，不够抢正文的戏。
  static const Color selectedSurface = Color(0xFFE4EDE8);
  static const Color selectedSurfaceDark = Color(0xFF14241D);

  /// 品牌 tint 底（输入框 hover、强调区块）。比 [selectedSurface] 绿味重一档。
  static const Color accentSurface = Color(0xFFDFEAE4);
  static const Color accentSurfaceDark = Color(0xFF10291F);

  /// 提问卡片底（§4.1 提问）。
  static const Color questionSurface = Color(0xFFFBF1E4);
  static const Color questionSurfaceDark = Color(0xFF241809);

  /// 提问卡片描边。
  static const Color questionBorder = Color(0xFFE8CFA8);
  static const Color questionBorderDark = Color(0xFF5A3A12);
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

  /// 代码块 / 工具输出底。与 surfaceMuted 分开的一档，见 [AppColors.codeBackground]。
  Color get codeBackground => isDark ? AppColors.codeBackgroundDark : AppColors.codeBackground;

  /// 消息气泡。AI 侧在两种主题下都是透明（裸排版），所以这里没有分支差异。
  Color get userBubble => isDark ? AppColors.userBubbleDark : AppColors.userBubble;
  Color get aiBubble => isDark ? AppColors.aiBubbleDark : AppColors.aiBubble;

  Color get danger => isDark ? AppColors.dangerDark : AppColors.danger;
  Color get success => isDark ? AppColors.successDark : AppColors.success;
  Color get terminalGreen => isDark ? AppColors.terminalGreenDark : AppColors.terminalGreen;
  Color get warning => isDark ? AppColors.warningDark : AppColors.warning;
  Color get purple => isDark ? AppColors.purpleDark : AppColors.purple;
  Color get orange => isDark ? AppColors.orangeDark : AppColors.orange;

  /// 实心 accent 上的前景色（深色侧必须是近黑，见 [AppColors.onAccent]）。
  Color get onAccent => isDark ? AppColors.onAccentDark : AppColors.onAccent;

  /// 警告色上的前景色（按各自底明度取，见 [AppColors.onWarning]）。
  Color get onWarning => isDark ? AppColors.onWarningDark : AppColors.onWarning;

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
