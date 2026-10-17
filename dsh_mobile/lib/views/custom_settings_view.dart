import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/dsh_settings.dart';
import '../models/app_version.dart';
import '../models/client_update.dart';
import '../models/gateway_features.dart';
import '../models/local_snippet.dart';
import '../services/dsh_service.dart';
import '../services/platform_services.dart';
import '../services/storage_service.dart';
import '../services/update_service.dart';
import 'config_page.dart';
import 'gateway_health_view.dart';
import 'host_ops_view.dart';
import 'push_setup_view.dart';
import 'security_permissions_view.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../main.dart';
import 'widgets/snippet_param_dialog.dart';

class CustomSettingsView extends StatefulWidget {
  /// [feat 2026-10-17] 安全策略页是**推入**的（不再是底部导航的一级 tab），
  /// 页内"去处理"需要回到对话 tab —— 而只有 MainShell 能切 tab，所以从上面传进来。
  /// 为 null 时"去处理"退化成只关掉本页（不给一个点了没反应的按钮）。
  final VoidCallback? onOpenChat;

  /// 测试注入口：用内存里的「网关下发条目」替代 `dsh.snippets`。
  ///
  /// 为什么需要：合并列表那条规则（本地在前、网关只读）只有在两边的条目同时存在
  /// 时才看得见，而 `DshService.snippets` 只能由一次真实 HTTP 抓取填充 —— widget
  /// 测试不该为了一行顺序去打真网关（历史上打真网关的测试往用户会话里塞过垃圾）。
  /// 生产路径永远不传它。
  @visibleForTesting
  final List<Snippet>? debugRemoteSnippets;

  const CustomSettingsView({super.key, this.onOpenChat, this.debugRemoteSnippets});

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

  /// 检查/下载更新进行中（只有用户主动点才会置位 —— 启动时不查更新）。
  bool _updateBusy = false;

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

  // ---- 本地快捷指令（v1.27，Phase 5.4）----
  //
  // 只读一份内存副本：本地条目是"少数几条、一次性改完"的东西，不值得为它引状态
  // 管理。真源在 StorageService 的 `dsh_local_snippets`，任何一次改动都**先写盘
  // 再更新内存**（写失败会留在屏幕上并如实提示，见 _persistLocalSnippets）。
  List<LocalSnippet> _localSnippets = const [];
  bool _snippetsLoading = true;
  String? _localSnippetsError;

  @override
  void initState() {
    super.initState();
    _loadLocalSnippets();
  }

  Future<void> _loadLocalSnippets() async {
    var list = const <LocalSnippet>[];
    String? error;
    try {
      list = await StorageService.loadLocalSnippets();
    } on MissingPluginException {
      // 没有本地存储后端（widget 测试、或极早期启动还没挂上插件）：当成"还没有
      // 本地指令"。这不是数据丢失，写的时候会照实报错。
      error = null;
    } catch (e) {
      // 读失败也不清数据、不崩页：界面降级成只读那一档。
      error = '$e';
    }
    if (!mounted) return;
    setState(() {
      _localSnippets = list;
      _snippetsLoading = false;
      _localSnippetsError = error;
    });
  }

