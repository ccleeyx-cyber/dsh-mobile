import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/services/secure_store.dart';

/// [SecureStore] 的降级契约测试。
///
/// 全部跑在 Dart VM 上 —— 也就是**没有** MethodChannel 宿主的那种环境，
/// `MethodChannel('dsh_mobile/secure')` 的每次调用都会抛
/// `MissingPluginException`。这正是本层必须优雅降级的那条路径：它一旦把异常
/// 抛出去，`StorageService` 会连带炸掉 40+ 个既有测试，真机上则是启动即崩。
///
/// 真机（Keystore 可用）那条路径没法在这里断言，只能靠方法契约 + 交付说明声明。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 每个用例从零开始：既清 SharedPreferences，也清 SecureStore 的静态缓存
    // 与内存降级表（它们跨用例存活，不清会互相串状态）。
    SharedPreferences.setMockInitialValues({});
    SecureStore.resetForTesting();
  });

  group('无原生实现时的降级', () {
    test('init() 不抛异常，并标记 usingPlatform=false', () async {
      await SecureStore.init();
      expect(SecureStore.usingPlatform, isFalse,
          reason: 'Dart VM 没有 dsh_mobile/secure 的宿主，必须如实报告降级');
      expect(SecureStore.isPlatformBacked, isFalse);
    });

    test('read/write/delete 都不抛异常，write 返回 false 表示"没进 Keystore"', () async {
      // write 的返回值是调用方唯一能依赖的信号：false = 明文必须继续兜底。
      expect(await SecureStore.write('dsh_secure_token_a', 'tok-1'), isFalse);
      expect(await SecureStore.read('dsh_secure_token_a'), 'tok-1');

      await SecureStore.delete('dsh_secure_token_a');
      expect(await SecureStore.read('dsh_secure_token_a'), isNull);
    });

    test('没写过的键读回 null（而不是抛 / 空串）', () async {
      expect(await SecureStore.read('dsh_secure_token_missing'), isNull);
    });

    test('降级是逐调用的：先 read 再 write 也不会突然开始抛异常', () async {
      await SecureStore.read('k1');
      await SecureStore.write('k1', 'v1');
      await SecureStore.delete('k1');
      await SecureStore.readAll(['k1', 'k2']);
      expect(await SecureStore.writeAll({'k3': 'v3'}), isFalse);
      expect(await SecureStore.read('k3'), 'v3');
    });

    test('空串按"没有值"处理，读回 null', () async {
      await SecureStore.write('k-empty', '');
      // 空 token 与"没有 token"在连接层是同一件事，不能因为空串就认为是密文。
      expect(await SecureStore.read('k-empty'), isNull);
    });
  });

  group('读取缓存', () {
    test('同键二次读取命中缓存，结果一致', () async {
      await SecureStore.write('k', 'v');
      expect(await SecureStore.read('k'), 'v');
      expect(await SecureStore.read('k'), 'v');
    });

    test('删除会同时作废缓存与降级表，不会读回旧值', () async {
      await SecureStore.write('k', 'v');
      await SecureStore.read('k');
      await SecureStore.delete('k');
      expect(await SecureStore.read('k'), isNull);
    });

    test('SharedPreferences 被重置（模拟进程重启）后降级值不残留', () async {
      await SecureStore.write('k', 'v');
      expect(await SecureStore.read('k'), 'v');

      SharedPreferences.setMockInitialValues({});
      // 内存表必须整体作废：否则上一条用例/上一次运行的降级值会冒充密文，
      // 让"明明没存过的 token"被读出来。
      expect(await SecureStore.read('k'), isNull);
    });
  });

  group('批量接口契约', () {
    test('readAll 一定包含所有请求的键，缺失为 null', () async {
      await SecureStore.write('a', '1');
      final r = await SecureStore.readAll(['a', 'b']);
      expect(r.containsKey('a'), isTrue);
      expect(r.containsKey('b'), isTrue);
      expect(r['a'], '1');
      expect(r['b'], isNull);
    });

    test('writeAll 任一项没进 Keystore 就返回 false（保守但不丢数据）', () async {
      expect(await SecureStore.writeAll({'a': '1', 'b': '2'}), isFalse);
      expect(await SecureStore.read('a'), '1');
      expect(await SecureStore.read('b'), '2');
    });
  });
}
