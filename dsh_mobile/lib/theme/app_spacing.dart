import 'package:flutter/material.dart';

/// 字号与间距 token 层。
///
/// ## 为什么需要这一层
///
/// [AppColors] 把 592 处硬编码色值收敛成语义槽位之后，`lib/` 里剩下的**第二类**
/// 魔法数字是字号与间距：`fontSize` 有 16 个离散取值（9.5 / 10 / 10.5 / 11 / 11.5
/// / 12 / 12.5 / 13 / 13.5 / 14 / 14.5 / 15 / 16 / 16.5 / 17 / 18），间距有 17 个
/// 离散取值（1 / 2 / 3 / 4 / 5 / 6 / 7 / 8 / 9 / 10 / 12 / 14 / 16 / 18 / 20 / 24）。
///
/// 这不只是好不好看的问题，它是**可访问性的硬约束**。Flutter 的
/// `MediaQuery.textScaler` 会跟随系统字体设置放大，而全局**没有任何一处**处理过
/// 它：深色模式切换走的是真 ThemeData（所以能工作），字号则完全交给系统默认值。
/// 系统字号放到 1.3x 时，9.5pt 的时间戳、11pt 的工具卡副文案、12pt 的状态条会在
/// 固定高度的 Row 里溢出 —— 用户看到的不是「大一点的字」，而是错位的控件。
///
/// ## 怎么用
///
/// 按**角色**取值，不按数字大小猜：
///
/// - `AppText.caption` —— 时间戳、角标计数、辅助说明（可被系统放大）
/// - `AppText.subhead` —— 等宽代码/终端输出的正文（工具调用输入输出、代码块）
/// - `AppText.body`    —— 正文、选项、次要文案
/// - `AppText.title`   —— 卡片标题、分区标题
/// - `AppText.heading` —— 设置页分区头、sheet 标题行
/// - `AppText.display` —— 空态大标题（罕见）
///
/// 间距同理：`AppSpace.xs`（2）/ `s`（4）/ `m`（8）/ `l`（12）/ `xl`（16）。
/// 不是每个 1、3、5 都有对应 token —— 那些在视觉上不构成可辨识的节奏，硬套只会
/// 让 token 表失去意义。少数仍用字面量的地方应当是刻意的，且值得一行注释。
class AppText {
  AppText._();

  // ---- 字号 ----
  /// 10.5 —— 角标计数、时间戳前缀。最小的可读正文下限。
  static const double caption = 10.5;

  /// 11.5 —— 等宽正文（工具调用的输入/输出、代码块、终端回显）。
  ///
  /// 它不能直接复用 [body]：等宽字每个字符都占满字宽，同样 12.5 号的代码行比
  /// 比例字宽出约 8%，360dp 宽屏上会提前折行、把缩进结构打散。11.5 是"等宽下
  /// 与 12.5 正文视觉重量相当"的那一档。
  static const double subhead = 11.5;

  /// 12.5 —— 辅助说明、状态条、选项副文案。
  static const double body = 12.5;

  /// 13.5 —— 正文、卡片标题。
  static const double title = 13.5;

  /// 15 —— 分区标题（设置页分组头、sheet 标题行、列表组标题）。
  ///
  /// 比 [title] 高一档，但刻意不到 16：16 以上在 5 寸屏的密集列表里会把内容挤掉
  /// 一屏，而分区标题并不比正文更重要。
  static const double heading = 15;

  /// 18 —— 空态大标题。刻意保留在 16/18 两档：超过 18pt 在 5 寸屏上会挤掉内容。
  static const double display = 18;
}

/// 间距 token。
///
/// 命名沿用界面对 CSS 的习惯：xs < s < m < l < xl。
class AppSpace {
  AppSpace._();

  /// 2 —— 紧贴元素之间。
  static const double xs = 2;

  /// 4 —— 图标与文字、同组元素之间。
  static const double s = 4;

  /// 8 —— 控件之间、卡片内边距的常用档。
  static const double m = 8;

  /// 12 —— 卡片与卡片之间。
  static const double l = 12;

  /// 16 —— 区块之间。
  static const double xl = 16;
}

/// 最小可点区域包装器（44×44dp）。
///
/// [add 2026-10-20] 审计发现一批自绘可点区域（裸 `Icon` + `GestureDetector`）
/// 命中区只有 13~20dp：工作区路径的复制图标 13dp、错误横幅的关闭图标 16dp、
/// 代码查看器的复制 21dp。视觉尺寸**不该**变大（它们在密集行里本来就该小），
/// 缺的只是能被手指点中的面积。
///
/// 用法：`MinimumTouchTarget(onTap: ..., child: Icon(Icons.copy, size: 13))`。
/// 视觉不变，命中区扩到 44×44（Android 无障碍基线 48dp 的务实取值 —— 48 在
/// 这些密集行里会把行高顶起来）。
///
/// 注意：它会把**布局盒**撑到 44，所以只能放在 Row/Column 里有余量的位置；
/// 若父级高度被写死且小于 44，请改用带 padding 的扩容而不是本组件。
class MinimumTouchTarget extends StatelessWidget {
  final Widget child;
  final double size;
  final VoidCallback? onTap;

  /// 语义标签。给了就走 `Semantics(button: true)`，读屏能念出这是干什么的。
  final String? semanticLabel;

  const MinimumTouchTarget({
    super.key,
    required this.child,
    this.size = 44,
    this.onTap,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    Widget tappable = SizedBox(
      width: size,
      height: size,
      child: Center(child: child),
    );
    if (onTap != null) {
      tappable = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: tappable,
      );
    }
    if (semanticLabel != null) {
      tappable = Semantics(
        button: onTap != null,
        label: semanticLabel,
        child: tappable,
      );
    }
    return tappable;
  }
}

/// 系统字号的可控放大区间。
///
/// Flutter 默认跟随系统字号无上限。1.0~1.3 之间是可用的：更大的取值会让大量固定
/// 高度的行（审批卡的按钮 Row、状态条、单行折叠卡）直接溢出，而那些地方无法逐个
/// 重排。钳位不是无视可访问性 —— 1.3x 已经覆盖了绝大多数低视力用户需要的放大倍率，
/// 真正需要更大倍率的场景下更好的做法是改布局，而不是让文字互相压住。
class AppTextScale {
  AppTextScale._();

  static const double min = 1.0;
  static const double max = 1.3;
  static const double normal = 1.0;

  /// 把系统提供的 [scaler] 钳进 [min]~[max]。
  static TextScaler clamp(TextScaler scaler) {
    return scaler.clamp(minScaleFactor: min, maxScaleFactor: max);
  }

  /// 从 context 读取并钳位后的 scaler。
  static TextScaler of(BuildContext context) {
    return clamp(MediaQuery.textScalerOf(context));
  }
}
