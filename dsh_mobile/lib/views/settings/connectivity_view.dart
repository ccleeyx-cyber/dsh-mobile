import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/gateway_health.dart';
import '../../services/dsh_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../config_page.dart';
import 'settings_widgets.dart';

/// 「连接与诊断」——把原来的两张卡合成一页。
///
/// ## 为什么合并
///
/// 旧设置页里有两个入口说同一件事：一张「网关健康」卡（跳 [GatewayHealthView]：
/// 连接态、令牌、积压、延迟、会话规模）和一段「网络与网关诊断」内联卡（地址、
/// 上游、ping 测速、重连、切换服务器）。用户想知道"为什么连不上"时，得先判断
/// 该点哪个 —— 而它们本来就是同一个问题的两种呈现。
///
/// 合并后只有一页：**先是结论（banner）→ 再是地址与延迟 → 再是动作 → 最后是
/// 逐项指标**。诊断动作（测速 / 重连 / 换服务器）与指标在同一个视野里，
/// 不需要在两个页面之间来回跳。
class ConnectivityView extends StatefulWidget {
  const ConnectivityView({super.key});

  @override
  State<ConnectivityView> createState() => _ConnectivityViewState();
}

class _ConnectivityViewState extends State<ConnectivityView> {
  bool _isTestingPing = false;

  /// 手动重连进行中（防连点 + 按钮反馈）。
  bool _reconnecting = false;

  /// 「断线重连」的确认。
  ///
  /// 重连会断开当前长连接，正在跑的回合可能收不到后续增量 —— 这不是"刷新一下"
  /// 那种无害动作，轻点就触发会让用户在一次误触里丢进度。连接本来就断着的时候
  /// 不问：那时重连是唯一出路，多一步只是添堵。
  Future<void> _confirmReconnect(DshService dsh) async {
    final cfg = dsh.currentConfig;
    if (cfg == null) return;
    if (!dsh.isConnected) {
      if (_reconnecting || !mounted) return;
      setState(() => _reconnecting = true);
      try {
        await dsh.connect(cfg);
      } finally {
        if (mounted) setState(() => _reconnecting = false);
      }
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('现在就重连？'),
        content: const Text(
            '会断开当前连接再重新握手。正在执行的回合可能收不到后续增量；'
            '如果你只是觉得界面卡住，先回对话页下拉刷新或稍等几秒通常更安全。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('重连')),
        ],
      ),
    );
    if (ok != true) return;
    if (_reconnecting || !mounted) return;
    setState(() => _reconnecting = true);
    try {
      await dsh.connect(cfg);
    } finally {
      if (mounted) setState(() => _reconnecting = false);
    }
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

