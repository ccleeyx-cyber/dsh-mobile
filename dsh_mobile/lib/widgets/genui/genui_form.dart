import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import 'genui_parse.dart';

/// 一次 `[genui-action]` 回传：动作名 + 组件数据。
typedef GenuiActionCallback = void Function(
  String action,
  Map<String, dynamic> data,
);

/// 表单状态只属于当前这一个 ```dsh-ui 规格。
///
/// 不放进全局单例是刻意的：两份相同题目的消息不能共享答案；但同一个 spec
/// 在组件重建时（滚动、主题切换、父级 notify）必须保留用户已填的内容，
/// 所以 controller 由外层 Stateful host 持有，而不是每个输入框自己一份。
class GenuiFormController extends ChangeNotifier {
  final Map<String, List<String>> answers = <String, List<String>>{};
  final Map<String, String> fields = <String, String>{};

  bool locked = false;

  void setRadio(String group, String value) {
    if (locked) return;
    answers[group] = [value];
    notifyListeners();
  }

  void setCheckbox(String group, String label, bool checked) {
    if (locked) return;
    final set = (answers[group] ?? const <String>[]).toList();
    if (checked) {
      if (!set.contains(label)) set.add(label);
    } else {
      set.remove(label);
    }
    if (set.isEmpty) {
      answers.remove(group);
    } else {
      answers[group] = set;
    }
    notifyListeners();
  }

  void setField(String id, String value) {
    if (locked || id.isEmpty) return;
    if (fields[id] == value) return;
    if (value.isEmpty) {
      fields.remove(id);
    } else {
      fields[id] = value;
    }
    notifyListeners();
  }

  bool isComplete(String key) {
    if ((answers[key] ?? const <String>[]).isNotEmpty) return true;
    return (fields[key] ?? '').trim().isNotEmpty;
  }

  int answered(List<String>? groups) {
    if (groups != null && groups.isNotEmpty) {
      return groups.where(isComplete).length;
    }
    return answers.values.where((v) => v.isNotEmpty).length +
        fields.values.where((v) => v.trim().isNotEmpty).length;
  }

  int total(List<String>? groups) {
    if (groups != null && groups.isNotEmpty) return groups.length;
    return answers.length + fields.length;
  }

  /// 提交时的稳定形状：`answers` 放分组标签，`fields` 放带 id 的输入值。
  Map<String, dynamic> payload(List<String>? groups) {
    final cleanAnswers = <String, List<String>>{};
    for (final e in answers.entries) {
      final values = e.value.where((v) => v.trim().isNotEmpty).toList();
      if (values.isNotEmpty) cleanAnswers[e.key] = values;
    }
    final cleanFields = <String, String>{};
    for (final e in fields.entries) {
      final value = e.value.trim();
      if (value.isNotEmpty) cleanFields[e.key] = value;
    }
    return {
      'answers': cleanAnswers,
      'fields': cleanFields,
      'total': total(groups),
      'answered': answered(groups),
    };
  }

  void lock() {
    locked = true;
    notifyListeners();
  }
}

/// 会话内的表单状态缓存。
///
/// Chat 列表会回收滚出屏幕的消息；如果状态只挂在 widget 上，用户选完单选项
/// 往下滚去点提交，回来时答案就没了。按**规格内容**缓存（不是按位置），
/// 相同内容重建可恢复，换题自动得到新 controller。
class GenuiFormStore {
  static final Map<String, GenuiFormController> _cache = {};

  static GenuiFormController forSignature(String signature) {
    final existing = _cache.remove(signature);
    if (existing != null) {
      _cache[signature] = existing; // 触达即刷新 LRU
      return existing;
    }
    final controller = GenuiFormController();
    _cache[signature] = controller;
    while (_cache.length > 40) {
      // 只从缓存淘汰，不 dispose：可能仍有旧 widget 正在监听。
      _cache.remove(_cache.keys.first);
    }
    return controller;
  }
}

/// 把 controller 和回传通道传给规格树里的任意深度子节点。
class GenuiFormScope extends InheritedWidget {
  const GenuiFormScope({
    super.key,
    required this.controller,
    required this.onAction,
    required super.child,
  });

  final GenuiFormController controller;
  final GenuiActionCallback? onAction;

  bool get canAct => onAction != null;

  static GenuiFormScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GenuiFormScope>();

  @override
  bool updateShouldNotify(GenuiFormScope oldWidget) =>
      controller != oldWidget.controller || onAction != oldWidget.onAction;
}

