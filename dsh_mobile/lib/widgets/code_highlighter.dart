/// 零依赖语法高亮器（Phase 4.2）。
///
/// ## 为什么不引 `flutter_highlight` 之类的包
///
/// 高亮一份**交付物预览**只需要五类信息：注释、字符串、数字、关键字、标点。为这
/// 五类引入一个几十 KB、带几百个语言定义、又要跟着依赖图一起升级的包，换来的是
/// "能把 Scala 的宏高亮对"——而预览层永远不会展示那些文件。这里用 Dart 自带的
/// `RegExp` 拼一条合并正则，按"最左匹配 + 规则优先级"切 token：零依赖、零代码
/// 生成、可被 widget 测试直接覆盖。
///
/// ## 颜色为什么是参数而不是这里的常量
///
/// 颜色必须来自 `context.c.<token>`（深色模式的唯一正确来源）。高亮器因此刻意不
/// 认识 `BuildContext`：调用方把 [CodePalette] 传进来，本文件里没有任何色值常量。
///
/// ## token 化规则
///
/// 每种语言编译成**一条**合并正则（`r0|r1|…`，每条规则自带非捕获组），规则顺序
/// 即优先级：
///
/// 1. 行注释 → 2. 块注释（先吃掉注释，否则 `'http://x'` 里的 `//` 会被当注释）
/// 3. 三引号字符串 → 4. 单行字符串 → 5. 关键字 → 6. 数字 → 7. 标点
///
/// 正则引擎是"最左匹配"，所以字符串内部的 `//`、注释内部的引号不会互相误判：
/// 起点更靠前的那条规则先赢；顺序只在**同一位置**上起作用。
///
/// **不变式：每条规则内部只能用非捕获组 `(?:…)`。** 合并后第 i 条规则对应
/// `match.group(i + 1)`，靠这个下标决定 token 类型；一旦某条规则里出现捕获组，
/// 下标整体错位，高亮会变成随机上色。改本文件的规则时请守住这条。
library;

import 'package:flutter/material.dart';

/// 一个 token 被赋予的类型。`plain` 是没被任何规则匹配到的默认段
/// （标识符、空白、换行）——它占绝大多数长度，所以必须是最便宜的那一档。
enum CodeTokenKind { plain, comment, string, number, keyword, punctuation }

/// 调色板：颜色由调用方从 `context.c.<token>` 取好后传进来。
///
/// 这样本文件里既没有硬编码色值字面量，也不需要知道当前是浅色还是深色。
class CodePalette {
  const CodePalette({
    required this.plain,
    required this.comment,
    required this.string,
    required this.number,
    required this.keyword,
    required this.punctuation,
  });

  final Color plain;
  final Color comment;
  final Color string;
  final Color number;
  final Color keyword;
  final Color punctuation;

  Color colorOf(CodeTokenKind kind) => switch (kind) {
        CodeTokenKind.plain => plain,
        CodeTokenKind.comment => comment,
        CodeTokenKind.string => string,
        CodeTokenKind.number => number,
        CodeTokenKind.keyword => keyword,
        CodeTokenKind.punctuation => punctuation,
      };
}

/// 一条 token 规则。[pattern] 必须只用非捕获组（见文件头的不变式）。
class _Rule {
  const _Rule(this.kind, this.pattern);

  final CodeTokenKind kind;
  final String pattern;
}

/// 一门语言：扩展名 + 规则表。
///
/// 只在**已知**扩展名上构造；未知扩展名返回 null，调用方回落到纯等宽渲染 ——
/// "猜错语言"比"不高亮"更糟：给一份 .csv 上色会让数字列和文本列难以区分。
class CodeLanguage {
  CodeLanguage._(this.id, this.label, this.extensions, this._rules);

  /// 稳定标识，也是合并正则的缓存键。
  final String id;

  /// 人类可读名（tooltip / 调试用）。
  final String label;

  final List<String> extensions;

  final List<_Rule> _rules;

  // ------------------------------------------------------------ 语言注册 ----

  static final List<CodeLanguage> _all = [
    _dart(),
    _python(),
    _javascript(),
    _typescript(),
    _json(),
    _yaml(),
    _markdown(),
    _shell(),
    _sql(),
    _java(),
    _kotlin(),
  ];

  static final Map<String, CodeLanguage> _byExtension = {
    for (final lang in _all)
      for (final ext in lang.extensions) ext: lang,
  };

