import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/server_config.dart';
import 'package:dsh_mobile/services/dsh_service.dart';

/// 「agent 弹出的选择手机端没显示出来」的回归测试。
///
/// ## 缺陷本体
///
/// App 要向网关声明"这台手机愿意回答交互式提问"（`subscribe_questions`），网关
/// 才把提问转发过来；否则它按设计把提问留给 Web UI。
///
/// 而声明原来的发送时机是错的：它在 `_channel.stream.listen(...)` 刚注册完就调
/// `_sendWsJson({'type':'subscribe_questions'})`，但 `_sendWsJson` 的守卫要求
/// `_status == connected` —— 而 `_status` 恰恰是**收到第一条消息时**才被置位的。
/// 于是那一次订阅被静默丢弃，网关永远认为没有手机订阅者，提问一个都到不了手机。
///
/// ## 为什么必须用真实 WebSocket 服务器测
///
/// 这个 bug 是**时序**问题：谁先谁后。打桩 `_sendWsJson` 只能验证"调用了"，
/// 验证不了"在那一刻发得出去"。起一个真的 WS 服务器、断言它**实际收到**了
/// subscribe_questions，才是能抓到这个 bug 的判据。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ⚠️ flutter_test 默认装一个 HttpOverrides，把所有真实 HTTP 请求换成假的响应
  // （意图是防止单测打网络）。WebSocketChannel 底层走 HttpClient，会被一起拦掉,
  // 表现为"连接被拒绝"、服务器一条消息都收不到 —— 而代码其实没问题。
  //
  // 关键：必须在**每个测试体内部**解除它。放在 setUpAll / setUp 里不生效 ——
  // flutter_test 是在每个测试自己的 Zone 里应用 override 的，外层赋值会被覆盖。
  // （这个坑实测踩过：setUpAll 里设 null 之后仍然全是 ECONNREFUSED。）
  void allowRealNetwork() => HttpOverrides.global = null;

  late HttpServer server;
  late int port;
  late List<String> received;
  late List<WebSocket> sockets;

  setUp(() async {
    received = [];
    sockets = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;

    server.listen((req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        sockets.add(ws);
        ws.listen(
          (data) {
            if (data is String) received.add(data);
          },
          onError: (_) {},
          cancelOnError: false,
        );
        return;
      }
      // connect() 还会顺手拉一批 REST 数据。这里一律 404，让它们快速失败，
      // 不要在测试里挂住。
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    });
  });

  tearDown(() async {
    for (final ws in sockets) {
      try { await ws.close(); } catch (_) {}
    }
    try { await server.close(force: true); } catch (_) {}
  });

  /// 等到 [test] 为真，或超时。返回是否等到。
  Future<bool> waitFor(bool Function() test,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (test()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return test();
  }

  List<Map<String, dynamic>> parsed() => received
      .map((s) {
        try {
          final v = jsonDecode(s);
          return v is Map<String, dynamic> ? v : <String, dynamic>{};
        } catch (_) {
          return <String, dynamic>{};
        }
      })
      .toList();

  test('连接建立后必须真的把 subscribe_questions 发出去', () async {
    allowRealNetwork();
    final dsh = DshService();
    // 不 await：connect 末尾还会 await 一批会 404 的 REST 拉取，我们只关心
    // WS 这条线。
    unawaited(dsh.connect(ServerConfig(
      host: '127.0.0.1',
      port: port,
      token: 'test-token',
    )));

    final got = await waitFor(
      () => parsed().any((m) => m['type'] == 'subscribe_questions'),
    );

    expect(
      got,
      isTrue,
      reason: '服务器实际收到的消息里必须有 subscribe_questions —— '
          '旧代码在 _status 还是 connecting 时就发，会被守卫丢掉，'
          '结果网关认为没有手机订阅者，所有提问都只留给 Web UI。'
          '实际收到：$received',
    );

    dsh.disconnect();
  });

  test('订阅是在连接确立之后发的，不是刚建连就发', () async {
    allowRealNetwork();
    final dsh = DshService();
    unawaited(dsh.connect(ServerConfig(
      host: '127.0.0.1',
      port: port,
      token: 'test-token',
    )));

    final got = await waitFor(
      () => parsed().any((m) => m['type'] == 'subscribe_questions'),
    );
    expect(got, isTrue);

    // 关键：消息确实到达了服务器。如果它是在 _status 还是 connecting 的时候
    // 被发送的，它就永远不会出现在这里 —— 这正是旧的失败方式。
    expect(received, isNotEmpty);
    dsh.disconnect();
  });

  test('网关回的 pending 提问能被重放出来（连接前就挂着的提问）', () async {
    allowRealNetwork();
    final dsh = DshService();
    unawaited(dsh.connect(ServerConfig(
      host: '127.0.0.1',
      port: port,
      token: 'test-token',
    )));

    // 等服务器拿到握手/订阅，再模拟网关回一条带 pending 的确认。
    final subscribed = await waitFor(
      () => parsed().any((m) => m['type'] == 'subscribe_questions'),
    );
    expect(subscribed, isTrue, reason: '前置条件：必须先订阅');

    expect(sockets, isNotEmpty);
    sockets.first.add(jsonEncode({
      'type': 'question_subscribed',
      'ok': true,
      'pending': [
        {
          'eventId': 'evt-1',
          'sessionId': 's1',
          'questions': [
            {
              'id': 'q1',
              'question': '要继续吗？',
              'options': [
                {'label': '继续'},
                {'label': '停止'},
              ],
            }
          ],
        }
      ],
    }));

    final shown = await waitFor(() => dsh.pendingQuestions.isNotEmpty);
    expect(
      shown,
      isTrue,
      reason: '网关回放的挂起提问必须被解析留存，否则重连后看不到任何提问。'
          '实际：${dsh.pendingQuestions.length} 条',
    );
    expect(dsh.pendingQuestions.first.eventId, 'evt-1');

    dsh.disconnect();
  });

  test('切换会话不能把已收到的提问清掉（点通知进来看不到选项的回归）', () async {
    allowRealNetwork();
    final dsh = DshService();
    unawaited(dsh.connect(ServerConfig(
      host: '127.0.0.1',
      port: port,
      token: 'test-token',
    )));

    final subscribed = await waitFor(
      () => parsed().any((m) => m['type'] == 'subscribe_questions'),
    );
    expect(subscribed, isTrue, reason: '前置条件：必须先订阅');

    // 模拟网关转发一条实时提问。
    sockets.first.add(jsonEncode({
      'type': 'question_request',
      'eventId': 'evt-keep',
      'sessionId': 'session-target',
      'questions': [
        {
          'id': 'q1',
          'question': '选哪个？',
          'options': [
            {'label': '甲'},
            {'label': '乙'},
          ],
        }
      ],
    }));

    final got = await waitFor(() => dsh.pendingQuestions.isNotEmpty);
    expect(got, isTrue, reason: '前置条件：提问先要收到');

    // 用户点通知 → openSessionById → selectSession。旧代码在这里
    // _pendingQuestions.clear()，把刚到手的提问整批删掉，而网关只在
    // subscribe 时重放一次 —— 清了就永远拿不回来，界面上就是
    // "点进去什么选项都没有"。
    await dsh.openSessionById('session-target');
    await testerPump();
    expect(
      dsh.pendingQuestions,
      isNotEmpty,
      reason: 'selectSession 不得清空 _pendingQuestions —— 提问没有 HTTP 补拉'
          '接口，清了就永久丢失（用户点通知进来看不到选项的真因）。',
    );
    expect(dsh.pendingQuestions.first.eventId, 'evt-keep');

    dsh.disconnect();
  });

  test('回前台重订阅能拿回 pending 重放（后台半死连接的回归）', () async {
    allowRealNetwork();
    final dsh = DshService();
    unawaited(dsh.connect(ServerConfig(
      host: '127.0.0.1',
      port: port,
      token: 'test-token',
    )));

    final subscribed = await waitFor(
      () => parsed().any((m) => m['type'] == 'subscribe_questions'),
    );
    expect(subscribed, isTrue, reason: '前置条件：必须先订阅');
    // 服务器先回一个 pong，喂饱看门狗 —— 让 handleAppResumed 判定连接健康，
    // 走"补订阅"分支而不是重连分支。两条路径都要能拿回提问，这里测的是
    // 更难的那条：连接看着活着（Resumed 只补订阅）。
    sockets.first.add('pong');

    // 网关挂着的 pending（App 在后台期间错过实时帧的那条）。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final countBefore = parsed()
        .where((m) => m['type'] == 'subscribe_questions')
        .length;

    dsh.handleAppResumed();
    final resub = await waitFor(
      () => parsed().where((m) => m['type'] == 'subscribe_questions').length > countBefore,
    );
    expect(
      resub,
      isTrue,
      reason: 'handleAppResumed 在连接健康时必须补发一次 subscribe_questions '
          '（幂等，网关会重放 pending）—— 否则后台期间错过的提问永远拿不回来。',
    );

    // 模拟网关对这次补订阅回放 pending。
    sockets.first.add(jsonEncode({
      'type': 'question_subscribed',
      'ok': true,
      'pending': [
        {
          'eventId': 'evt-replay',
          'sessionId': 's1',
          'questions': [
            {
              'id': 'q1',
              'question': '后台期间错过的提问？',
              'options': [
                {'label': '继续'},
              ],
            }
          ],
        }
      ],
    }));

    final shown = await waitFor(
      () => dsh.pendingQuestions.any((p) => p.eventId == 'evt-replay'),
    );
    expect(
      shown,
      isTrue,
      reason: '补订阅换回的 pending 重放必须被留存渲染。',
    );

    dsh.disconnect();
  });
}

/// selectSession 内部有真实的网络调用（REST 历史拉取），测试服务器对它们
/// 一律 404，await 返回即可；这里额外让出事件循环一拍，确保清理路径
/// （如果存在）已经被执行过再断言。
Future<void> testerPump() async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
}
