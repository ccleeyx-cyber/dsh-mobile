import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/models/chat_message.dart';

/// [fix 2026-10-16] 流式增量缓冲的契约测试。
///
/// 背景：delta 帧不再直接 `content += text`（Dart 字符串不可变，逐片拼接是
/// O(n²)），而是先攒在 StringBuffer 里、到 flush 边界才写回成品字段。
/// 这套测试钉住三件事，任何一条被破坏都会变成用户可见的内容丢失：
///   ① flush 之前成品字段看不到增量（否则缓冲失去意义）；
///   ② flush 之后增量按**到达顺序**完整写回（顺序错了内容就乱了）；
///   ③ streaming 结束时**一定** flush（取消/错误/超时兜底都走同一条路）。
void main() {
  group('ChatMessage 流式缓冲', () {
    ChatMessage streaming() => ChatMessage(
          id: 'm1',
          role: 'assistant',
          content: '',
          thinking: '',
          isStreaming: true,
        );

    test('增量先进 buffer，不碰成品字段', () {
      final m = streaming();
      m.appendStreamDelta(content: 'Hello');
      m.appendStreamDelta(content: ' world');

      expect(m.content, isEmpty, reason: 'flush 之前成品字段必须是空的');
      m.flushStreamBuffers();
      expect(m.content, equals('Hello world'));
    });

    test('content 与 thinking 两个槽互不串味', () {
      final m = streaming();
      m.appendStreamDelta(content: 'A', thinking: 'think-1');
      m.appendStreamDelta(content: 'B', thinking: 'think-2');
      m.flushStreamBuffers();

      expect(m.content, equals('AB'));
      expect(m.thinking, equals('think-1think-2'));
    });

    test('增量按到达顺序写回，且与既有成品拼接', () {
      final m = ChatMessage(id: 'm2', role: 'assistant', content: '前缀', isStreaming: true);
      m.appendStreamDelta(content: '-中');
      m.appendStreamDelta(content: '-后');
      m.flushStreamBuffers();

      expect(m.content, equals('前缀-中-后'));
    });

    test('空 delta 不会把 buffering 点亮', () {
      final m = streaming();
      m.appendStreamDelta(content: '', thinking: '');
      // 没有真实增量 → flush 是彻底的 no-op，成品保持原值。
      m.flushStreamBuffers();
      expect(m.content, isEmpty);
      expect(m.thinking, isEmpty);
    });

    test('streaming 结束这一下会 flush —— 取消/错误/兜底都靠它', () {
      final m = streaming();
      m.appendStreamDelta(content: '半截回答');
      expect(m.content, isEmpty, reason: '还没结束，内容不该出现');

      m.isStreaming = false;
      expect(m.content, equals('半截回答'),
          reason: 'isStreaming=false 必须把最后一段增量写回，否则取消或弱网兜底时它凭空消失');
    });

    test('反复 flush 幂等，不会重复拼接', () {
      final m = streaming();
      m.appendStreamDelta(content: 'X');
      m.flushStreamBuffers();
      m.flushStreamBuffers();
      m.flushStreamBuffers();
      expect(m.content, equals('X'));
    });

    test('先结束 streaming 再 append：增量立即可见', () {
      final m = streaming();
      m.isStreaming = false;
      // 回合已结束还来的 delta 是迟到帧；此时没有缓冲语义，直接进成品。
      m.appendStreamDelta(content: '迟到');
      m.flushStreamBuffers();
      expect(m.content, equals('迟到'));
    });

    test('非流式消息从不参与缓冲', () {
      final m = ChatMessage(id: 'm3', role: 'user', content: '提问');
      m.flushStreamBuffers();
      expect(m.content, equals('提问'));
    });
  });
}