  /// 按文件名 / 路径取语言；未知或没有扩展名时返回 null（**不抛异常**）。
  ///
  /// 只认最后一段扩展名：`a.tar.gz` → `gz`（未知 → 回落），不做"猜测式"二次解析。
  static CodeLanguage? forFile(String nameOrPath) {
    if (nameOrPath.isEmpty) return null;
    final lower = nameOrPath.toLowerCase();
    final dot = lower.lastIndexOf('.');
    if (dot < 0 || dot == lower.length - 1) return null;
    // 路径里的点（`../a.dart`）不会造成误判：只取最后一个点之后的部分。
    return _byExtension[lower.substring(dot + 1)];
  }

  /// 供测试/调试：已支持的全部语言标识。
  static List<String> get supportedIds => [for (final lang in _all) lang.id];

  // -------------------------------------------------------------- 编译 ----

  static final Map<String, RegExp> _compiled = {};

  RegExp get _regex => _compiled.putIfAbsent(id, () {
        final buf = StringBuffer();
        for (final rule in _rules) {
          if (buf.isNotEmpty) buf.write('|');
          // 这里必须是**捕获组**：`group(i + 1) != null` 是判断"第 i 条规则命中"
          // 的唯一依据。规则内部才用非捕获组，两层分工见文件头的不变式。
          buf.write('(${rule.pattern})');
        }
        // multiLine 让 `^`/`$` 在 Markdown 的标题、引用行上生效；其它语言不依赖它。
        return RegExp(buf.toString(), multiLine: true);
      });

  /// 单次高亮的长度上限（字符）。
  ///
  /// **前提**：预览层拿到的文本由网关截断，现实量级是几十~几百 KB；这套合并正则
  /// 就是按那个量级调的（一次 allMatches，毫秒级）。若以后有人把截断上限调到整个
  /// 文件（几 MB），同步 tokenize 会卡住一帧 —— 超限时宁可不给上色（整段 plain，
  /// 观感与未知类型一致），也不要卡帧。这条守卫防的就是那个"以后"。
  static const int maxHighlightLength = 200000;

  /// 把 [source] 切成带类型的片段，供 UI 直接拼 `TextSpan`。
  ///
  /// 未匹配的长段（标识符、缩进、换行）整段保留为 `plain`，不做逐字符切分：
  /// 一份 200KB 的日志逐字符成 span 会有几万个对象，而它们全是同一个颜色。
  List<({CodeTokenKind kind, String text})> tokenize(String source) {
    if (source.isEmpty) return const [];
    if (source.length > maxHighlightLength) {
      return [(kind: CodeTokenKind.plain, text: source)];
    }
    final out = <({CodeTokenKind kind, String text})>[];
    var from = 0;
    for (final m in _regex.allMatches(source)) {
      if (m.end <= m.start) continue; // 防御：零宽匹配不该出现，出现也跳过
      if (m.start > from) {
        out.add((kind: CodeTokenKind.plain, text: source.substring(from, m.start)));
      }
      var kind = CodeTokenKind.plain;
      for (var i = 0; i < _rules.length; i++) {
        if (m.group(i + 1) != null) {
          kind = _rules[i].kind;
          break;
        }
      }
      out.add((kind: kind, text: source.substring(m.start, m.end)));
      from = m.end;
    }
    if (from < source.length) {
      out.add((kind: CodeTokenKind.plain, text: source.substring(from)));
    }
    return out;
  }

  // ---------------------------------------------------------- 正则片段 ----
  //
  // 全部写成 raw string：Dart 层不转义、正则层一次转义到底，读的人只需要懂正则。
  //
  // **已知边界**（无状态正则方案的固有代价，刻意不引入状态机去"修"）：
  // * shell 里的 `$#`（参数个数）、`${#var}`（长度）会被当成行注释起点，该行余下
  //   部分染成注释色；
  // * yaml 里未加引号的值中间出现 `#` 会被截成注释 —— 这与 YAML 规范一致，但用户
  //   把它当普通字符串写时会误伤；
  // * 单行字符串规则的结束引号是可选的（`'?`），所以多行字符串（如 JS 模板串以外
  //   的未闭合引号）会在行尾收束，后续行按普通代码上色。
  //
  // 这三处都只影响**颜色**，不影响内容：tokenize 的输出拼接恒等于原文（有测试守着
  // "不丢字"），所以最坏情况只是某段没上对色，而不会吞字符。

