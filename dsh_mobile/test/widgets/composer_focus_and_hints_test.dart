import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/models/local_snippet.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/services/storage_service.dart';
import 'package:dsh_mobile/services/voice_input_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';

/// Phase 4.6 / 4.5 的输入区回归测试。
///
/// 三件事，都是"代码看起来对、装置里跑起来才知道"的类型：
///
///   1. **确认态自动聚焦**：松开麦克风之后键盘必须自己弹出来、光标落在文末。
///      否则用户要再点一下输入框才能改字 —— 而确认态的全部意义就是"让你改"。
///   2. **确认态的按钮不能被键盘盖住**：输入区靠 `Padding(bottom: viewInsets)`
///      抬升，这条用例量的是几何位置，不量实现手段 —— 只要「重录 / 发送」落在
///      键盘顶边之上就算通过，将来谁换了实现也不会假失败。
///   3. **发送后键盘收起**：输入框已经空了、键盘还杵着，用户会以为卡住了。
///
/// 另外钉住 v1.27 之后新增的一次性引导：长按输入框本体不再录音，第一次要讲一句
/// "麦克风在右边"，之后（跨进程）不再打扰。
void main() {
  Future<DshService> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 见 hold_to_talk_test.dart 的说明：不置为可用的话长按麦克风走的是诊断
    // 对话框，永远进不了录音态。
    VoiceInputService.instance.debugSetAvailable(true);
    final dsh = DshService();
    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: MaterialApp(
          builder: (ctx, child) =>
              ThemeScope(isDark: false, child: child ?? const SizedBox()),
          home: const ChatView(),
        ),
      ),
    );
    await tester.pump();
    return dsh;
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // 22s 覆盖语音服务内部最长的那个 20s 诊断兜底（见 hold_to_talk_test）。
    await tester.pump(const Duration(seconds: 22));
    VoiceInputService.instance.debugClearFakeRecognition();
    VoiceInputService.instance.debugReset();
  }

  final fieldFinder = find.byKey(const ValueKey('chat-input-field'));
  final micHolder = find.byKey(const ValueKey('chat-hold-layer'));
  final recordingHint = find.textContaining('松开结束');

  /// 清空输入框：`DraftStore.instance` 是进程级单例，上一条用例的草稿会被下一个
  /// ChatView 恢复进来。
  Future<void> clearField(WidgetTester tester) async {
    await tester.enterText(fieldFinder, '');
    await tester.pump();
  }

  Future<TestGesture> holdMic(WidgetTester tester) async {
    final gesture = await tester.startGesture(tester.getCenter(micHolder));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    return gesture;
  }

  Future<TestGesture> holdField(WidgetTester tester) async {
    final gesture = await tester.startGesture(tester.getCenter(fieldFinder));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    return gesture;
  }

  /// 走一遍"按住麦克风 → 松开"，停在确认态。
  Future<FocusNode> enterConfirm(WidgetTester tester, String text) async {
    VoiceInputService.instance
        .debugSetFakeRecognition(partials: [text], finalText: text);
    await pumpChat(tester);
    await clearField(tester);
    final gesture = await holdMic(tester);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('重录'), findsOneWidget, reason: '前置条件：必须已进入确认态');
    return tester.widget<TextField>(fieldFinder).focusNode!;
  }

  testWidgets('松开麦克风进入确认态 → 自动聚焦，光标落在文末', (tester) async {
    final node = await enterConfirm(tester, '帮我查一下今天的日志');

    // 确认态的整个意义是"这段话说错了你可以改"。不自动聚焦，用户得先点一下
    // 输入框 —— 而这一帧键盘本来是收着的，等于多一步才能开始改字。
    expect(node.hasFocus, isTrue, reason: '进入确认态必须自动拿到焦点（真机上即弹键盘）');

    final controller = tester.widget<TextField>(fieldFinder).controller!;
    expect(controller.selection.isCollapsed, isTrue, reason: '光标应是插入点，不是一段选区');
    expect(controller.selection.baseOffset, controller.text.length,
        reason: '光标必须停在文末 —— 用户是从末尾继续说话/改字，不是从头改');

    await teardown(tester);
  });

  testWidgets('确认态弹键盘后「重录 / 发送」仍完整落在键盘上方', (tester) async {
    await enterConfirm(tester, '帮我查一下');

    // 真机上这一帧键盘正在弹起。用 viewInsets 模拟同样的抬升，然后量几何位置：
    // 输入栏底边必须紧贴键盘顶边（不许有空白），两个按钮的文案必须整条在上方。
    const viewportHeight = 900.0;
    const keyboardHeight = 320.0;
    const keyboardTop = viewportHeight - keyboardHeight;

    tester.view.viewInsets = const FakeViewPadding(bottom: keyboardHeight);
    await tester.pumpAndSettle();

    final bar = tester.getRect(find.byKey(const ValueKey('chat-input-bar')));
    expect((bar.bottom - keyboardTop).abs() <= 1.0, isTrue,
        reason: '输入栏底边 ${bar.bottom} 应等于键盘顶边 $keyboardTop');

    for (final label in <String>['重录', '发送']) {
      final rect = tester.getRect(find.text(label));
      expect(rect.bottom <= keyboardTop, isTrue,
          reason: '「$label」被键盘盖住了：文案底边 ${rect.bottom} > 键盘顶边 $keyboardTop');
    }

    await teardown(tester);
  });

  testWidgets('确认态点「发送」后收起键盘（空输入框配着键盘 = 像卡住）', (tester) async {
    final node = await enterConfirm(tester, '发一条就走');
    expect(node.hasFocus, isTrue, reason: '前置条件：确认态是聚焦的');

    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(node.hasFocus, isFalse, reason: '发送之后键盘必须收起：输入框已清空，留着它像死机');
    expect(find.text('重录'), findsNothing, reason: '确认态动作行必须随发送一起消失');
    expect(recordingHint, findsNothing);

    await teardown(tester);
  });

  testWidgets('确认态点「重录」也收起键盘（那块高度要让给"正在聆听"）', (tester) async {
    final node = await enterConfirm(tester, '第一遍');

    await tester.tap(find.text('重录'));
    await tester.pump();
    await tester.pump();

    expect(recordingHint, findsOneWidget, reason: '前置条件：重录应立刻重新开始录音');
    expect(node.hasFocus, isFalse, reason: '进入录音态必须收键盘，否则键盘会把聆听面板顶掉');

    await teardown(tester);
  });

  testWidgets('第一次长按输入框本体才提示"按住麦克风说话"，之后不再打扰', (tester) async {
    // 用 mock prefs 走真实的持久化分支，而不是只测进程内标记。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await pumpChat(tester);
    await clearField(tester);

    // 第一次：空框里长按 —— 老用户会以为这里还能录音（v1.27 之前就是这样），
    // 现在什么都不发生，不讲一句他们会以为语音坏了。
    var gesture = await holdField(tester);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('按住右下角 🎤 说话'), findsOneWidget,
        reason: '第一次长按输入框必须提示真正的入口在麦克风上');
    expect(recordingHint, findsNothing, reason: '提示不能顺手把录音抢回来');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('dsh_hint_hold_mic_v1'), isTrue,
        reason: '引导必须落盘 —— 否则重启后会再弹一次');

    // 等第一条 SnackBar 自己走完再测第二次，避免把"还挂在那儿"当成"又弹了"。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    gesture = await holdField(tester);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('按住右下角 🎤 说话'), findsNothing, reason: '引导只能出现一次');

    await teardown(tester);
  });

  testWidgets('本地快捷指令出现在「/」面板里，点一条是**追加**进输入框', (tester) async {
    // Phase 5.4 的接入点。设置页能把本地指令建出来只是做了一半 —— 入口没进
    // 「/」面板，用户在建完之后根本用不上。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'dsh_local_snippets': jsonEncode([
        {'id': 'l1', 'label': '我的周报', 'text': '总结这周的进展', 'tag': ''},
        {'id': 'l2', 'label': '翻译', 'text': '把下面这段译成{语言}：', 'tag': '翻译'},
      ]),
    });
    await pumpChat(tester);
    await clearField(tester);
    // initState 里的本地指令加载是异步的，等它落地。
    await tester.pumpAndSettle();

    await tester.enterText(fieldFinder, '已有内容');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('composer-slash-button')));
    await tester.pumpAndSettle();

    expect(find.text('我的周报'), findsOneWidget, reason: '本地条目必须进「/」面板');
    // [fix 2026-10-18] 只有本地一组时不画分组标题 —— 标题只用来区分来源，
    // 而弹层本身已经叫「命令与模板」。
    expect(find.text('本地快捷指令'), findsNothing,
        reason: '只有一组时不显示分组标题');
    expect(find.text('网关模板'), findsNothing,
        reason: '网关没下发模板时不能吊着一个空标题');
    // 带占位符的那条要有不同图标：点它会先弹一屏填参数，不是直接插入。
    expect(find.byIcon(Icons.edit_note_rounded), findsOneWidget);

    await tester.tap(find.text('我的周报'));
    await tester.pumpAndSettle();

    final controller = tester.widget<TextField>(fieldFinder).controller!;
    expect(controller.text, '已有内容\n总结这周的进展',
        reason: '插入必须**追加**在已有草稿后面，不能覆盖用户打的半句话');

    await teardown(tester);
  });

  testWidgets('设置里新建的指令不需要重启就出现在面板里（缓存过期回归）', (tester) async {
    // [regression 2026-10-18] 真实缺陷：本组件常驻在 IndexedStack 里、State 永不
    // 复建，本地指令只在 initState 读一次 —— 用户在设置里新建之后回到对话页，
    // 面板里还是空的（或还是旧的那几条），要重启 App 才出现。用户当时的描述
    // 就是"快捷指令没地方使用"。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await pumpChat(tester);
    await clearField(tester);
    await tester.pumpAndSettle();

    // 模拟"在设置 → 快捷指令里新建一条"：写入方是另一个页面，与这里不共享 State。
    await StorageService.saveLocalSnippets(const [
      LocalSnippet(id: 'l9', label: '刚建的', text: '按这个来'),
    ]);

    // 不重启、不重新挂载，直接点开面板。
    await tester.tap(find.byKey(const ValueKey('composer-slash-button')));
    await tester.pumpAndSettle();

    expect(find.text('刚建的'), findsOneWidget,
        reason: '面板打开时必须重读本地条目，否则新建的指令要重启才可见');

    await teardown(tester);
  });

  testWidgets('输入框里打一个 / 自动弹出模板面板（入口不用去找那个 ⚡）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'dsh_local_snippets': jsonEncode([
        {'id': 'l1', 'label': '周报', 'text': '总结这周的进展', 'tag': ''},
      ]),
    });
    await pumpChat(tester);
    await clearField(tester);
    await tester.pumpAndSettle();

    await tester.enterText(fieldFinder, '/');
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('命令与模板'), findsOneWidget,
        reason: '斜杠是用户本来就有的习惯，用它把面板带出来，比再加一行常驻 chips 便宜');
    expect(find.text('周报'), findsOneWidget);

    await teardown(tester);
  });
}
