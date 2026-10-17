import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// 一轮在导航刻度上的锚点。
///
/// [turn] 是**从 1 开始的轮号**（与电脑端 `第 {turn} 轮` 同一口径：只数真人回话，
/// 注入通知与上下文块不算一轮）。[messageId] 用于跳转时精确滚动/高亮。
class TurnMark {
  final int turn;
  final String messageId;

  const TurnMark({required this.turn, required this.messageId});
}

/// 会话右侧的**轮次导航刻度**（电脑端同款，v1.26.0）。
///
/// 电脑端在消息流右边缘有一列短刻度：一轮一格，当前所在的一轮更深更长，点某格
/// 直接跳到那一轮。手机上以前只能靠滑 —— 十轮的会话要滑好几屏才能回到某一轮，
/// 而"我要看第 3 轮那个结论"是很常见的动作。
///
/// 三条设计约束：
///
/// 1. **只认真人回话**。刻度格数 = 真人回合数，与状态条的 `N 轮` 同一口径；把注入
///    通知也算一格会让"第 6 轮"在两个地方指不同的东西。
/// 2. **它是一层浮层，不占布局**。挂在消息列表的 `Stack` 上、右边缘 4dp，所以既不会
///    挤窄气泡，也不会随列表滚动 —— 列表本身是懒构建的，刻度的位置**不能**由 item
///    偏移推导。
/// 3. **参数里没有 DshService**。跳转怎么实现由 `ChatView` 决定（它握着 GlobalKey
///    与滚动控制器）；这里只负责"第几轮被点了"。
class TurnNavigationRail extends StatelessWidget {
  const TurnNavigationRail({
    super.key,
    required this.marks,
    this.currentTurn,
    required this.onSelect,
  });

  /// 已加载的轮次锚点（按消息顺序）。
  final List<TurnMark> marks;

  /// 当前可见的是第几轮（1 起）；null = 还没算出来，此时不高亮任何一格。
  final int? currentTurn;

  /// 点第 [TurnMark.turn] 轮。
  final ValueChanged<int> onSelect;

  /// 超过这个轮数就把刻度压紧（每格间距从 5 收到 2），否则十轮以上会顶到屏幕外。
  static const int _compactFrom = 14;

  @override
  Widget build(BuildContext context) {
    if (marks.isEmpty) return const SizedBox.shrink();

    final gap = marks.length > _compactFrom ? 2.0 : 5.0;

    return Center(
      child: Container(
        key: const ValueKey('turn-nav-rail'),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
        decoration: BoxDecoration(
          // 半透明底：刻度要能被看见，但不能盖住气泡里的字。
          color: context.c.surface.withOpacity(0.82),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: context.c.border.withOpacity(0.6)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mark in marks)
              Tooltip(
                message: '跳到第 ${mark.turn} 轮',
                waitDuration: const Duration(milliseconds: 400),
                child: InkWell(
                  key: ValueKey('turn-nav-${mark.turn}'),
                  onTap: () => onSelect(mark.turn),
                  borderRadius: BorderRadius.circular(2),
                  // 点击热区比刻度本身大：3dp 高的细线直接点很费劲，而"点不中"
                  // 在用户看来就是"这功能没反应"。
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: gap / 2 + 1),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      width: mark.turn == currentTurn ? 17 : 10,
                      height: 3,
                      decoration: BoxDecoration(
                        color: mark.turn == currentTurn
                            ? context.c.textPrimary
                            : context.c.textTertiary.withOpacity(0.45),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
