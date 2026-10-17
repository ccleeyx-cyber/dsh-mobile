import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/models/local_snippet.dart';
import 'package:dsh_mobile/services/storage_service.dart';

/// 本地快捷指令的存储层测试（Phase 5.4）。
///
/// 全部跑在 SharedPreferences 的内存 mock 上，不读写任何真实设备数据。
///
/// 这一组测试真正关心的是**升级路径**：读不出来时绝不能把用户已有的数据清掉，
/// 缺字段也不能让整个列表解析失败。所以每个用例都直接摆"盘上的原始字符串"，
/// 而不是先 save 再 load —— 那只能证明自己写进去的能读回来。
void main() {
  const kKey = 'dsh_local_snippets';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<String?> rawValue() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(kKey);
  }

  group('缺省', () {
    test('键不存在 → 空列表，且不回写（"没有"与"空"要能区分）', () async {
      expect(await StorageService.loadLocalSnippets(), isEmpty);
      expect(await rawValue(), isNull);
    });

    test('空串 → 空列表', () async {
      SharedPreferences.setMockInitialValues({kKey: ''});
      expect(await StorageService.loadLocalSnippets(), isEmpty);
    });

    test('空数组 → 空列表', () async {
      SharedPreferences.setMockInitialValues({kKey: '[]'});
      expect(await StorageService.loadLocalSnippets(), isEmpty);
    });
  });

  group('读写往返', () {
    test('顺序、id、标签都保住（列表顺序就是界面顺序）', () async {
      const rows = [
        LocalSnippet(id: 'local_2', label: '第二条', text: 'b', tag: '写作'),
        LocalSnippet(id: 'local_1', label: '第一条', text: 'a'),
      ];
      await StorageService.saveLocalSnippets(rows);
      final back = await StorageService.loadLocalSnippets();
      expect(back.map((e) => e.id).toList(), ['local_2', 'local_1']);
      expect(back.first.label, '第二条');
      expect(back.first.tag, '写作');
      expect(back.last.tag, '');
    });

    test('保存空列表写的是 [] 而不是删键', () async {
      SharedPreferences.setMockInitialValues(
          {kKey: '[{"id":"a","label":"","text":"x"}]'});
      await StorageService.saveLocalSnippets(const []);
      expect(await rawValue(), '[]');
      expect(await StorageService.loadLocalSnippets(), isEmpty);
    });
  });

  group('旧数据兼容（不回写、不清数据）', () {
    test('缺 id → 按位置补一个，这一轮就能编辑/删除', () async {
      SharedPreferences.setMockInitialValues({
        kKey: jsonEncode([
          {'label': '第一条', 'text': 'a'},
          {'label': '第二条', 'text': 'b', 'tag': 'x'},
        ]),
      });
      final list = await StorageService.loadLocalSnippets();
      expect(list.map((e) => e.id).toList(), ['local-0', 'local-1']);
      expect(list[1].tag, 'x');
      // 读的过程不写盘：补出来的 id 要到下一次真正的保存才落盘。
      expect(await rawValue(), contains('"label":"第一条"'));
      expect(await rawValue(), isNot(contains('local-0')));
    });

    test('缺 label/tag → 空串，正文照旧', () async {
      SharedPreferences.setMockInitialValues({
        kKey: jsonEncode([
          {'id': 'a', 'text': '正文'},
        ]),
      });
      final list = await StorageService.loadLocalSnippets();
      expect(list.single.label, '');
      expect(list.single.tag, '');
      expect(list.single.text, '正文');
    });

    test('正文为空的条目跳过（它插不进输入框）', () async {
      SharedPreferences.setMockInitialValues({
        kKey: jsonEncode([
          {'id': 'a', 'label': '空', 'text': '   '},
          {'id': 'b', 'label': '有', 'text': '正文'},
        ]),
      });
      final list = await StorageService.loadLocalSnippets();
      expect(list.map((e) => e.id).toList(), ['b']);
    });

    test('坏 JSON → 空列表，但盘上的原文一个字都不动', () async {
      const broken = '[{"id":"a","text":"正文"';
      SharedPreferences.setMockInitialValues({kKey: broken});
      expect(await StorageService.loadLocalSnippets(), isEmpty);
      expect(await rawValue(), broken, reason: '读失败不等于没有数据，不能顺手把它删了');
    });

    test('值是对象而不是数组 → 空列表（也不回写）', () async {
      const obj = '{"id":"a"}';
      SharedPreferences.setMockInitialValues({kKey: obj});
      expect(await StorageService.loadLocalSnippets(), isEmpty);
      expect(await rawValue(), obj);
    });

    test('数组里混了非对象元素 → 能救的照救', () async {
      SharedPreferences.setMockInitialValues({
        kKey: jsonEncode([
          'not-a-map',
          42,
          {'id': 'ok', 'text': '正文'},
        ]),
      });
      final list = await StorageService.loadLocalSnippets();
      expect(list.map((e) => e.id).toList(), ['ok']);
    });
  });

  group('上限', () {
    test('保存超过上限时保留前 N 条（与界面顺序一致）', () async {
      final many = [
        for (var i = 0; i < StorageService.maxLocalSnippets + 5; i++)
          LocalSnippet(id: 'local_$i', label: '第$i', text: '正文$i'),
      ];
      await StorageService.saveLocalSnippets(many);
      final back = await StorageService.loadLocalSnippets();
      expect(back.length, StorageService.maxLocalSnippets);
      expect(back.first.id, 'local_0');
      expect(back.last.id, 'local_${StorageService.maxLocalSnippets - 1}');
    });

    test('盘上已超限的数据读取时截断，但不过量写回', () async {
      final raw = jsonEncode([
        for (var i = 0; i < StorageService.maxLocalSnippets + 5; i++)
          {'id': 'local_$i', 'label': '第$i', 'text': '正文$i'},
      ]);
      SharedPreferences.setMockInitialValues({kKey: raw});
      final back = await StorageService.loadLocalSnippets();
      expect(back.length, StorageService.maxLocalSnippets);
      expect(await rawValue(), raw);
    });
  });
}
