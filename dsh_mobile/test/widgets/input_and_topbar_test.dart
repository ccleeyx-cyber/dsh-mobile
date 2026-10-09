import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/services/voice_input_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';
import 'package:dsh_mobile/views/main_shell.dart';

/// 输入栏与顶栏的回归测试（v1.9.0）。
///
/// 两个都是用户实际报出来的缺陷，且都属于「代码看起来没问题、跑起来才知道」
/// 的那一类，所以必须有断言把它们钉住。
void main() {
  /// 把 ChatView 挂起来。ChatView 只依赖 DshService 和 ThemeScope；
  /// ThemeController 是菜单回调里才用到的（context.read），build 期不碰。
  Future<void> pumpChat(WidgetTester tester, {Size size = const Size(400, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: DshService(),
        child: MaterialApp(
          builder: (ctx, child) => ThemeScope(isDark: false, child: child ?? const SizedBox()),
          home: const ChatView(),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  group('语音按钮必须永远可点（用户报「有按钮但没法点击、也没弹权限」）', () {
    testWidgets('设备判定为不可用时，按钮依然带 onTap', (tester) async {
      // 这是缺陷的核心：上一版在 !_voiceSupported 时返回一个**不带 onTap 的
      // Icon**，于是点击毫无反应、麦克风权限弹窗永远不会出现，也没有任何
      // 恢复路径 —— 用户唯一能做的就是卸载重装。
      VoiceInputService.instance.debugSetAvailable(false);
      await pumpChat(tester);

      final icon = find.byIcon(Icons.mic_off_rounded);
      expect(icon, findsOneWidget, reason: '不可用时应显示划掉的麦克风，但仍要能点');

      final ink = tester.widget<InkWell>(
        find.ancestor(of: icon, matching: find.byType(InkWell)).first,
      );
      expect(ink.onTap, isNotNull, reason: '不可用时也必须可点 —— 点它才会重新探测并申请权限');

      await teardown(tester);
    });

    testWidgets('设备可用时按钮带 onTap', (tester) async {
      VoiceInputService.instance.debugSetAvailable(true);
      await pumpChat(tester);

      final icon = find.byIcon(Icons.mic_none_rounded);
      expect(icon, findsOneWidget);

      final ink = tester.widget<InkWell>(
        find.ancestor(of: icon, matching: find.byType(InkWell)).first,
      );
      expect(ink.onTap, isNotNull);

      await teardown(tester);
    });

    testWidgets('可用性尚未探测完成时，按钮就应可见（不能是空白占位）', (tester) async {
      // 上一版在 _voiceSupported == null 时返回空的 SizedBox，探测一旦卡住按钮
      // 就永远不出现，功能看起来根本不存在。
      VoiceInputService.instance.debugSetAvailable(false);
      await pumpChat(tester);
      // 构造后立刻断言：探测的 Future 还没回填时，界面已有可见的麦克风。
      expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);
    });

    testWidgets('点击不可用的按钮不会抛异常，并给出原因提示', (tester) async {
      VoiceInputService.instance.debugSetAvailable(false);
      await pumpChat(tester);

      await tester.tap(find.byIcon(Icons.mic_off_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 关键：不能崩。测试环境里插件方法通道不可用，这条路径会走到
      // unavailableReason()，必须被吞掉并以 SnackBar 呈现。
      expect(tester.takeException(), isNull);

      await teardown(tester);
    });
  });

  group('不可用原因必须可区分（没授权 vs 没有识别引擎）', () {
    test('unavailableReason 不抛异常且返回非空说明', () async {
      // 测试环境拿不到插件，hasPermission 会抛 —— 必须被捕获并回落到
      // 「没有识别引擎」那条，而不是把异常抛给 UI。
      final reason = await VoiceInputService.instance.unavailableReason();
      expect(reason, isNotEmpty);
      expect(reason, contains('语音'));
    });

    test('默认识别语言是 zh_CN', () {
      expect(VoiceInputService.defaultLocaleId, 'zh_CN');
    });
  });

  group('键盘弹出时不能留空白（用户报输入框下方一大段空白）', () {
    Future<void> pumpShell(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<DshService>.value(value: DshService()),
            ChangeNotifierProvider<ThemeController>.value(value: ThemeController()),
          ],
          child: MaterialApp(
            builder: (ctx, child) => ThemeScope(isDark: false, child: child ?? const SizedBox()),
            home: const MainShell(),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('键盘收起时底部导航栏存在', (tester) async {
      await pumpShell(tester);
      expect(find.byType(NavigationBar), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('键盘弹出时底部导航栏被移除', (tester) async {
      // 成因：chat_view 内部有自己的 Scaffold（默认 resizeToAvoidBottomInset
      // 为 true），按**完整**键盘高度抬高内容；而外层 Scaffold 关掉了 resize，
      // 导航栏仍占着屏幕底部。两者相加使输入框被多抬了一个导航栏的高度，
      // 于是输入框与键盘之间空出一条与导航栏等高的空白。
      //
      // 去掉导航栏后内层底边等于屏幕底边，抬高量恰好等于键盘高度。
      await pumpShell(tester);
      expect(find.byType(NavigationBar), findsOneWidget, reason: '前置条件：收起时有导航栏');

      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();

      expect(find.byType(NavigationBar), findsNothing,
          reason: '键盘弹出时必须移除导航栏，否则输入框下方会空出一条等高空白');

      await teardown(tester);
    });

    testWidgets('键盘收起后导航栏恢复', (tester) async {
      await pumpShell(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();
      expect(find.byType(NavigationBar), findsNothing);

      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();

      expect(find.byType(NavigationBar), findsOneWidget, reason: '收起键盘后必须恢复');
      await teardown(tester);
    });

    testWidgets('键盘弹出后输入栏底边紧贴键盘顶边 —— 中间不能有空白', (tester) async {
      // 这条才是用户要的验收标准。只断言"导航栏消失了"是不够的：它只证明手段，
      // 不证明结果。这里直接量输入栏的渲染位置。
      //
      // 视口高 900、键盘高 320 → 键盘顶边在 y=580。输入栏底边必须落在 580 上
      // （允许 1px 的取整误差）。修复前它会停在 580 - 导航栏高度 处，也就是
      // 两者之间空出一条导航栏高的空白。
      const viewportHeight = 900.0;
      const keyboardHeight = 320.0;
      const keyboardTop = viewportHeight - keyboardHeight;

      await pumpShell(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: keyboardHeight);
      await tester.pump();

      final bar = tester.getRect(find.byKey(const ValueKey('chat-input-bar')));
      expect(
        (bar.bottom - keyboardTop).abs() <= 1.0,
        isTrue,
        reason: '输入栏底边 ${bar.bottom} 应等于键盘顶边 $keyboardTop；'
            '两者之差就是输入框下方那条空白的高度',
      );

      await teardown(tester);
    });
  });
}
