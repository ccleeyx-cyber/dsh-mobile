import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/server_config.dart';

class StorageService {
  static const String _keyConfig = 'dsh_server_config';

  static Future<void> saveConfig(ServerConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyConfig, jsonEncode(config.toJson()));
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
}
