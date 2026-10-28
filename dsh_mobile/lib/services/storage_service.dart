import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/local_snippet.dart';
import '../models/server_config.dart';
import 'secure_store.dart';

/// Persistence for the active gateway plus the list of saved gateways.
///
/// SharedPreferences layout:
///   `dsh_server_config`      the ACTIVE gateway. Same key as before multi-gateway
///                            support existed, so an upgrade keeps working and
///                            `main.dart`'s startup path is unchanged.
///   `dsh_server_profiles`    JSON array of every saved gateway.
///   `dsh_active_profile_id`  which entry of the array is active.
///   `dsh_secure_*`           AndroidKeystore 密文（token / authCode）。
///
/// **敏感字段不再进默认 SharedPreferences。** `token` 与 `authCode` 是唯一
/// 「拿到就能冒充这个客户端」的凭据，而默认 SP 文件是明文 XML：adb backup、
/// root、任何能读到应用沙箱的东西都能直接拿走。所以：
///
///   * 写入：`token`/`authCode` 交给 [SecureStore]（AES/GCM + AndroidKeyStore
///     里不可导出的密钥），SP 里那份 JSON 把这两个键剥掉。
///   * 读取：从 [SecureStore] 取回来填进模型，业务代码看到的 [ServerConfig]
///     依然是完整的 —— 公开 API 一个都没变。
///   * 迁移：旧安装的明文在第一次读取时被搬进 [SecureStore]，并从 SP 里删掉。
///   * **失败不丢数据**：任何一步没成功（无原生实现、Keystore 失败、写后读回
///     校验不过），明文就留在 SP 里继续当兜底。宁可这一版没改善，也不能让用户
///     的网关凭据凭空消失 —— 那会让他连不上自己的机器。
///
/// An install that predates the profile list has only `dsh_server_config`;
/// [loadProfiles] promotes that single config into the first profile on demand,
/// so the switcher is never empty and nothing has to be re-entered.
class StorageService {
  static const String _keyConfig = 'dsh_server_config';
  static const String _keyProfiles = 'dsh_server_profiles';
  static const String _keyActiveId = 'dsh_active_profile_id';

  /// 无法归属到某个 profile id 时（旧安装还没分配 id）的密文槽位。
  static const String _activeSecretScope = 'active';

  /// Theme preference: 'system' | 'light' | 'dark' (v1.6.0).
  ///
  /// Stored as a plain string rather than an index so reordering the enum later
  /// cannot silently reinterpret an existing user's choice.
  static const String _keyThemeMode = 'dsh_theme_mode';

  /// 敏感字段名。集中在这里，避免「剥字段」和「回填字段」两处写法漂移。
  static const String _kToken = 'token';
  static const String _kAuthCode = 'authCode';

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

  // ------------------------------------------------- 本地快捷指令（v1.27）--

  /// 本地快捷指令的持久化键（Phase 5.4）。
  ///
  /// **存储键**：`dsh_local_snippets`，值是一个 JSON 数组，每个元素形如
  /// `{"id":"local_...","label":"翻译","text":"把下面这段翻成{lang}：","tag":"翻译"}`。
  ///
  /// 为什么是独立的一个键、而不是塞进 `dsh_server_config`：
  ///
  ///   * 快捷指令是**本机**的东西，删掉/换掉当前网关不该把它带走。挂在网关下面
  ///     等于让它随配置一起被覆盖；
  ///   * 网关下发的 `dsh.snippets` 只有内存副本（服务端 `~/.dsh/mobile-access/
  ///     snippets.json` 才是真源），两者刻意不同步 —— 本地这份永远不写回服务端。
  ///
  /// **迁移策略**（比"新版本读旧数据"更宽一点，覆盖三种真实会遇到的形状）：
  ///
  ///   1. 键不存在（升级前的安装、或用户从没建过）→ 空列表。**不写回**，所以
  ///      下次还能区分"没有"与"空"；
  ///   2. 某个元素缺 `id`/`label`/`tag` → 该字段按空串处理，`id` 就地按**位置**
  ///      补一个（`local-<i>`），这一轮里编辑/删除/排序立刻可用；下次保存时才落盘；
  ///   3. JSON 坏掉 / 不是数组 / 元素不是对象 → 能救的照救，救不了的就跳过；
  ///      整体解析失败返回空列表并**保留盘上的原文不删** —— 读失败不等于没有数据，
  ///      真把用户的东西清掉才是。正文为空串的条目跳过（它插不进输入框，留着只
  ///      会在列表里多一行点不出内容的行）。
  ///
  /// 取值上限 [maxLocalSnippets] 条，超出时**保留前 N 条**（与界面上的顺序一致，
  /// 用户在底部看不到的条目先被截掉），并在界面上如实提示。
  static const String _keyLocalSnippets = 'dsh_local_snippets';

