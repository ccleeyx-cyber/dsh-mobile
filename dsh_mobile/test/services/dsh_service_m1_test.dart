import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/models/chat_message.dart';

void main() {
  group('DshService M1 Enhancements', () {
    test('streamRevision starts at 0 and is readable', () {
      final service = DshService();
      expect(service.streamRevision, equals(0));
      expect(service.isCanceling, isFalse);
    });

    test('cancelActiveTurn synchronously updates local state and prevents orphaned streams', () async {
      final service = DshService();

      // Add a mock assistant message in streaming state with a running tool
      final streamingMsg = ChatMessage(
        id: 'msg-1',
        role: 'assistant',
        content: 'Analyzing repository structure...',
        thinking: 'Checking package layout...',
        isStreaming: true,
        tools: [
          ToolExecution(name: 'list_files', input: '.', isRunning: true),
        ],
      );
      service.messages.add(streamingMsg);

      // Invoke cancelActiveTurn without active HTTP server configured (should catch and gracefully complete)
      await service.cancelActiveTurn();

      // Verify that after cancelActiveTurn:
      // 1. isCanceling is false (finally block completed)
      expect(service.isCanceling, isFalse);
      // 2. isSending is false
      expect(service.isSending, isFalse);
      // 3. message streaming flag cleared
      expect(service.messages.last.isStreaming, isFalse);
      // 4. tools are not running
      expect(service.messages.last.tools.first.isRunning, isFalse);
      // 5. stop notice appended to content
      expect(service.messages.last.content, contains('*(任务已被手动停止)*'));
      // 6. streamRevision was incremented
      expect(service.streamRevision, greaterThan(0));
    });
  });
}
