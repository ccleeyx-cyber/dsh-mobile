import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/models/server_config.dart';
import 'package:dsh_mobile/services/secure_store.dart';
import 'package:dsh_mobile/services/storage_service.dart';

/// 敏感字段（token / authCode）走 Keystore 存储的迁移与降级测试。
///
/// 跑在 Dart VM 上，也就是 **SecureStore 一定处于降级状态**（没有
/// `dsh_mobile/secure` 宿主）。这看似只测了降级，其实正好覆盖了最关键的两条：
///
///   1. **向后兼容**：所有既有公开 API 的返回值仍带 token，`loadProfiles()` /
///      `loadConfig()` / `setActiveProfile()` 的行为与改造前一致；
///   2. **失败不丢数据**：密文不可用时，明文必须原样留在 SharedPreferences 里，
///      不能出现"两边都没有"的窗口。
///
/// 真机上"密文可用 → 明文被剥掉"那一条只能靠 [SecureStore.isPlatformBacked]
/// 的分支逻辑保证，见交付报告第 4 节。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const kConfig = 'dsh_server_config';
  const kProfiles = 'dsh_server_profiles';
  const kActiveId = 'dsh_active_profile_id';
  const kTokenSlot = 'dsh_secure_token_';
  const kAuthSlot = 'dsh_secure_auth_';

  ServerConfig cfg({
    String id = '',
    String name = '',
    String host = '192.168.1.10',
    int port = 3088,
    String token = 'tok',
    String authCode = '',
    bool useHttps = false,
  }) =>
      ServerConfig(
        id: id,
        name: name,
        host: host,
        port: port,
        token: token,
        authCode: authCode,
        useHttps: useHttps,
      );

  /// 读回 profiles 键的原始 JSON，用来断言"SP 里到底写了什么"。
  Future<List<Map<String, dynamic>>> rawProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kProfiles);
    if (raw == null || raw.isEmpty) return const [];
    return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>?> rawConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kConfig);
    if (raw == null || raw.isEmpty) return null;
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SecureStore.resetForTesting();
  });

  group('降级标志（供测试与诊断断言）', () {
    test('Dart VM 上没有原生实现，SecureStore 如实报告降级', () async {
      // 触发一次初始化。
      await StorageService.loadProfiles();
      expect(SecureStore.usingPlatform, isFalse);
      expect(SecureStore.isPlatformBacked, isFalse,
          reason: 'isPlatformBacked=false 是"必须保留明文兜底"的判据');
    });
  });

  group('旧安装迁移：明文 → Keystore', () {
    setUp(() {
      // 精确复刻升级前的形状：token 与 authCode 明文躺在 dsh_server_config 里。
      SharedPreferences.setMockInitialValues({
        kConfig: jsonEncode({
          'host': '172.20.128.1',
          'port': 3088,
          'token': 'legacy-token',
          'useHttps': false,
          'npsAddress': '',
          'authCode': 'legacy-auth',
        }),
      });
    });

    test('loadConfig 仍能读到明文 token / authCode（升级不让用户重填）', () async {
      final c = await StorageService.loadConfig();
      expect(c, isNotNull);
      expect(c!.host, '172.20.128.1');
      expect(c.token, 'legacy-token');
      expect(c.authCode, 'legacy-auth');
      // 非敏感字段不受影响。
      expect(c.port, 3088);
      expect(c.useHttps, isFalse);
    });

    test('读取会把明文搬进 SecureStore 的对应槽位', () async {
      final c = await StorageService.loadConfig();
      expect(await SecureStore.read('$kTokenSlot${c!.id}'), 'legacy-token');
      expect(await SecureStore.read('$kAuthSlot${c.id}'), 'legacy-auth');
    });

    test('降级状态下**不**删除 SharedPreferences 里的明文（失败不丢数据）', () async {
      await StorageService.loadConfig();
      final raw = await rawConfig();
      expect(raw, isNotNull);
      expect(raw!['token'], 'legacy-token',
          reason: '密文只在进程内存里，删掉明文等于下次启动就丢凭据');
      expect(raw['authCode'], 'legacy-auth');
    });

    test('迁移是幂等的：反复读取不产生第二个 profile，id 也不变', () async {
      final first = await StorageService.loadProfiles();
      final second = await StorageService.loadProfiles();
      final third = await StorageService.loadProfiles();

      expect(second, hasLength(1));
      expect(third, hasLength(1));
      expect(second.first.id, first.first.id);
      expect(second.first.token, 'legacy-token');
      expect(third.first.token, 'legacy-token');
    });

    test('迁移后 active id 指向那唯一的网关，且列表里带得回 token', () async {
      final profiles = await StorageService.loadProfiles();
      expect(await StorageService.activeProfileId(), profiles.first.id);
      expect(profiles.first.token, 'legacy-token');
      expect(profiles.first.authCode, 'legacy-auth');
      // name 为空时回落到 host —— 与改造前一致。
      expect(profiles.first.name, '172.20.128.1');
    });

    test('保存一次后，明文与密文两份都还在，读回来的仍是正确的 token', () async {
      final c = (await StorageService.loadConfig())!;
      await StorageService.saveConfig(c);

      final again = await StorageService.loadConfig();
      expect(again!.token, 'legacy-token');
      expect(again.authCode, 'legacy-auth');

      final raw = await rawConfig();
      expect(raw!['token'], 'legacy-token',
          reason: 'SecureStore.isPlatformBacked=false 时 _scrub 必须保留明文');
    });

    test('profile 列表里每一项也各自拿到自己的凭据（不串号）', () async {
      await StorageService.saveConfig(cfg(id: 'a', host: 'h-a', token: 't-a'));
      await StorageService.saveConfig(cfg(id: 'b', host: 'h-b', token: 't-b'));

      final profiles = await StorageService.loadProfiles();
      final a = profiles.firstWhere((p) => p.id == 'a');
      final b = profiles.firstWhere((p) => p.id == 'b');
      expect(a.token, 't-a');
      expect(b.token, 't-b');
      expect(await SecureStore.read('${kTokenSlot}a'), 't-a');
      expect(await SecureStore.read('${kTokenSlot}b'), 't-b');
    });

    test('删掉网关会连它的密钥槽一起删（不留一条读不到的密文）', () async {
      await StorageService.saveConfig(cfg(id: 'a', host: 'h-a', token: 't-a'));
      await StorageService.deleteProfile('a');
      expect(await SecureStore.read('${kTokenSlot}a'), isNull);
      expect(await SecureStore.read('${kAuthSlot}a'), isNull);
    });
  });

  group('profile 列表里的明文凭据', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        kProfiles: jsonEncode([
          {
            'id': 'a',
            'host': '192.168.1.10',
            'port': 3088,
            'token': 'plain-a',
            'authCode': 'auth-a',
          },
          {
            'id': 'b',
            'host': '10.0.0.5',
            'port': 3089,
            'token': 'plain-b',
            'authCode': '',
          },
        ]),
        kActiveId: 'b',
      });
    });

    test('每一项的 token / authCode 都能读回来', () async {
      final profiles = await StorageService.loadProfiles();
      expect(profiles, hasLength(2));
      final a = profiles.firstWhere((p) => p.id == 'a');
      final b = profiles.firstWhere((p) => p.id == 'b');
      expect(a.token, 'plain-a');
      expect(a.authCode, 'auth-a');
      expect(b.token, 'plain-b');
      expect(b.authCode, '');
    });

    test('凭据被搬进各自的 id 槽位', () async {
      await StorageService.loadProfiles();
      expect(await SecureStore.read('${kTokenSlot}a'), 'plain-a');
      expect(await SecureStore.read('${kTokenSlot}b'), 'plain-b');
      expect(await SecureStore.read('${kAuthSlot}a'), 'auth-a');
    });

    test('降级状态下列表里的明文保持不动（幂等，不反复重写）', () async {
      await StorageService.loadProfiles();
      await StorageService.loadProfiles();
      final raw = await rawProfiles();
      expect(raw, hasLength(2));
      expect(raw.firstWhere((p) => p['id'] == 'a')['token'], 'plain-a');
      expect(raw.firstWhere((p) => p['id'] == 'b')['token'], 'plain-b');
    });

    test('切换 active 之后 loadConfig 拿到的是那一个网关的凭据', () async {
      final activated = await StorageService.setActiveProfile('a');
      expect(activated!.token, 'plain-a');

      final active = await StorageService.loadConfig();
      expect(active!.id, 'a');
      expect(active.token, 'plain-a');
      expect(active.host, '192.168.1.10');
    });

    test('缺 id 的项会被补 id，但 token 不会因为补 id 而丢失', () async {
      SharedPreferences.setMockInitialValues({
        kProfiles: jsonEncode([
          {'host': 'h-1', 'port': 3088, 'token': 'tok-1'},
        ]),
      });
      final profiles = await StorageService.loadProfiles();
      expect(profiles, hasLength(1));
      expect(profiles.first.id, isNotEmpty);
      expect(profiles.first.token, 'tok-1');
    });
  });

  group('密文不可用/解不开时的兜底', () {
    test('SecureStore 里没有值、SP 里有明文 → 用明文，且不抛异常', () async {
      SharedPreferences.setMockInitialValues({
        kProfiles: jsonEncode([
          {'id': 'a', 'host': 'h-a', 'port': 3088, 'token': 'only-plain'},
        ]),
        kActiveId: 'a',
      });
      // 模拟"密钥被系统清掉/密文损坏"：SecureStore 读不到任何东西。
      final c = await StorageService.loadConfig();
      expect(c, isNotNull);
      expect(c!.token, 'only-plain',
          reason: '读不到密文时必须回落到 SP 明文，而不是变成空 token');
    });

    test('两边都没有值 → 空 token，而不是抛异常', () async {
      SharedPreferences.setMockInitialValues({
        kConfig: jsonEncode({'host': 'h', 'port': 3088}),
      });
      final c = await StorageService.loadConfig();
      expect(c, isNotNull);
      expect(c!.token, '');
      expect(c.effectiveToken, '');
    });

    test('坏 JSON 仍然返回 null（与改造前一致）', () async {
      SharedPreferences.setMockInitialValues({kConfig: 'not-json'});
      expect(await StorageService.loadConfig(), isNull);
    });

    test('全新安装不写任何键，loadProfiles/loadConfig 都是空', () async {
      expect(await StorageService.loadProfiles(), isEmpty);
      expect(await StorageService.loadConfig(), isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty,
          reason: '空存储不得被迁移逻辑写入任何键，否则"是否旧安装"的判定会失真');
    });
  });

  group('既有公开 API 的兼容性', () {
    test('saveConfig → loadConfig 的完整往返（含 token 与 authCode）', () async {
      final c = cfg(id: 'gw-1', name: '家里台式机', host: '172.20.128.1', token: 'tok-x', authCode: 'auth-x');
      await StorageService.saveConfig(c);

      final loaded = await StorageService.loadConfig();
      expect(loaded!.id, 'gw-1');
      expect(loaded.name, '家里台式机');
      expect(loaded.host, '172.20.128.1');
      expect(loaded.token, 'tok-x');
      expect(loaded.authCode, 'auth-x');
      expect(loaded.deviceId, '');
      expect(loaded.useHttps, isFalse);
    });

    test('setActiveProfile 会同时更新 active 镜像与 active id', () async {
      await StorageService.upsertProfile(cfg(id: 'a', host: 'h-a', token: 't-a'));
      await StorageService.upsertProfile(cfg(id: 'b', host: 'h-b', token: 't-b'));

      final activated = await StorageService.setActiveProfile('b');
      expect(activated!.token, 't-b');
      expect(await StorageService.activeProfileId(), 'b');

      final active = await StorageService.loadConfig();
      expect(active!.id, 'b');
      expect(active.token, 't-b');
      expect(active.host, 'h-b');
    });

    test('renameProfile 同步 active 镜像时不会把 token 弄丢', () async {
      await StorageService.saveConfig(cfg(id: 'a', name: '旧名字', host: 'h-a', token: 't-a'));
      final after = await StorageService.renameProfile('a', '  新名字  ');
      expect(after.single.name, '新名字');

      final active = await StorageService.loadConfig();
      expect(active!.name, '新名字');
      expect(active.token, 't-a');
    });

    test('未知 id 返回 null，且不破坏现有 active config', () async {
      await StorageService.saveConfig(cfg(id: 'a', host: 'h-a', token: 't-a'));
      expect(await StorageService.setActiveProfile('missing'), isNull);
      expect((await StorageService.loadConfig())!.token, 't-a');
      expect(await StorageService.activeProfileId(), 'a');
    });

    test('删掉当前 active 网关后，active id 与 loadConfig 都不再指向它', () async {
      await StorageService.saveConfig(cfg(id: 'a', host: 'h-a', token: 't-a'));
      await StorageService.deleteProfile('a');

      expect(await StorageService.activeProfileId(), isNull);
      expect(await StorageService.loadConfig(), isNull,
          reason: '被用户删掉的网关不允许下次启动静默复活并重新连上');
      expect(await StorageService.loadProfiles(), isEmpty);
    });

    test('没有 active id 但配置带 id 且已在列表中 → 仍能读到（升级后的旧安装）', () async {
      // 升级路径可能留下"列表里有、active id 缺失"的中间态，这时不能判成"已删除"。
      SharedPreferences.setMockInitialValues({
        kConfig: jsonEncode({'id': 'a', 'host': 'h-a', 'port': 3088, 'token': 't-a'}),
        kProfiles: jsonEncode([
          {'id': 'a', 'host': 'h-a', 'port': 3088, 'token': 't-a'},
        ]),
      });
      final c = await StorageService.loadConfig();
      expect(c, isNotNull);
      expect(c!.id, 'a');
      expect(c.token, 't-a');
    });

    test('没有 id 的旧配置仍能读到（预 profile 时代）', () async {
      SharedPreferences.setMockInitialValues({
        kConfig: jsonEncode({'host': 'h-a', 'port': 3088, 'token': 't-a'}),
      });
      final c = await StorageService.loadConfig();
      expect(c, isNotNull);
      expect(c!.host, 'h-a');
      expect(c.token, 't-a');
    });

    test('非敏感键（主题 / 横幅记账）完全不受影响', () async {
      await StorageService.saveThemeMode('dark');
      expect(await StorageService.loadThemeMode(), 'dark');
      await StorageService.saveDismissedTurnFailures(['s1', 's2']);
      expect(await StorageService.loadDismissedTurnFailures(), ['s1', 's2']);
    });

    test('toJson 的形状仍然完整 —— 改造没有从模型层面删字段', () {
      final c = cfg(id: 'x', token: 't', authCode: 'a');
      expect(c.toJson().keys, containsAll(['id', 'name', 'host', 'port', 'token', 'useHttps', 'npsAddress', 'authCode', 'deviceId']));
      final round = ServerConfig.fromJson(jsonDecode(jsonEncode(c.toJson())));
      expect(round.token, 't');
      expect(round.authCode, 'a');
    });
  });
}
