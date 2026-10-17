import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// 一轮在导航刻度上的锚点。
///
/// [turn] 是**从 1 开始的轮号**（与电脑端 `第 {turn} 轮` 同一口径：只数真人回话，
/// 注入通知与上下文块不算一轮）。[messageId] 用于跳转时精确滚动/高亮。
class TurnMark {
  final int turn;
  final String messageId;

  const TurnMark({required this.turn, required this.messageId});

  // TODO(turn-preview): 长按弹层的"首 12 字摘要"需要父级在构造 [TurnMark] 时多传
  // 一个 `preview` 字段（从该轮第一条真人消息的正文截取）。本组件拿到的数据里
  // **没有正文**，也不打算为了摘要去读 DshService —— 它是纯展示组件（见类注释
  // 第 3 条）。父级补上字段后，把 [_TurnPickerSheet] 里那句占位换成 `mark.preview`
  // 即可，其余不用改。
}

/// 会话**左边缘**的轮次导航刻度（电脑端同款，v1.26.0；v1.27 换到左侧）。
///
/// 电脑端在消息流边缘有一列短刻度：一轮一格，当前所在的一轮更深更长，点某格
/// 直接跳到那一轮。手机上以前只能靠滑 —— 十轮的会话要滑好几屏才能回到某一轮，
/// 而"我要看第 3 轮那个结论"是很常见的动作。
///
/// 五条设计约束：
///
/// 1. **只认真人回话**。刻度格数 = 真人回合数，与状态条的 `N 轮` 同一口径；把注入
///    通知也算一格会让"第 6 轮"在两个地方指不同的东西。
/// 2. **它是一层浮层，不占布局**。挂在消息列表的 `Stack` 上（挂载处见
///    `message_list_view.dart` 的 `overlay`），所以既不会挤窄气泡，也不会随列表
///    滚动 —— 列表本身是懒构建的，刻度的位置**不能**由 item 偏移推导。
/// 3. **参数里没有 DshService**。跳转怎么实现由 `ChatView` 决定（它握着 GlobalKey
///    与滚动控制器）；这里只负责"第几轮被点了"。
/// 4. **在左边缘**（v1.27）。右侧原本与 Android 返回手势、"回到最新"浮钮的热区
///    重叠：右手一划就从会话里退出去，或者误触浮钮跳到底。左侧既避开这两者，
///    左手持机时也顺手。
/// 5. **不再压紧**。旧版超过 14 轮把格间距从 5 收到 2，结果是"越长的会话越点不中"，
///    而那恰好是最需要刻度的会话。现在间距恒为 5，超过 10 轮整体放进一个占屏高
///    40% 的内部滚动列 —— 拉得再长也不糊成一团。
class TurnNavigationRail extends StatelessWidget {
  const TurnNavigationRail({
    super.key,
    required this.marks,
    this.currentTurn,
    required this.onSelect,
    this.onLongPress,
  });

  /// 已加载的轮次锚点（按消息顺序）。
  final List<TurnMark> marks;

  /// 当前可见的是第几轮（1 起）；null = 还没算出来，此时不高亮任何一格。
  final int? currentTurn;

  /// 点第 [TurnMark.turn] 轮。
  final ValueChanged<int> onSelect;

  /// 长按整条刻度时回调。为 null 时退化成组件自己弹轮次选择弹层（默认行为）。
  ///
  /// 留这个口子是为了让宿主能在长按里做它才知道的事（例如带轨迹摘要的选择器）。
  final VoidCallback? onLongPress;

  /// 单格间隔，**固定**（不再按轮数压紧）。
  static const double _gap = 5;

  /// 超过这个轮数就整体放进内部滚动列。
  static const int _scrollFrom = 10;

  /// 内部滚动列的高度上限（占屏高比例）。
  static const double _scrollHeightFraction = 0.4;

