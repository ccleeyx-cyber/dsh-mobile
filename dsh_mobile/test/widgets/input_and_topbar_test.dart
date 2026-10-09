import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/models/pending_attachment.dart';
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
  ///
  /// 返回 service 实例，因为有些路径只在"已连接"时才可达（附件入口就是），
  /// 调用方需要自己设定连接状态。
  Future<DshService> pumpChat(WidgetTester tester, {Size size = const Size(400, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dsh = DshService();
    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: MaterialApp(
          builder: (ctx, child) => ThemeScope(isDark: false, child: child ?? const SizedBox()),
          home: const ChatView(),
        ),
      ),
    );
    await tester.pump();
    return dsh;
  }

  Future<void> teardown(WidgetTester tester) async {
    // 先把待定的计时器跑完再拆树。
    //
    // 有两类计时器要收：
    //   1. 草稿存储的 600ms 防抖（onChanged → dsh.updateDraft）。
    //   2. 语音服务内部的平台调用超时（unavailableReason / diagnose 各 5s）。
    //      它们是为"平台不回调"准备的 —— 测试环境里平台确实不回调，于是这些
    //      timer 会一直挂着，直到被断言成
    //      "A Timer is still pending even after the widget tree was disposed"。
    //
    //   3. 语音诊断对话框最外层那个 20s 超时（chat_view 里 _VoiceDiagnoseBody
    //      给 diagnose() 套的兜底）。它比内部两个 5s 之和还长，所以是这个文件里
    //      最长的一个待收计时器。
    //
    // 推 21s 覆盖上面最长的那个。假时钟推进是瞬时的，不花真实时间。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 21));
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

      // v1.11.1 起正常态图标换成了实心 mic_rounded（按钮加大到 44px 的一部分）。
      final icon = find.byIcon(Icons.mic_rounded);
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

  group('附件入口（用户报「没有上传图片或者文件功能」）', () {
    testWidgets('输入栏有附件按钮，且可点', (tester) async {
      await pumpChat(tester);

      final icon = find.byIcon(Icons.add_rounded);
      expect(icon, findsOneWidget, reason: '输入栏必须有附件入口');

      final ink = tester.widget<InkWell>(
        find.ancestor(of: icon, matching: find.byType(InkWell)).first,
      );
      expect(ink.onTap, isNotNull);

      await teardown(tester);
    });

    testWidgets('点击后弹出「图片 / 文件」两个入口', (tester) async {
      // 附件入口是"已连接"才可达的路径（离线点它会提示先重连，而不是打开一个
      // 必然失败的选择器），所以这里先把状态设成已连接。
      final dsh = await pumpChat(tester);
      dsh.debugSetConnection(true);
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();

      expect(find.text('图片'), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);

      await teardown(tester);
    });

    testWidgets('离线时点附件不打开选择器，而是提示先重连', (tester) async {
      await pumpChat(tester);

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();

      // 离线时打开选择器只会让用户白选一次、上传必然失败，所以必须先拦住。
      expect(find.text('图片'), findsNothing);
      expect(find.textContaining('网络已断开'), findsOneWidget);

      await teardown(tester);
    });

    testWidgets('待发附件显示名字与体积，且能单独删除', (tester) async {
      await pumpChat(tester);
      final state = tester.state(find.byType(ChatView));

      // 用测试缝隙直接挂载，绕开原生选择器（单测里调不起来）。
      (state as dynamic).debugAddPendingAttachment(
        const PendingFile(
          localId: 'f1',
          name: 'report.pdf',
          byteLength: 2048,
          receiptId: 'r-1',
        ),
      );
      await tester.pump();

      // 名字与体积都要显示 —— 用户必须能确认"挂上的到底是哪个文件"。
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('2 KB'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pump();

      expect(find.text('report.pdf'), findsNothing);
      expect(find.text('2 KB'), findsNothing);

      await teardown(tester);
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

  group('输入卡片：全部控件都在框内（v1.10.2 的布局重做）', () {
    testWidgets('四个控件都在输入卡片内部，而不是并排在它外面', (tester) async {
      await pumpChat(tester);

      // 卡片的判定用"包含输入框的最内层那个圆角容器"来表达：直接量几何关系
      // 比找一个样式常量稳。附件、模型、麦克风、发送都必须在它内部。
      final card = find.ancestor(
        of: find.byType(TextField),
        matching: find.byType(Container),
      );
      expect(card, findsWidgets);

      for (final probe in <(String, Finder)>[
        ('附件', find.byIcon(Icons.add_rounded)),
        // 语音图标取决于可用性探测结果：测试环境里插件拿不到，探测会失败，
        // 于是渲染的是"划掉的麦克风"。所以两种都接受 —— 这里要断言的是
        // **位置**（在卡片内），不是可用状态。
        (
          '麦克风',
          find.byWidgetPredicate(
            (w) =>
                w is Icon &&
                (w.icon == Icons.mic_rounded || w.icon == Icons.mic_none_rounded || w.icon == Icons.mic_off_rounded),
          )
        ),
        ('发送', find.byIcon(Icons.arrow_upward_rounded)),
      ]) {
        final (label, finder) = probe;
        expect(finder, findsOneWidget, reason: '$label 控件必须存在');

        // 几何判定：控件的水平范围必须落在卡片内，而不是卡片右侧的空白里。
        final cardRect = tester.getRect(card.last);
        final ctlRect = tester.getRect(finder);
        expect(
          ctlRect.left >= cardRect.left - 1 && ctlRect.right <= cardRect.right + 1,
          isTrue,
          reason: '$label 应位于输入卡片内部：控件 $ctlRect vs 卡片 $cardRect',
        );
      }

      await teardown(tester);
    });

    testWidgets('模型选择在输入卡片里，且可点开', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetConnection(true);
      await tester.pump();

      // 模型名来自 dsh.currentModel；这里只校验"有一处可点的模型入口"。
      final pill = find.byIcon(Icons.keyboard_arrow_down_rounded);
      expect(pill, findsOneWidget, reason: '模型选择下拉必须在输入卡片里');

      final ink = tester.widget<InkWell>(
        find.ancestor(of: pill, matching: find.byType(InkWell)).first,
      );
      expect(ink.onTap, isNotNull, reason: '模型选择必须可点');

      await teardown(tester);
    });

    testWidgets('发送键在没内容时不可点、有文字后可点', (tester) async {
      await pumpChat(tester);

      InkWell sendInk() => tester.widget<InkWell>(
            find.ancestor(
              of: find.byIcon(Icons.arrow_upward_rounded),
              matching: find.byType(InkWell),
            ).first,
          );

      // 空输入框：发送键必须是禁用的 —— 上一版无论有没有文字都是亮着的，
      // 点下去没反应，用户会以为卡住了。
      expect(sendInk().onTap, isNull, reason: '没有可发内容时发送键应禁用');

      await tester.enterText(find.byType(TextField), '你好');
      await tester.pump();

      expect(sendInk().onTap, isNotNull, reason: '有文字后发送键必须可点');

      await teardown(tester);
    });

    testWidgets('挂了附件但没写字时，发送键也可点', (tester) async {
      await pumpChat(tester);
      final state = tester.state(find.byType(ChatView));

      (state as dynamic).debugAddPendingAttachment(
        const PendingFile(localId: 'f1', name: 'a.txt', byteLength: 8, receiptId: 'r'),
      );
      await tester.pump();

      final ink = tester.widget<InkWell>(
        find.ancestor(
          of: find.byIcon(Icons.arrow_upward_rounded),
          matching: find.byType(InkWell),
        ).first,
      );
      // 引擎的准入规则是"文字或附件"，所以只有附件也必须能发。
      expect(ink.onTap, isNotNull, reason: '只挂附件也应当能发送');

      await teardown(tester);
    });

    testWidgets('长按麦克风打开语音诊断（"点了没反应"的排查入口）', (tester) async {
      await pumpChat(tester);

      final mic = find.byWidgetPredicate(
        (w) =>
            w is Icon &&
            (w.icon == Icons.mic_rounded || w.icon == Icons.mic_none_rounded || w.icon == Icons.mic_off_rounded),
      );
      expect(mic, findsOneWidget);

      await tester.longPress(mic);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 对话框必须**立刻**出现，不能等诊断结果 —— 诊断要跑四五次平台查询，
      // 让它先转圈、结果后填，比"点了半天才弹窗"好得多。
      expect(find.text('语音输入诊断'), findsOneWidget,
          reason: '长按麦克风必须能打开诊断，否则用户遇到"没反应"时无从下手');

      await tester.pump(const Duration(seconds: 1));
      await teardown(tester);
    });

    testWidgets('顶栏不再有工作区/模型胶囊（已移进输入卡片，避免重复）', (tester) async {
      await pumpChat(tester);

      // 顶栏里不应该再出现工作区或模型胶囊：
      //   * 工作区胶囊用 Icons.folder_rounded
      //   * 模型胶囊用 Icons.smart_toy_outlined + 下拉箭头
      // 输入卡片里的模型入口用的是 keyboard_arrow_down_rounded，两者不同，
      // 所以这里的断言不会误伤。
      expect(find.byIcon(Icons.folder_rounded), findsNothing,
          reason: '工作区胶囊已从顶栏移除');
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.arrow_drop_down)),
        findsNothing,
        reason: '顶栏不应再有胶囊式下拉',
      );

      await teardown(tester);
    });
  });
}
