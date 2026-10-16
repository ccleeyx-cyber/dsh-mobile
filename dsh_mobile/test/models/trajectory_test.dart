import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/models/trajectory.dart';

/// 轨迹模型的回归测试。
///
/// 这一层的失败模式不是"崩了"，而是**把未知说成已知**：耗时算不出来却显示 0s、
/// 历史轮的 token 补一个 0、上下文块被当成 Agent 的动作。所以下面每一组都同时
/// 钉住"该有值的必须有值"和"该是 null 的必须是 null"。
void main() {
  final t0 = DateTime(2026, 10, 16, 22, 0, 0);
  final t1 = DateTime(2026, 10, 16, 22, 0, 3);
  final t2 = DateTime(2026, 10, 16, 22, 1, 0);
  final t3 = DateTime(2026, 10, 16, 22, 1, 2);
  final t4 = DateTime(2026, 10, 16, 22, 5, 0);

  ChatMessage msg({
    required String id,
    required String role,
    String content = '',
    String? thinking,
    List<ToolExecution>? tools,
    required DateTime at,
    int? seq,
  }) =>
      ChatMessage(
        id: id,
        role: role,
        content: content,
        thinking: thinking,
        tools: tools,
        timestamp: at,
        seq: seq,
      );

  group('分组：用户消息开新轮', () {
    test('两条用户消息 → 两轮，且各自的事件不串轮', () {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: '第一条', at: t0),
        msg(
          id: 'a1',
          role: 'assistant',
          content: '收到',
          tools: [ToolExecution(name: 'bash', input: 'ls', output: 'ok', isRunning: false)],
          at: t1,
        ),
        msg(id: 'u2', role: 'user', content: '第二条', at: t2),
        msg(id: 'a2', role: 'assistant', content: '好的', at: t3),
      ]);

      expect(traj.turns.length, 2);
      expect(traj.turns[0].index, 1);
      expect(traj.turns[1].index, 2);
      expect(traj.turns[0].toolCount, 1);
      expect(traj.turns[1].toolCount, 0);
      expect(traj.turns[0].actionEvents.map((e) => e.kind), [
        TrajectoryEventKind.user,
        TrajectoryEventKind.tool,
        TrajectoryEventKind.reply,
      ]);
      // 第二轮的事件绝不能跑到第一轮里。
      expect(traj.turns[1].actionEvents.first.preview, '第二条');
    });

    test('会话开头的上下文块不额外占一轮，被并入第 1 轮', () {
      final traj = Trajectory.build([
        msg(id: 'c1', role: 'system', content: '<runtime-memory-file>x</runtime-memory-file>', at: t0),
        msg(id: 'u1', role: 'user', content: '开始', at: t1),
      ]);

      expect(traj.turns.length, 1, reason: '开头只有上下文时不该多造一轮');
      expect(traj.turns.single.contextEvents.length, 1);
      expect(traj.turns.single.actionEvents.length, 1);
      expect(traj.contextEventCount, 1);
    });

    test('同一 id 的重复消息只算一次（reconcile 会重复搬运）', () {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: '一次', at: t0),
        msg(id: 'u1', role: 'user', content: '一次', at: t0),
      ]);
      expect(traj.turns.length, 1);
      expect(traj.turns.single.actionEvents.length, 1);
    });

    test('引擎注入的通知不会凭空开一轮（它 role 是 user）', () {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: '开始', at: t0),
        msg(id: 'a1', role: 'assistant', content: '好', at: t1),
        // 子代理结算通知：role 是 user，但没人打过这些字。
        msg(
          id: 'n1',
          role: 'user',
          content: 'Background subagent 915eb2f4-0d12-4b86-8922-b2b26cfc3ecc finished and will '
              'do no further work unless you send it more.Its closing message:做完了',
          at: t2,
        ),
        msg(id: 'a2', role: 'assistant', content: '继续', at: t3),
      ]);

      expect(traj.turns.length, 1, reason: '通知既不是用户输入也不是 agent 动作，不能开新一轮');
      // 本轮的动作只有：用户开的头 + 两条助手回复（通知不在这里面）。
      expect(traj.turns.single.actionEvents.map((e) => e.label), ['你', '回复', '回复']);
      expect(traj.contextEventCount, 1, reason: '但它必须仍然可被计数，不能静默消失');
      expect(traj.turns.single.contextEvents.single.label, '通知');
      expect(traj.turns.single.contextEvents.single.preview, '做完了');
    });
  });

  group('耗时：取不到就是 null，绝不补一个假的 0', () {
    test('首末事件时间差即本轮耗时', () {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: '跑一下', at: t0),
        msg(id: 'a1', role: 'assistant', content: '好了', at: t3),
      ]);
      expect(traj.turns.single.duration, const Duration(minutes: 1, seconds: 2));
      expect(traj.totalDuration, const Duration(minutes: 1, seconds: 2));
    });

    test('只有一条用户消息（还没回复）→ 耗时不可用', () {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: '刚发出去', at: t0),
      ]);
      expect(traj.turns.single.duration, isNull);
      expect(traj.turns.single.timedEventCount, 1);
    });

    test('所有事件同一时刻 → 耗时不可用（0 秒差不可信）', () {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: 'a', at: t0),
        msg(id: 'a1', role: 'assistant', content: 'b', at: t0),
      ]);
      expect(traj.turns.single.duration, isNull);
    });

    test('总耗时只在每一轮都有数据时才给出（部分求和会被误读）', () {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: 'a', at: t0),
        msg(id: 'a1', role: 'assistant', content: 'b', at: t1),
        msg(id: 'u2', role: 'user', content: 'c', at: t2),
        // 第二轮只有用户消息 → 无耗时
      ]);
      expect(traj.turns[0].duration, isNotNull);
      expect(traj.turns[1].duration, isNull);
      expect(traj.totalDuration, isNull, reason: '缺一轮就不给总和');
      expect(traj.timedTurnCount, 1);
    });

    test('运行中的轮不封口，但能算出"已经跑了多久"', () {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: '跑一个长任务', at: t0),
        msg(id: 'a1', role: 'assistant', content: '开始', at: t1),
      ], running: true);

      expect(traj.turns.single.running, isTrue);
      expect(traj.turns.single.duration, isNull, reason: '还没结束就没有结束时间');
      expect(traj.hasRunningTurn, isTrue);
      expect(
        traj.turns.single.elapsedAt(t4),
        const Duration(minutes: 5),
        reason: '进行中的轮按"第一个事件到现在"计算',
      );
    });
  });

  group('token：只挂在最后一轮', () {
    test('liveTurnTokens 只给最后一轮，历史轮保持 null', () {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: 'a', at: t0),
        msg(id: 'a1', role: 'assistant', content: 'b', at: t1),
        msg(id: 'u2', role: 'user', content: 'c', at: t2),
        msg(id: 'a2', role: 'assistant', content: 'd', at: t3),
      ], liveTurnTokens: 12400);

      expect(traj.turns[0].tokens, isNull, reason: '引擎不提供历史轮用量，不许补 0');
      expect(traj.turns[1].tokens, 12400);
    });

    test('读数为 0 视为"没有数据"，不是"这一轮免费"', () {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: 'a', at: t0),
        msg(id: 'a1', role: 'assistant', content: 'b', at: t1),
      ], liveTurnTokens: 0);
      expect(traj.turns.single.tokens, isNull);
    });
  });

  group('工具事件', () {
    test('工具顺序保留，参数与结果都进 detail', () {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: 'x', at: t0),
        msg(
          id: 'a1',
          role: 'assistant',
          at: t1,
          tools: [
            ToolExecution(name: 'bash', input: 'ls -la', output: 'file1\nfile2', isRunning: false),
            ToolExecution(name: 'read', input: 'a.dart', output: '...', isRunning: true),
          ],
        ),
      ]);

      final tools = traj.turns.single.actionEvents
          .where((e) => e.kind == TrajectoryEventKind.tool)
          .toList();
      expect(tools.map((e) => e.label), ['bash', 'read']);
      expect(tools[0].detail, contains('参数'));
      expect(tools[0].detail, contains('ls -la'));
      expect(tools[0].detail, contains('结果'));
      expect(tools[0].detail, contains('file1'));
      expect(tools[0].running, isFalse);
      expect(tools[1].running, isTrue);
      expect(tools[1].preview, '运行中…');
      expect(traj.toolCount, 2);
    });

    test('思考与回复各自成事件，思考在工具之前（消息结构里的顺序）', () {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: 'x', at: t0),
        msg(
          id: 'a1',
          role: 'assistant',
          thinking: '先看看目录',
          content: '看完了',
          tools: [ToolExecution(name: 'bash', input: 'ls', output: 'ok', isRunning: false)],
          at: t1,
        ),
      ]);
      expect(traj.turns.single.actionEvents.map((e) => e.kind), [
        TrajectoryEventKind.user,
        TrajectoryEventKind.thinking,
        TrajectoryEventKind.tool,
        TrajectoryEventKind.reply,
      ]);
    });

    test('工具无参数无结果时不产生可展开内容', () {
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: 'x', at: t0),
        msg(
          id: 'a1',
          role: 'assistant',
          at: t1,
          tools: [ToolExecution(name: 'noop', isRunning: false)],
        ),
      ]);
      final tool = traj.turns.single.actionEvents.firstWhere((e) => e.kind == TrajectoryEventKind.tool);
      expect(tool.expandable, isFalse);
    });
  });

  group('空与摘要', () {
    test('没有消息 → 空轨迹', () {
      final traj = Trajectory.build(const []);
      expect(traj.isEmpty, isTrue);
      expect(traj.totalDuration, isNull);
      expect(traj.actionEventCount, 0);
    });

    test('摘要折叠空白并截断，原文留在 detail 里', () {
      final long = List.generate(30, (i) => '第$i行').join('\n');
      final traj = Trajectory.build([
        msg(id: 'u1', role: 'user', content: long, at: t0),
        msg(id: 'a1', role: 'assistant', content: 'ok', at: t1),
      ]);
      final user = traj.turns.single.actionEvents.first;
      expect(user.preview, '第0行');
      expect(user.preview.contains('\n'), isFalse);
      expect(user.detail, long, reason: '展开内容必须是原文');

      expect(TrajectoryEvent.summarise('a\n\n  b   c'), 'a b c');
      expect(TrajectoryEvent.summarise('x' * 200).endsWith('…'), isTrue);
      expect(TrajectoryEvent.firstLine('\n\n  第一行  \n第二行'), '第一行');
      expect(TrajectoryEvent.firstLine('   '), '');
    });
  });
}
