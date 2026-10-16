import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 小体量敏感字符串（网关 token / 授权码）的落盘层。
///
/// 为什么要自己写：`flutter_secure_storage` 会把 `js` 拖到 ^0.6.x，而
/// `speech_to_text: 6.6.2` 钉住的 `js ^0.7.1` 与它直接冲突（见 README §4）。
/// 为一个「存两段字符串」的需求去放开那个版本钉、再连带升级 Flutter /
/// plugin-loader，代价远大于收益 —— 原生侧真正需要的只是 AndroidKeyStore
/// 里一把不可导出的密钥 + AES/GCM，几十行 Kotlin 就够。
///
/// 职责边界：**加解密全部在原生**。本层只负责「把一段字符串变成一段不透明
/// 密文放进 SharedPreferences，再取回来」，密文格式（`iv:ct` 的 Base64）由
/// Kotlin 自己定义自己解释。这样 AndroidKeyStore 的密钥句柄永远不出原生进程，
/// Dart 侧拿到的只是密文串。
///
/// **降级是契约的一部分，不是补丁。** 单元测试 / widget 测试跑在 Dart VM 上，
/// 那里没有 MethodChannel 的宿主，任何 `invokeMethod` 都会抛
/// `MissingPluginException`；真机上 Keystore 也可能因为厂商 ROM、密钥被系统
/// 清除、密钥策略不兼容而失败。以上任何一种情况都必须变成「安静地退到进程内
/// 存储」，绝不把异常抛给 `StorageService` 的调用方 —— 否则 40+ 个既有测试会
/// 全红，真机上则是启动即崩。
///
/// 降级会不会丢用户配置？不会。内存表只在「本次进程」有效，所以
/// [isPlatformBacked] 为 false 时 `StorageService` **拒绝**把 SharedPreferences
/// 里的明文删掉（宁可暂时不变差，也不能把 token 弄丢）：明文继续兜底，
/// 下次启动照常能连上网关。
class SecureStore {
  SecureStore._();

  /// 原生通道。能力：`ping` / `write(key,value)` / `read(key)` / `delete(key)`。
  /// 返回的密文是不透明字符串，Dart 不解释它的内部结构。
  static const MethodChannel _ch = MethodChannel('dsh_mobile/secure');

  /// 进程内降级表。SharedPreferences 的读是异步的，而 `StorageService` 的若干
  /// 读取路径需要立即拿到结果，所以这一层必须存在。
  static final Map<String, String> _fallback = <String, String>{};

  /// 已经就"某个键没进 Keystore"提示过的集合。这条消息在降级环境里每次写入都会
  /// 命中（含测试输出），不去重会把日志刷满、反而盖住真正的问题。
  static final Set<String> _warned = <String>{};

  /// 读缓存，避免 `loadProfiles()` 这种高频路径每次都跨 MethodChannel。
  /// 值为 null 表示「读过且确认不存在」，与「没读过」区分开。
  static final Map<String, String?> _cache = <String, String?>{};

  /// 降级层所属的 SharedPreferences 实例。测试里的 `setMockInitialValues`
  /// 会换掉单例，此时上一代的内存数据必须整体作废，否则用例之间会互相串状态。
  static SharedPreferences? _gen;

  static bool _initStarted = false;

  /// 原生通道是否可用。**只读**，供测试断言降级行为。
  static bool _usingPlatform = false;

  /// 至少有一次原生调用抛过异常。**只读**，供诊断断言。
  static bool _degraded = false;

  /// 最近一次原生错误，仅供调试输出，不含任何敏感内容。
  static String _lastError = '';

  static bool get usingPlatform => _usingPlatform;
  static bool get degraded => _degraded;
  static String get lastError => _lastError;

  /// 值是否真的受 Keystore 保护。false 表示当前值只活在进程内存 + 明文 SP 里，
  /// 调用方据此决定「能不能把 SharedPreferences 的明文删掉」。
  static bool get isPlatformBacked => _usingPlatform && !_degraded;

