import 'dart:convert';

/// One tool invocation decoded from the tool input payload.
///
/// The wire format is not stable across tools: most carry a JSON object, but a
/// parallel bash call can arrive as several JSON objects concatenated without a
/// separator. Keeping this as a presentation model lets the widget render the
/// command without guessing on every build.
class ToolInvocation {
  const ToolInvocation({
    this.command,
    this.description,
    this.details = const {},
  });

  final String? command;
  final String? description;
  final Map<String, String> details;

  bool get hasCommand => command != null && command!.trim().isNotEmpty;
}

/// Parsed, human-oriented projection of [ToolExecution.input].
class ToolInputView {
  const ToolInputView._({
    required this.raw,
    required this.invocations,
    required this.structured,
  });

  factory ToolInputView.parse(String raw) {
    final text = _stripCodeFence(raw.trim());
    final decoded = _decodeJsonSequence(text);
    if (decoded == null || decoded.isEmpty) {
      return ToolInputView._(
          raw: raw, invocations: const [], structured: false);
    }

    final maps = <Map<String, dynamic>>[];
    for (final value in decoded) {
      if (value is Map) {
        maps.add(Map<String, dynamic>.from(value));
      } else if (value is List) {
        for (final item in value) {
          if (item is! Map) {
            return ToolInputView._(
              raw: raw,
              invocations: const [],
              structured: false,
            );
          }
          maps.add(Map<String, dynamic>.from(item));
        }
      } else {
        return ToolInputView._(
            raw: raw, invocations: const [], structured: false);
      }
    }
    if (maps.isEmpty) {
      return ToolInputView._(
          raw: raw, invocations: const [], structured: false);
    }

    return ToolInputView._(
      raw: raw,
      structured: true,
      invocations: maps.map(_invocationFromMap).toList(growable: false),
    );
  }

  final String raw;
  final List<ToolInvocation> invocations;
  final bool structured;

  bool get hasCommands => invocations.any((i) => i.hasCommand);
  int get commandCount => invocations.where((i) => i.hasCommand).length;

  /// Text copied by the command copy action. Raw input stays available via the
  /// explicit "原始参数" toggle.
  String get copyText {
    final commands = invocations
        .map((i) => i.command?.trim())
        .whereType<String>()
        .where((c) => c.isNotEmpty)
        .toList();
    return commands.isEmpty ? raw : commands.join('\n\n');
  }

  /// One-line summary for the collapsed row. Empty when the payload is opaque.
  String? get preview {
    if (!structured || invocations.isEmpty) {
      return _oneLine(raw);
    }
    final first = invocations.first;
    final command = _oneLine(first.command);
    final description = _oneLine(first.description);
    if (commandCount > 1) {
      final hint =
          (description?.isNotEmpty ?? false) ? description : (command ?? '');
      return hint == null || hint.isEmpty
          ? '$commandCount 条命令'
          : '$commandCount 条命令 · $hint';
    }
    if (description != null &&
        description.isNotEmpty &&
        command != null &&
        command.isNotEmpty) {
      return '$description · $command';
    }
    if (command != null && command.isNotEmpty) return command;
    if (description != null && description.isNotEmpty) return description;
    if (first.details.isNotEmpty) {
      final detail = first.details.entries.first;
      return _oneLine('${detail.key}: ${detail.value}');
    }
    return null;
  }

  static String? _oneLine(String? value, {int max = 180}) {
    if (value == null) return null;
    final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return null;
    return text.length > max ? '${text.substring(0, max)}…' : text;
  }

  static ToolInvocation _invocationFromMap(Map<String, dynamic> map) {
    final command =
        _firstString(map, const ['command', 'cmd', 'script', 'shell']);
    final description =
        _firstString(map, const ['description', 'reason', 'title', 'summary']);
    final details = <String, String>{};
    for (final entry in map.entries) {
      if (const {
        'command',
        'cmd',
        'script',
        'shell',
        'description',
        'reason',
        'title',
        'summary'
      }.contains(entry.key)) {
        continue;
      }
      final value = _shortValue(entry.value);
      if (value != null && value.isNotEmpty) details[entry.key] = value;
    }
    return ToolInvocation(
        command: command, description: description, details: details);
  }

  static String? _firstString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String) {
        final text = value.trim();
        if (text.isNotEmpty) return text;
      }
      if (value is List) {
        final text = value
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .join('\n');
        if (text.isNotEmpty) return text;
      }
    }
    return null;
  }

  static String? _shortValue(dynamic value) {
    if (value == null) return null;
    if (value is String) {
      return value.length > 240 ? '${value.substring(0, 240)}…' : value;
    }
    if (value is num || value is bool) return value.toString();
    try {
      final text = const JsonEncoder.withIndent('  ').convert(value);
      return text.length > 240 ? '${text.substring(0, 240)}…' : text;
    } catch (_) {
      return value.toString();
    }
  }

  static String _stripCodeFence(String text) {
    if (!text.startsWith('```')) return text;
    final firstBreak = text.indexOf('\n');
    if (firstBreak < 0) return text;
    final body = text.substring(firstBreak + 1);
    final end = body.lastIndexOf('```');
    return end >= 0 ? body.substring(0, end).trim() : body;
  }

  /// Decode one or more adjacent JSON values.
  ///
  /// `jsonDecode` only accepts exactly one value, so a payload shaped
  /// `{"command":"…"}{"command":"…"}` is otherwise treated as opaque and shown
  /// as one long line of braces. The scanner respects strings/escapes and
  /// nested objects/arrays.
  static List<dynamic>? _decodeJsonSequence(String text) {
    if (text.isEmpty) return null;
    final values = <dynamic>[];
    var index = 0;
    while (index < text.length) {
      while (index < text.length) {
        final ch = text[index];
        if (ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t' || ch == ',') {
          index++;
        } else {
          break;
        }
      }
      if (index >= text.length) break;
      final startChar = text[index];
      if (startChar != '{' && startChar != '[') return null;
      final end = _findValueEnd(text, index);
      if (end == null) return null;
      final slice = text.substring(index, end);
      try {
        values.add(jsonDecode(slice));
      } catch (_) {
        return null;
      }
      index = end;
    }
    return values;
  }

  static int? _findValueEnd(String text, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{' || ch == '[') {
        depth++;
      } else if (ch == '}' || ch == ']') {
        depth--;
        if (depth == 0) return i + 1;
        if (depth < 0) return null;
      }
    }
    return null;
  }
}
