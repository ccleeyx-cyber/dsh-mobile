import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/dsh_service.dart';
import '../widgets/approval_card.dart';
import 'config_page.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  bool _isSwitchingModel = false;

  void _showModelPicker(DshService dsh) {
    final settings = dsh.settings;
    if (settings == null || settings.availableModels.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无可用模型列表，请确认 DSH 服务端正常运行')),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, scrollController) {
            return Column(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade600,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.psychology_rounded, color: Colors.blueAccent),
                      const SizedBox(width: 8),
                      Text(
                        '选择默认模型 (${settings.availableModels.length} 个可用)',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: settings.availableModels.length,
                    itemBuilder: (ctx, index) {
                      final m = settings.availableModels[index];
                      final isSelected = m.id == settings.currentModel;

                      return ListTile(
                        leading: Icon(
                          isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                          color: isSelected ? Colors.blueAccent : Colors.grey,
                        ),
                        title: Text(
                          m.name,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? Colors.blueAccent : null,
                          ),
                        ),
                        subtitle: m.contextWindow != null
                            ? Text('上下文: ${(m.contextWindow! / 1000).toStringAsFixed(0)}k tokens')
                            : null,
                        onTap: () async {
                          Navigator.pop(ctx);
                          setState(() => _isSwitchingModel = true);
                          final ok = await dsh.switchModel(m.id);
                          setState(() => _isSwitchingModel = false);

                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(ok ? '✅ 已成功切换至模型: ${m.name}' : '❌ 切换模型失败'),
                                backgroundColor: ok ? Colors.green : Colors.red,
                              ),
                            );
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final settings = dsh.settings;
    final config = dsh.currentConfig;

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置与管理'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // 1. Model Selection Card
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.smart_toy_rounded, color: Colors.blueAccent, size: 24),
                      const SizedBox(width: 8),
                      const Text(
                        '智能体模型设置',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      if (_isSwitchingModel)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.blue.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('当前默认模型', style: TextStyle(fontSize: 12, color: Colors.grey)),
                              const SizedBox(height: 4),
                              Text(
                                settings?.currentModel ?? '读取中...',
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: () => _showModelPicker(dsh),
                          icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                          label: const Text('切换模型'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 2. Pending Approvals Section
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.verified_user_rounded, color: Colors.amber, size: 24),
                      const SizedBox(width: 8),
                      const Text(
                        '授权审批管理',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: dsh.pendingApprovals.isEmpty ? Colors.grey.shade700 : Colors.amber.shade800,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${dsh.pendingApprovals.length} 项待处理',
                          style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      )
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (dsh.pendingApprovals.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12.0),
                      child: Text(
                        '当前没有待处理的工具执行审批。当 DSH 智能体执行高权限工具（如 Bash / 终端 / 敏感文件操作）时，会在此处弹出审批请求。',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    )
                  else
                    Column(
                      children: dsh.pendingApprovals.map((req) {
                        return ApprovalCard(
                          request: req,
                          onRespond: (r, outcome) => dsh.respondApproval(r, outcome),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 3. Server Info Card
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.dns_rounded, color: Colors.green, size: 24),
                      const SizedBox(width: 8),
                      const Text(
                        '服务器与公网连接',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: dsh.isConnected ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          dsh.isConnected ? '已连接' : '未连接',
                          style: TextStyle(
                            color: dsh.isConnected ? Colors.green : Colors.red,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      )
                    ],
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('网关地址 (Host / IP)'),
                    subtitle: Text('${config?.host ?? "未配置"}:${config?.port ?? 3088}'),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('宿主机 DSH 上游'),
                    subtitle: Text(settings?.dshHost ?? '127.0.0.1:3080'),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('安全访问令牌 (Token)'),
                    subtitle: Text(config?.token.isNotEmpty == true ? '••••••••••••••••' : '未配置'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ConfigPage()),
                      );
                    },
                    icon: const Icon(Icons.edit_rounded, size: 16),
                    label: const Text('修改服务器连接与 Token'),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  )
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