  /// 探测原生实现。**永不抛异常**，可以放心在 `main()` 里 await。
  /// 幂等：重复调用只走缓存，不会反复打 MethodChannel。
  static Future<void> init() async {
    if (_initStarted) return;
    _initStarted = true;
    var ok = false;
    try {
      ok = await _ch.invokeMethod<bool>('ping') ?? false;
    } on MissingPluginException {
      // Dart VM（flutter test）/ 宿主未注册：完全正常的路径，不是错误。
      ok = false;
    } catch (e) {
      ok = false;
      _noteFailure('init', e);
    }
    _usingPlatform = ok;
    if (!ok && kDebugMode) {
      debugPrint('[SecureStore] 原生通道不可用，降级为进程内存储。');
    }
  }

  /// 惰性初始化。读取路径先 await 它一把：同步部分没有别的动作，await 之后
  /// 才碰 `_cache` / `_fallback`，保证读到的一定是当前这一代的数据。
  ///
  /// 还没探测过时先**乐观**把 [_usingPlatform] 置真：`StorageService` 的判断
  /// 依赖它，不能让调用方先看到「无原生 → 删掉明文」的中间态。随后 [init]
  /// 用 `ping` 的真实结果覆盖它。
  static Future<void> ensureInitialized() async {
    if (!_initStarted) {
      _usingPlatform = true;
      await Future.wait<void>([init(), _settleGeneration()]);
      return;
    }
    await _settleGeneration();
  }

  /// 读不到时返回 null；任何失败都退到内存表，绝不抛。空串视为不存在。
  static Future<String?> read(String key) async {
    await ensureInitialized();
    if (_cache.containsKey(key)) return _cache[key];

    if (_usingPlatform) {
      try {
        final v = await _ch.invokeMethod<String>('read', {'key': key});
        if (v != null) {
          // 原生侧确实有值：不再看内存表，避免读到降级期的旧值。
          _cache[key] = v;
          return v;
        }
      } catch (e) {
        _noteFailure('read', e);
      }
    }

    final mem = _fallback[key];
    if (mem != null && mem.isNotEmpty) {
      _cache[key] = mem;
      return mem;
    }
    // 原生可用但没这条记录 → 真的没有；原生不可用时也一样，内存表为空即无值。
    // 空串一律归一成 null（见类注释的契约）：空 token 与"没有 token"在连接层
    // 是同一件事，混用两种表示只会在调用方逼出 `!= null && != ''` 这种易错写法。
    if (_usingPlatform) _cache[key] = null;
    return null;
  }

  /// 写入一段字符串。
  ///
  /// 返回「值是否已处于 Keystore 保护之下」。[isPlatformBacked] 为 false 时，
  /// 值只进了内存表 + 明文兜底，返回 false，调用方据此**保留** SharedPreferences
  /// 里的明文。
  static Future<bool> write(String key, String value) async {
    if (value.isEmpty) {
      // 空串等价于"删除"：本层把"没有值"统一表示成 null，写入空串会同时污染
      // 缓存与降级表，让 read 读出 '' —— 调用方就得分两种情况判断。
      await delete(key);
      return false;
    }
    await ensureInitialized();
    var protected = false;

    if (_usingPlatform) {
      try {
        await _ch.invokeMethod<void>('write', {'key': key, 'value': value});
        protected = await _verifyRoundTrip(key, value);
      } catch (e) {
        _noteFailure('write', e);
      }
    }

    _cache[key] = value;
    if (protected) {
      _fallback.remove(key);
    } else {
      _fallback[key] = value;
      if (kDebugMode && _warned.add(key)) {
        debugPrint('[SecureStore] $key 未能进入 Keystore，仅进程内保存（每个键只提示一次）。');
      }
    }
    return protected;
  }

