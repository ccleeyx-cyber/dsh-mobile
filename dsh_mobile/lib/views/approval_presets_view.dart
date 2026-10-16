/// 审批预设页：内置四档（只读）+ 网关上存的自定义预设（可增删改）。
///
/// ## 为什么内置的那四档不在这一屏、也不在网关上
///
/// `严格 / 均衡 / 自主 / 完全信任` 是 App 里的一个 Dart enum
/// （`lib/models/approval_preset.dart`），**它们的价值就是随二进制一起发布的、
/// 被审查过的文字** —— 每一档都带着 `effects` 里逐条写清的实际后果（"命令可以写
/// 到工作区之外"这种话）。那些话是编译进 App 的，网关从来没存过，所以这一屏把它
/// 们渲染成**只读**：不提供编辑/删除按钮，而不是"给了按钮再让网关报错"。
///
/// 自定义预设反过来 —— 它们只存在于网关
/// （`GET /api/mobile/approval-presets`），这一屏是它们唯一的入口，所以可增删改。
///
/// ## 两条不能重新发明的规则
///
/// 1. `fetchApprovalPresets()` 返回 **null 表示"问不到"**（未连接 / 令牌失效 /
///    网关版本过旧），`[]` 表示"问到了，一个都没有"。前者必须渲染**错误卡 + 重试**，
///    绝不能画成空列表 —— 那会让用户以为自己的预设被删了。
/// 2. **保存一个预设不会改变当前生效的策略**。预设只是一个存起来的组合，
///    要生效得去安全策略页挑它。所以界面上必须一直写着"保存后需在安全策略页应用"，
///    绝不能因为保存成功就暗示策略已经变严或变松了。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/approval_preset.dart';
import '../models/bridge_extras.dart';
import '../services/dsh_service.dart';
import '../theme/app_colors.dart';

/// picker 的可选值。**文案不在这里写死** —— 走
/// [PermissionConfigSnapshot.policyLabel]，与内置预设、安全策略页用的是同一份
/// 措辞。同一个概念在两个页面上叫两个名字，是最便宜的误导方式。
const List<String> _policyValues = <String>['ask', 'auto-read', 'danger-full-access'];

class ApprovalPresetsView extends StatefulWidget {
  const ApprovalPresetsView({super.key});

  @override
  State<ApprovalPresetsView> createState() => _ApprovalPresetsViewState();
}

class _ApprovalPresetsViewState extends State<ApprovalPresetsView> {
  bool _loading = true;

  /// 非 null = "问不到"。此时**不渲染**自定义列表，渲染错误卡。
  String? _loadError;

  List<ApprovalPresetInfo> _customs = const <ApprovalPresetInfo>[];

