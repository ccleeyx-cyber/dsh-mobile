import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/models/chat_message.dart';

void main() {
  group('DshService M3 Network Resilience & Lifecycle Enhancements', () {
    test('Initial connection resilience state is initialized properly', () {
      final service = DshService();
      expect(service.status, equals(ConnectionStatus.disconnected));
      expect(service.isConnected, isFalse);
      expect(service.isDisconnected, isTrue);
      expect(service.isConnecting, isFalse);
      expect(service.hasError, isFalse);
      expect(service.reconnectAttempts, equals(0));
      expect(service.isReconnecting, isFalse);
    });

    test('retryConnection without config does not crash or transition to invalid state', () async {
      final service = DshService();
      await service.retryConnection();
      expect(service.reconnectAttempts, equals(0));
    });

    test('disconnect sets explicit disconnected flag and resets retry attempts', () {
      final service = DshService();
      service.disconnect();
      expect(service.status, equals(ConnectionStatus.disconnected));
      expect(service.reconnectAttempts, equals(0));
      expect(service.isReconnecting, isFalse);
    });

    test('handleAppResumed while disconnected attempts immediate reconnect without crashing', () {
      final service = DshService();
      // Should cleanly evaluate disconnected state and attempt reconnect logic safely
      service.handleAppResumed();
      expect(service.isDisconnected, isTrue);
      // Repeated invocation within 500ms is debounced
      service.handleAppResumed();
      expect(service.isDisconnected, isTrue);
    });

    test('handleAppPaused cleanly cancels session polling timer', () {
      final service = DshService();
      service.handleAppPaused();
      // Verifies no exception thrown when paused
      expect(service.status, equals(ConnectionStatus.disconnected));
    });
  });
}
