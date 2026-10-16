import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/widgets/genui/genui_parse.dart';

/// ```dsh-ui 围栏切分的回归测试。
///
/// 这层的失败模式有两种，且方向相反：**该认出却没认出**（组件被当代码块画出来，
/// 用户看到一坨 JSON）和**不该动却动了**（普通 markdown 被切碎、代码块被吞掉）。
/// 所以下面每组断言都成对。
void main() {
  const fence = '```';

  String message(String body, {String info = 'dsh-ui'}) =>
      '先看结论。\n\n$fence$info\n$body\n$fence\n\n以上。';

  group('切分：识别与保留', () {
    test('把消息切成 markdown 段与规格段', () {
      final segments = parseGenuiSegments(message('{"title":"概览","items":[]}'));
      expect(segments.whereType<GenuiSpecSegment>().length, 1);
      expect(segments.whereType<MarkdownSegment>().length, 2);
      expect(segments.first, isA<MarkdownSegment>());
      expect((segments.first as MarkdownSegment).text, contains('先看结论'));
    });

    test('info string 里含 dsh-ui 词就算（json dsh-ui 也认）', () {
      final segments = parseGenuiSegments(
        message('{"items":[{"type":"divider"}]}', info: 'json dsh-ui'),
      );
      expect(segments.whereType<GenuiSpecSegment>().length, 1);
    });

    test('没有围栏的消息整条是 markdown，且内容逐字不变', () {
      const text = '普通回答，带 ```dart 代码块\nvoid main() {}\n``` 结束。';      final segments = parseGenuiSegments(text);
      expect(segments.length, 1);
      expect((segments.single as MarkdownSegment).text, text);
    });

    test('非 dsh-ui 的围栏原样留在 markdown 里', () {
      const text = '```bash\nls -la\n```';
      final segments = parseGenuiSegments(text);
      expect(segments.length, 1);
      expect((segments.single as MarkdownSegment).text, text);
    });

    test('规格可以出现在消息中间，前后文字都保留', () {
      // 闭合围栏必须独占一行（markdown 规则）——同行带文字时它不算闭合，
      // 那是"未闭合"用例要覆盖的事。
      final segments = parseGenuiSegments(
        '前\n$fence dsh-ui\n{"items":[{"type":"divider"}]}\n$fence\n后',
      );
      expect((segments.first as MarkdownSegment).text, '前');
      expect(segments[1], isA<GenuiSpecSegment>());
      expect((segments.last as MarkdownSegment).text, '后');
    });
  });

  group('降级：解析不了就原样保留', () {
    test('JSON 结构错（缺括号）→ 整段退回 markdown，不丢内容', () {
      final segments = parseGenuiSegments(message('{"items":[{"type":"text"'));
      expect(segments.whereType<GenuiSpecSegment>(), isEmpty);
      final joined = segments.whereType<MarkdownSegment>().map((s) => s.text).join('\n');
      expect(joined, contains('"items"'), reason: '用户至少要能看到原文');
    });

    test('尾随逗号是**标点级**小错，修掉并渲染（与 Web 端一致）', () {
      final segments = parseGenuiSegments(message('{"items":[{"type":"divider"},],}'));
      expect(segments.whereType<GenuiSpecSegment>().length, 1);
    });

    test('未闭合的围栏（流式输出到一半）当普通文字，等增量补全', () {
      const text = '正在生成…\n``` dsh-ui\n{"items":[{"type":"divider"}]}';
      final segments = parseGenuiSegments(text);
      expect(segments.whereType<GenuiSpecSegment>(), isEmpty);
      expect((segments.single as MarkdownSegment).text, text);
    });

    test('空规格（既没 title 也没 items）不渲染成空块', () {
      final segments = parseGenuiSegments(message('{}'));
      expect(segments.whereType<GenuiSpecSegment>(), isEmpty);
    });
  });

  group('规格结构', () {
    test('title / gap / items 都读出来', () {
      final spec = GenuiSpec.fromJson({
        'title': '状态',
        'gap': 14,
        'items': [
          {'type': 'stat', 'label': '用例', 'value': '33'},
        ],
      });
      expect(spec, isNotNull);
      expect(spec!.title, '状态');
      expect(spec.gap, 14);
      expect(spec.items.single.type, 'stat');
      expect(spec.items.single.textAny(const ['value']), '33');
    });

    test('裸组件根（没有外壳）也能解析', () {
      final spec = GenuiSpec.fromJson({'type': 'text', 'content': '你好'});
      expect(spec, isNotNull);
      expect(spec!.items.single.type, 'text');
    });

    test('items 里混入非对象时跳过，而不是整份失败', () {
      // 全是非对象 → 没有可渲染节点
      expect(GenuiSpec.fromJson({'items': [42, 'x']}), isNull);
      // 掺了非对象 → 只保留能渲染的那个
      final spec = GenuiSpec.fromJson({
        'items': [42, {'type': 'divider'}, 'x'],
      });
      expect(spec!.items.length, 1);
    });

    test('未知 type 不在这里丢，留给渲染器显示占位', () {
      final spec = GenuiSpec.fromJson({
        'items': [
          {'type': 'scene3d', 'meshes': []},
        ],
      });
      expect(spec!.items.single.type, 'scene3d');
    });

    test('subtitle 之类的字段通过 textAny 的别名兼容读取', () {
      final node = GenuiNode.fromJson({'type': 'text', 'content': '正文'});
      expect(node.textAny(const ['content', 'text']), '正文');
      // 空串要当作"没写"，否则会渲染出一个空节点
      final empty = GenuiNode.fromJson({'type': 'text', 'content': ''});
      expect(empty.textAny(const ['content', 'text']), isNull);
    });
  });
}