List<String> _optionLabels(GenuiNode node) {
  final raw = node.data['options'];
  if (raw is! List) return const [];
  final out = <String>[];
  for (final item in raw) {
    if (item is String && item.trim().isNotEmpty) {
      out.add(item);
    } else if (item is Map) {
      final label = item['label'] ?? item['value'] ?? item['title'];
      if (label is String && label.trim().isNotEmpty) out.add(label);
    }
  }
  return out;
}

String _label(GenuiNode node, [String fallback = '']) =>
    node.nonEmpty('label') ?? fallback;

String _action(GenuiNode node) => node.nonEmpty('action') ?? '';

String _id(GenuiNode node) => node.nonEmpty('id') ?? '';

int? _int(GenuiNode node, String key) {
  final value = node.data[key];
  return value is num ? value.toInt() : null;
}

int? _selectedIndex(List<String>? values, List<String> options) {
  if (values == null || values.isEmpty) return null;
  final index = options.indexOf(values.first);
  return index < 0 ? null : index;
}

void _emit(
  BuildContext context,
  String action,
  Map<String, dynamic> data,
) {
  if (action.isEmpty) return;
  final scope = GenuiFormScope.maybeOf(context);
  final callback = scope?.onAction;
  if (callback == null) return;
  callback(action, data);
}

Widget _fieldLabel(BuildContext context, String text) {
  if (text.isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: context.c.textPrimary,
      ),
    ),
  );
}

InputDecoration _inputDecoration(BuildContext context, String hint) {
  return InputDecoration(
    hintText: hint.isEmpty ? null : hint,
    hintStyle: TextStyle(fontSize: 13, color: context.c.textTertiary),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
    filled: true,
    fillColor: context.c.surfaceMuted,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: context.c.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: context.c.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: context.c.accent, width: 1.4),
    ),
  );
}

class GenuiTextField extends StatefulWidget {
  const GenuiTextField({super.key, required this.node, this.multiline = false});

  final GenuiNode node;
  final bool multiline;

  @override
  State<GenuiTextField> createState() => _GenuiTextFieldState();
}

class _GenuiTextFieldState extends State<GenuiTextField> {
  late final TextEditingController _text;
  late final FocusNode _focus;
  String _lastSent = '';
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.node.nonEmpty('value') ?? '';
    _text = TextEditingController(text: initial);
    _focus = FocusNode();
    _focus.addListener(_onBlur);
    _lastSent = initial;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _seeded = true;
    final saved =
        GenuiFormScope.maybeOf(context)?.controller.fields[_id(widget.node)];
    if (saved != null && saved.isNotEmpty) {
      _text.text = saved;
      _lastSent = saved;
    }
  }

  @override
  void didUpdateWidget(covariant GenuiTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只在身份/初始值真的换了时改写输入框；普通父级重建不能把用户正在输入的
    // 内容覆盖回初始 value。
    if (oldWidget.node.nonEmpty('value') != widget.node.nonEmpty('value') &&
        !_focus.hasFocus) {
      final next = widget.node.nonEmpty('value') ?? '';
      _text.text = next;
      _lastSent = next;
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onBlur);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _onBlur() {
    if (_focus.hasFocus) return;
    _send(reason: 'blur');
  }

  void _send({required String reason}) {
    final action = _action(widget.node);
    if (action.isEmpty || _lastSent == _text.text) return;
    _lastSent = _text.text;
    _emit(context, action, {
      if (_id(widget.node).isNotEmpty) 'id': _id(widget.node),
      'value': _text.text,
      if (reason == 'submit') 'submit': true,
    });
  }

  @override
  Widget build(BuildContext context) {
    final scope = GenuiFormScope.maybeOf(context);
    final id = _id(widget.node);
    final label = _label(widget.node);
    final hint = widget.node.nonEmpty('placeholder') ?? '';
    final keyboard = widget.node.nonEmpty('inputType');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _fieldLabel(context, label),
        TextField(
          controller: _text,
          focusNode: _focus,
          maxLines: widget.multiline ? (_int(widget.node, 'rows') ?? 3) : 1,
          minLines: widget.multiline ? 2 : 1,
          keyboardType: keyboard == 'email'
              ? TextInputType.emailAddress
              : (widget.multiline
                  ? TextInputType.multiline
                  : TextInputType.text),
          style: TextStyle(fontSize: 13.5, color: context.c.textPrimary),
          decoration: _inputDecoration(context, hint),
          onChanged: (value) => scope?.controller.setField(id, value),
          onSubmitted: (_) => _send(reason: 'submit'),
        ),
      ],
    );
  }
}

