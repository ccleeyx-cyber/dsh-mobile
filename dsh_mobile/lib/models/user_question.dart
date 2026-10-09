/// Data model for the `user-questions/request` waterfall (patch 0003).
///
/// Shapes mirror the engine's `AskUserQuestionRequestEvent` exactly — see
/// `@deepseek-ai/dsh-user-questions/lib/types/types.d.ts`. That file is the
/// contract, so every field here has a counterpart there and nothing is invented.
///
/// The encoding is load-bearing in one direction: the answer is sent as
/// `{answers: [{id, selected[], custom?}]}` and the engine rejects anything
/// else, so `toAnswerJson` must not be "improved" later.
library;

class AskUserQuestionOption {
  final String label;
  final String? description;

  const AskUserQuestionOption({required this.label, this.description});

  factory AskUserQuestionOption.fromJson(Map<String, dynamic> json) {
    final label = json['label'];
    // An option with no label is unselectable by definition: the engine's
    // validator requires a label, and a plan-review `intent.approve` that names
    // no option is rejected upstream. Keep it out rather than render a blank.
    if (label is! String || label.isEmpty) {
      throw const FormatException('AskUserQuestionOption 缺少 label');
    }
    final desc = json['description'];
    return AskUserQuestionOption(label: label, description: desc is String ? desc : null);
  }

  Map<String, dynamic> toJson() => {
        'label': label,
        if (description != null) 'description': description,
      };
}

class AskUserQuestionIntent {
  /// Only 'plan-review' exists today, but the field is open-ended by design:
  /// the engine documents that a UI which does not know a tag renders the
  /// generic flow and the answer encoding is identical either way.
  final String kind;

  /// The option label that APPROVES. Named rather than positional so no UI
  /// infers the verdict from option order.
  final String approve;

  const AskUserQuestionIntent({required this.kind, required this.approve});

  factory AskUserQuestionIntent.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    final approve = json['approve'];
    if (kind is! String || approve is! String || approve.isEmpty) return _reject();
    return AskUserQuestionIntent(kind: kind, approve: approve);
  }

  Map<String, dynamic> toJson() => {'kind': kind, 'approve': approve};

  /// Throwing rather than returning a half-built object: a plan-review whose
  /// `approve` label is missing would otherwise be rendered as a generic
  /// question, and the user could pick an "approve"-looking option that the
  /// engine then treats as a decline.
  static AskUserQuestionIntent _reject() =>
      throw const FormatException('AskUserQuestionIntent 缺少 kind/approve');
}

class AskUserQuestionItem {
  final String id;
  final String question;
  final String? detail;
  final String? header;
  final List<AskUserQuestionOption> options;

  /// Defaults to single-select, matching the engine.
  final bool multiSelect;
  final AskUserQuestionIntent? intent;

  const AskUserQuestionItem({
    required this.id,
    required this.question,
    this.detail,
    this.header,
    this.options = const [],
    this.multiSelect = false,
    this.intent,
  });

  factory AskUserQuestionItem.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final question = json['question'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('AskUserQuestionItem 缺少 id');
    }
    if (question is! String || question.isEmpty) {
      throw FormatException('AskUserQuestionItem $id 缺少 question');
    }

    final rawOptions = json['options'];
    final options = <AskUserQuestionOption>[];
    if (rawOptions is List) {
      for (final o in rawOptions) {
        if (o is Map<String, dynamic>) {
          options.add(AskUserQuestionOption.fromJson(o));
        }
      }
    }

    final rawIntent = json['intent'];
    return AskUserQuestionItem(
      id: id,
      question: question,
      detail: json['detail'] is String ? json['detail'] as String : null,
      header: json['header'] is String ? json['header'] as String : null,
      options: options,
      multiSelect: json['multiSelect'] == true,
      intent: (rawIntent is Map<String, dynamic>) ? AskUserQuestionIntent.fromJson(rawIntent) : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'question': question,
        if (detail != null) 'detail': detail,
        if (header != null) 'header': header,
        'options': options.map((o) => o.toJson()).toList(),
        'multiSelect': multiSelect,
        if (intent != null) 'intent': intent!.toJson(),
      };

  /// True when this is a plan review and `label` is the approving choice.
  bool approvesWith(String label) => intent?.approve == label;

  /// Whether the question declares an approving option at all. The engine
  /// rejects a `plan-review` intent whose `approve` names none of its options,
  /// so if that ever arrives the UI must not fake an approve button.
  bool get hasApproveOption =>
      intent == null || intent!.approve.isEmpty || options.any((o) => o.label == intent!.approve);
}

