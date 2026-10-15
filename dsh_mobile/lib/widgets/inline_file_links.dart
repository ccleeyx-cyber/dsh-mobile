/// 正文里的产物引用 → 可点链接（与 `SafeMarkdown.onTapLink` 配套）。
///
/// 为什么需要这一层：`present` 声明的产物目前只在「本轮产出」卡片和信息面板里
/// 可点，而 agent 在正文里提文件名才是最自然的形态（"已生成 `报告.docx`"）。
/// 用户看到名字却点不动，只能往上滚到卡片、或翻进信息面板。
///
/// 四条设计约束，每条都有对应测试：
///
/// 1. **只链接化本会话声明过的产物**。这里刻意不做"看起来像路径"的通用识别：
///    通用正则会命中正文里的示例路径、别人的目录、纯属打比方的文件名，而"点开
///    一个不存在的文件"比"点不动"更糟——它把一句可信的话变成了一次报错。清单
///    是白名单，零误伤。
/// 2. **围栏代码块一个字符都不动**。多行代码里的路径属于程序文本，在那里插
///    `[..](..)` 会让用户直接看到 markdown 源码。
/// 3. **行内 code 例外，但它有严格条件**：`` `报告.docx` `` 是 agent 提产物最
///    常见的写法，而反引号内根本不解析 markdown——原样跳过等于这功能一半失效。
///    所以当反引号内**整段恰好就是这个产物名**时，连同反引号一起换成链接；
///    只要内部还有别的字符（`` `见 报告.docx` ``、`` `a.md; b.md` ``）就整段不动。
/// 4. **已有的链接与裸 URL 不动**，避免链接里嵌链接。
///
/// 幂等：改写结果里的链接会被 [_linkSpans] 整体跳过，所以对同一段文本连续调用两次
/// 与调用一次结果相同（宿主在若干重建路径里会重复预处理）。
library;

import '../models/task_center.dart';

/// 自定义 scheme：`dsh-file:<百分号编码的绝对路径>`。
///
/// 用 `dsh-file` 而不是直接写服务器 URL：正文里插的 href 必须是**纯标记**，真正
/// 去取内容的那次请求由宿主（`chat_view`）决定，这样预览走的是和其他两个入口
/// 完全相同的链路（同一个弹层、同一个 loader），而不是第二条数据通路。
const String kDshFileScheme = 'dsh-file';

/// 把一条产物绝对路径编码成可安全放进 markdown 链接的 href。
///
/// 为什么不能直接用 `Uri.encodeComponent` 就完事：它保留 `(` `)` `'` 不编码，
/// 而 `)` 正是 markdown 内联链接的结束符——路径里带括号的产物（`报告(1).docx`
/// 这种自动重命名的文件太常见了）会当场把链接语法截断。所以这三个字符补编码。
String encodeDshFileHref(String absolutePath) => '$kDshFileScheme:${_encodePath(absolutePath)}';

String _encodePath(String path) => Uri.encodeComponent(path)
    .replaceAll('(', '%28')
    .replaceAll(')', '%29')
    .replaceAll("'", '%27');

/// 从 href 解出绝对路径。不是本 scheme、或编码坏了时返回 null。
String? decodeDshFileHref(String? href) {
  if (href == null) return null;
  const prefix = '$kDshFileScheme:';
  if (!href.startsWith(prefix)) return null;
  final raw = href.substring(prefix.length);
  if (raw.isEmpty) return null;
  try {
    final decoded = Uri.decodeComponent(raw);
    return decoded.isEmpty ? null : decoded;
  } catch (_) {
    // 坏编码（用户手打、或上游截断）不该抛进渲染帧里——按"不是产物链接"处理。
    return null;
  }
}

/// 这个 href 是不是产物链接。
bool isDshFileHref(String? href) => href != null && href.startsWith('$kDshFileScheme:');

