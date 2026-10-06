import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/dsh_settings.dart';
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

    String filter = '';

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
                StatefulBuilder(
                  builder: (context, setModalState) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                          decoration: InputDecoration(
                            hintText: '搜索模型 (如 deepseek, glm, gpt, qwen...)',
                            hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                            prefixIcon: const Icon(Icons.search, size: 20, color: Color(0xFF6B7280)),
                            filled: true,
                            fillColor: const Color(0xFFF3F4F6),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          onChanged: (val) {
                            setModalState(() {
                              filter = val.trim().toLowerCase();
                            });
                          },
                        ),
                        const SizedBox(height: 10),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
                          child: Builder(
                            builder: (context) {
                              final filtered = modelList.where((m) {
                                if (filter.isEmpty) return true;
                                return m.name.toLowerCase().contains(filter) || m.id.toLowerCase().contains(filter);
                              }).toList();

                              if (filtered.isEmpty) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 24),
                                  child: Center(
                                    child: Text('未找到匹配的模型', style: TextStyle(color: Color(0xFF9CA3AF))),
                                  ),
                                );
                              }

                              return ListView.separated(
                                shrinkWrap: true,
                                separatorBuilder: (_, __) => const SizedBox(height: 6),
                                itemCount: filtered.length,
                                itemBuilder: (context, index) {
                                  final m = filtered[index];
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
                                      'ID: ${m.id} | 上下文: ${(m.contextWindow ?? 0) ~/ 1000}k',
                                      style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                                    ),
                                    trailing: isSelected ? const Icon(Icons.check_circle, color: Color(0xFF0078D4)) : null,
                                    onTap: () async {
                                      Navigator.pop(ctx);
                                      final ok = await dsh.switchModel(m.id);
                                      if (ok && context.mounted) {
                                        ScaffoldMessenger.of(context).clearSnackBars();
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text('已切换默认模型至: ${m.name}'),
                                            backgroundColor: const Color(0xFF10B981),
                                            behavior: SnackBarBehavior.floating,
                                            duration: const Duration(seconds: 2),
                                          ),
                                        );
                                      }
                                    },
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    );
                  },
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

          const SizedBox(height: 16),

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
