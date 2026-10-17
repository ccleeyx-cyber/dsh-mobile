import 'package:flutter/material.dart';

/// 语义色 token 层（v1.6.0 深色模式的地基）。
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
/// - 品牌蓝（按钮、选中态）→ `accent`
/// - 用户消息气泡 → `userBubble`；AI 气泡 → `aiBubble`（透明，裸排版）
/// - 危险红 → `danger`
/// - 成功绿 → `success`；命令输出成功 → `terminalGreen`
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
  //
  // 旧值 #0078D4 是 Flutter/Windows 的默认蓝，本身不丑，但它在整整一代 Windows
  // 应用里出现过，用户看到它不会觉得这是「这个产品的颜色」，只觉得自己还在系统
  // 设置页里。现在换成偏紫的 #3F5AF0：与正文的中性灰拉开色相距离，也让选中态
  // 不再和系统 UI 撞色。
  //
  // 深色侧 #6E8BFF 是同一色相提亮，而不是简单取反 —— 取反得到的是低饱和的暗蓝，
  // 那会让所有按钮在深色下看起来都是禁用态。
  //
  // 实测对比度（WCAG 公式自测，改色前必须重算）：
  // - accent(#3F5AF0) 对白底 5.34:1、对页面底 #F1F5F9 4.88:1 —— 白字压在 accent
  //   上同样是 5.34:1，正文级 AA(4.5:1) 达标，用户气泡/实心按钮可以放心用正文号；
  // - accentDark(#6E8BFF) 对页面底 #0D1117 6.13:1、对卡片面 #161B22 5.60:1。
  //
  // 之所以是 #3F5AF0 而不是更亮的 #4C6FFF：后者白字只有 4.18:1，卡在正文 AA 线上
  // 下。#4C6FFF 的穿透感更好，但用户气泡里是 13.5~14.5pt 的正常字重正文，不是大字，
  // 拿不到 3:1 的大字豁免。token 层的责任是先把可访问性做对 —— 观感问题应该在
  // 排版层（字号、字重、留白）解决，而不是靠把底色调亮换来的假对比。
  static const Color accent = Color(0xFF3F5AF0);
  static const Color accentDark = Color(0xFF6E8BFF);

  /// 用户消息气泡底。
  ///
  /// [fix 2026-10-17] 之前直接复用 `accent`（实心蓝）。问题不是好看不好看，而是
  /// **选中文字看不见**：Flutter 的选区高亮是 accent 的半透明叠色，压在实心 accent
  /// 底上几乎看不出变化 —— 用户长按选中一句话，屏幕上像没反应，只能靠"复制"
  /// 按钮亮起来猜自己选中了没有（用户实测反馈）。
  ///
  /// 现在改成 accent 的**浅色 tint** + 深色正文：选区高亮压在浅底上对比明显，
  /// 气泡仍有品牌感，与"裸排版的 AI 正文"也依然一眼可分。
  static const Color userBubble = Color(0xFFE3EAFE);
  static const Color userBubbleDark = Color(0xFF1E2B4D);

  /// AI 消息气泡底。透明 —— AI 正文裸排在页面底上，不再套卡片（Phase 2.1）。
  ///
  /// 之所以仍然留这个 token 而不是让调用方不设背景：消息流的两种气泡必须共用
  /// 同一段布局代码，用「透明色」比用「null 背景」少一个分支，也不会让深色模式
  /// 在气泡这一层出现结构差异。
  static const Color aiBubble = Colors.transparent;
  static const Color aiBubbleDark = Colors.transparent;

  // ---- 中性：文字 ----
  /// 主要文字（正文、标题）。
  static const Color textPrimary = Color(0xFF111827);
  static const Color textPrimaryDark = Color(0xFFE5E7EB);

  /// 次要文字（说明、标签）。
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color textSecondaryDark = Color(0xFF9CA3AF);

  /// 最低对比度文字（时间戳、占位符、禁用态）。
  ///
  /// 这三档此前是「按视觉轻重分级」而非「按对比度分级」：#9CA3AF 在白底只有约
  /// 2.8:1，#6B7280 在 #111827 深底约 3.9:1，两者都低于 WCAG AA 对正文的 4.5:1。
  /// 而这一档恰好用在时间戳、工具卡副文案、输入框占位符上 —— 正是视力最弱的用户
  /// 最需要看清的位置。现已改为满足 AA：浅底 #4B5563(7.5:1)、深底 #9CA3AF(7.0:1)。
  static const Color textTertiary = Color(0xFF4B5563);
  static const Color textTertiaryDark = Color(0xFF9CA3AF);

  // ---- 中性：面 ----
  //
  // 三级明度模型：**页面底最暗 → 浮层（surface）→ 内嵌区（surfaceMuted）逐级变亮**。
  // 浅色与深色守着同一条规则，只是绝对值相反 —— 浅色从灰白往上走到纯白，深色从
  // 近黑往上走到炭灰。这样「层级越高越亮」在两种主题里是同一句话，不需要每个
  // widget 自己判断深浅。
  //
  // 旧取值有两个具体问题：
  //
  // 1. 浅色三档太挤。#F8FAFC(页面底) / #F9FAFB(内嵌) / #FFFFFF(卡片) 之间只差 6~7
  //    个通道值，肉眼分辨不出层级，于是所有分层都要靠 1px 边框去说 —— 结果是满屏
  //    都是框。现在把页面底压到 #F1F5F9（与卡片每通道差 14，约 5.5%），边框变成
  //    补充说明而不是唯一的分层手段。
  // 2. 深色里同一个 token 的相对层级幅度和浅色对不上。旧的 surfaceMuted #374151
  //    相对 surface #1F2937 亮了整整两档（+24 每通道），而浅色下 surfaceMuted
  //    相对 surface 只暗一档。同一个语义在两种主题里差了两个量级，导致「内嵌区」
  //    在深色下看起来像「浮起的选中卡片」。新取值把幅度对齐成对称的一档：
  //    浅色压一档（#FFFFFF → #F8FAFC），深色抬一档（#161B22 → #21262D）。
  //
  // 深色边框从 #4B5563 压到 #30363D：旧值相对 #1F2937 的面对比过强，看上去像
  // 发光的白色描边，深色下最刺眼的往往不是文字而是这些线。

  /// 页面底色（最低一层）。
  static const Color background = Color(0xFFF1F5F9);
  static const Color backgroundDark = Color(0xFF0D1117);

  /// 卡片/输入框底色（第二层）。
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceDark = Color(0xFF161B22);

  /// 次级面（内嵌区域、hover、工具输出的外层）。
  static const Color surfaceMuted = Color(0xFFF8FAFC);
  static const Color surfaceMutedDark = Color(0xFF21262D);

  /// 描边 / 分隔线。
  static const Color border = Color(0xFFE2E8F0);
  static const Color borderDark = Color(0xFF30363D);

  /// 代码块 / 终端输出底色。
  ///
  /// 刻意不直接复用 [surfaceMuted]：内嵌区可能同时既是 surfaceMuted（浮层内的
  /// 区块）又要放一段代码，两者共用一个值时就分不出边界了。现在浅色取页面底色
  /// （代码块看起来是「挖进卡片里的洞」），深色取最暗的页面底色（同理）。它比
  /// surfaceMuted 更深一档，等宽字在上面也更容易读。
  static const Color codeBackground = Color(0xFFF1F5F9);
  static const Color codeBackgroundDark = Color(0xFF0D1117);

  // ---- 状态 ----
  static const Color danger = Color(0xFFDC2626);
  static const Color dangerDark = Color(0xFFF87171);

  static const Color success = Color(0xFF10B981);
  static const Color successDark = Color(0xFF34D399);

  /// 命令/工具执行成功的绿色（终端语义）。
  ///
  /// 与 [success] 分开是因为两者出现的位置反差很大：[success] 用在徽章、状态点
  /// 这类小色块上，可以偏青、偏亮；terminalGreen 用于等宽正文里的整行回显。
  ///
  /// 统一按**正文 AA** 取值，状态圆点复用同一个色而不是再开一档浅绿：同一个语义
  /// 在界面里出现两种绿，用户看到圆点和文字颜色不一致时只会怀疑哪个才是"成功"。
  /// 一个绿同时满足圆点（门槛 3:1）和 11.5pt 回显正文（门槛 4.5:1），就没有取舍
  /// 要讲 —— 事实上更深的那档反而更适合整屏终端输出，亮绿在大面积上会发飘。
  ///
  /// 实测对比度：浅色 #15803D 对页面底 #F1F5F9 4.58:1、对白底 5.02:1；
  /// 深色 #4ADE80 对 #0D1117 10.9:1、对卡片面 #161B22 9.9:1。两条主题都过 AA。
  static const Color terminalGreen = Color(0xFF15803D);
  static const Color terminalGreenDark = Color(0xFF4ADE80);

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
  ///
  /// **取值以页面底 `background` 为基准校对比，不是以卡片白面为基准** —— 选中行
  /// 大多数时候直接落在页面底上（工作区列表、会话列表），拿白色卡片去校会得出
  /// "看起来还行"的结论，实际在 #F1F5F9 上几乎看不出选中。
  ///
  /// 旧值 #EFF6FC 是照着旧的浅页面底 #F8FAFC 调的；页面底压到 #F1F5F9 之后两者
  /// 相对亮度几乎相等（1.005:1），选中态等于消失了。现值 #E3EDF9 对页面底
  /// 1.08:1、对白卡片 1.18:1。深色侧 #14263F 对 #0D1117 1.24:1、对 #161B22 1.14:1
  /// （旧 #10243A 在卡片上只有 1.10:1，偏弱）。
  static const Color selectedSurface = Color(0xFFE3EDF9);
  static const Color selectedSurfaceDark = Color(0xFF14263F);

  /// 品牌浅蓝底（输入框 hover、强调区块）。
  ///
  /// 同样**以页面底 `background` 为基准校对比**，理由见 [selectedSurface]。
  ///
  /// 与 [selectedSurface] 的区别只在色相强弱：这个更接近品牌蓝（用于 hover、引导
  /// 区块），那个更中性（用于"当前项"）。现值 #E8F0FE 对页面底 1.05:1、对白卡片
  /// 1.15:1；深色侧 #12233A 对 #0D1117 1.20:1、对 #161B22 1.09:1。深色侧刻意取
  /// 比 [selectedSurfaceDark] 低一档的对比（1.20 对 1.24），hover 与选中才区分得开。
  static const Color accentSurface = Color(0xFFE8F0FE);
  static const Color accentSurfaceDark = Color(0xFF12233A);

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
