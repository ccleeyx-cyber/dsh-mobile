/// ```dsh-ui 围栏的切分与解析（纯逻辑，无 widget 依赖）。
///
/// 为什么 App 需要自己解析：GenUI 的渲染器是插件 `@changfenhuang/dsh-genui` 的
/// **浏览器侧**模块（`dsh.client.platform = "web"`，入口是
/// `window.__ModuleLoader__.load(...)`），只在 dsh web 客户端里运行。手机端拿不到
/// 它，于是 ```dsh-ui 围栏会走 markdown 的默认分支 —— 渲染成一坨裸 JSON 代码块。
/// 本文件是手机端自己的那一半：把围栏识别出来、解析成规格树，交给
/// `genui_view.dart` 画成本地组件。
///
/// 降级策略与 Web 端一致：**JSON 解析失败就原样保留那段围栏**（markdown 会把它
/// 渲染成代码块），而不是把内容丢掉 —— 用户至少能看到原文，也不会看到半截组件。
library;

import 'dart:convert';

/// 一段消息正文：要么是普通 markdown，要么是一个 GenUI 规格。
sealed class GenuiSegment {
  const GenuiSegment();
}

/// 普通 markdown 文本（含非 dsh-ui 的代码围栏）。
class MarkdownSegment extends GenuiSegment {
  const MarkdownSegment(this.text);
  final String text;
}

/// 一个解析成功的 ```dsh-ui 规格。
class GenuiSpecSegment extends GenuiSegment {
  const GenuiSpecSegment(this.spec);
  final GenuiSpec spec;
}

/// 一个 GenUI 规格：`{title?, gap?, items:[...]}`。
class GenuiSpec {
  const GenuiSpec({this.title, required this.items, this.gap = 0});

  final String? title;
  final List<GenuiNode> items;
  final double gap;

  /// 顶层也可以直接是数组或单个组件（规范允许"裸组件根"），都已归一化进 items。
  static GenuiSpec? fromJson(Object? raw) {
    if (raw is List) {
      final items = _nodesFrom(raw);
      return items.isEmpty ? null : GenuiSpec(items: items);
    }
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    // 裸组件根：有 type 字段就当单个节点，外面的壳是可选的。
    if (map['type'] is String) {
      return GenuiSpec(items: [GenuiNode.fromJson(map)]);
    }
    final items = _nodesFrom(map['items']);
    final title = _str(map['title']);
    if (items.isEmpty && (title == null || title.isEmpty)) return null;
    return GenuiSpec(
      title: title,
      items: items,
      gap: _num(map['gap']) ?? 0,
    );
  }

  static List<GenuiNode> _nodesFrom(Object? raw) {
    if (raw is! List) return const [];
    final out = <GenuiNode>[];
    for (final entry in raw) {
      if (entry is Map) out.add(GenuiNode.fromJson(Map<String, dynamic>.from(entry)));
    }
    return out;
  }
}

/// 规格树里的一个节点。
class GenuiNode {
  const GenuiNode(this.type, this.data);

  /// 组件类型。白名单由渲染器把关，这里只做"是不是字符串"的判断 ——
  /// 未知类型要能被渲染成"不支持"的占位，而不是被解析层直接丢掉。
  final String type;

  /// 归一化后的原始字段。渲染器按 type 取字段，不做二次解析。
  final Map<String, dynamic> data;

  factory GenuiNode.fromJson(Map<String, dynamic> json) {
    final type = _str(json['type']) ?? '';
    return GenuiNode(type, json);
  }

  /// 字符串字段。非字符串返回 null（不 toString 一个 Map 假装是文本）。
  String? str(String key) => _str(data[key]);

  /// 语言/标签类字段：空串与缺失都返回 null，让调用方能区分"没写"与"写了空的"。
  String? nonEmpty(String key) {
    final v = _str(data[key]);
    return (v == null || v.isEmpty) ? null : v;
  }

  double? num_(String key) => _num(data[key]);

  bool? bool_(String key) {
    final v = data[key];
    return v is bool ? v : null;
  }

  List<dynamic> list(String key) {
    final v = data[key];
    return v is List ? v : const [];
  }

  Map<String, dynamic>? map(String key) {
    final v = data[key];
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }

