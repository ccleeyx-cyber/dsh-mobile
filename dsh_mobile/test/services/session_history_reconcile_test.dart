import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/models/task_center.dart';

/// 会话历史的两个 2026-10-17 缺陷回归：
///
/// 1. **"明明有五轮，只显示三轮"**。服务端那份快照只覆盖最新一页（引擎按消息数给的
///    窗口），用户上翻加载出来的更早几轮不在里面；而 reconcile 原来整体替换
///    `_messages`，于是每 2.5 秒一次的轮询/重连都会把旧轮抹掉。
/// 2. **"本轮用量不显示"**。以前只能靠回合起止两次 stats 读数相减，基线没记到就
///    永远 `—`；现在优先用网关汇总的引擎权威值（每条 user 消息上的 `tokens`）。
void main() {
  DshService newService() {
    final dsh = DshService();
    dsh.debugSetCurrentSession(SessionMeta(sessionId: 'session-abc', title: 't'));
    return dsh;
  }

  /// 手上已有的消息（翻页加载出来的更早几轮带**较早**的时间戳，与真实历史一致）。
  ChatMessage mine(String id, String role, String content, int seq,
          {int minutesAgo = 30, int? turnTokens}) =>
      ChatMessage(
        id: id,
        role: role,
        content: content,
        seq: seq,
        timestamp: DateTime.now().subtract(Duration(minutes: minutesAgo)),
        turnTokens: turnTokens,
      );

  /// 网关回包里的消息（历史转换的 JSON 形状）。
  Map<String, dynamic> wire(String id, String role, String content, int seq,
          {int? tokens, List<dynamic>? attachments}) =>
      {
        'id': id,
        'role': role,
        'content': content,
        'seq': seq,
        'time': DateTime.now().millisecondsSinceEpoch,
        if (tokens != null) 'tokens': tokens,
        if (attachments != null) 'attachments': attachments,
      };

  group('reconcile 与翻页历史', () {
    test('上翻加载出来的更早几轮不会被下一次快照抹掉', () {
      final dsh = newService();
      // 用户上翻后手上是完整 5 轮（这里放 3 轮就够说明问题）。
      dsh.debugSetMessages([
        mine('u101', 'user', '第一轮', 101),
        mine('a102', 'assistant', '第一轮回复', 102),
        mine('u201', 'user', '第二轮', 201),
        mine('a202', 'assistant', '第二轮回复', 202),
        mine('u901', 'user', '最新一轮', 901),
        mine('a902', 'assistant', '最新回复', 902),
      ]);

      // 服务端快照只给最新一页（901/902）。
      dsh.debugReconcileServerMessages([
        wire('u901', 'user', '最新一轮', 901),
        wire('a902', 'assistant', '最新回复', 902),
      ]);

      expect(
        dsh.messages.map((m) => m.id).toList(),
        ['u101', 'a102', 'u201', 'a202', 'u901', 'a902'],
        reason: '窗口之前的消息必须原样留在头部，顺序不能乱',
      );
    });

    test('窗口内的消息只出现一份（保留逻辑不与本地补插重叠）', () {
      final dsh = newService();
      dsh.debugSetMessages([
        mine('u101', 'user', '第一轮', 101),
        mine('u901', 'user', '最新一轮', 901),
        mine('a902', 'assistant', '最新回复', 902),
      ]);

      dsh.debugReconcileServerMessages([
        wire('u901', 'user', '最新一轮', 901),
        wire('a902', 'assistant', '最新回复', 902),
      ]);

      expect(dsh.messages.where((m) => m.id == 'u901').length, 1);
      expect(dsh.messages.map((m) => m.id).toList(), ['u101', 'u901', 'a902']);
    });

    test('没有 seq 的本地乐观消息照旧由"保留最近本地提问"兜住', () {
      final dsh = newService();
      dsh.debugSetMessages([
        mine('u101', 'user', '第一轮', 101),
        ChatMessage(id: 'local1', role: 'user', content: '刚敲下的一句', timestamp: DateTime.now()),
        ChatMessage(
            id: 'local2',
            role: 'assistant',
            content: '在跑',
            isStreaming: true,
            timestamp: DateTime.now()),
      ]);

      dsh.debugReconcileServerMessages([
        wire('u901', 'user', '最新一轮', 901),
        wire('a902', 'assistant', '最新回复', 902),
      ]);

      final ids = dsh.messages.map((m) => m.id).toList();
      expect(ids.first, 'u101');
      expect(ids.contains('local1'), isTrue, reason: '刚发出的提问不能被服务端窗口吞掉');
    });
  });

  group('本轮用量（lastTurnTokens）', () {
    test('优先用引擎的权威读数：最近一次跑完的那一轮', () {
      final dsh = newService();
      dsh.debugSetMessages([
        mine('u1', 'user', '第一轮', 11, turnTokens: 5521),
        mine('a1', 'assistant', '…', 12),
        mine('u2', 'user', '第二轮', 21, turnTokens: 8888),
        mine('a2', 'assistant', '…', 22),
      ]);

      expect(dsh.lastTurnTokens, 8888);
    });

    test('当前这一轮还在跑（没有权威值）时，显示的是上一次跑完的读数', () {
      final dsh = newService();
      dsh.debugSetMessages([
        mine('u1', 'user', '第一轮', 11, turnTokens: 5521),
        mine('a1', 'assistant', '…', 12),
        mine('u2', 'user', '第二轮', 21), // 已发出、还没跑完 → 网关不给值
        ChatMessage(
            id: 'a2',
            role: 'assistant',
            content: '',
            isStreaming: true,
            seq: 22,
            timestamp: DateTime.now()),
      ]);

      expect(dsh.lastTurnTokens, 5521);
    });

    test('没有权威值、也没量到 → null（界面显示 —，不是 0）', () {
      final dsh = newService();
      dsh.debugSetMessages([
        mine('u1', 'user', '第一轮', 11),
        mine('a1', 'assistant', '…', 12),
      ]);

      expect(dsh.lastTurnTokens, isNull);
    });

    test('没有权威值时退回本机相减（老网关 / 老会话仍然可用）', () {
      final dsh = newService();
      dsh.debugSetMessages([
        mine('u1', 'user', '第一轮', 11),
        mine('a1', 'assistant', '…', 12),
      ]);
      dsh.debugSetTaskCenter(
        stats: const SessionStats(source: 'live', totalTokens: 1000),
        statsBaselineTokens: 400,
        measuredTurnTokens: 600,
      );

      expect(dsh.lastTurnTokens, 600);
    });
  });
}
