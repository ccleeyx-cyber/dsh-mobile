import 'dart:convert';

/// 一条提示词模板（quick reply）。
///
/// 服务端持久化在 `~/.dsh/mobile-access/snippets.json`（最多 50 条）。
/// 客户端只持有内存副本，不本地另存一份 —— 两个来源必然漂移。
class Snippet {
  final String id;
  final String label;
  final String text;

  const Snippet({required this.id, required this.label, required this.text});

  Snippet copyWith({String? id, String? label, String? text}) => Snippet(
        id: id ?? this.id,
        label: label ?? this.label,
        text: text ?? this.text,
      );

  factory Snippet.fromJson(Map<String, dynamic> json) => Snippet(
        id: json['id']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        text: json['text']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'text': text};
}

/// 跨会话搜索命中（GET /api/mobile/sessions/search?q=）。
class SessionSearchHit {
  final String workspaceId;
  final String workspaceTitle;
  final String sessionId;
  final String title;
  final String firstPrompt;
  final int lastPromptAt;
  final bool archived;

  const SessionSearchHit({
    required this.workspaceId,
    required this.workspaceTitle,
    required this.sessionId,
    required this.title,
    this.firstPrompt = '',
    this.lastPromptAt = 0,
    this.archived = false,
  });

  factory SessionSearchHit.fromJson(Map<String, dynamic> json) =>
      SessionSearchHit(
        workspaceId: json['workspaceId']?.toString() ?? '',
        workspaceTitle: json['workspaceTitle']?.toString() ?? '',
        sessionId: json['sessionId']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        firstPrompt: json['firstPrompt']?.toString() ?? '',
        lastPromptAt: json['lastPromptAt'] is int ? json['lastPromptAt'] as int : 0,
        archived: json['archived'] == true || json['archived'] == 'true',
      );
}

/// 最近一次回合的结束原因（网关 session 历史里的 `lastTurn`）。
///
/// 引擎没有独立的"回合出错"事件：失败信息只存在于 `turn/end.reason` 里，
/// 网关把它翻译成这个结构。手机据此在会话里显示"上一轮以错误结束：…"，
/// 而不是让上次的失败悄悄消失、或永远停在"运行中"。
class TurnEndInfo {
  /// completed / error / aborted / blocked / max-tokens / interrupted / forked
  final String kind;

  /// 可直接展示的中文说明（正常结束时为空串）。
  final String text;
  final String code;
  final bool failed;
  final int time;

  /// 这是第几轮（引擎的 turn 号），用于判定"是不是最新那一轮"。
  final int? turn;

  const TurnEndInfo({
    required this.kind,
    this.text = '',
    this.code = '',
    this.failed = false,
    this.time = 0,
    this.turn,
  });

  static TurnEndInfo? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final kind = raw['kind']?.toString();
    if (kind == null || kind.isEmpty) return null;
    return TurnEndInfo(
      kind: kind,
      text: raw['text']?.toString() ?? '',
      code: raw['code']?.toString() ?? '',
      failed: raw['failed'] == true || raw['failed'] == 'true',
      time: raw['time'] is int ? raw['time'] as int : 0,
      turn: raw['turn'] is int ? raw['turn'] as int : null,
    );
  }
}

/// 简单的 JSON 解析助手（与项目其它 model 的容错风格一致）。
Map<String, dynamic>? parseJsonObject(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  return null;
}
