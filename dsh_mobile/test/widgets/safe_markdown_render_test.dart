import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/widgets/genui/genui_view.dart';
import 'package:dsh_mobile/widgets/safe_markdown.dart';

/// 真机反馈的两条渲染缺陷（2026-10-21）的回归钉子。
///
/// 两条的根因各在一处，都在 `safe_markdown.dart`：
/// 1. **CRLF 击穿围栏正则** —— 闭合围栏的模式是 `^[ \t]{0,3}`{3,}[ \t]*$`，
///    CRLF 下这一行是 "```\r"，`\r` 不在 `[ \t]` 里 → 匹配失败 → 整段
///    ```dsh-ui 被当成未闭合代码块 → 屏幕上是裸 JSON 而不是列表。
/// 2. **段内单换行被折叠成空格** —— flutter_markdown 默认 `softLineBreak:false`，
///    实现是 `text.replaceAll(' ?\n *', ' ')`；而模型正文用单换行分句、空行分段，
///    于是整段在手机上糊成一坨（网页端是 GFM breaks 语义）。
void main() {
  const spec =
      '{"title":"推送方式","gap":10,"items":[{"type":"list","items":["直接推","并到下一个版本","建分支推"]}]}';

  /// 收集当前树里所有文本内容的纯文本。
  ///
  /// `SafeMarkdown` 默认 `selectable: true`，此时 flutter_markdown 走的是
  /// `SelectableText.rich`（`data` 为 null，正文在 `textSpan` 里），所以两种
  /// widget 都要收 —— 只找 `RichText` 会什么都收不到。
  List<String> plainTexts(WidgetTester tester) {
    final out = <String>[];
    for (final w in tester.widgetList<RichText>(find.byType(RichText))) {
      out.add(w.text.toPlainText());
    }
    for (final s in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
      final span = s.textSpan;
      if (span != null) out.add(span.toPlainText());
      if (s.data != null) out.add(s.data!);
    }
    return out;
  }

  Future<void> pump(WidgetTester tester, String data) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: SafeMarkdown(data: data)),
      ),
    ));
    await tester.pump();
  }

  testWidgets('CRLF 正文里的 dsh-ui 围栏仍要渲染成组件，不能显示裸 JSON', (tester) async {
    const crlf = '三个选择：\r\n\r\n```dsh-ui\r\n$spec\r\n```\r\n\r\n收尾。';
    await pump(tester, crlf);

    expect(find.byType(GenuiSpecView), findsWidgets,
        reason: 'CRLF 不应让围栏退化成代码块');

    final joined = plainTexts(tester).join('\n');
    expect(joined.contains('"title":"推送方式"'), isFalse,
        reason: '渲染出组件时不应该再把原始 JSON 当正文显示');
  });

  testWidgets('同一段内容用 LF 时行为一致（防止只修了 CRLF 分支）', (tester) async {
    const lf = '三个选择：\n\n```dsh-ui\n$spec\n```\n\n收尾。';
    await pump(tester, lf);
    expect(find.byType(GenuiSpecView), findsWidgets);
  });

  testWidgets('段内单换行要保留换行，不能被折叠成一个空格', (tester) async {
    await pump(tester, '第一行\n第二行');

    final joined = plainTexts(tester).join('');
    expect(joined.contains('\n'), isTrue,
        reason: 'softLineBreak=false 会把 \\n 替换成空格，整段糊成一坨');
    expect(joined.contains('第一行 第二行'), isFalse);
  });
}