/// 把正文里出现过的产物引用改写成 markdown 链接，原样返回其余文本。
String linkifyDeliverableRefs(String markdown, List<DeliverableItem> deliverables) {
  if (markdown.isEmpty || deliverables.isEmpty) return markdown;

  final tokens = _candidateTokens(deliverables);
  if (tokens.isEmpty) return markdown;

  final fences = _codeFenceSpans(markdown);
  final inlineCode = _inlineCodeSpans(markdown, fences);
  // 链接与裸 URL 也是禁区（只在围栏与行内 code 之外的那些里找）。
  final links = _linkSpans(markdown, <_Span>[...fences, ...inlineCode]);
  final hard = <_Span>[...fences, ...links];

  final hits = <_Hit>[];
  for (final token in tokens) {
    var from = 0;
    while (true) {
      final start = markdown.indexOf(token.text, from);
      if (start < 0) break;
      from = start + 1; // +1 而不是 +len：token 自重叠时也不漏
      final end = start + token.text.length;
      if (_overlapsAny(hard, start, end)) continue;

      final code = _containing(inlineCode, start, end);
      if (code != null) {
        // 反引号内必须是**整段**这个产物名；替换范围扩到反引号本身，否则用户
        // 看到的是 `[报告.docx](dsh-file:…)` 这一串源码。
        if (start != code.innerStart || end != code.innerEnd) continue;
        hits.add(_Hit(code.start, code.end, token));
        continue;
      }
      if (!_hasBoundaries(markdown, start, end)) continue;
      hits.add(_Hit(start, end, token));
    }
  }
  if (hits.isEmpty) return markdown;

  // 起点升序、同起点长的优先 —— 再按"不重叠"贪心取一遍，这样 `out/a.md` 不会被
  // `a.md` 吃掉一半而留下一个半截链接。
  hits.sort((a, b) => a.start != b.start ? a.start - b.start : b.end - a.end);
  final chosen = <_Hit>[];
  var cursor = 0;
  for (final hit in hits) {
    if (hit.start < cursor) continue;
    chosen.add(hit);
    cursor = hit.end;
  }

  final buffer = StringBuffer();
  var pos = 0;
  for (final hit in chosen) {
    buffer
      ..write(markdown.substring(pos, hit.start))
      ..write('[')
      ..write(hit.token.text)
      ..write('](')
      ..write(hit.token.href)
      ..write(')');
    pos = hit.end;
  }
  buffer.write(markdown.substring(pos));
  return buffer.toString();
}

// ------------------------------------------------------------------ 候选词 ----

