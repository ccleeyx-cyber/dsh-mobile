import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/server_config.dart';
import '../../services/cert_trust.dart';
import '../../services/dsh_service.dart';
import '../../services/storage_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import 'settings_widgets.dart';

/// 「远程访问」——v1.35 新增的二级页。
///
/// ## 它解决什么
///
/// 网关直到 v1.34 只有局域网明文 HTTP，人一出门就断联。v1.35 给了两条腿：
/// TLS 端口（自签证书 + TOFU）和 cloudflared quick tunnel（免账号的临时公网
/// 通道）。这一页是它们的**唯一操作面**：
///
///  * 隧道开关与当前公网地址（地址每次重启都变，文案必须说清）；
///  * 远程通道配置（一条 `https://…` 地址，保存成独立 profile）；
///  * 证书指纹展示 + 变更确认（TOFU 的"人"这一环）。
///
/// ## 产品取舍
///
/// - **远程地址必须是 https**：明文远程等于把 token 发到公网，这里直接拒绝，
///   而不是"先连上再提示风险"。
/// - **保存成新 profile 而不是改掉当前配置**：同一台电脑的局域网与远程是两条
///   连接路径，改掉局域网地址会让用户回家后连不上。`<id>-remote` 的后缀让两条
///   记录并存，切回局域网只需要把 active 切回原 id。
/// - 隧道地址变化时**不自动改写配置**：新地址要用户确认（复制/保存），因为这
///   时候旧地址可能已经不可用，静默替换会让"连不上"变成"不知道为什么连不上"。
class RemoteAccessView extends StatefulWidget {
  const RemoteAccessView({super.key});

  @override
  State<RemoteAccessView> createState() => _RemoteAccessViewState();
}

class _RemoteAccessViewState extends State<RemoteAccessView> {
  final _urlController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String _fingerprint = '';
  bool _saving = false;
  bool _tunnelBusy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  DshService get _dsh => Provider.of<DshService>(context, listen: false);

  static String _gatewayIdOf(ServerConfig cfg) {
    final id = cfg.id.trim();
    return id.isNotEmpty ? id : '${cfg.cleanHost}:${cfg.cleanPort}';
  }

  Future<void> _load() async {
    final cfg = _dsh.currentConfig;
    if (cfg == null) return;
    try {
      final stored = await CertTrust.stored(
        gatewayId: _gatewayIdOf(cfg),
        channel: 'lan',
      );
      final normalized = stored == null ? '' : CertTrust.normalizeFingerprint(stored);
      if (!mounted) return;
      setState(() => _fingerprint = normalized);
    } catch (_) {
      // 指纹读不到不是错误：页面上还有别的信息可看。
    }
    // 隧道状态：连不上网关就停在"未知"，不弹错误（这一页本身可能就是在断网时打开的）。
    await _dsh.refreshTunnel();
    if (mounted) setState(() {});
  }

  String _currentChannel(ServerConfig cfg) => cfg.channel == 'remote' ? '远程' : '局域网';

  Future<void> _saveRemote() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final cfg = _dsh.currentConfig;
    if (cfg == null) return;

