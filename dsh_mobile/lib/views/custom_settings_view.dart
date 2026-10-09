import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/dsh_settings.dart';
import '../models/app_version.dart';
import '../services/dsh_service.dart';
import 'config_page.dart';
import 'gateway_health_view.dart';
import '../theme/app_colors.dart';
import '../main.dart';

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
      backgroundColor: context.c.surface,
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
                      color: context.c.border,
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
                        color: context.c.accent.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.smart_toy_outlined, color: context.c.accent, size: 20),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '选择大语言模型 (Select LLM)',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.c.textPrimary),
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
                            hintStyle: TextStyle(fontSize: 13, color: context.c.textTertiary),
                            prefixIcon: Icon(Icons.search, size: 20, color: context.c.textSecondary),
                            filled: true,
                            fillColor: context.c.surfaceMuted,
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
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 24),
                                  child: Center(
                                    child: Text('未找到匹配的模型', style: TextStyle(color: context.c.textTertiary)),
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
                                    tileColor: isSelected ? context.c.accent.withOpacity(0.08) : null,
                                    title: Text(
                                      m.name,
                                      style: TextStyle(
                                        color: isSelected ? context.c.accent : context.c.textPrimary,
                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                      ),
                                    ),
                                    subtitle: Text(
                                      'ID: ${m.id} | 上下文: ${(m.contextWindow ?? 0) ~/ 1000}k',
                                      style: TextStyle(fontSize: 12, color: context.c.textSecondary),
                                    ),
                                    trailing: isSelected ? Icon(Icons.check_circle, color: context.c.accent) : null,
                                    onTap: () async {
                                      Navigator.pop(ctx);
                                      final ok = await dsh.switchModel(m.id);
                                      if (ok && context.mounted) {
                                        ScaffoldMessenger.of(context).clearSnackBars();
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text('已切换默认模型至: ${m.name}'),
                                            backgroundColor: context.c.success,
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
      color: context.c.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.c.border),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.02),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  /// 通知状态卡（§4.2 推送通知）。
  ///
  /// 这一屏**不提供开关**，只如实显示当前能不能收到通知。理由：能不能收到不
  /// 取决于三件用户无法在 App 内改变的事 —— 系统通知权限是否给了、Android 是否
  /// 允许后台保活、以及用户有没有手动划掉常驻通知。给一个开关却无法保证它
  /// 有效，比不给开关更糟。
  ///
  /// 真正缺权限时给出的是**可执行的指引**（去系统设置），而不是一句"不可用"。
  Widget _buildNotificationCard(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final granted = dsh.notificationPermissionGranted;

    final (Color iconColor, String title, String subtitle) = granted
        ? (
            context.c.success,
            '后台通知已开启',
            'Agent 需要你授权或回答时会弹通知；App 在前台时不打扰。'
          )
        : (
            context.c.warning,
            '通知未开启，你将收不到提醒',
            'Android 13 及以上需要授权。请到 系统设置 → 应用 → DSH Mobile → 通知 中开启。'
          );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.notifications_active_outlined, size: 17, color: iconColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(fontSize: 11.5, height: 1.5, color: context.c.textSecondary),
          ),
        ],
      ),
    );
  }

  /// 外观 / 主题选择（v1.6.0）。
  ///
  /// 用三选一分段控件而不是一个循环切换按钮：这里是要"选一个状态"，分段控件能
  /// 一眼看到当前值和全部可选值；顶栏那个循环按钮适合低频快速切换。两处按场景
  /// 各选一种，不是重复功能。
  Widget _buildAppearanceCard(BuildContext context) {
    final theme = context.watch<ThemeController>();
    const options = [
      ('system', '跟随系统', Icons.brightness_auto_rounded),
      ('light', '浅色', Icons.light_mode_rounded),
      ('dark', '深色', Icons.dark_mode_rounded),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.palette_outlined, size: 16, color: context.c.purple),
              const SizedBox(width: 7),
              const Text(
                '主题模式',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final (mode, label, icon) in options) ...[
                Expanded(
                  child: _ThemeOption(
                    label: label,
                    icon: icon,
                    selected: theme.mode == mode,
                    onTap: () => theme.setMode(mode),
                  ),
                ),
                if (mode != 'dark') const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHealthEntry(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final color = dsh.isConnected
        ? context.c.success
        : (dsh.isTokenInvalid ? context.c.danger : context.c.textTertiary);
    final label = dsh.isConnected ? '已连接' : (dsh.isTokenInvalid ? '令牌失效' : '未连接');

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const GatewayHealthView()),
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: _cardDecoration(),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.monitor_heart_outlined, color: color, size: 21),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '网关健康',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                      const SizedBox(width: 5),
                      Text(
                        label,
                        style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w500),
                      ),
                      if (dsh.pendingApprovals.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        Text(
                          '· ${dsh.pendingApprovals.length} 个待授权',
                          style: TextStyle(fontSize: 11.5, color: context.c.warning),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: context.c.textTertiary, size: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final settings = dsh.settings;
    final currentModel = settings?.currentModel ?? 'cn:deepseek-v4.1-flash';

    return Scaffold(
      backgroundColor: context.c.surfaceMuted,
      appBar: AppBar(
        backgroundColor: context.c.surface,
        foregroundColor: context.c.textPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: context.c.border, height: 1),
        ),
        title: Row(
          children: [
            Icon(Icons.tune_rounded, color: context.c.accent),
            const SizedBox(width: 8),
            Text(
              '设置与深度自定义',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.c.textPrimary),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        children: [
          // 0. 网关健康（v1.6.0）。放在最上面：出问题时用户最想立刻看到它，
          // 而不是先滚过一屏模型参数。
          _buildHealthEntry(context),
          const SizedBox(height: 16),
          _buildAppearanceCard(context),
          const SizedBox(height: 16),
          _buildNotificationCard(context),
          const SizedBox(height: 24),

          // 1. Model & Reasoning Engine Section
          _buildSectionHeader('大语言模型与思考引擎 (LLM & Reasoning)', Icons.smart_toy_outlined, context.c.accent),
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
                        color: context.c.accent.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.psychology_outlined, color: context.c.accent, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('当前默认模型', style: TextStyle(color: context.c.textSecondary, fontSize: 11)),
                          const SizedBox(height: 2),
                          Text(
                            currentModel,
                            style: TextStyle(color: context.c.textPrimary, fontSize: 14, fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: context.c.accent.withOpacity(0.1),
                        foregroundColor: context.c.accent,
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
                Divider(color: context.c.surfaceMuted),
                const SizedBox(height: 12),

                // Reasoning Effort Slider
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('深度思考预算 (Reasoning Budget)', style: TextStyle(color: context.c.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
                    Text(
                      dsh.reasoningBudget == 0 ? '关闭思考' : '${dsh.reasoningBudget ~/ 1000}k Tokens',
                      style: TextStyle(color: context.c.accent, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Slider(
                  value: dsh.reasoningBudget.toDouble(),
                  min: 0,
                  max: 32000,
                  divisions: 8,
                  activeColor: context.c.accent,
                  inactiveColor: context.c.border,
                  onChanged: (v) {
                    dsh.setReasoningBudget(v.round());
                  },
                ),

                // Temperature Slider
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('采样创造力 (Temperature)', style: TextStyle(color: context.c.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
                    Text(
                      dsh.temperature.toStringAsFixed(2),
                      style: TextStyle(color: context.c.accent, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Slider(
                  value: dsh.temperature,
                  min: 0.0,
                  max: 1.0,
                  divisions: 10,
                  activeColor: context.c.accent,
                  inactiveColor: context.c.border,
                  onChanged: (v) {
                    dsh.setTemperature(v);
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 3. Connectivity & Network Diagnostics
          _buildSectionHeader('网络与网关诊断 (Connectivity & Diagnostics)', Icons.network_check_rounded, context.c.success),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: _cardDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInfoRow('网关地址 (Gateway)', dsh.currentConfig?.httpBaseUrl ?? '未配置'),
                const SizedBox(height: 8),
                _buildInfoRow('DSH 本地上游', settings?.dshHost ?? '127.0.0.1:3080'),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('实时往返延迟 (Ping)', style: TextStyle(color: context.c.textSecondary, fontSize: 13)),
                    Row(
                      children: [
                        Text(
                          dsh.pingMs >= 0 ? '${dsh.pingMs} ms' : '未测速',
                          style: TextStyle(
                            color: dsh.pingMs >= 0 && dsh.pingMs < 100
                                ? context.c.success
                                : dsh.pingMs >= 100
                                    ? context.c.warning
                                    : context.c.textTertiary,
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
                              color: context.c.success.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: _isTestingPing
                                ? SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: context.c.success))
                                : Text('测速', style: TextStyle(color: context.c.success, fontSize: 11, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Divider(color: context.c.surfaceMuted),
                const SizedBox(height: 10),

                // Reconnect & Change Server
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
                          backgroundColor: context.c.accent,
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
          _buildSectionHeader('关于客户端与更新', Icons.info_outline_rounded, context.c.textSecondary),
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
                        gradient: LinearGradient(colors: [context.c.accent, const Color(0xFF2563EB)]),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.layers_rounded, color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('DSH Mobile Pro', style: TextStyle(color: context.c.textPrimary, fontWeight: FontWeight.bold, fontSize: 14)),
                        const SizedBox(height: 2),
                        // Single source of truth is lib/models/app_version.dart,
                        // which mirrors pubspec.yaml — no stale literal here.
                        Text(
                          '版本: v${AppVersion.version} (Build ${AppVersion.buildNumber})',
                          style: TextStyle(color: context.c.textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        icon: Icon(Icons.download_rounded, size: 16, color: context.c.accent),
                        label: Text('复制 APK 下载直链', style: TextStyle(color: context.c.accent, fontSize: 12, fontWeight: FontWeight.w600)),
                        onPressed: () {
                          // Build the download URL from the gateway the user is
                          // actually connected to, instead of a baked-in host
                          // that silently breaks on LAN / tunnel / port changes.
                          final cfg = dsh.currentConfig;
                          final apkUrl = '${cfg?.httpBaseUrl ?? 'http://127.0.0.1:3088'}/dsh-agent.apk';
                          Clipboard.setData(ClipboardData(text: apkUrl));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('已复制直链: $apkUrl'),
                              backgroundColor: context.c.accent,
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
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: context.c.textPrimary),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: context.c.textSecondary, fontSize: 13)),
        Text(value, style: TextStyle(color: context.c.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// 主题模式的一个分段选项。
///
/// 用 [InkWell] + 边框而不是 [ChoiceChip]：Chip 自带圆角胶囊底色，三枚并排时
/// 视觉上像三个独立按钮，用户不容易看出"这是单选"。
class _ThemeOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeOption({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = context.c.purple;
    final idleBorder = context.c.border;
    final idleFill = context.c.surfaceMuted;
    final idleFg = context.c.textSecondary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: selected ? active.withOpacity(0.10) : idleFill,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected ? active : idleBorder,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(icon, size: 19, color: selected ? active : idleFg),
            const SizedBox(height: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                color: selected ? active : idleFg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
