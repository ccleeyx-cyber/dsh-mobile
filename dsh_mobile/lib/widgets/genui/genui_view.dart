/// ```dsh-ui 规格 → 原生组件。
///
/// ## 支持范围（明确取舍，不是遗漏）
///
/// **原生渲染**：布局（text/row/col/grid/card/divider/spacer/hero）、展示
/// （stat/badge/progress/list/table/keyvalue/timeline/file-tree/breadcrumb/diff/
/// json/code/callout/steps/avatar）、图表（chart：bars/line/donut）、交互容器
/// （tabs/accordion/copy/link）、以及行内富文本。
///
/// **降级为占位**：`echart`/`plot`/`mermaid`/`diagram`/`scene3d`/`svg`/`audio`/
/// `video`，以及全部需要 `[genui-action]` 往返的表单类
/// （button/input/select/checkbox/radio/switch/textarea/submit/quiz）。
///
/// 降级**不丢信息**：渲染成一条说明 + 可展开的原始 JSON。理由 —— 这些能力的
/// 渲染成本差一个数量级（ECharts ≈1MB、diagram 27 种排版、scene3d 需要 WebGL），
/// 而表单类还依赖宿主把 action 送回模型（App 侧尚无该链路）。先把信息如实呈现，
/// 比假装支持然后画错要好。
///
/// ⚠️ 与 Web 端已知的差距（本轮未做）：表格的本地排序/筛选/导出/`details` 展开、
/// 状态持久化、`filter`/`sortField` 绑定。它们都是本地增强，不影响信息完整性。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_colors.dart';
import 'genui_charts.dart';
import 'genui_inline.dart';
import 'genui_parse.dart';

/// 一个规格的根视图：可选标题 + 纵向组件列表。
class GenuiSpecView extends StatelessWidget {
  const GenuiSpecView({super.key, required this.spec, this.onLink});

  final GenuiSpec spec;
  final void Function(String href)? onLink;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    final title = spec.title;
    if (title != null && title.isNotEmpty) {
      children.add(GenuiInlineText(
        title,
        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: context.c.textPrimary),
      ));
    }
    for (final node in spec.items) {
      children.add(GenuiNodeView(node: node, onLink: onLink));
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: spec.gap > 0 ? spec.gap : 10),
          children[i],
        ],
      ],
    );
  }
}

/// 一个节点 → 一个组件。未知类型降级为占位说明。
class GenuiNodeView extends StatelessWidget {
  const GenuiNodeView({super.key, required this.node, this.onLink, this.depth = 0});

  final GenuiNode node;
  final void Function(String href)? onLink;
  final int depth;

  /// 规范上限 8 层；超过就不再往下画（防止畸形 spec 把界面撑爆）。
  static const int maxDepth = 8;

  @override
  Widget build(BuildContext context) {
    if (depth > maxDepth) return const SizedBox.shrink();
    switch (node.type) {
      case 'text':
        return _text(context);
      case 'hero':
        return _hero(context);
      case 'row':
        return _row(context, wrap: node.bool_('wrap') ?? false);
      case 'col':
        return _children(context);
      case 'grid':
        return _grid(context);
      case 'card':
        return _card(context);
      case 'divider':
        return Divider(height: 1, color: context.c.border);
      case 'spacer':
        return const SizedBox(height: 8);
      case 'stat':
        return _stat(context);
      case 'badge':
        return _badge(context);
      case 'progress':
        return _progress(context);
      case 'avatar':
        return _avatar(context);
      case 'list':
        return _list(context);
      case 'table':
        return _table(context);
      case 'keyvalue':
        return _keyvalue(context);
      case 'timeline':
        return _timeline(context);
      case 'file-tree':
        return _fileTree(context);
      case 'breadcrumb':
        return _breadcrumb(context);
      case 'diff':
        return _diff(context);
      case 'json':
        return _jsonBlock(context);
      case 'code':
        return _code(context);
      case 'callout':
        return _callout(context);
      case 'steps':
        return _steps(context);
      case 'copy':
        return _copy(context);
      case 'link':
        return _link(context);
      case 'image':
        return _image(context);
      case 'chart':
        return _chart(context);
      case 'tabs':
        return _Tabs(node: node, onLink: onLink, depth: depth);
      case 'accordion':
        return _Accordion(node: node, onLink: onLink, depth: depth);
      default:
        return _Unsupported(node: node);
    }
  }

