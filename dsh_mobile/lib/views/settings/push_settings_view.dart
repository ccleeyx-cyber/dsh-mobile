import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/dsh_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../push_setup_view.dart';
import 'settings_widgets.dart';

/// 「离线推送（ntfy）」二级页。
///
/// ## 为什么从设置首页搬出来
///
/// 这里是一个完整表单（三个输入框 + 一段必须读的须知 + 保存/测试两个按钮），
/// 内联在设置页里等于让每个只想改主题的人滚过一屏表单。搬成二级页之后，
/// 首页只留一行入口和一句状态摘要，而本页可以把"为什么需要它、代价是什么"
/// 一次讲完，不再被相邻卡片挤成小字。
///
/// ## 内容规则（搬过来一字未改，都是踩过的坑）
///
/// * **发布方不是订阅方**：填好地址与 topic 只决定"往哪儿发"，手机上还得有
///   一个客户端订阅同一个 topic，否则一条提示都不会有；
/// * **App 在线时不发 ntfy**：去重是网关侧行为，界面必须说清，否则用户开着
///   App 测推送、什么都没收到，就会判定"功能没做"；
/// * **token 永不回显**：网关只回 `hasToken` 布尔，字段始终留空并提示
///   "留空则不改动"；
/// * 默认**关闭**：事件摘要会经第三方服务器中转，这是用户对自己的选择，不能
///   默默打开。
class PushSettingsView extends StatefulWidget {
  const PushSettingsView({super.key});

  /// 稳定的定位句柄：界面测试断言这一块而不依赖会变的文案。
  @visibleForTesting
  static const pushRequirementNoteKey = Key('push-requirement-note');
  @visibleForTesting
  static const pushUrlFieldKey = Key('push-url-field');
  @visibleForTesting
  static const pushTopicFieldKey = Key('push-topic-field');
  @visibleForTesting
  static const pushTokenFieldKey = Key('push-token-field');

  @override
  State<PushSettingsView> createState() => _PushSettingsViewState();
}

class _PushSettingsViewState extends State<PushSettingsView> {
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

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
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
    _toast(ok ? '推送配置已保存' : (dsh.lastError.isEmpty ? '保存失败' : dsh.lastError));
  }

  Future<void> _testPush(DshService dsh) async {
    setState(() => _pushBusy = true);
    final ok = await dsh.testPush();
    if (!mounted) return;
    setState(() => _pushBusy = false);
    _toast(ok ? '测试推送已发出，检查 ntfy App' : '推送发送失败：检查地址、topic 与是否已开启');
  }

  @override
  Widget build(BuildContext context) {
    final dsh = context.watch<DshService>();
    _syncPushForm(dsh);
    final cfg = dsh.pushConfig;

    return Scaffold(
      backgroundColor: context.c.surfaceMuted,
      appBar: settingsAppBar(context, '推送提醒'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: settingsCardDecoration(context),
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
                const SizedBox(height: AppSpace.s),
                Text(
                  '开启后，审批/提问/任务完成会经 ntfy 推到系统通知栏；'
                  '点开通知直接进入对应会话（App 没运行时也能收到）。'
                  '事件摘要会经该服务中转，请只在接受这一点时开启。',
                  style: TextStyle(fontSize: AppText.subhead, color: context.c.textSecondary, height: 1.35),
                ),
                const SizedBox(height: AppSpace.m),
                _buildPushRequirementNote(context),
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
                const SizedBox(height: AppSpace.l),
                TextField(
                  key: PushSettingsView.pushUrlFieldKey,
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
                  key: PushSettingsView.pushTopicFieldKey,
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
                  key: PushSettingsView.pushTokenFieldKey,
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
                const SizedBox(height: AppSpace.m),
                Text(
                  'Topic 建议用一段随机串：ntfy 上知道 topic 的人就能订阅到你的通知。',
                  style: TextStyle(fontSize: 11, color: context.c.textTertiary),
                ),
                const SizedBox(height: AppSpace.l),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _pushBusy ? null : () => _savePush(dsh),
                      icon: _pushBusy
                          ? const SizedBox(
                              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
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
          ),
        ],
      ),
    );
  }

  /// 「另一半在手机上」：网关只是**发布方**，没有订阅方就什么都不会响。
  Widget _buildPushRequirementNote(BuildContext context) {
    final lines = <String>[
      '① 在应用商店安装一个 ntfy 客户端（官方开源 App，Android/iOS 都有）。',
      '② 在客户端里订阅与下面完全相同的一个 topic（一个字都不能差）。',
      '③ 没装客户端，或 topic 对不上 → 手机不会有任何提示。',
      '④ 提醒只在 App 不在线（进程被杀/断网/锁屏）时经 ntfy 发送；'
          'App 活着时由它自己弹本地通知，不会重复推两条。',
    ];
    return Container(
      key: PushSettingsView.pushRequirementNoteKey,
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
}
