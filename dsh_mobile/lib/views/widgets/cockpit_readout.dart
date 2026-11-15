import 'package:flutter/material.dart';

import '../../models/task_center.dart';
import '../../theme/app_colors.dart';

/// 驾驶舱仪表簇（2026-11-15 方向 A 的签名件）。
///
/// 固定五格：轮 · 步 · tok/s · 累计消耗 · 产出。它与 2026-10-17 砍掉的
/// 「34dp 横滑数字带」是**相反的结构**：等宽网格、不横滑、不渐隐 —— 360dp 屏
/// 每格约 72dp，等宽数字放得下，也就没有"有一半读数被遮住"的问题。
/// 上下文占用不进这里：身份行第二行已经有它（含阈值换色），同一个读数
/// 不在 40dp 内出现两次。
///
/// 三条原则沿用旧带的遗产：
/// 1. **未知即破折号。** 读不到显示暗 `—`，绝不补 0 —— `0 轮 0 步` 会被读成
///    "这轮没干活"，而真相可能是网关没投影。
/// 2. **只读不操作。** 整条可点，目的地是会话信息面板的「用量」小节：仪表是
///    "瞥一眼"，面板是"翻明细"，两级口径各守各的。
/// 3. **信号色。** tok/s 列常驻信号绿 —— 它是整条上唯一"活着"的读数；
///    其余列用正文色，未知列压暗。
class CockpitReadout extends StatelessWidget implements PreferredSizeWidget {
  const CockpitReadout({
    super.key,
    required this.stats,
    required this.deliverableCount,
    this.onTap,
  });

  final SessionStats? stats;

  /// 产出总数；`null` = 网关没给（显示 `—`，不是 0）。
  final int? deliverableCount;

  final VoidCallback? onTap;

  /// 带高。34 = 数值行 13 + 标签行 10 + 上下呼吸 11。
  static const double height = 34;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  /// 仪表格的紧凑口径。
  ///
  /// 阈值与信息面板（`session_info_sheet.dart` 的 `_compact`）**刻意不同**：那是
  /// 一整行的明细，用千分位精确值更好读；这里每格只有约 72dp，`12,345` 会挤爆
  /// 等宽格，所以从一万往上收成 K/M。一万以下仍给精确值 —— 把 1540 写成 `1.5K`
  /// 是在丢信息，而四个字符放得下。
  static String compact(int n) {
    final abs = n.abs();
    String trim(String s) => s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
    if (abs < 10000) return '$n';
    if (abs < 1000000) return '${trim((n / 1000).toStringAsFixed(1))}K';
    return '${trim((n / 1000000).toStringAsFixed(1))}M';
  }

  Widget _cell(
    BuildContext context,
    String label,
    String? value, {
    Color? valueColor,
    bool first = false,
  }) {
    final c = context.c;
    return Expanded(
      child: Container(
        height: height,
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: first ? Colors.transparent : c.border,
            ),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              value ?? '—',
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.1,
                color: value == null
                    ? c.textTertiary.withOpacity(0.55)
                    : (valueColor ?? c.textPrimary),
              ),
            ),
            Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 8.5,
                letterSpacing: 1.1,
                height: 1.2,
                color: c.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final counters = stats?.counters;
    final tps = stats?.tokensPerSecond;
    final consumed = stats?.consumedTokens;

    return InkWell(
      onTap: onTap,
      child: Container(
        // 底色必须写进 decoration，不能与 `color:` 并存 —— Container 对两者
        // 同时非空会直接断言失败（`color == null || decoration == null`），
        // 2026-11-15 的 CI 就是被这一处拦下的。
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: SizedBox(
          height: height,
          child: Row(
            children: [
              // 与方向板一致的五个格：轮 / 步 / tok/s / 累计消耗 / 产出。
              // 上下文占用**不**进这里 —— 顶栏身份行第二行已经有它（含 70%/85%
              // 阈值换色），同一个读数不该在 40dp 内出现两次。
              _cell(context, 'TURN', counters?.turns?.toString(), first: true),
              _cell(context, 'STEP', counters?.steps?.toString()),
              _cell(
                context,
                'TOK/S',
                tps == null
                    ? null
                    : (tps >= 10 ? tps.round().toString() : tps.toStringAsFixed(1)),
                valueColor: tps == null ? null : c.accent,
              ),
              _cell(context, 'BURN', consumed == null ? null : compact(consumed)),
              _cell(context, 'OUT',
                  deliverableCount == null ? null : compact(deliverableCount!)),
            ],
          ),
        ),
      ),
    );
  }
}
