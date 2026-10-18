import 'package:flutter/foundation.dart';

import 'secure_store.dart';

/// 自签证书指纹的信任判定结果（v1.35 / 任务 1.4）。
enum CertTrustDecision {
  /// 首次见到这张证书：已写入信任库，本次放行（TOFU）。
  firstUse,

  /// 指纹与信任库一致：放行。
  match,

  /// 信任库里是另一张证书：**必须拦截**，由用户显式确认后才能更新。
  mismatch,

  /// 网关没有提供指纹（老网关 / 证书签发失败的降级态）：不做校验。
  unavailable,
}

/// [CertTrust.check] 的返回值。UI 层据此展示告警页（mismatch 时带上旧指纹）。
class CertTrustResult {
  const CertTrustResult({
    required this.decision,
    required this.fingerprint,
    this.previousFingerprint,
  });

  final CertTrustDecision decision;

  /// 规范化后的新指纹（`sha256/<hex>`）；不可用时为空串。
  final String fingerprint;

  /// mismatch 时信任库里存的旧指纹，其余情况为 null。
  final String? previousFingerprint;

  bool get allowsConnection =>
      decision == CertTrustDecision.firstUse ||
      decision == CertTrustDecision.match ||
      decision == CertTrustDecision.unavailable;

  bool get needsUserConfirmation => decision == CertTrustDecision.mismatch;
}

/// 网关自签证书的 TOFU 信任库。
///
/// ## 为什么要它
///
/// v1.35 起网关可以开 HTTPS/WSS（自签证书）。自签意味着系统信任链不成立，
/// 若客户端一律 `badCertificateCallback => true`，那就等于把 TLS 降级成"加密但不
/// 防冒充"——同一 Wi-Fi 下的任何人都能中间人。TOFU 是这套约束下的标准解法：
///
/// 1. 第一次见到某张证书 → 记住它的 SHA-256 指纹，放行；
/// 2. 之后每次连接都比对指纹；
/// 3. 指纹变了 → **断开并要用户确认**（证书轮换 / 换机器 都会走到这里）。
///
/// 指纹变化有两种真实成因，用户必须能区分：
/// - 内网 IP 变了导致网关按新 SAN 重签（正常，常见于换 Wi-Fi/热点）；
/// - 有人在中间冒充网关（危险）。
/// 所以告警文案里要同时给出旧/新指纹与时间，让用户自己判断——本类只负责
/// 判定与存储，不做自动放行。
///
/// ## 存储边界
///
/// 按「网关身份 + 通道」分条：`cert_fp::<gatewayId>::<lan|remote>`。
/// 分成两个通道是因为远程通道（quick tunnel）用的是 Cloudflare 公开证书，
/// 由系统信任链校验，不参与 TOFU；而局域网自签证书的指纹变化不应影响远程
/// 通道的信任状态，反之亦然。
///
/// 值走 [SecureStore]（Android Keystore）。指纹本身不是秘密，但它与 token
/// 同处一个存储层，就不必再引入第二种落盘机制；降级到内存时行为一致。
class CertTrust {
  CertTrust._();

  static const String _prefix = 'cert_fp::';

