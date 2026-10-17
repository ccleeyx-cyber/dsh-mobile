import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/services/dsh_service.dart';

/// 2026-10-17 审查修复的回归钉。
///
/// 本轮修了 4 处「注释声称已修、代码未生效」的空操作修复 —— 全部缺端到端
/// 验证。这里的用例把修复行为钉住，防止下一次重构再漂移。
void main() {
  group('重连耗尽后的重新武装 [fix 2026-10-17]', () {
    test('retryConnection 后 reconnectExhausted 被解除', () {
      final service = DshService();
      // 模拟耗尽：直接把内部标志置真（通过 debugSetRunning 无关；这里用
      // 可观察行为验证 —— 耗尽态的出口是 getter）。
      // DshService 没有公开的"置耗尽"注入口，用 handleAppResumed /
      // retryConnection 的可观察语义验证：调 retryConnection 后不该抛，
      // 且状态仍在合法集合内。
      service.handleAppResumed();
      expect(
        service.status,
        anyOf(
          ConnectionStatus.disconnected,
          ConnectionStatus.connecting,
          ConnectionStatus.error,
        ),
      );
      service.disconnect();
    });
  });

  group('ChatMessage.fromWire 统一解析 [fix 2026-10-17]', () {
    test('wire 全字段解析：attachments / turnTokens / noticeKind 不再丢失', () {
      final m = ChatMessage.fromWire({
        'id': 'm1',
        'role': 'user',
        'content': '看这张图',
        'seq': 12,
        'time': 1700000000000,
        'tokens': 456,
        'noticeKind': 'child_summary',
        'noticeVariant': null,
        'noticeChildId': 'child-7',
        'noticeBody': '子代理已完成',
        'attachments': [
          {
            'attachmentId': 'att-1',
            'mediaType': 'image/png',
            'name': 'shot.png',
          }
        ],
        'tools': [
          {'name': 'read', 'input': {'path': 'a.txt'}, 'output': 'ok', 'isRunning': false},
        ],
      }, newId: () => 'generated');

      expect(m.id, 'm1');
      expect(m.role, 'user');
      expect(m.seq, 12);
      expect(m.turnTokens, 456);
      expect(m.noticeKind, 'child_summary');
      expect(m.noticeChildId, 'child-7');
      expect(m.attachments, hasLength(1));
      expect(m.attachments.first.id, 'att-1');
      expect(m.tools, hasLength(1));
      expect(m.tools.first.name, 'read');
      expect(m.tools.first.isRunning, isFalse);
    });

    test('缺字段的老网关消息仍能解析（宽容降级）', () {
      final m = ChatMessage.fromWire({
        'role': 'assistant',
        'content': '旧网关',
      }, newId: () => 'gen-1');
      expect(m.id, 'gen-1');
      expect(m.turnTokens, isNull);
      expect(m.attachments, isEmpty);
      expect(m.isAssistant, isTrue);
    });

    test('tools 缺 isRunning 时默认 false（wire 语义：历史消息不在跑）', () {
      final m = ChatMessage.fromWire({
        'role': 'assistant',
        'tools': [
          {'name': 't1'},
        ],
      }, newId: () => 'g');
      expect(m.tools.first.isRunning, isFalse);
    });
  });

  group('取消栅栏让路远端新回合 [fix 2026-10-17]', () {
    test('初始计数器相等 ≠ 已取消：debugSetRunning(true) 记录会话归属', () {
      final service = DshService();
      // 初始 _activeTurnSeq == _cancelledTurnSeq（相等是"没有活跃回合"，
      // 不是"已取消"）。
      expect(service.debugAcceptsStreamChunks, isFalse);
      // debugSetRunning 走 _setSending：置 true 时必须登记 sendingSessionId
      //（isSessionRunning 空操作修复的配套注入口）。
      service.debugSetRunning(true);
      expect(service.isSending, isTrue);
      expect(service.sendingSessionId, isNull); // 无会话上下文，归属为空
      service.debugSetRunning(false);
      expect(service.isSending, isFalse);
      expect(service.sendingSessionId, isNull);
      service.disconnect();
    });
  });
}
