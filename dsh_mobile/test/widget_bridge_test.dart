import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/services/widget_bridge.dart';

/// v1.35 / 3.5 —— 小组件状态推送的节流与容错。
///
/// 小组件是"增强"，不是主链路：它的每一条失败路径都必须是静默的。
/// 这里钉三件事：
///  1. 内容没变不重复推（否则每次 delta 都刷一遍 RemoteViews）；
///  2. 5 秒内连续变化只推一次（节流），force 时不受限；
///  3. 原生通道不存在（多数用户没添加部件）时不抛异常。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <Map<Object?, Object?>>[];
  bool failChannel = false;

  setUp(() {
    calls.clear();
    failChannel = false;
    WidgetBridge.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dsh_mobile/widget'), (call) async {
      if (failChannel) throw PlatformException(code: 'missing_plugin');
      if (call.method == 'update') {
        calls.add((call.arguments as Map).cast<Object?, Object?>());
      }
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dsh_mobile/widget'), null);
  });

  test('内容相同不重复推送', () async {
    const data = {'title': '会话 A', 'status': '空闲', 'context': '', 'approvals': 0};
    await WidgetBridge.push(data, force: true);
    await WidgetBridge.push(data, force: true);
    expect(calls.length, 2, reason: 'force 时必须推送');

    WidgetBridge.debugReset();
    calls.clear();
    await WidgetBridge.push(data);
    await WidgetBridge.push(data);
    expect(calls.length, 1, reason: '第二次内容相同应被去重');
  });

  test('5 秒内的连续变化合并成一次', () async {
    await WidgetBridge.push({'status': '未连接'});
    await WidgetBridge.push({'status': '空闲'});
    await WidgetBridge.push({'status': '执行中'});
    expect(calls.length, 1);
    expect(calls.first['status'], '未连接');
  });

  test('approvals > 0 时 force 绕过节流（有活要处理，必须立刻显示）', () async {
    await WidgetBridge.push({'status': '空闲', 'approvals': 0});
    await WidgetBridge.push({'status': '空闲', 'approvals': 1}, force: true);
    expect(calls.length, 2);
    expect(calls.last['approvals'], 1);
  });

  test('原生通道缺失时静默失败', () async {
    failChannel = true;
    await expectLater(WidgetBridge.push({'status': 'x'}), completes);
    await expectLater(WidgetBridge.clear(), completes);
  });
}
