import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/services/voice_input_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';

/// 长按说话（v1.12.0；**v1.27 改了触发位置**）。
///
/// 交互契约（v1.27 起）：
///   * **点按**输入框 → 正常打字（与之前完全一致，且长按选词/系统工具条**回来了**）
///   * **按住麦克风按钮** → 开始说话；**松开** → 识别文本进输入框
///   * 松开后出现「重录 / 发送」两个按钮
///   * 长按**输入框本体**不再触发录音 —— 那个手势要留给系统选词/粘贴
///   * 麦克风按钮在"设备确定不可用"时长按仍打开语音诊断（v1.12 的排查入口）
///
/// ## 为什么触发点从"整块输入区"挪到麦克风按钮
///
/// 旧实现是"空框时整块输入区盖一层 opaque 手势层"，理由是 EditableText 内部也有
/// 一个长按识别器（选词 + 弹工具条），在手势竞技场里它会先赢。代价是：只要输入框
/// 是空的，文本区就**永远拿不到长按**（选词、粘贴全没了），而且"按住输入框"这个
/// 手势对谁都不直观。
///
/// 现在长按挂在麦克风按钮上，它不在 EditableText 的命中路径里，两个识别器根本不
/// 进同一个竞技场。所以这组用例的第二条（长按输入框不抢手势）从"靠 opaque 层
/// 让开"变成了"结构上就不可能被抢"——断言不变，理由变了。
///
/// ⚠️ 用例必须 `debugSetAvailable(true)`：新逻辑里"设备确定不可用"时长按麦克风
/// 走的是**诊断对话框**（录音在那种设备上不可能成功）。测试环境本来探测必失败，
/// 不显式置为可用的话，长按就只会弹诊断，永远进不了录音态。
void main() {
  Future<DshService> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 见文件头的 ⚠️：必须先把"设备可用"定下来，initState 的探测才会返回 true。
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
    // 收掉挂着的计时器。22 秒覆盖语音内部最长的那个 20s 诊断兜底
    // （unavailableReason / hasPermission 各 5s）—— 只推 3 秒会让它落到**下一个**
    // 用例头上，报成一句与产品无关的 "A Timer is still pending"。
    await tester.pump(const Duration(seconds: 22));
    VoiceInputService.instance.debugClearFakeRecognition();
    VoiceInputService.instance.debugReset();
  }

  final fieldFinder = find.byKey(const ValueKey('chat-input-field'));

  /// 长按说话的入口（v1.27）：麦克风按钮上的手势层。
  final micHolder = find.byKey(const ValueKey('chat-hold-layer'));
  final recordingHint = find.textContaining('松开结束');

  /// 把输入框清空。
  ///
  /// ⚠️ 必须每个用例都做：`DraftStore.instance` 是**进程级单例**，上一个用例
  /// 打过的字（或语音识别结果）会作为草稿被下一个用例的 ChatView 恢复进输入框。
  Future<void> clearField(WidgetTester tester) async {
    await tester.enterText(fieldFinder, '');
    await tester.pump();
  }

  /// 按住**麦克风按钮**不放。
  ///
  /// **两次 pump 都是必要的**：第一次推进过长按阈值（识别器在这时才回调），
  /// 第二次让 setState 的结果真正渲染出来 —— 只 pump 一次会看到尚未重建的旧
  /// 界面，测试会随机失败。
  Future<TestGesture> holdMic(WidgetTester tester) async {
    final gesture = await tester.startGesture(tester.getCenter(micHolder));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    return gesture;
  }

  /// 按住**输入框本体**不放（用来钉住"长按不再被录音抢走"）。
  Future<TestGesture> holdField(WidgetTester tester) async {
    final gesture = await tester.startGesture(tester.getCenter(fieldFinder));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    return gesture;
  }

  testWidgets('按住麦克风 → 进入录音态；松开 → 文本进输入框并出现重录/发送', (tester) async {
    VoiceInputService.instance.debugSetFakeRecognition(
      partials: ['帮我查一下'],
      finalText: '帮我查一下今天的日志',
    );
    await pumpChat(tester);
    await clearField(tester);

    final gesture = await holdMic(tester);
    // 录音态：输入区换成"松开结束"面板。
    expect(recordingHint, findsOneWidget, reason: '按住麦克风必须真的开始录音');
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

  testWidgets('长按输入框本体不再录音（那个手势属于系统的选词/粘贴）', (tester) async {
    VoiceInputService.instance.debugSetFakeRecognition(finalText: '不该出现');
    await pumpChat(tester);
    await clearField(tester);

    await tester.enterText(fieldFinder, '已经打了半句话');
    await tester.pump();

    final gesture = await holdField(tester);
    expect(recordingHint, findsNothing, reason: '有内容时不能夺走长按 —— 那是选词/粘贴的手势');
    await gesture.up();
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(fieldFinder);
    expect(field.controller!.text, '已经打了半句话', reason: '不能改写用户已有的输入');

    await teardown(tester);
  });

  testWidgets('空框时长按输入框同样不录音（触发点只在麦克风上）', (tester) async {
    // 这条是 v1.27 的核心：旧实现"空框时整块输入区可长按录音"，代价是空框里
    // 长按选词永远失效（想选中一段粘贴进来是不可能的）。现在空框长按什么都不做，
    // 指针完全交给 TextField —— 选词/工具条恢复。
    VoiceInputService.instance.debugSetFakeRecognition(finalText: '不该出现');
    await pumpChat(tester);
    await clearField(tester);

    final gesture = await holdField(tester);
    expect(recordingHint, findsNothing, reason: '空框长按也不该触发录音');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(recordingHint, findsNothing);

    await teardown(tester);
  });

  testWidgets('录音启动失败时不留下挂死状态', (tester) async {
    // 设备标记为可用（否则长按走的是诊断），但没有假识别、平台通道也不存在：
    // start() 走真实失败路径并回调 onError。
    await pumpChat(tester);
    await clearField(tester);

    final gesture = await holdMic(tester);
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

    await tester.tap(fieldFinder);
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

    final gesture = await holdMic(tester);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('重录'), findsOneWidget);

    await tester.tap(find.text('重录'));
    await tester.pump();
    await tester.pump();

    expect(recordingHint, findsOneWidget, reason: '重录应立刻重新开始录音（不用再按住一次）');
    expect(find.text('第一遍识别结果'), findsNothing, reason: '重录要先清掉上一遍的结果');
    expect(find.text('重录'), findsNothing, reason: '录音中不该还显示上一轮的确认按钮');

    await teardown(tester);
  });
}