  static const String _slashComment = r'//[^\n]*';
  static const String _hashComment = r'#[^\n]*';
  static const String _dashComment = r'--[^\n]*';
  static const String _blockComment = r'/\*[\s\S]*?\*/';
  static const String _doubleString = r'"(?:\\.|[^"\\\n])*"?';
  static const String _singleString = r"'(?:\\.|[^'\\\n])*'?";
  static const String _backtickString = r'`(?:\\.|[^`\\])*`?';
  static const String _tripleDouble = r'"""[\s\S]*?"""';
  static const String _tripleSingle = r"'''[\s\S]*?'''";
  static const String _number = r'\b(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b';
  static const String _punctuation = r'[{}\(\)\[\];,.<>+\-*/%=&|!?:^~$]';

  /// `\b(?:a|b|c)\b`。全为标识符字符，天然被 `\b` 约束成整词，不会命中
  /// `iffy` 里的 `if`。
  static String _keywords(List<String> words, {bool caseInsensitive = false}) {
    final parts = <String>[
      for (final w in words) caseInsensitive ? _caseFolded(w) : w,
    ];
    return r'\b(?:' + parts.join('|') + r')\b';
  }

  /// SQL 的关键字大小写都常见（`select` / `SELECT`）。Dart 的正则没有内联 `(?i)`，
  /// 也不能对整条合并正则开 `caseSensitive: false`（那会把 `Class` 也当成关键字），
  /// 所以只把关键字本身逐字展开成 `[sS][eE]…`。
  static String _caseFolded(String keyword) {
    final buf = StringBuffer();
    for (final ch in keyword.split('')) {
      final upper = ch.toUpperCase();
      final lower = ch.toLowerCase();
      buf.write(upper == lower ? RegExp.escape(ch) : '[$lower$upper]');
    }
    return buf.toString();
  }

  /// 规则表组装：注释 → 字符串 → 关键字 → 数字 → 标点。
  static List<_Rule> _build({
    String? lineComment,
    bool blockComment = false,
    bool singleQuoted = true,
    bool doubleQuoted = true,
    bool backtickQuoted = false,
    bool tripleQuoted = false,
    required List<String> keywords,
    bool caseInsensitive = false,
    bool punctuation = true,
  }) {
    return [
      if (lineComment != null) _Rule(CodeTokenKind.comment, lineComment),
      if (blockComment) const _Rule(CodeTokenKind.comment, _blockComment),
      if (tripleQuoted) const _Rule(CodeTokenKind.string, _tripleDouble),
      if (tripleQuoted) const _Rule(CodeTokenKind.string, _tripleSingle),
      if (backtickQuoted) const _Rule(CodeTokenKind.string, _backtickString),
      if (doubleQuoted) const _Rule(CodeTokenKind.string, _doubleString),
      if (singleQuoted) const _Rule(CodeTokenKind.string, _singleString),
      if (keywords.isNotEmpty)
        _Rule(CodeTokenKind.keyword, _keywords(keywords, caseInsensitive: caseInsensitive)),
      const _Rule(CodeTokenKind.number, _number),
      if (punctuation) const _Rule(CodeTokenKind.punctuation, _punctuation),
    ];
  }

  // ------------------------------------------------------------ 具体语言 ----

  static CodeLanguage _dart() => CodeLanguage._(
        'dart',
        'Dart',
        const ['dart'],
        _build(
          lineComment: _slashComment,
          blockComment: true,
          tripleQuoted: true,
          keywords: const [
            'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch',
            'class', 'const', 'continue', 'covariant', 'default', 'deferred', 'do',
            'dynamic', 'else', 'enum', 'export', 'extends', 'extension', 'external',
            'factory', 'false', 'final', 'finally', 'for', 'get', 'hide', 'if',
            'implements', 'import', 'in', 'interface', 'is', 'late', 'library',
            'mixin', 'new', 'null', 'on', 'operator', 'part', 'required', 'rethrow',
            'return', 'set', 'show', 'static', 'super', 'switch', 'sync', 'this',
            'throw', 'true', 'try', 'typedef', 'var', 'void', 'while', 'with', 'yield',
          ],
        ),
      );