class GenuiRadioField extends StatefulWidget {
  const GenuiRadioField({super.key, required this.node});

  final GenuiNode node;

  @override
  State<GenuiRadioField> createState() => _GenuiRadioFieldState();
}

class _GenuiRadioFieldState extends State<GenuiRadioField> {
  int? _localSelected;
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    _localSelected = _int(widget.node, 'selected');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _seeded = true;
    final group = widget.node.nonEmpty('group');
    final selected = _int(widget.node, 'selected');
    final scope = GenuiFormScope.maybeOf(context);
    if (group == null || selected == null || scope == null) return;
    if (scope.controller.answers[group]?.isNotEmpty ?? false) return;
    final options = _optionLabels(widget.node);
    if (selected < 0 || selected >= options.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      scope.controller.setRadio(group, options[selected]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final options = _optionLabels(widget.node);
    final group = widget.node.nonEmpty('group');
    final action = _action(widget.node);
    final scope = GenuiFormScope.maybeOf(context);
    final selected = group == null
        ? _localSelected
        : _selectedIndex(scope?.controller.answers[group], options);
    final canTap = group != null
        ? scope != null && !scope.controller.locked
        : (action.isEmpty || (scope?.canAct ?? false));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _fieldLabel(context, _label(widget.node)),
        for (var i = 0; i < options.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: !canTap
                  ? null
                  : () {
                      if (group != null) {
                        scope!.controller.setRadio(group, options[i]);
                      } else {
                        setState(() => _localSelected = i);
                        _emit(context, action, {'value': options[i]});
                      }
                    },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
                decoration: BoxDecoration(
                  color: selected == i
                      ? context.c.accent.withOpacity(0.08)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected == i
                        ? context.c.accent.withOpacity(0.45)
                        : context.c.border.withOpacity(0.6),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      selected == i
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: selected == i
                          ? context.c.accent
                          : context.c.textTertiary,
                    ),
                    const SizedBox(width: AppSpace.s),
                    Expanded(
                      child: Text(
                        options[i],
                        style: TextStyle(
                          fontSize: 13,
                          color: context.c.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class GenuiCheckboxField extends StatefulWidget {
  const GenuiCheckboxField({super.key, required this.node});

  final GenuiNode node;

  @override
  State<GenuiCheckboxField> createState() => _GenuiCheckboxFieldState();
}

class _GenuiCheckboxFieldState extends State<GenuiCheckboxField> {
  bool _local = false;

  @override
  void initState() {
    super.initState();
    _local = widget.node.bool_('checked') ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final label = _label(widget.node);
    final group = widget.node.nonEmpty('group');
    final action = _action(widget.node);
    final scope = GenuiFormScope.maybeOf(context);
    final checked = group == null
        ? _local
        : (scope?.controller.answers[group]?.contains(label) ?? false);
    final canTap = group != null
        ? scope != null && !scope.controller.locked
        : (action.isEmpty || (scope?.canAct ?? false));

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: !canTap
          ? null
          : () {
              final next = !checked;
              if (group != null) {
                scope!.controller.setCheckbox(group, label, next);
              } else {
                setState(() => _local = next);
                _emit(context, action, {
                  'label': label,
                  'checked': next,
                });
              }
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              checked
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 19,
              color: checked ? context.c.accent : context.c.textTertiary,
            ),
            const SizedBox(width: AppSpace.s),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 13, color: context.c.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GenuiSelectField extends StatefulWidget {
  const GenuiSelectField({super.key, required this.node});

  final GenuiNode node;

  @override
  State<GenuiSelectField> createState() => _GenuiSelectFieldState();
}

class _GenuiSelectFieldState extends State<GenuiSelectField> {
  String? _value;
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    final options = _optionLabels(widget.node);
    final selected = _int(widget.node, 'selected');
    if (selected != null && selected >= 0 && selected < options.length) {
      _value = options[selected];
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _seeded = true;
    final saved =
        GenuiFormScope.maybeOf(context)?.controller.fields[_id(widget.node)];
    if (saved != null &&
        saved.isNotEmpty &&
        _optionLabels(widget.node).contains(saved)) {
      _value = saved;
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = _optionLabels(widget.node);
    final action = _action(widget.node);
    final id = _id(widget.node);
    final scope = GenuiFormScope.maybeOf(context);
    final selected = _value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _fieldLabel(context, _label(widget.node)),
        DropdownButtonFormField<String>(
          value: selected,
          isDense: true,
          decoration: _inputDecoration(context, '请选择…'),
          style: TextStyle(fontSize: 13, color: context.c.textPrimary),
          items: [
            for (final option in options)
              DropdownMenuItem<String>(
                value: option,
                child: Text(option, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: !(scope?.canAct ?? false) && action.isNotEmpty
              ? null
              : (value) {
                  if (value == null) return;
                  setState(() => _value = value);
                  scope?.controller.setField(id, value);
                  if (action.isNotEmpty) {
                    _emit(context, action, {
                      if (id.isNotEmpty) 'id': id,
                      'value': value,
                    });
                  }
                },
        ),
      ],
    );
  }
}

class GenuiSwitchField extends StatefulWidget {
  const GenuiSwitchField({super.key, required this.node});

  final GenuiNode node;

  @override
  State<GenuiSwitchField> createState() => _GenuiSwitchFieldState();
}

class _GenuiSwitchFieldState extends State<GenuiSwitchField> {
  late bool _checked;

  @override
  void initState() {
    super.initState();
    _checked = widget.node.bool_('checked') ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final action = _action(widget.node);
    final scope = GenuiFormScope.maybeOf(context);
    final canTap = action.isEmpty || (scope?.canAct ?? false);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: !canTap
          ? null
          : () {
              setState(() => _checked = !_checked);
              _emit(context, action, {'checked': _checked});
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _label(widget.node),
                style: TextStyle(fontSize: 13, color: context.c.textPrimary),
              ),
            ),
            Switch(
              value: _checked,
              onChanged: !canTap
                  ? null
                  : (value) {
                      setState(() => _checked = value);
                      _emit(context, action, {'checked': value});
                    },
            ),
          ],
        ),
      ),
    );
  }
}

class GenuiSliderField extends StatefulWidget {
  const GenuiSliderField({super.key, required this.node});

  final GenuiNode node;

  @override
  State<GenuiSliderField> createState() => _GenuiSliderFieldState();
}

class _GenuiSliderFieldState extends State<GenuiSliderField> {
  late double _value;

  @override
  void initState() {
    super.initState();
    final raw = widget.node.data['value'];
    _value = raw is num ? raw.toDouble() : 0;
  }

  @override
  Widget build(BuildContext context) {
    final min = (widget.node.data['min'] as num?)?.toDouble() ?? 0;
    final max = (widget.node.data['max'] as num?)?.toDouble() ?? 100;
    final step = (widget.node.data['step'] as num?)?.toDouble() ?? 1;
    final action = _action(widget.node);
    final id = _id(widget.node);
    final scope = GenuiFormScope.maybeOf(context);
    final rounded =
        (_value / (step <= 0 ? 1 : step)).round() * (step <= 0 ? 1 : step);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
                child: Text(
              _label(widget.node),
              style: TextStyle(fontSize: 13, color: context.c.textPrimary),
            )),
            Text(
              rounded.toStringAsFixed(step < 1 ? 1 : 0),
              style: TextStyle(fontSize: 12.5, color: context.c.textSecondary),
            ),
          ],
        ),
        Slider(
          value: _value.clamp(min, max).toDouble(),
          min: min,
          max: max <= min ? min + 1 : max,
          divisions: step > 0 && max > min
              ? ((max - min) / step).round().clamp(1, 1000)
              : null,
          onChanged: scope?.controller.locked ?? false
              ? null
              : (value) {
                  setState(() => _value = value);
                  scope?.controller
                      .setField(id, value.toStringAsFixed(step < 1 ? 1 : 0));
                },
          onChangeEnd: (value) {
            if (action.isNotEmpty && (scope?.canAct ?? false)) {
              _emit(context, action, {
                if (id.isNotEmpty) 'id': id,
                'value': value,
              });
            }
          },
        ),
      ],
    );
  }
}

class GenuiSubmitButton extends StatelessWidget {
  const GenuiSubmitButton({super.key, required this.node});

