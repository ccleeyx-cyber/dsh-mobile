import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/harness_notice.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/services/voice_input_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';
import 'package:dsh_mobile/widgets/harness_notice_card.dart';

/// 注入通知卡片的回归测试（2026-10-17）。
///
/// 两件事必须钉住：
/// 1. **它不能长成用户气泡** —— 用户报的就是"我什么时候发过这种消息"。用户气泡有
///    人像图标（`Icons.person_rounded`），通知卡必须是居中的灰色块，且明确写着
///    "引擎注入的通知（不是你说的话）"。
/// 2. **超长收尾默认折叠** —— 一条子代理收尾实测能占满两屏，默认全展开会把整条
///    消息流冲掉；折叠 + 显式展开才是能用的形态。
void main() {
  const settlement =
      'Background subagent 915eb2f4-0d12-4b86-8922-b2b26cfc3ecc finished and will do no '
      'further work unless you send it more.Its closing message:2026-10-06 | 修复考勤报表；'
      '新增绩效报表正常开班小组课班级数';

  Future<void> pumpCard(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (ctx, c) => ThemeScope(isDark: false, child: c ?? const SizedBox()),
        home: Scaffold(body: child),
      ),
    );
    await tester.pump();
  }

  group('HarnessNoticeCard', () {
    testWidgets('标题按种类给，并写明"不是你说的话"', (tester) async {
      await pumpCard(
        tester,
        HarnessNoticeCard(notice: HarnessNotice.tryParse(settlement)!),
      );

      expect(find.byKey(const ValueKey('harness-notice-card')), findsOneWidget);
      expect(find.text('子代理完成'), findsOneWidget);
      expect(find.text('#915eb2f4'), findsOneWidget);
      expect(find.text('引擎注入的通知（不是你说的话）'), findsOneWidget);
    });

    testWidgets('aborted / 插件通知 / 认不出的种类各有标题，不编功能名', (tester) async {
      await pumpCard(
        tester,
        HarnessNoticeCard(
          notice: HarnessNotice.tryParse('Background subagent a1 was stopped before it finished.')!,
        ),
      );
      expect(find.text('子代理被中止'), findsOneWidget);

      await pumpCard(
        tester,
        const HarnessNoticeCard(notice: HarnessNotice(kind: 'plugin:user-approval', body: '请批准')),
      );
      expect(find.text('插件通知'), findsOneWidget);

      await pumpCard(
        tester,
        const HarnessNoticeCard(notice: HarnessNotice(kind: 'something-new')),
      );
      expect(find.text('引擎通知'), findsOneWidget);
    });

    testWidgets('收尾正文默认折叠，点一下展开、再点收起', (tester) async {
      await pumpCard(
        tester,
        HarnessNoticeCard(notice: HarnessNotice.tryParse(settlement)!),
      );

      final bodyFinder = find.byKey(const ValueKey('harness-notice-body'));
      expect(bodyFinder, findsOneWidget);
      expect(tester.widget<SelectableText>(bodyFinder).maxLines, 3, reason: '默认 3 行');

      await tester.tap(find.byKey(const ValueKey('harness-notice-toggle')));
      await tester.pump();
      expect(tester.widget<SelectableText>(bodyFinder).maxLines, isNull, reason: '展开后不限行');
      expect(find.text('收起'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('harness-notice-toggle')));
      await tester.pump();
      expect(tester.widget<SelectableText>(bodyFinder).maxLines, 3);
    });

    testWidgets('没有收尾正文时不渲染正文与展开按钮', (tester) async {
      await pumpCard(
        tester,
        const HarnessNoticeCard(notice: HarnessNotice(kind: 'agent-instructions')),
      );
      expect(find.byKey(const ValueKey('harness-notice-body')), findsNothing);
      expect(find.byKey(const ValueKey('harness-notice-toggle')), findsNothing);
      expect(find.text('系统指令'), findsOneWidget);
    });
  });

  group('ChatView 集成：通知不再是蓝色用户气泡', () {
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
      await tester.pump(const Duration(seconds: 21));
    }

    testWidgets('同一条消息：通知走卡片，真人用户消息仍走气泡', (tester) async {
      VoiceInputService.instance.debugSetAvailable(false);
      final dsh = await pumpChat(tester);
      dsh.debugSetMessages([
        ChatMessage(id: 'n1', role: 'user', content: settlement),
        ChatMessage(id: 'u1', role: 'user', content: '这是我自己打的字'),
      ]);
      await tester.pump();

      // 通知：卡片在，且带"不是你说的话"这一行。
      expect(find.byKey(const ValueKey('harness-notice-card')), findsOneWidget);
      expect(find.text('引擎注入的通知（不是你说的话）'), findsOneWidget);
      expect(find.text('子代理完成'), findsOneWidget);

      // 真人消息仍然是气泡（能读到原文）。
      expect(find.text('这是我自己打的字'), findsOneWidget);
      // [v1.28 修正] 用户头像（`Icons.person_rounded`）已删除 —— 真机上它是
      // 一个实心 accent 方块，紧贴彩色气泡，既抢视觉重量又在"AI 没有头像"的
      // 对照下显得只对用户特殊。右对齐 + 填色气泡已足够区分。
      //
      // 原来这里靠"人像图标只有一个"来判断"通知没有混进用户气泡"，现在改用
      // **通知卡的标题不该出现在任何气泡里**来钉同一件事：通知卡必须自带那句
      // 免责说明，而用户气泡里只有原文。
      expect(find.byIcon(Icons.person_rounded), findsNothing,
          reason: '头像已移除，回来一个就是回归');
      expect(find.text('子代理完成'), findsOneWidget,
          reason: '同一条消息里：通知只以卡片形式出现一次');

      await teardown(tester);
    });
  });
}
