import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/pending_attachment.dart';
import 'package:dsh_mobile/models/task_center.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';

/// 运行中投递的语义测试（v1.14）：**默认排队 + 二次确认才插话**。
///
/// 用户定的语义（不是待讨论项）：
///   * 会话进行中发消息 → 默认排队，等当前回合跑完自动发送；
///   * 要立刻插进正在跑的回合 → 必须在队列条目上**再点一次**确认。
///
/// 全部用 `debugSetDeliverResult` / `debugSetQueueActionResult` 注入返回值，
/// **一次网络都不打**：否则这些用例会往用户的真实会话里塞消息（历史教训）。
/// 注入为 null 时程序走真实 HTTP 路径，那两个口子只影响测试。
void main() {
  Future<DshService> pump(WidgetTester tester, {Size size = const Size(420, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dsh = DshService();
    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: MaterialApp(
          builder: (ctx, c) => ThemeScope(isDark: false, child: c ?? const SizedBox()),
          home: const ChatView(),
        ),
      ),
    );
    await tester.pump();
    // 发送前 `_sendMessage` 会检查连接状态；测试环境没有真实网关，必须显式摆成
    // 已连接，否则它会走"网络已断开"的提示分支、根本到不了投递那一步。
    dsh.debugSetConnection(true);
    await tester.pump();
    return dsh;
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 21));
  }

  dynamic stateOf(WidgetTester tester) => tester.state(find.byType(ChatView)) as dynamic;

  Finder sendKey() => find.byKey(const ValueKey('chat-send-button'));
  Finder stopKey() => find.byKey(const ValueKey('chat-stop-button'));
  Finder field() => find.byKey(const ValueKey('chat-input-field'));

  /// 打字 → 点发送 → 让注入后立即完成的异步投递落地。
  Future<void> sendText(WidgetTester tester, String text) async {
    await tester.enterText(field(), text);
    await tester.pump();
    await tester.tap(sendKey());
    await tester.pump();
    await tester.pump();
  }

  group('默认排队：运行中发送没有第二含义', () {
    testWidgets('运行中发送恒为排队，且界面上不存在"排队/插话"开关', (tester) async {
      final dsh = await pump(tester);
      dsh.debugSetRunning(true);
      dsh.debugSetDeliverResult(true, appendsRow: const QueueItem(id: 'q-new', text: '这条排上了', attachments: 0));
      await tester.pump();

      await sendText(tester, '这条排上了');

      expect(stateOf(tester).debugNoticeText, contains('已排队'));
      // 旧版那枚常驻开关（「排队」/「插话」胶囊）必须彻底消失：一个能被记住的
      // 开关会让"默认"在下次变成插话。
      expect(find.text('排队'), findsNothing);
      expect(find.text('插话'), findsNothing);
      // 运行中不插本地乐观气泡：正文只在队列里，不在消息流里。
      expect(dsh.messages, isEmpty);
      await teardown(tester);
    });

    testWidgets('回执条上的「撤回」把刚排进去的那一条从队列删掉', (tester) async {
      final dsh = await pump(tester);
      dsh.debugSetRunning(true);
      dsh.debugSetQueue([const QueueItem(id: 'm1', text: '先来的', attachments: 0)]);
      dsh.debugSetDeliverResult(true, appendsRow: const QueueItem(id: 'q-new', text: '我这条', attachments: 0));
      dsh.debugSetQueueActionResult(QueueActionOutcome.applied);
      await tester.pump();

      await sendText(tester, '我这条');
      expect(find.text('撤回'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chat-notice-action')));
      await tester.pump();
      await tester.pump();

      // 撤回是安全方向：一次点击即生效，不需要二次确认。
      expect(dsh.debugLastQueueAction, 'remove:q-new');
      expect(stateOf(tester).debugNoticeText, '已撤回');
      await teardown(tester);
    });

    testWidgets('排队失败：正文与附件回到输入框，提示条变失败态并带「重试」', (tester) async {
      final dsh = await pump(tester);
      dsh.debugSetRunning(true);
      dsh.debugSetDeliverResult(false);
      await tester.pump();

      await sendText(tester, '这段字不能丢');

      expect(find.text('这段字不能丢'), findsOneWidget, reason: '失败必须把正文放回输入框');
      expect(stateOf(tester).debugNoticeText, contains('排队失败'));
      expect(find.text('重试'), findsOneWidget);
      await teardown(tester);
    });
  });

  group('发送键与停止键彻底分家', () {
    testWidgets('运行中空输入框：两个按钮同时存在，且不在同一位置', (tester) async {
      final dsh = await pump(tester);
      dsh.debugSetRunning(true);
      await tester.pump();

      expect(sendKey(), findsOneWidget);
      expect(stopKey(), findsOneWidget);
      // 停止在最左、发送在最右：位置不同 → "清空输入框"不会再改变任何按钮的含义。
      expect(tester.getCenter(stopKey()).dx, lessThan(tester.getCenter(sendKey()).dx));
      await teardown(tester);
    });

    testWidgets('敲字不会让停止键消失（停止键不再承担两种含义）', (tester) async {
      final dsh = await pump(tester);
      dsh.debugSetRunning(true);
      await tester.pump();
      expect(stopKey(), findsOneWidget);

      await tester.enterText(field(), '半句话');
      await tester.pump();

      // 旧版：敲字之后停止键被发送键顶掉，"停止"这个意图就找不到了。
      expect(stopKey(), findsOneWidget);
      expect(sendKey(), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('点发送位置是"排队"，绝不会变成"取消本轮"', (tester) async {
      final dsh = await pump(tester);
      dsh.debugSetRunning(true);
      dsh.debugSetDeliverResult(true);
      await tester.pump();

      await sendText(tester, '接着说');

      expect(dsh.isCanceling, isFalse, reason: '点发送位置不该取消回合');
      expect(dsh.isSending, isTrue, reason: '回合仍在跑（只是多了一条排队的消息）');
      await teardown(tester);
    });

    testWidgets('旁观别人发起的回合时不给停止键（否则手机会停掉电脑端的活）', (tester) async {
      final dsh = await pump(tester);
      dsh.debugSetRunning(false); // 本机没在发
      dsh.debugSetCurrentSession(SessionMeta(sessionId: 's-remote', title: '电脑端在跑', isRunning: true));
      await tester.pump();

      expect(find.textContaining('本轮执行中'), findsOneWidget, reason: '会话确实在跑');
      expect(stopKey(), findsNothing, reason: '不是本机发起的回合，不该提供停止键');
      await teardown(tester);
    });
  });

  group('切会话不会在用户没输入的情况下改变按钮语义（误取消回归）', () {
    testWidgets('切走再切回：正文按会话各归各位，发送仍是排队而不是取消', (tester) async {
      final dsh = await pump(tester);
      dsh.drafts.clear('t2-a');
      dsh.drafts.clear('t2-b');
      dsh.debugSetRunning(true);
      dsh.debugSetDeliverResult(true);
      dsh.debugSetCurrentSession(SessionMeta(sessionId: 't2-a', title: 'A'));
      await tester.pump();

      await tester.enterText(field(), '写在 A 里的字');
      await tester.pump();
      final sendBefore = tester.getRect(sendKey());
      final stopBefore = tester.getRect(stopKey());

      // 切到 B（B 自己有草稿）→ ChatView 的会话切换分支会跑。
      dsh.drafts.write('t2-b', 'B 的草稿');
      dsh.debugSetCurrentSession(SessionMeta(sessionId: 't2-b', title: 'B'));
      await tester.pump();

      // 1) 不串味：A 的字回到 A 的槽位，输入框显示的是 B 自己的草稿。
      expect(dsh.drafts.read('t2-a'), '写在 A 里的字');
      expect(find.text('B 的草稿'), findsOneWidget);
      // 2) 两个按钮的位置和含义都没变。
      expect(tester.getRect(sendKey()), sendBefore);
      expect(tester.getRect(stopKey()), stopBefore);
      // 3) 在发送键的位置点下去 = 排队，不是取消本轮。
      await sendText(tester, 'B 里的新话');
      expect(dsh.isCanceling, isFalse);
      expect(stateOf(tester).debugNoticeText, contains('已排队'));
      await teardown(tester);
    });

    testWidgets('首次进入会话不会清掉它已存的草稿', (tester) async {
      final dsh = await pump(tester);
      dsh.drafts.write('t2-c', '差点丢掉的半句话');

      dsh.debugSetCurrentSession(SessionMeta(sessionId: 't2-c', title: 'C'));
      await tester.pump();

      // 旧代码在首次进入时会 `updateDraft('')`（键=当前会话），等于把这条草稿
      // 用空串清掉：用户回来发现写了半天的东西没了。
      expect(find.text('差点丢掉的半句话'), findsOneWidget);
      expect(dsh.drafts.read('t2-c'), '差点丢掉的半句话');
      await teardown(tester);
    });
  });

  group('立即插话：只有在队列条目上，且必须再点一次', () {
    testWidgets('运行中说明行只在会话跑着时出现', (tester) async {
      final dsh = await pump(tester);
      dsh.debugSetRunning(false);
      await tester.pump();
      expect(find.textContaining('本轮执行中'), findsNothing);

      dsh.debugSetRunning(true);
      await tester.pump();
      expect(find.textContaining('本轮执行中 · 你发的消息会在本轮结束后自动发送'), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('第一次点击只进入待确认态：文案变化、且一次网关都没打', (tester) async {
      final dsh = await pump(tester);
      dsh.debugSetRunning(true);
      dsh.debugSetQueue([const QueueItem(id: 'm1', text: '这条想插队', attachments: 0)]);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('queue-steer-m1')));
      await tester.pump();

      expect(stateOf(tester).debugArmedSteerItemId, 'm1');
      expect(find.text('确认插话？'), findsOneWidget);
      expect(find.text('立即插话'), findsNothing);
      // 文案不许写"打断本轮"：引擎是 agent.steer()，插进最近的步骤、不取消本轮。
      expect(find.text('会插进当前步骤，本轮不会重来'), findsOneWidget);
      expect(dsh.debugLastQueueAction, isEmpty, reason: '第一次点击不该调用任何动作');
      expect(dsh.queueItems.length, 1, reason: '条目仍在队列里');
      await teardown(tester);
    });

    testWidgets('第二次点击才真正插话', (tester) async {
      final dsh = await pump(tester);
      dsh.debugSetRunning(true);
      dsh.debugSetQueue([const QueueItem(id: 'm1', text: '这条想插队', attachments: 0)]);
      dsh.debugSetQueueActionResult(QueueActionOutcome.applied);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('queue-steer-m1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('queue-steer-m1')));
      await tester.pump();
      await tester.pump();

      expect(dsh.debugLastQueueAction, 'steer:m1');
      expect(stateOf(tester).debugArmedSteerItemId, isNull);
      expect(stateOf(tester).debugNoticeText, '已插话发送');
      await teardown(tester);
    });

    testWidgets('待确认态 2.5 秒后自动还原（不产生任何副作用）', (tester) async {
      final dsh = await pump(tester);
      dsh.debugSetRunning(true);
      dsh.debugSetQueue([const QueueItem(id: 'm1', text: '这条想插队', attachments: 0)]);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('queue-steer-m1')));
      await tester.pump();
      expect(find.text('确认插话？'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));

      expect(find.text('立即插话'), findsOneWidget);
      expect(stateOf(tester).debugArmedSteerItemId, isNull);
      expect(dsh.debugLastQueueAction, isEmpty, reason: '超时还原不该执行插话');
      await teardown(tester);
    });

    testWidgets('条目已被引擎领走：静默收敛，不报红错', (tester) async {
      final dsh = await pump(tester);
      dsh.debugSetRunning(true);
      dsh.debugSetQueue([const QueueItem(id: 'm1', text: '这条想插队', attachments: 0)]);
      dsh.debugSetQueueActionResult(QueueActionOutcome.alreadyGone);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('queue-steer-m1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('queue-steer-m1')));
      await tester.pump();
      await tester.pump();

      expect(stateOf(tester).debugNoticeText, '这条已经发出去了');
      expect(find.textContaining('失败'), findsNothing, reason: '正常时序不该报错');
      await teardown(tester);
    });

    testWidgets('真正的失败：条目留着并说明原因', (tester) async {
      final dsh = await pump(tester);
      dsh.debugSetRunning(true);
      dsh.debugSetQueue(
        [const QueueItem(id: 'm1', text: '这条想插队', attachments: 0)],
        error: '操作失败: boom',
      );
      dsh.debugSetQueueActionResult(QueueActionOutcome.failed);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('queue-steer-m1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('queue-steer-m1')));
      await tester.pump();
      await tester.pump();

      expect(stateOf(tester).debugNoticeText, '操作失败: boom');
      expect(find.text('这条想插队'), findsOneWidget, reason: '失败时条目必须留在队列里');
      await teardown(tester);
    });

    testWidgets('队列条目上的「编辑 / 删除」触摸区不小于 36dp（旧版只有 24dp，紧贴插话）', (tester) async {
      final dsh = await pump(tester);
      dsh.debugSetRunning(true);
      dsh.debugSetQueue([const QueueItem(id: 'm1', text: '这条', attachments: 0)]);
      await tester.pump();

      for (final id in ['queue-edit-m1', 'queue-remove-m1']) {
        final size = tester.getSize(find.byKey(ValueKey(id)));
        expect(size.width, greaterThanOrEqualTo(36.0), reason: '$id 的触摸区太小');
        expect(size.height, greaterThanOrEqualTo(36.0), reason: '$id 的触摸区太小');
      }
      // 删除与插话之间必须留出间距：旧版两键中心距 28px，误触会插队。
      final remove = tester.getCenter(find.byKey(const ValueKey('queue-remove-m1')));
      final steer = tester.getCenter(find.byKey(const ValueKey('queue-steer-m1')));
      expect((remove - steer).distance, greaterThan(28.0));
      await teardown(tester);
    });
  });

  group('小屏下的空间', () {
    testWidgets('360×640 + 3 条队列 + 2 个附件：不溢出，输入框仍可用', (tester) async {
      final dsh = await pump(tester, size: const Size(360, 640));
      dsh.debugSetRunning(true);
      dsh.debugSetQueue([
        for (var i = 1; i <= 3; i++) QueueItem(id: 'm$i', text: '排队第 $i 条，稍微长一点的正文内容', attachments: 0),
      ]);
      await tester.pump();
      stateOf(tester).debugAddPendingAttachment(
        const PendingFile(localId: 'f1', name: 'a.txt', byteLength: 8, receiptId: 'r1'),
      );
      stateOf(tester).debugAddPendingAttachment(
        const PendingFile(localId: 'f2', name: 'b.txt', byteLength: 8, receiptId: 'r2'),
      );
      await tester.pump();

      expect(tester.takeException(), isNull, reason: '不该溢出');
      await tester.enterText(field(), '还能打字');
      await tester.pump();
      expect(find.text('还能打字'), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('队列读不到（路由被吞）时，说明"状态未知"而不是渲染成空队列', (tester) async {
      final dsh = await pump(tester);
      // 生产上 GET /api/mobile/sessions/queue 曾被通配路由当成 getSessionHistory("queue")，
      // 响应里没有 queue 字段。旧代码 `?? []` 把它静默当成"没有排队消息"。
      dsh.debugSetQueue(const [], known: false);
      await tester.pump();

      expect(find.text('队列状态未知'), findsOneWidget);
      await teardown(tester);
    });
  });
}
