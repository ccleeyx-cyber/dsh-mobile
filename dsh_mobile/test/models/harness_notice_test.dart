import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/harness_notice.dart';

/// 注入通知的判定层测试（2026-10-17）。
///
/// 起因：用户在手机上看到一条蓝色右对齐的"自己发的消息"，内容是
/// `Background subagent … finished … Its closing message: …`。它 `role` 真的是
/// `user` —— 引擎把子代理结算通知以 user/message 的形式写进了会话日志。
///
/// 这一层的失败模式有两个方向，两边都要钉住：
/// * **漏判**：通知落回用户气泡，看起来像"我发过这段话"（用户报的就是这个）。
/// * **误判**：把用户真的打出来的字当成通知并折叠掉 —— 这个更糟，因为它会吞掉
///   用户的输入，而且只在这种"用户恰好引用了这段文案"的时候发生。
void main() {
  const settlement =
      'Background subagent 915eb2f4-0d12-4b86-8922-b2b26cfc3ecc finished and will do no '
      'further work unless you send it more.Its closing message:2026-10-06 | 修复考勤报表；'
      '新增绩效报表正常开班小组课班级数';

  group('HarnessNotice.tryParse（文案兜底）', () {
    test('认出子代理结算通知：kind / variant / childId / 收尾正文', () {
      final notice = HarnessNotice.tryParse(settlement);
      expect(notice, isNotNull);
      expect(notice!.kind, 'subagent-settlement');
      expect(notice.variant, 'completed');
      expect(notice.childId, '915eb2f4-0d12-4b86-8922-b2b26cfc3ecc');
      expect(notice.shortChildId, '915eb2f4');
      expect(notice.body, startsWith('2026-10-06 | 修复考勤报表'));
      expect(notice.body, isNot(contains(HarnessNotice.closingMarker)));
    });

    test('aborted / max-tokens 认得出，认不出的分支退化成 unknown', () {
      expect(
        HarnessNotice.tryParse('Background subagent a1 was stopped before it finished.')!.variant,
        'aborted',
      );
      expect(
        HarnessNotice.tryParse('Background subagent a1 ran out of room before it finished.')!.variant,
        'max-tokens',
      );
      expect(
        HarnessNotice.tryParse('Background subagent a1 sent a new request to the parent.')!.variant,
        'unknown',
      );
    });

    test('没有 `Its closing message:` 时 body 是 null（不是空串）', () {
      final notice = HarnessNotice.tryParse('Background subagent a1 was stopped before it finished.');
      expect(notice!.body, isNull);
    });

    test('锚定开头 —— 用户正文里提到这段文案不算通知', () {
      expect(HarnessNotice.tryParse('帮我看看 Background subagent 这句是什么意思'), isNull);
      expect(HarnessNotice.tryParse('\n  Background subagent a1 finished'), isNotNull,
          reason: '前后空白不影响锚定；trim 之后仍在开头');
      expect(HarnessNotice.tryParse('普通提问'), isNull);
      expect(HarnessNotice.tryParse(''), isNull);
    });
  });

  group('HarnessNotice.resolve（网关标记优先）', () {
    test('网关给了 kind 就用网关的，哪怕正文认不出来', () {
      final notice = HarnessNotice.resolve(kind: 'agent-instructions', content: '一段看不出种类的注入');
      expect(notice!.kind, 'agent-instructions');
    });

    test('网关给了 kind 时，正文里的文案不影响种类判定', () {
      final notice = HarnessNotice.resolve(kind: 'plugin:user-approval', content: settlement);
      expect(notice!.kind, 'plugin:user-approval');
    });

    test('mayBeNotice=false（非 user 角色 / 上下文块）时不做文案兜底', () {
      expect(HarnessNotice.resolve(content: settlement, mayBeNotice: false), isNull);
    });
  });

  group('ChatMessage 集成', () {
    ChatMessage make(String content, {String role = 'user', String? kind}) => ChatMessage(
          id: 'm1',
          role: role,
          content: content,
          noticeKind: kind,
        );

    test('user 角色 + 结算文案 → isHarnessNotice，notice 可用', () {
      final msg = make(settlement);
      expect(msg.isHarnessNotice, isTrue);
      expect(msg.isUser, isTrue, reason: 'role 仍然是 user：其它按 role 走的逻辑不受影响');
      expect(msg.notice!.kind, 'subagent-settlement');
      expect(msg.notice!.shortChildId, '915eb2f4');
    });

    test('assistant 角色永远不会被判成通知', () {
      final msg = make(settlement, role: 'assistant');
      expect(msg.isHarnessNotice, isFalse);
      expect(msg.notice, isNull);
    });

    test('普通用户消息不受影响', () {
      final msg = make('帮我把登录接口改成异步');
      expect(msg.isHarnessNotice, isFalse);
      expect(msg.isUser, isTrue);
      expect(msg.notice, isNull);
    });

    test('网关字段优先于文案：网关说是插件通知就听网关的', () {
      final msg = make(settlement, kind: 'plugin:user-approval');
      expect(msg.notice!.kind, 'plugin:user-approval');
      expect(msg.noticeVariant, isNull, reason: '网关没给 variant 就不该编一个');
    });

    test('上下文/记忆块不会被当成通知（它们走折叠卡片那条路）', () {
      final msg = ChatMessage(
        id: 'm2',
        role: 'user',
        content: settlement,
        isContext: true,
      );
      expect(msg.isHarnessNotice, isFalse);
      expect(msg.isContextOrMemory, isTrue);
    });
  });
}