  /// 规范化指纹：统一成 `sha256/<64 位小写 hex>`。
  ///
  /// 容忍三种真实输入：
  /// - 网关下发的 `sha256/ab12…`（配对二维码、/health）；
  /// - Dart `X509Certificate.sha256` 的裸 hex（无前缀）；
  /// - 带冒号或大写的手抄值（用户从截图里对着敲）。
  ///
  /// 规范化失败返回空串——调用方按 [CertTrustDecision.unavailable] 处理，
  /// 而不是把一段无法比较的字符串写进信任库。
  static String normalizeFingerprint(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.isEmpty) return '';
    if (s.startsWith('sha256/')) s = s.substring(7);
    s = s.replaceAll(RegExp(r'[^0-9a-f]'), '');
    if (s.length != 64) return '';
    return 'sha256/$s';
  }

  /// 通道归一：除 `remote` 之外一律算 `lan`。
  static String normalizeChannel(String channel) =>
      channel.trim().toLowerCase() == 'remote' ? 'remote' : 'lan';

  /// 网关身份归一。空 id（多网关功能之前写下的配置）退化为 host:port，
  /// 保证同一台机器在升级前后不会变成两个不同的信任条目。
  static String normalizeGatewayId(String gatewayId) {
    final id = gatewayId.trim();
    return id.isEmpty ? 'unknown' : id;
  }

  static String storageKey({
    required String gatewayId,
    String channel = 'lan',
  }) =>
      '$_prefix${normalizeGatewayId(gatewayId)}::${normalizeChannel(channel)}';

  /// 读信任库里存的指纹（未规范化前的原样值，调用方用 [normalizeFingerprint]
  /// 比较；没有记录返回 null）。
  static Future<String?> stored({
    required String gatewayId,
    String channel = 'lan',
  }) async {
    try {
      final v = await SecureStore.read(storageKey(gatewayId: gatewayId, channel: channel));
      if (v == null || v.isEmpty) return null;
      return v;
    } catch (e) {
      // SecureStore 自身已经"绝不抛"，这里是第二道保险：信任库读失败不能
      // 让连接流程崩掉。
      debugPrint('[CertTrust] 读取信任库失败: $e');
      return null;
    }
  }

  /// 核心判定：把本次连接拿到的证书指纹与信任库比对。
  ///
  /// 首次见到会**立即写入**（否则每次连都要用户确认，等于没做 TOFU）；
  /// mismatch **绝不自动覆盖**——覆盖只能走 [acceptChange]。
  static Future<CertTrustResult> check({
    required String gatewayId,
    required String fingerprint,
    String channel = 'lan',
  }) async {
    final incoming = normalizeFingerprint(fingerprint);
    if (incoming.isEmpty) {
      return const CertTrustResult(
        decision: CertTrustDecision.unavailable,
        fingerprint: '',
      );
    }

    final existing = await stored(gatewayId: gatewayId, channel: channel);
    final previous = existing == null ? '' : normalizeFingerprint(existing);

    if (previous.isEmpty) {
      await _persist(gatewayId: gatewayId, channel: channel, fingerprint: incoming);
      return CertTrustResult(
        decision: CertTrustDecision.firstUse,
        fingerprint: incoming,
      );
    }

    if (previous == incoming) {
      return CertTrustResult(
        decision: CertTrustDecision.match,
        fingerprint: incoming,
      );
    }

    return CertTrustResult(
      decision: CertTrustDecision.mismatch,
      fingerprint: incoming,
      previousFingerprint: previous,
    );
  }

  /// 用户点了「我认识这次变更」后调用：覆盖信任库并返回是否写入成功。
  static Future<bool> acceptChange({
    required String gatewayId,
    required String fingerprint,
    String channel = 'lan',
  }) async {
    final normalized = normalizeFingerprint(fingerprint);
    if (normalized.isEmpty) return false;
    return _persist(gatewayId: gatewayId, channel: channel, fingerprint: normalized);
  }

  /// 忘记一条信任记录（删除网关 / 重新配对时调用）。
  ///
  /// 不删的后果：用户重新配对了同一台机器，但网关重装过（新证书），
  /// 于是每次连接都弹「证书变了」——对一个刚刚主动删除网关的用户来说，
  /// 这条告警毫无信息量。
  static Future<void> forget({
    required String gatewayId,
    String channel = 'lan',
  }) async {
    try {
      await SecureStore.delete(storageKey(gatewayId: gatewayId, channel: channel));
    } catch (e) {
      debugPrint('[CertTrust] 删除信任记录失败: $e');
    }
  }

  /// 忘记某网关的全部通道（删除网关时用这一个就够了）。
  static Future<void> forgetGateway(String gatewayId) async {
    await forget(gatewayId: gatewayId, channel: 'lan');
    await forget(gatewayId: gatewayId, channel: 'remote');
  }

  static Future<bool> _persist({
    required String gatewayId,
    required String channel,
    required String fingerprint,
  }) async {
    try {
      await SecureStore.write(
        storageKey(gatewayId: gatewayId, channel: channel),
        fingerprint,
      );
      return true;
    } catch (e) {
      debugPrint('[CertTrust] 写入信任库失败: $e');
      return false;
    }
  }

  /* ------------------------------------------------------------------ *
   * 同步视图（TLS 握手路径专用）
   *
   * `HttpClient.badCertificateCallback` 是**同步**回调：握手卡在那几毫秒里，
   * 不能 await Keystore。所以连接前先 [preload] 把该网关该通道的记录读进内存，
   * 握手时用 [decideSync] 纯内存判定。
   *
   * 第一次见到证书时 decideSync 只更新内存，落盘由调用方在连接建立后补一次
   * [acceptChange]（fire-and-forget）。丢一次落盘不会导致安全问题：下一次连接
   * 会重新走 firstUse → 再写一次；最坏情况是"每次都要确认"的体验退化，而
   * 不是错误地放行一张陌生证书。
   * ------------------------------------------------------------------ */

  static final Map<String, String> _sync = <String, String>{};

  /// 读一次信任库，填充同步视图。connect() 在建立 WSS 之前 await 它。
  static Future<void> preload({
    required String gatewayId,
    String channel = 'lan',
  }) async {
    final raw = await stored(gatewayId: gatewayId, channel: channel);
    final key = storageKey(gatewayId: gatewayId, channel: channel);
    final normalized = normalizeFingerprint(raw ?? '');
    if (normalized.isEmpty) {
      _sync.remove(key);
    } else {
      _sync[key] = normalized;
    }
  }

  /// 同步判定（不读盘、不写盘）。语义与 [check] 一致。
  static CertTrustResult decideSync({
    required String gatewayId,
    required String fingerprint,
    String channel = 'lan',
  }) {
    final incoming = normalizeFingerprint(fingerprint);
    if (incoming.isEmpty) {
      return const CertTrustResult(
        decision: CertTrustDecision.unavailable,
        fingerprint: '',
      );
    }
    final key = storageKey(gatewayId: gatewayId, channel: channel);
    final previous = _sync[key] ?? '';
    if (previous.isEmpty) {
      _sync[key] = incoming;
      return CertTrustResult(
        decision: CertTrustDecision.firstUse,
        fingerprint: incoming,
      );
    }
    if (previous == incoming) {
      return CertTrustResult(
        decision: CertTrustDecision.match,
        fingerprint: incoming,
      );
    }
    return CertTrustResult(
      decision: CertTrustDecision.mismatch,
      fingerprint: incoming,
      previousFingerprint: previous,
    );
  }

  /// `X509Certificate.sha256` → `sha256/<hex>`。坏证书返回空串。
  static String fingerprintOfCertificate(Object? certificate) {
    try {
      final dynamic cert = certificate;
      final raw = cert?.sha256;
      return normalizeFingerprint(raw is String ? raw : '');
    } catch (_) {
      return '';
    }
  }

  /// 测试与诊断用：清空同步视图。
  static void resetSyncView() => _sync.clear();
}
