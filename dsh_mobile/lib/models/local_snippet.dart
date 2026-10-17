// 本地「快捷指令」（Phase 5.4）：存在手机上的、不经过网关的提示词模板。
//
// 为什么不能直接复用 [Snippet]（`models/gateway_features.dart`）：
//
// 那一个是**网关侧**的一等公民：服务端持久化在 `~/.dsh/mobile-access/snippets.json`，
// 手机只持有内存副本，删/改都发一次 HTTP 请求。本文件这个类型反过来 —— 它只活在
// 本机（`StorageService.loadLocalSnippets`），离线可用、不需要网关认证、也不会因为
// 换网关而消失。
//
// 两者刻意**不同步**：同名的两条在两个来源里各自演化，不会互相覆盖。合并展示时
// 由界面决定顺序（本地的排前面）与可编辑性（网关的只读），模型层不掺和这件事。
//
// ## `{param}` 占位符
//
// 语法只有一个规则：`{名字}`，名字由字母/数字/下划线/连字符/点/中日韩字符组成，
// 长度 1~24。解析与替换都走 [placeholderNames] / [render]，两处共用同一个正则 ——
// 否则"识别出 3 个参数、替换时只换了 2 个"这种漂移没人会发现。
//
// **留空 = 原样保留 `{名字}`**，不是替换成空串：静默删掉用户没填的那一段，比把
// 占位符摆在他眼前更糟（他还会以为模板本身就是空的）。

import 'dart:convert';

/// 一条快捷指令（本地）。
class LocalSnippet {
  const LocalSnippet({
    required this.id,
    required this.label,
    required this.text,
    this.tag = '',
  });

  /// 稳定身份键。由调用方在创建时给出（`local_<微妙时间戳>`）；从磁盘读回时若
  /// 缺失会就地补一个（见 `StorageService.loadLocalSnippets`），保证列表里
  /// 编辑/删除/排序都有可用的键。
  final String id;

  /// 显示名。空串表示"没有起名"，界面回落到正文首行。
  final String label;

  /// 模板正文。可以多行。
  final String text;

  /// 可选分类标签（「翻译」「代码」「写作」这类），空串表示未分类。
  final String tag;

  LocalSnippet copyWith(
          {String? id, String? label, String? text, String? tag}) =>
      LocalSnippet(
        id: id ?? this.id,
        label: label ?? this.label,
        text: text ?? this.text,
        tag: tag ?? this.tag,
      );

  /// 从持久化的 JSON 对象恢复。
  ///
  /// 缺字段一律按空串：旧版本/手改过的数据不能因为少一个键就整条丢掉，更不能让
  /// 整个列表解析失败（那会把用户已有的指令全清空）。
  factory LocalSnippet.fromJson(Map<String, dynamic> json) => LocalSnippet(
        id: (json['id'] ?? '').toString().trim(),
        label: (json['label'] ?? '').toString(),
        text: (json['text'] ?? '').toString(),
        tag: (json['tag'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'text': text,
        'tag': tag,
      };

  /// 序列化成一行，用于界面上的「存储形态」自检与测试断言。
  String toJsonString() => jsonEncode(toJson());

  /// 正文里出现的占位符名字，按首次出现顺序去重。
  List<String> get placeholders => placeholderNames(text);

  /// 占位符语法。名字字符集刻意收窄（不含空格与括号），这样 `{ "a": 1 }` 这种
  /// 代码片段里的花括号不会被误判成参数；`{1,2}` 也不会（逗号不在字符集里）。
  ///
  /// 中日韩范围显式写出来而不是用 `\w`：Dart 的 RegExp 在未开 unicode 标志时
  /// `\w` 只匹配 ASCII，中文参数名会被漏掉。
  static final RegExp placeholderPattern =
      RegExp(r'\{([A-Za-z0-9_.\-\u4e00-\u9fa5]{1,24})\}');

  /// 提取占位符名字（去重、保序）。
  static List<String> placeholderNames(String template) {
    final seen = <String>{};
    final out = <String>[];
    for (final m in placeholderPattern.allMatches(template)) {
      final name = (m.group(1) ?? '').trim();
      if (name.isEmpty) continue;
      if (seen.add(name)) out.add(name);
    }
    return out;
  }

  /// 用 [values] 替换模板里的 `{名字}`。
  ///
  /// 缺失或留空的参数**原样保留**占位符 —— 这不是"没替换成功"，而是刻意的：
  /// 用户还能在输入框里补，界面上的预览也是同一份结果（见
  /// `views/widgets/snippet_param_dialog.dart`）。
  static String render(String template, Map<String, String> values) {
    return template.replaceAllMapped(placeholderPattern, (m) {
      final name = (m.group(1) ?? '').trim();
      final value = values[name];
      if (value == null || value.isEmpty) return m.group(0) ?? '';
      return value;
    });
  }

  /// 没起名时的回落标签：正文第一行前 12 个字。
  static String autoLabel(String text) {
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      return t.length <= 12 ? t : '${t.substring(0, 12)}…';
    }
    return '未命名指令';
  }
}