  static CodeLanguage _python() => CodeLanguage._(
        'python',
        'Python',
        const ['py', 'pyw', 'pyi'],
        _build(
          lineComment: _hashComment,
          tripleQuoted: true,
          keywords: const [
            'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue',
            'def', 'del', 'elif', 'else', 'except', 'False', 'finally', 'for', 'from',
            'global', 'if', 'import', 'in', 'is', 'lambda', 'None', 'nonlocal', 'not',
            'or', 'pass', 'raise', 'return', 'True', 'try', 'while', 'with', 'yield',
            'self',
          ],
        ),
      );

  static CodeLanguage _javascript() => CodeLanguage._(
        'javascript',
        'JavaScript',
        const ['js', 'jsx', 'mjs', 'cjs'],
        _build(
          lineComment: _slashComment,
          blockComment: true,
          backtickQuoted: true,
          keywords: const [
            'async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue',
            'debugger', 'default', 'delete', 'do', 'else', 'export', 'extends',
            'false', 'finally', 'for', 'from', 'function', 'if', 'import', 'in',
            'instanceof', 'let', 'new', 'null', 'of', 'return', 'static', 'super',
            'switch', 'this', 'throw', 'true', 'try', 'typeof', 'undefined', 'var',
            'void', 'while', 'yield',
          ],
        ),
      );

  static CodeLanguage _typescript() => CodeLanguage._(
        'typescript',
        'TypeScript',
        const ['ts', 'tsx', 'mts', 'cts'],
        _build(
          lineComment: _slashComment,
          blockComment: true,
          backtickQuoted: true,
          keywords: const [
            'abstract', 'any', 'as', 'asserts', 'async', 'await', 'boolean', 'break',
            'case', 'catch', 'class', 'const', 'continue', 'declare', 'default',
            'delete', 'do', 'else', 'enum', 'export', 'extends', 'false', 'finally',
            'for', 'from', 'function', 'if', 'implements', 'import', 'in',
            'instanceof', 'interface', 'keyof', 'let', 'namespace', 'never', 'new',
            'null', 'number', 'of', 'private', 'protected', 'public', 'readonly',
            'return', 'static', 'string', 'super', 'switch', 'this', 'throw', 'true',
            'try', 'type', 'typeof', 'undefined', 'unknown', 'var', 'void', 'while',
            'yield',
          ],
        ),
      );

  /// JSON 没有注释、没有单引号；字符串必须是双引号。若也吃单引号，`{'a': 1}` 这种
  /// 非法 JSON 里一个裸词就会被当字符串染成彩色，反而掩盖了"这不是合法 JSON"。
  static CodeLanguage _json() => CodeLanguage._(
        'json',
        'JSON',
        const ['json'],
        _build(
          singleQuoted: false,
          keywords: const ['true', 'false', 'null'],
        ),
      );

  /// YAML：注释、引号字符串、数字、布尔/空值。**键不单独上色** —— YAML 的键没有
  /// 引号，与裸值无法用正则可靠区分，硬标会得到"半行彩色半行灰"。
  static CodeLanguage _yaml() => CodeLanguage._(
        'yaml',
        'YAML',
        const ['yaml', 'yml'],
        _build(
          lineComment: _hashComment,
          keywords: const ['true', 'false', 'null', 'yes', 'no', 'on', 'off'],
        ),
      );

  /// Markdown：标题/加粗算"关键字"，行内代码与链接算"字符串"，引用算"注释"。
  /// 这是**源码视图**下的近似着色（渲染视图走 SafeMarkdown），够看清结构即可。
  static CodeLanguage _markdown() => CodeLanguage._(
        'markdown',
        'Markdown',
        const ['md', 'markdown'],
        const [
          _Rule(CodeTokenKind.string, r'```[\s\S]*?(?:```|$)'),
          _Rule(CodeTokenKind.keyword, r'^#{1,6}[ \t][^\n]*'),
          _Rule(CodeTokenKind.comment, r'^[ \t]*>[^\n]*'),
          _Rule(CodeTokenKind.string, r'`[^`\n]+`'),
          _Rule(CodeTokenKind.keyword, r'\*\*[^*\n]+\*\*'),
          _Rule(CodeTokenKind.string, r'\[[^\]\n]*\]\([^)\n]*\)'),
          _Rule(CodeTokenKind.punctuation, r'^[ \t]*[-*+][ \t]'),
        ],
      );