  // ------------------------------------------------------------ 布局 ----

  Widget _text(BuildContext context) {
    final size = node.nonEmpty('size') ?? 'body';
    final style = switch (size) {
      'h1' => TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: context.c.textPrimary, height: 1.5),
      'h2' => TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: context.c.textPrimary, height: 1.5),
      'h3' => TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: context.c.textPrimary, height: 1.5),
      'muted' => TextStyle(fontSize: 13, color: context.c.textSecondary, height: 1.9),
      'caption' => TextStyle(fontSize: 11.5, color: context.c.textTertiary, height: 1.5),
      _ => TextStyle(fontSize: 13.5, color: context.c.textPrimary, height: 1.7),
    };
    final content = node.textAny(const ['content', 'text']) ?? '';
    final center = node.bool_('center') ?? false;
    final body = GenuiInlineText(
      content,
      style: style,
      onLink: onLink,
      codeBackground: context.c.surfaceMuted,
      highlightBackground: context.c.warningBadgeSurface,
      linkColor: context.c.accent,
    );
    return SizedBox(
      width: double.infinity,
      child: center ? Center(child: body) : body,
    );
  }

  Widget _hero(BuildContext context) {
    final tone = _toneColors(context, node.nonEmpty('tone') ?? 'accent');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: tone.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tone.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (node.nonEmpty('label') != null)
            GenuiInlineText(node.nonEmpty('label')!, style: TextStyle(fontSize: 11.5, color: tone.fg, letterSpacing: 0.4)),
          if (node.nonEmpty('value') != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 2),
              child: Text(
                node.nonEmpty('value')!,
                style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: tone.fg, letterSpacing: -0.8),
              ),
            ),
          if (node.nonEmpty('title') != null)
            GenuiInlineText(node.nonEmpty('title')!, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: context.c.textPrimary)),
          if (node.nonEmpty('subtitle') != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: GenuiInlineText(node.nonEmpty('subtitle')!, style: TextStyle(fontSize: 12, color: context.c.textSecondary)),
            ),
          if (node.nonEmpty('delta') != null) _deltaChip(context, node.nonEmpty('delta')!),
        ],
      ),
    );
  }

  Widget _children(BuildContext context) {
    final items = node.list('items');
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _child(context, items[i]),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, {required bool wrap}) {
    final items = node.list('items');
    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [for (final c in items) _child(context, c)],
    );
  }

  Widget _grid(BuildContext context) {
    final items = node.list('items');
    final cols = (node.num_('cols') ?? 2).toInt().clamp(1, 4);
    if (items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, c) {
        const gap = 8.0;
        final w = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final item in items)
              SizedBox(
                width: w,
                child: _child(context, item),
              ),
          ],
        );
      },
    );
  }

  Widget _card(BuildContext context) {
    final accent = _hex(node.nonEmpty('accent'));
    final items = node.list('items');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent ?? context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (node.nonEmpty('title') != null) ...[
            GenuiInlineText(
              node.nonEmpty('title')!,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: accent ?? context.c.textPrimary),
            ),
            const SizedBox(height: 8),
          ],
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _child(context, items[i]),
          ],
        ],
      ),
    );
  }

  Widget _child(BuildContext context, Object? raw) {
    if (raw is Map) {
      return GenuiNodeView(node: GenuiNode.fromJson(Map<String, dynamic>.from(raw)), onLink: onLink, depth: depth + 1);
    }
    // 裸字符串当一行文字（list 项里混字符串是常见写法）
    return GenuiInlineText('$raw', style: TextStyle(fontSize: 13, color: context.c.textPrimary));
  }

  // ------------------------------------------------------------ 展示 ----

  Widget _stat(BuildContext context) {
    final value = node.textAny(const ['value']) ?? '';
    final label = node.textAny(const ['label']) ?? '';
    final delta = node.nonEmpty('delta');
    final spark = node.list('spark');
    final big = node.nonEmpty('size') == 'hero';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty)
          GenuiInlineText(label, style: TextStyle(fontSize: 11.5, color: context.c.textTertiary)),
        Text(
          value,
          style: TextStyle(
            fontSize: big ? 30 : 20,
            fontWeight: FontWeight.w700,
            color: context.c.textPrimary,
            letterSpacing: big ? -0.6 : 0,
          ),
        ),
        if (delta != null) _deltaChip(context, delta),
        if (spark.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(
              height: 22,
              child: CustomPaint(
                painter: _Sparkline(
                  values: [for (final v in spark) (v is num) ? v.toDouble() : 0],
                  color: context.c.accent,
                ),
                size: const Size(double.infinity, 22),
              ),
            ),
          ),
      ],
    );
  }

  Widget _deltaChip(BuildContext context, String delta) {
    final up = !delta.startsWith('-');
    final color = delta.startsWith('-') ? context.c.danger : (delta.startsWith('+') ? context.c.success : context.c.textSecondary);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (delta.startsWith('+') || delta.startsWith('-'))
            Icon(up ? Icons.trending_up_rounded : Icons.trending_down_rounded, size: 13, color: color),
          const SizedBox(width: 3),
          Text(delta, style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _badge(BuildContext context) {
    final tone = _toneColors(context, node.nonEmpty('tone') ?? 'accent');
    final icon = node.nonEmpty('icon');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tone.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Text(icon, style: const TextStyle(fontSize: 11)),
            const SizedBox(width: 4),
          ],
          GenuiInlineText(node.textAny(const ['label', 'title']) ?? '', style: TextStyle(fontSize: 11.5, color: tone.fg, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _progress(BuildContext context) {
    final value = (node.num_('value') ?? 0).clamp(0, 100).toDouble();
    final label = node.nonEmpty('label');
    final valueLabel = node.nonEmpty('valueLabel');
    final ring = node.nonEmpty('variant') == 'ring';
    if (ring) {
      return Row(
        children: [
          SizedBox(
            width: 54,
            height: 54,
            child: CustomPaint(
              painter: _Ring(value: value / 100, color: context.c.accent, track: context.c.border),
              child: Center(
                child: Text(
                  valueLabel ?? '${value.toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                ),
              ),
            ),
          ),
          if (label != null) ...[
            const SizedBox(width: 10),
            Expanded(child: GenuiInlineText(label, style: TextStyle(fontSize: 12.5, color: context.c.textSecondary))),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (label != null)
              Expanded(child: GenuiInlineText(label, style: TextStyle(fontSize: 12, color: context.c.textSecondary))),
            Text(valueLabel ?? '${value.toStringAsFixed(0)}%', style: TextStyle(fontSize: 11.5, color: context.c.textTertiary)),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: value / 100,
            minHeight: 6,
            backgroundColor: context.c.border,
            valueColor: AlwaysStoppedAnimation(context.c.accent),
          ),
        ),
      ],
    );
  }

  Widget _avatar(BuildContext context) {
    final name = node.textAny(const ['name']) ?? '?';
    final color = _hex(node.nonEmpty('color')) ?? context.c.accent;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 12,
          backgroundColor: color.withOpacity(0.15),
          child: Text(
            // 用 runes 而不是 substring(0,1)：名字首字符是 emoji 时后者会切出半个
            // 代理对，渲染成方块。
            name.isEmpty ? '?' : String.fromCharCode(name.runes.first),
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
          ),
        ),
        const SizedBox(width: 6),
        GenuiInlineText(name, style: TextStyle(fontSize: 12.5, color: context.c.textPrimary)),
      ],
    );
  }

  Widget _list(BuildContext context) {
    final items = node.list('items');
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: 7),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(color: context.c.textTertiary, shape: BoxShape.circle),
                  ),
                ),
                Expanded(child: _listEntry(context, item)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _listEntry(BuildContext context, Object? raw) {
    if (raw is Map) {
      // 规范里的归一化：label/name → title，description/content/text/body/detail → desc
      final title = _pickText(raw, const ['title', 'label', 'name']);
      final desc = _pickText(raw, const ['desc', 'description', 'content', 'text', 'body', 'detail']);
      if (title == null && desc == null) {
        return _child(context, raw);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            GenuiInlineText(title, style: TextStyle(fontSize: 13, color: context.c.textPrimary, height: 1.5)),
          if (desc != null)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: GenuiInlineText(desc, style: TextStyle(fontSize: 12, color: context.c.textSecondary, height: 1.6)),
            ),
        ],
      );
    }
    return GenuiInlineText('$raw', style: TextStyle(fontSize: 13, color: context.c.textPrimary, height: 1.5));
  }

  /// 从 map 里按优先级取第一个非空字符串（用于 list 项的字段归一化）。
  static String? _pickText(Object? raw, List<String> keys) {
    if (raw is! Map) return null;
    for (final k in keys) {
      final v = raw[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  Widget _table(BuildContext context) {
    final columns = node.list('columns');
    final rows = node.list('rows');
    final types = node.list('types');
    if (columns.isEmpty && rows.isEmpty) return const SizedBox.shrink();
    final total = node.bool_('total') ?? false;

    final header = <String>[for (final c in columns) '$c'];
    final body = <List<String>>[
      for (final r in rows)
        if (r is List) [for (final c in r) c == null ? '' : '$c'],
    ];

    // 合计行：数值列求和（规范里 total:true 的语义）
    if (total && body.isNotEmpty) {
      final sumRow = <String>[];
      for (var c = 0; c < header.length; c++) {
        if (c == 0) {
          sumRow.add('合计');
          continue;
        }
        var sum = 0.0;
        var numeric = true;
        for (final r in body) {
          if (c >= r.length) continue;
          final v = double.tryParse(r[c].replaceAll(RegExp(r'[,\s%¥$]'), ''));
          if (v == null) {
            numeric = false;
            break;
          }
          sum += v;
        }
        sumRow.add(numeric ? (sum == sum.roundToDouble() ? '${sum.toInt()}' : sum.toStringAsFixed(1)) : '');
      }
      body.add(sumRow);
    }

    String? typeOf(int i) {
      if (i < types.length) {
        final t = types[i];
        if (t is String) return t;
      }
      return null;
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: context.c.border),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 34,
          dataRowMinHeight: 34,
          dataRowMaxHeight: 44,
          horizontalMargin: 12,
          columnSpacing: 16,
          headingRowColor: WidgetStatePropertyAll(context.c.surfaceMuted),
          dividerThickness: 0.6,
          border: TableBorder(horizontalInside: BorderSide(color: context.c.border, width: 0.6)),
          columns: [
            for (var i = 0; i < header.length; i++)
              DataColumn(
                label: Text(
                  header[i],
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                ),
              ),
          ],
          rows: [
            for (final r in body)
              DataRow(
                cells: [
                  for (var i = 0; i < header.length; i++) DataCell(_tableCell(context, i < r.length ? r[i] : '', typeOf(i))),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// 表格单元格里的胶囊标签。规范把 `tone` 留给独立的 badge 组件，
  /// 单元格只有文本，所以这里用中性底而不是猜一个语义色。
  Widget _cellBadge(BuildContext context, String raw) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: context.c.surfaceMuted,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: context.c.border),
      ),
      child: Text(raw, style: TextStyle(fontSize: 11, color: context.c.textSecondary)),
    );
  }

  Widget _tableCell(BuildContext context, String raw, String? type) {
    switch (type) {
      case 'index':
        return Text(raw.isEmpty ? '' : raw, style: TextStyle(fontSize: 11.5, color: context.c.textTertiary));
      case 'badge':
        return _cellBadge(context, raw);
      case 'bar':
        final v = double.tryParse(raw.replaceAll('%', '')) ?? 0;
        return SizedBox(
          width: 64,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: (v / 100).clamp(0, 1).toDouble(),
              minHeight: 5,
              backgroundColor: context.c.border,
              valueColor: AlwaysStoppedAnimation(context.c.accent),
            ),
          ),
        );
      case 'delta':
        return Text(raw, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: raw.startsWith('-') ? context.c.danger : context.c.success));
      case 'num':
        return Text(raw, style: TextStyle(fontSize: 12, color: context.c.textPrimary), textAlign: TextAlign.right);
      default:
        if (type == null && (raw.startsWith('+') || raw.startsWith('-'))) {
          return Text(raw, style: TextStyle(fontSize: 12, color: raw.startsWith('-') ? context.c.danger : context.c.success));
        }
        return GenuiInlineText(
          raw,
          style: TextStyle(fontSize: 12, color: context.c.textPrimary),
          onLink: onLink,
          linkColor: context.c.accent,
        );
    }
  }

  Widget _keyvalue(BuildContext context) {
    final pairs = node.list('pairs');
    if (pairs.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final p in pairs)
          if (p is Map)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: GenuiInlineText('${p['key'] ?? ''}', style: TextStyle(fontSize: 12, color: context.c.textSecondary)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GenuiInlineText(
                      '${p['value'] ?? ''}',
                      style: TextStyle(fontSize: 12.5, color: context.c.textPrimary),
                      onLink: onLink,
                      linkColor: context.c.accent,
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _timeline(BuildContext context) {
    final items = node.list('items');
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          if (items[i] is Map)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.only(top: 4),
                        decoration: BoxDecoration(color: context.c.accent, shape: BoxShape.circle),
                      ),
                      if (i != items.length - 1)
                        Expanded(child: Container(width: 1.5, color: context.c.border)),
                    ],
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if ((items[i] as Map)['time'] != null)
                            Text('${(items[i] as Map)['time']}', style: TextStyle(fontSize: 11, color: context.c.textTertiary)),
                          GenuiInlineText(
                            '${(items[i] as Map)['title'] ?? ''}',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                          ),
                          if ((items[i] as Map)['desc'] != null)
                            GenuiInlineText('${(items[i] as Map)['desc']}', style: TextStyle(fontSize: 12, color: context.c.textSecondary, height: 1.6)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _fileTree(BuildContext context) {
    final items = node.list('items');
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [for (final item in items) _fileNode(context, item, 0)],
    );
  }

  Widget _fileNode(BuildContext context, Object? raw, int level) {
    if (raw is! Map) return const SizedBox.shrink();
    final name = '${raw['name'] ?? ''}';
    final isDir = raw['type'] == 'dir';
    final children = raw['children'] is List ? raw['children'] as List : const [];
    final row = Padding(
      padding: EdgeInsets.only(left: level * 14.0, top: 2, bottom: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isDir ? Icons.folder_rounded : Icons.insert_drive_file_outlined,
            size: 14,
            color: isDir ? context.c.warning : context.c.textTertiary,
          ),
          const SizedBox(width: 5),
          GenuiInlineText(name, style: TextStyle(fontSize: 12, color: context.c.textPrimary)),
        ],
      ),
    );
    if (!isDir || children.isEmpty) return row;
    // 目录默认展开：手机上手势成本高，而树通常不深。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [row, for (final c in children) _fileNode(context, c, level + 1)],
    );
  }

  Widget _breadcrumb(BuildContext context) {
    final items = node.list('items');
    final parts = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) {
        parts.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Icon(Icons.chevron_right_rounded, size: 14, color: context.c.textTertiary),
        ));
      }
      parts.add(GenuiInlineText('${items[i]}', style: TextStyle(fontSize: 12, color: context.c.textSecondary)));
    }
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: parts);
  }

  Widget _diff(BuildContext context) {
    final diffs = node.list('diffs');
    if (diffs.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final d in diffs)
          if (d is Map)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                border: Border.all(color: context.c.border),
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    color: context.c.surfaceMuted,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text(
                      '${d['path'] ?? ''}',
                      style: TextStyle(fontSize: 11.5, fontFamily: 'monospace', color: context.c.textPrimary),
                    ),
                  ),
                  if (d['oldText'] != null) _diffLines(context, '${d['oldText']}', isOld: true),
                  if (d['newText'] != null) _diffLines(context, '${d['newText']}', isOld: false),
                ],
              ),
            ),
      ],
    );
  }

  Widget _diffLines(BuildContext context, String text, {required bool isOld}) {
    final lines = text.split('\n');
    return Container(
      color: isOld ? context.c.dangerSurface : context.c.successSurface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Text(
              '${isOld ? '-' : '+'}$line',
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                height: 1.45,
                color: isOld ? context.c.danger : context.c.textPrimary,
              ),
            ),
        ],
      ),
    );
  }

  Widget _jsonBlock(BuildContext context) {
    final pretty = const JsonEncoder.withIndent('  ').convert(node.data['value'] ?? const {});
    return _mono(context, pretty);
  }

  Widget _code(BuildContext context) {
    final lang = node.nonEmpty('lang');
    final code = node.textAny(const ['code', 'value']) ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (lang != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(lang, style: TextStyle(fontSize: 10.5, color: context.c.textTertiary, letterSpacing: 0.4)),
          ),
        _mono(context, code, copyable: true),
      ],
    );
  }

  Widget _mono(BuildContext context, String text, {bool copyable = false}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: context.c.surfaceMuted,
        border: Border.all(color: context.c.border),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, fontFamily: 'monospace', height: 1.5, color: context.c.textPrimary),
            ),
          ),
          if (copyable && text.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: _copyButton(context, text, '复制'),
            ),
        ],
      ),
    );
  }

  Widget _copyButton(BuildContext context, String text, String label) {
    return TextButton.icon(
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (!context.mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
          content: Text('已复制'),
          duration: Duration(milliseconds: 900),
          behavior: SnackBarBehavior.floating,
        ));
      },
      icon: Icon(Icons.copy_rounded, size: 13, color: context.c.textSecondary),
      label: Text(label, style: TextStyle(fontSize: 11.5, color: context.c.textSecondary)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _callout(BuildContext context) {
    final tone = _toneColors(context, node.nonEmpty('tone') ?? 'info');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
      decoration: BoxDecoration(
        color: tone.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: tone.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (node.nonEmpty('title') != null)
            GenuiInlineText(
              node.nonEmpty('title')!,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: tone.fg),
            ),
          if (node.nonEmpty('content') != null)
            Padding(
              padding: EdgeInsets.only(top: node.nonEmpty('title') == null ? 0 : 3),
              child: GenuiInlineText(
                node.nonEmpty('content')!,
                style: TextStyle(fontSize: 12.5, color: context.c.textPrimary, height: 1.6),
                onLink: onLink,
                linkColor: tone.fg,
              ),
            ),
        ],
      ),
    );
  }

  Widget _steps(BuildContext context) {
    final steps = node.list('steps');
    if (steps.isEmpty) return const SizedBox.shrink();
    final current = (node.num_('current') ?? 0).toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < steps.length; i++)
          if (steps[i] is Map)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: i <= current ? context.c.accent : context.c.surfaceMuted,
                          shape: BoxShape.circle,
                          border: Border.all(color: i <= current ? context.c.accent : context.c.border),
                        ),
                        child: Center(
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: i <= current ? Colors.white : context.c.textTertiary,
                            ),
                          ),
                        ),
                      ),
                      if (i != steps.length - 1)
                        Expanded(child: Container(width: 1.5, color: context.c.border)),
                    ],
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 10, top: 1),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GenuiInlineText(
                            '${(steps[i] as Map)['title'] ?? ''}',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                          ),
                          if ((steps[i] as Map)['desc'] != null)
                            GenuiInlineText('${(steps[i] as Map)['desc']}', style: TextStyle(fontSize: 12, color: context.c.textSecondary, height: 1.6)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _copy(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: node.textAny(const ['text', 'value']) ?? ''));
          if (!context.mounted) return;
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
            content: Text('已复制'),
            duration: Duration(milliseconds: 900),
            behavior: SnackBarBehavior.floating,
          ));
        },
        icon: Icon(Icons.copy_rounded, size: 14, color: context.c.accent),
        label: Text(
          node.textAny(const ['label']) ?? '复制',
          style: TextStyle(fontSize: 12, color: context.c.accent),
        ),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          side: BorderSide(color: context.c.border),
        ),
      ),
    );
  }

  Widget _link(BuildContext context) {
    final href = node.nonEmpty('href');
    final label = node.textAny(const ['label', 'text']) ?? href ?? '';
    final clickable = href != null && (href.startsWith('http://') || href.startsWith('https://') || href.startsWith('mailto:')) && onLink != null;
    return InkWell(
      onTap: clickable ? () => onLink!(href) : null,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12.5,
          color: clickable ? context.c.accent : context.c.textSecondary,
          decoration: clickable ? TextDecoration.underline : null,
          decorationColor: context.c.accent,
        ),
      ),
    );
  }

  Widget _image(BuildContext context) {
    final src = node.nonEmpty('src') ?? '';
    final isRemote = src.startsWith('http://') || src.startsWith('https://');
    if (!isRemote) {
      // 相对路径（如 /mmx-files/x.png）需要宿主 base，App 侧不做猜测 ——
      // 猜错会显示一张烂图，比明确说"打不开"更糟。
      return _Unsupported(node: node, reason: '图片地址是相对路径，App 需要宿主基地址才能加载');
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        src,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _Unsupported(node: node, reason: '图片加载失败'),
      ),
    );
  }

  Widget _chart(BuildContext context) {
    final kind = node.nonEmpty('kind') ?? 'bars';
    final data = <GenuiPoint>[];
    final raw = node.list('data');
    for (var i = 0; i < raw.length; i++) {
      final p = GenuiPoint.fromJson(raw[i], i);
      if (p != null) data.add(p);
    }
    final series = <GenuiSeries>[];
    for (final s in node.list('series')) {
      final parsed = GenuiSeries.fromJson(s);
      if (parsed != null && parsed.points.isNotEmpty) series.add(parsed);
    }
    final palette = <Color>[];
    for (final c in node.list('palette')) {
      if (c is String) {
        final parsed = parseHexColor(c);
        if (parsed != null) palette.add(parsed);
      }
    }
    if (data.isEmpty && series.isEmpty) return const SizedBox.shrink();
    return GenuiChart(
      kind: kind,
      data: data,
      series: series,
      horizontal: node.bool_('horizontal') ?? false,
      stacked: node.bool_('stacked') ?? false,
      palette: palette,
      height: (node.num_('height') ?? 220).clamp(120, 420).toDouble(),
    );
  }

  // ------------------------------------------------------------ 工具 ----

  /// 语义色对：surface（底）/ border（描边）/ fg（前景）。用主题 token 而不是硬编码，
  /// 深色模式下才不会是"刺眼的色块"。
  _ToneColors _toneColors(BuildContext context, String tone) {
    switch (tone) {
      case 'success':
        return _ToneColors(context.c.successSurface, context.c.success, context.c.success);
      case 'warning':
        return _ToneColors(context.c.warningSurface, context.c.warningBorder, context.c.warning);
      case 'danger':
      case 'error':
        return _ToneColors(context.c.dangerSurface, context.c.dangerBorder, context.c.danger);
      default:
        return _ToneColors(context.c.accentSurface, context.c.border, context.c.accent);
    }
  }

  static Color? _hex(String? s) => s == null ? null : parseHexColor(s);
}

