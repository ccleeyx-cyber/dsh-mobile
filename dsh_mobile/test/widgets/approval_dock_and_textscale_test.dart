import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/models/approval_request.dart';
import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/theme/app_spacing.dart';
import 'package:dsh_mobile/views/chat_view.dart';
import 'package:dsh_mobile/widgets/approval_card.dart';

/// 审批卡位置 + 字号/间距 token 的回归测试（v1.14.5）。
///
/// 两个都来自同一类缺陷：**交互对象的位置没有测试钉住，于是它悄悄退化**。
///
/// 1. 审批卡曾挂在消息 ListView 的最后一项。于是任何一条长回复都能把它顶出
///    屏幕 —— agent 已经停下等授权，而用户得先滚到底才够得着「允许一次」。
///    提问卡早修好了同一个问题（固定区 + 限高 + 提交钉底），两个卡片行为不一致
///    本身就是缺陷。同一屏出现提问和审批时，审批卡尤其容易被顶走。
///
/// 2. 全局此前**完全没有**处理 `MediaQuery.textScaler`：深色模式走了真
///    ThemeData 所以能工作，字号则完全交给系统默认值。系统字号放大到 1.3x 时，
///    10.5pt 的时间戳、11pt 的状态条会在固定高度的行里互相压住。
void main() {
  Future<DshService> pumpChat(
    WidgetTester tester, {
    Size size = const Size(400, 900),
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dsh = DshService();
    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: MaterialApp(
          builder: (ctx, child) => ThemeScope(
            isDark: false,
            child: MediaQuery(
              data: MediaQuery.of(ctx).copyWith(
                textScaler: TextScaler.linear(textScale),
              ),
              child: child ?? const SizedBox(),
            ),
          ),
          home: const ChatView(),
        ),
      ),
    );
    await tester.pump();
    return dsh;
  }

  /// ChatView 挂载时会起一个 12s 的语音初始化看门狗（平台在测试里不回调）。
  /// 不收掉它，每个用例都会以 "A Timer is still pending" 失败 —— 那是与本文件
  /// 要测的东西无关的噪声。
  ///
  /// 必须**在用例体内**调用，不能放 addTearDown：不变式检查（timersPending）
  /// 先于 teardown 回调执行，等回调跑时断言已经炸了。
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 21));
  }

  /// 把一条很长的助手消息塞进当前会话 —— 它正是把审批卡顶出屏幕的那个元凶。
  void addLongMessage(DshService dsh, {int paragraphs = 40}) {
    final body = List.filled(paragraphs, '这是一段用于把审批卡顶出屏幕的长回复内容。').join('\n\n');
    dsh.debugSetMessages([
      ChatMessage(
        id: 'm-long',
        role: 'assistant',
        content: body,
        timestamp: DateTime.now(),
      ),
    ]);
  }

  ApprovalRequest approval(String sessionId, {String id = 'a1'}) =>
      ApprovalRequest.fromJson({
        'id': id,
        'eventId': 'evt-$id',
        'sessionId': sessionId,
        'toolName': 'shell',
        'command': 'rm -rf /tmp/some/deeply/nested/path/that/is/long',
        'createdAt': 1,
      });

  group('审批卡必须挂在输入框上方的固定 dock（v1.14.5）', () {
    testWidgets('有超长回复时，审批卡仍在屏幕内可见', (tester) async {
      final dsh = await pumpChat(tester);
      // 必须先有当前会话：审批卡按 sessionId 归属当前会话，会话为空时整块
      // 都不渲染（这不是本次要测的过滤逻辑，所以先把前置条件摆好）。
      dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-abc', title: 't'));
      dsh.debugSetPendingApprovals([approval('session-abc')]);
      addLongMessage(dsh);
      await tester.pumpAndSettle();

      expect(find.byType(ApprovalCard), findsOneWidget);

      // 核心断言：整张卡必须落在视口内（曾经它在 ListView 尾部，被长消息顶没）。
      final screenH = tester.view.physicalSize.height;
      expect(
        tester.getTopLeft(find.byType(ApprovalCard)).dy,
        lessThan(screenH),
        reason: '审批卡不能被消息流顶到屏幕外',
      );
      expect(
        tester.getBottomLeft(find.byType(ApprovalCard)).dy,
        lessThanOrEqualTo(screenH),
        reason: '审批卡底部不能超出视口（操作按钮会点不到）',
      );

      await settle(tester);
    });

    testWidgets('审批卡与输入框同屏，不需要先滚动', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-abc', title: 't'));
      dsh.debugSetPendingApprovals([approval('session-abc')]);
      addLongMessage(dsh);
      await tester.pumpAndSettle();

      // 审批的操作按钮与输入框必须同时可见 —— 这是「不用滚就能批」的定义。
      expect(find.byType(ApprovalCard), findsOneWidget);
      expect(find.byType(TextField), findsWidgets,
          reason: '输入框与审批卡应在同一屏共存');

      await settle(tester);
    });

    testWidgets('多个审批时一次只展示一张，并说明还有几张', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-abc', title: 't'));
      dsh.debugSetPendingApprovals([
        approval('session-abc', id: 'a1'),
        approval('session-abc', id: 'a2'),
        approval('session-abc', id: 'a3'),
      ]);
      await tester.pumpAndSettle();

      // 一次摆三张可点的审批，用户很容易批错那一个 —— 而错批的代价是让 agent
      // 执行了一条没打算执行的命令。所以只给一张。
      expect(find.byType(ApprovalCard), findsOneWidget);
      expect(find.textContaining('还有 2 个操作等待授权'), findsOneWidget);

      await settle(tester);
    });

    testWidgets('没有审批时不渲染任何占位', (tester) async {
      await pumpChat(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ApprovalCard), findsNothing);
      await settle(tester);
    });
  });

  group('系统字号放大不再压垮固定高度的行（v1.14.5）', () {
    testWidgets('AppTextScale 把超出上限的倍率钳回 1.3', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: const TextScaler.linear(3.0)),
            child: child ?? const SizedBox(),
          ),
          home: const _ScaleProbe(),
        ),
      );
      await tester.pump();

      final applied = tester.widget<Text>(find.byKey(const ValueKey('probe-text')));
      expect(applied.textScaler!.scale(10) / 10, closeTo(1.3, 0.001));
    });

    testWidgets('AppTextScale 把调小的字号也挡在设计值之外（不低于 1.0）', (tester) async {
      // 钳位的下限是有意的设计决定，不是疏漏：低于 1.0 会让设计稿里定的下限字号
      // 进一步缩小，而那一档（10.5pt）已经是可读性底线。缩小字体的用户要的是
      // 「一屏多看点内容」，正确做法是折叠次要信息，不是把字压到看不清。
      await tester.pumpWidget(
        MaterialApp(
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: const TextScaler.linear(0.85)),
            child: child ?? const SizedBox(),
          ),
          home: const _ScaleProbe(),
        ),
      );
      await tester.pump();

      final applied = tester.widget<Text>(find.byKey(const ValueKey('probe-text')));
      expect(applied.textScaler!.scale(10) / 10, closeTo(1.0, 0.001),
          reason: '下限 1.0：不为缩小字体的用户进一步下调');
    });

    testWidgets('textTertiary 在两种主题下都达到 WCAG AA 对比度 4.5:1', (tester) async {
      // 这一档用在时间戳、占位符、工具卡副文案上 —— 视力最弱的用户最需要看清的
      // 位置。此前浅底 #9CA3AF 只有 2.8:1、深底 #6B7280 只有 3.9:1。
      double luminance(Color c) => c.computeLuminance();

      Future<double> ratio(Color fg, Color bg) async {
        final l1 = luminance(fg);
        final l2 = luminance(bg);
        final hi = l1 > l2 ? l1 : l2;
        final lo = l1 > l2 ? l2 : l1;
        return (hi + 0.05) / (lo + 0.05);
      }

      expect(await ratio(AppColors.textTertiary, const Color(0xFFFFFFFF)),
          greaterThanOrEqualTo(4.5));
      expect(await ratio(AppColors.textTertiaryDark, const Color(0xFF111827)),
          greaterThanOrEqualTo(4.5));
    });

    testWidgets('系统字号放到最大：ChatView 在真 app 根下不溢出', (tester) async {
      // 必须挂在 MyApp 上，不能自己拼一个 MediaQuery。
      //
      // 原因：钳位发生在 MyApp 的 builder 里（main.dart:217）。自己包一层
      // MediaQuery(textScaler: 3.0) 等于**绕过**了钳位，然后测一个 App 永远不会
      // 出现的状态 —— 那不是回归，是假警报。
      //
      // 这里让系统给出 3.0，再断言树里**没有**任何 OVERFLOW：钳位生效时布局是
      // 健康的；如果有人把钳位删了或改宽了上限，ApprovalCard 的操作按钮 Row 会在
      // 1.3x 就溢出（实测报 RenderFlex OVERFLOWING），这条用例随即变红。
      addTearDown(tester.view.reset);
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 3.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final dsh = DshService();
      // 与 main() 的 MultiProvider 一一对应。少给 ThemeController 的话
      // MyApp 自己会 context.watch 它并抛 ProviderNotFoundException。
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<DshService>.value(value: dsh),
            ChangeNotifierProvider<ThemeController>(
              create: (_) => ThemeController(),
            ),
          ],
          child: const MyApp(),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: '字号放大后 App 根必须先不抛异常');

      dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-abc', title: 't'));
      dsh.debugSetPendingApprovals([approval('session-abc')]);
      addLongMessage(dsh, paragraphs: 8);
      await tester.pump();

      // 关键：任何 RenderFlex 溢出在 widget 测试里都作为异常抛出。
      expect(tester.takeException(), isNull,
          reason: '系统字号 3.0 时（经 App 钳到 1.3）布局不得溢出');
    });
  });
}

class _ScaleProbe extends StatelessWidget {
  const _ScaleProbe();

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Scaffold(
      body: Text(
        'probe',
        key: const ValueKey('probe-text'),
        textScaler: AppTextScale.clamp(mq.textScaler),
      ),
    );
  }
}