  /// 本地条目上限。网关侧是 50 条，本地放宽一档且不联网，纯粹是防止某个 bug
  /// 把 SharedPreferences 写成几 MB。
  static const int maxLocalSnippets = 200;

  static Future<List<LocalSnippet>> loadLocalSnippets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyLocalSnippets);
    if (raw == null || raw.trim().isEmpty) return const [];

    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      // 坏 JSON：返回空列表，但**不回写**。下次用户保存时会用一份干净的数据覆盖，
      // 在此之前盘上的原文原封不动（万一只是本次解码路径出了问题）。
      return const [];
    }
    if (decoded is! List) return const [];

    final out = <LocalSnippet>[];
    for (var i = 0; i < decoded.length; i++) {
      final e = decoded[i];
      if (e is! Map) continue;
      final s = LocalSnippet.fromJson(Map<String, dynamic>.from(e));
      if (s.text.trim().isEmpty) continue;
      out.add(s.id.isEmpty ? s.copyWith(id: 'local-$i') : s);
      if (out.length >= maxLocalSnippets) break;
    }
    return out;
  }

  static Future<void> saveLocalSnippets(List<LocalSnippet> snippets) async {
    final prefs = await SharedPreferences.getInstance();
    final capped = snippets.length > maxLocalSnippets
        ? snippets.sublist(0, maxLocalSnippets)
        : snippets;
    await prefs.setString(
      _keyLocalSnippets,
      jsonEncode(capped.map((s) => s.toJson()).toList()),
    );
  }

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
    await _writeSecrets(config);
    // 覆盖墓碑：用户已经在配置页选定了要连的网关，"没有活动网关"不再成立。
    await prefs.setString(_keyActiveId, config.id);
    await _writeConfigMirror(config);
    await upsertProfile(config);
  }

  /// 「当前没有活动网关」的墓碑值。
  ///
  /// 为什么需要它、而不是直接把 `dsh_active_profile_id` 删掉：`loadProfiles()` 把
  /// `dsh_server_config` 提升为第一个 profile 的迁移路径，判据正是"active id 键
  /// 不存在"。用户删掉当前网关后，那面 `dsh_server_config` 镜像还留着内容 ——
  /// 键一删，下次启动就会把它当成"旧安装"重新提升回来，被删掉的网关静默复活
  /// 并重新连上。写一个空串表示"我知道有这个键，只是现在没有活动网关"，
  /// 迁移路径就不会误判。
  static const String _noActiveProfile = '';

  /// 是否处于"用户明确清空过活动网关"的状态（区别于"从来没有过"）。
  /// 同步函数：只读一个键，构造 Future 去 await 它没有意义。
  static bool _activeCleared(SharedPreferences prefs) =>
      prefs.containsKey(_keyActiveId) && (prefs.getString(_keyActiveId) ?? '').isEmpty;

  static Future<ServerConfig?> loadConfig() async {
    // 走 loadProfiles：密文回填、明文迁移都只有那么一条路径，配置页与启动路径
    // 不会有第二种解释。
    final profiles = await loadProfiles();
    final id = await activeProfileId();
    for (final p in profiles) {
      if (p.id == id) return p;
    }

    final legacy = await _loadRawActiveConfig();
    if (legacy == null) return null;

    // 用户在配置页删掉了当前网关 → 不能让镜像把它带回来。
    final prefs = await SharedPreferences.getInstance();
    if (_activeCleared(prefs)) return null;

    if (legacy.id.isEmpty) return legacy; // 预 profile 时代的单配置，没有 id 可对
    if (id == null) {
      // 没有 active id，但配置的 id 在列表里 —— 升级过程中会短暂出现这个形状
      // （列表已写、`dsh_active_profile_id` 还没写）。按列表里那一项用，
      // 否则用户会在升级后的第一次启动看到"配置丢失"。
      for (final p in profiles) {
        if (p.id == legacy.id) return p;
      }
      return null;
    }
    // 有 id 却对不上任何已保存的网关 → 它已经被删了。
    return null;
  }

  static Future<String?> activeProfileId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_keyActiveId);
    return (id == null || id.isEmpty) ? null : id;
  }

  // --------------------------------------------------------------- profiles --

  /// Every saved gateway, oldest first. Migrates a pre-profile install.
  static Future<List<ServerConfig>> loadProfiles() async {
    await SecureStore.ensureInitialized();
    _pendingScrub = false;
    final prefs = await SharedPreferences.getInstance();
    final out = <ServerConfig>[];
    var dirty = false;

    final raw = prefs.getString(_keyProfiles);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) {
              final c = await _loadProfileFromJson(Map<String, dynamic>.from(e));
              if (c.id.isEmpty) {
                c.id = newId();
                dirty = true;
              }
              out.add(c);
            }
          }
        }
      } catch (_) {
        // A corrupt list must not wedge the config page; fall through to the
        // migration path, which rebuilds one entry from the active config.
        out.clear();
        dirty = false;
      }
    }
    if (out.isNotEmpty) {
      // 只在「补齐了 id」或「剥掉了明文」时才回写，正常读取不产生写放大。
      if (dirty || _pendingScrub) await _writeProfiles(out);
      return out;
    }

    // 预 profile 时代只写了 `dsh_server_config`。把它提升为第一个 profile，
    // 同时把里面的明文凭据搬进 SecureStore。
    //
    // 但墓碑存在时**不能**提升：用户刚删掉当前网关，`dsh_server_config` 那面镜像
    // 还留着内容，键一被当成"旧安装"就会把它重新提升回来 —— 被删的网关静默复活
    // 并重新连上。这是"删了又回来"这类 bug 唯一的入口，必须堵在这里。
    if (_activeCleared(prefs)) return out;

    final legacy = await _loadRawActiveConfig();
    if (legacy != null) {
      if (legacy.id.isEmpty) legacy.id = newId();
      if (legacy.name.trim().isEmpty) legacy.name = legacy.displayName;
      out.add(legacy);
      await _writeProfiles(out);
      await prefs.setString(_keyActiveId, legacy.id);
      // 明文是否真的剥干净由 _loadRawActiveConfig 决定（它只有在密文确认可用时
      // 才会删 SP 里的明文），这里不再重复判断。
      await _writeConfigMirror(legacy);
    }
    return out;
  }

  static Future<void> saveProfiles(List<ServerConfig> profiles) async {
    await _writeProfiles(profiles);
    // 列表里那一项如果正是 active，镜像必须跟着走，否则下次启动连的还是旧 token。
    await _syncActiveMirror(profiles);
  }

  /// 给一个新网关挑一个**不重复**的别名（[feat 2026-10-22]）。
  ///
  /// 为什么需要：用户可能挂着两台电脑走同一个域名（或同一台电脑的两个网关
  /// 端口），别名一样时下拉框里两行字完全分不出来 —— 那正好是"需要加个别名"
  /// 的原始诉求。这里只在**创建**新网关时兜底：用户自己填了名字就照用，没填就
  /// 用 `主机:端口`，撞名就加 `(2)`、`(3)`。
  ///
  /// @param profiles 现有列表（调用方已经加载过，不必再读一次盘）。
  /// @param desired 用户填的别名（可空）。
  /// @param fallback 没填时的候选（通常是 `host:port`）。
  /// @param excludeId 编辑已有项时排除它自己，避免"改名成自己"被判成重复。
  static String uniqueProfileName(
    List<ServerConfig> profiles,
    String desired, {
    required String fallback,
    String? excludeId,
  }) {
    final base = (desired.trim().isNotEmpty ? desired.trim() : fallback.trim());
    final seed = base.isEmpty ? '未命名网关' : base;
    final taken = profiles
        .where((p) => excludeId == null || p.id != excludeId)
        .map((p) => p.name.trim().toLowerCase())
        .where((n) => n.isNotEmpty)
        .toSet();
    if (!taken.contains(seed.toLowerCase())) return seed;
    for (var n = 2; n < 1000; n += 1) {
      final candidate = '$seed ($n)';
      if (!taken.contains(candidate.toLowerCase())) return candidate;
    }
    return '$seed (${DateTime.now().millisecondsSinceEpoch})';
  }

  static Future<List<ServerConfig>> deleteProfile(String id) =>
      _withProfilesLock(() async {
        final profiles = await loadProfiles();
        profiles.removeWhere((p) => p.id == id);
        await _writeProfiles(profiles);
        // 连密钥槽一起删。失败不影响删除结果 —— 留一段读不到的密文远好过因为清理
        // 失败而删不掉网关。
        await SecureStore.delete(_tokenKey(id));
        await SecureStore.delete(_authKey(id));
        // [fix 2026-10-17] 迁移前的旧槽（_activeSecretScope）也要清：profile 早年
        // 可能还没分配 id 就把密文写在了 active 槽里，只删主槽会把它留在 Keystore。
        await SecureStore.delete(_tokenKey(_activeSecretScope));
        await SecureStore.delete(_authKey(_activeSecretScope));
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getString(_keyActiveId) == id) {
          // 删掉的正是当前网关 → 留一个空墓碑，而不是把键删掉：键一旦不存在，
          // 下次启动的迁移路径会把 `dsh_server_config` 镜像当成旧安装重新提升，
          // 被删的网关就复活了。
          await prefs.setString(_keyActiveId, _noActiveProfile);
        }
        return profiles;
      });

  static Future<List<ServerConfig>> renameProfile(String id, String name) =>
      _withProfilesLock(() async {
        final profiles = await loadProfiles();
        final i = profiles.indexWhere((p) => p.id == id);
        if (i < 0) return profiles;
        profiles[i].name = name.trim();
        await _writeProfiles(profiles);
        final prefs = await SharedPreferences.getInstance();
        // Keep the active copy in step, otherwise the next launch loads a gateway
        // whose label no longer matches the list entry it came from.
        if (prefs.getString(_keyActiveId) == id) {
          await _writeConfigMirror(profiles[i]);
        }
        return profiles;
      });

  /// Marks [id] active and mirrors it into `dsh_server_config`, which is what
  /// `main.dart` reads at startup. Returns null when the id is unknown.
  static Future<ServerConfig?> setActiveProfile(String id) async {
    final profiles = await loadProfiles();
    final i = profiles.indexWhere((p) => p.id == id);
    if (i < 0) return null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyActiveId, id);
    await _writeConfigMirror(profiles[i]);
    return profiles[i];
  }

  // --------------------------------------------------- 敏感字段：KeyValue 槽 --

  /// 密文键名。AndroidKeyStore 里只有一把主密钥（别名固定），每个字段一个
  /// 独立 IV；键名本身不含敏感信息，所以明文命名可以直接用。
  static String _tokenKey(String scope) => 'dsh_secure_token_$scope';
  static String _authKey(String scope) => 'dsh_secure_auth_$scope';

  /// 把 [c] 的 token / authCode 写进 [SecureStore]，并报告**逐个字段**的结果。
  ///
  /// 返回值是"哪些键已经在 Keystore 保护之下"。调用方据此只剥掉有把握的那几个
  /// 字段 —— 不透明的"全局可用/不可用"正是丢数据的入口：token 写进去了、
  /// authCode 没写进去时，一刀切地剥掉两个字段就等于把 authCode 弄丢。
  static Future<Map<String, bool>> _writeSecrets(ServerConfig c) async {
    final scope = c.id.isEmpty ? _activeSecretScope : c.id;
    final values = <String, String>{};
    if (c.token.isNotEmpty) values[_tokenKey(scope)] = c.token;
    if (c.authCode.isNotEmpty) values[_authKey(scope)] = c.authCode;
    // [fix 2026-10-17] 空字段 = 用户清掉了这个凭据：必须把密文槽一起删掉。
    // 此前这里只写非空值、从不 delete —— 下次 _resolveSecret 读到旧密文回填，
    // 用户删除的凭据"复活"，UI 无法摆脱。
    if (c.token.isEmpty) await SecureStore.delete(_tokenKey(scope));
    if (c.authCode.isEmpty) await SecureStore.delete(_authKey(scope));
    if (values.isEmpty) return const {};

    await SecureStore.writeAll(values);

    final secured = <String, bool>{};
    for (final e in values.entries) {
      // verify 打到原生侧，不看缓存：write 失败也会把值放进缓存，
      // 用 read 校验会读到缓存里的自己，把"写得进读不出"验成成功。
      secured[e.key] = await SecureStore.verify(e.key, e.value);
    }
    return secured;
  }

  /// 从 [SecureStore] 取回敏感字段并填进 [c]，报告**逐个字段**的搬迁结果。
  ///
  /// 返回"哪些键已经在 Keystore 保护之下"。没有确认成功的字段必须保留明文：
  /// 那是"失败不丢数据"的落点，而且判断要逐字段做 —— 一刀切地"有一个失败就
  /// 整体保留明文"会让已经搬迁成功的字段白搬（下次还要再搬一次），
  /// "整体成功才剥"则会在部分成功时把没搬走的那个字段从 SP 里删掉。
  static Future<Map<String, bool>> _readSecrets(
    ServerConfig c, {
    required bool allowActiveFallback,
  }) async {
    final scope = c.id.isEmpty ? _activeSecretScope : c.id;
    final secured = <String, bool>{};

    final token = await _resolveSecret(
      primary: _tokenKey(scope),
      legacy: allowActiveFallback ? _tokenKey(_activeSecretScope) : null,
      plain: c.token,
    );
    c.token = token.value;
    secured[_tokenKey(scope)] = token.secured;

    final auth = await _resolveSecret(
      primary: _authKey(scope),
      legacy: allowActiveFallback ? _authKey(_activeSecretScope) : null,
      plain: c.authCode,
    );
    c.authCode = auth.value;
    secured[_authKey(scope)] = auth.secured;

    return secured;
  }

  /// 单个字段的三段式解析：密文槽 → 旧槽 → SP 明文。
  ///
  /// 旧槽（`_activeSecretScope`）的存在是给「已经存过密文、但还没分配 profile id」
  /// 的中间状态兜底：升级前那一次 load 把密文写在了 active 槽里，之后 id 才被
  /// 补上。没有它，用户的 token 会在「升级 → 保存 → 重启」之间消失。
  static Future<_Secret> _resolveSecret({
    required String primary,
    required String? legacy,
    required String plain,
  }) async {
    final fromPrimary = await SecureStore.read(primary);
    if (fromPrimary != null && fromPrimary.isNotEmpty) {
      return _Secret(fromPrimary, true);
    }
    if (legacy != null && legacy != primary) {
      final fromLegacy = await SecureStore.read(legacy);
      if (fromLegacy != null && fromLegacy.isNotEmpty) {
        // 搬到主槽后再删旧槽，顺序不能反。
        final ok = await SecureStore.write(primary, fromLegacy);
        if (ok) await SecureStore.delete(legacy);
        return _Secret(fromLegacy, ok);
      }
    }
    if (plain.isEmpty) return const _Secret('', true);

    // 明文迁移：只有「确认写进去且读得回来」才把 SP 里的明文清掉。
    final ok = await SecureStore.write(primary, plain);
    if (!ok) return _Secret(plain, false);
    // 关键：用 verify（绕过缓存、打到原生侧）而不是 SecureStore.read。
    // write 失败时也会把值放进内存缓存，用 read 校验会读到缓存里的自己，
    // 于是"写得进读不出"被验成成功 → 明文被删 → 用户凭据丢失。
    if (!await SecureStore.verify(primary, plain)) return _Secret(plain, false);
    return _Secret(plain, true);
  }

  /// 把 [c] 里非敏感部分写进 `dsh_server_config`（active 镜像）。
  ///
  /// [secured] 只标"有把握已经进 Keystore"的键，其余字段的原样保留明文 ——
  /// 这是"失败不丢数据"的落点。
  static Future<void> _writeConfigMirror(ServerConfig c) async {
    final prefs = await SharedPreferences.getInstance();
    final secured = await _writeSecrets(c);
    await prefs.setString(_keyConfig, jsonEncode(_scrub(c, secured)));
  }

  /// 读 `dsh_server_config` 原始条目、回填凭据、必要时迁移明文。
  ///
  /// 这一步**不**提升成 profile、**不**写 `dsh_active_profile_id`：调用方
  /// （[loadProfiles] / [loadConfig]）才决定要不要提升，避免两条路径互相触发。
  static Future<ServerConfig?> _loadRawActiveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_keyConfig);
    if (jsonStr == null || jsonStr.isEmpty) return null;

    Map<String, dynamic> map;
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return null;
      map = Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 与旧实现保持一致：坏 JSON 返回 null 而不是抛。
      return null;
    }

    ServerConfig c;
    try {
      c = ServerConfig.fromJson(map);
    } catch (_) {
      return null;
    }

    final secured = await _readSecrets(c, allowActiveFallback: false);
    if (_hasPlainSensitive(map) && _anySecured(secured)) {
      // 至少有一个字段确认搬进了 Keystore → 把能剥的剥掉。没确认成功的字段
      // 由 _writeConfigMirror → _scrub 按同一份 secured 判定保留明文，
      // 所以不会出现"哪一边都没有"。幂等：下次启动再试。
      await _writeConfigMirror(c);
    }
    return c;
  }

  /// 读一条 profile JSON、回填凭据。
  ///
  /// [allowActiveFallback] 用于「id 是本进程才补上的」这一种情况（见 [_resolveSecret]）。
  static Future<ServerConfig> _loadProfileFromJson(
    Map<String, dynamic> map, {
    bool allowActiveFallback = true,
  }) async {
    final c = ServerConfig.fromJson(map);
    final secured = await _readSecrets(c, allowActiveFallback: allowActiveFallback);
    if (_hasPlainSensitive(map) && _anySecured(secured)) {
      // 需要调用方整体回写列表（单条就地改不了数组）。用 dirty 标记，由
      // loadProfiles 统一处理，避免这里又触发一次 load→save 递归。
      _pendingScrub = true;
    }
    return c;
  }

  /// 有没有任何一个键确认进了 Keystore。全都失败时不必回写（写了也没变化）。
  static bool _anySecured(Map<String, bool> secured) =>
      secured.values.any((v) => v);

  /// 本进程读取过程中发现有需要回写的内容（补 id / 剥明文）。
  static bool _pendingScrub = false;

  /// [fix 2026-10-28] profile 读-改-写串行锁。
  ///
  /// upsert/rename/delete 都是「异步读 → 改 → 整体回写」。无互斥时并发调用
  /// 后写覆盖前写：一次丢更新（典型：保存网关的同时另一次保存在途，先完成的
  /// 那份修改被静默抹掉）。
  static bool _profilesBusy = false;
  static final List<Completer<void>> _profilesWaiters = <Completer<void>>[];

  /// 在串行锁内执行一次 profile 复合操作（读-改-写）。
  static Future<T> _withProfilesLock<T>(Future<T> Function() op) async {
    // 无竞争时与直接调用完全同形（只多一个微任务），不会改变既有调用时序。
    if (_profilesBusy) {
      final waiter = Completer<void>();
      _profilesWaiters.add(waiter);
      // 排队等待，但**最多等 10 秒**：平台通道（Keystore / SharedPreferences）
      // 出现过永不完成的情况，一次卡死不能把后续所有读写永久堵住。
      await waiter.future
          .timeout(const Duration(seconds: 10), onTimeout: () {});
    }
    _profilesBusy = true;
    try {
      return await op();
    } finally {
      _profilesBusy = false;
      if (_profilesWaiters.isNotEmpty) {
        final next = _profilesWaiters.removeAt(0);
        if (!next.isCompleted) next.complete();
      }
    }
  }

  /// Inserts or replaces by id, serialized against other profile writes.
  ///
  /// [config.id] is assigned **同步**（与改锁之前一致）：调用方 `await` 之后
  /// 立刻读 `config.id` 的既有契约不能因为排队而延后。
  static Future<List<ServerConfig>> upsertProfile(ServerConfig config) {
    if (config.id.isEmpty) config.id = newId();
    return _withProfilesLock(() async {
      final profiles = await loadProfiles();
      final i = profiles.indexWhere((p) => p.id == config.id);
      if (i >= 0) {
        profiles[i] = config;
      } else {
        profiles.add(config);
      }
      await _writeProfiles(profiles);
      return profiles;
    });
  }

  static Future<void> _writeProfiles(List<ServerConfig> profiles) async {
    _pendingScrub = false;
    final prefs = await SharedPreferences.getInstance();
    final encoded = <Map<String, dynamic>>[];
    for (final p in profiles) {
      final secured = await _writeSecrets(p);
      encoded.add(_scrub(p, secured));
    }
    await prefs.setString(_keyProfiles, jsonEncode(encoded));
  }

  /// 把 active 镜像同步成 [profiles] 里对应那一项（id 对得上才动）。
  static Future<void> _syncActiveMirror(List<ServerConfig> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final activeId = prefs.getString(_keyActiveId);
    if (activeId == null || activeId.isEmpty) return;
    for (final p in profiles) {
      if (p.id == activeId) {
        await _writeConfigMirror(p);
        return;
      }
    }
  }

  /// 按 [secured] 剥掉已经确认进 Keystore 的敏感字段；没确认的保持明文。
  ///
  /// 逐字段判断而不是"整体可用/不可用"：token 写进去了、authCode 没写进去时，
  /// 一刀切地剥两个就等于把 authCode 弄丢。
  ///
  /// 空字段一律删掉：明文时代 `toJson()` 会带上 `"authCode":""` 这种纯空串，
  /// 既然敏感字段现在另存，就不该在 SP 里留一个空的同名键 —— 它让"SP 里还有
  /// 没有敏感字段"这个最该一眼看清的问题变得需要逐值判断。
  static Map<String, dynamic> _scrub(ServerConfig c, Map<String, bool> secured) {
    final json = c.toJson();
    final scope = c.id.isEmpty ? _activeSecretScope : c.id;
    if (secured[_tokenKey(scope)] == true || c.token.isEmpty) {
      json.remove(_kToken);
    }
    if (secured[_authKey(scope)] == true || c.authCode.isEmpty) {
      json.remove(_kAuthCode);
    }
    return json;
  }

  static bool _hasPlainSensitive(Map<String, dynamic> json) {
    for (final k in const [_kToken, _kAuthCode]) {
      final v = json[k];
      if (v is String && v.isNotEmpty) return true;
    }
    return false;
  }
}

/// 单个敏感字段的解析结果。
class _Secret {
  final String value;

  /// 值是否已经处于 Keystore 保护之下（或本来就是空的）。
  final bool secured;
  const _Secret(this.value, this.secured);
}
