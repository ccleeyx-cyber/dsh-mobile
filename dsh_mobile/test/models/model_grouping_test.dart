import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/dsh_settings.dart';

/// [feat 2026-10-22] 模型按供应商分组。
///
/// 用户原话：「模型设置没有分组，需要按不同的供应商分组显示」。这里钉住分组逻辑
/// 本身（纯函数），界面在 `test/widgets/model_picker_sheet_test.dart`。
void main() {
  ModelItem item(String id, String name, {String provider = '', String label = ''}) =>
      ModelItem(
        id: id,
        name: name,
        provider: provider,
        providerLabel: label,
        contextWindow: 256000,
        maxTokens: 32000,
      );

  group('groupModelsByProvider', () {
    test('按服务端 provider 分组，并保持服务端给的顺序', () {
      final groups = groupModelsByProvider([
        item('cn:auto', 'cn:auto', provider: 'wb'),
        item('cn:deepseek-v4-pro', 'DeepSeek V4 Pro', provider: 'wb'),
        item('gpt-5.2', 'GPT-5.2', provider: 'qwen', label: 'qwen'),
        item('cn:kimi-k3-1', 'Kimi K3.1', provider: 'wb'),
      ]);

      expect(groups.length, 2);
      // 顺序 = 配置里 providers 的先后，不按字母重排
      expect(groups[0].key, 'wb');
      expect(groups[0].models.length, 3);
      expect(groups[0].models.map((m) => m.id),
          ['cn:auto', 'cn:deepseek-v4-pro', 'cn:kimi-k3-1']);
      expect(groups[1].key, 'qwen');
      expect(groups[1].models.length, 1);
      // 服务端给的都算"确定"，不该标成推断
      expect(groups[0].inferred, isFalse);
    });

    test('providerLabel 用作标题；没配就用 key', () {
      final groups = groupModelsByProvider([
        item('a:1', 'A1', provider: 'wb', label: '微博云'),
        item('b:1', 'B1', provider: 'qwen'),
      ]);
      expect(groups[0].title, '微博云');
      expect(groups[1].title, 'qwen');
    });

    test('老网关没 provider：按 id 前缀兜底，并如实标成推断', () {
      final groups = groupModelsByProvider([
        item('cn:deepseek-v4-pro', 'DeepSeek V4 Pro'),
        item('cn:kimi-k3-1', 'Kimi K3.1'),
        item('gpt-5.2', 'GPT-5.2'),
      ]);
      expect(groups.map((g) => g.key).toList(), ['cn', '未分组']);
      expect(groups[0].inferred, isTrue);
      // 没有前缀的模型不硬塞进别的组
      expect(groups[1].key, '未分组');
      expect(groups[1].models.single.id, 'gpt-5.2');
    });

    test('空列表不出组，也不报错', () {
      expect(groupModelsByProvider(const []), isEmpty);
    });
  });

  group('ModelItem 解析与选中判定', () {
    test('fromJson 接住 provider 两个字段', () {
      final m = ModelItem.fromJson({
        'id': 'cn:deepseek-v4.1-flash',
        'name': 'DeepSeek V4.1 Flash',
        'provider': 'wb',
        'providerLabel': 'wb',
        'contextWindow': 1000000,
      });
      expect(m.provider, 'wb');
      expect(m.providerKey, 'wb');
      expect(m.providerIsInferred, isFalse);
    });

    test('老网关缺字段时退到 id 前缀', () {
      final m = ModelItem.fromJson({'id': 'cn:kimi-k3-1', 'name': 'Kimi'});
      expect(m.provider, '');
      expect(m.providerKey, 'cn');
      expect(m.providerTitle, 'cn');
      expect(m.providerIsInferred, isTrue);
    });

    test('DshSettings 能说出当前模型的供应商', () {
      final s = DshSettings.fromJson({
        'currentModel': 'gpt-5.2',
        'availableModels': [
          {'id': 'cn:auto', 'name': 'cn:auto', 'provider': 'wb'},
          {'id': 'gpt-5.2', 'name': 'GPT-5.2', 'provider': 'qwen'},
        ],
      });
      expect(s.currentModelProvider, 'qwen');
    });
  });
}
