import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/services/voice_input_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';

/// 长按说话（v1.12.0）。
///
/// 交互契约：
///   * **点按**输入框 → 正常打字（与之前完全一致）
///   * **长按空输入框** → 开始说话；**松开** → 识别文本进输入框
///   * 松开后出现「重录 / 发送」两个按钮
///   * 输入框**已有文字**时长按 → 保持系统原本的选中/粘贴行为（不抢手势）
///
/// ⚠️ 第一条断言（长按真的落到我们手上）不是形式主义：Flutter 的
/// EditableText 内部**也**有一个长按识别器（选词 + 弹工具条），它在手势竞技场
/// 里比外层先注册、会赢。实现是靠"空框时关掉 enableInteractiveSelection"
/// 把它让开的 —— 一旦哪天有人把那个开关去掉，长按就会退化成选词，
/// 而界面上看起来只是"语音没反应"。这个用例就是钉住这一点。
void main() {
  Future<DshService> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
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
    await tester.pumpWidget(const SizedBox.shrink());
    // 收掉挂着的计时器。8 秒覆盖语音内部最长的那个 5s 平台超时
    // （unavailableReason / hasPermission）—— 只推 3 秒会让它落到**下一个**
    // 用例头上，报成一句与产品无关的 "A Timer is still pending"。
    await tester.pump(const Duration(seconds: 22));
    VoiceInputService.instance.debugClearFakeRecognition();
    VoiceInputService.instance.debugReset();
  }

  final fieldFinder = find.byKey(const ValueKey('chat-input-field'));
  final recordingHint = find.textContaining('松开结束');

  /// 把输入框清空。
  ///
  /// ⚠️ 必须每个用例都做：`DraftStore.instance` 是**进程级单例**，上一个用例
  /// 打过的字（或语音识别结果）会作为草稿被下一个用例的 ChatView 恢复进输入框。
  /// 而按设计"长按说话"只在输入框为空时生效 —— 于是那些用例会看到"长按没反应"，
  /// 失败得很像产品缺陷，其实是测试互相污染。
  Future<void> clearField(WidgetTester tester) async {
    await tester.enterText(fieldFinder, '');
    await tester.pump();
  }

  /// 按住不放。**两次 pump 都是必要的**：第一次推进过长按阈值（识别器在这时
  /// 才回调），第二次让 setState 的结果真正渲染出来 —— 只 pump 一次会看到
  /// 尚未重建的旧界面，测试会随机失败。
  Future<TestGesture> holdDown(WidgetTester tester) async {
    final gesture = await tester.startGesture(tester.getCenter(fieldFinder));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    return gesture;
  }

  testWidgets('长按空输入框 → 进入录音态；松开 → 文本进输入框并出现重录/发送', (tester) async {
    VoiceInputService.instance.debugSetFakeRecognition(
      partials: ['帮我查一下'],
      finalText: '帮我查一下今天的日志',
    );
    await pumpChat(tester);
    await clearField(tester);

    final gesture = await holdDown(tester);
    // 录音态：输入区换成"松开结束"面板。
    expect(recordingHint, findsOneWidget, reason: '长按必须真的开始录音（不能被输入框内部的长按选词吃掉）');
    expect(find.text('帮我查一下'), findsOneWidget, reason: '中间结果应实时显示');

    await gesture.up();
    await tester.pumpAndSettle();

    // 松开后：最终文本进输入框，且出现两个动作按钮。
    expect(fieldFinder, findsOneWidget);
    final field = tester.widget<TextField>(fieldFinder);
    expect(field.controller!.text, '帮我查一下今天的日志',
        reason: '松手要交付最终结果，而不是停在中间结果上');
    expect(find.text('重录'), findsOneWidget);
    expect(find.text('发送'), findsOneWidget);
    expect(recordingHint, findsNothing);

    await teardown(tester);
  });

  testWidgets('已有文字时长按不抢手势（保留系统选词/粘贴）', (tester) async {
    VoiceInputService.instance.debugSetFakeRecognition(finalText: '不该出现');
    await pumpChat(tester);
    await clearField(tester);

    await tester.enterText(fieldFinder, '已经打了半句话');
    await tester.pump();

    final gesture = await holdDown(tester);
    expect(recordingHint, findsNothing, reason: '有内容时不能夺走长按 —— 那是选词/粘贴的手势');
    await gesture.up();
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(fieldFinder);
    expect(field.controller!.text, '已经打了半句话', reason: '不能改写用户已有的输入');

    await teardown(tester);
  });

  testWidgets('录音启动失败时不留下挂死状态', (tester) async {
    // 关掉假识别 + 标记不可用：start() 会走真实的失败路径（测试环境里平台
    // 通道不存在，必然失败）并回调 onError。
    VoiceInputService.instance.debugSetAvailable(false);
    await pumpChat(tester);
    await clearField(tester);

    final gesture = await holdDown(tester);
    await gesture.up();
    await tester.pumpAndSettle();

    // 关键契约：失败后必须回到普通输入态 —— 不能卡在"正在聆听"，也不能
    // 留下一个没人能取消的录音状态。
    expect(recordingHint, findsNothing, reason: '启动失败后不能停在录音态');
    expect(fieldFinder, findsOneWidget);
    expect(find.text('重录'), findsNothing);

    await teardown(tester);
  });

  testWidgets('点按输入框仍是打字（不会误触发录音）', (tester) async {
    VoiceInputService.instance.debugSetFakeRecognition(finalText: '不该出现');
    await pumpChat(tester);
    await clearField(tester);

    // 空框上盖着手势层，点按落在它上面（warnIfMissed: false，因为按的就是这一层）。
    await tester.tap(fieldFinder, warnIfMissed: false);
    await tester.pump(); // 不推进到长按阈值

    expect(recordingHint, findsNothing, reason: '点按必须还是打字，不能变成长按录音');
    // "点按 = 打字"的实质：拿到焦点（键盘会弹出来）。
    final field = tester.widget<TextField>(fieldFinder);
    expect(field.focusNode!.hasFocus, isTrue, reason: '点按空框应聚焦，之后才能打字');

    await teardown(tester);
  });

  testWidgets('「重录」清空上一遍结果并立刻重新开始录音', (tester) async {
    VoiceInputService.instance.debugSetFakeRecognition(
      partials: ['第一遍'],
      finalText: '第一遍识别结果',
    );
    await pumpChat(tester);
    await clearField(tester);

    final gesture = await holdDown(tester);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('重录'), findsOneWidget);

    await tester.tap(find.text('重录'));
    await tester.pump();
    await tester.pump();

    expect(recordingHint, findsOneWidget, reason: '重录应立刻重新开始录音（不用再长按一次）');
    expect(find.text('第一遍识别结果'), findsNothing, reason: '重录要先清掉上一遍的结果');
    expect(find.text('重录'), findsNothing, reason: '录音中不该还显示上一轮的确认按钮');

    await teardown(tester);
  });
}