  static CodeLanguage _shell() => CodeLanguage._(
        'shell',
        'Shell',
        const ['sh', 'bash', 'zsh'],
        _build(
          lineComment: _hashComment,
          keywords: const [
            'if', 'then', 'else', 'elif', 'fi', 'for', 'in', 'do', 'done', 'while',
            'until', 'case', 'esac', 'function', 'return', 'local', 'export',
            'unset', 'source', 'eval', 'exec', 'trap', 'exit',
          ],
        ),
      );

  static CodeLanguage _sql() => CodeLanguage._(
        'sql',
        'SQL',
        const ['sql'],
        _build(
          lineComment: _dashComment,
          blockComment: true,
          caseInsensitive: true,
          keywords: const [
            'select', 'from', 'where', 'insert', 'into', 'values', 'update', 'set',
            'delete', 'create', 'table', 'drop', 'alter', 'add', 'column', 'index',
            'view', 'join', 'left', 'right', 'inner', 'outer', 'on', 'as', 'and',
            'or', 'not', 'null', 'is', 'in', 'like', 'between', 'group', 'by',
            'order', 'having', 'limit', 'offset', 'distinct', 'union', 'all', 'case',
            'when', 'then', 'else', 'end', 'primary', 'foreign', 'references',
            'default', 'constraint', 'unique', 'asc', 'desc', 'count', 'sum', 'avg',
            'min', 'max', 'cast', 'exists', 'begin', 'commit', 'rollback',
          ],
        ),
      );

  static CodeLanguage _java() => CodeLanguage._(
        'java',
        'Java',
        const ['java'],
        _build(
          lineComment: _slashComment,
          blockComment: true,
          tripleQuoted: true,
          keywords: const [
            'abstract', 'assert', 'boolean', 'break', 'byte', 'case', 'catch', 'char',
            'class', 'const', 'continue', 'default', 'do', 'double', 'else', 'enum',
            'extends', 'false', 'final', 'finally', 'float', 'for', 'if',
            'implements', 'import', 'instanceof', 'int', 'interface', 'long',
            'native', 'new', 'null', 'package', 'private', 'protected', 'public',
            'record', 'return', 'sealed', 'short', 'static', 'strictfp', 'super',
            'switch', 'synchronized', 'this', 'throw', 'throws', 'transient', 'true',
            'try', 'var', 'void', 'volatile', 'while',
          ],
        ),
      );

  static CodeLanguage _kotlin() => CodeLanguage._(
        'kotlin',
        'Kotlin',
        const ['kt', 'kts'],
        _build(
          lineComment: _slashComment,
          blockComment: true,
          tripleQuoted: true,
          keywords: const [
            'abstract', 'as', 'break', 'by', 'catch', 'class', 'companion', 'const',
            'constructor', 'continue', 'crossinline', 'data', 'do', 'dynamic',
            'else', 'enum', 'expect', 'external', 'false', 'field', 'file', 'final',
            'finally', 'for', 'fun', 'get', 'if', 'import', 'in', 'infix', 'init',
            'inline', 'inner', 'interface', 'internal', 'is', 'lateinit', 'noinline',
            'null', 'object', 'open', 'operator', 'out', 'override', 'package',
            'private', 'protected', 'public', 'reified', 'return', 'sealed', 'set',
            'setparam', 'super', 'suspend', 'tailrec', 'this', 'throw', 'true', 'try',
            'typealias', 'val', 'value', 'var', 'vararg', 'when', 'where', 'while',
          ],
        ),
      );
}

/// 把 [source] 按 [language] 切成 [TextSpan]，可直接喂给 `Text.rich` /
/// `SelectableText.rich`。
///
/// [language] 为 null（未知扩展名 / 纯文本）时返回**单个** plain span：不逐字符切，
/// 与"现有等宽渲染"等价，只是换了承载的 widget。
List<TextSpan> codeSpans(
  String source, {
  CodeLanguage? language,
  required CodePalette palette,
  TextStyle base = const TextStyle(),
}) {
  final plain = base.copyWith(color: palette.plain);
  if (source.isEmpty) return const [];
  if (language == null) return [TextSpan(text: source, style: plain)];

  return [
    for (final token in language.tokenize(source))
      TextSpan(
        text: token.text,
        style: token.kind == CodeTokenKind.plain
            ? plain
            : base.copyWith(color: palette.colorOf(token.kind)),
      ),
  ];
}
