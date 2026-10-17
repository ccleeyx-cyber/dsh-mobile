import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/widgets/top_toast.dart';

/// 顶部浮层提示的位置契约（2026-10-17）。
///
/// 用户要求：切换模型 / 权限之后的提示**不要**出现在下方 —— 底部是输入卡片、
/// 状态胶囊、审批 dock 的地盘，贴底的提示会盖住正在打的字。
///
/// 这里用"提示矩形必须落在屏幕上 1/3 以内"把这件事钉死：改回 SnackBar、或者
/// 把 Positioned.top 改大，都会直接红。
void main() {
  Widget host({required bool isDark}) {
    return MaterialApp(
      home: ThemeScope(
        isDark: isDark,
        child: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const ValueKey('fire-toast'),
                onPressed: () => TopToast.show(context, '本会话模型已切换为 DeepSeek V4.1'),
                child: const Text('fire'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('提示浮在顶部：矩形上沿在屏幕 1/3 以内，且不压到下半屏', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(isDark: false));
    await tester.tap(find.byKey(const ValueKey('fire-toast')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    final text = find.byKey(const ValueKey('top-toast-text'));
    expect(text, findsOneWidget, reason: '提示没出来');

    final rect = tester.getRect(text);
    expect(rect.top, lessThan(800 / 3),
        reason: '提示必须在上半屏（用户明确要求），实际 top=${rect.top}');
    expect(rect.bottom, lessThan(800 / 2),
        reason: '提示不能伸到下半屏：那里是输入区');

    // 走完 1.8 秒后自己消失 —— 这类"不痛的消息"不该常驻。
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const ValueKey('top-toast-text')), findsNothing,
        reason: '顶部提示必须自动消失');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('深色主题下也能渲染（不依赖 InheritedWidget 的 context 存活）', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(isDark: true));
    await tester.tap(find.byKey(const ValueKey('fire-toast')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.byKey(const ValueKey('top-toast-text')), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