  final GenuiNode node;

  @override
  Widget build(BuildContext context) {
    final action = _action(node);
    final scope = GenuiFormScope.maybeOf(context);
    if (scope == null) return const SizedBox.shrink();
    final groupsRaw = node.data['groups'];
    final groups =
        groupsRaw is List ? groupsRaw.whereType<String>().toList() : <String>[];
    final controller = scope.controller;
    final accounted = groups.isEmpty
        ? controller.answered(null)
        : controller.answered(groups);
    final span = groups.isEmpty
        ? controller.total(null)
        : (groups.isEmpty ? 0 : groups.length);
    final ready =
        accounted > 0 && (groups.isEmpty || accounted >= groups.length);
    final enabled =
        ready && !controller.locked && action.isNotEmpty && scope.canAct;

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 40,
            child: FilledButton.icon(
              key: const ValueKey('genui-submit'),
              onPressed: enabled
                  ? () {
                      controller.lock();
                      _emit(context, action, controller.payload(groups));
                    }
                  : null,
              icon: Icon(
                controller.locked
                    ? Icons.check_circle_outline_rounded
                    : Icons.send_rounded,
                size: 16,
              ),
              label: Text(
                controller.locked ? '已提交' : (_label(node, '提交选择')),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              controller.locked
                  ? '等待更新'
                  : '已填 $accounted/$span${groups.isEmpty ? '' : ''}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: AppText.caption,
                color: context.c.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GenuiButton extends StatefulWidget {
  const GenuiButton({super.key, required this.node});

  final GenuiNode node;

  @override
  State<GenuiButton> createState() => _GenuiButtonState();
}

class _GenuiButtonState extends State<GenuiButton> {
  bool _sent = false;

  @override
  Widget build(BuildContext context) {
    final action = _action(widget.node);
    final scope = GenuiFormScope.maybeOf(context);
    final label = _label(widget.node, '继续');
    final tone = widget.node.nonEmpty('tone') ?? 'primary';
    final enabled = action.isNotEmpty && (scope?.canAct ?? false) && !_sent;
    final onPressed = enabled
        ? () {
            setState(() => _sent = true);
            _emit(context, action, const {});
          }
        : null;
    final child =
        Text(_sent ? '已触发' : label, style: const TextStyle(fontSize: 13));
    final button = tone == 'ghost'
        ? OutlinedButton(onPressed: onPressed, child: child)
        : FilledButton(onPressed: onPressed, child: child);
    return widget.node.bool_('full') == true
        ? SizedBox(width: double.infinity, child: button)
        : Align(alignment: Alignment.centerLeft, child: button);
  }
}

class GenuiQuiz extends StatefulWidget {
  const GenuiQuiz({super.key, required this.node});

  final GenuiNode node;

  @override
  State<GenuiQuiz> createState() => _GenuiQuizState();
}

class _GenuiQuizState extends State<GenuiQuiz> {
  int? _selected;
  bool _sent = false;

  List<Map<String, dynamic>> get _options {
    final raw = widget.node.data['options'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final options = _options;
    final action = _action(widget.node);
    final scope = GenuiFormScope.maybeOf(context);
    final selected = _selected;
    final correct = selected != null &&
        selected >= 0 &&
        selected < options.length &&
        options[selected]['correct'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.node.nonEmpty('question') ?? '',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: context.c.textPrimary,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < options.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                setState(() => _selected = i);
                if (!_sent &&
                    selected == null &&
                    action.isNotEmpty &&
                    (scope?.canAct ?? false)) {
                  _sent = true;
                  _emit(context, action, {
                    'type': 'quiz',
                    'question': widget.node.nonEmpty('question') ?? '',
                    'answer': options[i]['label'],
                    'correct': options[i]['correct'] == true,
                  });
                }
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: selected == i
                      ? (correct
                          ? context.c.success.withOpacity(0.10)
                          : context.c.danger.withOpacity(0.08))
                      : context.c.surfaceMuted,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected == i
                        ? (correct ? context.c.success : context.c.danger)
                        : context.c.border,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${options[i]['label'] ?? ''}',
                        style: TextStyle(
                            fontSize: 13, color: context.c.textPrimary),
                      ),
                    ),
                    if (selected == i)
                      Icon(
                        correct ? Icons.check_rounded : Icons.close_rounded,
                        size: 17,
                        color: correct ? context.c.success : context.c.danger,
                      ),
                  ],
                ),
              ),
            ),
          ),
        if (selected != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              correct
                  ? (options[selected]['feedback']?.toString() ??
                      widget.node.nonEmpty('explanation') ??
                      '回答正确')
                  : '再试一次',
              style: TextStyle(
                fontSize: 12,
                color: correct ? context.c.success : context.c.textSecondary,
              ),
            ),
          ),
      ],
    );
  }
}
