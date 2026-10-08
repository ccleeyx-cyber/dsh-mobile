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

  static final Random _rng = Random();

  /// A short, collision-resistant id. Uniqueness only has to hold within one
  /// device's saved list, and these are created by deliberate user actions.
  static String newId() =>
      'gw-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_rng.nextInt(0xFFFFFF).toRadixString(36)}';

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
