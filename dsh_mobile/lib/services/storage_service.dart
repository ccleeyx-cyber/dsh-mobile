import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/server_config.dart';

/// Persistence for the active gateway plus the list of saved gateways.
///
/// SharedPreferences layout:
///   `dsh_server_config`      the ACTIVE gateway. Same key as before multi-gateway
///                            support existed, so an upgrade keeps working and
///                            `main.dart`'s startup path is unchanged.
///   `dsh_server_profiles`    JSON array of every saved gateway.
///   `dsh_active_profile_id`  which entry of the array is active.
///
/// An install that predates the profile list has only `dsh_server_config`;
/// [loadProfiles] promotes that single config into the first profile on demand,
/// so the switcher is never empty and nothing has to be re-entered.
class StorageService {
  static const String _keyConfig = 'dsh_server_config';
  static const String _keyProfiles = 'dsh_server_profiles';
  static const String _keyActiveId = 'dsh_active_profile_id';

  /// Theme preference: 'system' | 'light' | 'dark' (v1.6.0).
  ///
  /// Stored as a plain string rather than an index so reordering the enum later
  /// cannot silently reinterpret an existing user's choice.
  static const String _keyThemeMode = 'dsh_theme_mode';

  static Future<String> loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_keyThemeMode);
    // Anything unrecognised falls back to 'system' rather than throwing: a bad
    // value must never block startup.
    return (v == 'light' || v == 'dark') ? v! : 'system';
  }

  static Future<void> saveThemeMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyThemeMode, mode);
  }

  /// 已被用户关掉"本轮以错误结束"横幅的会话 id 集合（v1.11.3）。
  ///
  /// 为什么要持久化：横幅读的是历史里的 lastTurn，只要那一轮仍是最后一轮，
  /// 每次打开会话都会重新判定为失败 —— 用户关掉之后重启 App 又弹一遍，就是
  /// "每次都弹过期信息"。关掉即记账，直到该会话有新的一轮结束才清账。
  static const String _keyDismissedFailures = 'dsh_dismissed_turn_failures';
  static const int _maxDismissedFailures = 100;

  static Future<List<String>> loadDismissedTurnFailures() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_keyDismissedFailures) ?? const [];
  }

  static Future<void> saveDismissedTurnFailures(List<String> sessionIds) async {
    final prefs = await SharedPreferences.getInstance();
    final capped = sessionIds.length > _maxDismissedFailures
        ? sessionIds.sublist(sessionIds.length - _maxDismissedFailures)
        : sessionIds;
    await prefs.setStringList(_keyDismissedFailures, capped);
  }

  static final Random _rng = Random.secure();

  // v1.14 删除了「运行中投递方式」的持久化（原 `dsh_delivery_mode` 键）。
  //
  // 它当初是"记住这台手机习惯排队还是插话"，但一个能被记住的开关会让"默认"
  // 在下次变成插话 —— 用户不会记得它停在哪一格，一次没注意就插了正在跑的活。
  // 现在运行中发送恒为排队（`mode:'queue'`），插话只能靠在队列条目上再确认一次。
  // 落盘的旧值不再被读取，因此不做迁移清理（写清理代码是净增代码、无收益）。

  /// Guarantees uniqueness **by construction**, not by luck.
  ///
  /// The earlier form was `'gw-' + microsecondsSinceEpoch + '-' + nextInt(0xFFFFFF)`.
  /// That is probabilistic: inside `flutter test` the wall clock is effectively
  /// frozen, so a tight loop of newId() calls produces many ids sharing the same
  /// timestamp component and depends entirely on the RNG for the rest. The
  /// "no collision across 2000 ids" test failed intermittently because of it —
  /// a real (if rare) defect, not just a flaky test.
  ///
  /// A monotonic counter makes it impossible: two calls in the same process
  /// always differ in the counter. Randomness is still there so ids created in
  /// different processes/after reinstall don't look sequential.
  static int _idSeq = 0;

  static String newId() {
    final seq = _idSeq++;
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'gw-$stamp-${seq.toRadixString(36)}${_rng.nextInt(0xFFFF).toRadixString(36)}';
  }

  // ---------------------------------------------------------------- active --

  /// Persists [config] as the active gateway and keeps the saved list in step.
  ///
  /// If [config] has no id yet one is assigned to it in place, so the caller can
  /// read back the identity of what was just saved.
  static Future<void> saveConfig(ServerConfig config) async {
    if (config.id.isEmpty) config.id = newId();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyConfig, jsonEncode(config.toJson()));
    await prefs.setString(_keyActiveId, config.id);
    await upsertProfile(config);
  }

  static Future<ServerConfig?> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_keyConfig);
    if (jsonStr == null || jsonStr.isEmpty) return null;
    try {
      return ServerConfig.fromJson(jsonDecode(jsonStr));
    } catch (_) {
      return null;
    }
  }

  static Future<String?> activeProfileId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_keyActiveId);
    return (id == null || id.isEmpty) ? null : id;
  }

  // --------------------------------------------------------------- profiles --

  /// Every saved gateway, oldest first. Migrates a pre-profile install.
  static Future<List<ServerConfig>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <ServerConfig>[];

    final raw = prefs.getString(_keyProfiles);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) {
              final c = ServerConfig.fromJson(Map<String, dynamic>.from(e));
              if (c.id.isEmpty) c.id = newId();
              out.add(c);
            }
          }
        }
      } catch (_) {
        // A corrupt list must not wedge the config page; fall through to the
        // migration path, which rebuilds one entry from the active config.
        out.clear();
      }
    }
    if (out.isNotEmpty) return out;

    final legacy = await loadConfig();
    if (legacy != null) {
      if (legacy.id.isEmpty) legacy.id = newId();
      if (legacy.name.trim().isEmpty) legacy.name = legacy.displayName;
      out.add(legacy);
      await saveProfiles(out);
      await prefs.setString(_keyActiveId, legacy.id);
    }
    return out;
  }

  static Future<void> saveProfiles(List<ServerConfig> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyProfiles,
      jsonEncode(profiles.map((p) => p.toJson()).toList()),
    );
  }

  /// Inserts or replaces by id. Assigns an id to [config] in place if it has
  /// none, and returns the new list so the caller can refresh its state.
  static Future<List<ServerConfig>> upsertProfile(ServerConfig config) async {
    if (config.id.isEmpty) config.id = newId();
    final profiles = await loadProfiles();
    final i = profiles.indexWhere((p) => p.id == config.id);
    if (i >= 0) {
      profiles[i] = config;
    } else {
      profiles.add(config);
    }
    await saveProfiles(profiles);
    return profiles;
  }

  static Future<List<ServerConfig>> deleteProfile(String id) async {
    final profiles = await loadProfiles();
    profiles.removeWhere((p) => p.id == id);
    await saveProfiles(profiles);
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_keyActiveId) == id) await prefs.remove(_keyActiveId);
    return profiles;
  }

  static Future<List<ServerConfig>> renameProfile(String id, String name) async {
    final profiles = await loadProfiles();
    final i = profiles.indexWhere((p) => p.id == id);
    if (i < 0) return profiles;
    profiles[i].name = name.trim();
    await saveProfiles(profiles);
    final prefs = await SharedPreferences.getInstance();
    // Keep the active copy in step, otherwise the next launch loads a gateway
    // whose label no longer matches the list entry it came from.
    if (prefs.getString(_keyActiveId) == id) {
      await prefs.setString(_keyConfig, jsonEncode(profiles[i].toJson()));
    }
    return profiles;
  }

  /// Marks [id] active and mirrors it into `dsh_server_config`, which is what
  /// `main.dart` reads at startup. Returns null when the id is unknown.
  static Future<ServerConfig?> setActiveProfile(String id) async {
    final profiles = await loadProfiles();
    final i = profiles.indexWhere((p) => p.id == id);
    if (i < 0) return null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyActiveId, id);
    await prefs.setString(_keyConfig, jsonEncode(profiles[i].toJson()));
    return profiles[i];
  }
}
