import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/task_center.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/widgets/cockpit_readout.dart';

/// 驾驶舱仪表簇（2026-11-15 方向 A）。
///
/// 这里锁的是**承诺给用户的读数口径**，不是排版细节：
/// 1. 读不到 = `—`，绝不是 `0`（`0 轮 0 步` 会被读成"这轮没干活"）；
/// 2. 五个格位固定（轮 / 步 / tok/s / 累计消耗 / 产出），不因缺数而塌陷成四个；
/// 3. 整条可点 → 打开信息面板。
void main() {
  Future<void> pumpReadout(
    WidgetTester tester, {
    SessionStats? stats,
    int? deliverableCount,
    VoidCallback? onTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ThemeScope(
          isDark: false,
          child: Scaffold(
            body: Column(
              children: [
                CockpitReadout(
                  stats: stats,
                  deliverableCount: deliverableCount,
                  onTap: onTap,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 五个格位标签恒在 —— 缺数只影响数值，不影响结构。
  void expectAllLabels() {
    for (final label in const ['TURN', 'STEP', 'TOK/S', 'BURN', 'OUT']) {
      expect(find.text(label), findsOneWidget, reason: '格位标签 $label 必须常驻');
    }
  }

  testWidgets('什么都没读到：五个格位都在，数值全是破折号，不出现 0', (tester) async {
    await pumpReadout(tester);

    expectAllLabels();
    expect(find.text('—'), findsNWidgets(5), reason: '未知一律渲染成破折号');
    expect(find.text('0'), findsNothing, reason: '把未知画成 0 会被读成"这轮没花钱"');
  });

  testWidgets('读到了：轮/步、tok/s、累计消耗、产出各就各位', (tester) async {
    await pumpReadout(
      tester,
      stats: const SessionStats(
        source: 'live',
        uncachedInputTokens: 1200,
        outputTokens: 340,
        counters: SessionCounters(
          turns: 6,
          steps: 351,
          decodeMs: 1000,
          decodeTokens: 210,
        ),
      ),
      deliverableCount: 3,
    );

    expectAllLabels();
    expect(find.text('6'), findsOneWidget, reason: '轮');
    expect(find.text('351'), findsOneWidget, reason: '步');
    expect(find.text('210'), findsOneWidget, reason: 'tok/s');
    expect(find.text('1540'), findsOneWidget,
        reason: '累计消耗 1200+340；一万以下给精确值，收成 1.5K 是丢信息');
    expect(find.text('3'), findsOneWidget, reason: '产出');
  });

  testWidgets('tok/s 只缺解码耗时：该格是破折号，别的格照常显示', (tester) async {
    await pumpReadout(
      tester,
      stats: const SessionStats(
        source: 'live',
        // 只给了 turns/steps，没给 decodeMs/decodeTokens。
        counters: SessionCounters(turns: 2, steps: 9),
      ),
      deliverableCount: 0,
    );

    expect(find.text('2'), findsOneWidget);
    expect(find.text('9'), findsOneWidget);
    // TURN/STEP 之外的三个格里，TOK/S 与 BURN 未知 → 破折号；OUT 是已知的 0。
    expect(find.text('—'), findsNWidgets(2));
    expect(find.text('0'), findsOneWidget, reason: '产出 0 是已知真值，应当如实显示');
  });

  testWidgets('整条可点：点一下触发打开信息面板', (tester) async {
    var tapped = 0;
    await pumpReadout(tester, onTap: () => tapped++);

    await tester.tap(find.byType(CockpitReadout));
    await tester.pump();

    expect(tapped, 1);
  });
}
