import 'package:flutter/material.dart';

import '../../models/server_config.dart';
import '../../services/dsh_service.dart';
import '../../services/storage_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../config_page.dart';
import 'settings_widgets.dart';

/// 设置首屏的服务器切换卡。
///
/// 多网关用户最常见的动作不是"调设置"，而是"从公司切回家里"。以前必须
/// 设置 → 连接与诊断 → 连接页 → 下拉 → 切换并连接，五步；这里把当前服务器
/// 和切换动作直接放到设置页第一层，点一下服务器就切。
///
/// 只做切换和入口，不在卡里铺表单：新增/重命名/删除仍然归 [ConfigPage]。
class GatewaySwitcherCard extends StatefulWidget {
  final DshService dsh;

  const GatewaySwitcherCard({super.key, required this.dsh});

  @override
  State<GatewaySwitcherCard> createState() => _GatewaySwitcherCardState();
}

class _GatewaySwitcherCardState extends State<GatewaySwitcherCard> {
  List<ServerConfig> _profiles = const [];
  String? _activeId;
  bool _loading = true;
  bool _switching = false;
  ServerConfig? _switchingTo;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    var profiles = <ServerConfig>[];
    String? activeId;
    try {
      profiles = await StorageService.loadProfiles();
      activeId = await StorageService.activeProfileId();
    } catch (_) {
      // 设置页不能因为读本地配置失败就整页崩掉；空列表本身就是可恢复状态。
      profiles = const [];
    }
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _activeId = activeId;
      _loading = false;
    });
  }

  /// 列表为空但已经连着一台（例如旧配置）时，至少把当前这台显示出来。
  List<ServerConfig> get _options {
    if (_profiles.isNotEmpty) return _profiles;
    final current = widget.dsh.currentConfig;
    return current == null ? const [] : [current];
  }

  ServerConfig? get _current {
    final cfg = widget.dsh.currentConfig;
    if (cfg != null) return cfg;
    for (final p in _profiles) {
      if (p.id == _activeId) return p;
    }
    return _options.isEmpty ? null : _options.first;
  }

  bool _isCurrent(ServerConfig profile) {
    final current = widget.dsh.currentConfig;
    if (current == null) return profile.id == _activeId;
    if (current.id.isNotEmpty && profile.id.isNotEmpty) {
      return current.id == profile.id;
    }
    return current.cleanHost == profile.cleanHost &&
        current.cleanPort == profile.cleanPort;
  }

  String _statusLine(ServerConfig? current) {
    if (_switching && _switchingTo != null) {
      return '正在连接 ${_switchingTo!.cleanHost}:${_switchingTo!.cleanPort}…';
    }
    if (current == null) {
      return _loading ? '正在读取已保存的服务器' : '添加 DSH 宿主机后即可开始';
    }
    final addr = '${current.cleanHost}:${current.cleanPort}';
    if (widget.dsh.isTokenInvalid) return '$addr · 令牌失效';
    if (!widget.dsh.isConnected) {
      final error = widget.dsh.lastError.trim();
      return error.isEmpty ? '$addr · 未连接' : '$addr · $error';
    }
    final ping = widget.dsh.pingMs >= 0 ? ' · ${widget.dsh.pingMs} ms' : '';
    return '$addr · 已连接$ping';
  }

  Color _statusColor(BuildContext context) {
    if (widget.dsh.isTokenInvalid) return context.c.danger;
    if (widget.dsh.isConnected) return context.c.success;
    return context.c.warning;
  }

  Future<void> _openSwitcher() async {
    if (_switching) return;
    final options = _options;
    if (options.isEmpty) {
      await _openManager();
      return;
    }

    final picked = await showModalBottomSheet<ServerConfig>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => _GatewaySheet(
        options: options,
        isCurrent: _isCurrent,
        onManage: () {
          Navigator.of(sheetContext).pop();
          // 等 sheet 的关闭动画先开始，再推页面；同一帧 pop+push 会让新页面
          // 被退场路由盖住一瞬。
          Future<void>.delayed(Duration.zero, _openManager);
        },
      ),
    );
    if (!mounted || picked == null || _isCurrent(picked)) return;
    await _switchTo(picked);
  }

  Future<void> _openManager() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ConfigPage()),
    );
    if (!mounted) return;
    await _loadProfiles();
  }

  Future<void> _switchTo(ServerConfig profile) async {
    if (_switching) return;
    setState(() {
      _switching = true;
      _switchingTo = profile;
    });

    ServerConfig? cfg;
    String? failure;
    try {
      cfg = await StorageService.setActiveProfile(profile.id);
      if (cfg == null) {
        failure = '该服务器已不存在';
      } else {
        widget.dsh.clearAuthError();
        await widget.dsh.connect(cfg);
      }
    } catch (e) {
      failure = e.toString();
    }

    if (!mounted) return;
    setState(() {
      _switching = false;
      _switchingTo = null;
    });

    final name = cfg?.displayName ?? profile.displayName;
    final error =
        failure ?? (widget.dsh.isConnected ? '' : widget.dsh.lastError.trim());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text(error.isEmpty ? '已切换到「$name」' : '已切换到「$name」，连接未成功：$error'),
        duration: const Duration(milliseconds: 1800),
        behavior: SnackBarBehavior.floating,
      ),
    );
    await _loadProfiles();
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final shown = _switchingTo ?? current;
    final title = shown?.displayName ?? (_loading ? '读取服务器…' : '尚未添加服务器');
    final hasOptions = _options.isNotEmpty;

    return InkWell(
      key: const ValueKey('settings-gateway-switcher'),
      borderRadius: BorderRadius.circular(12),
      onTap: _switching ? null : _openSwitcher,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
        decoration: settingsCardDecoration(context),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: context.c.accent.withOpacity(0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.dns_outlined,
                size: 21,
                color: context.c.accent,
              ),
            ),
            const SizedBox(width: AppSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '当前服务器',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: context.c.textTertiary,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      color: context.c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _statusColor(context),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          _statusLine(current),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppText.caption,
                            color: widget.dsh.isConnected
                                ? context.c.textSecondary
                                : _statusColor(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.s),
            if (_switching)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              TextButton.icon(
                key: const ValueKey('settings-gateway-switch-button'),
                onPressed: _openSwitcher,
                icon: Icon(
                  hasOptions ? Icons.swap_horiz_rounded : Icons.add_rounded,
                  size: 17,
                ),
                label: Text(
                  hasOptions ? '切换' : '添加',
                  style: const TextStyle(fontSize: 12.5),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  minimumSize: const Size(0, 32),
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 服务器选择面板。只负责选择，切换动作留给卡片（这样进度与错误提示都在
/// 卡片所在页面，不会跟着 sheet 一起消失）。
class _GatewaySheet extends StatelessWidget {
  final List<ServerConfig> options;
  final bool Function(ServerConfig) isCurrent;
  final VoidCallback onManage;

  const _GatewaySheet({
    required this.options,
    required this.isCurrent,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.72;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 34,
            height: 4,
            decoration: BoxDecoration(
              color: context.c.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 10, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '切换服务器',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: context.c.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '选择后立即连接，不需要再进连接页',
                        style: TextStyle(
                          fontSize: AppText.caption,
                          color: context.c.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, size: 20),
                  tooltip: '关闭',
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: options.length,
              itemBuilder: (context, i) {
                final p = options[i];
                final selected = isCurrent(p);
                return InkWell(
                  key: ValueKey('settings-gateway-option-${p.id}'),
                  onTap: () => Navigator.of(context).pop(p),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 11,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.dns_outlined,
                          size: 21,
                          color: selected
                              ? context.c.success
                              : context.c.textSecondary,
                        ),
                        const SizedBox(width: AppSpace.m),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                p.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: context.c.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${p.cleanHost}:${p.cleanPort}'
                                '${p.channel == 'remote' ? ' · 远程' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppText.caption,
                                  color: context.c.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpace.s),
                        if (selected)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: context.c.success.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '当前',
                              style: TextStyle(
                                fontSize: AppText.caption,
                                fontWeight: FontWeight.w600,
                                color: context.c.success,
                              ),
                            ),
                          )
                        else
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: context.c.textTertiary,
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Divider(height: 1, color: context.c.border),
          ListTile(
            key: const ValueKey('settings-manage-gateways'),
            onTap: onManage,
            leading: Icon(
              Icons.settings_outlined,
              size: 20,
              color: context.c.textSecondary,
            ),
            title: Text(
              '管理服务器',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: context.c.textPrimary,
              ),
            ),
            subtitle: Text(
              '添加、重命名或删除',
              style: TextStyle(
                fontSize: AppText.caption,
                color: context.c.textTertiary,
              ),
            ),
            trailing: Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: context.c.textTertiary,
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
