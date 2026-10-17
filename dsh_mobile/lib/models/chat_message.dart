import 'dart:convert';
import 'dart:typed_data';

import 'harness_notice.dart';
import 'user_question.dart' show AttachmentRef;

class ToolExecution {
  final String name;
  final String input;
  String output;
  bool isRunning;

  ToolExecution({
    required this.name,
    dynamic input = '',
    dynamic output = '',
    this.isRunning = true,
  })  : input = _safeFormat(input),
        output = _safeFormat(output);

  static String _safeFormat(dynamic val) {
    if (val == null) return '';
    if (val is String) return val;
    if (val is Map || val is List) {
      try {
        return const JsonEncoder.withIndent('  ').convert(val);
      } catch (_) {
        return val.toString();
      }
    }
    return val.toString();
  }
}

class ChatMessage {
  final String id;
  final String role; // 'user', 'assistant', 'system', 'memory', 'context'
  String content;
  String? thinking; // 深度思考/思维链内容
  List<ToolExecution> tools;
  bool get isStreaming => _isStreaming;

  /// 写入时先 flush 累积槽。
  ///
  /// 流式增量先进 buffer（见 [appendStreamDelta]），靠这个 setter 保证
  /// 「streaming 结束」的所有路径 —— done / error / 取消 / 轮询超时兜底 /
  /// reconcile / stream_snapshot replay —— 都会把最后一段增量写回成品字段。
  /// 少了这一步，取消或弱网兜底时最后 100ms 内的内容会凭空消失。
  set isStreaming(bool value) {
    if (_isStreaming == value) return;
    _isStreaming = value;
    if (!value) flushStreamBuffers();
  }
  bool _isStreaming = false;
  final DateTime timestamp;
  final bool isMemory;
  final bool isContext;

  /// [feat 2026-10-12] 引擎事件序号：反向翻页的 beforeSeq 游标 + 与实时流
  /// 去重的身份键。网关从 1.14.x 起在历史消息上带 seq；本地乐观消息和旧网关
  /// 没有时为 null（这类消息不参与翻页与去重，只留在尾部）。
  final int? seq;

  /// [feat 2026-10-17] 引擎注入的通知语义（见 [HarnessNotice]）。
  ///
  /// 网关标了就用网关的（权威：它能读到事件上的 `source`），没标就按锚定文案兜底。
  /// 用 `late final` 是为了**只判定一次** —— 四个字段出自同一个判定结果，写成四个
  /// initializer 表达式会把同一段正则跑四遍。
  late final String? noticeKind;
  late final String? noticeVariant;
  late final String? noticeChildId;
  late final String? noticeBody;

  /// [feat 2026-10-17] 这一轮消耗的 token 数（**引擎的权威读数**）。
  ///
  /// 引擎每个 step 的 `assistant/message` 都带 `usage`，网关把它汇总到该轮的那条
  /// user 消息上。以前只能靠"回合起止两次 stats 读数相减"算，基线一旦没记到
  /// （切会话、冷启动到一个正在跑的会话、轮末 App 不在前台）就永远显示 `—`。
  ///
  /// 只有**已结束**的轮才有值；回合还在跑时是 null（部分和会被读成"这轮就花了这么多"）。
  final int? turnTokens;

  /// [feat 2026-10-17] 这条消息带的附件（图片 / 文件）。
  ///
  /// 引擎的 `user/message` 里附件是独立 content part
  /// （`{type:'image'|'file', attachment:{attachmentId, mediaType, width, height, bytes, name}}`），
  /// 而网关以前只把 `text` part 拼进正文 —— 于是手机发出去的图**在历史里彻底消失**
  /// （Web 端读原始事件所以有）。现在网关把它映射成这个字段，手机照常按需拉字节。
  final List<AttachmentRef> attachments;