/// `#RRGGBB` / `RRGGBB` / `#RGB` → Color。失败返回 null。
Color? parseHexColor(String s) {
  var hex = s.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length == 3) {
    hex = '${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}';
  }
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return null;
  final v = int.tryParse(hex, radix: 16);
  return v == null ? null : Color(v);
}

class _ToneColors {
  const _ToneColors(this.surface, this.border, this.fg);
  final Color surface;
  final Color border;
  final Color fg;
}

/// tabs / accordion：本地展开状态，零往返（规范里的"本地优先"）。
class _Tabs extends StatefulWidget {
  const _Tabs({required this.node, this.onLink, required this.depth});
  final GenuiNode node;
  final void Function(String href)? onLink;
  final int depth;

  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = widget.node.list('tabs');
    if (tabs.isEmpty) return const SizedBox.shrink();
    final labels = [for (final t in tabs) if (t is Map) '${t['label'] ?? ''}' else '$t'];
    final current = _index.clamp(0, tabs.length - 1);
    final selected = tabs[current];
    final items = (selected is Map && selected['items'] is List) ? selected['items'] as List : const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < labels.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onTap: () => setState(() => _index = i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: i == current ? context.c.accentSurface : context.c.surfaceMuted,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: i == current ? context.c.accent : context.c.border),
                      ),
                      child: Text(
                        labels[i],
                        style: TextStyle(
                          fontSize: 12,
                          color: i == current ? context.c.accent : context.c.textSecondary,
                          fontWeight: i == current ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          if (items[i] is Map)
            GenuiNodeView(
              node: GenuiNode.fromJson(Map<String, dynamic>.from(items[i] as Map)),
              onLink: widget.onLink,
              depth: widget.depth + 1,
            ),
        ],
      ],
    );
  }
}

