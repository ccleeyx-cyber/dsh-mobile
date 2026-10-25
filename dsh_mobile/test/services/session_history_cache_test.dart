import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';

/// [fix 2026-10-25] 首次完整加载后必须写回缓存。
///
/// 旧实现只在“已有缓存”分支写回，首次打开走 `ensureFullHistory()` 之后缓存
/// 仍为空，第二次打开又从零翻页。这里直接钉住真实缓存写入路径的语义。
void main() {
  test('首次加载写回的消息快照可被下一次打开命中', () {
    final service = DshService();
    expect(DshService.historyCacheLimit, greaterThan(0));

    service.debugSetCurrentSession(
      SessionMeta(sessionId: 'session-cache-a', title: '缓存测试'),
    );
    service.debugSetMessages([
      ChatMessage(
        id: 'm1',
        role: 'user',
        content: '第一条',
        timestamp: DateTime(2026, 10, 25),
      ),
    ]);

    // 走与 ensureFullHistory 收尾相同的 _cacheSessionHistory 路径。
    service.debugWriteHistoryCache();
    expect(service.debugHistoryCache('session-cache-a'),
        (messages: 1, exhausted: false));

    // 空消息不产生空快照（否则会用一个空壳覆盖已有的可用缓存）。
    service.debugSetMessages([]);
    service.debugWriteHistoryCache();
    expect(service.debugHistoryCache('session-cache-a')?.messages, 1);

    service.dispose();
    expect(service.isDisconnected, isTrue);
  });
}
