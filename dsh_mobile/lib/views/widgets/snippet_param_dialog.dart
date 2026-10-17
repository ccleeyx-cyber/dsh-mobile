// 「填 `{param}` 参数」对话框（Phase 5.4）。
//
// 这是**快捷指令插入链路**里唯一需要用户输入的环节，刻意做成一个可复用函数而不是
// 塞进设置页或输入框里：
//
//   * 设置页的「试填」用它做预览（`custom_settings_view.dart`）；
//   * 输入框（`composer.dart`）在插入模板前也用它 —— 见交接给 Lead 的 patch 说明。
//
// 三条设计约束：
//
// 1. **一屏填完**。多个占位符 = 多个输入框一次性摆出来，绝不按顺序弹 N 次对话框：
//    连点 N 次"确定"是移动端最容易让人放弃的交互，而且中途取消会留下半填的结果。
// 2. **空值允许，但必须看得见后果**。留空的参数原样保留 `{名字}`（见
//    `LocalSnippet.render`），预览区显示的就是最终插进输入框的那段文字，
//    不是"大概是这样"。
// 3. **没有占位符就不弹框**。直接返回模板本身，调用方不必分支。

import 'package:flutter/material.dart';

import '../../models/local_snippet.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// 弹出参数填写框，返回替换后的文本；用户取消返回 null。
///
/// 模板里没有 `{param}` 时**不弹框**、直接返回 [template]。
Future<String?> showSnippetParamDialog(
  BuildContext context, {
  required String title,
  required String template,
}) async {
  final names = LocalSnippet.placeholderNames(template);
  if (names.isEmpty) return template;

  final controllers = <String, TextEditingController>{
    for (final n in names) n: TextEditingController(),
  };
  final values = <String, String>{for (final n in names) n: ''};

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final preview = LocalSnippet.render(template, values);
        return AlertDialog(
          backgroundColor: ctx.c.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: ctx.c.border),
          ),
          title: Text(
            title.trim().isEmpty ? '填写参数' : title.trim(),
            style: TextStyle(
              fontSize: AppText.title,
              fontWeight: FontWeight.bold,
              color: ctx.c.textPrimary,
            ),
          ),
          content: SizedBox(
            // 固定一个上界宽度：平板上不跟着屏幕拉成一条长横条。
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '这条指令有 ${names.length} 个参数，一次填完再插入。'
                    '留空的参数会原样保留 {名字}，不会偷偷删掉 —— 你可以在输入框里再补。',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      height: 1.4,
                      color: ctx.c.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpace.l),
                  for (final name in names)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.m),
                      child: TextField(
                        key: ValueKey('snippet-param-field-$name'),
                        controller: controllers[name],
                        // 第一个参数直接聚焦：一屏填完的前提是别让用户先点一下。
                        autofocus: name == names.first,
                        textInputAction: name == names.last
                            ? TextInputAction.done
                            : TextInputAction.next,
                        onChanged: (v) => setLocal(() => values[name] = v),
                        style: TextStyle(
                            fontSize: AppText.body, color: ctx.c.textPrimary),
                        decoration: InputDecoration(
                          labelText: '{$name}',
                          hintText: '留空则保留 {$name}',
                          isDense: true,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpace.s),
                  Text(
                    '预览（插入输入框的就是这段）',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      fontWeight: FontWeight.w600,
                      color: ctx.c.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpace.s),
                  Container(
                    key: const ValueKey('snippet-param-preview'),
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpace.l),
                    decoration: BoxDecoration(
                      color: ctx.c.surfaceMuted,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: ctx.c.border),
                    ),
                    child: Text(
                      preview,
                      style: TextStyle(
                        fontSize: AppText.subhead,
                        height: 1.4,
                        color: ctx.c.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('取消', style: TextStyle(color: ctx.c.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: ctx.c.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('使用',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    ),
  );

  // 先取值再 dispose：controller 释放之后 `text` 仍在，但那是实现细节，不赌它。
  final filled = <String, String>{
    for (final n in names) n: controllers[n]!.text,
  };
  for (final c in controllers.values) {
    c.dispose();
  }
  if (confirmed != true) return null;
  return LocalSnippet.render(template, filled);
}