  /// 删除进行中：禁掉所有删除按钮，避免连点发出两个删除请求。
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 推到第一帧之后再发请求：页面先画出骨架，不会因为一次慢请求白屏。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _load();
    });
  }

  Future<void> _load() async {
    final dsh = Provider.of<DshService>(context, listen: false);
    setState(() {
      _loading = true;
      _loadError = null;
    });
    final customs = await dsh.fetchApprovalPresets();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (customs == null) {
        // 只记住"失败"，不清空 _customs：清空会让下一次成功前的内容闪烁，
        // 而列表区域已经被错误卡取代，旧数据不会被当成事实渲染出来。
        _loadError = '读取自定义预设失败：未连接网关、令牌失效，或网关版本过旧不支持该接口。';
      } else {
        _customs = customs;
      }
    });
  }

  void _toast(String msg, {Color? tone}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: tone ?? context.c.success,
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: tone == null ? 2 : 4),
    ));
  }

  /// 打开新建/编辑表单。[existing] 为 null 即新建。
  Future<void> _openEditor([ApprovalPresetInfo? existing]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _PresetEditorPage(existing: existing)),
    );
    if (!mounted || saved != true) return;
    await _load();
    if (!mounted) return;
    _toast('已保存。预设不会自动生效 —— 请到安全策略页应用它。');
  }

  Future<void> _delete(ApprovalPresetInfo info) async {
    final dsh = Provider.of<DshService>(context, listen: false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: ctx.c.border),
        ),
        title: Text(
          '删除预设「${info.label}」？',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: ctx.c.textPrimary),
        ),
        content: Text(
          '删除后无法恢复。已经用这个预设应用过的策略不会跟着回滚 —— '
          '需要到安全策略页重新挑一个。',
          style: TextStyle(fontSize: 13, height: 1.45, color: ctx.c.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: ctx.c.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.c.danger, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    setState(() => _busy = true);
    final err = await dsh.deleteApprovalPreset(info.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      // 网关原文（例如「「strict」是内置预设，不能被覆盖」）直接贴出来，
      // 换成"删除失败"等于把唯一能解释原因的信息丢掉。
      _toast(err, tone: context.c.danger);
      return;
    }
    await _load();
    if (!mounted) return;
    _toast('已删除「${info.label}」');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.c.surfaceMuted,
      appBar: AppBar(
        backgroundColor: context.c.surface,
        foregroundColor: context.c.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: context.c.border, height: 1),
        ),
        title: Text(
          '审批预设',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.c.textPrimary),
        ),
        actions: [
          IconButton(
            tooltip: '重新读取',
            onPressed: _loading ? null : _load,
            icon: Icon(Icons.refresh_rounded, color: context.c.textSecondary),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        children: [
          _buildIntroCard(context),
          const SizedBox(height: 16),
          _sectionHeader(context, '内置预设（只读）', Icons.verified_user_outlined, context.c.accent),
          const SizedBox(height: 8),
          _buildBuiltins(context),
          const SizedBox(height: 20),
          _sectionHeader(context, '自定义预设', Icons.tune_rounded, context.c.purple),
          const SizedBox(height: 8),
          _buildCustomsSection(context),
          const SizedBox(height: 16),
          // 「新建」放在两个分区之后而不是 AppBar 里：它属于"自定义"这一类，
          // 贴着自定义列表，用户才不会以为它是在改内置预设。
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: context.c.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
              ),
              onPressed: _busy ? null : () => _openEditor(),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('新建预设', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildIntroCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.c.accentSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 16, color: context.c.accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '预设 = 一组存起来的权限组合，不是一个开关',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            '上面四档内置预设随 App 一起发布（文字已审查，因此只能看不能改）；'
            '下面的自定义预设存在网关上，可以自己增删改。',
            style: TextStyle(fontSize: 11.5, height: 1.45, color: context.c.textSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            '⚠ 保存后需在安全策略页应用：保存只是把组合存起来，当前正在生效的策略不会变。',
            style: TextStyle(fontSize: 11.5, height: 1.45, color: context.c.warning, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, size: 19, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: context.c.textPrimary),
          ),
        ),
      ],
    );
  }

  Widget _buildBuiltins(BuildContext context) {
    return Column(
      children: [
        for (final preset in ApprovalPreset.values) ...[
          _BuiltinPresetCard(preset: preset),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildCustomsSection(BuildContext context) {
    if (_loading) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 26),
        decoration: BoxDecoration(
          color: context.c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.c.border),
        ),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: context.c.accent),
          ),
        ),
      );
    }

    final err = _loadError;
    if (err != null) {
      // 错误卡，而不是空列表：空列表的含义是"问到了，没有自定义预设"，
      // 与"问不到"完全是两件事。
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.c.dangerSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.c.dangerBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_off_rounded, size: 17, color: context.c.danger),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '拿不到自定义预设',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: context.c.danger),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              err,
              style: TextStyle(fontSize: 12, height: 1.45, color: context.c.textSecondary),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.c.danger,
                  side: BorderSide(color: context.c.dangerBorder),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('重试', style: TextStyle(fontSize: 12.5)),
              ),
            ),
          ],
        ),
      );
    }

    if (_customs.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.c.border),
        ),
        child: Text(
          '网关上还没有自定义预设。新建一个，把常用的权限组合存下来，'
          '以后在安全策略页一键切过去。',
          style: TextStyle(fontSize: 12, height: 1.45, color: context.c.textSecondary),
        ),
      );
    }

    return Column(
      children: [
        for (final info in _customs) ...[
          _CustomPresetCard(
            info: info,
            busy: _busy,
            onEdit: () => _openEditor(info),
            onDelete: () => _delete(info),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

/// 一档内置预设。只读 —— 没有编辑/删除入口，并且明说出来。
class _BuiltinPresetCard extends StatelessWidget {
  final ApprovalPreset preset;

  const _BuiltinPresetCard({required this.preset});

  @override
  Widget build(BuildContext context) {
    final danger = preset.isDangerous;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: danger ? context.c.dangerBorder : context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  preset.label,
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                ),
              ),
              _KnobChip(
                label: '只读',
                fg: context.c.textSecondary,
                bg: context.c.surfaceMuted,
                border: context.c.border,
              ),
              if (danger) ...[
                const SizedBox(width: 6),
                _KnobChip(
                  label: '危险',
                  fg: context.c.danger,
                  bg: context.c.dangerSurface,
                  border: context.c.dangerBorder,
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            preset.summary,
            style: TextStyle(fontSize: 12, height: 1.4, color: context.c.textSecondary),
          ),
          const SizedBox(height: 9),
          for (final effect in preset.effects)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(color: context.c.textTertiary, shape: BoxShape.circle),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      effect,
                      style: TextStyle(fontSize: 12, height: 1.4, color: context.c.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Text(
            '内置预设随 App 一起发布，不能被编辑或删除。',
            style: TextStyle(fontSize: 11, color: context.c.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// 一条自定义预设：四个旋钮的值 + 编辑/删除。
class _CustomPresetCard extends StatelessWidget {
  final ApprovalPresetInfo info;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _CustomPresetCard({
    required this.info,
    required this.busy,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final cfg = info.config;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: info.dangerous ? context.c.dangerBorder : context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  info.label,
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                ),
              ),
              if (info.dangerous)
                _KnobChip(
                  label: '危险',
                  fg: context.c.danger,
                  bg: context.c.dangerSurface,
                  border: context.c.dangerBorder,
                ),
            ],
          ),
          if (info.summary.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              info.summary,
              style: TextStyle(fontSize: 12, height: 1.4, color: context.c.textSecondary),
            ),
          ],
          const SizedBox(height: 9),
          // 旋钮逐条列出来：只写一个名字，用户没法判断这个预设到底放宽了什么。
          // 只有执行策略一个旋钮 —— 沙箱 / 单轮上限 / Git 保护三个字段全链路无人
          // 消费，已从预设里删掉（详见 PermissionConfig 的说明）。
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _KnobChip(
                label: '策略：${PermissionConfigSnapshot.policyLabel(cfg.defaultPolicy)}',
                fg: context.c.textPrimary,
                bg: context.c.surfaceMuted,
                border: context.c.border,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: context.c.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: busy ? null : onEdit,
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('编辑', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: context.c.danger,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: busy ? null : onDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                label: const Text('删除', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 一枚信息小胶囊。
///
/// 不用 [Chip]：Chip 自带 Material 的胶囊底与内边距，在这个紧凑卡片里会显得比
/// 正文还重，而且它默认主题色不跟 token 走。自己画一个三色可控的小块更省事。
class _KnobChip extends StatelessWidget {
  final String label;
  final Color fg;
  final Color bg;
  final Color border;

  const _KnobChip({required this.label, required this.fg, required this.bg, required this.border});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}

/// 新建/编辑表单。
///
/// 做成独立页面而不是 dialog：六个字段 + 两段说明在手机上放不进一个 dialog，
/// 而 dialog 里的滚动几乎总是被忽略；独立页有 AppBar、有底部固定的保存条，
/// 键盘弹起时也不会把保存按钮顶出屏幕。
///
/// 保存**在这个页面里完成**（而不是把值 pop 回上一页再请求），因为网关的错误
/// 必须就地显示给用户改（"单轮步数上限必须是 1–200 的整数"这类提示只对表单有意义）。
class _PresetEditorPage extends StatefulWidget {
  final ApprovalPresetInfo? existing;

  const _PresetEditorPage({this.existing});

  @override
  State<_PresetEditorPage> createState() => _PresetEditorPageState();
}

class _PresetEditorPageState extends State<_PresetEditorPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _labelCtrl;
  late final TextEditingController _summaryCtrl;

  late String _policy;

  bool _saving = false;

  /// 网关返回的原文错误（"预设名称必填（1–24 字）"…）。原样贴出来。
  String? _serverError;

  @override
  void initState() {
    super.initState();
    final cfg = widget.existing?.config;
    _labelCtrl = TextEditingController(text: widget.existing?.label ?? '');
    _summaryCtrl = TextEditingController(text: widget.existing?.summary ?? '');
    // 新建时的初值刻意用最保守的策略（= 内置「严格」），这样"随便存一个"
    // 也不会意外放宽权限；想放宽得自己动手改。
    _policy = cfg?.defaultPolicy ?? 'ask';
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _summaryCtrl.dispose();
    super.dispose();
  }

  /// 这个组合会不会让 agent 不设防。
  ///
  /// 策略为 `danger-full-access` 即算：命令不再弹确认。网关也是这么判的
  /// （回 `dangerous: true`）。
  bool get _dangerous => _policy == 'danger-full-access';

  String? _validateLabel(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return '预设名称必填（1–24 字）';
    if (t.length > 24) return '预设名称最多 24 字（当前 ${t.length} 字）';
    return null;
  }

  String? _validateSummary(String? v) {
    final t = (v ?? '').trim();
    if (t.length > 80) return '摘要最多 80 字（当前 ${t.length} 字）';
    return null;
  }

  Future<void> _save() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    // 危险确认放在**发请求之前**：网关一保存就落盘了，事后再弹窗没有意义。
    if (_dangerous) {
      final ok = await _confirmDanger();
      if (!mounted || !ok) return;
    }

    final dsh = Provider.of<DshService>(context, listen: false);
    setState(() {
      _saving = true;
      _serverError = null;
    });

    final err = await dsh.saveApprovalPreset(
      // 新建时 id 为 null：id 是网关生成的主键，App 不该编一个。
      id: widget.existing?.id,
      label: _labelCtrl.text.trim(),
      summary: _summaryCtrl.text.trim(),
      config: PresetConfig(
        defaultPolicy: _policy,
      ),
    );
    if (!mounted) return;
    if (err != null) {
      // 网关的原文就地显示 —— 它是唯一能告诉用户"改哪里才对"的信息。
      setState(() {
        _saving = false;
        _serverError = err;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  /// 把"不设防"这件事说清楚，并要求一次明确的确认。
  Future<bool> _confirmDanger() async {
    final why = <String>[
      if (_policy == 'danger-full-access') '执行策略 = 全部放行：所有命令直接执行，不再弹任何确认。',
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: ctx.c.dangerBorder),
        ),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 20, color: ctx.c.danger),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '这个预设不设防，确认保存？',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: ctx.c.textPrimary),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in why)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '• $line',
                  style: TextStyle(fontSize: 13, height: 1.45, color: ctx.c.textPrimary),
                ),
              ),
            Text(
              '保存本身不会改变当前策略；但一旦你在安全策略页应用它，agent 就会在不需要确认的情况下执行命令，'
              '并且可以写到工作区之外 —— 包括删掉你不想被删的文件。',
              style: TextStyle(fontSize: 12, height: 1.5, color: ctx.c.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: ctx.c.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.c.danger, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('我明白，仍然保存'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Scaffold(
      backgroundColor: context.c.surfaceMuted,
      appBar: AppBar(
        backgroundColor: context.c.surface,
        foregroundColor: context.c.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: context.c.border, height: 1),
        ),
        title: Text(
          editing ? '编辑预设' : '新建预设',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.c.textPrimary),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Form(
              key: _formKey,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                children: [
                  TextFormField(
                    controller: _labelCtrl,
                    maxLength: 24,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: '预设名称（必填）',
                      hintText: '例如：只读巡检',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 13.5),
                    validator: _validateLabel,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _summaryCtrl,
                    maxLength: 80,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: '一句话摘要（可选）',
                      hintText: '例如：只读命令放行，写操作逐次确认',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 13.5),
                    validator: _validateSummary,
                  ),
                  const SizedBox(height: 6),
                  _fieldHeader(context, '执行策略 (defaultPolicy)'),
                  const SizedBox(height: 6),
                  for (final v in _policyValues)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _OptionTile(
                        title: PermissionConfigSnapshot.policyLabel(v),
                        subtitle: _policyHint(v),
                        selected: _policy == v,
                        danger: v == 'danger-full-access',
                        onTap: () => setState(() {
                          _policy = v;
                          _serverError = null;
                        }),
                      ),
                    ),
                  if (_serverError != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: context.c.dangerSurface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: context.c.dangerBorder),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.error_outline_rounded, size: 16, color: context.c.danger),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '网关拒绝了这次保存',
                                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: context.c.danger),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  _serverError!,
                                  style: TextStyle(fontSize: 12, height: 1.45, color: context.c.textPrimary),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Text(
                    '保存后需在安全策略页应用：这里只把组合存到网关上，正在生效的策略不会因此改变。',
                    style: TextStyle(fontSize: 11.5, height: 1.45, color: context.c.textTertiary),
                  ),
                ],
              ),
            ),
          ),
          _buildSaveBar(context, editing),
        ],
      ),
    );
  }

  Widget _buildSaveBar(BuildContext context, bool editing) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: context.c.surface,
        border: Border(top: BorderSide(color: context.c.border)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.c.textSecondary,
                  side: BorderSide(color: context.c.border),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                ),
                onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                child: const Text('取消', style: TextStyle(fontSize: 13.5)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _dangerous ? context.c.danger : context.c.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                ),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(_dangerous ? Icons.warning_amber_rounded : Icons.save_outlined, size: 17),
                label: Text(
                  editing ? '保存修改' : '保存预设',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldHeader(BuildContext context, String title) {
    return Text(
      title,
      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: context.c.textPrimary),
    );
  }

  /// 每个取值都要说清"选它会怎样"，否则三个选项看起来只是三种说法。
  static String _policyHint(String v) => switch (v) {
        'ask' => '每一步都等你确认 —— 最安全，也最啰嗦',
        'auto-read' => '只读命令（ls / cat / grep / git status）直接放行，写操作仍然逐次确认',
        _ => '所有命令直接执行，不弹任何确认 —— 危险',
      };
}

/// 单选一行。
///
/// 不用 [RadioListTile]：它自带的圆点与 Material 高亮色不跟 token 走，且三行并排
/// 时"当前选中的是哪个"远不如整块高亮明显。整块可点 + 描边 + 对勾，扫一眼就能看
/// 出选的是哪个。危险取值额外染红，与保存时的确认弹窗前后呼应。
class _OptionTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final bool danger;
  final VoidCallback onTap;

  const _OptionTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.danger,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = danger ? context.c.danger : context.c.accent;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? (danger ? context.c.dangerSurface : context.c.selectedSurface)
              : context.c.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? (danger ? context.c.dangerBorder : context.c.accent) : context.c.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.bold : FontWeight.w600,
                      color: selected ? accent : context.c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11, height: 1.35, color: context.c.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
              size: 18,
              color: selected ? accent : context.c.border,
            ),
          ],
        ),
      ),
    );
  }
}
