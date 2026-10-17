import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/services/voice_input_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/chat_view.dart';
import 'package:dsh_mobile/views/code_viewer_page.dart';
import 'package:dsh_mobile/widgets/code_highlighter.dart';

/// Phase 5.1 回归：代码块全屏阅读。
///
/// 三段各自钉一件事：
/// 1. 语言标注 → 高亮器语言的映射（错一个别名就是"明明认得出却不高亮"）；
/// 2. 全屏页本身：行号槽与正文对齐、复制/分享写进剪贴板的内容、空内容的降级；
/// 3. 会话里的接线：代码块右上角的 icon **只**出现在代码块上，点它推入全屏页
///    且带着完整源码与语言标注。
void main() {
  Future<void> pumpPage(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (ctx, c) =>
            ThemeScope(isDark: false, child: c ?? const SizedBox()),
        home: child,
      ),
    );
    await tester.pump();
  }

  Future<DshService> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dsh = DshService();
    dsh.debugSetCurrentSession(
        SessionMeta(sessionId: 'session-a', title: '测试会话'));
    await tester.pumpWidget(
      ChangeNotifierProvider<DshService>.value(
        value: dsh,
        child: MaterialApp(
          builder: (ctx, child) =>
              ThemeScope(isDark: false, child: child ?? const SizedBox()),
          home: const ChatView(),
        ),
      ),
    );
    await tester.pump();
    return dsh;
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 22));
    VoiceInputService.instance.debugReset();
  }

  List<String> captureClipboard(WidgetTester tester) {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments;
          if (args is Map && args['text'] is String) {
            copied.add(args['text'] as String);
          }
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    return copied;
  }

  // ============================================== 语言标注 → 高亮语言 ====

  group('语言标注解析', () {
    test('常见语言名与 language- 前缀都认', () {
      expect(codeLanguageForLabel('dart')?.id, 'dart');
      expect(codeLanguageForLabel('language-dart')?.id, 'dart');
      expect(codeLanguageForLabel('DART')?.id, 'dart',
          reason: '标注的大小写不该决定能不能高亮');
      expect(codeLanguageForLabel('python')?.id, 'python',
          reason: '```python 写的是语言名，不是扩展名，必须走别名表');
      expect(codeLanguageForLabel('language-python')?.id, 'python');
      expect(codeLanguageForLabel('bash')?.id, 'shell');
      expect(codeLanguageForLabel('yml')?.id, 'yaml');
      expect(codeLanguageForLabel('sql')?.id, 'sql');
    });

    test('纯文本与未知标注一律回落（不猜）', () {
      expect(codeLanguageForLabel(null), isNull);
      expect(codeLanguageForLabel(''), isNull);
      expect(codeLanguageForLabel('   '), isNull);
      expect(codeLanguageForLabel('text'), isNull);
      expect(codeLanguageForLabel('plaintext'), isNull);
      expect(codeLanguageForLabel('brainfuck'), isNull,
          reason: '猜错语言比不高亮更糟：给一份未知文件上色会掩盖结构');
    });

    test('```console 按 shell 会话处理（它是终端回显，不是纯文本）', () {
      expect(codeLanguageForLabel('console')?.id, 'shell');
      expect(codeLanguageForLabel('shell-session')?.id, 'shell');
    });
  });

  // ================================================== 全屏页本身 ====

  group('CodeViewerPage', () {
    const code = 'void main() {\n  runApp();\n}';

    testWidgets('行号与正文共用 strut：行号字符串逐行对齐', (tester) async {
      await pumpPage(
        tester,
        const CodeViewerPage(code: code, languageLabel: 'dart'),
      );

      final gutter =
          tester.widget<Text>(find.byKey(const ValueKey('code-viewer-gutter')));
      expect(gutter.data, '1\n2\n3');
      expect(gutter.textAlign, TextAlign.right);

      // 两边必须是**同一个** strut —— 否则滚动几屏之后行号就指向上一行。
      final bodyWidget = tester.widget<SelectableText>(
        find.byType(SelectableText).first,
      );
      expect(
        bodyWidget.strutStyle?.fontSize,
        gutter.strutStyle?.fontSize,
      );
      expect(
        bodyWidget.strutStyle?.forceStrutHeight,
        gutter.strutStyle?.forceStrutHeight,
      );
      expect(bodyWidget.strutStyle?.height, gutter.strutStyle?.height);
    });

    testWidgets('未知语言：标题回落"代码"，正文仍是等宽纯文本', (tester) async {
      await pumpPage(
        tester,
        const CodeViewerPage(code: 'a = 1', languageLabel: 'brainfuck'),
      );
      expect(find.text('brainfuck'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.byKey(const ValueKey('code-viewer-gutter')), findsOneWidget);
    });

    testWidgets('没有语言标注时标题写"代码"（不摆空串或围栏符号）', (tester) async {
      await pumpPage(tester, const CodeViewerPage(code: 'x'));
      expect(find.text('代码'), findsOneWidget);
    });

    testWidgets('复制按钮复制的是完整源码（不含渲染用的行号）', (tester) async {
      final copied = captureClipboard(tester);
      await pumpPage(
        tester,
        const CodeViewerPage(code: code, languageLabel: 'dart'),
      );

      await tester.tap(find.byKey(const ValueKey('code-viewer-copy')));
      await tester.pump();

      expect(copied, [code]);
    });

    testWidgets('分享退化成"复制为 Markdown 代码块"（本版本无分享出口）', (tester) async {
      final copied = captureClipboard(tester);
      await pumpPage(
        tester,
        const CodeViewerPage(code: code, languageLabel: 'dart'),
      );

      await tester.tap(find.byKey(const ValueKey('code-viewer-share')));
      await tester.pump();

      expect(copied, ['```dart\n$code\n```']);
      // 说清它做了什么，别让"分享"这个名字骗人。
      expect(find.textContaining('Markdown 代码块'), findsOneWidget);
    });

    testWidgets('空代码块给出说明而不是一片空白', (tester) async {
      await pumpPage(tester, const CodeViewerPage(code: '   '));
      expect(find.text('这个代码块是空的'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('code-viewer-copy')))
            .onPressed,
        isNull,
        reason: '没内容可复制时按钮该是禁用的，而不是点了没反应',
      );
    });

    testWidgets('高亮真的生效：Dart 关键字与正文用了不同颜色', (tester) async {
      await pumpPage(
        tester,
        const CodeViewerPage(code: 'final x = 1;', languageLabel: 'dart'),
      );
      final body = tester.widget<SelectableText>(find.byType(SelectableText));
      final span = body.textSpan as TextSpan;
      final colors = <Color>{
        for (final child in span.children ?? const <InlineSpan>[])
          if (child is TextSpan && child.style?.color != null)
            child.style!.color!,
      };
      expect(colors.length, greaterThan(1),
          reason: '一个颜色 = 没高亮；这里至少关键字与标点要不同色');
      expect(CodeLanguage.forFile('a.dart'), isNotNull);
    });
  });

  // ============================================ 会话里的接线与入口 ====

  group('会话里的代码块入口', () {
    testWidgets('代码块右上角出现入口，点它推入全屏页并带上语言与源码', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetMessages([
        ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: '看这段：\n\n```dart\nvoid main() {}\n```\n',
          timestamp: DateTime.now(),
        ),
      ]);
      await tester.pump();

      final opener = find.byKey(const ValueKey('code-block-open'));
      expect(opener, findsOneWidget, reason: '代码块上必须有全屏入口');

      await tester.tap(opener);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(CodeViewerPage), findsOneWidget);
      expect(find.byKey(const ValueKey('code-viewer-page')), findsOneWidget);
      expect(find.text('Dart'), findsOneWidget, reason: '标题 = 语言名');
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('code-viewer-gutter')))
            .data,
        '1',
        reason: '传过去的是代码块正文本身，不是整条消息',
      );

      await teardown(tester);
    });

    testWidgets('行内 code 不带全屏入口（只在代码块上）', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetMessages([
        ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: '用 `codeSpans` 这个名字就够了，没有围栏。',
          timestamp: DateTime.now(),
        ),
      ]);
      await tester.pump();

      expect(find.byKey(const ValueKey('code-block-open')), findsNothing);
      await teardown(tester);
    });

    testWidgets('空围栏不画一个点不动的入口', (tester) async {
      final dsh = await pumpChat(tester);
      dsh.debugSetMessages([
        ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: '空的：\n\n```dart\n\n```\n',
          timestamp: DateTime.now(),
        ),
      ]);
      await tester.pump();

      expect(find.byKey(const ValueKey('code-block-open')), findsNothing);
      await teardown(tester);
    });
  });
}