class _Accordion extends StatefulWidget {
  const _Accordion({required this.node, this.onLink, required this.depth});
  final GenuiNode node;
  final void Function(String href)? onLink;
  final int depth;

  @override
  State<_Accordion> createState() => _AccordionState();
}

class _AccordionState extends State<_Accordion> {
  final Set<int> _open = {0};

  @override
  Widget build(BuildContext context) {
    final items = widget.node.list('items');
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          if (items[i] is Map)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                border: Border.all(color: context.c.border),
                borderRadius: BorderRadius.circular(9),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InkWell(
                    onTap: () => setState(() => _open.contains(i) ? _open.remove(i) : _open.add(i)),
                    child: Container(
                      color: context.c.surfaceMuted,
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                      child: Row(
                        children: [
                          Expanded(
                            child: GenuiInlineText(
                              '${(items[i] as Map)['title'] ?? ''}',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                            ),
                          ),
                          Icon(
                            _open.contains(i) ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                            size: 18,
                            color: context.c.textSecondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_open.contains(i))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(11, 9, 11, 11),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final child in ((items[i] as Map)['items'] is List ? (items[i] as Map)['items'] as List : const []))
                            if (child is Map)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: GenuiNodeView(
                                  node: GenuiNode.fromJson(Map<String, dynamic>.from(child)),
                                  onLink: widget.onLink,
                                  depth: widget.depth + 1,
                                ),
                              ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
      ],
    );
  }
}

/// 不支持的类型：一句说明 + 可展开的原始 JSON。**不丢信息**。
class _Unsupported extends StatelessWidget {
  const _Unsupported({required this.node, this.reason});