  /// 行内富文本字段的通用读取：`title` 优先，再退到规范里那几种别名。
  String? textAny(List<String> keys) {
    for (final k in keys) {
      final v = _str(data[k]);
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }
}

/// 把一条消息正文切成 markdown 段与 GenUI 规格段。
///
/// 只认 **info string 里含 `dsh-ui` 词**的围栏（`dsh-ui` 与 `json dsh-ui` 两种写法
/// 都是规范里出现过的），其余围栏原样留在 markdown 里。
List<GenuiSegment> parseGenuiSegments(String markdown) {
  if (markdown.isEmpty) return const [MarkdownSegment('')];
  // 快路径：不含 "dsh-ui" 的消息不可能有这类围栏。这条判断省掉逐行扫描 ——
  // 绝大多数消息走的就是这里，而 streaming 期间每帧都会重新解析一次。
  if (!markdown.contains('dsh-ui')) return [MarkdownSegment(markdown)];
  final lines = markdown.split('\n');
  final out = <GenuiSegment>[];
  final buffer = <String>[];

  void flush() {
    if (buffer.isEmpty) return;
    out.add(MarkdownSegment(buffer.join('\n')));
    buffer.clear();
  }

  // 围栏起始：行首最多 3 空格缩进 + 3 个以上反引号 + info string
  final openRe = RegExp(r'^[ \t]{0,3}(`{3,})(.*)$');
  var i = 0;
  while (i < lines.length) {
    final m = openRe.firstMatch(lines[i]);
    final info = m?.group(2)?.trim() ?? '';
    final isGenui = m != null &&
        info.split(RegExp(r'\s+')).any((t) => t.toLowerCase() == 'dsh-ui');
    if (!isGenui) {
      buffer.add(lines[i]);
      i++;
      continue;
    }

    // 找到同类型的闭合围栏（同字符、长度不短于起始围栏）。
    // [fix 2026-10-28] CommonMark 语义：闭合围栏**不短于**起始即可（``` 开、
    // ```` 关合法）。旧正则用 RegExp.escape(fence) 要求严格等长——比开栏长的
    // 闭栏匹配不上，整段被误判未闭合降级成裸 JSON 代码块（组件消失）。与
    // safe_markdown.dart 的 {fenceLen,} 写法对齐。
    final fence = m.group(1)!;
    final closeRe =
        RegExp('^[ \\t]{0,3}`{${fence.length},}[ \t]*\$');
    var j = i + 1;
    while (j < lines.length && !closeRe.hasMatch(lines[j])) {
      j++;
    }
    if (j >= lines.length) {
      // 没有闭合围栏（多半是流式输出到一半）——原样留在 markdown 里，
      // 等这一帧之后的增量把它补全。
      buffer.addAll(lines.sublist(i));
      break;
    }

    final body = lines.sublist(i + 1, j).join('\n');
    final spec = _tryParseSpec(body);
    if (spec != null) {
      flush();
      out.add(GenuiSpecSegment(spec));
    } else {
      // 解析失败：连围栏一起原样保留 → markdown 渲染成代码块。
      // 与 Web 端"静默降级为代码块"的行为一致。
      buffer.addAll(lines.sublist(i, j + 1));
    }
    i = j + 1;
  }
  flush();
  if (out.isEmpty) out.add(MarkdownSegment(markdown));
  return out;
}

GenuiSpec? _tryParseSpec(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;
  Object? decoded;
  try {
    decoded = _jsonDecodeLenient(trimmed);
  } catch (_) {
    return null; // 交给调用方降级成代码块
  }
  return GenuiSpec.fromJson(decoded);
}

/// JSON 解析：先严格，再容忍"尾随逗号"这一类标点级小错。
///
/// 为什么容忍这一种：模型输出长表格时最容易多打一个逗号，而 Web 端插件也会修
/// 这一类错误；手机端若直接降级成代码块，用户看到的就是一坨 JSON 而不是表格。
/// 只修标点，**不修结构错**（缺括号一律降级）—— 与 Web 端"围栏解析失败就退化成
/// 代码块"的语义保持一致。
Object? _jsonDecodeLenient(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    // ⚠️ 必须用 replaceAllMapped：Dart 的 `String.replaceAll` **不**解析 `$1`
    // 这类分组引用，会把字面量 "$1" 插进去，修复后的串更坏。
    final repaired = text.replaceAllMapped(RegExp(r',(\s*[}\]])'), (m) => m.group(1)!);
    if (repaired == text) rethrow;
    return jsonDecode(repaired);
  }
}

String? _str(Object? v) => v is String ? v : null;

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}
