import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/workspace.dart';
import 'package:dsh_mobile/services/dsh_service.dart';

/// 「打开正在执行的会话看不到流式信息」的回归测试。
///
/// ## 缺陷本体
///
/// 流式增量块进来时有一道守卫：
///
///     if (_activeTurnSeq <= _cancelledTurnSeq) return;   // 丢弃
///
/// `_cancelledTurnSeq` 的语义是"这一轮已被取消"。`cancelActiveTurn` 把它提到
/// `_activeTurnSeq` 是对的 —— 取消之后就该校弃本轮的所有块。
///
/// 但 `selectSession` 与 `createNewSession` 也把两者设成了相等的值，于是
/// `_activeTurnSeq <= _cancelledTurnSeq` 在**刚打开的会话上恒为真**，每一个增量
/// 块都被丢掉：用户看到的是一动不动、只剩历史内容的界面。
///
/// 而从本机发送之所以正常，是因为 `sendChatMessage` 只自增 `_activeTurnSeq`
/// 而不动 `_cancelledTurnSeq`（同样的守卫就通过了）。两者行为不一致，正是这个
/// bug 活了很久的原因。
///
/// 切会话真正需要的是"丢弃上一个会话的残余块"，那由事件里的
/// `matchesSessionId(sId)` 判断负责，与 turn 计数无关。
void main() {
  SessionMeta runningSession(String id) => SessionMeta(
        sessionId: id,
        title: '正在跑的会话',
        lastPromptAt: 1700000000000,
        isRunning: true,
      );

  group('流式块准入', () {
    // 这里刻意没有"构造后立即接受"的断言：那时 _activeTurnSeq 与
    // _cancelledTurnSeq 都是 0，`0 > 0` 为假。但这是个**不可达状态** ——
    // 没有选中任何会话时，增量块在守卫之前就被 matchesSessionId 拦掉了。
    // 断言一个走不到的状态只会给人虚假的安全感。

    test('打开会话后必须仍然接受流式块（本次修复的核心）', () async {
      final dsh = DshService();
      // selectSession 内部会发 WS follow 并拉历史；测试环境里两者都失败，但异常
      // 被它自己吞掉（只写 _lastError），所以这里能完整走一遍真实代码路径。
      await dsh.selectSession(runningSession('s1'));

      expect(
        dsh.debugAcceptsStreamChunks,
        isTrue,
        reason: '打开一个正在执行的会话后，流式增量必须还能进来 —— '
            '旧代码在这里把 _cancelledTurnSeq 一起提上来，导致全部被丢弃',
      );
    });

    test('连开两个会话后仍然接受', () async {
      final dsh = DshService();
      await dsh.selectSession(runningSession('s1'));
      await dsh.selectSession(runningSession('s2'));
      expect(dsh.debugAcceptsStreamChunks, isTrue);
    });

    test('新建会话后仍然接受（同一处反模式，别只修一半）', () async {
      final dsh = DshService();
      await dsh.createNewSession();
      expect(dsh.debugAcceptsStreamChunks, isTrue);
    });
  });

  group('取消仍然必须丢弃本轮的块（守卫方向没错，别改坏）', () {
    test('取消后拒绝流式块', () async {
      final dsh = DshService();
      await dsh.selectSession(runningSession('s1'));
      expect(dsh.debugAcceptsStreamChunks, isTrue, reason: '前置条件');

      // 不 await：取消的客户端状态切换是同步发生在函数开头的，后面的网络部分
      // 在测试环境里会失败，但这正是我们要的同步行为。
      unawaited(dsh.cancelActiveTurn());

      expect(
        dsh.debugAcceptsStreamChunks,
        isFalse,
        reason: '取消后本轮的残余块必须被丢掉，否则界面会继续增长出已取消的内容',
      );
    });
  });

  group('发送路径本来就是对的（对照，防止我改错方向）', () {
    test('发送后接受流式块', () async {
      final dsh = DshService();
      await dsh.selectSession(runningSession('s1'));
      dsh.sendChatMessage('hi');
      // sendChatMessage 只自增 _activeTurnSeq，不动 _cancelledTurnSeq。
      expect(dsh.debugAcceptsStreamChunks, isTrue);
    });
  });
}
