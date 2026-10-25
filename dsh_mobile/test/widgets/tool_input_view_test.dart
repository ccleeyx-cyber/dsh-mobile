import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/widgets/tool_input_view.dart';

void main() {
  group('ToolInputView', () {
    test('splits concatenated JSON objects without separators', () {
      const raw = '{"command":"cd /tmp && ls","description":"列出文件"}'
          '{"command":"pwd","description":"显示目录"}';

      final view = ToolInputView.parse(raw);

      expect(view.structured, isTrue);
      expect(view.commandCount, 2);
      expect(view.invocations[0].command, 'cd /tmp && ls');
      expect(view.invocations[0].description, '列出文件');
      expect(view.invocations[1].command, 'pwd');
      expect(view.preview, '2 条命令 · 列出文件');
      expect(view.copyText, 'cd /tmp && ls\n\npwd');
    });

    test('accepts a JSON array and a fenced JSON block', () {
      const raw =
          '```json\n[{"command":"git status -s","description":"状态"}]\n```';

      final view = ToolInputView.parse(raw);

      expect(view.hasCommands, isTrue);
      expect(view.commandCount, 1);
      expect(view.invocations.single.command, 'git status -s');
      expect(view.preview, '状态 · git status -s');
    });

    test('nested braces and escaped quotes do not split the object early', () {
      const raw =
          r"""{"command":"printf '%s\\n' \"{\"","description":"quoted"}""";

      final view = ToolInputView.parse(raw);

      expect(view.structured, isTrue);
      expect(view.invocations.single.command, contains('"{"'));
    });

    test('plain command strings stay unstructured and are used as preview', () {
      final view = ToolInputView.parse('git status -s');

      expect(view.structured, isFalse);
      expect(view.hasCommands, isFalse);
      expect(view.preview, 'git status -s');
      expect(view.copyText, 'git status -s');
    });

    test('malformed JSON falls back to raw instead of throwing', () {
      final view = ToolInputView.parse('{"command": ');

      expect(view.structured, isFalse);
      expect(view.copyText, '{"command": ');
    });
  });
}