  @override
  Widget build(BuildContext context) {
    if (marks.isEmpty) return const SizedBox.shrink();

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final mark in marks)
          Tooltip(
            message: '跳到第 ${mark.turn} 轮',
            waitDuration: const Duration(milliseconds: 400),
            // ⚠️ 必须 manual：Tooltip 在移动端**默认长按触发**，它内部的识别器
            // 比外面那个 GestureDetector 更靠里、会先赢走长按 —— 结果就是
            // "长按刻度只弹出一句 tooltip，轮次选择弹层永远打不开"（实测）。
            // 长按在整条 rail 上的语义归轮次选择器所有，tooltip 只在悬停时出现。
            triggerMode: TooltipTriggerMode.manual,
            child: InkWell(
              key: ValueKey('turn-nav-${mark.turn}'),
              onTap: () => onSelect(mark.turn),
              borderRadius: BorderRadius.circular(3),
              // 点击热区比刻度本身大：3dp 高的细线直接点很费劲，而"点不中"
              // 在用户看来就是"这功能没反应"。横向 20 是还看得见、又不至于
              // 骑到气泡文字上的宽度。
              child: SizedBox(
                width: 20,
                height: 3 + _gap,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    // 当前轮 17×3 细条，其余 6×3 圆点：形状差就是"我在哪一轮"
                    // 的一眼可读化，比只换颜色更容易在余光里分辨。
                    width: mark.turn == currentTurn ? 17 : 6,
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
          ),
      ],
    );

    return Center(
      child: GestureDetector(
        // 长按整条刻度 = 轮次选择弹层：几十轮的会话里，靠"点第 N 格"往下找
        // 比滑动还慢；一个 grid 能一眼看全。
        //
        // 单格的 InkWell 只有 tap，长按会冒泡到这里 —— 两者不冲突。
        onLongPress: onLongPress ?? () => _openTurnPicker(context),
        child: Container(
          key: const ValueKey('turn-nav-rail'),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
          decoration: BoxDecoration(
            // 半透明底：刻度要能被看见，但不能盖住气泡里的字。
            color: context.c.surface.withOpacity(0.82),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: context.c.border.withOpacity(0.6)),
          ),
          child: marks.length > _scrollFrom
              ? ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height *
                        _scrollHeightFraction,
                  ),
                  child: SingleChildScrollView(child: column),
                )
              : column,
        ),
      ),
    );
  }

  Future<void> _openTurnPicker(BuildContext context) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _TurnPickerSheet(
        marks: marks,
        currentTurn: currentTurn,
      ),
    );
    if (picked != null) onSelect(picked);
  }
}

/// 长按刻度弹出的轮次选择弹层。
///
/// 摘要一行目前是**禁用态占位**：组件只拿到 `TurnMark(turn, messageId)`，没有
/// 正文，见 [TurnMark] 上的 TODO。
class _TurnPickerSheet extends StatelessWidget {
  const _TurnPickerSheet({required this.marks, required this.currentTurn});

  final List<TurnMark> marks;
  final int? currentTurn;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '跳到某一轮',
                    style: TextStyle(
                      fontSize: AppText.heading,
                      fontWeight: FontWeight.bold,
                      color: context.c.textPrimary,
                    ),
                  ),
                ),
                Text(
                  '共 ${marks.length} 轮',
                  style: TextStyle(
                      fontSize: AppText.caption, color: context.c.textTertiary),
                ),
              ],
            ),
          ),
          Flexible(
            child: GridView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: AppSpace.m,
                crossAxisSpacing: AppSpace.m,
                childAspectRatio: 2.1,
              ),
              itemCount: marks.length,
              itemBuilder: (ctx, i) {
                final mark = marks[i];
                final active = mark.turn == currentTurn;
                return InkWell(
                  key: ValueKey('turn-picker-${mark.turn}'),
                  borderRadius: BorderRadius.circular(9),
                  onTap: () => Navigator.of(ctx).pop(mark.turn),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: active
                          ? context.c.accentSurface
                          : context.c.surfaceMuted,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: active
                            ? context.c.accent.withOpacity(0.6)
                            : context.c.border,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '第 ${mark.turn} 轮',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppText.body,
                            fontWeight:
                                active ? FontWeight.w700 : FontWeight.w600,
                            color: active
                                ? context.c.accent
                                : context.c.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        // 摘要占位：明确的禁用态，而不是编一句假摘要。父级补上
                        // `TurnMark.preview` 之后换成正文首 12 字。
                        Text(
                          '摘要待接入',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: AppText.caption,
                              color: context.c.textTertiary),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