  /// 本地即时预览用的图片字节（**只存在于本机乐观消息上，服务端回包不带**）。
  ///
  /// 用户刚发出去的那张图，字节就在自己手里，没有理由等 2~3 秒的轮询回包才显示；
  /// 服务端版本到达后这条乐观消息会被替换掉，预览也随之让位给真附件。
  final List<Uint8List> localImagePreviews;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.thinking,
    List<ToolExecution>? tools,
    bool isStreaming = false,
    DateTime? timestamp,
    this.isMemory = false,
    this.isContext = false,
    this.seq,
    String? noticeKind,
    String? noticeVariant,
    String? noticeChildId,
    String? noticeBody,
    this.turnTokens,
    List<dynamic>? attachments,
    List<Uint8List>? localImagePreviews,
  })  : tools = tools ?? [],
        timestamp = timestamp ?? DateTime.now(),
        attachments = _parseAttachments(attachments),
        localImagePreviews = localImagePreviews ?? const <Uint8List>[],
        _isStreaming = isStreaming {
    final notice = HarnessNotice.resolve(
      kind: noticeKind,
      variant: noticeVariant,
      childId: noticeChildId,
      body: noticeBody,
      content: content,
      // 只有 user 角色、且不是上下文/记忆块的消息才可能是注入通知。
      mayBeNotice: role == 'user' && !isMemory && !isContext,
    );
    this.noticeKind = notice?.kind;
    this.noticeVariant = notice?.variant;
    this.noticeChildId = notice?.childId;
    this.noticeBody = notice?.body;
  }

  /// 这条消息是引擎注入的通知 —— 它 `role` 是 `user`，但没人打过这些字。
  ///
  /// 渲染层必须**先**判它再判 [isUser]，否则子代理结算通知会显示成"你说的话"。
  bool get isHarnessNotice => noticeKind != null;

  /// 通知语义；不是通知时为 null。
  HarnessNotice? get notice => isHarnessNotice
      ? HarnessNotice(
          kind: noticeKind!,
          variant: noticeVariant,
          childId: noticeChildId,
          body: noticeBody,
        )
      : null;

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isSystem => role == 'system';
  bool get isContextRole => role == 'context';
  bool get isMemoryRole => role == 'memory';

  /// 流式增量累积槽。`content` / `thinking` 是渲染层读的**成品**字段，
  /// 但增量到达时不能直接 `content += text` —— Dart 的 String 不可变，
  /// 每次拼接都整体拷贝一次，一条 20 万字符的回复按 4 字符一片进来就是
  /// O(n²) 次拷贝（实测长回复下流式越来越卡的主因）。
  ///
  /// 所以 delta 一律进 buffer，只在 flush 边界写回成品字段。非流式消息
  /// 永远不碰这两个 buffer。
  final StringBuffer _contentBuffer = StringBuffer();
  final StringBuffer _thinkingBuffer = StringBuffer();
  bool _buffering = false;

  /// 追加一段增量。调用方负责在合适的时机调 [flushStreamBuffers]。
  void appendStreamDelta({String? content, String? thinking}) {
    if (content != null && content.isNotEmpty) {
      _contentBuffer.write(content);
      _buffering = true;
    }
    if (thinking != null && thinking.isNotEmpty) {
      _thinkingBuffer.write(thinking);
      _buffering = true;
    }
  }

  /// 把累积槽写回 `content` / `thinking`。幂等：没有未 flush 的增量时是 no-op。
  void flushStreamBuffers() {
    if (!_buffering) return;
    if (_contentBuffer.isNotEmpty) {
      content += _contentBuffer.toString();
      _contentBuffer.clear();
    }
    if (_thinkingBuffer.isNotEmpty) {
      thinking = (thinking ?? '') + _thinkingBuffer.toString();
      _thinkingBuffer.clear();
    }
    _buffering = false;
  }

  /// Returns true if the message is a carried context, workspace document, runtime instructions, or memory snapshot
  bool get isContextOrMemory {
    if (isMemory || isContext || role == 'memory' || role == 'context' || role == 'system') {
      return true;
    }
    final trimmed = content.trim();
    if (trimmed.startsWith('MNEMON RUNTIME MEMORY SNAPSHOT') ||
        trimmed.startsWith('[MNEMON]') ||
        trimmed.contains('<runtime-memory-file') ||
        trimmed.contains('<system-reminder>') ||
        trimmed.startsWith('Current runtime context.') ||
        trimmed.contains('DSH file policy:') ||
        trimmed.contains('Instructions from:') ||
        trimmed.contains('<available_skills>') ||
        trimmed.contains('A skill is a reusable set') ||
        (trimmed.contains('Contents of ') && (trimmed.contains('.md') || trimmed.contains('<runtime-memory-file'))) ||
        RegExp(r'<(workspace|project|environment|file)_context>', caseSensitive: false).hasMatch(trimmed)) {
      return true;
    }
    return false;
  }

  bool get isMemoryRecall => isContextOrMemory;

  /// 这条消息有没有附件（图片 / 文件），或本机待展示的即时预览。
  bool get hasAttachments => attachments.isNotEmpty || localImagePreviews.isNotEmpty;

  /// 把网关给的 `attachments` 解析成 [AttachmentRef]。
  ///
  /// 单条坏数据（缺 id 等）只跳过它自己：`AttachmentRef.fromJson` 对缺失 id 会抛，
  /// 而"一条附件格式不对"不该让整条消息连正文都渲染不出来。
  static List<AttachmentRef> _parseAttachments(List<dynamic>? raw) {
    if (raw == null || raw.isEmpty) return const <AttachmentRef>[];
    final out = <AttachmentRef>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        out.add(AttachmentRef.fromJson(Map<String, dynamic>.from(item)));
      } catch (_) {
        continue;
      }
    }
    return out;
  }
}