/// One pending `user-questions/request` as offered to this phone.
class PendingQuestion {
  final String eventId;
  final String sessionId;
  final List<AskUserQuestionItem> questions;
  final DateTime createdAt;

  const PendingQuestion({
    required this.eventId,
    required this.sessionId,
    required this.questions,
    required this.createdAt,
  });

  factory PendingQuestion.fromJson(Map<String, dynamic> json) {
    final eventId = json['eventId'];
    final rawQuestions = json['questions'];
    if (eventId is! String || eventId.isEmpty) {
      throw const FormatException('PendingQuestion 缺少 eventId');
    }
    if (rawQuestions is! List || rawQuestions.isEmpty) {
      // The engine guarantees at least one question; an empty batch means the
      // frame is malformed and answering it would be meaningless.
      throw const FormatException('PendingQuestion 缺少 questions');
    }
    final items = <AskUserQuestionItem>[];
    for (final q in rawQuestions) {
      if (q is Map<String, dynamic>) items.add(AskUserQuestionItem.fromJson(q));
    }
    if (items.isEmpty) throw const FormatException('PendingQuestion questions 全部无法解析');
    return PendingQuestion(
      eventId: eventId,
      sessionId: json['sessionId']?.toString() ?? 'default',
      questions: items,
      createdAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'eventId': eventId,
        'sessionId': sessionId,
        'questions': questions.map((q) => q.toJson()).toList(),
      };
}

/// One answered question inside a batch.
class AskUserQuestionAnswerItem {
  final String id;
  final List<String> selected;
  final String custom;

  const AskUserQuestionAnswerItem({required this.id, required this.selected, this.custom = ''});

  /// Empty `selected` with empty `custom` is NOT a valid answer for this
  /// question — the web client refuses to submit in that state, and doing so
  /// would tell the agent the user skipped without saying why.
  bool get isAnswered => selected.isNotEmpty || custom.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'selected': selected,
        if (custom.trim().isNotEmpty) 'custom': custom.trim(),
      };
}

/// A whole answer batch. This object is exactly what becomes
/// `outcome.value` in `$events/result`, so its shape must not drift.
class AskUserQuestionAnswer {
  final List<AskUserQuestionAnswerItem> answers;

  const AskUserQuestionAnswer(this.answers);

  Map<String, dynamic> toJson() => {
        'answers': answers.map((a) => a.toJson()).toList(),
      };
}

/// A `todo/write` snapshot: whole-list replacement, never a delta.
class TodoItem {
  /// Engine values are exactly pending | in_progress | completed.
  final String status;
  final String content;

  const TodoItem({required this.status, required this.content});

  factory TodoItem.fromJson(Map<String, dynamic> json) {
    final content = json['content'];
    final status = json['status'];
    if (content is! String || content.isEmpty) {
      throw const FormatException('TodoItem 缺少 content');
    }
    // Only the three engine-defined values are recognised; anything else falls
    // back to `pending`. Storing an unknown status would render as a state the
    // UI has no icon for, and the TODO list is progress information — showing a
    // row as "neither done nor active" is the safe reading, not a crash.
    final normalized =
        (status == inProgress || status == completed) ? status : pending;
    return TodoItem(status: normalized, content: content);
  }

  Map<String, dynamic> toJson() => {'content': content, 'status': status};

  static const String pending = 'pending';
  static const String inProgress = 'in_progress';
  static const String completed = 'completed';

  bool get isDone => status == completed;
  bool get isActive => status == inProgress;
}

/// An image/attachment notification. Metadata only — the bytes are fetched
/// through the authenticated attachment route, never inlined.
class AttachmentRef {
  final String id;
  final String mimeType;
  final int? width;
  final int? height;
  final int? byteSize;
  final String? filename;

  const AttachmentRef({
    required this.id,
    required this.mimeType,
    this.width,
    this.height,
    this.byteSize,
    this.filename,
  });

  factory AttachmentRef.fromJson(Map<String, dynamic> json) {
    final id = json['id'] ?? json['attachmentId'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('AttachmentRef 缺少 id');
    }
    int? asInt(dynamic v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}'));
    return AttachmentRef(
      id: id,
      mimeType: json['mimeType']?.toString() ?? 'application/octet-stream',
      width: asInt(json['width']),
      height: asInt(json['height']),
      byteSize: asInt(json['bytes'] ?? json['byteSize'] ?? json['size']),
      filename: json['filename']?.toString(),
    );
  }

  bool get isImage => mimeType.startsWith('image/');
}