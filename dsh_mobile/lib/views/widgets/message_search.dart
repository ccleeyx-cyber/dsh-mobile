import 'dart:convert';

import '../../models/chat_message.dart';

/// One hit in an in-session search.
///
/// [snippet] is the matched message with match offsets already recorded, so the
/// UI can highlight without re-running the matcher. [context] is the plain
/// text around the match for the result row.
class SearchHit {
  final int messageIndex;

  /// Index of the match inside the message's rendered text.
  final int matchStart;
  final int matchEnd;

  /// The full text the offsets refer to.
  final String text;

  /// Where the hit came from, so the UI can label it.
  final SearchField field;

  final DateTime? timestamp;

  const SearchHit({
    required this.messageIndex,
    required this.matchStart,
    required this.matchEnd,
    required this.text,
    required this.field,
    required this.timestamp,
  });

  /// A short window of text around the match, with ellipses where it was cut.
  String context({int radius = 40}) {
    if (text.length <= radius * 2) return text;
    var start = matchStart - radius;
    var end = matchEnd + radius;
    if (start < 0) {
      end -= start;
      start = 0;
    }
    if (end > text.length) {
      start -= end - text.length;
      end = text.length;
      if (start < 0) start = 0;
    }
    final prefix = start > 0 ? '…' : '';
    final suffix = end < text.length ? '…' : '';
    return '$prefix${text.substring(start, end).replaceAll('\n', ' ')}$suffix';
  }
}

enum SearchField { content, thinking, toolName, toolOutput }

/// In-session search over the loaded message list.
///
/// Deliberately a plain value object rather than a widget: the matching rules
/// are the part worth testing, and they are testable without pumping anything.
///
/// Design points that matter:
///
/// * **Tool calls are searchable.** A user remembers "the command that deleted
///   my file" far more often than "the paragraph about it", and the tool output
///   is where the answer usually is.
/// * **Thinking is searchable but rankable separately.** Chain-of-thought is
///   often the only place the reasoning is written down. A hit there is a
///   weaker signal than a hit in the assistant's answer, so it sorts below.
/// * **Every match in a message is reported, not just the first.** A message
///   containing the word five times should appear once with a count, otherwise
///   the result list becomes unusable on long messages.
class MessageSearch {
  /// Case-insensitive substring search over all searchable fields.
  static List<SearchHit> search(List<ChatMessage> messages, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final hits = <SearchHit>[];
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      hits.addAll(_inText(i, m.content, q, SearchField.content, m.timestamp));
      final thinking = m.thinking;
      if (thinking != null && thinking.isNotEmpty) {
        hits.addAll(_inText(i, thinking, q, SearchField.thinking, m.timestamp));
      }
      for (final t in m.tools) {
        hits.addAll(_inText(i, t.name, q, SearchField.toolName, m.timestamp));
        // Tool output can be a JSON blob hundreds of lines long; only search
        // what is actually rendered so a hit is always visible.
        hits.addAll(_inText(i, _visibleToolOutput(t.output), q, SearchField.toolOutput, m.timestamp));
      }
    }
    return rank(hits);
  }

  /// Tool output is stored pretty-printed JSON; the UI shows it in a scroll box.
  /// Stripping to the leaf values keeps the snippet close to what the user
  /// actually reads.
  static String _visibleToolOutput(String raw) {
    final t = raw.trim();
    if (!t.startsWith('{') && !t.startsWith('[')) return raw;
    try {
      final decoded = jsonDecode(t);
      final buf = StringBuffer();
      void walk(dynamic v) {
        if (v is Map) {
          for (final val in v.values) {
            walk(val);
          }
        } else if (v is List) {
          for (final val in v) {
            walk(val);
          }
        } else if (v != null) {
          buf.write(v);
          buf.write(' ');
        }
      }
      walk(decoded);
      return buf.toString();
    } catch (_) {
      return raw;
    }
  }

  static List<SearchHit> _inText(
    int messageIndex,
    String source,
    String lowerQuery,
    SearchField field,
    DateTime? ts,
  ) {
    if (source.isEmpty) return const [];
    final lower = source.toLowerCase();
    final out = <SearchHit>[];
    var from = 0;
    while (true) {
      final at = lower.indexOf(lowerQuery, from);
      if (at < 0) break;
      out.add(SearchHit(
        messageIndex: messageIndex,
        matchStart: at,
        matchEnd: at + lowerQuery.length,
        text: source,
        field: field,
        timestamp: ts,
      ));
      from = at + lowerQuery.length; // non-overlapping
      if (out.length >= 50) break; // one pathological message shouldn't blow up the list
    }
    return out;
  }

  /// Order: assistant/user content before thinking before tools; then newest
  /// message first within a field, because recent context is usually what the
  /// user is trying to recall.
  static List<SearchHit> rank(List<SearchHit> hits) {
    final sorted = [...hits];
    sorted.sort((a, b) {
      final fa = _fieldRank(a.field);
      final fb = _fieldRank(b.field);
      if (fa != fb) return fa - fb;
      if (a.messageIndex != b.messageIndex) return b.messageIndex.compareTo(a.messageIndex);
      return a.matchStart.compareTo(b.matchStart);
    });
    return sorted;
  }

  static int _fieldRank(SearchField f) => switch (f) {
        SearchField.content => 0,
        SearchField.thinking => 1,
        SearchField.toolName => 2,
        SearchField.toolOutput => 3,
      };

  static String fieldLabel(SearchField f) => switch (f) {
        SearchField.content => '正文',
        SearchField.thinking => '思考',
        SearchField.toolName => '工具',
        SearchField.toolOutput => '输出',
      };

  /// Collapses hits to one row per message, carrying a count.
  static List<({SearchHit first, int count})> collapse(List<SearchHit> hits) {
    final byMessage = <int, List<SearchHit>>{};
    for (final h in hits) {
      byMessage.putIfAbsent(h.messageIndex, () => []).add(h);
    }
    final out = <({SearchHit first, int count})>[];
    for (final group in byMessage.values) {
      out.add((first: group.first, count: group.length));
    }
    out.sort((a, b) => b.count.compareTo(a.count));
    return out;
  }
}