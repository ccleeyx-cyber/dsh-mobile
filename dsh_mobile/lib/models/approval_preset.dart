import 'permission_config.dart';

/// Named permission presets (v1.4.2 审批规则化).
///
/// Why presets at all: an execution policy has exactly three values and each one
/// is a real trade-off, so the settings page offers reviewed combinations with
/// the concrete effect written out in plain words, plus
/// [PermissionConfigSnapshot.describeDiff] so the page can show what switching
/// would change *before* it changes anything.
///
/// ## 为什么只剩三个预设、且只描述执行策略
///
/// 此前每个预设还带着 `sandboxMode` / `maxSteps` / `protectGit` 三个维度，但它们
/// **全链路无人消费**（详见 [PermissionConfig] 的说明）。删掉之后：
///
/// - 四个预设塌缩成三个 —— 原来的 `autonomous` 与 `balanced` 的唯一区别就在这三个
///   死字段上（执行策略同为 `auto-read`），保留下会出现两个"看起来不同、实际完全相同"
///   的选项，那是换一种方式误导。
/// - `effects` 只保留**执行策略真的会造成**的后果。沙箱可写范围与单轮步数上限属于
///   引擎自身的设置，不由本预设控制，所以不再写成预设的效果。
enum ApprovalPreset {
  strict(
    id: 'strict',
    label: '严格',
    summary: '每一步都问，只放行纯只读命令',
    config: PermissionConfigSnapshot(defaultPolicy: 'ask'),
    effects: [
      '任何写操作、任何非只读命令都会弹窗等你确认',
      '没有任何命令会被自动放行 —— 最安全，但最需要你陪着',
    ],
  ),
  balanced(
    id: 'balanced',
    label: '均衡',
    summary: '只读自动放行，写操作仍然逐次确认',
    config: PermissionConfigSnapshot(defaultPolicy: 'auto-read'),
    effects: [
      'ls / cat / grep / git status 这类只读命令直接放行，不再打扰你',
      '写操作、删除、执行脚本仍然逐次弹窗',
    ],
  ),
  trusted(
    id: 'trusted',
    label: '完全信任',
    summary: '不设防：任何命令都直接执行',
    config: PermissionConfigSnapshot(defaultPolicy: 'danger-full-access'),
    effects: [
      '所有命令直接执行，不再弹任何确认',
      '没有二次确认环节 —— 出错时你也没有拦截的机会',
    ],
  );

  const ApprovalPreset({
    required this.id,
    required this.label,
    required this.summary,
    required this.config,
    required this.effects,
  });

  final String id;
  final String label;
  final String summary;
  final PermissionConfigSnapshot config;

  /// What this preset actually does, in words. Shown in the picker so the user
  /// is choosing a behaviour rather than a name.
  final List<String> effects;

  bool get isDangerous => config.defaultPolicy == 'danger-full-access';

  static ApprovalPreset? byId(String id) {
    for (final p in ApprovalPreset.values) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// An immutable snapshot of the knobs a preset controls.
///
/// Separate from [PermissionConfig] on purpose: [PermissionConfig] carries the
/// live `sessionPolicies` map, and a preset must not touch per-session
/// overrides. Building a preset therefore cannot accidentally rewrite someone's
/// deliberate per-session settings.
class PermissionConfigSnapshot {
  final String defaultPolicy;

  const PermissionConfigSnapshot({required this.defaultPolicy});

  /// Apply this preset to a live config, leaving per-session overrides alone.
  PermissionConfig applyTo(PermissionConfig base) => base.copyWith(
        defaultPolicy: defaultPolicy,
      );

  /// Which preset (if any) matches this config.
  ///
  /// Returns null when the config matches no preset — which is a real state once
  /// a custom preset is applied, not an error.
  static ApprovalPreset? matching(PermissionConfig config) {
    for (final p in ApprovalPreset.values) {
      if (p.config.defaultPolicy == config.defaultPolicy) return p;
    }
    return null;
  }

  /// Human-readable diffs between two configs, for the "what would change"
  /// preview. Only lists what actually differs, so an empty list means the
  /// switch is a no-op and the UI can say so rather than showing noise.
  static List<String> describeDiff(PermissionConfig from, PermissionConfigSnapshot to) {
    final out = <String>[];
    if (from.defaultPolicy != to.defaultPolicy) {
      out.add('执行策略：${policyLabel(from.defaultPolicy)} → ${policyLabel(to.defaultPolicy)}');
    }
    return out;
  }

  static String policyLabel(String v) => switch (v) {
        'ask' => '逐次询问',
        'auto-read' => '只读自动放行',
        'danger-full-access' => '全部放行',
        _ => v,
      };
}

/// A one-time reminder that `auto-read` is a real policy with consequences.
///
/// Shown when the user first selects a preset that relaxes anything. Not shown
/// again for the same preset within the same install — nagging teaches users to
/// dismiss things without reading them.
class PresetWarning {
  final String presetId;
  final String body;

  const PresetWarning({required this.presetId, required this.body});
}
