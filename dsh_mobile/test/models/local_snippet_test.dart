import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/local_snippet.dart';

/// 本地快捷指令的模型层测试（Phase 5.4）。
///
/// 钉住两件容易悄悄退化的东西：
///  * `{param}` 的**识别**与**替换**必须用同一个正则 —— 一边改另一边没改，用户
///    就会遇到"显示有 3 个参数，实际只换了 2 个"；
///  * 留空的参数**原样保留**占位符，而不是静默替换成空串（静默删掉用户没填的那段，
///    比把占位符摆在他眼前糟得多）。
void main() {
  group('序列化', () {
    test('往返不丢字段', () {
      const s = LocalSnippet(
          id: 'local_1', label: '翻译', text: '翻成{lang}：', tag: '翻译');
      final back = LocalSnippet.fromJson(s.toJson());
      expect(back.id, 'local_1');
      expect(back.label, '翻译');
      expect(back.text, '翻成{lang}：');
      expect(back.tag, '翻译');
    });

    test('缺字段按空串处理，不抛（旧数据/手改过的数据不能整条丢）', () {
      final s = LocalSnippet.fromJson(const {'id': 'x'});
      expect(s.label, '');
      expect(s.text, '');
      expect(s.tag, '');
    });

    test('null 字段按空串处理', () {
      final s = LocalSnippet.fromJson(
          const {'id': null, 'label': null, 'text': null, 'tag': null});
      expect(s.id, '');
      expect(s.text, '');
    });
  });

  group('占位符识别', () {
    test('按出现顺序去重', () {
      expect(
          LocalSnippet.placeholderNames('把{原文}翻成{语言}，再检查{原文}'), ['原文', '语言']);
    });

    test('中文、下划线、连字符、点、数字都算名字', () {
      expect(
        LocalSnippet.placeholderNames('{a}{a_b}{a-b}{a.b}{1}'),
        ['a', 'a_b', 'a-b', 'a.b', '1'],
      );
    });

    test('代码里的花括号不会被误判成参数', () {
      expect(LocalSnippet.placeholderNames('{"a": 1}'), isEmpty);
      expect(LocalSnippet.placeholderNames('{1,2}'), isEmpty);
      expect(LocalSnippet.placeholderNames('{ }'), isEmpty);
      expect(LocalSnippet.placeholderNames('{}'), isEmpty);
    });

    test('超长（>24）不算参数', () {
      expect(LocalSnippet.placeholderNames('{${'a' * 25}}'), isEmpty);
    });

    test('没有占位符就是空列表（调用方据此跳过对话框）', () {
      expect(LocalSnippet.placeholderNames('继续'), isEmpty);
    });
  });

  group('占位符替换', () {
    test('填了值就替换，多个一次换完', () {
      expect(
        LocalSnippet.render('把{原文}翻成{语言}', const {'原文': '你好', '语言': '英文'}),
        '把你好翻成英文',
      );
    });

    test('留空的参数原样保留 {名字}（不静默删）', () {
      expect(
        LocalSnippet.render('把{原文}翻成{语言}', const {'原文': '你好', '语言': ''}),
        '把你好翻成{语言}',
      );
    });

    test('没提供的参数也原样保留', () {
      expect(
          LocalSnippet.render('把{原文}翻成{语言}', const {'原文': '你好'}), '把你好翻成{语言}');
    });

    test('替换结果里同一参数出现多次都会被换掉', () {
      expect(LocalSnippet.render('{a}-{a}-{b}', const {'a': 'x', 'b': 'y'}),
          'x-x-y');
    });

    test('替换值本身含花括号不会被二次解析', () {
      // 值里的 {} 是用户输入，不是新的占位符 —— 否则填进去的 JSON 会被吃掉。
      expect(LocalSnippet.render('{a}', const {'a': '{b}'}), '{b}');
    });

    test('没有占位符时原样返回', () {
      expect(LocalSnippet.render('继续', const {}), '继续');
    });
  });

  group('自动标签', () {
    test('取正文第一行前 12 字', () {
      expect(LocalSnippet.autoLabel('把下面这段翻成英文'), '把下面这段翻成英文');
      expect(LocalSnippet.autoLabel('\n\n第一行\n第二行'), '第一行');
      expect(LocalSnippet.autoLabel('很' * 20), '${'很' * 12}…');
    });

    test('全空白给出兜底名字', () {
      expect(LocalSnippet.autoLabel('   \n\t'), '未命名指令');
    });
  });
}
