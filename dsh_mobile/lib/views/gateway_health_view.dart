import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/gateway_health.dart';
import '../services/dsh_service.dart';

/// 网关健康仪表盘（v1.6.0）。
///
/// 只读 + 一个"刷新"按钮：不提供任何"修复"动作。每个可执行的修复（更新令牌 /
/// 重连）都已经存在于它对应的地方 —— 在这里再造一份会让用户困惑该去哪。
class GatewayHealthView extends StatefulWidget {
  const GatewayHealthView({super.key});

  @override
  State<GatewayHealthView> createState() => _GatewayHealthViewState();
}

class _GatewayHealthViewState extends State<GatewayHealthView> {
  @override
  Widget build(BuildContext context) {
    final dsh = context.watch<DshService>();
    final health = _snapshot(dsh);

    return Scaffold(
      appBar: AppBar(
        title: const Text('网关健康'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () async {
              await dsh.measurePing();
              await dsh.fetchWorkspaces();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已刷新'),
                    duration: Duration(milliseconds: 900),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _OverallBanner(health: health),
          const SizedBox(height: 16),
          ...health.metrics.map((m) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _MetricTile(metric: m),
              )),
          const SizedBox(height: 8),
          _Legend(),
        ],
      ),
    );
  }

  GatewayHealth _snapshot(DshService dsh) {
    var running = 0;
    var total = 0;
    for (final ws in dsh.workspaces) {
      total += ws.sessions.length;
      for (final s in ws.sessions) {
        if (s.isRunning) running++;
      }
    }
    return GatewayHealth.build(
      isConnected: dsh.isConnected,
      isTokenInvalid: dsh.isTokenInvalid,
      pingMs: dsh.pingMs,
      pendingApprovals: dsh.pendingApprovals.length,
      pendingQuestions: dsh.pendingQuestions.length,
      runningSessions: running,
      totalSessions: total,
      workspaceCount: dsh.workspaces.length,
      lastError: dsh.lastError.isEmpty ? null : dsh.lastError,
    );
  }
}

class _OverallBanner extends StatelessWidget {
  final GatewayHealth health;
  const _OverallBanner({required this.health});

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color border, Color fg, IconData icon) = switch (health.overall) {
      HealthBad() => (
          const Color(0xFFFEF2F2),
          const Color(0xFFFECACA),
          const Color(0xFFB91C1C),
          Icons.error_outline_rounded,
        ),
      HealthWarn() => (
          const Color(0xFFFFFBEB),
          const Color(0xFFFDE68A),
          const Color(0xFFB45309),
          Icons.warning_amber_rounded,
        ),
      _ => (
          const Color(0xFFDCFCE7),
          const Color(0xFF86EFAC),
          const Color(0xFF15803D),
          Icons.check_circle_outline_rounded,
        ),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border, width: 1.2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 24, color: fg),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  health.headline,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: fg),
                ),
                if (health.fix != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    health.fix!,
                    style: TextStyle(fontSize: 12.5, height: 1.5, color: fg.withOpacity(0.9)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final HealthMetric metric;
  const _MetricTile({required this.metric});

  @override
  Widget build(BuildContext context) {
    final Color dot = switch (metric.level) {
      HealthBad() => const Color(0xFFDC2626),
      HealthWarn() => const Color(0xFFF59E0B),
      _ => const Color(0xFF10B981),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 5),
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  metric.label,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                ),
                const SizedBox(height: 2),
                Text(
                  metric.value,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111827),
                  ),
                ),
                if (metric.detail != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    metric.detail!,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF), height: 1.4),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const items = [
      (Color(0xFF10B981), '正常'),
      (Color(0xFFF59E0B), '需要注意'),
      (Color(0xFFDC2626), '需要处理'),
    ];
    return Row(
      children: [
        for (final (c, label) in items) ...[
          Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 10.5, color: Color(0xFF9CA3AF))),
          const SizedBox(width: 14),
        ],
      ],
    );
  }
}