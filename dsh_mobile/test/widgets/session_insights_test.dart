import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/task_center.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';
import 'package:dsh_mobile/views/widgets/session_info_sheet.dart';
import 'package:dsh_mobile/views/widgets/session_status_strip.dart';
import 'package:dsh_mobile/views/widgets/turn_output_card.dart';

/// 会话信息架构（v1.14）的回归测试：组件 + **集成**（挂进 ChatView 之后）。
///
/// 这一轮最容易出的错不是"页面崩了"，而是**把读不到渲染成没有**：
/// "改动 0"其实是"没读出来"、"没有后台作业"其实是"网关降级了"、
/// "本轮消耗 0"其实是"取不到实时读数"。所以下面每个组件都有一组
/// 「未知 ≠ 零」的断言，且都断言的是**界面上出现了什么**。
///
/// 前四组是纯组件测试（数据靠参数传、不碰 DshService、不联网）；最后一组是
/// 集成断言（状态条挂进 AppBar、尾部卡片、面板可从状态条打开）—— 那些必须走
/// 真实的 ChatView + DshService 注入口，因为"组件对了但没挂上"正是这类重构
/// 最容易漏掉的失败模式。
///
/// 测试数据一律用**绝对路径**（REST 返回的形状），因为交付物下载路由按绝对路径
/// 做成员判定 —— 用相对路径的假数据会让测试在真实链路上失效。
void main() {
  Future<void> pump(WidgetTester tester, Widget child, {Size size = const Size(420, 900)}) async {
    tester.view.physicalSize = size;
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

  /// 集成用：真实的 ChatView + 可注入的 DshService（不联网）。
  Future<DshService> pumpChat(WidgetTester tester, {Size size = const Size(420, 900)}) async {
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
    return dsh;
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 21));
  }

  // ============================================================ 模型 =====

  group('交付物模型：轮次归属', () {
    test('解析网关回传的 time（之前漏掉的字段）', () {
      final row = DeliverableItem.fromJson(const {
        'path': 'C:/w/out/a.docx',
        'display': 'out/a.docx',
        'description': 'v1',
        'turn': 3,
        'seq': 41,
        'time': 1700000000000,
      });
      expect(row.time, 1700000000000);
      expect(row.turn, 3);
      expect(row.path, 'C:/w/out/a.docx', reason: 'path 必须是网关给的绝对路径，下载按它做成员判定');
    });

    test('缺 time 时为 null，不编 0', () {
      final row = DeliverableItem.fromJson(const {'path': '/w/a.txt', 'display': 'a.txt'});
      expect(row.time, isNull);
      expect(row.turn, isNull);
    });

    test('按轮分组：轮号大的在前，组内保持网关给的 seq 倒序', () {
      const rows = [
        DeliverableItem(path: '/w/2-b.docx', display: '2-b.docx', description: '', turn: 2, seq: 20),
        DeliverableItem(path: '/w/1-a.pdf', display: '1-a.pdf', description: '', turn: 1, seq: 10),
        DeliverableItem(path: '/w/2-a.docx', display: '2-a.docx', description: '', turn: 2, seq: 21),
      ];
      final groups = groupDeliverablesByTurn(rows);
      expect(groups.length, 2);
      expect(groups[0].turn, 2);
      expect(groups[0].items.map((e) => e.display).toList(), ['2-b.docx', '2-a.docx'],
          reason: '只分组不重排：组内顺序必须还是网关给的顺序');
      expect(groups[1].turn, 1);
      expect(groups[0].turnLabel, '第 2 轮');
    });

    test('没有轮号的记录自成一组建在最后，且不编轮号', () {
      const rows = [
        DeliverableItem(path: '/w/a', display: 'a', description: '', turn: 1),
        DeliverableItem(path: '/w/x', display: 'x', description: ''),
      ];
      final groups = groupDeliverablesByTurn(rows);
      expect(groups.length, 2);
      expect(groups.last.turn, isNull);
      expect(groups.last.turnLabel, isNull, reason: '未知轮号不能被渲染成"第 0 轮"之类');
    });

    test('最新一轮：取轮号最大的那一组；全都没有轮号时退回整份清单', () {
      const mixed = [
        DeliverableItem(path: '/w/old', display: 'old', description: '', turn: 1),
        DeliverableItem(path: '/w/new', display: 'new', description: '', turn: 2),
      ];
      expect(latestDeliverableTurn(mixed).map((e) => e.display).toList(), ['new']);

      const unnumbered = [
        DeliverableItem(path: '/w/a', display: 'a', description: ''),
        DeliverableItem(path: '/w/b', display: 'b', description: ''),
      ];
      expect(latestDeliverableTurn(unnumbered).length, 2,
          reason: '"哪一轮"无从判断时返回最近声明的清单，由界面降级文案，而不是假装同一轮');

      expect(latestDeliverableTurn(const []), isEmpty);
    });
  });

  group('用量模型：本轮消耗', () {
    const live = SessionStats(source: 'live', totalTokens: 1500);
    const cached = SessionStats(source: 'cache', totalTokens: 1500);

    test('实时读数相减得到本轮消耗', () {
      expect(SessionStats.turnDelta(baseline: 1000, now: live), 500);
      expect(SessionStats.turnDelta(baseline: 1500, now: live), 0, reason: '两次读数相同是真的没消耗，0 是合法真值');
    });

    test('取不到就返回 null —— 绝不回落成 0', () {
      expect(SessionStats.turnDelta(baseline: null, now: live), isNull);
      expect(SessionStats.turnDelta(baseline: 1000, now: null), isNull);
      expect(SessionStats.turnDelta(baseline: 1000, now: const SessionStats(source: 'live')), isNull);
      expect(SessionStats.turnDelta(baseline: 1000, now: cached), isNull,
          reason: '缓存快照可能是几小时前的，拿它做差得到的不是"本轮"');
      expect(SessionStats.turnDelta(baseline: 2000, now: live), isNull, reason: '累计值不会倒退，倒退说明读数不可信');
    });

    test('区分实时与快照', () {
      expect(live.isLive, isTrue);
      expect(live.isSnapshot, isFalse);
      expect(cached.isLive, isFalse);
      expect(cached.isSnapshot, isTrue);
      expect(const SessionStats(source: 'none').isLive, isFalse);
      expect(const SessionStats(source: 'none').isSnapshot, isFalse);
    });
  });

  // ======================================================== 状态条 =====

  group('会话状态条：未知即隐藏', () {
    testWidgets('什么都读不到时只留 1px 分隔线，不显示"产出 0 / 改动 0"', (tester) async {
      const strip = SessionStatusStrip();
      expect(strip.preferredSize.height, 1);
      await pump(tester, const SessionStatusStrip());
      expect(find.textContaining('产出'), findsNothing);
      expect(find.textContaining('改动'), findsNothing);
      expect(find.textContaining('上下文'), findsNothing);
      expect(find.byKey(const ValueKey('session-status-strip')), findsNothing);
    });

    testWidgets('已知为 0 要显示：0 是"确实没有"，与"读不到"长得不一样', (tester) async {
      const strip = SessionStatusStrip(deliverableCount: 0, changeCount: 0);
      expect(strip.preferredSize.height, 34);
      await pump(tester, const SessionStatusStrip(deliverableCount: 0, changeCount: 0));
      expect(find.text('产出 0'), findsOneWidget);
      expect(find.text('改动 0'), findsOneWidget);
    });

    testWidgets('非 git 仓库时"改动"整段隐藏（不是显示 0）', (tester) async {
      await pump(
        tester,
        const SessionStatusStrip(deliverableCount: 1, changeCount: 0, changesUnavailable: true),
      );
      expect(find.text('产出 1'), findsOneWidget);
      expect(find.textContaining('改动'), findsNothing);
    });

    testWidgets('上下文百分比 + 只在超过阈值时出现进度线', (tester) async {
      await pump(tester, const SessionStatusStrip(contextFraction: 0.62));
      expect(find.text('上下文 62%'), findsOneWidget);
      expect(find.byKey(const ValueKey('strip-context-bar')), findsNothing);

      await pump(tester, const SessionStatusStrip(contextFraction: 0.70));
      expect(find.byKey(const ValueKey('strip-context-bar')), findsNothing, reason: '阈值不包含于触发条件');

      await pump(tester, const SessionStatusStrip(contextFraction: 0.72));
      final bar = tester.widget<LinearProgressIndicator>(find.byKey(const ValueKey('strip-context-bar')));
      expect(bar.value, closeTo(0.72, 0.001));
    });

    testWidgets('缓存快照必须看得出来，不能当实时值展示', (tester) async {
      await pump(tester, const SessionStatusStrip(contextFraction: 0.5, contextIsSnapshot: true));
      expect(find.byKey(const ValueKey('strip-context-snapshot')), findsOneWidget);
      expect(find.byTooltip('会话不在内存中，这是最后一次上报的快照'), findsOneWidget);
    });

    testWidgets('后台作业：未知隐藏、0 隐藏、>0 显示', (tester) async {
      await pump(tester, const SessionStatusStrip(liveJobCount: null));
      expect(find.textContaining('运行中'), findsNothing);

      await pump(tester, const SessionStatusStrip(liveJobCount: 0));
      expect(find.textContaining('运行中'), findsNothing);

      await pump(tester, const SessionStatusStrip(liveJobCount: 2));
      expect(find.text('运行中 2'), findsOneWidget);
    });

    testWidgets('执行中徽标 + 点某一段回调对应小节', (tester) async {
      SessionInsightSection? tapped;
      await pump(
        tester,
        SessionStatusStrip(
          isRunning: true,
          deliverableCount: 3,
          contextFraction: 0.4,
          onTapSection: (s) => tapped = s,
        ),
      );
      expect(find.text('执行中'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('strip-segment-deliverables')));
      await tester.pump();
      expect(tapped, SessionInsightSection.deliverables);

      await tester.tap(find.byKey(const ValueKey('strip-segment-context')));
      await tester.pump();
      expect(tapped, SessionInsightSection.usage);
    });

    testWidgets('未读产出用强调色，读过之后回落普通色', (tester) async {
      await pump(tester, const SessionStatusStrip(deliverableCount: 2, deliverablesUnread: true));
      final unread = tester.widget<Text>(find.text('产出 2'));
      expect(unread.style?.fontWeight, FontWeight.w700);

      await pump(tester, const SessionStatusStrip(deliverableCount: 2));
      final read = tester.widget<Text>(find.text('产出 2'));
      expect(read.style?.fontWeight, FontWeight.w500);
    });
  });

  // ==================================================== 本轮产出卡片 ====

  group('本轮产出卡片', () {
    const twoTurns = [
      DeliverableItem(
        path: 'C:/w/out/new.docx',
        display: 'out/new.docx',
        description: '新稿',
        turn: 2,
        seq: 20,
        time: 1700000000000,
      ),
      DeliverableItem(path: 'C:/w/out/old.pdf', display: 'out/old.pdf', description: '旧稿', turn: 1, seq: 10),
    ];

    testWidgets('只显示最新一轮，旧轮次不进卡片', (tester) async {
      await pump(tester, const TurnOutputCard(deliverables: twoTurns));
      expect(find.text('第 2 轮产出 · 1 个文件'), findsOneWidget);
      expect(find.text('new.docx'), findsOneWidget);
      expect(find.text('新稿'), findsOneWidget);
      expect(find.text('old.pdf'), findsNothing, reason: '旧产出属于状态，去信息面板里看，不该占消息流');
    });

    testWidgets('没有轮号时降级成「最近交付」，不编轮号', (tester) async {
      await pump(tester, const TurnOutputCard(deliverables: [
        DeliverableItem(path: '/w/a.txt', display: 'a.txt', description: ''),
      ]));
      expect(find.text('最近交付 · 1 个文件'), findsOneWidget);
      expect(find.textContaining('第 0 轮'), findsNothing);
    });

    testWidgets('超过上限时给"还有 N 个 · 查看全部"，点了走面板', (tester) async {
      var showAll = 0;
      await pump(
        tester,
        TurnOutputCard(
          maxRows: 3,
          onShowAll: () => showAll++,
          deliverables: [
            for (var i = 1; i <= 6; i++)
              DeliverableItem(path: '/w/out/f$i.txt', display: 'out/f$i.txt', description: '', turn: 5, seq: i),
          ],
        ),
      );
      expect(find.text('f1.txt'), findsOneWidget);
      expect(find.text('f4.txt'), findsNothing);
      expect(find.text('还有 3 个 · 查看全部'), findsOneWidget);

      await tester.tap(find.text('还有 3 个 · 查看全部'));
      await tester.pump();
      expect(showAll, 1);
    });

    testWidgets('文件名与回退说明相同时不重复画两行', (tester) async {
      await pump(tester, const TurnOutputCard(deliverables: [
        DeliverableItem(path: '/w/out/a.txt', display: 'a.txt', description: '', turn: 1, seq: 1),
      ]));
      expect(find.text('a.txt'), findsOneWidget, reason: '同一个名字出现两遍是噪声');
    });

    testWidgets('点文件名回调的是绝对路径（相对路径会被下载路由判 403）', (tester) async {
      DeliverableItem? opened;
      await pump(tester, TurnOutputCard(deliverables: twoTurns, onOpen: (item) => opened = item));
      await tester.tap(find.text('new.docx'));
      await tester.pump();
      expect(opened?.path, 'C:/w/out/new.docx');
      expect(opened?.display, 'out/new.docx');
    });

    testWidgets('下载失败内联在卡片里（不用会自己消失的 SnackBar）', (tester) async {
      await pump(tester, const TurnOutputCard(deliverables: twoTurns, errorText: '下载失败 (HTTP 403)'));
      expect(find.byKey(const ValueKey('turn-output-error')), findsOneWidget);
      expect(find.text('下载失败 (HTTP 403)'), findsOneWidget);
    });

    testWidgets('正在下载的那一行显示转圈', (tester) async {
      await pump(tester, const TurnOutputCard(deliverables: twoTurns, busyPath: 'C:/w/out/new.docx'));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('没有交付物时不占任何空间', (tester) async {
      await pump(tester, const TurnOutputCard(deliverables: []));
      expect(find.byKey(const ValueKey('turn-output-card')), findsNothing);
    });

    test('交付物图标映射有唯一来源', () {
      expect(deliverableIconFor('docx'), Icons.description_rounded);
      expect(deliverableIconFor('xlsx'), Icons.table_chart_rounded);
      expect(deliverableIconFor('pdf'), Icons.picture_as_pdf_rounded);
      expect(deliverableIconFor('unknown'), Icons.insert_drive_file_rounded);
    });
  });

  // ====================================================== 信息面板 ====

  const deliverableRows = [
    DeliverableItem(path: 'C:/w/out/t2.docx', display: 'out/t2.docx', description: '第二轮', turn: 2, seq: 20),
    DeliverableItem(path: 'C:/w/out/t1.pdf', display: 'out/t1.pdf', description: '第一轮', turn: 1, seq: 10),
  ];

  Future<void> pumpSheet(WidgetTester tester, SessionInfoSheet sheet) =>
      pump(tester, sheet, size: const Size(420, 900));

  group('信息面板：作业"读不到"≠"没有"', () {
    testWidgets('网关降级时说明是"未知"，不能渲染成"没有后台作业"', (tester) async {
      await pumpSheet(tester, const SessionInfoSheet(jobsUnavailable: true));
      expect(find.byKey(const ValueKey('jobs-unknown')), findsOneWidget);
      expect(find.textContaining('作业状态未知'), findsOneWidget);
      expect(find.textContaining('没有后台作业'), findsNothing);
    });

    testWidgets('确实没有作业时才说"没有"', (tester) async {
      await pumpSheet(tester, const SessionInfoSheet());
      expect(find.textContaining('没有后台作业'), findsOneWidget);
      expect(find.byKey(const ValueKey('jobs-unknown')), findsNothing);
    });

    testWidgets('有作业时列出状态与标签，运行中的可以终止（要二次确认）', (tester) async {
      JobItem? killed;
      await pumpSheet(
        tester,
        SessionInfoSheet(
          jobs: const [JobItem(id: 'bash-1', kind: 'bash', label: 'npm test', status: 'running')],
          onKillJob: (job) async => killed = job,
        ),
      );
      expect(find.text('npm test'), findsOneWidget);
      expect(find.text('运行中'), findsOneWidget);

      await tester.tap(find.text('终止'));
      await tester.pump();
      expect(find.text('终止这个后台作业？'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '终止'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(killed?.id, 'bash-1');
    });
  });

  group('信息面板：用量', () {
    testWidgets('没有实时读数时本轮消耗显示「—」，绝不显示 0', (tester) async {
      await pumpSheet(
        tester,
        const SessionInfoSheet(stats: SessionStats(source: 'live', totalTokens: 1500)),
      );
      expect(find.text('本轮消耗'), findsOneWidget);
      // 两处未知都显示「—」：本轮消耗（没量到实时读数）与会话累计消耗（该 fixture
      // 只有 totalTokens、没有分桶，按"未知≠0"的规矩不能拿 totalTokens 冒充）。
      expect(find.text('—'), findsNWidgets(2));
      expect(find.text('0'), findsNothing, reason: '0 会被读成"这轮没花钱"，而真相是"不知道"');
      expect(find.textContaining('取不到实时读数时显示「—」'), findsOneWidget);
      expect(find.text('1,500'), findsNothing, reason: 'totalTokens 不是消耗，不得显示');
    });

    testWidgets('拿得到实时读数时显示本轮消耗，并做千分位', (tester) async {
      await pumpSheet(
        tester,
        const SessionInfoSheet(
          stats: SessionStats(
            source: 'live',
            totalTokens: 139500,
            uncachedInputTokens: 128000,
            outputTokens: 11500,
            pressureTokens: 64000,
            contextWindow: 128000,
          ),
          turnBurnTokens: 12345,
        ),
      );
      expect(find.text('12,345'), findsOneWidget);
      expect(find.text('139,500'), findsOneWidget, reason: '消耗 = 未缓存输入 + 输出');
      // 千分位必须同样作用在上下文那一行：以前这里是裸整数 `64000 / 128000`，
      // 而它上面一行却是分好组的，容易被读成"按 1M 算的"。
      expect(find.textContaining('上下文已用 64,000 / 128,000'), findsOneWidget);
    });

    testWidgets('缓存复用不得被算进"消耗"（用户实测 205M 的成因）', (tester) async {
      // 用户活会话的真实形状：输入 11.08M、输出 0.34M、缓存读 193.46M。
      // 旧实现把四个桶全加进 totalTokens 并当作"会话累计"显示 ⇒ 界面报出
      // 2.05 亿 token 的"消耗"，其中 94% 只是同一段上下文被反复重读。
      await pumpSheet(
        tester,
        const SessionInfoSheet(
          stats: SessionStats(
            source: 'live',
            totalTokens: 204881889,
            uncachedInputTokens: 11080549,
            outputTokens: 342002,
            cacheReadTokens: 193459338,
            cacheWriteTokens: 0,
          ),
        ),
      );

      expect(find.text('11.4M'), findsOneWidget, reason: '消耗 = 11,080,549 + 342,002 → 11.4M');
      expect(find.text('204.9M'), findsNothing, reason: '把缓存读算进去会凭空报出 200M 量级');
      expect(find.textContaining('缓存复用 193.5M'), findsOneWidget);
      expect(find.textContaining('不计入上面的消耗'), findsOneWidget);
    });

    testWidgets('一百万写成 1M（用户指定的量级口径）', (tester) async {
      await pumpSheet(
        tester,
        const SessionInfoSheet(
          stats: SessionStats(
            source: 'live',
            uncachedInputTokens: 1000000,
            outputTokens: 0,
            pressureTokens: 325000,
            contextWindow: 1000000,
          ),
        ),
      );
      // 窗口 1000000 必须写成 1M，而不是把七个 0 摊在屏幕上。
      expect(find.textContaining('/ 1M'), findsOneWidget);
      expect(find.text('1M'), findsOneWidget, reason: '消耗 1,000,000 → 1M，不是 1.0M');
      expect(find.text('1.0M'), findsNothing);
      // 不到一百万的量级保留精确值。
      expect(find.textContaining('上下文已用 325,000'), findsOneWidget);
    });

    testWidgets('不到一百万的数字不写 M（12,345 不能变成 0.0M）', (tester) async {
      await pumpSheet(
        tester,
        const SessionInfoSheet(
          stats: SessionStats(source: 'live', uncachedInputTokens: 12000, outputTokens: 400),
          turnBurnTokens: 12345,
        ),
      );
      expect(find.text('12,345'), findsOneWidget);
      expect(find.text('12,400'), findsOneWidget);
      expect(find.text('0.0M'), findsNothing);
    });

    testWidgets('分桶取不到时显示「—」，绝不用 totalTokens 冒充消耗', (tester) async {
      await pumpSheet(
        tester,
        const SessionInfoSheet(stats: SessionStats(source: 'live', totalTokens: 128000)),
      );
      expect(find.text('会话累计消耗'), findsOneWidget);
      expect(find.text('128,000'), findsNothing, reason: '只有 totalTokens 时无法得知真实消耗');
    });

    testWidgets('缓存快照与实时值给的是两种说明', (tester) async {
      await pumpSheet(
        tester,
        const SessionInfoSheet(stats: SessionStats(source: 'cache', totalTokens: 900)),
      );
      expect(find.textContaining('投影缓存快照'), findsOneWidget);

      await pumpSheet(
        tester,
        const SessionInfoSheet(stats: SessionStats(source: 'live', totalTokens: 900)),
      );
      expect(find.textContaining('提供方上报值'), findsOneWidget);
    });

    testWidgets('没跑过模型请求时说明原因，而不是一片空白', (tester) async {
      await pumpSheet(tester, const SessionInfoSheet());
      expect(find.textContaining('还没有用量记录'), findsOneWidget);
    });

    testWidgets('目标存在时显示目标与受阻原因', (tester) async {
      await pumpSheet(
        tester,
        const SessionInfoSheet(
          stats: SessionStats(
            source: 'live',
            totalTokens: 10,
            goal: GoalInfo(objective: '把 v1.13 发出去', phase: 'blocked', roundsStarted: 3, maxGoalRounds: 5, blockedReason: '等用户确认'),
          ),
        ),
      );
      expect(find.text('目标 · 受阻'), findsOneWidget);
      expect(find.text('把 v1.13 发出去'), findsOneWidget);
      expect(find.text('第 3/5 轮'), findsOneWidget);
      expect(find.text('受阻：等用户确认'), findsOneWidget);
    });
  });

  group('信息面板：本次变更', () {
    testWidgets('非 git 仓库说清原因，而不是渲染成"工作区是干净的"', (tester) async {
      await pumpSheet(
        tester,
        const SessionInfoSheet(changesAvailable: false, changesReason: 'not-a-git-repository'),
      );
      expect(find.textContaining('不是 git 仓库'), findsOneWidget);
      expect(find.textContaining('工作区是干净的'), findsNothing);
    });

    testWidgets('可用但为空时才说干净', (tester) async {
      await pumpSheet(tester, const SessionInfoSheet(changesAvailable: true));
      expect(find.textContaining('工作区是干净的'), findsOneWidget);
    });

    testWidgets('列出变更并能点开 diff', (tester) async {
      await pumpSheet(
        tester,
        SessionInfoSheet(
          changes: const [WorkspaceChange(path: 'lib/a.dart', status: 'M', added: 3, deleted: 1)],
          changesAvailable: true,
          onLoadDiff: (path) async => const [
            DiffHunk(header: '@@ -1,3 +1,4 @@', lines: [DiffLine(kind: 'add', text: '新的一行')]),
          ],
        ),
      );
      expect(find.text('lib/a.dart'), findsOneWidget);
      expect(find.text('+3 −1'), findsOneWidget);

      await tester.tap(find.text('lib/a.dart'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('@@ -1,3 +1,4 @@'), findsOneWidget);
      expect(find.text('+新的一行'), findsOneWidget);
    });
  });

  group('信息面板：交付物与定时', () {
    testWidgets('按轮分组，默认只展开最新一轮，其余折叠（可点开）', (tester) async {
      await pumpSheet(tester, const SessionInfoSheet(deliverables: deliverableRows));

      expect(find.text('第 2 轮 · 1 个文件'), findsOneWidget);
      expect(find.text('第 1 轮 · 1 个文件'), findsOneWidget);
      // 最新一轮直接铺开（不是 ExpansionTile）
      expect(tester.widget(find.byKey(const ValueKey('deliverable-group-2'))), isNot(isA<ExpansionTile>()));
      expect(find.text('t2.docx'), findsOneWidget);
      // 其余轮次是折叠的 ExpansionTile
      final older = tester.widget<ExpansionTile>(find.byKey(const ValueKey('deliverable-group-1')));
      expect(older.initiallyExpanded, isFalse);
      expect(find.text('t1.pdf'), findsNothing, reason: '折叠时子项不构建，也就不会占空间');

      // 点开后确实能看到这一轮的文件（默认折叠不等于永久隐藏）
      await tester.tap(find.text('第 1 轮 · 1 个文件'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('t1.pdf'), findsOneWidget);
    });

    testWidgets('点交付物回调完整的行（含绝对路径）', (tester) async {
      DeliverableItem? opened;
      await pumpSheet(
        tester,
        SessionInfoSheet(deliverables: deliverableRows, onOpenDeliverable: (item) => opened = item),
      );
      await tester.tap(find.text('t2.docx'));
      await tester.pump();
      expect(opened?.path, 'C:/w/out/t2.docx');
    });

    testWidgets('没有交付物时说明它何时会出现', (tester) async {
      await pumpSheet(tester, const SessionInfoSheet());
      expect(find.textContaining('还没有声明交付文件'), findsOneWidget);
    });

    testWidgets('定时任务默认折叠（它与"当前会话此刻是什么样"无关）', (tester) async {
      await pumpSheet(
        tester,
        const SessionInfoSheet(
          schedules: [ScheduleItem(id: 's1', kind: 'daily', title: '日报', prompt: '总结', schedule: '每天 09:00')],
        ),
      );
      final section = tester.widget<ExpansionTile>(find.byKey(const ValueKey('schedules-section')));
      expect(section.initiallyExpanded, isFalse);
      expect(find.text('定时任务 1'), findsOneWidget);
      expect(find.text('日报'), findsNothing, reason: '默认折叠时连子项都不构建');

      await tester.tap(find.text('定时任务 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('日报'), findsOneWidget);
      expect(find.textContaining('每天 09:00'), findsOneWidget);
    });

    testWidgets('打开面板时触发一次懒加载（作业/定时是最贵的两个请求）', (tester) async {
      var refreshes = 0;
      await pumpSheet(tester, SessionInfoSheet(onRefresh: () async => refreshes++));
      await tester.pump(const Duration(milliseconds: 100));
      expect(refreshes, 1);
    });
  });

  // =========================================== 集成：挂进 ChatView 之后 ====
  //
  // 组件对了但"没挂上"是这类重构最常见的失败模式（上一轮的教训是：功能做了、
  // 页面也在，但角标数据恒为 0）。所以这里断言的是"会话里真的出现了什么"。

  group('会话集成', () {
    Future<DshService> chatWithSession(WidgetTester tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-a', title: '测试会话'));
      await tester.pump();
      return dsh;
    }

    // ------------------------------------------------- 顶栏：工作区归属 ----
    //
    // 需求原话："我在会话界面想要看到这个会话是属于哪个工作区的"。不同工作区
    // 可以有同名会话，而从通知/深链接/搜索结果跳进来时，界面上原本完全看不出
    // 这是哪个工作区的会话。

    Workspace ws(String id, String title, List<String> sessionIds) => Workspace(
          workspaceId: id,
          title: title,
          path: 'E:\\workspace\\$title',
          sessions: [
            for (final s in sessionIds) SessionMeta(sessionId: s, title: '会话 $s'),
          ],
        );

    testWidgets('顶栏第二行显示会话所属工作区', (tester) async {
      final dsh = await chatWithSession(tester);
      dsh.debugSetWorkspaces([
        ws('w1', '个人', ['session-a']),
        ws('w2', 'GZ', ['session-z']),
      ]);
      await tester.pump();

      expect(find.text('个人'), findsOneWidget);
      expect(find.text('GZ'), findsNothing, reason: '不能把别的工作区的名字显示出来');
      await teardown(tester);
    });

    testWidgets('会话归属判定不出来时不显示任何工作区名（宁可没有，也不能显示错的）', (tester) async {
      final dsh = await chatWithSession(tester);
      // 从搜索结果/通知按 id 打开的会话可能不在任何已加载的工作区里。此时把
      // "上次选中的工作区"顶上去就是主动误导：不同工作区可以有同名会话，
      // 用户没有任何办法察觉自己看错了。
      dsh.debugSetWorkspaces([ws('w1', '个人', ['session-z'])]);
      await tester.pump();

      expect(find.text('个人'), findsNothing);
      expect(find.byIcon(Icons.folder_outlined), findsNothing);
      await teardown(tester);
    });

    testWidgets('切到另一个工作区的会话后，副标题跟着变', (tester) async {
      final dsh = await chatWithSession(tester);
      dsh.debugSetWorkspaces([ws('w1', '个人', ['session-a'])]);
      await tester.pump();
      expect(find.text('个人'), findsOneWidget);

      dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-z', title: '另一个会话'));
      dsh.debugSetWorkspaces([ws('w2', 'SZ', ['session-z'])]);
      await tester.pump();
      expect(find.text('SZ'), findsOneWidget);
      expect(find.text('个人'), findsNothing, reason: '旧工作区名不得残留');
      await teardown(tester);
    });

    testWidgets('状态条挂在 AppBar 下方，显示上下文与产出，不是一条空白带', (tester) async {
      final dsh = await chatWithSession(tester);
      dsh.debugSetTaskCenter(
        deliverables: const [
          DeliverableItem(path: '/w/out/报表.xlsx', display: 'out/报表.xlsx', description: '本月汇总'),
        ],
        deliverableEvents: 1,
        stats: const SessionStats(source: 'live', totalTokens: 1234, pressureTokens: 64000, contextWindow: 128000),
      );
      await tester.pump();

      expect(find.byType(SessionStatusStrip), findsOneWidget);
      expect(find.text('产出 1'), findsOneWidget);
      expect(find.text('上下文 50%'), findsOneWidget);
      // 位置：状态条必须在消息流上方（AppBar 之内），不能跑到别处去。
      final stripRect = tester.getRect(find.byType(SessionStatusStrip));
      final inputRect = tester.getRect(find.byKey(const ValueKey('chat-input-bar')));
      expect(stripRect.bottom, lessThan(inputRect.top));
      await teardown(tester);
    });

    testWidgets('未拉过交付物时状态条隐藏"产出"段，且不显示"产出 0"', (tester) async {
      final dsh = await chatWithSession(tester);
      // 只给用量，交付物从来没拉过（deliverablesKnown 为 null）。
      dsh.debugSetTaskCenter(stats: const SessionStats(source: 'live', totalTokens: 10));
      await tester.pump();

      expect(find.text('上下文 —%'), findsNothing);
      expect(find.textContaining('产出'), findsNothing, reason: '未拉过 = 未知，整段隐藏，不许显示 0');
      await teardown(tester);
    });

    testWidgets('真正拉到 0 个交付物时才显示"产出 0"', (tester) async {
      final dsh = await chatWithSession(tester);
      dsh.debugSetTaskCenter(deliverables: const []);
      await tester.pump();
      expect(find.text('产出 0'), findsOneWidget, reason: '0 是已知真值，与"未知"必须长得不一样');
      await teardown(tester);
    });

    testWidgets('非 git 仓库：状态条不显示"改动"（不是显示 0）', (tester) async {
      final dsh = await chatWithSession(tester);
      dsh.debugSetTaskCenter(changes: const [], changesAvailable: false, changesReason: 'not-a-git-repository');
      await tester.pump();
      expect(find.textContaining('改动'), findsNothing);
      await teardown(tester);
    });

    testWidgets('交付物事件之后：消息流尾部出现「本轮产出」卡片', (tester) async {
      final dsh = await chatWithSession(tester);
      dsh.messages.add(ChatMessage(id: 'm1', role: 'assistant', content: '做完了'));
      // 事件计数就是"刚刚交付"的信号：只给清单不给事件 = 进会话补拉到的旧产出，
      // 那属于状态，不该在消息流尾部冒充刚刚交付。
      dsh.debugSetTaskCenter(deliverables: const [
        DeliverableItem(path: '/w/out/报表.xlsx', display: 'out/报表.xlsx', description: '本月汇总'),
      ]);
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-output-card')), findsNothing,
          reason: '没有事件就不能冒充"刚刚交付"');

      dsh.debugSetTaskCenter(deliverableEvents: 1);
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-output-card')), findsOneWidget);
      expect(find.text('报表.xlsx'), findsOneWidget);

      // 用户发出下一条消息 → 卡片不再是"刚刚发生的事"，自动消失。
      dsh.messages.add(ChatMessage(id: 'm2', role: 'user', content: '再来一次'));
      dsh.debugSetTaskCenter(deliverableEvents: 1);
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-output-card')), findsNothing);
      await teardown(tester);
    });

    testWidgets('点状态条那一段能从会话里打开信息面板（不留二级页面）', (tester) async {
      final dsh = await chatWithSession(tester);
      dsh.debugSetTaskCenter(
        deliverables: const [
          DeliverableItem(path: '/w/out/报表.xlsx', display: 'out/报表.xlsx', description: '本月汇总'),
        ],
        changes: const [WorkspaceChange(path: 'src/a.ts', status: 'M', added: 3, deleted: 1)],
        changesAvailable: true,
        schedules: const [ScheduleItem(id: 's1', kind: 'daily', title: '日报', prompt: '总结', schedule: '每天 09:00')],
        jobs: const [JobItem(id: 'bash-1', kind: 'bash', label: 'npm test', status: 'running')],
        stats: const SessionStats(source: 'live', totalTokens: 1234),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('strip-segment-deliverables')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(SessionInfoSheet), findsOneWidget);
      expect(find.text('会话信息'), findsOneWidget);
      expect(find.text('报表.xlsx'), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('jobsDegraded 非空：面板说"作业状态未知"，不说"没有后台作业"', (tester) async {
      final dsh = await chatWithSession(tester);
      // 网关在取不到 job/list 帧时会回 degraded:'jobs-unavailable' —— 这是"读不到"。
      // 同时给一个已知为 0 的产出段，让状态条有可点的那一段（面板入口就是它）。
      dsh.debugSetTaskCenter(deliverables: const [], jobs: const [], jobsDegraded: 'jobs-unavailable');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('strip-segment-deliverables')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(SessionInfoSheet), findsOneWidget);
      expect(find.byKey(const ValueKey('jobs-unknown')), findsOneWidget);
      expect(find.textContaining('作业状态未知'), findsOneWidget);
      expect(find.textContaining('没有后台作业'), findsNothing);
      await teardown(tester);
    });

    testWidgets('上下文 ≥85% 时输入框上方出现告警，且只有实时读数才触发', (tester) async {
      final dsh = await chatWithSession(tester);
      // 缓存快照：不拿来催用户做不可逆的决定。
      dsh.debugSetTaskCenter(
        stats: const SessionStats(source: 'cache', totalTokens: 10, pressureTokens: 120000, contextWindow: 128000),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('context-pressure-row')), findsNothing);

      dsh.debugSetTaskCenter(
        stats: const SessionStats(source: 'live', totalTokens: 10, pressureTokens: 120000, contextWindow: 128000),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('context-pressure-row')), findsOneWidget);
      expect(find.textContaining('上下文已用 94%'), findsOneWidget);

      // 低于阈值一行都不占。
      dsh.debugSetTaskCenter(
        stats: const SessionStats(source: 'live', totalTokens: 10, pressureTokens: 64000, contextWindow: 128000),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('context-pressure-row')), findsNothing);
      await teardown(tester);
    });

    testWidgets('一轮结束后的消耗显示真值；没量到就显示「—」，绝不显示 0', (tester) async {
      final dsh = await chatWithSession(tester);
      dsh.debugSetTaskCenter(
        deliverables: const [],
        stats: const SessionStats(source: 'live', totalTokens: 1500),
        // ⚠️ 这一行就是"陷阱现场"：基线等于当前读数，正是"在 done 那一帧就地设基线"
        // 会造成的状态 —— 朴素实现（直接相减）在这里会显示 0，被用户读成"这轮没花钱"。
        statsBaselineTokens: 1500,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('strip-segment-deliverables')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SessionInfoSheet), findsOneWidget);
      expect(find.text('本轮消耗'), findsOneWidget);
      expect(find.text('—'), findsWidgets, reason: '没量到本轮消耗时必须显示「—」');
      expect(find.text('0'), findsNothing, reason: '0 会被读成"这轮没花钱"，而真相是"不知道"');

      // 量到了就显示真值（含千分位）。
      dsh.debugSetTaskCenter(measuredTurnTokens: 12345);
      await tester.pump();
      expect(find.text('12,345'), findsOneWidget);
      await teardown(tester);
    });
  });

  // ================================== 服务层：本轮消耗绝不编 0 ==========
  //
  // 这一组盯的是一个具体陷阱：`tokenUsage` 是**单调累计**值，如果在 `done` 那一帧
  // 直接把它设成基线，紧接着相减就是 `total - total = 0`。服务层必须把"回合终值
  // 还没量到"表达成**未知**，而不是把这个 0 交给界面（0 会被读成"这轮没花钱"）。

  group('服务层：本轮消耗', () {
    test('基线等于当前读数时 lastTurnTokens 是 null，不是 0', () {
      const stats = SessionStats(source: 'live', totalTokens: 1500);
      // 模型层确实会算出 0 —— 这正是"在 done 那一帧就地设基线"会踩的坑。
      expect(SessionStats.turnDelta(baseline: 1500, now: stats), 0);

      final dsh = DshService();
      dsh.debugSetTaskCenter(stats: stats, statsBaselineTokens: 1500);
      expect(dsh.lastTurnTokens, isNull,
          reason: '回合终值还没量到 = 未知，必须显示「—」；显示 0 会让用户以为这轮没花钱');
    });

    test('量到终值才给数字；0 与"没量到"一律按未知处理', () {
      final dsh = DshService();
      dsh.debugSetTaskCenter(
        stats: const SessionStats(source: 'live', totalTokens: 1500),
        measuredTurnTokens: 500,
      );
      expect(dsh.lastTurnTokens, 500);

      dsh.debugSetTaskCenter(measuredTurnTokens: 0);
      expect(dsh.lastTurnTokens, isNull, reason: '0 与"没量到"在界面上无法区分，按未知处理');
    });

    test('缓存快照与读数倒退都不算数：相减出来的不是"本轮"', () {
      // source=='cache' = 会话不在内存里，数值是最后一次上报的快照（可能几小时前）。
      expect(
        SessionStats.turnDelta(baseline: 1000, now: const SessionStats(source: 'cache', totalTokens: 2000)),
        isNull,
      );
      // 累计值不会倒退；倒退说明读数不可信。
      expect(
        SessionStats.turnDelta(baseline: 2000, now: const SessionStats(source: 'live', totalTokens: 1500)),
        isNull,
      );
    });
  });
}
