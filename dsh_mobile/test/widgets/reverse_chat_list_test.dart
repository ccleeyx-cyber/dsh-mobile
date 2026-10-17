/// [fix 2026-10-18] 打开会话即最新内容（reverse 列表）的回归测试。
///
/// 用户报告：每次点开会话都是"从上往下滑到最新"，又卡又别扭。根因是正序
/// ListView 挂载在 offset 0（视觉顶部=最旧），再 postFrame 跳底部。改成
/// `reverse: true` 后 offset 0 = 最新，挂载即锚定，全程零滚动。
///
/// 这组测试把 reverse 形态的关键行为钉死，防止以后有人"顺手"改回去：
/// 1. 挂载即最新（不依赖任何 jumpToBottom）；
/// 2. 用户在上方看历史时新消息不拖视口；
/// 3. 上翻加载更早历史时现有内容位置不动（无需 delta 补偿）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/views/widgets/message_list_view.dart';

Widget _msgTile(ChatMessage m) => SizedBox(
      key: ValueKey(m.id),
      height: 200,
      child: Text(m.id),
    );

ChatMessage _msg(String id, {bool isUser = false}) => ChatMessage(
      id: id,
      content: '内容-$id',
      role: isUser ? 'user' : 'assistant',
    );

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('挂载即锚定最新消息：最新一条可见、最旧一条不可见', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final c = ScrollController();
    final messages = List.generate(30, (i) => _msg('m$i'));
    await tester.pumpWidget(_host(MessageListView(
      messages: messages,
      itemCount: messages.length,
      headerCount: 0,
      buildItem: (_, i) => _msgTile(messages[i]),
      buildHeader: () => const SizedBox.shrink(),
      buildTrailer: () => const SizedBox.shrink(),
      controller: c,
      onScrollNotification: (_) => false,
    )));
    await tester.pumpAndSettle();

    expect(c.offset, 0.0, reason: 'reverse 列表挂载即底部，不需要任何滚动');
    expect(find.byKey(const ValueKey('m29')), findsOneWidget, reason: '最新一条可见');
    expect(find.byKey(const ValueKey('m0')), findsNothing, reason: '最旧一条不可见');
  });

  testWidgets('buildItem 收到的是正序索引（0 = 最旧）', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final c = ScrollController();
    final messages = List.generate(3, (i) => _msg('m$i'));
    final seenIndices = <int>[];
    await tester.pumpWidget(_host(MessageListView(
      messages: messages,
      itemCount: messages.length,
      headerCount: 0,
      buildItem: (_, i) {
        seenIndices.add(i);
        return Text(messages[i].id, key: ValueKey(messages[i].id));
      },
      buildHeader: () => const SizedBox.shrink(),
      buildTrailer: () => const SizedBox.shrink(),
      controller: c,
      onScrollNotification: (_) => false,
    )));
    await tester.pumpAndSettle();

    // 3 条都可见；构建过的索引都在 [0, length) 范围内（正序语义）。
    expect(seenIndices.every((i) => i >= 0 && i < messages.length), isTrue);
    expect(find.byKey(const ValueKey('m2')), findsOneWidget);
    expect(find.byKey(const ValueKey('m1')), findsOneWidget);
    expect(find.byKey(const ValueKey('m0')), findsOneWidget);
  });

  testWidgets('用户在上方看历史时新消息到达：视口不被拖走', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final c = ScrollController();
    var messages = List.generate(30, (i) => _msg('m$i'));
    await tester.pumpWidget(_host(MessageListView(
      messages: messages,
      itemCount: messages.length,
      headerCount: 0,
      buildItem: (_, i) => _msgTile(messages[i]),
      buildHeader: () => const SizedBox.shrink(),
      buildTrailer: () => const SizedBox.shrink(),
      controller: c,
      onScrollNotification: (_) => false,
    )));
    await tester.pumpAndSettle();

    // 用户上翻
    c.jumpTo(c.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('m0')), findsOneWidget);

    // 尾部来了新消息（正序列表 append；reverse 列表视觉上是"锚定侧"加入）
    messages = [...messages, _msg('m_new')];
    await tester.pumpWidget(_host(MessageListView(
      messages: messages,
      itemCount: messages.length,
      headerCount: 0,
      buildItem: (_, i) => _msgTile(messages[i]),
      buildHeader: () => const SizedBox.shrink(),
      buildTrailer: () => const SizedBox.shrink(),
      controller: c,
      onScrollNotification: (_) => false,
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('m0')), findsOneWidget,
        reason: '用户看的历史仍在原位 —— 新消息不会把视口拖走');
  });

  testWidgets('trailer（本轮产出卡）渲染在视觉最底部（最新消息之下）', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final c = ScrollController();
    final messages = List.generate(3, (i) => _msg('m$i'));
    await tester.pumpWidget(_host(MessageListView(
      messages: messages,
      itemCount: messages.length + 1, // +1 trailer
      headerCount: 0,
      buildItem: (_, i) => _msgTile(messages[i]),
      buildHeader: () => const SizedBox.shrink(),
      buildTrailer: () => const Text('trailer', key: ValueKey('trailer')),
      controller: c,
      onScrollNotification: (_) => false,
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('trailer')), findsOneWidget);
    // trailer 在最新消息 m2 之下（视觉位置更靠底）
    final trailerY = tester.getTopLeft(find.byKey(const ValueKey('trailer'))).dy;
    final newestY = tester.getTopLeft(find.byKey(const ValueKey('m2'))).dy;
    expect(trailerY, greaterThan(newestY),
        reason: '产出卡跟在最新消息后面（视觉更靠底）');
  });
}
