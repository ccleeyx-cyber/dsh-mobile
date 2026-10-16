import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/models/server_config.dart';
import 'package:dsh_mobile/services/secure_store.dart';
import 'package:dsh_mobile/services/storage_service.dart';

/// 用 MethodChannel 的 mock handler 假装"这台手机有 Keystore"，
/// 覆盖真机上才会走的那条路径：密文写成功 → 明文从 SharedPreferences 剥掉。
///
/// 这是本轮唯一能在本机验证"加密真的生效"的手段 —— 没有 Android SDK，跑不了
/// 真机；但 Dart 侧的判断逻辑（写后读回、剥不剥明文、重启后还读不读得回来）
/// 全部经过这个假的原生实现，分支覆盖是真实的。剩下没有覆盖的只有 Keystore
/// 本身的行为，那部分见交付报告第 4 节的如实声明。
///
/// 假实现直接拿"值"当"密文"存进一个 Map：这里要验的是**编排**（何时剥明文、
/// 何时保守保留），不是密码学 —— 密码学由 [SecureStoreBridge] 负责。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const kChannel = MethodChannel('dsh_mobile/secure');
  const kConfig = 'dsh_server_config';
  const kProfiles = 'dsh_server_profiles';
  const kActiveId = 'dsh_active_profile_id';
  const kTokenSlot = 'dsh_secure_token_';
  const kAuthSlot = 'dsh_secure_auth_';

  /// "手机上的密文"。进程重启不清空，模拟真实设备行为。
  final store = <String, String>{};

  /// 装一个假的 `dsh_mobile/secure`。
  ///
  /// [silentlyDropWrites] 模拟最危险的一类厂商 ROM 行为：write 不报错，
  /// 值却根本读不回来。Dart 侧必须靠"写后读回"发现它，然后**不删明文**。
  void installFakePlatform({bool silentlyDropWrites = false}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kChannel, (MethodCall call) async {
      // ping / read 可能不带参数（arguments 为 null），所以不能无条件强转。
      final raw = call.arguments;
      final args = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
      switch (call.method) {
        case 'ping':
          return true;
        case 'write':
          // 即便"读不出来"，值也确实被写进了原生存储文件 —— 这正是那种
          // 最恶心的厂商 ROM 行为：write 不报错，read 却回不出值。
          // 如果这里连存都不存，测试就变成了在验"根本没写过"，
          // 而不是在验"写了但读不回时 Dart 侧还敢不敢删明文"。
          store[args['key'] as String] = args['value'] as String;
          return null;
        case 'read':
          if (silentlyDropWrites) return null;
          return store[args['key'] as String];
        case 'delete':
          store.remove(args['key'] as String);
          return null;
      }
      return null;
    });
  }

  ServerConfig cfg({
    required String id,
    required String host,
    required String token,
    String authCode = '',
  }) =>
      ServerConfig(id: id, host: host, token: token, authCode: authCode);

  Future<Map<String, dynamic>?> rawConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kConfig);
    if (raw == null || raw.isEmpty) return null;
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  setUp(() {
    store.clear();
    SharedPreferences.setMockInitialValues({});
    SecureStore.resetForTesting();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kChannel, null);
  });

  group('有原生实现（Keystore 可用）', () {
    test('ping 之后 usingPlatform / isPlatformBacked 都为真', () async {
      installFakePlatform();
      await SecureStore.init();
      expect(SecureStore.usingPlatform, isTrue);
      expect(SecureStore.isPlatformBacked, isTrue);
    });

    test('写进去的值能原样读回来，才算"进去了"', () async {
      installFakePlatform();
      expect(await SecureStore.write('${kTokenSlot}a', 'tok-1'), isTrue);
      expect(await SecureStore.read('${kTokenSlot}a'), 'tok-1');
      expect(store['${kTokenSlot}a'], 'tok-1', reason: '确实落到了原生侧');
    });

    test('迁移后被读走：明文 token 从 SharedPreferences 里消失', () async {
      installFakePlatform();
      SharedPreferences.setMockInitialValues({
        kConfig: jsonEncode({
          'host': '172.20.128.1',
          'port': 3088,
          'token': 'legacy-token',
          'authCode': 'legacy-auth',
          'useHttps': false,
        }),
      });

      final c = await StorageService.loadConfig();
      expect(c!.token, 'legacy-token', reason: '业务层读到的仍是完整配置');
      expect(c.authCode, 'legacy-auth');

      // 这一条才是本轮的核心收益：SP 里不再有明文凭据。
      final raw = await rawConfig();
      expect(raw, isNotNull);
      expect(raw!.containsKey('token'), isFalse,
          reason: '密文可用时，明文必须从 SharedPreferences 抹掉');
      expect(raw.containsKey('authCode'), isFalse);
      expect(raw['host'], '172.20.128.1', reason: '非敏感字段照旧留在 SP');

      // 值本身落在 Keystore 保护的槽里。
      final tokenKey = '$kTokenSlot${c.id}';
      final authKey = '$kAuthSlot${c.id}';
      expect(store[tokenKey], 'legacy-token');
      expect(store[authKey], 'legacy-auth');
    });

    test('重启（Dart 侧缓存全清、明文已删）后仍能从密文读回 token', () async {
      installFakePlatform();
      SharedPreferences.setMockInitialValues({
        kConfig: jsonEncode({'host': 'h', 'port': 3088, 'token': 'legacy-token'}),
      });
      final first = (await StorageService.loadConfig())!;
      expect(first.token, 'legacy-token');

      // 模拟进程重启：Dart 侧缓存与降级表清空；"手机上的密文"（store）保留。
      SecureStore.resetForTesting();
      // 只保留升级**之后**真实落盘的形状：明文 token 已从配置里剥掉。
      SharedPreferences.setMockInitialValues({
        kConfig: jsonEncode({
          'id': first.id,
          'host': 'h',
          'port': 3088,
          'name': 'h',
          'useHttps': false,
          'npsAddress': '',
          'deviceId': '',
        }),
        kActiveId: first.id,
        kProfiles: jsonEncode([
          {
            'id': first.id,
            'host': 'h',
            'port': 3088,
            'name': 'h',
            'useHttps': false,
            'npsAddress': '',
            'deviceId': '',
          }
        ]),
      });

      await SecureStore.init();
      final again = await StorageService.loadConfig();
      expect(again, isNotNull);
      expect(again!.token, 'legacy-token',
          reason: '明文已删，凭据只能来自 Keystore —— 这条断了就是丢配置');
    });

    test('每一份 profile 的 token 各自加密存储，SP 列表里没有明文', () async {
      installFakePlatform();
      final a = await StorageService.upsertProfile(cfg(id: 'a', host: 'h-a', token: 't-a'));
      final b = await StorageService.upsertProfile(cfg(id: 'b', host: 'h-b', token: 't-b'));
      expect(a, hasLength(1));
      expect(b, hasLength(2));

      final prefs = await SharedPreferences.getInstance();
      final rawList = jsonDecode(prefs.getString(kProfiles)!) as List;
      for (final e in rawList) {
        final m = Map<String, dynamic>.from(e as Map);
        expect(m.containsKey('token'), isFalse, reason: '列表里也不许有明文 token');
        expect(m.containsKey('authCode'), isFalse);
      }

      final profiles = await StorageService.loadProfiles();
      expect(profiles.firstWhere((p) => p.id == 'a').token, 't-a');
      expect(profiles.firstWhere((p) => p.id == 'b').token, 't-b');
    });

    test('删除网关会把它在原生侧的密文一起删掉', () async {
      installFakePlatform();
      await StorageService.upsertProfile(cfg(id: 'a', host: 'h-a', token: 't-a'));
      expect(store.containsKey('${kTokenSlot}a'), isTrue);
      await StorageService.deleteProfile('a');
      expect(store.containsKey('${kTokenSlot}a'), isFalse);
      expect(store.containsKey('${kAuthSlot}a'), isFalse);
    });
  });

  group('原生实现"写得进读不出"（厂商 ROM 的典型失效）', () {
    test('写不进去时保留明文兜底，绝不出现两边都没有', () async {
      installFakePlatform(silentlyDropWrites: true);
      SharedPreferences.setMockInitialValues({
        kConfig: jsonEncode({'host': 'h', 'port': 3088, 'token': 'legacy-token'}),
      });

      final c = await StorageService.loadConfig();
      expect(c!.token, 'legacy-token', reason: '业务层照常能连上网关');

      final raw = await rawConfig();
      expect(raw!['token'], 'legacy-token',
          reason: '写后读回校验失败 → 明文必须保留。删掉它就是丢用户的凭据。');
      expect(store, isNotEmpty,
          reason: '值确实写进了原生存储 —— 读不回才是这里要防的故障');
    });

    test('之后每次读取都重试迁移，但结果始终一致（幂等、不越修越糟）', () async {
      installFakePlatform(silentlyDropWrites: true);
      SharedPreferences.setMockInitialValues({
        kConfig: jsonEncode({'host': 'h', 'port': 3088, 'token': 'legacy-token'}),
      });

      for (var i = 0; i < 3; i++) {
        final c = await StorageService.loadConfig();
        expect(c!.token, 'legacy-token');
      }
      final raw = await rawConfig();
      expect(raw!['token'], 'legacy-token');
      expect(await StorageService.loadProfiles(), hasLength(1));
    });
  });
}
