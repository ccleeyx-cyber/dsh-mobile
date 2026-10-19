import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/approval_request.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/services/notification_service.dart';

/// v1.35 / 2.3 —— 锁屏一键审批（App 侧纯逻辑）。
///
/// 真正弹通知需要 Android 插件，这里只钉三样最容易写错、且后果最直接的东西：
///  1. 令牌与敏感标记的解析（老网关缺字段时必须回落成"不给按钮"）；
///  2. 哪些审批配动作按钮（完全访问策略绝不能配）；
///  3. 网关结构化错误码 → 用户可读文案（过期不能被说成"失败"）。
void main() {
  ApprovalRequest req({
    String? token,
    bool sensitive = false,
  }) =>
      ApprovalRequest(
        id: 'appr_1',
        eventId: 'appr_1',
        sessionId: 'session-1',
        toolName: 'shell',
        reason: '申请执行: npm test',
        createdAt: 0,
        approvalToken: token,
        sensitive: sensitive,
      );

  group('ApprovalRequest 解析', () {
    test('带令牌与 sensitive 的载荷', () {
      final r = ApprovalRequest.fromJson({
        'id': 'appr_1',
        'eventId': 'appr_1',
        'sessionId': 's',
        'toolName': 'shell',
        'reason': 'x',
        'approvalToken': 'abc_DEF-123',
        'sensitive': false,
        'createdAt': 1,
      });
      expect(r.approvalToken, 'abc_DEF-123');
      expect(r.sensitive, isFalse);
    });

    test('老网关缺字段 → token 为 null（行为与升级前一致）', () {
      final r = ApprovalRequest.fromJson({
        'id': 'appr_1',
        'sessionId': 's',
        'toolName': 'shell',
        'reason': 'x',
        'createdAt': 1,
      });
      expect(r.approvalToken, isNull);
      expect(r.sensitive, isFalse);
    });

    test('空串令牌视为没有', () {
      final r = ApprovalRequest.fromJson({
        'id': 'appr_1',
        'sessionId': 's',
        'toolName': 'shell',
        'reason': 'x',
        'approvalToken': '   ',
        'createdAt': 1,
      });
      expect(r.approvalToken, isNull);
    });

    test('sensitive=true 时即使带令牌也不给按钮', () {
      final r = ApprovalRequest.fromJson({
        'id': 'a',
        'sessionId': 's',
        'toolName': 'shell',
        'reason': 'x',
        'approvalToken': 'tok',
        'sensitive': true,
        'createdAt': 1,
      });
      expect(r.sensitive, isTrue);
      expect(DshService.shouldOfferQuickActions(r), isFalse);
    });
  });

  group('是否给通知动作按钮', () {
    test('有令牌且非敏感 → 有按钮', () {
      expect(DshService.shouldOfferQuickActions(req(token: 'tok_123')), isTrue);
    });

    test('无令牌（老网关 / 网关未铸）→ 无按钮', () {
      expect(DshService.shouldOfferQuickActions(req()), isFalse);
    });
  });

  group('通知 payload 编解码', () {
    test('编码后再解码能还原 approvalId 与 token', () {
      const a = NotificationApprovalActions(approvalId: 'appr_9', token: 'tok-XYZ_1');
      final decoded = NotificationApprovalActions.decodePayload(a.encodePayload());
      expect(decoded, isNotNull);
      expect(decoded!.approvalId, 'appr_9');
      expect(decoded.token, 'tok-XYZ_1');
    });

    test('点按普通会话通知不会被误判成审批动作', () {
      expect(NotificationApprovalActions.decodePayload('session:approval:session-1'), isNull);
      expect(NotificationApprovalActions.decodePayload('approval:only-id'), isNull);
      expect(NotificationApprovalActions.decodePayload(''), isNull);
    });
  });

  group('网关错误码 → 用户文案', () {
    test('过期要说"过期"，不能笼统说失败', () {
      expect(DshService.approvalNoticeForResult({'ok': false, 'code': 'expired'}),
          contains('过期'));
    });

    test('敏感审批要引导回 App', () {
      expect(DshService.approvalNoticeForResult({'ok': false, 'code': 'sensitive'}),
          contains('App'));
    });

    test('相反决定已生效 → 冲突', () {
      expect(DshService.approvalNoticeForResult({'ok': false, 'code': 'conflict'}),
          contains('相反'));
    });

    test('引擎拒绝时带上原因', () {
      final msg = DshService.approvalNoticeForResult({
        'ok': false,
        'code': 'engine-rejected',
        'error': 'boom'
      });
      expect(msg, contains('boom'));
    });

    test('未知码回落到 error 字段，再回落到默认文案', () {
      expect(DshService.approvalNoticeForResult({'ok': false, 'error': 'custom'}),
          'custom');
      expect(DshService.approvalNoticeForResult({'ok': false}), contains('打开 App'));
    });
  });
}
