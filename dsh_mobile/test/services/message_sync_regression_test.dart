import 'dart:async';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> wire(
  String id,
  String role,
  String content,
  int seq, {
  String? rpcId,
}) =>
    {
      'id': id,
      'role': role,
      'content': content,
      'seq': seq,
      'time': 1700000000000 + seq,
      if (rpcId != null) 'rpcId': rpcId,
    };

void main() {
  DshService service() {
    final dsh = DshService();
    dsh.debugSetCurrentSession(
      SessionMeta(sessionId: 'session-sync', title: 'sync'),
    );
    return dsh;
  }

  group('历史身份与本地乐观消息', () {
    test('同一 requestId 的实时占位和历史记录只保留一份', () {
      final dsh = service();
      dsh.debugReconcileServerMessages([
        wire('u10', 'user', '查一下', 10, rpcId: 'request-1'),
        wire('live_request-1', 'user', '查一下', 999998,
            rpcId: 'request-1'),
        wire('a11', 'assistant', '结果', 11),
      ]);

      expect(dsh.messages.length, 2);
      expect(dsh.messages.singleWhere((m) => m.isUser).id, 'u10');
    });

    test('同一 requestId 重复到达不会越对账越多', () {
      final dsh = service();
      final page = [
        wire('u10', 'user', '查一下', 10, rpcId: 'request-1'),
        wire('a11', 'assistant', '结果', 11),
      ];
      dsh.debugReconcileServerMessages(page);
      dsh.debugReconcileServerMessages(page);

      expect(dsh.messages.map((m) => m.id), ['u10', 'a11']);
    });

    test('相同正文的两次发送仍是两个独立回合', () {
      final dsh = service();
      dsh.debugSetMessages([
        ChatMessage(
          id: 'local-old',
          role: 'user',
          content: '继续',
          clientRequestId: 'request-old',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
        ChatMessage(
          id: 'a-old',
          role: 'assistant',
          content: '旧回复',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000010),
        ),
      ]);
      dsh.debugReconcileServerMessages([
        wire('u20', 'user', '继续', 20, rpcId: 'request-new'),
        wire('a21', 'assistant', '新回复', 21),
      ]);

      expect(dsh.messages.where((m) => m.content == '继续').length, 2);
      expect(dsh.messages.map((m) => m.id),
          ['local-old', 'a-old', 'u20', 'a21']);
    });
    test('旧网关的同文本地提问仍能配对，不会多保留一份', () {
      final dsh = service();
      dsh.debugSetMessages([
        ChatMessage(id: 'local', role: 'user', content: '问题'),
      ]);
      dsh.debugReconcileServerMessages([
        wire('u1', 'user', '问题', 1),
        wire('a1', 'assistant', '回答', 2),
      ]);
      expect(dsh.messages.map((m) => m.id), ['u1', 'a1']);
    });

    test('带 rpcId 的实时提问遇到同文历史时不再多插一份', () {
      final dsh = service();
      dsh.debugSetMessages([
        ChatMessage(
          id: 'local',
          role: 'user',
          content: '相同正文',
          clientRequestId: 'request-live',
        ),
        ChatMessage(id: 'a', role: 'assistant', content: '回答'),
      ]);
      dsh.debugReconcileServerMessages([
        wire('u1', 'user', '相同正文', 1, rpcId: 'request-live'),
        wire('live_request-live', 'user', '相同正文', 999998,
            rpcId: 'request-live'),
        wire('a1', 'assistant', '回答', 2),
      ]);
      expect(dsh.messages.map((m) => m.id), ['u1', 'a1']);
    });
  });

  group('跨端回合边界', () {
    test('done 会请求一次最终历史，而不是只停止转圈', () async {
      final dsh = service();
      final synced = <String>[];
      dsh.debugFinalResync = (sessionId) async => synced.add(sessionId);

      dsh.debugHandleRawMessage({
        'type': 'done',
        'sessionId': 'session-sync',
        'reason': 'completed',
      });
      await Future<void>.delayed(Duration.zero);

      expect(synced, ['session-sync']);
      dsh.dispose();
    });

    test('done 与 idle 连续到达时最终补拉合并为一次', () async {
      final dsh = service();
      var calls = 0;
      final gate = Completer<void>();
      dsh.debugFinalResync = (_) async {
        calls++;
        await gate.future;
      };

      dsh.debugHandleRawMessage({
        'type': 'done',
        'sessionId': 'session-sync',
        'reason': 'completed',
      });
      dsh.debugHandleRawMessage({
        'type': 'session_status',
        'sessionId': 'session-sync',
        'isRunning': false,
      });
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      dsh.dispose();
    });

    test('done 携带的最终快照即使没有任何 delta 也能显示', () {
      final dsh = service();
      dsh.debugHandleRawMessage({
        'type': 'done',
        'sessionId': 'session-sync',
        'reason': 'completed',
        'text': 'Web 已完成的最终回答',
        'thinking': '思考摘要',
      });

      expect(dsh.messages.single.content, 'Web 已完成的最终回答');
      expect(dsh.messages.single.thinking, '思考摘要');
      expect(dsh.messages.single.isStreaming, isFalse);
      dsh.dispose();
    });

    test('下一轮 running 事件清除上一轮结束标记', () {
      final dsh = service();
      dsh.debugHandleRawMessage({
        'type': 'done',
        'sessionId': 'session-sync',
        'reason': 'completed',
        'text': '上一轮',
      });
      dsh.debugHandleRawMessage({
        'type': 'session_status',
        'sessionId': 'session-sync',
        'isRunning': true,
      });
      dsh.debugHandleRawMessage({
        'type': 'delta',
        'sessionId': 'session-sync',
        'delta': '下一轮',
      });
      expect(dsh.messages.last.content, '下一轮');
      expect(dsh.messages.last.isStreaming, isTrue);
      dsh.dispose();
    });

    test('结束后的迟到 delta 不得重新点亮流式状态', () {
      final dsh = service();
      dsh.debugHandleRawMessage({
        'type': 'session_status',
        'sessionId': 'session-sync',
        'isRunning': true,
      });
      dsh.debugHandleRawMessage({
        'type': 'delta',
        'sessionId': 'session-sync',
        'delta': '正文',
      });
      dsh.debugHandleRawMessage({
        'type': 'done',
        'sessionId': 'session-sync',
        'reason': 'completed',
      });
      dsh.debugHandleRawMessage({
        'type': 'delta',
        'sessionId': 'session-sync',
        'delta': '迟到尾包',
      });

      expect(dsh.messages.single.content, '正文');
      expect(dsh.messages.single.isStreaming, isFalse);
      expect(dsh.isSending, isFalse);
      dsh.dispose();
    });
  });
}
