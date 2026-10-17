import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/services/voice_input_service.dart';

/// [fix 2026-10-17] onAutoStopped 自赋值 no-op 的回归钉。
///
/// 此前 start() 的 fake 分支写的是 `onAutoStopped = onAutoStopped`（参数自赋
/// 值），实例字段永远是 null —— init() 的 onStatus 回调读不到它，引擎自动
/// 结束（静音超时/时长上限）永远无法通知 UI，[fix 2026-10-12] 特性整体失效。
void main() {
  setUp(() {
    VoiceInputService.instance.debugClearFakeRecognition();
    VoiceInputService.instance.debugResetAutoStop();
  });

  test('start() 后实例字段已挂上 onAutoStopped（fake 路径）', () async {
    VoiceInputService.instance.debugSetFakeRecognition(partials: ['你好']);
    String? stoppedReason;
    final ok = await VoiceInputService.instance.start(
      onPartial: (_, __) {},
      onFinal: (_) {},
      onAutoStopped: (reason) => stoppedReason = reason,
    );
    expect(ok, isTrue);
    // 触发引擎自动结束：debugFireAutoStopped 模拟 onStatus(done) 路径。
    VoiceInputService.instance.debugFireAutoStopped('done');
    expect(stoppedReason, 'done');
    // 迟到的状态只触发一次：之后自动摘除（原语义保持）。
    VoiceInputService.instance.debugFireAutoStopped('done');
    expect(stoppedReason, 'done');
  });

  test('start() 不传 onAutoStopped 时实例字段为 null（不残留上一次的回调）', () async {
    VoiceInputService.instance.debugSetFakeRecognition(partials: ['a']);
    await VoiceInputService.instance.start(
      onPartial: (_, __) {},
      onFinal: (_) {},
      onAutoStopped: (_) {},
    );
    await VoiceInputService.instance.start(
      onPartial: (_, __) {},
      onFinal: (_) {},
      // 不传 onAutoStopped
    );
    String? notCalled;
    VoiceInputService.instance.debugFireAutoStopped('done');
    expect(notCalled, isNull);
  });
}
