import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/models/remote_access.dart';

/// 「远程接入」状态模型（[refactor 2026-10-21]）。
///
/// 这份状态是 App 唯一的真相来源：通道怎么起是服务端的事，客户端只负责把
/// provider / 地址 / 就绪与否如实显示出来。所以这里钉的是**解析的宽容度**与
/// **人话标签**——解析错一处，界面上就会出现"看起来开通了其实没通"。
void main() {
  group('RemoteAccessState', () {
    test('cloudflared 已就绪：地址与 ready 都取自网关', () {
      final s = RemoteAccessState.fromJson({
        'ok': true,
        'provider': 'cloudflared',
        'managed': 'gateway',
        'publicUrl': 'https://random-words.trycloudflare.com',
        'localUrl': 'http://192.168.1.10:3088',
        'ready': true,
        'reason': '',
        'tlsPort': 3443,
        'certFingerprint': 'AB:CD',
      });
      expect(s.providerLabel, '临时隧道（cloudflared）');
      expect(s.managedLabel, '由网关自动建立');
      expect(s.publicUrl, 'https://random-words.trycloudflare.com');
      expect(s.ready, isTrue);
      expect(s.reason, isEmpty);
      expect(s.tlsPort, 3443);
      expect(s.certFingerprint, 'AB:CD');
    });

    test('nps 未加密时 ready 仍为 true，但 reason 带出明文风险', () {
      final s = RemoteAccessState.fromJson({
        'provider': 'nps',
        'managed': 'external',
        'publicUrl': 'http://n.example.com:3088',
        'localUrl': 'http://192.168.1.10:3088',
        'ready': true,
        'reason': 'NPS 走明文：token 会裸露在公网，建议在 NPS 上启用 HTTPS',
      });
      expect(s.providerLabel, '自建反向代理（NPS）');
      expect(s.managedLabel, '由你的反向代理提供');
      expect(s.ready, isTrue, reason: '配置完整就是 ready —— 网关无法验证外部反代');
      expect(s.reason, contains('明文'));
    });

    test('none：publicUrl 为 null，不能把空串当地址显示', () {
      final s = RemoteAccessState.fromJson({
        'provider': 'none',
        'managed': 'none',
        'publicUrl': null,
        'localUrl': 'http://192.168.1.10:3088',
        'ready': false,
        'reason': '未选择远程通道：只有同一局域网内的手机能连',
      });
      expect(s.publicUrl, isNull);
      expect(s.ready, isFalse);
      expect(s.providerLabel, '未开启（仅局域网）');
      expect(s.managedLabel, '未配置');
    });

    test('字段缺失/类型不对也不崩（老网关或降级响应）', () {
      final s = RemoteAccessState.fromJson(const <String, dynamic>{});
      expect(s.provider, 'none');
      expect(s.publicUrl, isNull);
      expect(s.tlsPort, 0);
      expect(s.certFingerprint, isNull);
      expect(s.localUrl, isEmpty);
    });

    test('空字符串的 publicUrl 归一成 null', () {
      final s = RemoteAccessState.fromJson({'provider': 'cloudflared', 'publicUrl': ''});
      expect(s.publicUrl, isNull);
    });
  });
}
