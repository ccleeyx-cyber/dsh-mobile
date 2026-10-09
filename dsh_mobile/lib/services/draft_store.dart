import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Per-session input drafts that survive an app restart (v1.4.2 离线草稿).
///
/// Why this exists, concretely: on Android the OS can kill the process while the
/// app is backgrounded, so anything held only in a TextEditingController is lost
/// without warning. A half-typed instruction — often a long prompt you were
/// about to paste details into — silently disappearing is the single most
/// annoying failure mode of a chat client.
///
/// Two rules shape the design:
///
///   * **Drafts are keyed by session.** Switching sessions keeps each session's
///     own text, because "I was writing two things at once" is common. The
///     default session (no id yet) gets its own bucket so a draft typed before
///     the first session exists isn't lost.
///   * **Writing is debounced, saving is not.** Every keystroke must not hit
///     SharedPreferences (which is a platform channel round-trip). Text is held
///     in memory and flushed after a pause; a crash inside the debounce window
///     loses at most the last few characters of typing, which is acceptable,
///     whereas a synchronous write per keystroke would stutter the keyboard.
///
/// Drafts are deliberately NOT cleared on a failed send — see [DshService].
class DraftStore {
  /// Single instance.
  ///
  /// It has to be: `main()` attaches SharedPreferences to it before `runApp`,
  /// while each `DshService` reads it. If the store were per-service, main's
  /// attached instance and the service's own instance would be different objects
  /// and every draft would appear to vanish. Making it a singleton removes the
  /// wiring problem instead of papering over it.
  static final DraftStore instance = DraftStore._();

  DraftStore._();

  static const String _keyPrefix = 'dsh_draft_';
  static const Duration _flushDelay = Duration(milliseconds: 600);

  /// How many drafts to retain. Public so the eviction behaviour is pinnable by a
  /// test — an unbounded draft map on a device that syncs thousands of sessions
  /// would grow forever.
  static const int maxDrafts = 60;

  final Map<String, String> _cache = {};
  Timer? _timer;
  bool _loaded = false;

  /// Called after a debounced write completes. Lets a view show a quiet
  /// "draft saved" hint without the store depending on Flutter.
  void Function()? onFlush;

  String _storageKey(String sessionKey) => '$_keyPrefix${Uri.encodeComponent(sessionKey)}';

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    // SharedPreferences caches synchronously after getInstance, so a one-time
    // synchronous read here is fine and avoids every caller having to await.
    final prefs = _prefs;
    if (prefs == null) return;
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_keyPrefix)) continue;
      final value = prefs.getString(key);
      if (value != null && value.isNotEmpty) _cache[key] = value;
    }
  }

  SharedPreferences? _prefs;

  /// Wires the store to SharedPreferences. Called once during startup; until
  /// then the store still works in memory, so a draft typed very early is not
  /// lost — it just won't survive a kill until the first flush.
  void attach(SharedPreferences prefs) {
    _prefs = prefs;
    _cache.clear();
    _loaded = false;
    _ensureLoaded();
  }

  String read(String sessionKey) {
    _ensureLoaded();
    return _cache[_storageKey(sessionKey)] ?? '';
  }

  bool hasDraft(String sessionKey) => read(sessionKey).trim().isNotEmpty;

  void write(String sessionKey, String text) {
    _ensureLoaded();
    final key = _storageKey(sessionKey);
    if (text.isEmpty) {
      if (_cache.remove(key) != null) _scheduleFlush();
      return;
    }
    _cache[key] = text;
    _evictIfNeeded();
    _scheduleFlush();
  }

  void clear(String sessionKey) {
    _ensureLoaded();
    final key = _storageKey(sessionKey);
    if (_cache.remove(key) != null) _scheduleFlush();
  }

  /// Synchronous write for use in lifecycle callbacks. `SharedPreferences` is
  /// backed by an in-memory map that is flushed to the platform on a later
  /// microtask, so writing it synchronously here is still cheap and is the only
  /// way to get the text out before the process is killed.
  void flushNow() {
    _timer?.cancel();
    _timer = null;
    final prefs = _prefs;
    if (prefs == null) return;
    for (final entry in _cache.entries) {
      prefs.setString(entry.key, entry.value);
    }
    // Remove keys that were deleted in memory but still on disk.
    final live = _cache.keys.toSet();
    for (final key in prefs.getKeys()) {
      if (key.startsWith(_keyPrefix) && !live.contains(key)) {
        prefs.remove(key);
      }
    }
    onFlush?.call();
  }

  void _scheduleFlush() {
    _timer?.cancel();
    _timer = Timer(_flushDelay, flushNow);
  }

  void _evictIfNeeded() {
    if (_cache.length <= maxDrafts) return;
    // A Dart Map preserves insertion order, so the head of the iteration is the
    // oldest *inserted* key. Sorting the keys as strings would evict an
    // arbitrary key instead of the oldest one. Rewriting an existing key does
    // not move it to the end, so this is "oldest session", not "least recently
    // edited" — which is the right thing to protect, since a session you keep
    // typing in is by definition one you still have open.
    final keys = _cache.keys.toList();
    for (final k in keys.take(_cache.length - maxDrafts)) {
      _cache.remove(k);
    }
  }

  /// All drafts, newest last. Used by a "恢复草稿" list so a user who forgot
  /// they had a draft can find it.
  List<MapEntry<String, String>> all() {
    _ensureLoaded();
    final out = <MapEntry<String, String>>[];
    for (final e in _cache.entries) {
      final key = Uri.decodeComponent(e.key.substring(_keyPrefix.length));
      out.add(MapEntry(key, e.value));
    }
    return out;
  }

  void dispose() {
    flushNow();
    _timer?.cancel();
    _timer = null;
  }
}