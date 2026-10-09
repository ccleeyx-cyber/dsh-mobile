import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/audit_log.dart';
import '../models/approval_preset.dart';
import '../models/permission_config.dart';
import '../services/dsh_service.dart';
import '../widgets/approval_card.dart';
import '../theme/app_colors.dart';

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
      backgroundColor: context.c.surfaceMuted,
      appBar: AppBar(
        backgroundColor: context.c.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: context.c.border, height: 1),
        ),
        title: Row(
          children: [
            Icon(Icons.security_rounded, color: context.c.accent),
            SizedBox(width: 8),
            Text(
              '权限与安全中心',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.c.textPrimary),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: context.c.textPrimary),
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
          _buildSectionHeader('待处理权限审批 (Pending Approvals)', Icons.pending_actions_rounded, context.c.warning),
          const SizedBox(height: 8),
          if (pendingApprovals.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              decoration: BoxDecoration(
                color: context.c.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: context.c.success.withOpacity(0.3)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.02),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Icon(Icons.verified_user_rounded, color: context.c.success, size: 28),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '安全状态良好',
                          style: TextStyle(color: context.c.textPrimary, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '所有后台操作已就绪，当前无阻塞性工具审批请求。',
                          style: TextStyle(color: context.c.textSecondary, fontSize: 12),
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

          // 1.5 审批预设 (v1.4.2)
          //
          // 放在四个原始开关之前，因为预设回答的是用户真正在问的问题
          // （"我该用哪个档位"），而下面四个开关回答的是另一个问题
          // （"把这个具体值改掉"）。反过来摆会让人先陷进细节。
          _buildPresetSection(context, dsh, permissions),
          const SizedBox(height: 24),

          // 2. Global Execution & Security Policy Matrix
          _buildSectionHeader('全局默认执行策略 (Execution Policies)', Icons.tune_rounded, context.c.accent),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.c.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.c.border),
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
                Text(
                  '终端命令默认放行规则 (Default Shell Policy)',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: context.c.textPrimary),
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
                Divider(color: context.c.border),
                const SizedBox(height: 10),

                // Sandbox Escalation Toggle
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: context.c.accent,
                  title: Text('允许沙箱提权执行 (Privilege Escalation)', style: TextStyle(fontSize: 14, color: context.c.textPrimary)),
                  subtitle: Text('允许 DSH 智能体执行需要管理员权限的命令', style: TextStyle(fontSize: 12, color: context.c.textSecondary)),
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
                  activeColor: context.c.accent,
                  title: Text('敏感目录防护 (Protected Path Guard)', style: TextStyle(fontSize: 14, color: context.c.textPrimary)),
                  subtitle: Text('拦截对 .git, .dsh, 系统根目录等敏感路径的覆盖写操作', style: TextStyle(fontSize: 12, color: context.c.textSecondary)),
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
          _buildSectionHeader('操作审计日志 (Audit Trail)', Icons.history_rounded, context.c.purple),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.c.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.c.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.02),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: auditLogs.isEmpty
                ? Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                       child: Text('暂无历史审计记录', style: TextStyle(color: context.c.textTertiary, fontSize: 13)),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: auditLogs.length,
                    separatorBuilder: (context, index) => Divider(color: context.c.border, height: 12),
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

  /// 审批预设卡片（v1.4.2 审批规则化）。
  ///
  /// 三件事刻意做在这里：
  /// 1. **先讲后果再给按钮。** 每个预设展开后列出它实际会怎样，而不是只给一个
  ///    名字。让用户在点之前就知道"完全信任"意味着命令能写到工作区以外。
  /// 2. **切换前先给差异。** 用 PermissionConfigSnapshot.describeDiff 列出这次
  ///    切换会改哪几项、改成什么；没有差异就直说"与当前设置相同"，而不是默默
  ///    提交一个空改动。
  /// 3. **危险预设二次确认。** 只有 danger-full-access 弹窗。给"严格"也弹窗
  ///    会训练用户闭眼点确认，那比不确认更糟。
  Widget _buildPresetSection(BuildContext context, DshService dsh, PermissionConfig permissions) {
    final current = PermissionConfigSnapshot.matching(permissions);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('审批预设 (Approval Presets)', Icons.auto_awesome_rounded, context.c.purple),
        const SizedBox(height: 4),
        Text(
          '一键套用一组经过审阅的策略组合。下面每个预设都列出了它实际会做什么，'
          '套用后仍可在下方逐项微调。',
          style: TextStyle(fontSize: 11.5, color: context.c.textSecondary, height: 1.45),
        ),
        const SizedBox(height: 10),
        ...ApprovalPreset.values.map((p) => _buildPresetTile(context, dsh, permissions, p, current)),
      ],
    );
  }

  Widget _buildPresetTile(
    BuildContext context,
    DshService dsh,
    PermissionConfig permissions,
    ApprovalPreset preset,
    ApprovalPreset? current,
  ) {
    final isActive = current?.id == preset.id;
    final borderColor = isActive
        ? context.c.purple
        : (preset.isDangerous ? const Color(0xFFFCA5A5) : context.c.border);
    final diff = PermissionConfigSnapshot.describeDiff(permissions, preset.config);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: isActive ? 1.6 : 1),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 4, offset: const Offset(0, 1)),
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: isActive,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          shape: const Border(),
          collapsedShape: const Border(),
          title: Row(
            children: [
              Text(
                preset.label,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: preset.isDangerous ? context.c.danger : context.c.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              if (isActive)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: context.c.purple.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '当前',
                    style: TextStyle(fontSize: 10, color: context.c.purple, fontWeight: FontWeight.bold),
                  ),
                ),
              if (preset.isDangerous) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: context.c.dangerSurface,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xFFFCA5A5)),
                  ),
                  child: Text(
                    '高风险',
                    style: TextStyle(fontSize: 10, color: context.c.danger, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ],
          ),
          subtitle: Text(
            preset.summary,
            style: TextStyle(fontSize: 11.5, color: context.c.textSecondary),
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '这个档位会：',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: preset.isDangerous ? context.c.danger : context.c.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 5),
            ...preset.effects.map(
              (e) => Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 5, right: 6),
                      child: Container(
                        width: 3,
                        height: 3,
                        decoration: BoxDecoration(
                          color: preset.isDangerous ? context.c.danger : context.c.textTertiary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        e,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.45,
                          color: preset.isDangerous ? context.c.danger : context.c.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            // 差异预览：切换前就说清楚会改什么。
            if (diff.isNotEmpty) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: context.c.surfaceMuted,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: context.c.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '套用后会改变：',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.c.textSecondary),
                    ),
                    const SizedBox(height: 4),
                    ...diff.map(
                      (d) => Text('· $d', style: TextStyle(fontSize: 11, color: context.c.textSecondary, height: 1.5)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ] else ...[
              Text(
                '与当前设置完全相同，套用不会改变任何配置项。',
                style: TextStyle(fontSize: 11, color: context.c.textTertiary),
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: isActive
                    ? null
                    : () => _applyPreset(context, dsh, permissions, preset, diff),
                style: FilledButton.styleFrom(
                  backgroundColor: preset.isDangerous ? context.c.danger : context.c.purple,
                  disabledBackgroundColor: context.c.border,
                  disabledForegroundColor: context.c.textTertiary,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: Text(
                  isActive ? '当前正在使用' : '套用此预设',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 应用预设。只有「完全信任」需要二次确认。
  Future<void> _applyPreset(
    BuildContext context,
    DshService dsh,
    PermissionConfig permissions,
    ApprovalPreset preset,
    List<String> diff,
  ) async {
    if (preset.isDangerous) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: context.c.danger, size: 22),
              SizedBox(width: 8),
              Text('套用「完全信任」？'),
            ],
          ),
          content: const Text(
            '套用后 Agent 执行的任何命令都不再弹窗确认，并且可以写到工作区以外'
            '的任意路径。\n\n'
            '这相当于把宿主机上的执行权限交给模型。如果这台机器上有你不能承受'
            '损失的数据或凭据，请不要继续。',
            style: TextStyle(height: 1.5),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: context.c.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('我明白风险，套用'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    final ok = await dsh.updatePermissions(preset.config.applyTo(permissions));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? (diff.isEmpty
                  ? '已套用「${preset.label}」（配置无变化）'
                  : '已套用「${preset.label}」，改动 ${diff.length} 项')
              : '套用失败: ${dsh.lastError}',
        ),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
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
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.c.textPrimary),
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
          color: isSelected ? context.c.accent.withOpacity(0.08) : context.c.surface,
          border: Border.all(
            color: isSelected ? context.c.accent : context.c.border,
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
              activeColor: context.c.accent,
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
                      color: isSelected ? context.c.accent : context.c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11, color: context.c.textSecondary),
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
        outcomeColor = context.c.success;
        outcomeText = '已授权放行';
        break;
      case 'auto-approved':
        outcomeColor = context.c.accent;
        outcomeText = '只读自动放行';
        break;
      case 'rejected':
        outcomeColor = context.c.danger;
        outcomeText = '已拦截拒绝';
        break;
      case 'pending':
      default:
        outcomeColor = context.c.warning;
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
                    style: TextStyle(color: context.c.textPrimary, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Text(
                    _formatTime(item.time),
                    style: TextStyle(color: context.c.textTertiary, fontSize: 10),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                item.command,
                style: TextStyle(color: context.c.textPrimary, fontSize: 11, fontFamily: 'monospace'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (item.reason != null && item.reason!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    item.reason!,
                    style: TextStyle(color: context.c.textTertiary, fontSize: 10),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
