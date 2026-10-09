import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/approval_preset.dart';
import 'package:dsh_mobile/models/permission_config.dart';

/// 审批预设（v1.4.2）的测试。
///
/// 重点放在两件容易出错的地方：
/// * **预设不能覆盖逐会话设置。** applyTo 走 copyWith 且不传 sessionPolicies,
///   所以一个"曾经给某个会话单独设过 ask"的用户套用预设后，那个会话仍然是
///   ask。这是最容易被"顺手"改掉的东西。
/// * **差异描述只列真正变了的项。** 空列表必须是"无变化"，而不是把四项全列出来
///   —— 那样用户会以为切换有副作用。
void main() {
  group('预设目录', () {
    test('四个预设，从最严到最宽排序', () {
      expect(ApprovalPreset.values.map((p) => p.id).toList(),
          ['strict', 'balanced', 'autonomous', 'trusted']);
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

    test('预设的宽松度是单调的（越往后执行策略越宽）', () {
      String rank(String p) => switch (p) {
            'ask' => '0',
            'auto-read' => '1',
            'danger-full-access' => '2',
            _ => '?',
          };
      final ranks = ApprovalPreset.values.map((p) => rank(p.config.defaultPolicy)).toList();
      for (var i = 1; i < ranks.length; i++) {
        expect(
          int.parse(ranks[i]),
          greaterThanOrEqualTo(int.parse(ranks[i - 1])),
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
      final applied = ApprovalPreset.autonomous.config.applyTo(withSession);

      expect(applied.sessionPolicies['session-x'], 'ask',
          reason: '套用预设不能抹掉用户对单个会话的刻意设置');
      // 但全局确实换了
      expect(applied.defaultPolicy, ApprovalPreset.autonomous.config.defaultPolicy);
      expect(applied.sandboxMode, ApprovalPreset.autonomous.config.sandboxMode);
    });

    test('applyTo 不修改传入的 base（不可变）', () {
      final base = PermissionConfig();
      final before = base.defaultPolicy;
      ApprovalPreset.trusted.config.applyTo(base);
      expect(base.defaultPolicy, before);
    });

    test('每个预设 applyTo 都得到与预设一致的四个值', () {
      final base = PermissionConfig();
      for (final p in ApprovalPreset.values) {
        final applied = p.config.applyTo(base);
        expect(applied.defaultPolicy, p.config.defaultPolicy);
        expect(applied.sandboxMode, p.config.sandboxMode);
        expect(applied.maxSteps, p.config.maxSteps);
        expect(applied.protectGit, p.config.protectGit);
      }
    });
  });

  group('matching 反查当前预设', () {
    test('完全匹配某个预设时返回它', () {
      final cfg = ApprovalPreset.balanced.config.applyTo(PermissionConfig());
      expect(PermissionConfigSnapshot.matching(cfg), ApprovalPreset.balanced);
    });

    test('任一值不同就返回 null（自定义配置是一个合法状态，不是错误）', () {
      final base = PermissionConfig().copyWith(maxSteps: 7);
      expect(PermissionConfigSnapshot.matching(base), isNull);
    });

    test('完全默认配置不匹配任何预设', () {
      // PermissionConfig() 的默认值是 ask/workspace-write/30/true，
      // 与 strict(balanced 之外) 都不同 —— 默认档不该假装是某个预设。
      expect(PermissionConfigSnapshot.matching(PermissionConfig()), isNot(ApprovalPreset.strict));
    });
  });

  group('describeDiff 只列真正变了的项', () {
    test('无变化时返回空列表', () {
      final base = ApprovalPreset.balanced.config.applyTo(PermissionConfig());
      final diff = PermissionConfigSnapshot.describeDiff(base, ApprovalPreset.balanced.config);
      expect(diff, isEmpty, reason: '空列表必须意味着"切换是空操作"，UI 依赖这一点显示提示');
    });

    test('只列变了的项（改一项就只列一项）', () {
      final base = PermissionConfig(defaultPolicy: 'ask', sandboxMode: 'sandboxed', maxSteps: 15, protectGit: true);
      final diff = PermissionConfigSnapshot.describeDiff(base, ApprovalPreset.trusted.config);
      // 四个都变了
      expect(diff, hasLength(4));
      // 改一项时只列一项
      final base2 = PermissionConfig(defaultPolicy: 'ask', sandboxMode: 'sandboxed', maxSteps: 15, protectGit: false);
      final diff2 = PermissionConfigSnapshot.describeDiff(base2, ApprovalPreset.trusted.config);
      expect(diff2, hasLength(3));
      expect(diff2.any((d) => d.contains('Git 保护')), isFalse,
          reason: 'Git 保护两项相同就不该出现在差异里');
    });

    test('差异文案含"→"且给出新旧两个值', () {
      final base = PermissionConfig(defaultPolicy: 'ask');
      final diff = PermissionConfigSnapshot.describeDiff(base, ApprovalPreset.balanced.config);
      expect(diff, isNotEmpty);
      for (final line in diff) {
        expect(line, contains('→'));
      }
      expect(diff.any((d) => d.contains('逐次询问') && d.contains('只读自动放行')), isTrue);
    });

    test('Git 保护的开关方向正确', () {
      // 用与目标快照相同的其它三项，让差异只剩 Git 保护这一条。
      final targetOff = const PermissionConfigSnapshot(
        defaultPolicy: 'ask', sandboxMode: 'sandboxed', maxSteps: 15, protectGit: false,
      );
      final base = PermissionConfig(
          defaultPolicy: 'ask', sandboxMode: 'sandboxed', maxSteps: 15, protectGit: true);
      final off = PermissionConfigSnapshot.describeDiff(base, targetOff);
      expect(off, hasLength(1));
      expect(off.single, contains('开 → 关'));

      final targetOn = const PermissionConfigSnapshot(
        defaultPolicy: 'ask', sandboxMode: 'sandboxed', maxSteps: 15, protectGit: true,
      );
      final base2 = PermissionConfig(
          defaultPolicy: 'ask', sandboxMode: 'sandboxed', maxSteps: 15, protectGit: false);
      final on = PermissionConfigSnapshot.describeDiff(base2, targetOn);
      expect(on, hasLength(1));
      expect(on.single, contains('关 → 开'));
    });
  });

  group('标签映射', () {
    test('已知策略/沙箱值有中文标签，未知值原样返回', () {
      expect(PermissionConfigSnapshot.policyLabel('ask'), '逐次询问');
      expect(PermissionConfigSnapshot.policyLabel('auto-read'), '只读自动放行');
      expect(PermissionConfigSnapshot.policyLabel('danger-full-access'), '全部放行');
      expect(PermissionConfigSnapshot.policyLabel('???'), '???');

      expect(PermissionConfigSnapshot.sandboxLabel('sandboxed'), '沙箱内');
      expect(PermissionConfigSnapshot.sandboxLabel('workspace-write'), '仅工作区可写');
      expect(PermissionConfigSnapshot.sandboxLabel('danger-full-access'), '完全开放');
      expect(PermissionConfigSnapshot.sandboxLabel('???'), '???');
    });

    test('每个预设的 defaultPolicy 与 sandboxMode 都有标签（不留裸值给用户看）', () {
      for (final p in ApprovalPreset.values) {
        expect(PermissionConfigSnapshot.policyLabel(p.config.defaultPolicy), isNot(p.config.defaultPolicy));
        expect(PermissionConfigSnapshot.sandboxLabel(p.config.sandboxMode), isNot(p.config.sandboxMode));
      }
    });
  });
}