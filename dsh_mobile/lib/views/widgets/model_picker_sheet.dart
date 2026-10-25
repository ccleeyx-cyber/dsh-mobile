import 'package:flutter/material.dart';

import '../../models/dsh_settings.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// 模型选择弹层（**按供应商分组**）。
///
/// ## 为什么做成一个共用组件
///
/// 这个动作有两个入口：会话里换（只影响本会话）和设置里换（改全局默认）。它们
/// 原先各写了一份几乎一样的平铺列表 —— 一处改了分组、另一处必然漂移。现在两份
/// 都走这里，差别只剩标题、说明和"选中之后做什么"（[onPick] 由调用方给）。
///
/// ## 为什么是"分组标题 + 供应商筛选胶囊"两件套
///
/// 这台机器的模型目录里有两个供应商、几十条模型（`wb` 的 `cn:*` 全家桶 + `qwen`
/// 的 codex/gpt/glm 系列）。手机上滚几十行找模型是最慢的交互，所以：
///   * 顶部一排供应商胶囊（带条数）—— 一眼看到"有哪几家、各多少条"，点一下只看
///     这一家；
///   * 列表里仍有分组标题（"全部"模式下），滚动时不会看串行。
///
/// 供应商来自服务端（`ModelItem.provider`）。老网关没这个字段时用模型 id 的
/// `xxx:` 前缀兜底，并在标题上写明"按 ID 前缀"——**不把猜测说成事实**。
Future<void> showModelPickerSheet({
  required BuildContext context,
  required List<ModelItem> models,
  required String selectedModelId,
  required String title,
  required Future<void> Function(ModelItem picked) onPick,
  String? subtitle,
  String? note,
  IconData icon = Icons.smart_toy_outlined,
  String? selectedProviderKey,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _ModelPickerSheet(
      models: models,
      selectedModelId: selectedModelId,
      selectedProviderKey: selectedProviderKey,
      title: title,
      subtitle: subtitle,
      note: note,
      icon: icon,
      onPick: onPick,
    ),
  );
}
class _ModelPickerSheet extends StatefulWidget {
  const _ModelPickerSheet({
    required this.models,
    required this.selectedModelId,
    required this.title,
    required this.onPick,
    this.selectedProviderKey,
    this.subtitle,
    this.note,
    this.icon = Icons.smart_toy_outlined,
  });

  final List<ModelItem> models;
  final String selectedModelId;

  /// 当前模型所属的供应商 key（调用方从模型目录里精确查到的最多一个）。
  /// 只在 `selectedModelId` 未能精确命中时才用于消歧 —— 见 `_effectiveSelectedId`。
  final String? selectedProviderKey;
  final String title;
  final String? subtitle;
  final String? note;
  final IconData icon;
  final Future<void> Function(ModelItem picked) onPick;

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  String _filter = '';

  /// 只看某一家；空串 = 全部。
  String _providerFilter = '';

  bool _busy = false;

  /// 当前选中的那**一条**模型 id。判定必须唯一。
  ///
  /// [fix 2026-10-26] 原来是无条件做"去掉供应商前缀"的宽松比较：
  ///
  /// ```dart
  /// if (m.id == selectedModelId) return true;
  /// return strip(m.id) == strip(selectedModelId) && strip(m.id).isNotEmpty;
  /// ```
  ///
  /// 第一行是对的（精确命中），第二行会**跨供应商**命中 —— 不同供应商本来就有同名
  /// 模型（本机实测：wb 的 `cn:glm-5.3` 与 qwen 的 `glm-5.3`、wb 的
  /// `cn:deepseek-v4-pro` 与 qwen 的 `deepseek-v4-pro`），去掉 `cn:` 之后两者同串，
  /// 于是选中一条、两家都显示"使用中"（用户实测反馈："两个都会选中"）。
  ///
  /// 新规则按"越精确越优先"，且**绝不返回多个**：
  ///   1. 列表里有完整 id → 就用它（正常情况，唯一）；
  ///   2. 没有（老会话/老网关存的是另一种写法）→ 才退回去前缀比较，且只在候选
  ///      **唯一**时才算数；多个候选时用 [selectedProviderKey] 收敛到一家；
  ///   3. 仍然无法唯一确定 → 一行都不点亮。宁可"看不出哪个在用"，也不能指错，
  ///      更不能同时指两条。
  String get _effectiveSelectedId {
    final want = widget.selectedModelId;
    if (want.isEmpty) return want;
    if (widget.models.any((m) => m.id == want)) return want;

    String strip(String s) => s.replaceFirst(RegExp(r'^[A-Za-z0-9_-]+:'), '');
    final base = strip(want);
    if (base.isEmpty) return want;

    var candidates = widget.models.where((m) => strip(m.id) == base).toList();
    final provider = (widget.selectedProviderKey ?? '').trim();
    if (provider.isNotEmpty && candidates.length > 1) {
      candidates = candidates.where((m) => m.providerKey == provider).toList();
    }
    return candidates.length == 1 ? candidates.first.id : want;
  }

  /// 先按搜索词过滤，再分组。胶囊与列表共用这一份 —— 胶囊上的条数必须与列表
  /// 里真实能看到的一致，否则"wb 2"点进去是空的，那是骗人。
  List<ModelGroup> _searchGroups() {
    final matched = widget.models.where((m) {
      if (_filter.isEmpty) return true;
      return m.name.toLowerCase().contains(_filter) || m.id.toLowerCase().contains(_filter);
    }).toList();
    return groupModelsByProvider(matched);
  }

