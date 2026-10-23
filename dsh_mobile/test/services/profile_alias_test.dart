import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/models/server_config.dart';
import 'package:dsh_mobile/services/storage_service.dart';

/// [feat 2026-10-22] 网关**别名**。
///
/// 用户原话：「app 连接那里，需要加一个别名，像我现在需要连接多个 dsh 客户端，
/// 域名相同的话就没办法区分了」。
///
/// 存储层要保证两件事：
///   1. 别名跟着网关一起存/读出来（下拉框显示的就是它）；
///   2. 新建时撞名要**自动区分**（`(2)` / `(3)`），否则同域名两台电脑在下拉框里
///      依旧是两行一模一样的字 —— 那正是这次需求的起因。
void main() {
  ServerConfig cfg({
    String id = '',
    String name = '',
    String host = 'dsh.example.com',
    int port = 3088,
  }) =>
      ServerConfig(id: id, name: name, host: host, port: port, token: 'tok');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('别名随网关存取', () {
    test('保存后能原样读回，displayName 用别名而不是域名', () async {
      final saved = cfg(name: '公司笔记本');
      await StorageService.upsertProfile(saved);
      final list = await StorageService.loadProfiles();
      expect(list.length, 1);
      expect(list.single.name, '公司笔记本');
      expect(list.single.displayName, '公司笔记本');
    });

    test('同域名不同别名的两条能共存（不会被当成同一条覆盖）', () async {
      final a = cfg(name: '台式机', port: 3088);
      final b = cfg(name: '笔记本', port: 3088);
      await StorageService.upsertProfile(a);
      await StorageService.upsertProfile(b);
      final list = await StorageService.loadProfiles();
      expect(list.length, 2);
      expect(list.map((c) => c.displayName).toSet(), {'台式机', '笔记本'});
      // 两条的 id 必须不同：id 才是身份，域名/端口不是
      expect(list.map((c) => c.id).toSet().length, 2);
    });

    test('别名留空时 displayName 回落到地址', () async {
      final c = cfg(host: 'dsh.example.com', port: 3099);
      await StorageService.upsertProfile(c);
      final list = await StorageService.loadProfiles();
      expect(list.single.name, '');
      expect(list.single.displayName, 'dsh.example.com');
    });
  });

  group('uniqueProfileName：新建时自动区分', () {
    test('用户填了别名就照用', () {
      final name = StorageService.uniqueProfileName(
        [cfg(id: 'a', name: '别的机器')],
        '机房-01',
        fallback: 'dsh.example.com:3088',
      );
      expect(name, '机房-01');
    });

    test('没填别名就用「主机:端口」兜底', () {
      final name = StorageService.uniqueProfileName(
        const [],
        '   ',
        fallback: 'dsh.example.com:3088',
      );
      expect(name, 'dsh.example.com:3088');
    });

    test('撞名自动加 (2)(3)，大小写不敏感', () {
      final existing = [
        cfg(id: 'a', name: 'dsh.example.com:3088'),
        cfg(id: 'b', name: 'DSH.example.com:3088 (2)'),
      ];
      expect(
        StorageService.uniqueProfileName(existing, '', fallback: 'dsh.example.com:3088'),
        'dsh.example.com:3088 (3)',
      );
    });

    test('编辑自己时不算撞名（excludeId）', () {
      final existing = [cfg(id: 'a', name: '台式机')];
      expect(
        StorageService.uniqueProfileName(existing, '台式机', fallback: 'x', excludeId: 'a'),
        '台式机',
      );
    });

    test('两边都空也不会出现空别名', () {
      expect(StorageService.uniqueProfileName(const [], '', fallback: ''), '未命名网关');
    });
  });
}