  /// 写盘并同步内存。失败时保留屏幕上的改动但明说"没能存住" —— 静默把它改回去，
  /// 用户会以为点保存没反应。
  Future<void> _persistLocalSnippets(List<LocalSnippet> next) async {
    setState(() => _localSnippets = next);
    try {
      await StorageService.saveLocalSnippets(next);
      if (_localSnippetsError != null && mounted) {
        setState(() => _localSnippetsError = null);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _localSnippetsError = '$e');
      _settingsToast('没能写入本地存储，这条改动重启后会丢');
    }
  }

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
                                      // 设置页改的是**全局默认**，不是某个会话。以前这里
                                      // 调 switchModel，它会同时写会话级（而那条路是哑的）
                                      // 与全局，语义含混；现在各走各的。
                                      final ok = await dsh.setDefaultModel(m.id);
                                      if (ok && context.mounted) {
                                        ScaffoldMessenger.of(context).clearSnackBars();
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            // 写明生效范围与生效时机：实测写进 settings.yaml
                                            // 后，正在运行的会话要到重启 dsh web 才会采用。
                                            content: Text('已将全局默认模型设为 ${m.name}（新建会话生效；正在运行的会话需重启 dsh web）'),
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

  /// 一张"跳去另一个页面"的行卡片：图标 + 标题 + 副标题 + 箭头。
  ///
  /// 与信息卡（键值对）刻意区分开：设置页里"显示一个值"和"去一个地方"是两类东西，
  /// 混在同一张卡里最容易出现的问题就是用户不知道哪块能点。
  Widget _navCard({
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: _cardDecoration(),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  // 浅品牌色底 + 同色图标：与上面那张「安全策略与授权」卡片的
                  // 图标方块保持同一套语言（纯灰底在设置页里只有"次要信息"才用）。
                  color: context.c.accent.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 17, color: context.c.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: context.c.textPrimary)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(fontSize: 11.5, color: context.c.textTertiary)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 20, color: context.c.textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  BoxDecoration _cardDecoration() {    return BoxDecoration(
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
          // [feat 2026-10-13] 一键生成的入口。
          //
          // 为什么必须在这里给一个按钮：ntfy 的 topic 是**按名字公开**的，可猜的名字
          // 等于把每一条审批/提问广播给猜中的人，所以正确做法是用随机串；而随机的
          // 20 位串没人愿意手打。下面对话框里既有一键生成，也有随机串的订阅深链。
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PushSetupView()),
              ),
              icon: Icon(Icons.qr_code_2_rounded, size: 18, color: context.c.accent),
              label: Text(
                '一键生成随机 topic / 订阅链接',
                style: TextStyle(fontSize: 12.5, color: context.c.accent),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
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
              Text(
                '主题模式',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.textPrimary),
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

  /// [feat 2026-10-17] 安全策略入口。
  ///
  /// 它原本是底部导航的第 3 个一级 tab，与「对话」平级 —— 而权限/审批预设是低频
  /// 配置，占一个一级入口的同时还在导航上重复显示同一个待审批角标（角标同时挂在
  /// 「工作区」和「安全策略」上）。改成从设置推入后，一级导航只剩 对话/工作区/设置。
  Widget _buildSecurityEntry(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final waiting = dsh.pendingApprovals.length + dsh.pendingQuestions.length;
    final color = waiting > 0 ? context.c.warning : context.c.accent;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (routeCtx) => SecurityPermissionsView(
            // 页内「去处理」= 关掉本页 + 切到对话 tab（审批与提问都在对话页处理）。
            onOpenChat: () {
              Navigator.of(routeCtx).pop();
              widget.onOpenChat?.call();
            },
          ),
        ),
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
              child: Icon(Icons.shield_outlined, color: color, size: 21),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '安全策略与授权',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    waiting > 0
                        ? '$waiting 项等待处理 · 权限、审批预设'
                        : 'Agent 执行权限、审批规则与预设',
                    key: const ValueKey('settings-security-subtitle'),
                    style: TextStyle(fontSize: 12, color: waiting > 0 ? color : context.c.textSecondary),
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
          const SizedBox(height: 16),
          // [feat 2026-10-17] 安全策略从一级 tab 降到这里（见 _buildSecurityEntry）。
          _buildSecurityEntry(context),
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
                          Text('当前全局默认模型', style: TextStyle(color: context.c.textSecondary, fontSize: 11)),
                          const SizedBox(height: 2),
                          Text(
                            currentModel,
                            style: TextStyle(color: context.c.textPrimary, fontSize: 14, fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '只影响新建会话；正在运行的会话在聊天页单独切换（立即生效）',
                            style: TextStyle(color: context.c.textTertiary, fontSize: 10.5),
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
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 2.5 快捷指令（本地 + 网关下发合并展示，Phase 5.4）
          _buildSectionHeader('快捷指令 (Quick Snippets)', Icons.bolt_rounded, context.c.warning),
          const SizedBox(height: 8),
          _buildSnippetsSection(context, widget.debugRemoteSnippets ?? dsh.snippets),

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
                const SizedBox(height: 12),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // [feat 2026-10-17] 「运维面板」入口从会话信息面板搬到这里。
          //
          // 它做的是**主机 / 引擎级**的活：跑白名单命令、浏览服务端文件、看连接
          // 诊断、管目标板。挂在会话信息面板里等于把服务端运维伪装成"这个会话的
          // 功能"，而它真正被用到的时机恰恰是"连不上 / 引擎异常"—— 也就是用户会
          // 来设置页排查的时候。
          //
          // 形态做成一整张**行卡片**（图标 + 标题 + 副标题 + 箭头），而不是塞进上面
          // 那张卡片底部的一个按钮：上面那张卡里全是"当前值"（地址、延迟、上游），
          // 混一个"跳去另一个页面"的按钮会把只读的信息区和导航动作搅在一起。
          // 独立成卡之后，它和上面那张是同级的两块，一眼能分清"这块是值，那块是门"。
          _navCard(
            key: const ValueKey('settings-open-host-ops'),
            icon: Icons.dns_outlined,
            title: '运维面板',
            subtitle: '服务端命令 · 文件浏览 · 连接诊断 · 目标板',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HostOpsView()),
              );
            },
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
                        // 真源是 pubspec.yaml，构建期经 --dart-define 注入
                        // （见 lib/models/app_version.dart 顶部链路说明），
                        // 这里只是读值，没有任何写死的版本字面量。
                        Text(
                          '版本: v${AppVersion.version} (Build ${AppVersion.buildNumber})',
                          style: TextStyle(color: context.c.textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 更新动线两条，前者是加速源、后者是保底：
                //  1) 「检查更新」读发布页**同级**的可选清单
                //     (releases/latest/download/latest.json)，拿到 versionCode /
                //     size / sha256 才能做真正的校验，并在 App 内下载+校验后交给
                //     系统安装器；
                //  2) 清单取不到（发布方没放/离线/坏 JSON）→ 回退到「打开发布页」，
                //     也就是这条动线一直以来的行为，功能不变差。
                //
                // 刻意**不**查网关的 /api/mobile/version、不用 DSH_LATEST_APP_VERSION ——
                // 那套东西要求网关侧额外配置环境变量并手工把 APK 放到盘上，任何一个
                // 漏了都会让界面言之凿凿地说"已是最新"，比不做更糟。也刻意**不**在
                // 启动时自动检查：只在用户点下去的那一刻才发请求。
                Text(
                  '客户端是自签名侧载安装的，系统不会自动更新。点「检查更新」可以在 App 内下载并校验（字节数 / sha256）；校验不过会拒绝安装，最终签名一致性由系统安装器裁决。',
                  style: TextStyle(fontSize: 11, color: context.c.textTertiary, height: 1.35),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: _updateBusy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.system_update_alt_rounded, size: 16),
                    label: Text(
                      _updateBusy ? '正在处理…' : '检查更新',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: context.c.accent,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: _updateBusy ? null : () => _checkForUpdate(context),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        icon: Icon(Icons.open_in_new_rounded, size: 16, color: context.c.accent),
                        label: Text('打开发布页', style: TextStyle(color: context.c.accent, fontSize: 12, fontWeight: FontWeight.w600)),
                        onPressed: () => _openDownloadPage(context),
                      ),
                    ),
                    Expanded(
                      child: TextButton.icon(
                        icon: Icon(Icons.link_rounded, size: 16, color: context.c.accent),
                        label: Text('复制发布页链接', style: TextStyle(color: context.c.accent, fontSize: 12, fontWeight: FontWeight.w600)),
                        onPressed: () {
                          Clipboard.setData(const ClipboardData(text: AppVersion.releasesUrl));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: const Text('已复制: ${AppVersion.releasesUrl}'),
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

  /// 「快捷指令」分区（v1.27，Phase 5.4）。
  ///
  /// 列表 = **本地条目**（可改可删可排序，排前面，带「本地」徽标）+ **网关下发
  /// 条目**（只读，带「网关」徽标 + 锁）。
  ///
  /// 为什么合并成一个列表而不是两个分区：对用户来说"我有哪些快捷指令"只有一个
  /// 答案。分成两块，他就得猜哪一份是真正会出现在输入框里的，而两份的名字还可能
  /// 撞车。顺序（本地优先）与可编辑性（网关只读）都在这一层表达，模型层不掺和。
  Widget _buildSnippetsSection(BuildContext context, List<Snippet> remote) {
    final local = _localSnippets;

    return Container(
      key: const ValueKey('settings-snippets-section'),
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '聊天输入框「命令与模板」里列出的快捷模板。本地条目排在最前面、可改可删可排序，'
            '只存在这台手机上；网关下发的条目在这里只读（真源在服务端）。'
            '正文里的 {参数} 会在插入前让你一屏填完。',
            style: TextStyle(
              color: context.c.textSecondary,
              fontSize: AppText.body,
              height: 1.35,
            ),
          ),
          const SizedBox(height: AppSpace.l),
          if (_snippetsLoading)
            Row(
              key: const ValueKey('settings-snippets-loading'),
              children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: AppSpace.m),
                Text(
                  '正在读取本地快捷指令…',
                  style: TextStyle(fontSize: AppText.caption, color: context.c.textSecondary),
                ),
              ],
            )
          else ...[
            if (_localSnippetsError != null) ...[
              _buildSnippetsStorageWarning(context),
              const SizedBox(height: AppSpace.l),
            ],
            if (local.isEmpty && remote.isEmpty)
              Text(
                '还没有快捷指令。点下面「新增本地指令」建一条 —— 它只存在这台手机上，删网关也不会丢。',
                style: TextStyle(fontSize: AppText.body, color: context.c.textTertiary, height: 1.35),
              ),
            for (var i = 0; i < local.length; i++) _buildLocalSnippetRow(context, i),
            for (final s in remote) _buildRemoteSnippetRow(context, s),
            if (local.isNotEmpty && remote.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.s),
                child: Text(
                  '网关还没有下发过模板；这一屏的本地条目不会上传到网关。',
                  style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('snippet-add-local'),
                icon: Icon(Icons.add_rounded, size: 16, color: context.c.accent),
                label: Text(
                  '新增本地指令',
                  style: TextStyle(
                    color: context.c.accent,
                    fontSize: AppText.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => _showLocalSnippetEditor(context),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 读/写本地存储失败时的诚实提示。
  ///
  /// 它不写"出错了"了事，而是说明**已保存的内容没有被动过** —— 用户最怕的是
  /// "我的东西是不是被删了"，而这一屏确实没删。
  Widget _buildSnippetsStorageWarning(BuildContext context) {
    return Container(
      key: const ValueKey('settings-snippets-storage-warning'),
      padding: const EdgeInsets.all(AppSpace.l),
      decoration: BoxDecoration(
        color: context.c.warningSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.c.warningBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 15, color: context.c.warning),
          const SizedBox(width: AppSpace.m),
          Expanded(
            child: Text(
              '本地存储不可用：这一屏现在读不到/存不住本地指令，'
              '但已经存下的内容没有被删除，其余设置也不受影响。',
              style: TextStyle(fontSize: AppText.caption, height: 1.35, color: context.c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSnippetBadge(BuildContext context, String text, Color color, Key key) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: AppText.caption, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  /// 本地条目：整行可编辑 + 上移/下移（不做拖拽 —— 手机上一屏能放几条，拖拽的
  /// 命中成本比点两下箭头高得多）。
  Widget _buildLocalSnippetRow(BuildContext context, int index) {
    final s = _localSnippets[index];
    final placeholders = s.placeholders;
    final label = s.label.trim().isEmpty ? LocalSnippet.autoLabel(s.text) : s.label.trim();

    return Container(
      key: ValueKey('snippet-row-${s.id}'),
      margin: const EdgeInsets.only(bottom: AppSpace.m),
      padding: const EdgeInsets.fromLTRB(AppSpace.l, AppSpace.m, AppSpace.s, AppSpace.s),
      decoration: BoxDecoration(
        color: context.c.surfaceMuted,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppText.body,
                    fontWeight: FontWeight.w600,
                    color: context.c.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.m),
              _buildSnippetBadge(context, '本地', context.c.accent, ValueKey('snippet-local-badge-${s.id}')),
              if (s.tag.trim().isNotEmpty) ...[
                const SizedBox(width: AppSpace.s),
                _buildSnippetBadge(
                  context,
                  '#${s.tag.trim()}',
                  context.c.purple,
                  ValueKey('snippet-tag-${s.id}'),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            s.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppText.subhead, height: 1.35, color: context.c.textSecondary),
          ),
          if (placeholders.isNotEmpty) ...[
            const SizedBox(height: AppSpace.xs),
            Text(
              '参数：${placeholders.map((p) => '{$p}').join(' ')}',
              key: ValueKey('snippet-params-${s.id}'),
              style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
            ),
          ],
          const SizedBox(height: AppSpace.xs),
          Row(
            children: [
              Expanded(
                child: Text(
                  placeholders.isEmpty ? '' : '插入前会弹一屏填参数',
                  style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
                ),
              ),
              _snippetIconButton(
                context,
                key: ValueKey('snippet-fill-${s.id}'),
                icon: Icons.playlist_add_check_rounded,
                tooltip: '试填并复制',
                onPressed: () => _previewLocalSnippet(context, s),
              ),
              _snippetIconButton(
                context,
                key: ValueKey('snippet-up-${s.id}'),
                icon: Icons.arrow_upward_rounded,
                tooltip: '上移',
                onPressed: index == 0 ? null : () => _moveLocalSnippet(index, -1),
              ),
              _snippetIconButton(
                context,
                key: ValueKey('snippet-down-${s.id}'),
                icon: Icons.arrow_downward_rounded,
                tooltip: '下移',
                onPressed: index == _localSnippets.length - 1 ? null : () => _moveLocalSnippet(index, 1),
              ),
              _snippetIconButton(
                context,
                key: ValueKey('snippet-edit-${s.id}'),
                icon: Icons.edit_outlined,
                tooltip: '编辑',
                onPressed: () => _showLocalSnippetEditor(context, existing: s),
              ),
              _snippetIconButton(
                context,
                key: ValueKey('snippet-delete-${s.id}'),
                icon: Icons.delete_outline_rounded,
                tooltip: '删除',
                color: context.c.danger,
                onPressed: () => _deleteLocalSnippet(context, s),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 网关下发的条目：**只读**。没有编辑/删除按钮，而不是给一个点了没反应的图标。
  Widget _buildRemoteSnippetRow(BuildContext context, Snippet s) {
    final placeholders = LocalSnippet.placeholderNames(s.text);
    final label = s.label.trim().isEmpty ? LocalSnippet.autoLabel(s.text) : s.label.trim();

    return Container(
      key: ValueKey('snippet-row-gateway-${s.id}'),
      margin: const EdgeInsets.only(bottom: AppSpace.m),
      padding: const EdgeInsets.all(AppSpace.l),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppText.body,
                    fontWeight: FontWeight.w600,
                    color: context.c.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.m),
              _buildSnippetBadge(context, '网关', context.c.textTertiary, ValueKey('snippet-gateway-badge-${s.id}')),
              const SizedBox(width: AppSpace.s),
              Icon(Icons.lock_outline_rounded, size: 13, color: context.c.textTertiary),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            s.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppText.subhead, height: 1.35, color: context.c.textSecondary),
          ),
          if (placeholders.isNotEmpty) ...[
            const SizedBox(height: AppSpace.xs),
            Text(
              '参数：${placeholders.map((p) => '{$p}').join(' ')}',
              style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _snippetIconButton(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      icon: Icon(
        icon,
        size: 16,
        color: onPressed == null ? context.c.textTertiary : (color ?? context.c.textSecondary),
      ),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      onPressed: onPressed,
    );
  }

  /// 新增/编辑本地指令。空名称回落为正文首行，空正文拒绝。
  Future<void> _showLocalSnippetEditor(BuildContext context, {LocalSnippet? existing}) async {
    final labelController = TextEditingController(text: existing?.label ?? '');
    final textController = TextEditingController(text: existing?.text ?? '');
    final tagController = TextEditingController(text: existing?.tag ?? '');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.c.border),
        ),
        title: Text(
          existing == null ? '新增本地指令' : '编辑本地指令',
          style: TextStyle(
            fontSize: AppText.title,
            fontWeight: FontWeight.bold,
            color: context.c.textPrimary,
          ),
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '只保存在这台手机上，不上传网关。正文里的 {参数} 会在插入前让你一屏填完。',
                  style: TextStyle(fontSize: AppText.caption, height: 1.35, color: context.c.textSecondary),
                ),
                const SizedBox(height: AppSpace.l),
                TextField(
                  key: const ValueKey('snippet-editor-label'),
                  controller: labelController,
                  autofocus: true,
                  maxLength: 24,
                  style: TextStyle(fontSize: AppText.body, color: context.c.textPrimary),
                  decoration: InputDecoration(
                    labelText: '名称',
                    hintText: '如：翻译成英文',
                    counterText: '',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: AppSpace.l),
                TextField(
                  key: const ValueKey('snippet-editor-text'),
                  controller: textController,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 2000,
                  keyboardType: TextInputType.multiline,
                  style: TextStyle(fontSize: AppText.body, color: context.c.textPrimary, height: 1.35),
                  decoration: InputDecoration(
                    labelText: '正文',
                    hintText: '如：把下面这段翻成{lang}：',
                    counterText: '',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: AppSpace.l),
                TextField(
                  key: const ValueKey('snippet-editor-tag'),
                  controller: tagController,
                  maxLength: 12,
                  style: TextStyle(fontSize: AppText.body, color: context.c.textPrimary),
                  decoration: InputDecoration(
                    labelText: '分类标签（可选）',
                    hintText: '如：翻译',
                    counterText: '',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: context.c.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: context.c.accent,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    final label = labelController.text.trim();
    final body = textController.text.trim();
    final tag = tagController.text.trim();
    labelController.dispose();
    textController.dispose();
    tagController.dispose();
    if (ok != true) return;
    if (body.isEmpty) {
      _settingsToast('正文为空，没有保存');
      return;
    }

    final resolvedLabel = label.isEmpty ? LocalSnippet.autoLabel(body) : label;
    final next = [..._localSnippets];
    if (existing == null) {
      if (next.length >= StorageService.maxLocalSnippets) {
        _settingsToast('本地指令最多 ${StorageService.maxLocalSnippets} 条');
        return;
      }
      next.add(LocalSnippet(
        id: 'local_${DateTime.now().microsecondsSinceEpoch}',
        label: resolvedLabel,
        text: body,
        tag: tag,
      ));
    } else {
      final i = next.indexWhere((x) => x.id == existing.id);
      if (i < 0) return;
      next[i] = next[i].copyWith(label: resolvedLabel, text: body, tag: tag);
    }
    await _persistLocalSnippets(next);
    _settingsToast(existing == null ? '已新增本地指令' : '已保存');
  }

  Future<void> _moveLocalSnippet(int index, int delta) async {
    final j = index + delta;
    if (j < 0 || j >= _localSnippets.length) return;
    final next = [..._localSnippets];
    final moved = next.removeAt(index);
    next.insert(j, moved);
    await _persistLocalSnippets(next);
  }

  Future<void> _deleteLocalSnippet(BuildContext context, LocalSnippet snippet) async {
    final label = snippet.label.trim().isEmpty ? LocalSnippet.autoLabel(snippet.text) : snippet.label.trim();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.c.border),
        ),
        title: Text(
          '删除本地指令',
          style: TextStyle(fontSize: AppText.title, fontWeight: FontWeight.bold, color: context.c.textPrimary),
        ),
        content: Text(
          '「$label」会从这台手机上删掉；网关下发的同名条目（如果有）不受影响。',
          style: TextStyle(fontSize: AppText.body, height: 1.4, color: context.c.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: context.c.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: context.c.danger,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final next = [..._localSnippets]..removeWhere((x) => x.id == snippet.id);
    await _persistLocalSnippets(next);
    _settingsToast('已删除');
  }

  /// 设置页里的「试填」：走和输入框**同一条**参数对话框（`showSnippetParamDialog`），
  /// 填完把结果复制走。
  ///
  /// 为什么要在这里也能试填：用户在设置页写 `{参数}` 时，唯一能验证"这条指令填出来
  /// 是什么样"的机会就在这一屏。
  Future<void> _previewLocalSnippet(BuildContext context, LocalSnippet snippet) async {
    final label = snippet.label.trim().isEmpty ? LocalSnippet.autoLabel(snippet.text) : snippet.label.trim();
    final rendered = await showSnippetParamDialog(context, title: label, template: snippet.text);
    if (rendered == null) return;
    await Clipboard.setData(ClipboardData(text: rendered));
    _settingsToast(snippet.placeholders.isEmpty ? '已复制指令正文' : '已复制填好参数的正文');
  }

  /// 用户主动点「检查更新」才会走到这里（启动时不查，保持静默）。
  ///
  /// 三条出路，任何一条都不会让界面说假话：
  ///  * 有新版   → 显示版本/大小/说明，可选「下载并安装」；
  ///  * 已是最新 → 明确说已是最新（**只有真读到清单且 versionCode 不比本机大**才敢说）；
  ///  * 问不到 / 清单不可信 → 回退到老行为：打开发布页，并如实说明原因。
  Future<void> _checkForUpdate(BuildContext context) async {
    if (_updateBusy) return;
    setState(() => _updateBusy = true);
    // whenComplete 而不是 try/finally：结果本身是非空的局部变量，省掉"可能未赋值"的
    // 空分支，也保证任何退出路径都会把 busy 复位。
    final check = await UpdateService.check().whenComplete(() {
      if (mounted) setState(() => _updateBusy = false);
    });
    if (!context.mounted) return;

    if (check == null || check.verdict == UpdateVerdict.manifestRejected) {
      final why = check == null
          ? '读不到发布页同级的最新清单（latest.json）。'
          : '最新的清单不可信：${check.note}。';
      await _showUpdateDialog(
        context,
        title: '更新检查不可用',
        body: '$why\n\n这不是"已是最新"。回退到发布页：点「打开发布页」，按自己的 ABI 下载。',
        primaryLabel: '打开发布页',
        primary: () => _openDownloadPage(context),
      );
      return;
    }

    final manifest = check.manifest;
    if (check.verdict == UpdateVerdict.upToDate || manifest == null) {
      await _showUpdateDialog(
        context,
        title: '已是最新',
        body: '本机 v${AppVersion.version} (Build ${AppVersion.buildNumber})。\n'
            '发布页：v${manifest?.version ?? '—'}'
            '${manifest == null ? '' : ' (${manifest.versionCode})'}'
            '${check.note.isEmpty ? '' : '\n${check.note}'}',
      );
      return;
    }

    final size = manifest.size;
    await _showUpdateDialog(
      context,
      title: '发现新版本 v${manifest.version}',
      body: 'Build ${manifest.versionCode}（本机 ${AppVersion.buildNumber}）'
          '${size == null ? '' : '\n大小：${(size / 1048576).toStringAsFixed(1)} MB'}'
          '${manifest.sha256 == null ? '\n清单未提供 sha256：下载后会如实标注"未校验哈希"' : '\n清单提供了 sha256：下载后必须校验通过才交给系统安装器'}'
          '${manifest.releaseNotes == null ? '' : '\n\n${manifest.releaseNotes}'}',
      primaryLabel: '下载并安装',
      primary: () => _downloadAndInstall(context, manifest),
    );
  }

  /// 下载 → 校验 → 交系统安装器。校验不过**绝不下发安装**。
  Future<void> _downloadAndInstall(BuildContext context, UpdateManifest manifest) async {
    final messenger = ScaffoldMessenger.of(context);
    final accent = context.c.accent;
    setState(() => _updateBusy = true);
    final result = await UpdateService.download(manifest).whenComplete(() {
      if (mounted) setState(() => _updateBusy = false);
    });
    // 用 context.mounted（而不是 State.mounted）：这里的 context 是入参，
    // 分析器无法证明两者相关，用错的那个会被 use_build_context_synchronously 拦下。
    if (!context.mounted) return;

    if (result.error != null) {
      await _showUpdateDialog(
        context,
        title: '下载失败',
        body: '${result.error}\n\n回退：点「打开发布页」手动下载。',
        primaryLabel: '打开发布页',
        primary: () => _openDownloadPage(context),
      );
      return;
    }

    final integrity = result.integrity;
    if (integrity == null || !integrity.installable) {
      final detail = integrity == null ? '没有拿到校验结论' : integrity.note;
      final actual = integrity?.actualSha256 ?? '';
      await _showUpdateDialog(
        context,
        title: '校验未通过，已拒绝安装',
        body: '$detail\n'
            '${actual.isEmpty ? '' : '实收 sha256：$actual\n'}'
            '这份文件没有被交给系统安装器。请改用「打开发布页」手动下载。',
        primaryLabel: '打开发布页',
        primary: () => _openDownloadPage(context),
      );
      return;
    }

    final bytes = result.bytes;
    if (bytes == null) {
      await _showUpdateDialog(
        context,
        title: '下载内容为空',
        body: '没有拿到可安装的字节。请改用「打开发布页」手动下载。',
        primaryLabel: '打开发布页',
        primary: () => _openDownloadPage(context),
      );
      return;
    }

    final launched = await UpdateService.handToSystemInstaller(manifest, bytes);
    if (!context.mounted) return;
    if (launched) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('已交给系统安装器（${integrity.note}）；签名一致性由系统校验'),
          backgroundColor: accent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    await _showUpdateDialog(
      context,
      title: '系统安装器没有拉起',
      body: '包已下载并通过校验（${integrity.note}），但系统没有可处理 .apk 的安装界面。'
          '常见原因：本应用未声明 REQUEST_INSTALL_PACKAGES、或未在本机允许"安装未知应用"、'
          '或该 APK 的 ABI 与本机不匹配。\n\n请改用「打开发布页」手动下载安装。',
      primaryLabel: '打开发布页',
      primary: () => _openDownloadPage(context),
    );
  }

  /// 更新相关的统一提示框。[primary] 非空时给一个主按钮，点"确定"后才执行它。
  Future<void> _showUpdateDialog(
    BuildContext context, {
    required String title,
    required String body,
    String? primaryLabel,
    Future<void> Function()? primary,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.c.border),
        ),
        title: Text(
          title,
          style: TextStyle(color: context.c.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Text(
            body,
            style: TextStyle(color: context.c.textSecondary, fontSize: 13, height: 1.4),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('关闭', style: TextStyle(color: context.c.textSecondary)),
          ),
          if (primary != null && primaryLabel != null)
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: context.c.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                elevation: 0,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(primaryLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
    if (confirmed != true || primary == null) return;
    if (!context.mounted) return;
    await primary();
  }

  /// 打开发布页；打不开（无浏览器等）就把链接复制下来，绝不静默失败。
  ///
  /// 这里不再做版本比对：唯一真值来源是发布页本身，而"告诉用户有没有新版"需要
  /// 一个能问的服务端（GitHub API 或网关自报），那是用户明确不要的复杂度。
  /// 宁可不猜，也不给出一个可能过期的"已是最新"。
  Future<void> _openDownloadPage(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    // 主题色来自 Element（context.c），必须和 messenger 一样在 await 之前取。
    final warningColor = context.c.warning;
    final ok = await UrlOpener.open(AppVersion.releasesUrl);
    if (!mounted) return;
    if (ok) return;
    await Clipboard.setData(const ClipboardData(text: AppVersion.releasesUrl));
    messenger.showSnackBar(SnackBar(
      content: const Text('打不开浏览器，链接已复制：${AppVersion.releasesUrl}'),
      backgroundColor: warningColor,
      behavior: SnackBarBehavior.floating,
    ));
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