  /// 删除。失败静默 —— 清理不彻底顶多多占几字节，不该影响主流程。
  static Future<void> delete(String key) async {
    await ensureInitialized();
    _cache[key] = null;
    _fallback.remove(key);
    if (!_usingPlatform) return;
    try {
      await _ch.invokeMethod<void>('delete', {'key': key});
    } catch (e) {
      _noteFailure('delete', e);
    }
  }

  /// 批量读：返回值一定含 [keys] 里的每一个键，缺失的为 null。
  static Future<Map<String, String?>> readAll(List<String> keys) async {
    final out = <String, String?>{};
    for (final k in keys) {
      out[k] = await read(k);
    }
    return out;
  }

  /// 批量写。返回「全部键都已受 Keystore 保护」—— 有一个没进去就返回 false，
  /// 调用方保守处理（继续留明文）。
  static Future<bool> writeAll(Map<String, String> values) async {
    var allProtected = true;
    for (final e in values.entries) {
      final ok = await write(e.key, e.value);
      if (!ok) allProtected = false;
    }
    return allProtected;
  }

  /// 只清缓存与内存表，不碰原生密文。测试用；进程重启等价于此。
  @visibleForTesting
  static void resetForTesting() {
    _cache.clear();
    _fallback.clear();
    _warned.clear();
    _gen = null;
    _initStarted = false;
    _usingPlatform = false;
    _degraded = false;
    _lastError = '';
  }

  // ------------------------------------------------------------ internals --

  /// 结算降级层所属的存储代。SharedPreferences 单例被换掉即视为新一代，
  /// 旧数据整体作废。
  ///
  /// 为什么必须 await：`SharedPreferences` 自己缓存单例，`setMockInitialValues`
  /// 会把缓存清掉，所以「换没换」只能靠解析出来的实例身份判断 —— 而解析必然是
  /// 异步的。把它放在任何 `_cache` / `_fallback` 读取之前，就能保证用例之间
  /// 不会互相串状态（前一条用例的降级值不会冒充后一条用例的密文）。
  static Future<void> _settleGeneration() async {
    try {
      final current = await SharedPreferences.getInstance();
      if (!identical(_gen, current)) {
        _gen = current;
        _fallback.clear();
        _cache.clear();
      }
    } catch (_) {
      // 纯 Dart 环境没有 SharedPreferences 宿主：只用内存表，不需要结算。
    }
  }

  /// 绕过缓存的写后读回校验：返回"这个键在原生侧**现在**确实存着 [expected]"。
  ///
  /// 为什么必须绕开缓存：[write] 无论成功失败都会把值写进内存缓存（失败时那是
  /// 唯一的存身处）。用 [read] 去校验就会读到缓存里的自己，把"写成功但读不回"
  /// 这类故障验成成功，进而删掉 SharedPreferences 里的明文 —— 那是真的丢凭据。
  /// 校验必须打到原生侧。
  static Future<bool> verify(String key, String expected) async {
    if (expected.isEmpty) return true;
    await ensureInitialized();
    if (!_usingPlatform) return false;
    return _verifyRoundTrip(key, expected);
  }

  /// 写后读回一次。Keystore 的失效模式大多是「写成功但读不出来」（密钥被系统
  /// 清除、ROM 的 GCM 实现异常），只有真读回来才算数 —— 不验证就删明文，
  /// 等于拿用户的网关凭据去赌厂商 ROM。
  static Future<bool> _verifyRoundTrip(String key, String expected) async {
    try {
      final stored = await _ch.invokeMethod<String>('read', {'key': key});
      return stored == expected;
    } catch (e) {
      _noteFailure('verify', e);
      return false;
    }
  }

  static void _noteFailure(String op, Object e) {
    if (e is MissingPluginException) {
      _usingPlatform = false;
      return;
    }
    _degraded = true;
    _lastError = '$op: $e';
    if (kDebugMode) debugPrint('[SecureStore] $op 失败，降级：$e');
  }
}
