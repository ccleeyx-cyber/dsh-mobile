import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_version.dart';
import '../models/dsh_settings.dart';
import '../services/dsh_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../main.dart';
import 'alerts_view.dart';
import 'security_permissions_view.dart';
import 'settings/about_view.dart';
import 'settings/connectivity_view.dart';
import 'settings/gateway_switcher_card.dart';
import 'settings/push_settings_view.dart';
import 'settings/settings_widgets.dart';
import 'settings/snippets_view.dart';
import 'widgets/model_picker_sheet.dart';

/// 设置页 —— 现在是一个**入口式 hub**，不再是一张全量铺开的表单。
///
/// ## 为什么改成 hub
///
/// v1.33 之前这一屏有 9 张卡 3 种交互形态（只读状态 / 跳转入口 / 完整表单），
/// 用户想改主题要先滚过快捷指令编辑器与 ntfy 表单，而"检查更新"沉在最底。
/// 每一样东西本身都是对的，错的是**层级**：内容管理、诊断动作、关于更新都不该
/// 和"开关某个设置"平级铺在同一屏。
///
/// 现在这一屏只回答两件事：**现在是什么状态**（连接、通知、安全、模型、外观），
/// 以及**要改的更细的东西在哪里**（四个二级页）。判断标准很简单 —— 一行里如果
/// 需要输入文字、需要滚过 4 屏列表、需要下载文件，它就不属于首页。
///
/// 二级页：
///  * [ConnectivityView] —— 原「网关健康」+「网络与网关诊断」合并；
///  * [PushSettingsView] —— 原内联的 ntfy 表单；
///  * [SnippetsView] —— 原内联的快捷指令列表与编辑器；
///  * [AboutView] —— 版本、检查更新、发布页。
///
/// 「运维面板」（HostOpsView）在 v1.33 整体移除：服务端命令、文件浏览、目标板
/// 与连接诊断里真正需要的部分（重连、换服务器、健康指标）重叠度高，而它承担
/// 的其余职责都属于桌面端。
class CustomSettingsView extends StatelessWidget {
  /// 安全策略页是**推入**的，页内"去处理"需要回到对话 tab —— 只有 MainShell 能
  /// 切 tab，所以从上面传进来。为 null 时"去处理"退化成只关掉本页。
  final VoidCallback? onOpenChat;

  const CustomSettingsView({super.key, this.onOpenChat});

