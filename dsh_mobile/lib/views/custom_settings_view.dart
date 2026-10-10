import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/dsh_settings.dart';
import '../models/app_version.dart';
import '../models/gateway_features.dart';
import '../services/dsh_service.dart';
import '../services/platform_services.dart';
import 'config_page.dart';
import 'gateway_health_view.dart';
import '../theme/app_colors.dart';
import '../main.dart';

class CustomSettingsView extends StatefulWidget {
  const CustomSettingsView({super.key});

  /// Stable handles for the ntfy block, so the interface tests can assert on it
  /// without depending on copy that is expected to keep changing.
  @visibleForTesting
  static const pushRequirementNoteKey = Key('push-requirement-note');
  @visibleForTesting
  static const pushUrlFieldKey = Key('push-url-field');
  @visibleForTesting
  static const pushTopicFieldKey = Key('push-topic-field');
  @visibleForTesting
  static const pushTokenFieldKey = Key('push-token-field');

  @override
  State<CustomSettingsView> createState() => _CustomSettingsViewState();
}

class _CustomSettingsViewState extends State<CustomSettingsView> {
  bool _isTestingPing = false;

  // ---- 离线推送（ntfy）草稿字段（v1.13）----
  //
  // 用 controller 而不是每敲一个字就提交：这些是"填完再保存"的配置，不存在
  // 即时生效的语义。初始值来自网关回显，用户改完点「保存」才写回去。
  final TextEditingController _ntfyUrlController = TextEditingController();
  final TextEditingController _ntfyTopicController = TextEditingController();
  final TextEditingController _ntfyTokenController = TextEditingController();
  bool _ntfyEnabled = false;
  bool _ntfyDirty = false;
  bool _pushBusy = false;

  @override
  void dispose() {
    _ntfyUrlController.dispose();
    _ntfyTopicController.dispose();
    _ntfyTokenController.dispose();
    super.dispose();
  }

  /// 把网关回显的推送配置灌进表单。
  ///
  /// 只在**用户还没改动**（!_ntfyDirty）时灌：否则一次后台刷新会把他正在
  /// 输入的地址覆盖掉。token 永远不回填（网关只回 hasToken 布尔），所以
  /// 留空 + 提示"留空则不改动"。
  void _syncPushForm(DshService dsh) {
    final cfg = dsh.pushConfig;
    if (cfg == null || _ntfyDirty) return;
    if (_ntfyUrlController.text == cfg.url &&
        _ntfyTopicController.text == cfg.topic &&
        _ntfyEnabled == cfg.enabled) {
      return;
    }
    _ntfyUrlController.text = cfg.url;
    _ntfyTopicController.text = cfg.topic;
    _ntfyEnabled = cfg.enabled;
  }