    final uri = Uri.tryParse(_urlController.text.trim());
    if (uri == null || uri.host.isEmpty) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final baseId = cfg.id.trim().isEmpty ? '${cfg.cleanHost}:${cfg.cleanPort}' : cfg.id.trim();
      final remote = ServerConfig(
        // 独立 id：与局域网那一条并存，而不是覆盖它。
        id: '$baseId-remote',
        name: '${cfg.displayName}·远程',
        host: uri.host,
        port: uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80),
        token: cfg.token,
        useHttps: true,
        authCode: cfg.authCode,
        deviceId: cfg.deviceId,
        npsAddress: cfg.npsAddress,
        channel: 'remote',
      );
      await StorageService.saveConfig(remote);
      if (!mounted) return;
      final active = await StorageService.setActiveProfile(remote.id);
      if (!mounted) return;
      if (active == null) {
        setState(() => _error = '保存成功但没能切换，请回「连接与诊断」重试');
        return;
      }
      await _dsh.connect(active);
    } catch (e) {
      if (mounted) setState(() => _error = '保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _switchBackToLan() async {
    final cfg = _dsh.currentConfig;
    if (cfg == null) return;
    final baseId = cfg.id.endsWith('-remote')
        ? cfg.id.substring(0, cfg.id.length - '-remote'.length)
        : cfg.id;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final lan = await StorageService.setActiveProfile(baseId);
      if (lan == null) {
        if (mounted) setState(() => _error = '找不到局域网配置，请到「连接与诊断」切换');
        return;
      }
      await _dsh.connect(lan);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleTunnel({required bool start}) async {
    setState(() {
      _tunnelBusy = true;
      _error = null;
    });
    try {
      final result = start ? await _dsh.startTunnel() : await _dsh.stopTunnel();
      if (mounted && result != null && result['ok'] == false) {
        setState(() => _error = (result['error'] ?? '隧道操作失败').toString());
      }
    } finally {
      if (mounted) setState(() => _tunnelBusy = false);
    }
  }

  Future<void> _trustPending() async {
    await _dsh.trustPendingCertChange();
    if (!mounted) return;
  }

  @override
  Widget build(BuildContext context) {
    final dsh = context.watch<DshService>();
    final cfg = dsh.currentConfig;
    final pending = dsh.pendingCertChange;
    final tunnel = dsh.tunnelState ?? const <String, dynamic>{};
    final tunnelStatus = (tunnel['status'] ?? 'idle').toString();
    final tunnelUrl = (tunnel['url'] ?? '').toString();
    final tunnelTarget = tunnel['target']?.toString();

    return Scaffold(
      backgroundColor: context.c.surfaceMuted,
      appBar: AppBar(
        backgroundColor: context.c.surface,
        foregroundColor: context.c.textPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text('远程访问'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        children: [
          // ---- 0. 证书变更告警（最高优先级：连接被拦时它是唯一解释） ----
          if (pending != null) _buildCertChangeCard(context, pending),

          // ---- 1. 当前状态 ----
          SettingsSectionHeader(
            title: '当前通道',
            icon: Icons.lan_outlined,
            color: context.c.accent,
          ),
          const SizedBox(height: AppSpace.m),
          _card(context, Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row(context, '通道', cfg == null ? '未连接' : _currentChannel(cfg)),
                const SizedBox(height: 8),
                _row(context, '地址', cfg?.httpBaseUrl ?? '未配置'),
                const SizedBox(height: 8),
                _row(
                  context,
                  '网关证书指纹',
                  _fingerprint.isEmpty ? '尚未记住（首次连接时写入）' : _fingerprint,
                  mono: true,
                ),
                if (cfg != null && cfg.channel == 'remote') ...[
                  const SizedBox(height: AppSpace.m),
                  OutlinedButton.icon(
                    key: const ValueKey('remote-switch-lan'),
                    onPressed: _saving ? null : _switchBackToLan,
                    icon: const Icon(Icons.wifi_rounded, size: 18),
                    label: const Text('切回局域网'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpace.xl),

          // ---- 2. 云隧道 ----
          SettingsSectionHeader(
            title: '临时公网通道（cloudflared）',
            icon: Icons.cloud_outlined,
            color: context.c.accent,
          ),
          const SizedBox(height: AppSpace.m),
          _card(context, Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '免账号、一条命令即可从外网连回这台电脑。'
                  '地址每次重启都会变，属于临时通道；长期使用建议改用 Tailscale 或自有反向代理。',
                  style: TextStyle(fontSize: 13, height: 1.5, color: context.c.textSecondary),
                ),
                const SizedBox(height: AppSpace.m),
                _row(context, '状态', _tunnelStatusLabel(tunnelStatus)),
                const SizedBox(height: 8),
                _row(context, '公网地址', tunnelUrl.isEmpty ? '未开通' : tunnelUrl, mono: true),
                if (tunnelTarget != null) ...[
                  const SizedBox(height: 8),
                  _row(context, '指向', tunnelTarget),
                ],
                if ((tunnel['error'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: AppSpace.s),
                  Text(
                    (tunnel['error']).toString(),
                    style: TextStyle(fontSize: 12.5, color: context.c.danger, height: 1.45),
                  ),
                ],
                const SizedBox(height: AppSpace.m),
                Row(
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('remote-tunnel-start'),
                      onPressed: _tunnelBusy || tunnelStatus == 'ready' || tunnelStatus == 'starting'
                          ? null
                          : () => _toggleTunnel(start: true),
                      icon: _tunnelBusy
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.play_arrow_rounded, size: 18),
                      label: Text(tunnelStatus == 'ready' ? '已开通' : '开通隧道'),
                    ),
                    const SizedBox(width: AppSpace.m),
                    OutlinedButton(
                      key: const ValueKey('remote-tunnel-stop'),
                      onPressed: _tunnelBusy || tunnelStatus == 'idle' || tunnelStatus == 'stopped'
                          ? null
                          : () => _toggleTunnel(start: false),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.xl),

          // ---- 3. 远程地址 ----
          SettingsSectionHeader(
            title: '远程地址',
            icon: Icons.link_rounded,
            color: context.c.accent,
          ),
          const SizedBox(height: AppSpace.m),
          _card(context, Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '填写可以从外网访问到网关的 HTTPS 地址（隧道域名、反代域名或 Tailscale 名称）。'
                    '保存后会新增一条「远程」配置并立即切换，局域网那条仍然保留。',
                    style: TextStyle(fontSize: 13, height: 1.5, color: context.c.textSecondary),
                  ),
                  const SizedBox(height: AppSpace.m),
                  TextFormField(
                    key: const ValueKey('remote-url-field'),
                    controller: _urlController,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '远程地址',
                      hintText: 'https://xxxx.trycloudflare.com',
                    ),
                    validator: (value) {
                      final raw = (value ?? '').trim();
                      if (raw.isEmpty) return '请填写远程地址';
                      final uri = Uri.tryParse(raw);
                      if (uri == null || uri.host.isEmpty) return '地址格式不正确';
                      // 明文远程会被直接拒绝：这不是"建议"，是硬门槛。
                      if (uri.scheme != 'https') {
                        return '远程通道必须使用 https（明文会让令牌暴露在公网）';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: AppSpace.m),
                  FilledButton(
                    key: const ValueKey('remote-save-button'),
                    onPressed: _saving ? null : _saveRemote,
                    child: _saving
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('保存并切换到远程通道'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: AppSpace.m),
                    Text(
                      _error!,
                      style: TextStyle(fontSize: 12.5, color: context.c.danger, height: 1.45),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _tunnelStatusLabel(String status) => switch (status) {
        'idle' => '未启动',
        'starting' => '正在建立…',
        'ready' => '已开通',
        'stopped' => '已关闭',
        'failed' => '启动失败',
        _ => status,
      };

  /// 设置页统一卡片形态（与 push/snippets 二级页同一套装饰）。
  Widget _card(BuildContext context, Widget child) => Container(
        padding: const EdgeInsets.all(AppSpace.m),
        decoration: settingsCardDecoration(context),
        child: child,
      );

  Widget _row(BuildContext context, String label, String value, {bool mono = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(label, style: TextStyle(fontSize: 12.5, color: context.c.textSecondary)),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: context.c.textPrimary,
              fontFamily: mono ? 'monospace' : null,
              fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCertChangeCard(BuildContext context, CertTrustResult pending) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.xl),
      padding: const EdgeInsets.all(AppSpace.m),
      decoration: BoxDecoration(
        color: context.c.danger.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.c.danger.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gpp_maybe_rounded, color: context.c.danger, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '网关证书指纹已变化，连接被阻止',
                  style: TextStyle(fontWeight: FontWeight.w600, color: context.c.danger),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.s),
          Text(
            '如果这是你刚换了 Wi-Fi/热点，或重装了网关，网关会按新地址重签证书，属于正常。'
            '如果不是你操作的，请停止连接并检查网络。',
            style: TextStyle(fontSize: 12.5, height: 1.45, color: context.c.textSecondary),
          ),
          const SizedBox(height: AppSpace.s),
          _row(context, '原指纹', pending.previousFingerprint ?? '（无）', mono: true),
          const SizedBox(height: 6),
          _row(context, '新指纹', pending.fingerprint, mono: true),
          const SizedBox(height: AppSpace.m),
          Row(
            children: [
              FilledButton(
                key: const ValueKey('cert-change-trust'),
                style: FilledButton.styleFrom(backgroundColor: context.c.danger),
                onPressed: _trustPending,
                child: const Text('我认识这次变更'),
              ),
              const SizedBox(width: AppSpace.m),
              OutlinedButton(
                key: const ValueKey('cert-change-reject'),
                onPressed: () {
                  _dsh.rejectPendingCertChange();
                },
                child: const Text('不信任，断开'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
