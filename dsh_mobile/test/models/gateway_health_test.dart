import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/gateway_health.dart';

/// 网关健康仪表盘（v1.6.0）的判定逻辑测试。
///
/// 判定规则是纯函数，所以能穷举边界 —— 这是把它从 Widget 里拆出来的原因。
/// 重点：
/// * **优先级**：令牌失效 > 断线 > 高延迟 > 积压 > 正常。每条都有对应测试。
/// * **令牌失效必须排在断线前面**：症状一样但修复动作不同（改令牌 vs 重连）。
/// * **健康时不出现 fix 文案**：一个"一切正常"却带着修复建议的界面很荒谬。
void main() {
  GatewayHealth healthy({
    bool isConnected = true,
    bool isTokenInvalid = false,
    int pingMs = 80,
    int pendingApprovals = 0,
    int pendingQuestions = 0,
    int runningSessions = 0,
    int totalSessions = 10,
    int workspaceCount = 2,
    String? lastError,
  }) {
    return GatewayHealth.build(
      isConnected: isConnected,
      isTokenInvalid: isTokenInvalid,
      pingMs: pingMs,
      pendingApprovals: pendingApprovals,
      pendingQuestions: pendingQuestions,
      runningSessions: runningSessions,
      totalSessions: totalSessions,
      workspaceCount: workspaceCount,
      lastError: lastError,
    );
  }

  HealthMetric metric(GatewayHealth h, String label) =>
      h.metrics.firstWhere((m) => m.label == label);

  group('整体判定优先级', () {
    test('全部正常 → 一切正常，且没有修复建议', () {
      final h = healthy();
      expect(h.isOk, isTrue);
      expect(h.headline, '一切正常');
      expect(h.fix, isNull, reason: '健康态不该显示"该做什么"');
    });

    test('令牌失效优先于断线（症状同、修复不同）', () {
      // 断开 + 令牌失效：如果按"断线"报，用户会去点重连，白忙。
      final h = healthy(isConnected: false, isTokenInvalid: true);
      expect(h.headline, contains('令牌'));
      expect(h.fix, contains('更新'));
      // 文案里"重连"出现是为了说"别去重连"；真正要断言的是它引导用户改令牌。
      expect(h.fix, contains('重连没有用'));
    });

    test('仅断线（非令牌）→ 报断线并建议重连', () {
      final h = healthy(isConnected: false);
      expect(h.isOk, isFalse);
      expect(h.headline, contains('断开'));
      expect(h.fix, contains('重连'));
    });

    test('高延迟 → 需要处理，且优先级高于积压', () {
      final h = healthy(pingMs: 2000, pendingApprovals: 5);
      expect(h.headline, contains('延迟'));
      expect(h.fix, anyOf(contains('慢'), contains('负载')));
    });

    test('有审批积压 → 需要注意，并说明正在阻塞', () {
      final h = healthy(pendingApprovals: 3);
      expect(h.overall, isA<HealthWarn>());
      expect(h.headline, contains('3'));
      expect(metric(h, '待授权操作').detail, contains('阻塞'));
    });

    test('有提问积压 → 需要注意', () {
      final h = healthy(pendingQuestions: 1);
      expect(h.overall, isA<HealthWarn>());
      expect(h.headline, contains('等你回答'));
      expect(metric(h, '待回答提问').detail, contains('等一个回答'));
    });

    test('健康判定忽略会话规模（会话多是信息，不是故障）', () {
      final h = healthy(totalSessions: 9999, workspaceCount: 50);
      expect(h.isOk, isTrue, reason: '会话多不健康，它只是信息');
    });
  });

  group('各项指标', () {
    test('连接与令牌', () {
      final h = healthy();
      expect(metric(h, '连接状态').value, '已连接');
      expect(metric(h, '连接状态').level, isA<HealthOk>());
      expect(metric(h, '访问令牌').value, '有效');

      final off = healthy(isConnected: false, isTokenInvalid: true);
      expect(metric(off, '访问令牌').value, '已失效');
      expect(metric(off, '访问令牌').level, isA<HealthBad>());
    });

    test('延迟三档：<300 正常，300~1000 注意，≥1000 处理', () {
      expect(metric(healthy(pingMs: 50), '网关延迟').level, isA<HealthOk>());
      expect(metric(healthy(pingMs: 500), '网关延迟').level, isA<HealthWarn>());
      expect(metric(healthy(pingMs: 1500), '网关延迟').level, isA<HealthBad>());
    });

    test('未测得延迟（-1）显示占位而不是负数', () {
      final h = healthy(pingMs: -1);
      expect(metric(h, '网关延迟').value, '—');
      expect(metric(h, '网关延迟').detail, '未测得');
    });

    test('会话指标带上执行中与工作区数', () {
      final h = healthy(runningSessions: 3, totalSessions: 42, workspaceCount: 5);
      final m = metric(h, '会话');
      expect(m.value, '42');
      expect(m.detail, contains('3 个执行中'));
      expect(m.detail, contains('5 个工作区'));
    });

    test('每个指标都有 label/value/level，不允许缺字段', () {
      final h = healthy();
      expect(h.metrics, hasLength(6));
      for (final m in h.metrics) {
        expect(m.label, isNotEmpty);
        expect(m.value, isNotEmpty);
        expect(m.level, isNotNull);
      }
    });
  });

  group('诚实性', () {
    test('断线时若带 lastError 就展示它（用户最想看到这个具体错误）', () {
      final h = healthy(isConnected: false, lastError: 'WebSocket认证失败: 访问令牌无效');
      expect(h.fix, contains('WebSocket认证失败'));
    });

    test('lastError 为空串时不当成错误文案', () {
      final h = healthy(isConnected: false, lastError: '');
      expect(h.fix, isNotNull);
      expect(h.fix, isNot(contains('：')));
    });
  });
}