  Future<void> _savePush(DshService dsh) async {
    setState(() => _pushBusy = true);
    final ok = await dsh.savePushConfig(
      enabled: _ntfyEnabled,
      url: _ntfyUrlController.text.trim(),
      topic: _ntfyTopicController.text.trim(),
      token: _ntfyTokenController.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _pushBusy = false;
      if (ok) {
        _ntfyDirty = false;
        _ntfyTokenController.clear();
      }
    });
    _settingsToast(ok ? '推送配置已保存' : (dsh.lastError.isEmpty ? '保存失败' : dsh.lastError));
  }

  Future<void> _testPush(DshService dsh) async {
    setState(() => _pushBusy = true);
    final ok = await dsh.testPush();
    if (!mounted) return;
    setState(() => _pushBusy = false);
    _settingsToast(ok ? '测试推送已发出，检查 ntfy App' : '推送发送失败：检查地址、topic 与是否已开启');
  }

  void _settingsToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

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

  /// 「另一半在手机上」：网关只是**发布方**，没有订阅方就什么都不会响。
  ///
  /// ntfy 是发布/订阅模型。这一屏填的地址与 topic 只决定"往哪儿发"，收到与否
  /// 取决于手机上是否有一个客户端**订阅了同一个 topic**。缺了后半句，配置项
  /// 看起来完全正常、测试推送也能成功，用户却"一直收不到"——这正是之前被
  /// 反馈为"推送只是看起来配好了"的原因。所以这句话必须挨着输入框写出来，
  /// 而不是折叠在别处的说明里。
  Widget _buildPushRequirementNote(BuildContext context) {
    final lines = <String>[
      '① 在应用商店安装一个 ntfy 客户端（官方开源 App，Android/iOS 都有）。',
      '② 在客户端里订阅与下面完全相同的一个 topic（一个字都不能差）。',
      '③ 没装客户端，或 topic 对不上 → 手机不会有任何提示。',
      '④ 提醒只在 App 不在线（进程被杀/断网/锁屏）时经 ntfy 发送；'
          'App 活着时由它自己弹本地通知，不会重复推两条。',
    ];
    return Container(
      key: CustomSettingsView.pushRequirementNoteKey,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.c.warning.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.c.warning.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.smartphone_rounded, size: 15, color: context.c.warning),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '还需要在手机上装一个 ntfy 客户端并订阅同一 topic',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: context.c.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                line,
                style: TextStyle(fontSize: 11, color: context.c.textSecondary, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }

  /// 离线推送配置卡。
  ///
  /// 为什么需要它：App 的本地通知只在**进程活着**时才有意义；Android 杀掉进程
  /// 后连接就断了，什么都不会来。ntfy 走的是服务器 → 第三方推送服务 → 系统通知，
  /// 与 App 死活无关，这是"手机不在手里也能被叫醒"的唯一路径。
  ///
  /// 同时必须说清代价：启用后事件摘要会经第三方服务器中转。这是用户对**自己**
  /// 的选择，不能默默打开 —— 默认关闭，并在这里写明。
  Widget _buildPushSection(BuildContext context, DshService dsh) {
    _syncPushForm(dsh);
    final cfg = dsh.pushConfig;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  cfg == null
                      ? '网关未上报推送配置（旧版网关？）'
                      : (cfg.configured ? '推送已开启' : '推送未开启'),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                    color: cfg?.configured == true ? context.c.success : context.c.textPrimary,
                  ),
                ),
              ),
              Switch(
                value: _ntfyEnabled,
                onChanged: _pushBusy
                    ? null
                    : (v) => setState(() {
                          _ntfyEnabled = v;
                          _ntfyDirty = true;
                        }),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '开启后，审批/提问/任务完成会经 ntfy 推到系统通知栏；'
            '点开通知直接进入对应会话（App 没运行时也能收到）。'
            '事件摘要会经该服务中转，请只在接受这一点时开启。',
            style: TextStyle(fontSize: 11.5, color: context.c.textSecondary, height: 1.35),
          ),
          const SizedBox(height: 10),
          _buildPushRequirementNote(context),
          const SizedBox(height: 12),
          TextField(
            key: CustomSettingsView.pushUrlFieldKey,
            controller: _ntfyUrlController,
            onChanged: (_) => _ntfyDirty = true,
            decoration: const InputDecoration(
              labelText: 'ntfy 服务器',
              hintText: 'https://ntfy.sh',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 10),
          TextField(
            key: CustomSettingsView.pushTopicFieldKey,
            controller: _ntfyTopicController,
            onChanged: (_) => _ntfyDirty = true,
            decoration: const InputDecoration(
              labelText: 'Topic（相当于收件箱名）',
              hintText: '例如 dsh-你的随机串（不要用可猜的名字）',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 10),
          TextField(
            key: CustomSettingsView.pushTokenFieldKey,
            controller: _ntfyTokenController,
            onChanged: (_) => _ntfyDirty = true,
            obscureText: true,
            decoration: InputDecoration(
              labelText: '访问令牌（自建且需要鉴权时填）',
              hintText: cfg?.hasToken == true ? '已保存，留空表示不改动' : '可留空',
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          Text(
            'Topic 建议用一段随机串：ntfy 上知道 topic 的人就能订阅到你的通知。',
            style: TextStyle(fontSize: 11, color: context.c.textTertiary),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _pushBusy ? null : () => _savePush(dsh),
                icon: _pushBusy
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_outlined, size: 16),
                label: const Text('保存', style: TextStyle(fontSize: 12.5)),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _pushBusy ? null : () => _testPush(dsh),
                icon: const Icon(Icons.send_rounded, size: 16),
                label: const Text('测试推送', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
        ],
      ),
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
  /// 通知状态卡片。
  ///
  /// 这里必须看**插件的真实就绪状态**，不能只看权限。
  ///
  /// 原先只看 `notificationPermissionGranted`，于是出现了一处真实误导：Android 上
  /// 初始化少了必要设置会抛异常、被 catch 吞掉，插件从未初始化成功、一条通知都发
  /// 不出去 —— 而这张卡片一直显示绿色的「后台通知已开启」。用户看到的是
  /// "开关是开的，但就是没有通知"，无从判断。
  ///
  /// 现在三态分明：可用 / 有权限但链路异常（并给出原因）/ 没有权限。
  Widget _buildNotificationCard(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final granted = dsh.notificationPermissionGranted;
    final ready = dsh.notificationsReady;
    final err = dsh.notificationError;
    final backgroundOn = dsh.notificationBackgroundOn;

    final (Color iconColor, String title, String subtitle) = ready
        ? (
            context.c.success,
            '后台通知已开启',
            'Agent 需要你授权或回答时会弹通知；App 在前台时不打扰。'
                '${backgroundOn ? "前台保活已启动。" : "前台保活未启动 —— App 被系统回收后连接会断，届时收不到通知。"}'
          )
        : granted
            ? (
                // 最容易被忽略的一态：权限有、链路坏。旧版把这种情况也说成"已开启"。
                context.c.danger,
                '通知链路异常，通知发不出去',
                '已获得通知权限，但通知组件没有就绪，因此一条也发不出来。'
                    '${err == null ? "" : "原因：$err"}'
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
              Icon(
                ready ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
                size: 17,
                color: iconColor,
              ),
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
                    // Expanded：左侧标签很长（"深度思考预算 (Reasoning Budget)"），
                    // spaceBetween 下两个裸 Text 会一起溢出（实测手机宽 97px）。
                    Expanded(
                      child: Text('深度思考预算 (Reasoning Budget)', style: TextStyle(color: context.c.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
                    ),
                    const SizedBox(width: 8),
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

          // 2.5 Prompt Snippets（提示词模板）
          _buildSectionHeader('提示词模板 (Quick Snippets)', Icons.bolt_rounded, context.c.warning),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: _cardDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '在聊天输入框上方显示的快捷模板条。点击模板即把内容追加到输入框。',
                  style: TextStyle(color: context.c.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 10),
                if (dsh.snippets.isEmpty)
                  Text('还没有模板，点下面按钮添加。', style: TextStyle(color: context.c.textTertiary, fontSize: 12))
                else
                  ...dsh.snippets.map(
                    (s) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${s.label} — ${s.text.length > 40 ? '${s.text.substring(0, 40)}…' : s.text}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: context.c.textPrimary, fontSize: 12.5),
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.delete_outline_rounded, size: 16, color: context.c.danger),
                            tooltip: '删除该模板',
                            onPressed: () async {
                              final next = [...dsh.snippets]..removeWhere((x) => x.id == s.id);
                              await dsh.saveSnippets(next);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: Icon(Icons.add_rounded, size: 16, color: context.c.accent),
                    label: Text('添加模板', style: TextStyle(color: context.c.accent, fontSize: 12, fontWeight: FontWeight.w600)),
                    onPressed: () => _showAddSnippetDialog(context, dsh),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 3. 离线推送（ntfy）—— 进程被杀/锁屏时的唯一叫醒方式（v1.13）
          _buildSectionHeader('离线推送 (ntfy)', Icons.notifications_active_rounded, context.c.warning),
          const SizedBox(height: 8),
          _buildPushSection(context, dsh),

          const SizedBox(height: 16),

          // 4. Connectivity & Network Diagnostics
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
                        icon: Icon(Icons.system_update_rounded, size: 16, color: context.c.accent),
                        label: Text('检查更新', style: TextStyle(color: context.c.accent, fontSize: 12, fontWeight: FontWeight.w600)),
                        onPressed: () => _checkForUpdate(context, dsh),
                      ),
                    ),
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

  /// 添加一条提示词模板：标签 + 内容，保存到网关。
  Future<void> _showAddSnippetDialog(BuildContext context, DshService dsh) async {
    final labelController = TextEditingController();
    final textController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: context.c.border)),
        title: Text('添加模板', style: TextStyle(color: context.c.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: labelController,
              autofocus: true,
              maxLength: 20,
              decoration: InputDecoration(hintText: '显示名称（如：继续）', counterText: '', border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: textController,
              maxLines: 4,
              maxLength: 400,
              decoration: InputDecoration(hintText: '模板内容（将追加到输入框）', counterText: '', border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消', style: TextStyle(color: context.c.textSecondary))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: context.c.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              elevation: 0,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    final label = labelController.text.trim();
    final text = textController.text.trim();
    labelController.dispose();
    textController.dispose();
    if (ok != true || text.isEmpty) return;
    final next = [
      ...dsh.snippets,
      Snippet(id: 'snip_${DateTime.now().millisecondsSinceEpoch}', label: label.isEmpty ? text.substring(0, text.length.clamp(0, 20)) : label, text: text),
    ];
    await dsh.saveSnippets(next);
  }

  /// 检查更新：调网关 /api/mobile/version，比较 App 版本与 latestVersion。
  Future<void> _checkForUpdate(BuildContext context, DshService dsh) async {
    final messenger = ScaffoldMessenger.of(context);
    final hasUpdate = await dsh.checkForUpdate();
    if (!mounted) return;
    final info = dsh.gatewayVersion;
    final cfg = dsh.currentConfig;
    if (hasUpdate && info?.latestVersion != null) {
      // 有新版：直接给"去下载"动线（浏览器打开网关的 APK 直链）。
      final apkUrl = '${cfg?.httpBaseUrl ?? 'http://127.0.0.1:3088'}/dsh-agent.apk';
      final ok = await UrlOpener.open(apkUrl);
      if (!mounted) return;
      if (!ok) {
        Clipboard.setData(ClipboardData(text: apkUrl));
        messenger.showSnackBar(SnackBar(
          content: Text('发现新版本 v${info!.latestVersion}，但打不开浏览器。直链已复制：$apkUrl'),
          backgroundColor: context.c.warning,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } else if (info?.latestVersion == null) {
      messenger.showSnackBar(SnackBar(
        content: const Text('网关未配置最新版本号（DSH_LATEST_APP_VERSION）。当前已是客户端最新版。'),
        backgroundColor: context.c.success,
        behavior: SnackBarBehavior.floating,
      ));
    } else {
      messenger.showSnackBar(SnackBar(
        content: Text('当前已是最新版本 (v${AppVersion.version})'),
        backgroundColor: context.c.success,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Widget _buildSectionHeader(String title, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        // Expanded: 标题里有"大语言模型与思考引擎 (LLM & Reasoning)"这种长串，
        // 手机宽度下裸 Text 会把这一行撑爆（实测 420 逻辑宽溢出 67px，屏幕上
        // 是黄黑斜纹）。给它剩余宽度让它换行，而不是被裁掉。
        Expanded(
          child: Text(
            title,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: context.c.textPrimary),
          ),
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
