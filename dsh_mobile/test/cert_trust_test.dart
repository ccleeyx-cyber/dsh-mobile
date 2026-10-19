import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/services/cert_trust.dart';

/// v1.35 / 1.4：TOFU 信任库的三态与隔离性。
///
/// 全部跑在 Dart VM 上：SecureStore 走 MethodChannel 会抛
/// MissingPluginException 并自动降级到进程内表，这正是我们想测的路径
/// （真机上换成 Keystore，行为契约相同）。
void main() {
  setUp(() async {
    // 每个用例一代新的 SharedPreferences（降级层），避免互相串状态。
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  String fp(String c) => 'sha256/${List.filled(64, c).join()}';

  group('指纹规范化', () {
    test('接受网关下发的 sha256/ 前缀形式', () {
      expect(CertTrust.normalizeFingerprint(fp('a')), fp('a'));
    });

    test('接受裸 hex（X509Certificate.sha256 的形态）', () {
      final bare = List.filled(64, 'b').join();
      expect(CertTrust.normalizeFingerprint(bare), 'sha256/$bare');
    });

    test('容忍大写与冒号分隔', () {
      // 32 组 AB = 64 位 hex = 一张真实证书的 SHA-256 长度
      final hexy = List.filled(32, 'AB').join(':');
      expect(CertTrust.normalizeFingerprint(hexy), 'sha256/${List.filled(32, 'ab').join()}');
    });

    test('长度不对视为不可用', () {
      expect(CertTrust.normalizeFingerprint('sha256/deadbeef'), '');
      expect(CertTrust.normalizeFingerprint(''), '');
      expect(CertTrust.normalizeFingerprint('   '), '');
    });
  });

  group('三态判定', () {
    test('首次见到 → firstUse，并立刻写入信任库', () async {
      final r = await CertTrust.check(gatewayId: 'gw-1', fingerprint: fp('1'));
      expect(r.decision, CertTrustDecision.firstUse);
      expect(r.allowsConnection, isTrue);
      expect(r.needsUserConfirmation, isFalse);
      expect(await CertTrust.stored(gatewayId: 'gw-1'), fp('1'));
    });

    test('同指纹再次连接 → match，不重复写', () async {
      await CertTrust.check(gatewayId: 'gw-1', fingerprint: fp('1'));
      final r = await CertTrust.check(gatewayId: 'gw-1', fingerprint: fp('1'));
      expect(r.decision, CertTrustDecision.match);
      expect(r.allowsConnection, isTrue);
    });

    test('指纹变了 → mismatch，带旧指纹，且绝不自动覆盖', () async {
      await CertTrust.check(gatewayId: 'gw-1', fingerprint: fp('1'));
      final r = await CertTrust.check(gatewayId: 'gw-1', fingerprint: fp('2'));

      expect(r.decision, CertTrustDecision.mismatch);
      expect(r.allowsConnection, isFalse, reason: '未确认前必须拦住连接');
      expect(r.previousFingerprint, fp('1'));
      expect(await CertTrust.stored(gatewayId: 'gw-1'), fp('1'),
          reason: '自动覆盖会让攻击者的证书永久生效');
    });

    test('用户确认后 → acceptChange 覆盖，后续连接变 match', () async {
      await CertTrust.check(gatewayId: 'gw-1', fingerprint: fp('1'));
      final changed = await CertTrust.check(gatewayId: 'gw-1', fingerprint: fp('2'));
      expect(changed.needsUserConfirmation, isTrue);

      expect(await CertTrust.acceptChange(gatewayId: 'gw-1', fingerprint: fp('2')), isTrue);
      final after = await CertTrust.check(gatewayId: 'gw-1', fingerprint: fp('2'));
      expect(after.decision, CertTrustDecision.match);
      expect(await CertTrust.stored(gatewayId: 'gw-1'), fp('2'));
    });

    test('acceptChange 拒绝不可用的指纹', () async {
      expect(await CertTrust.acceptChange(gatewayId: 'gw-1', fingerprint: 'garbage'), isFalse);
    });

    test('网关不给指纹 → unavailable，不做校验也不写库', () async {
      final r = await CertTrust.check(gatewayId: 'gw-1', fingerprint: '');
      expect(r.decision, CertTrustDecision.unavailable);
      expect(r.allowsConnection, isTrue);
      expect(r.needsUserConfirmation, isFalse);
      expect(await CertTrust.stored(gatewayId: 'gw-1'), isNull);
    });
  });

  group('隔离性', () {
    test('多网关互不影响', () async {
      await CertTrust.check(gatewayId: 'gw-a', fingerprint: fp('a'));
      await CertTrust.check(gatewayId: 'gw-b', fingerprint: fp('b'));

      // gw-b 的证书变化不应影响 gw-a
      final bChange = await CertTrust.check(gatewayId: 'gw-b', fingerprint: fp('c'));
      expect(bChange.decision, CertTrustDecision.mismatch);

      final aStillOk = await CertTrust.check(gatewayId: 'gw-a', fingerprint: fp('a'));
      expect(aStillOk.decision, CertTrustDecision.match);
    });

    test('同网关的 lan / remote 通道各存一条', () async {
      await CertTrust.check(gatewayId: 'gw', channel: 'lan', fingerprint: fp('1'));
      await CertTrust.check(gatewayId: 'gw', channel: 'remote', fingerprint: fp('2'));

      final lan = await CertTrust.check(gatewayId: 'gw', channel: 'lan', fingerprint: fp('1'));
      expect(lan.decision, CertTrustDecision.match);

      // 远程通道换证书不影响局域网那一条
      final remoteChange = await CertTrust.check(gatewayId: 'gw', channel: 'remote', fingerprint: fp('3'));
      expect(remoteChange.decision, CertTrustDecision.mismatch);
      expect(remoteChange.previousFingerprint, fp('2'));

      final lanAgain = await CertTrust.check(gatewayId: 'gw', channel: 'lan', fingerprint: fp('1'));
      expect(lanAgain.decision, CertTrustDecision.match);
    });

    test('未知通道名归一到 lan', () {
      expect(
        CertTrust.storageKey(gatewayId: 'gw', channel: 'wifi'),
        CertTrust.storageKey(gatewayId: 'gw', channel: 'lan'),
      );
      expect(CertTrust.storageKey(gatewayId: 'gw', channel: 'REMOTE'),
          CertTrust.storageKey(gatewayId: 'gw', channel: 'remote'));
    });

    test('空 gatewayId 归一到 unknown，不会与真实 id 相撞', () {
      expect(CertTrust.storageKey(gatewayId: ''), CertTrust.storageKey(gatewayId: 'unknown'));
      expect(CertTrust.storageKey(gatewayId: 'gw'),
          isNot(CertTrust.storageKey(gatewayId: '')));
    });
  });

  group('遗忘', () {
    test('forgetGateway 清掉两条通道', () async {
      await CertTrust.check(gatewayId: 'gw', channel: 'lan', fingerprint: fp('1'));
      await CertTrust.check(gatewayId: 'gw', channel: 'remote', fingerprint: fp('2'));

      await CertTrust.forgetGateway('gw');

      expect(await CertTrust.stored(gatewayId: 'gw', channel: 'lan'), isNull);
      expect(await CertTrust.stored(gatewayId: 'gw', channel: 'remote'), isNull);
      // 清空后重新连接是 firstUse，而不是一直报「证书变了」
      final r = await CertTrust.check(gatewayId: 'gw', fingerprint: fp('3'));
      expect(r.decision, CertTrustDecision.firstUse);
    });
  });
}
