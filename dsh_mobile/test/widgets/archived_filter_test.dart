import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/views/workspaces_view.dart';

/// 会话归档筛选（§4 新增需求）的 **UI 层** 验收。
///
/// 这里刻意数「实际渲染出来的行数」，而不是数 service 里的数据条数。两者之间
/// 还隔着搜索过滤、工作区分组与空白会话过滤 —— 只断言数据层会得出假的通过结论
/// （真实案例：服务端返回 572 条，侧边栏只渲染 10 行，差 57 倍）。
///
/// 全程离线：DshService 没有 config 时 fetchWorkspaces()/fetchApprovals() 都会
/// 立即返回，不发任何网络请求。
void main() {
  SessionMeta session(String id, String title, {bool archived = false}) => SessionMeta(
        sessionId: id,
        title: title,
        archived: archived,
        lastPromptAt: 1700000000000,
      );

  Workspace ws({
    String id = 'ws-a',
    String title = '工作区A',
    int archivedCount = 0,
    List<SessionMeta>? sessions,
  }) =>
      Workspace(
        workspaceId: id,
        title: title,
        path: 'E:\\ws\\a',
        archivedCount: archivedCount,
        sessions: sessions ?? [],
      );

  /// 把视口撑大，确保内层 shrinkWrap ListView 把所有行都布局出来。
  /// 否则「渲染行数」会变成「首屏行数」，测试就测不到东西了。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 展开所有工作区分组。
  ///
  /// 卡片是 `ExpansionTile(initiallyExpanded: isCurrent)`，而测试里
  /// `currentWorkspace` 为 null，所以默认**全部折叠** —— 会话行根本不会被布局。
  /// 不先展开就去数行数，会稳定得到 0，然后误判成「功能没生效」。
  ///
  /// 用固定时长的 pump 而不是 pumpAndSettle：运行中的会话带
  /// CircularProgressIndicator（无限动画），pumpAndSettle 会一直等到超时。
  ///
  /// 必须声明在 pumpView 之前：Dart 的局部函数不允许前向引用。
  Future<void> expandAllWorkspaces(WidgetTester tester) async {
    final tiles = find.byType(ExpansionTile);
    final n = tester.widgetList(tiles).length;
    for (var i = 0; i < n; i++) {
      await tester.tap(tiles.at(i), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }
  }

  Future<T> pumpView<T extends DshService>(
    WidgetTester tester,
    T dsh, {
    required List<Workspace> workspaces,
    required String mode,
    required bool supported,
  }) async {
    dsh.debugSetWorkspaces(workspaces, archivedFilter: mode, archivedFilterSupported: supported);
    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: const MaterialApp(home: WorkspacesView(active: true)),
      ),
    );
    await tester.pump();
    await expandAllWorkspaces(tester);
    return dsh;
  }

  /// exclude 模式会启动 3 秒 Timer.periodic；不销毁 widget 树的话，testWidgets
  /// 结束时会因「A Timer is still pending」而失败。
  Future<void> teardownView(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  /// 数出真正渲染出来的会话行（按标题文本找）。
  int renderedSessionRows(WidgetTester tester, List<String> titles) =>
      titles.where((t) => tester.widgetList(find.text(t)).isNotEmpty).length;

  group('筛选器本身', () {
    testWidgets('三片都渲染，且「已归档」片带上与模式无关的准确总数', (tester) async {
      useTallViewport(tester);
      // archivedCount 是工作区级、跨模式恒定的，所以即使当前在 exclude 视图，
      // 也应能看到「已归档 · 5」。
      await pumpView(
        tester,
        DshService(),
        workspaces: [
          ws(id: 'a', title: 'A区', archivedCount: 3, sessions: [session('l1', '活跃一')]),
          ws(id: 'b', title: 'B区', archivedCount: 2, sessions: [session('l2', '活跃二')]),
        ],
        mode: 'exclude',
        supported: true,
      );

      expect(find.text('未归档'), findsOneWidget);
      expect(find.text('已归档 · 5'), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);

      await teardownView(tester);
    });

    testWidgets('archivedCount 为 0 时不显示「· 0」', (tester) async {
      useTallViewport(tester);
      await pumpView(
        tester,
        DshService(),
        workspaces: [ws(archivedCount: 0, sessions: [session('l1', '活跃一')])],
        mode: 'exclude',
        supported: true,
      );

      expect(find.text('已归档'), findsOneWidget);
      expect(find.textContaining('已归档 ·'), findsNothing);

      await teardownView(tester);
    });

    testWidgets('点击「已归档」会把 only 传给 setArchivedFilter', (tester) async {
      useTallViewport(tester);
      final svc = _RecordingService();
      await pumpView(
        tester,
        svc,
        workspaces: [ws(archivedCount: 4, sessions: [session('l1', '活跃一')])],
        mode: 'exclude',
        supported: true,
      );

      await tester.tap(find.text('已归档 · 4'));
      await tester.pump();

      expect(svc.requested, ['only']);

      await tester.tap(find.text('全部'));
      await tester.pump();
      expect(svc.requested, ['only', 'include']);

      await teardownView(tester);
    });
  });

  group('实际渲染的会话行', () {
    testWidgets('exclude 模式只渲染未归档行', (tester) async {
      useTallViewport(tester);
      await pumpView(
        tester,
        DshService(),
        workspaces: [
          ws(archivedCount: 2, sessions: [
            session('l1', '活跃一'),
            session('l2', '活跃二'),
          ]),
        ],
        mode: 'exclude',
        supported: true,
      );

      expect(renderedSessionRows(tester, ['活跃一', '活跃二', '归档一', '归档二']), 2);
      expect(find.text('活跃一'), findsOneWidget);
      expect(find.text('归档一'), findsNothing);

      await teardownView(tester);
    });

    testWidgets('only 模式渲染全部已归档行（网关已过滤，客户端不再二次过滤）', (tester) async {
      useTallViewport(tester);
      final titles = List.generate(12, (i) => '归档$i');
      await pumpView(
        tester,
        DshService(),
        workspaces: [
          ws(archivedCount: 12, sessions: [for (var i = 0; i < 12; i++) session('a$i', '归档$i', archived: true)]),
        ],
        mode: 'only',
        supported: true,
      );

      expect(renderedSessionRows(tester, titles), 12,
          reason: '注入 12 条归档会话，UI 必须真的渲染出 12 行');

      await teardownView(tester);
    });

    testWidgets('include 模式两类都渲染，且归档行带「已归档」徽章', (tester) async {
      useTallViewport(tester);
      await pumpView(
        tester,
        DshService(),
        workspaces: [
          ws(archivedCount: 2, sessions: [
            session('l1', '活跃一'),
            session('a1', '归档一', archived: true),
            session('a2', '归档二', archived: true),
          ]),
        ],
        mode: 'include',
        supported: true,
      );

      expect(renderedSessionRows(tester, ['活跃一', '归档一', '归档二']), 3);
      // 两条归档行 → 两个徽章。
      expect(find.text('已归档'), findsNWidgets(2));

      await teardownView(tester);
    });

    testWidgets('only 模式不给每行挂徽章（1338 行全是徽章等于没有信息）', (tester) async {
      useTallViewport(tester);
      await pumpView(
        tester,
        DshService(),
        workspaces: [
          ws(archivedCount: 3, sessions: [
            session('a1', '归档一', archived: true),
            session('a2', '归档二', archived: true),
          ]),
        ],
        mode: 'only',
        supported: true,
      );

      expect(renderedSessionRows(tester, ['归档一', '归档二']), 2);
      // 筛选器上那个「已归档 · 3」是 ChoiceChip 的标签，不是行内徽章。
      expect(find.text('已归档'), findsNothing,
          reason: '行内徽章只在 include 模式出现');

      await teardownView(tester);
    });

    testWidgets('归档会话的标题原样渲染，不退化成 session id', (tester) async {
      useTallViewport(tester);
      await pumpView(
        tester,
        DshService(),
        workspaces: [
          ws(archivedCount: 1, sessions: [
            session('session-7f3a9c21', '重构登录模块', archived: true),
          ]),
        ],
        mode: 'only',
        supported: true,
      );

      expect(find.text('重构登录模块'), findsOneWidget);
      expect(find.textContaining('7f3a9c21'), findsNothing);

      await teardownView(tester);
    });

    testWidgets('only 模式下空工作区说「没有已归档的会话」而不是「暂无会话」', (tester) async {
      useTallViewport(tester);
      await pumpView(
        tester,
        DshService(),
        workspaces: [ws(id: 'gz', title: 'GZ', archivedCount: 0, sessions: [])],
        mode: 'only',
        supported: true,
      );

      expect(find.text('此工作区没有已归档的会话'), findsOneWidget);
      expect(find.text('此工作区暂无会话'), findsNothing);

      await teardownView(tester);
    });

    testWidgets('exclude 模式下空工作区仍说「暂无会话」', (tester) async {
      useTallViewport(tester);
      await pumpView(tester, DshService(),
          workspaces: [ws(sessions: [])], mode: 'exclude', supported: true);

      expect(find.text('此工作区暂无会话'), findsOneWidget);

      await teardownView(tester);
    });
  });

  group('B5 能力探测降级：绝不把未归档会话标成已归档', () {
    const noticeFragment = '网关没有回显归档筛选模式';

    testWidgets('旧网关 + 默认模式 → 完全不显示提示（零噪音）', (tester) async {
      useTallViewport(tester);
      await pumpView(
        tester,
        DshService(),
        workspaces: [ws(sessions: [session('l1', '活跃一')])],
        mode: 'exclude',
        supported: false,
      );

      expect(find.textContaining(noticeFragment), findsNothing);
      expect(find.text('活跃一'), findsOneWidget);

      await teardownView(tester);
    });

    testWidgets('旧网关 + only 模式 → 显示提示，并明说列出的不是已归档内容', (tester) async {
      useTallViewport(tester);
      // 模拟旧网关：忽略了 ?archived=only，返回的仍是未归档会话。
      await pumpView(
        tester,
        DshService(),
        workspaces: [ws(sessions: [session('l1', '活跃一')])],
        mode: 'only',
        supported: false,
      );

      expect(find.textContaining(noticeFragment), findsOneWidget);
      expect(find.textContaining('返回的还是未归档会话'), findsOneWidget);
      expect(find.textContaining('下面列出的并不是已归档内容'), findsOneWidget);
      expect(find.textContaining('重启 dsh web'), findsOneWidget);

      await teardownView(tester);
    });

    testWidgets('新网关 + only 模式 → 不显示提示', (tester) async {
      useTallViewport(tester);
      await pumpView(
        tester,
        DshService(),
        workspaces: [
          ws(archivedCount: 1, sessions: [session('a1', '归档一', archived: true)]),
        ],
        mode: 'only',
        supported: true,
      );

      expect(find.textContaining(noticeFragment), findsNothing);
      expect(find.text('归档一'), findsOneWidget);

      await teardownView(tester);
    });

    testWidgets('新网关 + include 模式 → 不显示提示', (tester) async {
      useTallViewport(tester);
      await pumpView(
        tester,
        DshService(),
        workspaces: [ws(archivedCount: 1, sessions: [session('l1', '活跃一')])],
        mode: 'include',
        supported: true,
      );

      expect(find.textContaining(noticeFragment), findsNothing);

      await teardownView(tester);
    });
  });

  group('折叠卡片头的计数文案（不点开也能看懂）', () {
    testWidgets('exclude 模式：共 N 个历史对话', (tester) async {
      useTallViewport(tester);
      await pumpView(
        tester,
        DshService(),
        workspaces: [ws(archivedCount: 9, sessions: [session('l1', '活跃一'), session('l2', '活跃二')])],
        mode: 'exclude',
        supported: true,
      );
      expect(find.text('共 2 个历史对话'), findsOneWidget);
      await teardownView(tester);
    });

    testWidgets('only 模式：共 N 个已归档对话', (tester) async {
      useTallViewport(tester);
      await pumpView(
        tester,
        DshService(),
        workspaces: [
          ws(archivedCount: 1275, sessions: [for (var i = 0; i < 3; i++) session('a$i', '归档$i', archived: true)]),
        ],
        mode: 'only',
        supported: true,
      );
      expect(find.text('共 3 个已归档对话'), findsOneWidget);
      expect(find.textContaining('个历史对话'), findsNothing);
      await teardownView(tester);
    });

    testWidgets('include 模式：共 N 个对话（含已归档）', (tester) async {
      useTallViewport(tester);
      await pumpView(
        tester,
        DshService(),
        workspaces: [
          ws(archivedCount: 4, sessions: [
            session('l1', '活跃一'),
            session('a1', '归档一', archived: true),
          ]),
        ],
        mode: 'include',
        supported: true,
      );
      expect(find.text('共 2 个对话（含已归档）'), findsOneWidget);
      await teardownView(tester);
    });
  });

  group('B4 归档模式暂停 3 秒轮询', () {
    testWidgets('exclude 模式：轮询确实在跑', (tester) async {
      useTallViewport(tester);
      final svc = _RecordingService();
      await pumpView(
        tester,
        svc,
        workspaces: [ws(sessions: [session('l1', '活跃一')])],
        mode: 'exclude',
        supported: true,
      );
      // initState 的 postFrame 已经拉过一次。
      final baseline = svc.fetchCount;
      expect(baseline, greaterThanOrEqualTo(1));

      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      expect(svc.fetchCount, greaterThanOrEqualTo(baseline + 2),
          reason: '未归档视图必须保留 3 秒轮询，否则运行中动画与审批角标会停更');

      await teardownView(tester);
    });

    testWidgets('only 模式：轮询停掉，不再反复重传大响应', (tester) async {
      useTallViewport(tester);
      final svc = _RecordingService();
      await pumpView(
        tester,
        svc,
        workspaces: [
          ws(archivedCount: 1338, sessions: [session('a1', '归档一', archived: true)]),
        ],
        mode: 'only',
        supported: true,
      );
      final baseline = svc.fetchCount;

      // 推进 15 秒 = 5 个轮询周期。若计时器还在跑，这里至少会多 5 次调用。
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 3));
      }
      expect(svc.fetchCount, baseline,
          reason: '已归档会话按定义不在运行，轮询毫无意义；且归档响应约为未归档的 2.4 倍');

      // 不调用 teardownView 也能通过，反证此刻确实没有 pending timer。
    });

    testWidgets('include 模式同样停掉轮询', (tester) async {
      useTallViewport(tester);
      final svc = _RecordingService();
      await pumpView(
        tester,
        svc,
        workspaces: [ws(archivedCount: 4, sessions: [session('l1', '活跃一')])],
        mode: 'include',
        supported: true,
      );
      final baseline = svc.fetchCount;
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 3));
      }
      expect(svc.fetchCount, baseline);
    });

    testWidgets('本页不可见时（active: false）即使在 exclude 模式也不轮询', (tester) async {
      useTallViewport(tester);
      final svc = _RecordingService();
      svc.debugSetWorkspaces([ws(sessions: [session('l1', '活跃一')])],
          archivedFilter: 'exclude', archivedFilterSupported: true);
      await tester.pumpWidget(
        ChangeNotifierProvider<DshService>.value(
          value: svc,
          child: const MaterialApp(home: WorkspacesView(active: false)),
        ),
      );
      await tester.pump();
      final baseline = svc.fetchCount;
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 3));
      }
      expect(svc.fetchCount, baseline, reason: 'IndexedStack 保活的隐藏页不该轮询');
    });
  });

  group('模型解析', () {
    test('SessionMeta.archived 接受布尔与字符串，缺省为 false', () {
      expect(SessionMeta.fromJson({'sessionId': 'a', 'title': 't', 'archived': true}).archived, isTrue);
      expect(SessionMeta.fromJson({'sessionId': 'a', 'title': 't', 'archived': 'true'}).archived, isTrue);
      expect(SessionMeta.fromJson({'sessionId': 'a', 'title': 't', 'archived': false}).archived, isFalse);
      // 旧网关不返回该字段。
      expect(SessionMeta.fromJson({'sessionId': 'a', 'title': 't'}).archived, isFalse);
    });

    test('SessionMeta.archived 随 toJson/copyWith 往返', () {
      final s = session('a', 't', archived: true);
      expect(SessionMeta.fromJson(s.toJson()).archived, isTrue);
      expect(s.copyWith().archived, isTrue);
      expect(s.copyWith(archived: false).archived, isFalse);
      // copyWith 不传该参数时不能被意外翻转。
      expect(s.copyWith(title: '新标题').archived, isTrue);
    });

    test('Workspace.archivedCount 缺省为 0，且能从字符串解析', () {
      expect(Workspace.fromJson({'workspaceId': 'w', 'title': 't'}).archivedCount, 0);
      expect(Workspace.fromJson({'workspaceId': 'w', 'title': 't', 'archivedCount': 1338}).archivedCount, 1338);
      expect(Workspace.fromJson({'workspaceId': 'w', 'title': 't', 'archivedCount': '7'}).archivedCount, 7);
    });

    test('Workspace.archivedCount 独立于 sessions 长度（跨模式恒定）', () {
      final w = Workspace.fromJson({
        'workspaceId': 'w',
        'title': 't',
        'archivedCount': 1275,
        'sessionCount': 98,
        'sessions': [
          {'sessionId': 'l1', 'title': '活跃一'}
        ],
      });
      expect(w.archivedCount, 1275);
      expect(w.sessionCount, 98);
      expect(w.sessions, hasLength(1));
      expect(w.toJson()['archivedCount'], 1275);
    });
  });
}

/// 记录 setArchivedFilter 调用并接管 fetchWorkspaces，全程不发网络请求。
///
/// 覆写 fetchWorkspaces 是「轮询是否真的停了」可以被断言的前提：真实实现在
/// 没有 config 时会立即 return，外部观察不到任何调用痕迹，也就无从判断
/// Timer.periodic 到底有没有在触发。
class _RecordingService extends DshService {
  final List<String> requested = [];
  int fetchCount = 0;

  @override
  Future<void> setArchivedFilter(String mode) async {
    requested.add(mode);
  }

  @override
  Future<void> fetchWorkspaces() async {
    fetchCount++;
  }
}
