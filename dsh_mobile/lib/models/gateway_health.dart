/// 网关健康快照的数据模型（v1.6.0 网关健康仪表盘）。
///
/// 刻意做成**纯数据 + 纯函数**（[GatewayHealth.build]），不碰 Widget：这样
/// 「什么算健康」这套判定规则可以被单元测试穷举，而不必 pump 任何界面。
///
/// 判定规则（每一条都对应一个可执行的诊断，而不是装饰性数字）：
///
/// * **断线**（status != connected）—— 最高优先级，其余指标都没有意义。
/// * **令牌失效**（isTokenInvalid）—— 单独一档。它和"断线"症状一样但原因
///   完全不同：改令牌 5 秒能修，重连没有用。混为一谈会让用户白忙。
/// * **审批积压** —— 待授权的操作在阻塞 agent。这是"看起来卡住了"最常见的
///   真实原因，用户最需要被提醒。
/// * **提问积压** —— 同样阻塞，但走的是不同路径（§4.1 提问）。
/// * **延迟** —— ping。分三档而不是连续色带，因为用户要的是"要不要管"。
/// * **会话规模** —— 纯信息，帮助定位"列表慢"是不是因为会话太多。
sealed class HealthLevel {
  const HealthLevel();
}

/// 完全健康。
class HealthOk extends HealthLevel {
  const HealthOk();
}

/// 需要注意但不阻塞。
class HealthWarn extends HealthLevel {
  final String reason;
  const HealthWarn(this.reason);
}

/// 阻塞 / 出故障。
class HealthBad extends HealthLevel {
  final String reason;
  final String fix;
  const HealthBad(this.reason, this.fix);
}

/// 一个可展示的健康项。UI 只负责渲染，判断全在 [GatewayHealth.build]。
class HealthMetric {
  final String label;
  final String value;

  /// 简短补充说明（例如延迟的具体毫秒、会话总数）。
  final String? detail;
  final HealthLevel level;

  const HealthMetric({
    required this.label,
    required this.value,
    this.detail,
    required this.level,
  });
}

class GatewayHealth {
  final HealthLevel overall;
  final String headline;
  final String? fix;
  final List<HealthMetric> metrics;

  const GatewayHealth({
    required this.overall,
    required this.headline,
    this.fix,
    required this.metrics,
  });

  /// 由原始信号构建快照。**不 import DshService** —— 传原始值进来，这样
  /// service 与判定规则解耦，规则可以被独立穷举测试。
  static GatewayHealth build({
    required bool isConnected,
    required bool isTokenInvalid,
    required int pingMs,
    required int pendingApprovals,
    required int pendingQuestions,
    required int runningSessions,
    required int totalSessions,
    required int workspaceCount,
    required String? lastError,
  }) {
    final metrics = <HealthMetric>[];

    // --- 连接 ---
    metrics.add(HealthMetric(
      label: '连接状态',
      value: isConnected ? '已连接' : '未连接',
      level: isConnected ? const HealthOk() : const HealthBad('与网关的连接已断开', '检查网络后重连'),
    ));

    // --- 令牌 ---
    if (isTokenInvalid) {
      metrics.add(const HealthMetric(
        label: '访问令牌',
        value: '已失效',
        detail: '401 Unauthorized',
        level: HealthBad('网关拒绝了当前访问令牌', '在设置里更新令牌 —— 重连没有用'),
      ));
    } else {
      metrics.add(HealthMetric(
        label: '访问令牌',
        value: '有效',
        level: isConnected ? const HealthOk() : const HealthWarn('连接断开，令牌状态待确认'),
      ));
    }

    // --- 延迟 ---
    // pingMs < 0 表示没测出来（离线）。分三档是因为用户要的是"要不要管"。
    final pingLevel = pingMs < 0
        ? const HealthWarn('尚未测得延迟')
        : (pingMs < 300 ? const HealthOk() : (pingMs < 1000 ? const HealthWarn('延迟偏高') : const HealthBad('延迟很高', '检查网关所在机器的网络')));
    metrics.add(HealthMetric(
      label: '网关延迟',
      value: pingMs < 0 ? '—' : '$pingMs ms',
      detail: pingMs < 0 ? '未测得' : null,
      level: pingLevel,
    ));

    // --- 审批积压（阻塞 agent）---
    metrics.add(HealthMetric(
      label: '待授权操作',
      value: '$pendingApprovals',
      detail: pendingApprovals > 0 ? '正在阻塞 Agent' : null,
      level: pendingApprovals > 0 ? const HealthWarn('有操作在等你授权') : const HealthOk(),
    ));

    // --- 提问积压 ---
    metrics.add(HealthMetric(
      label: '待回答提问',
      value: '$pendingQuestions',
      detail: pendingQuestions > 0 ? 'Agent 在等一个回答' : null,
      level: pendingQuestions > 0 ? const HealthWarn('有提问等你回答') : const HealthOk(),
    ));

    // --- 会话规模 ---
    metrics.add(HealthMetric(
      label: '会话',
      value: '$totalSessions',
      detail: '其中 $runningSessions 个执行中，分布在 $workspaceCount 个工作区',
      level: const HealthOk(),
    ));

    // --- 整体判定 ---
    // 优先级：令牌失效 > 断线 > 高延迟 > 有积压 > 正常。
    // 顺序有讲究：令牌失效排在断线前面，因为它的修复动作完全不同。
    HealthLevel overall;
    String headline;
    String? fix;

    if (isTokenInvalid) {
      overall = const HealthBad('访问令牌已失效', '打开设置更新网关访问令牌');
      headline = '需要处理：令牌失效';
      fix = '网关返回 401。更新令牌后会自动恢复；单纯重连没有用。';
    } else if (!isConnected) {
      overall = const HealthBad('与网关断开', '检查网络并重连');
      headline = '需要处理：连接已断开';
      fix = lastError ?? '检查手机网络与网关可达性，然后在设置里点重连。';
    } else if (pingMs >= 1000) {
      overall = const HealthBad('网关延迟很高', '检查网络');
      headline = '需要注意：延迟 $pingMs ms';
      fix = '连接是通的但响应很慢，通常是网络或网关机器负载问题。';
    } else if (pendingApprovals > 0 || pendingQuestions > 0) {
      overall = const HealthWarn('有操作在等待你');
      headline = pendingApprovals > 0
          ? '需要注意：$pendingApprovals 个操作等待授权'
          : '需要注意：Agent 在等你回答';
      fix = 'Agent 已经停下来了，处理完这些之后它会继续。';
    } else {
      overall = const HealthOk();
      headline = '一切正常';
    }

    return GatewayHealth(overall: overall, headline: headline, fix: fix, metrics: metrics);
  }

  bool get isOk => overall is HealthOk;
}