  final GenuiNode node;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: context.c.surfaceMuted,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: context.c.border),
      ),
      padding: const EdgeInsets.fromLTRB(11, 8, 11, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.widgets_outlined, size: 14, color: context.c.textTertiary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '组件 ${node.type} 暂不支持在手机上渲染',
                  style: TextStyle(fontSize: 12, color: context.c.textSecondary),
                ),
              ),
            ],
          ),
          if (reason != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 20),
              child: Text(reason!, style: TextStyle(fontSize: 11, color: context.c.textTertiary)),
            ),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 6),
              dense: true,
              title: Text('查看原始数据', style: TextStyle(fontSize: 11.5, color: context.c.textTertiary)),
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    const JsonEncoder.withIndent('  ').convert(node.data),
                    style: TextStyle(fontSize: 11, fontFamily: 'monospace', height: 1.5, color: context.c.textPrimary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// stat 的微趋势线。
class _Sparkline extends CustomPainter {
  _Sparkline({required this.values, required this.color});
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);
    final span = (max - min) == 0 ? 1.0 : (max - min);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height - (values[i] - min) / span * (size.height - 4) - 2;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _Sparkline old) => old.values != values;
}

/// progress 的环形变体。
class _Ring extends CustomPainter {
  _Ring({required this.value, required this.color, required this.track});
  final double value;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const width = 5.0;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height).deflate(width / 2 + 1);
    final base = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    canvas.drawArc(rect, 0, 6.2831853, false, base);
    canvas.drawArc(
      rect,
      -1.5707963,
      value.clamp(0, 1) * 6.2831853,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _Ring old) => old.value != value;
}
