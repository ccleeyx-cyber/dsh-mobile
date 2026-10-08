import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/models/server_config.dart';
import 'package:dsh_mobile/services/storage_service.dart';

/// 多网关（§4.2-5）的存储层测试。
///
/// 全部跑在 SharedPreferences 的内存 mock 上（setMockInitialValues），
/// 不读写任何真实设备数据。
void main() {
  const kConfig = 'dsh_server_config';
  const kProfiles = 'dsh_server_profiles';
  const kActiveId = 'dsh_active_profile_id';

  ServerConfig cfg({
    String id = '',
    String name = '',
    String host = '192.168.1.10',
    int port = 3088,
    String token = 'tok',
  }) =>
      ServerConfig(id: id, name: name, host: host, port: port, token: token);

  setUp(() {
    // 每个用例都从空存储开始，避免用例之间串状态。
    SharedPreferences.setMockInitialValues({});
  });

  group('ServerConfig 序列化向后兼容', () {
    test('旧数据没有 id/name 字段时不抛异常，且回落到空串', () {
      // 升级前写入的 JSON 就是这个形状：只有 host/port/token/useHttps/npsAddress/authCode。
      final legacy = {
        'host': '10.0.0.5',
        'port': 3088,
        'token': 'abc',
        'useHttps': false,
        'npsAddress': '',
        'authCode': '',
      };
      final c = ServerConfig.fromJson(legacy);
      expect(c.id, '');
      expect(c.name, '');
      expect(c.host, '10.0.0.5');
      expect(c.token, 'abc');
    });

    test('port 被存成字符串时也能解析，而不是整个 load 失败', () {
      final c = ServerConfig.fromJson({'host': 'h', 'port': '3099', 'token': 't'});
      expect(c.port, 3099);
    });

    test('useHttps 接受布尔与字符串两种形状', () {
      expect(ServerConfig.fromJson({'host': 'h', 'token': 't', 'useHttps': true}).useHttps, isTrue);
      expect(ServerConfig.fromJson({'host': 'h', 'token': 't', 'useHttps': 'true'}).useHttps, isTrue);
      expect(ServerConfig.fromJson({'host': 'h', 'token': 't'}).useHttps, isFalse);
    });

    test('id/name 会随 toJson 往返', () {
      final c = cfg(id: 'gw-1', name: '家里台式机');
      final round = ServerConfig.fromJson(jsonDecode(jsonEncode(c.toJson())));
      expect(round.id, 'gw-1');
      expect(round.name, '家里台式机');
    });

    test('displayName 回落顺序：name → host → 未命名网关', () {
      expect(cfg(name: '公司笔记本', host: '1.2.3.4').displayName, '公司笔记本');
      expect(cfg(name: '   ', host: '1.2.3.4').displayName, '1.2.3.4');
      expect(cfg(name: '', host: '').displayName, '未命名网关');
    });

    test('clone(id: "") 强制产生新身份，用于「另存为新网关」', () {
      final c = cfg(id: 'gw-1', name: 'A', host: 'h1');
      final copy = c.clone(id: '', name: 'B');
      expect(copy.id, '');
      expect(copy.name, 'B');
      // 连接字段必须原样带过来，否则另存会丢 host/token。
      expect(copy.host, 'h1');
      expect(copy.token, 'tok');
      expect(copy.port, 3088);
    });
  });

  group('全新安装', () {
    test('loadProfiles 返回空列表，且不写任何键', () async {
      final profiles = await StorageService.loadProfiles();
      expect(profiles, isEmpty);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty,
          reason: '空存储不应被 migration 写入任何键，否则下次判定「是否旧安装」会失真');
    });

    test('loadConfig 返回 null', () async {
      expect(await StorageService.loadConfig(), isNull);
    });

    test('activeProfileId 返回 null', () async {
      expect(await StorageService.activeProfileId(), isNull);
    });
  });

  group('旧安装迁移（只写了 dsh_server_config）', () {
    setUp(() {
      // 精确复刻升级前的存储形状：无 id、无 name、无 profiles 键。
      SharedPreferences.setMockInitialValues({
        kConfig: jsonEncode({
          'host': '172.20.128.1',
          'port': 3088,
          'token': 'legacy-token',
          'useHttps': false,
          'npsAddress': '115.150.53.154:8024',
          'authCode': '',
        }),
      });
    });

    test('把单一配置提升为第一个 profile，并补上 id 与 name', () async {
      final profiles = await StorageService.loadProfiles();
      expect(profiles, hasLength(1));
      expect(profiles.first.id, isNotEmpty);
      expect(profiles.first.token, 'legacy-token');
      // name 为空时回落到 host，让切换器里有个能认的标签。
      expect(profiles.first.name, '172.20.128.1');
    });

    test('迁移是幂等的：再读一次不会产生第二个 profile', () async {
      final first = await StorageService.loadProfiles();
      final second = await StorageService.loadProfiles();
      expect(second, hasLength(1));
      expect(second.first.id, first.first.id, reason: '同一个网关必须保持同一个 id');
    });

    test('迁移会记住 active id，且不动原有的 dsh_server_config', () async {
      final profiles = await StorageService.loadProfiles();
      expect(await StorageService.activeProfileId(), profiles.first.id);

      // 关键：main.dart 启动时读的就是这个键，迁移不能破坏它。
      final active = await StorageService.loadConfig();
      expect(active, isNotNull);
      expect(active!.host, '172.20.128.1');
      expect(active.token, 'legacy-token');
    });

    test('迁移后 loadConfig 仍然可用（升级不能让用户重新填一遍）', () async {
      await StorageService.loadProfiles();
      final active = await StorageService.loadConfig();
      expect(active!.npsAddress, '115.150.53.154:8024');
    });
  });

  group('saveConfig', () {
    test('给无 id 的配置分配 id，并写入 active id', () async {
      final c = cfg(host: 'h1');
      expect(c.id, '');
      await StorageService.saveConfig(c);

      // id 是就地写回入参的，调用方据此得知刚存的是哪一个。
      expect(c.id, isNotEmpty);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kActiveId), c.id);
      expect(await StorageService.activeProfileId(), c.id);
    });

    test('同一个网关重复保存不会在列表里堆出重复项', () async {
      final c = cfg(host: 'h1');
      await StorageService.saveConfig(c);
      c.host = 'h1-edited';
      await StorageService.saveConfig(c);

      final profiles = await StorageService.loadProfiles();
      expect(profiles, hasLength(1));
      expect(profiles.first.host, 'h1-edited');
    });

    test('保存的 active config 与 profiles 列表保持一致', () async {
      final c = cfg(id: 'gw-x', name: 'X', host: 'hX');
      await StorageService.saveConfig(c);

      final active = await StorageService.loadConfig();
      final profiles = await StorageService.loadProfiles();
      expect(active!.id, 'gw-x');
      expect(profiles.single.id, 'gw-x');
      expect(profiles.single.host, active.host);
    });
  });

  group('upsertProfile / deleteProfile', () {
    test('upsert 按 id 替换而不是追加', () async {
      await StorageService.upsertProfile(cfg(id: 'a', host: 'h-a'));
      final after = await StorageService.upsertProfile(cfg(id: 'a', host: 'h-a2'));
      expect(after, hasLength(1));
      expect(after.first.host, 'h-a2');
    });

    test('upsert 不同 id 则追加，并保持插入顺序', () async {
      await StorageService.upsertProfile(cfg(id: 'a', name: 'A'));
      await StorageService.upsertProfile(cfg(id: 'b', name: 'B'));
      final profiles = await StorageService.loadProfiles();
      expect(profiles.map((p) => p.id).toList(), ['a', 'b']);
    });

    test('upsert 给无 id 的配置分配 id 并回写入参', () async {
      final c = cfg();
      final profiles = await StorageService.upsertProfile(c);
      expect(c.id, isNotEmpty);
      expect(profiles.single.id, c.id);
    });

    test('deleteProfile 移除目标并保留其它', () async {
      await StorageService.upsertProfile(cfg(id: 'a'));
      await StorageService.upsertProfile(cfg(id: 'b'));
      final after = await StorageService.deleteProfile('a');
      expect(after.map((p) => p.id).toList(), ['b']);
    });

    test('删掉当前 active 网关时清空 active id', () async {
      final c = cfg(id: 'a');
      await StorageService.saveConfig(c);
      expect(await StorageService.activeProfileId(), 'a');

      await StorageService.deleteProfile('a');
      expect(await StorageService.activeProfileId(), isNull,
          reason: 'active id 指向已删除的网关会让 DropdownButton 断言失败');
    });

    test('删掉非 active 网关时不动 active id', () async {
      await StorageService.saveConfig(cfg(id: 'a'));
      await StorageService.upsertProfile(cfg(id: 'b'));
      await StorageService.deleteProfile('b');
      expect(await StorageService.activeProfileId(), 'a');
    });

    test('删除不存在的 id 是无害的 no-op', () async {
      await StorageService.upsertProfile(cfg(id: 'a'));
      final after = await StorageService.deleteProfile('nope');
      expect(after.map((p) => p.id).toList(), ['a']);
    });
  });

  group('setActiveProfile', () {
    test('切换 active 会同步 dsh_server_config（下次启动连的就是它）', () async {
      await StorageService.upsertProfile(cfg(id: 'a', host: 'h-a', token: 't-a'));
      await StorageService.upsertProfile(cfg(id: 'b', host: 'h-b', token: 't-b'));

      final activated = await StorageService.setActiveProfile('b');
      expect(activated, isNotNull);
      expect(activated!.host, 'h-b');

      // main.dart 启动路径读的是 loadConfig()，所以它必须跟着变。
      final active = await StorageService.loadConfig();
      expect(active!.id, 'b');
      expect(active.host, 'h-b');
      expect(active.token, 't-b');
      expect(await StorageService.activeProfileId(), 'b');
    });

    test('未知 id 返回 null，且不破坏现有的 active config', () async {
      await StorageService.saveConfig(cfg(id: 'a', host: 'h-a'));
      final r = await StorageService.setActiveProfile('missing');
      expect(r, isNull);
      expect((await StorageService.loadConfig())!.host, 'h-a');
      expect(await StorageService.activeProfileId(), 'a');
    });
  });

  group('renameProfile', () {
    test('重命名 active 网关会同步到 dsh_server_config', () async {
      await StorageService.saveConfig(cfg(id: 'a', name: '旧名字', host: 'h-a'));
      final after = await StorageService.renameProfile('a', '  新名字  ');

      expect(after.single.name, '新名字', reason: '名字应被 trim');
      final active = await StorageService.loadConfig();
      expect(active!.name, '新名字', reason: '否则下次启动载入的标签与列表不一致');
    });

    test('重命名非 active 网关不改动 dsh_server_config', () async {
      await StorageService.saveConfig(cfg(id: 'a', name: 'A', host: 'h-a'));
      await StorageService.upsertProfile(cfg(id: 'b', name: 'B', host: 'h-b'));

      await StorageService.renameProfile('b', 'B2');
      final active = await StorageService.loadConfig();
      expect(active!.id, 'a');
      expect(active.name, 'A');

      final profiles = await StorageService.loadProfiles();
      expect(profiles.firstWhere((p) => p.id == 'b').name, 'B2');
    });

    test('重命名不存在的 id 是无害的 no-op', () async {
      await StorageService.upsertProfile(cfg(id: 'a', name: 'A'));
      final after = await StorageService.renameProfile('nope', 'X');
      expect(after.single.name, 'A');
    });
  });

  group('健壮性', () {
    test('profiles 键损坏时不抛异常，回落到从 active config 重建', () async {
      SharedPreferences.setMockInitialValues({
        kProfiles: '{这不是合法 JSON',
        kConfig: jsonEncode({'host': 'h-recover', 'port': 3088, 'token': 't'}),
      });

      final profiles = await StorageService.loadProfiles();
      expect(profiles, hasLength(1));
      expect(profiles.first.host, 'h-recover');
    });

    test('profiles 里混入非对象元素时跳过而不是崩', () async {
      SharedPreferences.setMockInitialValues({
        kProfiles: jsonEncode([
          {'id': 'a', 'host': 'h-a', 'port': 3088, 'token': 't'},
          42,
          'junk',
          {'id': 'b', 'host': 'h-b', 'port': 3088, 'token': 't'},
        ]),
      });
      final profiles = await StorageService.loadProfiles();
      expect(profiles.map((p) => p.id).toList(), ['a', 'b']);
    });

    test('profiles 里某项缺 id 时补一个，避免列表出现两个空 id 互相覆盖', () async {
      SharedPreferences.setMockInitialValues({
        kProfiles: jsonEncode([
          {'host': 'h-1', 'port': 3088, 'token': 't'},
          {'host': 'h-2', 'port': 3088, 'token': 't'},
        ]),
      });
      final profiles = await StorageService.loadProfiles();
      expect(profiles, hasLength(2));
      expect(profiles[0].id, isNotEmpty);
      expect(profiles[1].id, isNotEmpty);
      expect(profiles[0].id, isNot(profiles[1].id));
    });

    test('newId 连续调用不产生碰撞', () {
      final ids = List.generate(2000, (_) => StorageService.newId());
      expect(ids.toSet().length, ids.length);
    });

    test('loadConfig 在内容非法时返回 null 而不是抛异常', () async {
      SharedPreferences.setMockInitialValues({kConfig: 'not-json'});
      expect(await StorageService.loadConfig(), isNull);
    });

    test('多网关各自保留独立的 host/token（切换的真实价值所在）', () async {
      await StorageService.saveConfig(cfg(id: 'lan', name: '局域网', host: '172.20.128.1', token: 't-lan'));
      await StorageService.saveConfig(cfg(id: 'nps', name: 'nps 隧道', host: '115.150.53.154', port: 8024, token: 't-nps'));

      final profiles = await StorageService.loadProfiles();
      expect(profiles, hasLength(2));

      final lan = profiles.firstWhere((p) => p.id == 'lan');
      final nps = profiles.firstWhere((p) => p.id == 'nps');
      expect(lan.httpBaseUrl, 'http://172.20.128.1:3088');
      expect(nps.httpBaseUrl, 'http://115.150.53.154:8024');
      expect(lan.token, 't-lan');
      expect(nps.token, 't-nps');

      // 切回局域网：active config 必须完整跟着换，包括 token。
      await StorageService.setActiveProfile('lan');
      final active = await StorageService.loadConfig();
      expect(active!.httpBaseUrl, 'http://172.20.128.1:3088');
      expect(active.token, 't-lan');
    });
  });
}
