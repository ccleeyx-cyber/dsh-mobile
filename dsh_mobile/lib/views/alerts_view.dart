import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/dsh_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// 「告警收件箱」（v1.35 / 3.4）。
///
/// 网关按规则把「回合失败 / 上下文过高 / 引擎掉线 / 作业失败」记进收件箱；
/// critical 还会走 ntfy 推送。这一页解决的是**打开 App 之后去哪看**的问题：
/// 推送只告诉你"出事了"，收件箱要能回答"出过哪些事、哪些还没看"。
///
/// 空态刻意不显示「0」——0 条告警是好消息，不是需要被量化的指标。
class AlertsView extends StatefulWidget {
  const AlertsView({super.key});

  @override
  State<AlertsView> createState() => _AlertsViewState();
}

class _AlertsViewState extends State<AlertsView> {
  bool _loading = true;
  bool _marking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final dsh = Provider.of<DshService>(context, listen: false);
    await dsh.refreshAlerts();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _markAll() async {
    setState(() => _marking = true);
    final dsh = Provider.of<DshService>(context, listen: false);
    await dsh.markAlertsRead(all: true);
    await dsh.refreshAlerts();
    if (mounted) setState(() => _marking = false);
  }

  @override
  Widget build(BuildContext context) {
    final dsh = context.watch<DshService>();
    final rows = dsh.alerts;

    return Scaffold(
      backgroundColor: context.c.surfaceMuted,
      appBar: AppBar(
        backgroundColor: context.c.surface,
        foregroundColor: context.c.textPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text('告警'),
        actions: [
          if (dsh.alertUnread > 0)
            TextButton(
              key: const ValueKey('alerts-mark-all'),
              onPressed: _marking ? null : _markAll,
              child: Text(_marking ? '处理中…' : '全部已读'),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : rows.isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      Icon(Icons.check_circle_outline_rounded,
                          size: 40, color: context.c.textSecondary),
                      const SizedBox(height: AppSpace.m),
                      Text(
                        '还没有告警',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: context.c.textSecondary),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '回合失败、上下文过高、引擎断连和作业失败都会记在这里。',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12.5, color: context.c.textTertiary, height: 1.45),
                      ),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
                    itemCount: rows.length,
                    itemBuilder: (ctx, i) {
                      final a = rows[i];
                      final critical = a['severity'] == 'critical';
                      final unread = a['readAt'] == null;
                      final created = a['createdAt'] is int
                          ? DateTime.fromMillisecondsSinceEpoch(a['createdAt'] as int)
                          : null;
                      return Container(
                        margin: const EdgeInsets.only(bottom: AppSpace.m),
                        padding: const EdgeInsets.all(AppSpace.m),
                        decoration: BoxDecoration(
                          color: context.c.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: unread && critical
                                ? context.c.danger.withOpacity(0.45)
                                : context.c.border,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  critical ? Icons.error_outline_rounded : Icons.info_outline_rounded,
                                  size: 16,
                                  color: critical ? context.c.danger : context.c.warning,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    a['title']?.toString() ?? '告警',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
                                    ),
                                  ),
                                ),
                                if (created != null)
                                  Text(
                                    _hhmm(created),
                                    style: TextStyle(fontSize: 11.5, color: context.c.textTertiary),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              a['message']?.toString() ?? '',
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.45,
                                color: context.c.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    );
  }

  String _hhmm(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay ? '${two(t.hour)}:${two(t.minute)}' : '${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}';
  }
}
