import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/task_center.dart';

/// 引擎 `sessionStats` 投影的解析（2026-10-17）。
///
/// 起因：用户要「用量信息跟电脑端一样显示」，而电脑端状态条第一组
/// `6 轮 351 步 · 210 tok/s` 读的是引擎的全日志投影（`sessionStats`），
/// 不是当前窗口里的消息。手机端以前完全没有这几个数字。
///
/// 这一层的失败模式是**静默错数**：把"读不到"渲染成 `0 轮 0 步`、把
/// `decodeMs == 0` 除出个 `0 tok/s`。两者都会让用户以为会话真的没跑。
void main() {
  group('SessionCounters 解析', () {
    test('八个字段照投影原名读出来', () {
      final counters = SessionCounters.fromJson({
        'turns': 6,
        'steps': 351,
        'llmMs': 120000,
        'toolMs': 45000,
        'ttftMs': 900,
        'ttftSteps': 351,
        'decodeMs': 300000,
        'decodeTokens': 63000,
      });

      expect(counters.turns, 6);
      expect(counters.steps, 351);
      expect(counters.llmMs, 120000);
      expect(counters.toolMs, 45000);
      expect(counters.ttftMs, 900);
      expect(counters.ttftSteps, 351);
      expect(counters.decodeMs, 300000);
      expect(counters.decodeTokens, 63000);
      expect(counters.hasCounts, isTrue);
    });

    test('解码速度 = decodeTokens /（decodeMs/1000），与电脑端同口径', () {
      final counters = SessionCounters.fromJson({'decodeMs': 300000, 'decodeTokens': 63000});
      expect(counters.tokensPerSecond, closeTo(210.0, 0.001));
    });

    test('decodeMs 为 0 或缺失 → 速度是 null（不是 0，也不是 Infinity）', () {
      expect(SessionCounters.fromJson({'decodeMs': 0, 'decodeTokens': 100}).tokensPerSecond, isNull);
      expect(SessionCounters.fromJson({'decodeTokens': 100}).tokensPerSecond, isNull);
      expect(SessionCounters.fromJson({'decodeMs': 100}).tokensPerSecond, isNull);
    });

    test('字段缺失不编值：turns/steps 仍是 null', () {
      final counters = SessionCounters.fromJson({});
      expect(counters.turns, isNull);
      expect(counters.steps, isNull);
      expect(counters.hasCounts, isFalse);
    });

    test('steps: 0 是合法事实（空会话），照实传 0', () {
      final counters = SessionCounters.fromJson({'turns': 0, 'steps': 0});
      expect(counters.steps, 0);
      expect(counters.hasCounts, isTrue);
    });
  });

  group('SessionStats 上的派生值', () {
    test('stats.sessionStats 里的计数被接到 turns/steps/tokensPerSecond', () {
      final stats = SessionStats.fromJson({
        'source': 'live',
        'totalTokens': 113704827,
        'uncachedInputTokens': 1063674,
        'cacheReadTokens': 112301824,
        'contextWindow': 1000000,
        'pressureTokens': 214263,
        'sessionStats': {'turns': 6, 'steps': 351, 'decodeMs': 300000, 'decodeTokens': 63000},
      });

      expect(stats.turns, 6);
      expect(stats.steps, 351);
      expect(stats.tokensPerSecond, closeTo(210.0, 0.001));
    });

    test('缓存命中率 = 缓存读取 /（未缓存输入 + 缓存读取），与电脑端 99% 一致', () {
      final stats = SessionStats.fromJson({
        'source': 'live',
        'uncachedInputTokens': 1063674,
        'cacheReadTokens': 112301824,
      });
      expect(stats.cacheHitPercent, 99);
    });

    test('没缓存复用 / 分母为 0 / 缺字段 → 缓存命中率是 null（显示时省略）', () {
      expect(
        SessionStats.fromJson({'source': 'live', 'uncachedInputTokens': 100, 'cacheReadTokens': 0}).cacheHitPercent,
        0,
      );
      expect(
        SessionStats.fromJson({'source': 'live', 'uncachedInputTokens': 0, 'cacheReadTokens': 0}).cacheHitPercent,
        isNull,
        reason: '分母为 0 时不能除零，也不能声称 0% 命中',
      );
      expect(SessionStats.fromJson({'source': 'live'}).cacheHitPercent, isNull);
    });

    test('老网关没有 sessionStats 键 → 那几个数字全是 null（界面隐藏整组）', () {
      final stats = SessionStats.fromJson({'source': 'live', 'totalTokens': 100});
      expect(stats.counters, isNull);
      expect(stats.turns, isNull);
      expect(stats.steps, isNull);
      expect(stats.tokensPerSecond, isNull);
    });
  });
}
