import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/approval_preset.dart';
import 'package:dsh_mobile/models/bridge_extras.dart';
import 'package:dsh_mobile/models/permission_config.dart';

/// 审批预设（v1.4.2）的测试。
///
/// 重点放在三件容易出错的地方：
/// * **预设不能覆盖逐会话设置。** applyTo 走 copyWith 且不传 sessionPolicies,
///   所以一个"曾经给某个会话单独设过 ask"的用户套用预设后，那个会话仍然是
///   ask。这是最容易被"顺手"改掉的东西。
/// * **差异描述只列真正变了的项。** 空列表必须是"无变化"，而不是把全部项列出来
///   —— 那样用户会以为切换有副作用。
/// * **没有两个预设是同一个东西。** 删掉 `sandboxMode`/`maxSteps`/`protectGit`
///   这三个无人消费的字段后，原先四个预设里的 `autonomous` 会与 `balanced`
///   塌缩成完全相同（两者的执行策略都是 `auto-read`，差别全在被删的字段上）。
///   并排展示两个"名字不同、实际一样"的选项是一种新的误导，所以这里钉死唯一性。
void main() {
  group('预设目录', () {
    test('三个预设，从最严到最宽排序', () {
      expect(ApprovalPreset.values.map((p) => p.id).toList(),
          ['strict', 'balanced', 'trusted']);
    });

    test('每个预设都有 id/标签/摘要/至少一条效果说明', () {
      for (final p in ApprovalPreset.values) {
        expect(p.id, isNotEmpty);
        expect(p.label, isNotEmpty);
        expect(p.summary, isNotEmpty);
        expect(p.effects, isNotEmpty, reason: '${p.id} 必须说明它到底会做什么');
      }
    });

    test('id 唯一', () {
      final ids = ApprovalPreset.values.map((p) => p.id).toSet();
      expect(ids.length, ApprovalPreset.values.length);
    });

    test('没有两个预设拥有同一条执行策略', () {
      final policies = ApprovalPreset.values.map((p) => p.config.defaultPolicy).toList();
      expect(policies.toSet().length, policies.length,
          reason: '重复策略 = 两个看起来不同、实际完全一样的选项');
    });

    test('三个预设恰好覆盖三种执行策略，一个不漏', () {
      expect(
        ApprovalPreset.values.map((p) => p.config.defaultPolicy).toSet(),
        {'ask', 'auto-read', 'danger-full-access'},
      );
    });

    test('只有完全信任被标为危险', () {
      expect(ApprovalPreset.trusted.isDangerous, isTrue);
      for (final p in ApprovalPreset.values.where((p) => p.id != 'trusted')) {
        expect(p.isDangerous, isFalse, reason: '${p.id} 不该被标成高风险');
      }
    });

    test('byId 能反查，未知 id 返回 null 而不是抛异常', () {
      expect(ApprovalPreset.byId('balanced'), ApprovalPreset.balanced);
      expect(ApprovalPreset.byId('不存在'), isNull);
    });

    test('已下线的 autonomous 不再是可选预设', () {
      // 它与 balanced 的策略完全相同；保留会让用户以为两者有区别。
      expect(ApprovalPreset.byId('autonomous'), isNull);
    });

    test('预设的宽松度是单调的（越往后执行策略越宽）', () {
      int rank(String p) => switch (p) {
            'ask' => 0,
            'auto-read' => 1,
            'danger-full-access' => 2,
            _ => -1,
          };
      final ranks = ApprovalPreset.values.map((p) => rank(p.config.defaultPolicy)).toList();
      expect(ranks.every((r) => r >= 0), isTrue, reason: '出现未知策略说明映射漏了一档');
      for (var i = 1; i < ranks.length; i++) {
        expect(
          ranks[i],
          greaterThan(ranks[i - 1]),
          reason: '预设顺序必须与宽松度一致，否则"第一个/最后一个"的暗示就是假的',
        );
      }
    });
  });

  group('applyTo 不动逐会话设置', () {
    test('套用预设后 sessionPolicies 原样保留', () {
      final base = PermissionConfig(defaultPolicy: 'ask');
      // 用户给某个会话单独设过 ask（与全局不同）
      final withSession = base.copyWith(sessionPolicies: {'session-x': 'ask'});
      final applied = ApprovalPreset.balanced.config.applyTo(withSession);

      expect(applied.sessionPolicies['session-x'], 'ask',
          reason: '套用预设不能抹掉用户对单个会话的刻意设置');
      // 但全局确实换了
      expect(applied.defaultPolicy, ApprovalPreset.balanced.config.defaultPolicy);
    });

    test('applyTo 不修改传入的 base（不可变）', () {
      final base = PermissionConfig();
      final before = base.defaultPolicy;
      ApprovalPreset.trusted.config.applyTo(base);
      expect(base.defaultPolicy, before);
    });

    test('每个预设 applyTo 都得到与预设一致的值', () {
      final base = PermissionConfig();
      for (final p in ApprovalPreset.values) {
        expect(p.config.applyTo(base).defaultPolicy, p.config.defaultPolicy);
      }
    });
  });

  group('matching 反查当前预设', () {
    test('完全匹配某个预设时返回它', () {
      final cfg = ApprovalPreset.balanced.config.applyTo(PermissionConfig());
      expect(PermissionConfigSnapshot.matching(cfg), ApprovalPreset.balanced);
    });

    test('默认配置就是最保守的那个预设（不是"无预设"）', () {
      // 默认执行策略是 ask，与 strict 一致；此时界面显示"严格"是准确的。
      expect(PermissionConfigSnapshot.matching(PermissionConfig()), ApprovalPreset.strict);
    });

    test('未知策略值返回 null（自定义配置是合法状态，不是错误）', () {
      final unknown = PermissionConfig(defaultPolicy: 'whatever-the-host-said');
      expect(PermissionConfigSnapshot.matching(unknown), isNull);
    });
  });

  group('describeDiff 只列真正变了的项', () {
    test('无变化时返回空列表', () {
      final base = ApprovalPreset.balanced.config.applyTo(PermissionConfig());
      final diff = PermissionConfigSnapshot.describeDiff(base, ApprovalPreset.balanced.config);
      expect(diff, isEmpty, reason: '空列表必须意味着"切换是空操作"，UI 依赖这一点显示提示');
    });

    test('只列变了的项（改一项就只列一项）', () {
      final base = PermissionConfig(defaultPolicy: 'ask');
      final diff = PermissionConfigSnapshot.describeDiff(base, ApprovalPreset.trusted.config);
      expect(diff, hasLength(1));
      expect(diff.single, contains('执行策略'));

      // 已经一致时不列
      final same = ApprovalPreset.trusted.config.applyTo(PermissionConfig());
      expect(PermissionConfigSnapshot.describeDiff(same, ApprovalPreset.trusted.config), isEmpty);
    });

    test('差异文案含"→"且给出新旧两个值', () {
      final diff = PermissionConfigSnapshot.describeDiff(
        PermissionConfig(defaultPolicy: 'ask'),
        ApprovalPreset.balanced.config,
      );
      expect(diff, isNotEmpty);
      for (final line in diff) {
        expect(line, contains('→'));
      }
      expect(diff.any((d) => d.contains('逐次询问') && d.contains('只读自动放行')), isTrue);
    });
  });

  group('标签映射', () {
    test('已知策略值有中文标签，未知值原样返回', () {
      expect(PermissionConfigSnapshot.policyLabel('ask'), '逐次询问');
      expect(PermissionConfigSnapshot.policyLabel('auto-read'), '只读自动放行');
      expect(PermissionConfigSnapshot.policyLabel('danger-full-access'), '全部放行');
      expect(PermissionConfigSnapshot.policyLabel('???'), '???');
    });

    test('每个预设的策略都有中文标签（不留裸值给用户看）', () {
      for (final p in ApprovalPreset.values) {
        expect(PermissionConfigSnapshot.policyLabel(p.config.defaultPolicy),
            isNot(p.config.defaultPolicy));
      }
    });
  });

  group('已删除的死字段不再出现在模型里', () {
    test('PermissionConfig 只带 defaultPolicy 与逐会话设置', () {
      final json = PermissionConfig().toJson();
      expect(json.keys.toSet(), {'defaultPolicy', 'sessionPolicies'});
      // 网关 payload 仍会带这三个字段（兼容旧版 App），解析时必须忽略而不是崩
      final parsed = PermissionConfig.fromJson({
        'defaultPolicy': 'auto-read',
        'sandboxMode': 'danger-full-access',
        'maxSteps': 999,
        'protectGit': false,
      });
      expect(parsed.defaultPolicy, 'auto-read');
    });

    test('保存预设时只发 defaultPolicy，不再发三个死字段', () {
      // 网关为兼容旧版 App 仍接收它们，但新版客户端不该再发 —— 发出去等于
      // 继续把一个没有效果的设置项写进预设。
      final wire = const PresetConfig(defaultPolicy: 'ask').toJson();
      expect(wire.keys.toSet(), {'defaultPolicy'});
    });

    test('解析旧预设（带三个死字段）不报错', () {
      final parsed = PresetConfig.fromJson({
        'defaultPolicy': 'auto-read',
        'sandboxMode': 'sandboxed',
        'maxSteps': 15,
        'protectGit': true,
      });
      expect(parsed.defaultPolicy, 'auto-read');
    });
  });
}