/// 按用户写下的**字样**在清单里找产物：绝对路径、相对路径、文件名都认。
///
/// 用在"点了正文里的链接"那一侧：链进去的可能是本 App 生成的 `dsh-file:` 链接，
/// 也可能是 agent 自己写的 `[名字](相对路径)`。清单按 `seq` 倒序传进来，所以同名
/// 命中时返回的是最近声明的那一份。
DeliverableItem? matchDeliverableByRef(List<DeliverableItem> deliverables, String ref) {
  final wanted = ref.trim().replaceAll(r'\', '/');
  if (wanted.isEmpty) return null;

  DeliverableItem? suffixHit;
  for (final item in deliverables) {
    if (item.path.isEmpty) continue;
    final path = item.path.replaceAll(r'\', '/');
    final display = item.display.trim().replaceAll(r'\', '/');
    if (path == wanted || display == wanted) return item;
    if (item.fileName.isNotEmpty && item.fileName == wanted) return item;
    if (suffixHit == null && wanted.length >= 3) {
      for (final candidate in <String>[path, display]) {
        if (candidate.length <= wanted.length || !candidate.endsWith(wanted)) continue;
        // 后缀必须落在目录分隔符上，否则 `report.md` 会命中 `myreport.md`。
        if (candidate.codeUnitAt(candidate.length - wanted.length - 1) != 0x2F) continue;
        suffixHit = item;
        break;
      }
    }
  }
  return suffixHit;
}

class _Token {
  const _Token(this.text, this.href);
  final String text;
  final String href;
}

class _Hit {
  const _Hit(this.start, this.end, this.token);
  final int start;
  final int end;
  final _Token token;
}

/// 一个产物可能被写成的几种样子：相对路径、文件名、绝对路径，各含两种斜杠。
///
/// 为什么要斜杠变体：网关回传的 `display` 保留 agent 当初写下的**反斜杠**
/// （`数据库变更\03_变更记录.md`），而 agent 在正文里往往写正斜杠的同一个文件。
/// 只按原样匹配的话，这类引用一次都命中不了。
List<_Token> _candidateTokens(List<DeliverableItem> items) {
  final byText = <String, _Token>{};
  for (final item in items) {
    if (item.path.isEmpty) continue;
    final href = encodeDshFileHref(item.path);
    final variants = <String>{};
    for (final raw in <String>[item.display, item.fileName, item.path]) {
      final text = raw.trim();
      // 短名字（`a.md`、`1.txt`）在正文里到处都是，边界检查挡不住全部；而三个
      // 字符以内本来也不可能唯一指向一个文件。
      if (text.length < 3) continue;
      // 方括号会破坏 `[文本](href)` 的语法，含它的文件名直接不参与链接化。
      if (text.contains('[') || text.contains(']')) continue;
      variants.add(text);
      if (text.contains(r'\')) variants.add(text.replaceAll(r'\', '/'));
      if (text.contains('/')) variants.add(text.replaceAll('/', r'\'));
    }
    for (final text in variants) {
      byText.putIfAbsent(text, () => _Token(text, href));
    }
  }
  return byText.values.toList(growable: false)
    ..sort((a, b) => b.text.length - a.text.length);
}

// -------------------------------------------------------------- 保护区间 ----

class _Span {
  const _Span(this.start, this.end);
  final int start;
  final int end;
}

/// 行内 code：`start`/`end` 含反引号，`innerStart`/`innerEnd` 是不含反引号的内容区。
class _CodeSpan extends _Span {
  const _CodeSpan(super.start, super.end, this.innerStart, this.innerEnd);
  final int innerStart;
  final int innerEnd;
}

/// 行首（最多 3 空格缩进）的 ``` 或 ~~~ 围栏，成对配对；未闭合的吃到结尾。
List<_Span> _codeFenceSpans(String text) {
  final spans = <_Span>[];
  final fence = RegExp('^[ \\t]{0,3}(?:`{3,}|~{3,})', multiLine: true);
  int? openStart;
  for (final m in fence.allMatches(text)) {
    if (openStart == null) {
      openStart = m.start;
    } else {
      spans.add(_Span(openStart, m.end));
      openStart = null;
    }
  }
  if (openStart != null) spans.add(_Span(openStart, text.length));
  return spans;
}

/// 行内 code：等长反引号 run 之间算一个区间。未配对的反引号按普通字符处理。
List<_CodeSpan> _inlineCodeSpans(String text, List<_Span> fences) {
  final spans = <_CodeSpan>[];
  final marks = RegExp('`+').allMatches(text).toList(growable: false);
  var i = 0;
  while (i < marks.length) {
    final open = marks[i];
    if (_overlapsAny(fences, open.start, open.end)) {
      i++;
      continue;
    }
    final runLength = open.group(0)!.length;
    var closed = false;
    for (var j = i + 1; j < marks.length; j++) {
      final candidate = marks[j];
      if (_overlapsAny(fences, candidate.start, candidate.end)) continue;
      if (candidate.group(0)!.length != runLength) continue;
      spans.add(_CodeSpan(open.start, candidate.end, open.end, candidate.start));
      i = j + 1;
      closed = true;
      break;
    }
    if (!closed) i++;
  }
  return spans;
}

/// 已有的 markdown 链接（含图片）与裸 URL —— 整体跳过。
List<_Span> _linkSpans(String text, List<_Span> excluded) {
  final spans = <_Span>[];
  final patterns = <RegExp>[
    RegExp(r'!?\[[^\]]*\]\([^)\n]*\)'),
    RegExp(r'<https?://[^>\s]+>'),
    RegExp(r'https?://[^\s<>\)\]]+'),
  ];
  for (final re in patterns) {
    for (final m in re.allMatches(text)) {
      if (_overlapsAny(excluded, m.start, m.end)) continue;
      spans.add(_Span(m.start, m.end));
    }
  }
  return spans;
}

_CodeSpan? _containing(List<_CodeSpan> spans, int start, int end) {
  for (final s in spans) {
    if (start >= s.start && end <= s.end) return s;
  }
  return null;
}

bool _overlapsAny(List<_Span> spans, int start, int end) {
  for (final s in spans) {
    if (start < s.end && s.start < end) return true;
  }
  return false;
}

/// token 两侧必须是"词边界"，否则 `xout/a.md` 里的 `out/a.md` 也会被算成命中。
///
/// 尾部额外排除 `/` `\`：token 后面还接路径分隔符，说明它是更长路径的前缀
/// （`out/a.md/bak` 里的 `out/a.md`），链到它就是把用户带到另一个位置。
bool _hasBoundaries(String text, int start, int end) {
  if (start > 0 && _isWordChar(text.codeUnitAt(start - 1))) return false;
  if (end < text.length) {
    final c = text.codeUnitAt(end);
    if (_isWordChar(c)) return false;
    if (c == 0x2F || c == 0x5C) return false;
  }
  return true;
}

bool _isWordChar(int c) =>
    (c >= 0x30 && c <= 0x39) || // 0-9
    (c >= 0x41 && c <= 0x5A) || // A-Z
    (c >= 0x61 && c <= 0x7A) || // a-z
    c == 0x5F; // _
