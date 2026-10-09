import 'permission_config.dart';

/// Named permission presets (v1.4.2 审批规则化).
///
/// Why presets at all: the raw settings expose four independent knobs
/// (`defaultPolicy`, `sandboxMode`, `maxSteps`, `protectGit`) and every
/// combination is legal, including several that are actively dangerous — for
/// example `defaultPolicy: auto-read` together with a sandbox that still allows
/// writes. A user picking values one at a time has no way to reason about the
/// result, so they either leave it at `ask` forever or flip one switch and get
/// a surprise.
///
/// A preset bundles a **reviewed** combination, and — more importantly — each
/// one carries the concrete effect in plain words, plus [describeDiff] so the
/// settings page can show exactly what switching would change *before* it
/// changes anything.
///
/// The ordering here is deliberate: most restrictive first, so the safest
/// option is the first thing read.
enum ApprovalPreset {
  strict(
    id: 'strict',
    label: '严格',
    summary: '每一步都问，只放行纯只读命令',
    config: PermissionConfigSnapshot(
      defaultPolicy: 'ask',
      sandboxMode: 'sandboxed',
      maxSteps: 15,
      protectGit: true,
    ),
    effects: [
      '任何写操作、任何非只读命令都会弹窗等你确认',
      '命令在沙箱里跑，不能写到工作区以外',
      '单轮最多 15 步（长任务会提前停下）',
    ],
  ),
  balanced(
    id: 'balanced',
    label: '均衡',
    summary: '只读自动放行，写操作仍然逐次确认',
    config: PermissionConfigSnapshot(
      defaultPolicy: 'auto-read',
      sandboxMode: 'workspace-write',
      maxSteps: 30,
      protectGit: true,
    ),
    effects: [
      'ls / cat / grep / git status 这类只读命令直接放行，不再打扰你',
      '写操作、删除、执行脚本仍然逐次弹窗',
      '命令可以写工作区，但不能写到工作区以外',
      '单轮最多 30 步',
    ],
  ),
  autonomous(
    id: 'autonomous',
    label: '自主',
    summary: '只在危险操作前确认，其余放行',
    config: PermissionConfigSnapshot(
      defaultPolicy: 'auto-read',
      sandboxMode: 'workspace-write',
      maxSteps: 60,
      protectGit: false,
    ),
    effects: [
      '只读命令自动放行',
      '写工作区自动放行；删除、执行脚本等危险操作仍会弹窗',
      'Git 不再强制保护 —— 允许 agent 自己 commit / push',
      '单轮最多 60 步，长任务不容易被拦腰截断',
    ],
  ),
  trusted(
    id: 'trusted',
    label: '完全信任',
    summary: '不设防：任何命令都直接执行',
    config: PermissionConfigSnapshot(
      defaultPolicy: 'danger-full-access',
      sandboxMode: 'danger-full-access',
      maxSteps: 100,
      protectGit: false,
    ),
    effects: [
      '所有命令直接执行，不弹任何确认',
      '命令可以写到机器上的任何路径，包括工作区之外',
      'Git 不受保护',
      '单轮最多 100 步',
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
  final String sandboxMode;
  final int maxSteps;
  final bool protectGit;

  const PermissionConfigSnapshot({
    required this.defaultPolicy,
    required this.sandboxMode,
    required this.maxSteps,
    required this.protectGit,
  });

  /// Apply this preset to a live config, leaving per-session overrides alone.
  PermissionConfig applyTo(PermissionConfig base) => base.copyWith(
        defaultPolicy: defaultPolicy,
        sandboxMode: sandboxMode,
        maxSteps: maxSteps,
        protectGit: protectGit,
      );

  /// Which preset (if any) matches this exact set of knobs.
  ///
  /// Used to show the current selection. Returns null when the config matches
  /// no preset — which is a real state, not an error: [PermissionConfig] lets
  /// the user set the knobs individually, and that must still work.
  static ApprovalPreset? matching(PermissionConfig config) {
    for (final p in ApprovalPreset.values) {
      if (p.config.defaultPolicy == config.defaultPolicy &&
          p.config.sandboxMode == config.sandboxMode &&
          p.config.maxSteps == config.maxSteps &&
          p.config.protectGit == config.protectGit) {
        return p;
      }
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
    if (from.sandboxMode != to.sandboxMode) {
      out.add('沙箱模式：${sandboxLabel(from.sandboxMode)} → ${sandboxLabel(to.sandboxMode)}');
    }
    if (from.maxSteps != to.maxSteps) {
      out.add('单轮步数上限：${from.maxSteps} → ${to.maxSteps}');
    }
    if (from.protectGit != to.protectGit) {
      out.add(from.protectGit ? 'Git 保护：开 → 关' : 'Git 保护：关 → 开');
    }
    return out;
  }

  static String policyLabel(String v) => switch (v) {
        'ask' => '逐次询问',
        'auto-read' => '只读自动放行',
        'danger-full-access' => '全部放行',
        _ => v,
      };

  static String sandboxLabel(String v) => switch (v) {
        'sandboxed' => '沙箱内',
        'workspace-write' => '仅工作区可写',
        'danger-full-access' => '完全开放',
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