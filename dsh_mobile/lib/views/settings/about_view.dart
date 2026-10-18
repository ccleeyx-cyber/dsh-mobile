import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/app_version.dart';
import '../../models/client_update.dart';
import '../../services/platform_services.dart';
import '../../services/update_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import 'settings_widgets.dart';

/// 「关于与更新」二级页。
///
/// 从设置首页搬出来的理由很直接：这一块包含一次网络请求、一次下载校验、四种
/// 结果对话框，属于"用户主动点才发生"的重流程。留在首页只会让每次打开设置都
/// 多滚一屏说明文字。
///
/// ## 三条出路，任何一条都不会让界面说假话
///
///  * 有新版   → 显示版本/大小/说明，可选「下载并安装」；
///  * 已是最新 → 明确说已是最新（**只有真读到清单且 versionCode 不比本机大**才敢说）；
///  * 问不到 / 清单不可信 → 回退到老行为：打开发布页，并如实说明原因。
class AboutView extends StatefulWidget {
  const AboutView({super.key});

  @override
  State<AboutView> createState() => _AboutViewState();
}

class _AboutViewState extends State<AboutView> {
  /// 检查/下载更新进行中（只有用户主动点才会置位 —— 启动时不查更新）。
  bool _updateBusy = false;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.c.surfaceMuted,
      appBar: settingsAppBar(context, '关于与更新'),
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
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [context.c.accent, const Color(0xFF2563EB)]),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.layers_rounded, color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: AppSpace.l),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('DSH Mobile Pro',
                            style: TextStyle(
                                color: context.c.textPrimary, fontWeight: FontWeight.bold, fontSize: 14)),
                        const SizedBox(height: AppSpace.xs),
                        // 真源是 pubspec.yaml，构建期经 --dart-define 注入
                        // （见 lib/models/app_version.dart 顶部链路说明）。
                        Text(
                          '版本: v${AppVersion.version} (Build ${AppVersion.buildNumber})',
                          style: TextStyle(color: context.c.textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.l),
                // 更新动线两条，前者是加速源、后者是保底：
                //  1) 「检查更新」读发布页**同级**的可选清单
                //     (releases/latest/download/latest.json)，拿到 versionCode /
                //     size / sha256 才能做真正的校验，并在 App 内下载+校验后交给
                //     系统安装器；
                //  2) 清单取不到（发布方没放/离线/坏 JSON）→ 回退到「打开发布页」。
                //
                // 刻意**不**查网关的 /api/mobile/version、不用 DSH_LATEST_APP_VERSION ——
                // 那套东西要求网关侧额外配置环境变量并手工把 APK 放到盘上，任何一个
                // 漏了都会让界面言之凿凿地说"已是最新"，比不做更糟。也刻意**不**在
                // 启动时自动检查：只在用户点下去的那一刻才发请求。
                Text(
                  '客户端是自签名侧载安装的，系统不会自动更新。点「检查更新」可以在 App 内下载并校验'
                  '（字节数 / sha256）；校验不过会拒绝安装，最终签名一致性由系统安装器裁决。',
                  style: TextStyle(fontSize: 11, color: context.c.textTertiary, height: 1.35),
                ),
                const SizedBox(height: AppSpace.m),
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
                const SizedBox(height: AppSpace.m),
                Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        icon: Icon(Icons.open_in_new_rounded, size: 16, color: context.c.accent),
                        label: Text('打开发布页',
                            style: TextStyle(
                                color: context.c.accent, fontSize: 12, fontWeight: FontWeight.w600)),
                        onPressed: () => _openDownloadPage(context),
                      ),
                    ),
                    Expanded(
                      child: TextButton.icon(
                        icon: Icon(Icons.link_rounded, size: 16, color: context.c.accent),
                        label: Text('复制发布页链接',
                            style: TextStyle(
                                color: context.c.accent, fontSize: 12, fontWeight: FontWeight.w600)),
                        onPressed: () {
                          Clipboard.setData(const ClipboardData(text: AppVersion.releasesUrl));
                          _toast('已复制: ${AppVersion.releasesUrl}');
                        },
                      ),
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

  /// 用户主动点「检查更新」才会走到这里（启动时不查，保持静默）。
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

  /// 更新相关的统一提示框。[primary] 非空时给一个主按钮，点它才执行。
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
  /// 这里不做版本比对：唯一真值来源是发布页本身，而"告诉用户有没有新版"需要
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
}