  @override
  Widget build(BuildContext context) {
    final dsh = context.watch<DshService>();
    final health = _snapshot(dsh);
    final settings = dsh.settings;

    return Scaffold(
      backgroundColor: context.c.surfaceMuted,
      appBar: settingsAppBar(context, '连接与诊断'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        children: [
          _OverallBanner(health: health),
          const SizedBox(height: AppSpace.xl),

          // ---- 地址与延迟 ----
          Container(
            padding: const EdgeInsets.all(16),
            decoration: settingsCardDecoration(context),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _infoRow(context, '网关地址', dsh.currentConfig?.httpBaseUrl ?? '未配置'),
                const SizedBox(height: AppSpace.m),
                _infoRow(context, 'DSH 本地上游', settings?.dshHost ?? '127.0.0.1:3080'),
                const SizedBox(height: AppSpace.m),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('往返延迟', style: TextStyle(color: context.c.textSecondary, fontSize: 13)),
                    Row(
                      children: [
                        Text(
                          dsh.pingMs >= 0 ? '${dsh.pingMs} ms' : '未测速',
                          style: TextStyle(
                            // 按阈值**单色梯度**：<100 绿 / 100–300 橙 / >300 红。
                            color: !(dsh.pingMs >= 0)
                                ? context.c.textTertiary
                                : dsh.pingMs < 100
                                    ? context.c.success
                                    : dsh.pingMs <= 300
                                        ? context.c.warning
                                        : context.c.danger,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: AppSpace.m),
                        // 测速是**动作**，与延迟数值的颜色语义（绿/橙/红=快慢）分开：
                        // 用主蓝，避免与"延迟低=绿色"撞在一起误读成"状态良好"。
                        GestureDetector(
                          onTap: _isTestingPing
                              ? null
                              : () async {
                                  setState(() => _isTestingPing = true);
                                  await dsh.measurePing();
                                  // await 之后先查 mounted：点测速后立刻退出本页会抛
                                  // setState-after-dispose。
                                  if (!mounted) return;
                                  setState(() => _isTestingPing = false);
                                },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: context.c.accent.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: _isTestingPing
                                ? SizedBox(
                                    width: 10,
                                    height: 10,
                                    child: CircularProgressIndicator(strokeWidth: 1.5, color: context.c.accent),
                                  )
                                : Text('测速',
                                    style: TextStyle(
                                        color: context.c.accent, fontSize: 11, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.l),
                Divider(color: context.c.surfaceMuted, height: 1),
                const SizedBox(height: AppSpace.l),

                // ---- 动作 ----
                //
                // 视觉权重要跟**代价**一致，而不是跟"听起来更急"一致：
                //  * 「切换服务器」是正常下一步（改配置、换机器），频繁操作、
                //    不破坏任何东西 —— 实心主按钮。
                //  * 「断线重连」会打断正在跑的会话流，属于"要不要现在做"的决策 ——
                //    描边次按钮 + 确认弹窗。
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: context.c.textPrimary,
                          side: BorderSide(color: context.c.border),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        icon: _reconnecting
                            ? const SizedBox(
                                width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('断线重连',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                        onPressed: _reconnecting ? null : () => _confirmReconnect(dsh),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: context.c.accent,
                          foregroundColor: context.c.onAccent,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                        label: const Text('切换服务器',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        onPressed: () {
                          Navigator.push(context, MaterialPageRoute(builder: (_) => const ConfigPage()));
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSpace.l + AppSpace.xs),
          SettingsSectionHeader(
            title: '健康指标',
            icon: Icons.monitor_heart_outlined,
            color: context.c.success,
          ),
          const SizedBox(height: AppSpace.m),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: settingsCardDecoration(context),
            child: Column(
              children: [
                for (final m in health.metrics)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: _MetricRow(metric: m),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.m),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '绿点=无需处理，橙点=有人在等你处理，红点=需要修。'
              '待授权与待提问会阻塞 Agent，处理完它才会继续。',
              style: TextStyle(fontSize: AppText.body, height: 1.4, color: context.c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: context.c.textSecondary, fontSize: 13)),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(color: context.c.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// 顶部结论条：只回答一个问题 —— 现在要不要我动手。
class _OverallBanner extends StatelessWidget {
  final GatewayHealth health;
  const _OverallBanner({required this.health});

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color border, Color fg, IconData icon) = switch (health.overall) {
      HealthBad() => (
          context.c.dangerSurface,
          context.c.dangerBorder,
          context.c.danger,
          Icons.error_outline_rounded,
        ),
      HealthWarn() => (
          context.c.warningSurface,
          context.c.warningBorder,
          context.c.warning,
          Icons.warning_amber_rounded,
        ),
      _ => (
          context.c.successSurface,
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
          Icon(icon, color: fg, size: 22),
          const SizedBox(width: AppSpace.l),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  health.headline,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: fg),
                ),
                if (health.fix != null) ...[
                  const SizedBox(height: AppSpace.s),
                  Text(
                    health.fix!,
                    style: TextStyle(fontSize: AppText.body, height: 1.4, color: context.c.textSecondary),
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

/// 一项指标：左边标签 + 右边值（带一个状态点），下面一行补充说明。
class _MetricRow extends StatelessWidget {
  final HealthMetric metric;
  const _MetricRow({required this.metric});

  @override
  Widget build(BuildContext context) {
    final (Color dot, String why) = switch (metric.level) {
      HealthBad(reason: final r, fix: final f) => (context.c.danger, '$r —— $f'),
      HealthWarn(reason: final r) => (context.c.warning, r),
      _ => (context.c.success, ''),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: AppSpace.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      metric.label,
                      style: TextStyle(fontSize: 13, color: context.c.textPrimary),
                    ),
                  ),
                  Text(
                    metric.value,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                  ),
                ],
              ),
              // detail 与"为什么不健康"都放第二行：指标值本身不该承载解释。
              if (metric.detail != null || why.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  [
                    if (metric.detail != null) metric.detail!,
                    if (why.isNotEmpty) why,
                  ].join(' · '),
                  style: TextStyle(fontSize: AppText.caption, height: 1.35, color: context.c.textTertiary),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