  @override
  Widget build(BuildContext context) {
    final searchGroups = _searchGroups();
    // 选中行只解析一次，所有行共用同一个答案 —— 逐行各自比较会产生"每条都觉得自己
    // 命中"的多选（正是这次修的 bug）。
    final selectedId = _effectiveSelectedId;
    final groups = _providerFilter.isEmpty
        ? searchGroups
        : searchGroups.where((g) => g.key == _providerFilter).toList();
    final allGroups = groupModelsByProvider(widget.models);
    final maxHeight = MediaQuery.of(context).size.height * 0.62;
    final totalShown = groups.fold<int>(0, (sum, g) => sum + g.models.length);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: context.c.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.m),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: context.c.accent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(widget.icon, color: context.c.accent, size: 19),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: TextStyle(
                          fontSize: 16.5,
                          fontWeight: FontWeight.bold,
                          color: context.c.textPrimary,
                        ),
                      ),
                      if ((widget.subtitle ?? '').isNotEmpty)
                        Text(
                          widget.subtitle!,
                          style: TextStyle(fontSize: 12, color: context.c.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                Text(
                  '${widget.models.length} 个 · ${allGroups.length} 家',
                  style: TextStyle(fontSize: 11.5, color: context.c.textTertiary),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.s),
            TextField(
              key: const ValueKey('model-picker-search'),
              style: TextStyle(fontSize: 13.5, color: context.c.textPrimary),
              decoration: InputDecoration(
                hintText: '搜索模型（如 deepseek, glm, gpt, qwen…）',
                hintStyle: TextStyle(fontSize: 13, color: context.c.textTertiary),
                prefixIcon: Icon(Icons.search, size: 19, color: context.c.textSecondary),
                isDense: true,
                filled: true,
                fillColor: context.c.surfaceMuted,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (val) => setState(() => _filter = val.trim().toLowerCase()),
            ),
            const SizedBox(height: AppSpace.s),
            // 供应商筛选胶囊：横向滚动，不换行（换行会吃掉列表高度）。
            SizedBox(
              height: 30,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: searchGroups.length + 1,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (ctx, index) {
                  final isAll = index == 0;
                  final group = isAll ? null : searchGroups[index - 1];
                  final key = isAll ? '' : group!.key;
                  final selected = _providerFilter == key;
                  final label = isAll ? '全部' : '${group!.title} ${group.models.length}';
                  return InkWell(
                    key: ValueKey('model-picker-chip-${isAll ? 'all' : group!.key}'),
                    borderRadius: BorderRadius.circular(15),
                    onTap: () => setState(() => _providerFilter = key),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                      decoration: BoxDecoration(
                        color: selected ? context.c.accent.withOpacity(0.12) : context.c.surfaceMuted,
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(
                          color: selected ? context.c.accent : context.c.border,
                          width: selected ? 1.2 : 1,
                        ),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                          color: selected ? context.c.accent : context.c.textSecondary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: AppSpace.s),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight - 150),
              child: totalShown == 0
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Center(
                        child: Text(
                          '未找到匹配的模型',
                          style: TextStyle(color: context.c.textTertiary, fontSize: 13),
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: groups.length,
                      itemBuilder: (ctx, index) {
                        final group = groups[index];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _groupHeader(context, group),
                            ...group.models.map((m) => _modelRow(context, m, selectedId)),
                            const SizedBox(height: 6),
                          ],
                        );
                      },
                    ),
            ),
            if ((widget.note ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  widget.note!,
                  style: TextStyle(fontSize: 11.5, color: context.c.textTertiary, height: 1.4),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 分组标题。`inferred` 时如实说明来源是 id 前缀（老网关没有 provider 字段）。
  Widget _groupHeader(BuildContext context, ModelGroup group) {
    return Padding(
      key: ValueKey('model-picker-group-${group.key}'),
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Row(
        children: [
          Text(
            group.title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: context.c.textSecondary,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${group.models.length}',
            style: TextStyle(fontSize: 11, color: context.c.textTertiary),
          ),
          if (group.inferred) ...[
            const SizedBox(width: 6),
            Text(
              '按 ID 前缀',
              style: TextStyle(fontSize: 10.5, color: context.c.textTertiary),
            ),
          ],
          const SizedBox(width: 8),
          Expanded(
            child: Container(height: 1, color: context.c.border.withOpacity(0.7)),
          ),
        ],
      ),
    );
  }

  Widget _modelRow(BuildContext context, ModelItem m, String selectedId) {
    final selected = m.id == selectedId;
    return InkWell(
      key: ValueKey('model-picker-item-${m.id}'),
      borderRadius: BorderRadius.circular(10),
      onTap: _busy
          ? null
          : () async {
              setState(() => _busy = true);
              // 先关弹层再执行切换：切换是异步的（要打网关），让用户盯着一个
              // 已经不再变化的列表等两秒，比直接关掉更难受。失败信息由调用方用
              // 弹层**外面**的 messenger / toast 播 — 这里的 context 已经没了。
              final navigator = Navigator.of(context);
              if (mounted) navigator.pop();
              try {
                await widget.onPick(m);
              } finally {
                if (mounted) setState(() => _busy = false);
              }
            },
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? context.c.accent.withOpacity(0.08) : context.c.surfaceMuted,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? context.c.accent : context.c.border,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? context.c.accent : context.c.textTertiary,
              size: 17,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: selected ? context.c.accent : context.c.textPrimary,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${m.id} · 上下文 ${(m.contextWindow ?? 0) ~/ 1000}k',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: context.c.textSecondary),
                  ),
                ],
              ),
            ),
            if (selected)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: context.c.accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '使用中',
                  style: TextStyle(
                    color: context.c.accent,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
