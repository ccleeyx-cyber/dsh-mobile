import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/approval_request.dart';
import '../models/permission_config.dart';
import '../models/audit_log.dart';
import '../services/dsh_service.dart';
import '../widgets/approval_card.dart';

class SecurityPermissionsView extends StatefulWidget {
  const SecurityPermissionsView({super.key});

  @override
  State<SecurityPermissionsView> createState() => _SecurityPermissionsViewState();
}

class _SecurityPermissionsViewState extends State<SecurityPermissionsView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final dsh = Provider.of<DshService>(context, listen: false);
      dsh.fetchPermissions();
      dsh.fetchApprovals();
      dsh.fetchAuditLogs();
    });
  }

  String _formatTime(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return DateFormat('HH:mm:ss').format(dt);
    }
    return DateFormat('MM-dd HH:mm').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final permissions = dsh.permissions;
    final pendingApprovals = dsh.pendingApprovals;
    final auditLogs = dsh.auditLogs;

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFFE5E7EB), height: 1),
        ),
        title: const Row(
          children: [
            Icon(Icons.security_rounded, color: Color(0xFF0078D4)),
            SizedBox(width: 8),
            Text(
              '权限与安全中心',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF4B5563)),
            tooltip: '刷新安全状态',
            onPressed: () {
              dsh.fetchApprovals();
              dsh.fetchPermissions();
              dsh.fetchAuditLogs();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        children: [
          // 1. Pending Approvals Section
          _buildSectionHeader('待处理权限审批 (Pending Approvals)', Icons.pending_actions_rounded, const Color(0xFFD97706)),
          const SizedBox(height: 8),
          if (pendingApprovals.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.02),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: const Row(
                children: [
                  Icon(Icons.verified_user_rounded, color: Color(0xFF10B981), size: 28),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '安全状态良好',
                          style: TextStyle(color: Color(0xFF111827), fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '所有后台操作已就绪，当前无阻塞性工具审批请求。',
                          style: TextStyle(color: Color(0xFF6B7280), fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else
            ...pendingApprovals.map((req) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ApprovalCard(
                  request: req,
                  onRespond: (r, outcome, [reason]) => dsh.respondApproval(r, outcome, reason: reason),
                ),
              );
            }),

          const SizedBox(height: 24),

          // 2. Global Execution & Security Policy Matrix
          _buildSectionHeader('全局默认执行策略 (Execution Policies)', Icons.tune_rounded, const Color(0xFF0078D4)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE5E7EB)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.02),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '终端命令默认放行规则 (Default Shell Policy)',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
                ),
                const SizedBox(height: 10),

                // Policy: Ask
                _buildPolicyRadioTile(
                  title: '🛡️ 每次询问 (Ask Every Time)',
                  subtitle: '最安全。任何工具执行均触发手机审批通知',
                  value: 'ask',
                  groupValue: permissions.defaultPolicy,
                  onChanged: (val) async {
                    if (val == null) return;
                    final updated = permissions.copyWith(defaultPolicy: val);
                    final ok = await dsh.updatePermissions(updated);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).clearSnackBars();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(ok ? '已切换默认策略为: 每次询问' : '切换失败: ${dsh.lastError}'),
                          duration: const Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),

                // Policy: Auto Read
                _buildPolicyRadioTile(
                  title: '🔍 自动放行只读命令 (Auto Read-Only)',
                  subtitle: '推荐。ls, grep, cat, dir, find, git status 免确认运行',
                  value: 'auto-read',
                  groupValue: permissions.defaultPolicy,
                  onChanged: (val) async {
                    if (val == null) return;
                    final updated = permissions.copyWith(defaultPolicy: val);
                    final ok = await dsh.updatePermissions(updated);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).clearSnackBars();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(ok ? '已切换默认策略为: 自动放行只读' : '切换失败: ${dsh.lastError}'),
                          duration: const Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),

                // Policy: Danger Full Access
                _buildPolicyRadioTile(
                  title: '⚡ 全信任全自动模式 (Danger Full Access)',
                  subtitle: '全自动执行所有命令，无需人工确认',
                  value: 'danger-full-access',
                  groupValue: permissions.defaultPolicy,
                  onChanged: (val) async {
                    if (val == null) return;
                    final updated = permissions.copyWith(defaultPolicy: val);
                    final ok = await dsh.updatePermissions(updated);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).clearSnackBars();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(ok ? '已切换默认策略为: 全信任全自动' : '切换失败: ${dsh.lastError}'),
                          duration: const Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),

                const SizedBox(height: 14),
                const Divider(color: Color(0xFFE5E7EB)),
                const SizedBox(height: 10),

                // Sandbox Escalation Toggle
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: const Color(0xFF0078D4),
                  title: const Text('允许沙箱提权执行 (Privilege Escalation)', style: TextStyle(fontSize: 14, color: Color(0xFF1F2937))),
                  subtitle: const Text('允许 DSH 智能体执行需要管理员权限的命令', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                  value: permissions.sandboxMode == 'danger-full-access',
                  onChanged: (val) async {
                    final updated = permissions.copyWith(
                      sandboxMode: val ? 'danger-full-access' : 'workspace-write',
                    );
                    final ok = await dsh.updatePermissions(updated);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).clearSnackBars();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(ok ? (val ? '已开启沙箱提权执行' : '已关闭沙箱提权执行') : '更新失败: ${dsh.lastError}'),
                          duration: const Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),

                // Git & Protected Directory Protection Toggle
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: const Color(0xFF0078D4),
                  title: const Text('敏感目录防护 (Protected Path Guard)', style: TextStyle(fontSize: 14, color: Color(0xFF1F2937))),
                  subtitle: const Text('拦截对 .git, .dsh, 系统根目录等敏感路径的覆盖写操作', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                  value: permissions.protectGit,
                  onChanged: (val) async {
                    final updated = permissions.copyWith(protectGit: val);
                    final ok = await dsh.updatePermissions(updated);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).clearSnackBars();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(ok ? (val ? '已开启敏感目录保护' : '已关闭敏感目录保护') : '更新失败: ${dsh.lastError}'),
                          duration: const Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // 3. Security Audit Log History
          _buildSectionHeader('操作审计日志 (Audit Trail)', Icons.history_rounded, const Color(0xFF7C3AED)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE5E7EB)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.02),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: auditLogs.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                       child: Text('暂无历史审计记录', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13)),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: auditLogs.length,
                    separatorBuilder: (context, index) => const Divider(color: Color(0xFFE5E7EB), height: 12),
                    itemBuilder: (context, index) {
                      final item = auditLogs[index];
                      return _buildAuditLogTile(item);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
        ),
      ],
    );
  }

  Widget _buildPolicyRadioTile({
    required String title,
    required String subtitle,
    required String value,
    required String groupValue,
    required ValueChanged<String?> onChanged,
  }) {
    final isSelected = value == groupValue;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0078D4).withOpacity(0.08) : Colors.white,
          border: Border.all(
            color: isSelected ? const Color(0xFF0078D4) : const Color(0xFFE5E7EB),
            width: isSelected ? 1.5 : 1.0,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Radio<String>(
              value: value,
              groupValue: groupValue,
              onChanged: onChanged,
              activeColor: const Color(0xFF0078D4),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? const Color(0xFF0078D4) : const Color(0xFF1F2937),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuditLogTile(AuditLogItem item) {
    Color outcomeColor;
    String outcomeText;
    switch (item.outcome) {
      case 'allowed-once':
        outcomeColor = const Color(0xFF16A34A);
        outcomeText = '已授权放行';
        break;
      case 'auto-approved':
        outcomeColor = const Color(0xFF0284C7);
        outcomeText = '只读自动放行';
        break;
      case 'rejected':
        outcomeColor = const Color(0xFFDC2626);
        outcomeText = '已拦截拒绝';
        break;
      case 'pending':
      default:
        outcomeColor = const Color(0xFFD97706);
        outcomeText = '等待审批中';
        break;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: outcomeColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: outcomeColor.withOpacity(0.3)),
          ),
          child: Text(
            outcomeText,
            style: TextStyle(color: outcomeColor, fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    item.toolName,
                    style: const TextStyle(color: Color(0xFF1F2937), fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Text(
                    _formatTime(item.time),
                    style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 10),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                item.command,
                style: const TextStyle(color: Color(0xFF4B5563), fontSize: 11, fontFamily: 'monospace'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (item.reason != null && item.reason!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    item.reason!,
                    style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 10),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
