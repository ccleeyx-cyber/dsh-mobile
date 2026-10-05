import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/dsh_settings.dart';
import '../models/persona.dart';
import '../services/dsh_service.dart';
import 'config_page.dart';

class CustomSettingsView extends StatefulWidget {
  const CustomSettingsView({super.key});

  @override
  State<CustomSettingsView> createState() => _CustomSettingsViewState();
}

class _CustomSettingsViewState extends State<CustomSettingsView> {
  bool _isTestingPing = false;

  void _showModelSwitchSheet(BuildContext context, DshService dsh) {
    final settings = dsh.settings;
    final currentModel = settings?.currentModel ?? 'cn:deepseek-v4.1-flash';
    final modelList = (settings != null && settings.availableModels.isNotEmpty)
        ? settings.availableModels
        : [
            ModelItem(id: 'cn:deepseek-v4.1-flash', name: 'DeepSeek V4.1 Flash', contextWindow: 1000000, maxTokens: 16384),
            ModelItem(id: 'cn:deepseek-v4-pro', name: 'DeepSeek V4 Pro', contextWindow: 1000000, maxTokens: 32768),
            ModelItem(id: 'cn:kimi-k3-1', name: 'Kimi K3.1', contextWindow: 1000000, maxTokens: 32768),
          ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD1D5DB),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0078D4).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.smart_toy_outlined, color: Color(0xFF0078D4), size: 20),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      '选择大语言模型 (Select LLM)',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.55),
                  child: ListView.separated(
                    shrinkWrap: true,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemCount: modelList.length,
                    itemBuilder: (context, index) {
                      final m = modelList[index];
                      final isSelected = m.id == currentModel || (m.id.replaceFirst('cn:', '') == currentModel.replaceFirst('cn:', ''));
                      return ListTile(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        tileColor: isSelected ? const Color(0xFF0078D4).withOpacity(0.08) : null,
                        title: Text(
                          m.name,
                          style: TextStyle(
                            color: isSelected ? const Color(0xFF0078D4) : const Color(0xFF1F2937),
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          '上下文: ${(m.contextWindow ?? 0) ~/ 1000}k | 最大输出: ${(m.maxTokens ?? 0) ~/ 1000}k',
                          style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                        ),
                        trailing: isSelected ? const Icon(Icons.check_circle, color: Color(0xFF0078D4)) : null,
                        onTap: () async {
                          Navigator.pop(ctx);
                          final ok = await dsh.switchModel(m.id);
                          if (ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('已切换默认模型至: ${m.name}'),
                                backgroundColor: const Color(0xFF10B981),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Add Custom Persona Bottom Sheet
  void _openCustomPersonaDialog(BuildContext context, DshService dsh) {
    final titleController = TextEditingController();
    final promptController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 16,
              bottom: MediaQuery.of(context).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD1D5DB),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0078D4).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.person_add_alt_1_rounded, color: Color(0xFF0078D4), size: 20),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      '自定义智能体人设 (Custom Persona)',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: titleController,
                  style: const TextStyle(color: Color(0xFF111827), fontSize: 14),
                  decoration: InputDecoration(
                    labelText: '角色名称 (如: 游戏逻辑架构师)',
                    labelStyle: const TextStyle(color: Color(0xFF6B7280)),
                    filled: true,
                    fillColor: const Color(0xFFF9FAFB),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF0078D4), width: 1.5)),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  height: 150,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF9FAFB),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: TextField(
                    controller: promptController,
                    maxLines: null,
                    expands: true,
                    style: const TextStyle(color: Color(0xFF111827), fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: '设定智能体的系统人设提示词 (System Prompt)...',
                      hintStyle: TextStyle(color: Color(0xFF9CA3AF)),
                      contentPadding: EdgeInsets.all(12),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0078D4),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: () async {
                      final title = titleController.text.trim();
                      final prompt = promptController.text.trim();
                      if (title.isEmpty || prompt.isEmpty) return;

                      final newPersona = AgentPersona(
                        id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
                        title: title,
                        icon: 'person',
                        description: '自定义人设',
                        prompt: prompt,
                        isCustom: true,
                      );

                      final list = List<AgentPersona>.from(dsh.personas)..add(newPersona);
                      await dsh.savePersonas(list);
                      if (context.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('已添加人设: $title'),
                            backgroundColor: const Color(0xFF10B981),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    },
                    child: const Text('保存为人设', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE5E7EB)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.02),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final settings = dsh.settings;
    final currentModel = settings?.currentModel ?? 'cn:deepseek-v4.1-flash';
    final personas = dsh.personas;

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF111827),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFFE5E7EB), height: 1),
        ),
        title: const Row(
          children: [
            Icon(Icons.tune_rounded, color: Color(0xFF0078D4)),
            SizedBox(width: 8),
            Text(
              '设置与深度自定义',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        children: [
          // 1. Model & Reasoning Engine Section
          _buildSectionHeader('大语言模型与思考引擎 (LLM & Reasoning)', Icons.smart_toy_outlined, const Color(0xFF0078D4)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: _cardDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Current Model Row
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0078D4).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.psychology_outlined, color: Color(0xFF0078D4), size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('当前默认模型', style: TextStyle(color: Color(0xFF6B7280), fontSize: 11)),
                          const SizedBox(height: 2),
                          Text(
                            currentModel,
                            style: const TextStyle(color: Color(0xFF111827), fontSize: 14, fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0078D4).withOpacity(0.1),
                        foregroundColor: const Color(0xFF0078D4),
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      ),
                      onPressed: () => _showModelSwitchSheet(context, dsh),
                      child: const Text('更换', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),

                const SizedBox(height: 16),
                const Divider(color: Color(0xFFF3F4F6)),
                const SizedBox(height: 12),

                // Reasoning Effort Slider
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('深度思考预算 (Reasoning Budget)', style: TextStyle(color: Color(0xFF374151), fontSize: 13, fontWeight: FontWeight.w500)),
                    Text(
                      dsh.reasoningBudget == 0 ? '关闭思考' : '${dsh.reasoningBudget ~/ 1000}k Tokens',
                      style: const TextStyle(color: Color(0xFF0078D4), fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Slider(
                  value: dsh.reasoningBudget.toDouble(),
                  min: 0,
                  max: 32000,
                  divisions: 8,
                  activeColor: const Color(0xFF0078D4),
                  inactiveColor: const Color(0xFFE5E7EB),
                  onChanged: (v) {
                    dsh.setReasoningBudget(v.round());
                  },
                ),

                // Temperature Slider
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('采样创造力 (Temperature)', style: TextStyle(color: Color(0xFF374151), fontSize: 13, fontWeight: FontWeight.w500)),
                    Text(
                      dsh.temperature.toStringAsFixed(2),
                      style: const TextStyle(color: Color(0xFF0078D4), fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Slider(
                  value: dsh.temperature,
                  min: 0.0,
                  max: 1.0,
                  divisions: 10,
                  activeColor: const Color(0xFF0078D4),
                  inactiveColor: const Color(0xFFE5E7EB),
                  onChanged: (v) {
                    dsh.setTemperature(v);
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // 2. Personas & System Prompts Section
          Row(
            children: [
              _buildSectionHeader('智能体角色人设 (Agent Personas)', Icons.psychology_rounded, const Color(0xFF0078D4)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, color: Color(0xFF0078D4), size: 22),
                tooltip: '添加自定义人设',
                onPressed: () => _openCustomPersonaDialog(context, dsh),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: _cardDecoration(),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: personas.length,
              separatorBuilder: (context, index) => const Divider(color: Color(0xFFF3F4F6), height: 12),
              itemBuilder: (context, index) {
                final p = personas[index];
                final isSelected = dsh.activePersonaId == p.id;
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFF0078D4).withOpacity(0.12) : const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      p.icon == 'bug'
                          ? Icons.bug_report_outlined
                          : p.icon == 'terminal'
                              ? Icons.terminal_rounded
                              : p.icon == 'shield'
                                  ? Icons.shield_outlined
                                  : Icons.code_rounded,
                      color: isSelected ? const Color(0xFF0078D4) : const Color(0xFF6B7280),
                      size: 20,
                    ),
                  ),
                  title: Text(
                    p.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                      color: isSelected ? const Color(0xFF0078D4) : const Color(0xFF1F2937),
                    ),
                  ),
                  subtitle: Text(
                    p.description,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                  ),
                  trailing: isSelected
                      ? const Icon(Icons.check_circle, color: Color(0xFF0078D4), size: 20)
                      : OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF374151),
                            side: const BorderSide(color: Color(0xFFD1D5DB)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          ),
                          child: const Text('启用', style: TextStyle(fontSize: 11)),
                          onPressed: () {
                            dsh.setActivePersona(p.id);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('已启用人设: ${p.title}'),
                                backgroundColor: const Color(0xFF0078D4),
                                duration: const Duration(seconds: 1),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                        ),
                );
              },
            ),
          ),

          const SizedBox(height: 24),

          // 3. Connectivity & Network Diagnostics
          _buildSectionHeader('网络与网关诊断 (Connectivity & Diagnostics)', Icons.network_check_rounded, const Color(0xFF059669)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: _cardDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInfoRow('网关地址 (Gateway)', dsh.currentConfig?.host ?? 'n.cnm.asia:3088'),
                const SizedBox(height: 8),
                _buildInfoRow('DSH 本地上游', settings?.dshHost ?? '127.0.0.1:3080'),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('实时往返延迟 (Ping)', style: TextStyle(color: Color(0xFF6B7280), fontSize: 13)),
                    Row(
                      children: [
                        Text(
                          dsh.pingMs >= 0 ? '${dsh.pingMs} ms' : '未测速',
                          style: TextStyle(
                            color: dsh.pingMs >= 0 && dsh.pingMs < 100
                                ? const Color(0xFF059669)
                                : dsh.pingMs >= 100
                                    ? const Color(0xFFD97706)
                                    : const Color(0xFF9CA3AF),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: _isTestingPing
                              ? null
                              : () async {
                                  setState(() => _isTestingPing = true);
                                  await dsh.measurePing();
                                  setState(() => _isTestingPing = false);
                                },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF10B981).withOpacity(0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: _isTestingPing
                                ? const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF059669)))
                                : const Text('测速', style: TextStyle(color: Color(0xFF059669), fontSize: 11, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Divider(color: Color(0xFFF3F4F6)),
                const SizedBox(height: 10),

                // Reconnect & Change Server
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF374151),
                          side: const BorderSide(color: Color(0xFFD1D5DB)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                        label: const Text('切换服务器', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const ConfigPage()),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0078D4),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('断线重连', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        onPressed: () {
                          if (dsh.currentConfig != null) {
                            dsh.connect(dsh.currentConfig!);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // 4. About & APK Updates Section
          _buildSectionHeader('关于客户端与更新', Icons.info_outline_rounded, const Color(0xFF6B7280)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: _cardDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(colors: [Color(0xFF0078D4), Color(0xFF2563EB)]),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.layers_rounded, color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: 12),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('DSH Mobile Pro', style: TextStyle(color: Color(0xFF111827), fontWeight: FontWeight.bold, fontSize: 14)),
                        SizedBox(height: 2),
                        Text('版本: v1.2.1 (Build 4)', style: TextStyle(color: Color(0xFF6B7280), fontSize: 12)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        icon: const Icon(Icons.download_rounded, size: 16, color: Color(0xFF0078D4)),
                        label: const Text('复制 APK 下载直链', style: TextStyle(color: Color(0xFF0078D4), fontSize: 12, fontWeight: FontWeight.w600)),
                        onPressed: () {
                          const apkUrl = 'http://n.cnm.asia:3088/dsh-agent.apk';
                          Clipboard.setData(const ClipboardData(text: apkUrl));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('已复制直链: http://n.cnm.asia:3088/dsh-agent.apk'),
                              backgroundColor: Color(0xFF0078D4),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
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
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13)),
        Text(value, style: const TextStyle(color: Color(0xFF111827), fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