  void _push(BuildContext context, Widget page) {
    // 推页面前把焦点交出去。设置 hub 自己没有输入框，但对话页的输入框仍活在
    // IndexedStack 里 —— 从二级页返回时它会成为"焦点恢复"的目标，系统输入法
    // 就会在设置页上弹出来（用户实测的 bug）。
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final dsh = context.watch<DshService>();
    final settings = dsh.settings;
    final currentModel = settings?.currentModel ?? 'cn:deepseek-v4.1-flash';
    final waiting = dsh.pendingApprovals.length + dsh.pendingQuestions.length;

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
            const SizedBox(width: AppSpace.m),
            Text(
              '设置',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.c.textPrimary),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        children: [
          // 0. 当前服务器 + 一键切换。
          //
          // 多网关是重度用法：家里一台、公司一台，切换频率远高于改任何设置。
          // 放在第一层，点开面板选一台就直接连接；新增/重命名仍走管理页。
          GatewaySwitcherCard(dsh: dsh),
          const SizedBox(height: AppSpace.m),

          // 1. 连接与诊断：出问题时用户最想立刻看到的东西，紧跟服务器卡。
          SettingsNavCard(
            key: const ValueKey('settings-open-connectivity'),
            icon: Icons.monitor_heart_outlined,
            title: '连接与诊断',
            subtitle: _connectivitySummary(dsh),
            dotColor: _connectionColor(context, dsh),
            subtitleColor: dsh.isConnected ? null : _connectionColor(context, dsh),
            badge: waiting > 0 ? '$waiting 项待处理' : null,
            onTap: () => _push(context, const ConnectivityView()),
          ),
          const SizedBox(height: AppSpace.m),
          // [remove 2026-10-25] 「远程访问」入口删除。
          //
          // 用户判断得对：这一页只读状态，而它描述的东西（公网通道建到哪一步）
          // **只在连不上时才有意义，而连不上时这一页本身就刷新不出来**；连得上
          // 时又不看它。所以它既救不了急，也不构成日常信息 —— 一个进不去又没
          // 人看的页面，留着只是让设置首屏多一张卡。
          //
          // 通道能力本身没有删：`DshService.refreshRemoteAccess` 与
          // `RemoteAccessState` 仍在（网关侧 /api/mobile/remote-access 继续可用），
          // 只是手机端不再有入口。
          const SizedBox(height: AppSpace.xl),

          // [v1.35] 运维入口：告警。它回答的是"人不在电脑前，还能不能把机器
          // 照顾好"，与"连接是否通畅"是同一层的问题。
          //
          // [move 2026-10-21] Runbook 已从本页移除，改为**会话信息面板**里的一个
          // tab。原因是它依赖会话上下文：网关按「会话 cwd」执行命令，而这个入口
          // 没有会话，cwd 回落到 ~/.dsh，`git log` / `git status` 一律报
          // not a git repository（默认模板三条里两条是 git）—— 等于功能不可用。
          SettingsSectionHeader(
            title: '运维',
            icon: Icons.build_outlined,
            color: context.c.warning,
          ),
          const SizedBox(height: AppSpace.m),
          SettingsNavCard(
            key: const ValueKey('settings-open-alerts'),
            icon: Icons.notification_important_outlined,
            title: '告警',
            subtitle: dsh.alertUnread > 0
                ? '${dsh.alertUnread} 条未读'
                : '回合失败 / 引擎掉线 / 作业失败',
            badge: dsh.alertUnread > 0 ? '${dsh.alertUnread}' : null,
            onTap: () => _push(context, const AlertsView()),
          ),
          const SizedBox(height: AppSpace.xl),
          // 1. 通知：本地通知状态与离线推送**必须挨着**。它们是同一件事的两条
          //    路径（App 活着时本地弹，App 死了走 ntfy），旧版被安全策略卡隔开，
          //    用户在两张卡之间来回看也拼不出完整因果。
          SettingsSectionHeader(
            title: '通知',
            icon: Icons.notifications_none_rounded,
            color: context.c.warning,
          ),
          const SizedBox(height: AppSpace.m),
          _buildNotificationCard(context, dsh),
          const SizedBox(height: AppSpace.m),
          SettingsNavCard(
            key: const ValueKey('settings-open-push'),
            icon: Icons.notifications_active_outlined,
            title: '离线推送（ntfy）',
            subtitle: _pushSummary(dsh),
            onTap: () => _push(context, const PushSettingsView()),
          ),
          const SizedBox(height: AppSpace.xl),

          // 2. 安全与授权（v1.22 从一级 tab 降级，v1.33 保持推入）。
          SettingsSectionHeader(
            title: '安全与授权',
            icon: Icons.shield_outlined,
            color: waiting > 0 ? context.c.warning : context.c.accent,
          ),
          const SizedBox(height: AppSpace.m),
          _buildSecurityEntry(context, dsh, waiting),
          const SizedBox(height: AppSpace.xl),

          // 3. 模型：只在首页留"当前值 + 更换"，不铺开参数。
          SettingsSectionHeader(
            title: '模型与思考引擎',
            icon: Icons.smart_toy_outlined,
            color: context.c.accent,
          ),
          const SizedBox(height: AppSpace.m),
          _buildModelCard(context, dsh, currentModel),
          const SizedBox(height: AppSpace.xl),

          // 4. 快捷指令：内容管理，进二级页。
          SettingsNavCard(
            key: const ValueKey('settings-open-snippets'),
            icon: Icons.bolt_rounded,
            title: '快捷指令',
            subtitle: _snippetsSummary(dsh),
            onTap: () => _push(context, const SnippetsView()),
          ),
          const SizedBox(height: AppSpace.xl),

          // 5. 外观。
          SettingsSectionHeader(
            title: '外观',
            icon: Icons.palette_outlined,
            color: context.c.purple,
          ),
          const SizedBox(height: AppSpace.m),
          _buildAppearanceCard(context),
          const SizedBox(height: AppSpace.xl),

          // 6. 关于与更新：一次网络请求 + 一次下载校验，属于重流程，进二级页。
          SettingsNavCard(
            key: const ValueKey('settings-open-about'),
            icon: Icons.info_outline_rounded,
            title: '关于与更新',
            // 版本号只有一个真源（pubspec → 构建期注入 → AppVersion），
            // 这里只做摘要，不另起一份常量。
            subtitle: 'DSH Mobile Pro v${AppVersion.version} · 检查更新与发布页',
            onTap: () => _push(context, const AboutView()),
          ),
        ],
      ),
    );
  }

  String _connectivitySummary(DshService dsh) {
    if (dsh.isTokenInvalid) return '令牌失效 · 需要更新访问令牌';
    if (!dsh.isConnected) {
      return dsh.lastError.isEmpty ? '未连接 · 点开诊断' : '未连接 · ${dsh.lastError}';
    }
    final ping = dsh.pingMs >= 0 ? '${dsh.pingMs} ms' : '未测速';
    final running = dsh.workspaces.fold<int>(0, (n, ws) => n + ws.sessions.where((s) => s.isRunning).length);
    return running > 0 ? '已连接 · $ping · $running 个会话执行中' : '已连接 · $ping';
  }

  Color _connectionColor(BuildContext context, DshService dsh) {
    if (dsh.isTokenInvalid) return context.c.danger;
    if (!dsh.isConnected) return context.c.warning;
    return context.c.success;
  }

  String _pushSummary(DshService dsh) {
    final cfg = dsh.pushConfig;
    if (cfg == null) return '网关未上报配置（旧版网关？）';
    if (!cfg.configured) return '未开启 · 进程被杀/锁屏时收不到提醒';
    return '已开启 · ${cfg.topic.isEmpty ? 'topic 未设置' : cfg.topic}';
  }

  String _snippetsSummary(DshService dsh) {
    final remote = dsh.snippets.length;
    return remote == 0 ? '本机模板 · 在对话输入框的 ⚡ 里使用' : '含 $remote 条网关下发模板 · 在输入框 ⚡ 里使用';
  }

  /// 「通知链路」状态卡。
  ///
  /// **不提供开关**，只如实显示当前能不能收到通知。理由：能不能收到不取决于
  /// 用户能在 App 内改变的事 —— 系统通知权限、后台保活、有没有划掉常驻通知。
  /// 给一个开关却无法保证它有效，比不给开关更糟。
  ///
  /// 三态必须分明：可用 / 有权限但链路异常（并给出原因）/ 没有权限。旧版只看
  /// 权限，于是插件初始化失败、一条通知都发不出去时，卡片仍然显示绿色的
  /// 「后台通知已开启」。
  Widget _buildNotificationCard(BuildContext context, DshService dsh) {
    final granted = dsh.notificationPermissionGranted;
    final ready = dsh.notificationsReady;
    final err = dsh.notificationError;
    final backgroundOn = dsh.notificationBackgroundOn;

    final (Color iconColor, IconData icon, String title, String subtitle) = ready
        ? (
            context.c.success,
            Icons.notifications_active_outlined,
            '后台通知已开启',
            'Agent 需要你授权或回答时会弹通知；App 在前台时不打扰。'
                '${backgroundOn ? "前台保活已启动。" : "前台保活未启动 —— App 被系统回收后连接会断，届时收不到通知。"}'
          )
        : granted
            ? (
                context.c.danger,
                Icons.notifications_off_outlined,
                '通知链路异常，通知发不出去',
                '已获得通知权限，但通知组件没有就绪，因此一条也发不出来。'
                    '${err == null ? "" : "原因：$err"}'
              )
            : (
                context.c.warning,
                Icons.notifications_off_outlined,
                '通知未开启，你将收不到提醒',
                'Android 13 及以上需要授权。请到 系统设置 → 应用 → DSH Mobile → 通知 中开启。'
              );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: settingsCardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: iconColor),
              const SizedBox(width: AppSpace.m),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.s),
          Text(
            subtitle,
            style: TextStyle(fontSize: AppText.subhead, height: 1.5, color: context.c.textSecondary),
          ),
        ],
      ),
    );
  }

  /// 安全策略入口。
  Widget _buildSecurityEntry(BuildContext context, DshService dsh, int waiting) {
    final color = waiting > 0 ? context.c.warning : context.c.accent;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (routeCtx) => SecurityPermissionsView(
            // 页内「去处理」= 关掉本页 + 切到对话 tab（审批与提问都在对话页处理）。
            onOpenChat: () {
              Navigator.of(routeCtx).pop();
              onOpenChat?.call();
            },
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: settingsCardDecoration(context),
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
            const SizedBox(width: AppSpace.l),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '安全策略与授权',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                  ),
                  const SizedBox(height: AppSpace.xs),
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

  Widget _buildModelCard(BuildContext context, DshService dsh, String currentModel) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: settingsCardDecoration(context),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: context.c.accent.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.psychology_outlined, color: context.c.accent, size: 22),
          ),
          const SizedBox(width: AppSpace.l),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前全局默认模型',
                    style: TextStyle(color: context.c.textSecondary, fontSize: 11)),
                const SizedBox(height: AppSpace.xs),
                Text(
                  currentModel,
                  style: TextStyle(color: context.c.textPrimary, fontSize: 14, fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpace.xs),
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
    );
  }

  /// 外观 / 主题选择。
  ///
  /// 用三选一分段控件而不是一个循环切换按钮：这里是要"选一个状态"，分段控件能
  /// 一眼看到当前值和全部可选值；顶栏那个循环按钮适合低频快速切换。
  Widget _buildAppearanceCard(BuildContext context) {
    final theme = context.watch<ThemeController>();
    const options = [
      ('system', '跟随系统', Icons.brightness_auto_rounded),
      ('light', '浅色', Icons.light_mode_rounded),
      ('dark', '深色', Icons.dark_mode_rounded),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: settingsCardDecoration(context),
      child: Row(
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
            if (mode != 'dark') const SizedBox(width: AppSpace.m),
          ],
        ],
      ),
    );
  }

  /// 全局默认模型选择 —— [feat 2026-10-22] 与对话页共用同一个**按供应商分组**的
  /// 弹层（`model_picker_sheet.dart`），只是把"选中之后做什么"换成改全局默认。
  void _showModelSwitchSheet(BuildContext context, DshService dsh) {
    final settings = dsh.settings;
    final currentModel = settings?.currentModel ?? 'cn:deepseek-v4.1-flash';
    final messenger = ScaffoldMessenger.of(context);
    final success = context.c.success;
    final modelList = (settings != null && settings.availableModels.isNotEmpty)
        ? settings.availableModels
        : [
            ModelItem(
                id: 'cn:deepseek-v4.1-flash',
                name: 'DeepSeek V4.1 Flash',
                contextWindow: 1000000,
                maxTokens: 16384,
                provider: 'cn',
                providerLabel: 'cn'),
            ModelItem(
                id: 'cn:deepseek-v4-pro',
                name: 'DeepSeek V4 Pro',
                contextWindow: 1000000,
                maxTokens: 32768,
                provider: 'cn',
                providerLabel: 'cn'),
            ModelItem(
                id: 'cn:kimi-k3-1',
                name: 'Kimi K3.1',
                contextWindow: 1000000,
                maxTokens: 32768,
                provider: 'cn',
                providerLabel: 'cn'),
          ];

    showModelPickerSheet(
      context: context,
      models: modelList,
      selectedModelId: currentModel,
      selectedProviderKey: settings?.currentModelProvider ?? '',
      title: '全局默认模型',
      subtitle: 'App 新建会话时用它',
      note: '引擎侧的全局默认要重启 dsh web 才对齐；App 新会话立即生效。',
      onPick: (m) async {
        // 设置页改的是**全局默认**，不是某个会话。
        final ok = await dsh.setDefaultModel(m.id);
        if (!ok) return;
        messenger.clearSnackBars();
        messenger.showSnackBar(
          SnackBar(
            content: Text('全局默认已设为 ${m.name}（App 新建会话生效；引擎对齐需重启 dsh web）'),
            backgroundColor: success,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      },
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
