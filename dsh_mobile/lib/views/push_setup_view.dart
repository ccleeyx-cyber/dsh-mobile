/// 离线推送（ntfy）配置页：一键生成随机 topic 并开启，手动配置作为兜底。
///
/// ## 为什么 topic 必须是随机的
///
/// ntfy 的 topic 在公共服务器上**按名字公开**：知道 topic 名字的任何人都能订阅到
/// 这条流。一个像 `dsh-mobile` 这样"好记"的默认值，等于把每一次审批提示都广播给
/// 猜到这个名字的人 —— 而审批提示里就有命令内容和文件路径。所以网关生成的是不可
/// 猜的 `dsh-<16 位十六进制>`，这一屏存在的意义就是让用户**永远不用自己起名字**，
/// 也不用在手机上手工敲那串随机串。
///
/// ## 这一屏只负责"配置好"，不负责"收到"
///
/// 手机上还得有一个 ntfy 客户端订阅**同一个** topic。缺了后半句，配置看着完全正常、
/// 测试推送也能成功，用户却永远收不到 —— 那句话必须写在按钮旁边，不能折叠在别处。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/bridge_extras.dart';
import '../models/task_center.dart';
import '../services/dsh_service.dart';
import '../services/platform_services.dart';
import '../theme/app_colors.dart';

class PushSetupView extends StatefulWidget {
  const PushSetupView({super.key});

  @override
  State<PushSetupView> createState() => _PushSetupViewState();
}

class _PushSetupViewState extends State<PushSetupView> {
  bool _loading = true;
  bool _autoBusy = false;
  bool _saveBusy = false;
  bool _testBusy = false;

  /// 一键生成的结果。null = 还没生成过（或生成失败，此时走手动配置）。
  ///
  /// 保留网关**返回的**链接而不是自己拼：链接怎么拼是网关的事。只有在"重新进这
  /// 一页、还没再点生成"时，才用已保存的 url + topic 现场推一遍（见 [_links]）。
  PushTopicResult? _result;

  final TextEditingController _urlCtrl = TextEditingController();
  final TextEditingController _topicCtrl = TextEditingController();
  final TextEditingController _tokenCtrl = TextEditingController();

  bool _enabled = false;

  /// 手动表单被改动过：之后不再用网关回显覆盖它（与设置页同一套理由 ——
  /// 一次后台刷新不该把用户正在输入的地址抹掉）。
  bool _dirty = false;

  /// 表单区域的错误/提示（网关原文优先）。
  String? _formError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _load();
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _topicCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final dsh = Provider.of<DshService>(context, listen: false);
    setState(() => _loading = true);
    // fetchPushConfig 是 void：它把结果写进 dsh.pushConfig 并 notifyListeners，
    // 所以取的是等待之后的 getter，而不是返回值。
    await dsh.fetchPushConfig();
    if (!mounted) return;
    _syncForm(dsh);
    setState(() => _loading = false);
  }

  /// 把网关回显灌进表单（用户改过就跳过）。
  ///
  /// token **永远不回填**：网关只回 `hasToken` 布尔，明文从不下来。所以 token
  /// 框留空 + 提示"留空表示不改动"。
  void _syncForm(DshService dsh) {
    final cfg = dsh.pushConfig;
    if (cfg == null || _dirty) return;
    _urlCtrl.text = cfg.url;
    _topicCtrl.text = cfg.topic;
    _enabled = cfg.enabled;
  }

  void _toast(String msg, {Color? tone}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: tone ?? context.c.success,
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: tone == null ? 2 : 4),
    ));
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _toast('已复制$what');
  }

  /// 打开外部链接。
  ///
  /// 走仓库自带的原生 [UrlOpener]（MethodChannel `dsh_mobile/url`），**不是**
  /// `url_launcher` —— 那个包不在 pubspec 里，而只为一个"跳出去"动线引入一个带
  /// transitive 依赖的插件不划算。失败（没有可处理该 scheme 的应用）时退回复制，
  /// 绝不静默失败。
  Future<void> _openUrl(String url, String what) async {
    final ok = await UrlOpener.open(url);
    if (!mounted) return;
    if (ok) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    _toast('打不开，$what已复制到剪贴板', tone: context.c.warning);
  }

  Future<void> _autoConfigure() async {
    final dsh = Provider.of<DshService>(context, listen: false);
    final typedUrl = _urlCtrl.text.trim();
    setState(() {
      _autoBusy = true;
      _formError = null;
    });

    // 顺手把用户已经填了的服务器地址带过去：换自建 ntfy 的人不该被"一键"覆盖回
    // 公共服务器。没填就让网关用它自己的默认值。
    final r = await dsh.autoConfigurePushTopic(url: typedUrl.isEmpty ? null : typedUrl);
    if (!mounted) return;

    setState(() {
      _autoBusy = false;
      if (r == null) {
        _formError = '一键生成失败：网关没有回应（未连接 / 令牌失效 / 网关版本过旧）。'
            '下面的手动配置仍然可用。';
      } else {
        _result = r;
        _dirty = false;
        _urlCtrl.text = r.url;
        _topicCtrl.text = r.topic;
        _enabled = r.enabled;
      }
    });
    if (r == null) {
      // 生成失败 → 页面内常驻错误（不弹 toast）：用户下一步就是"改用手动配置"，
      // 这句话必须一直可读，而不是 4 秒后消失。
      setState(() => _formError = '生成失败：网关没有返回 topic / 订阅链接，请改用手动配置。');
      return;
    }
    _toast('已生成随机 topic 并开启推送');
  }

  Future<void> _saveManual() async {
    final dsh = Provider.of<DshService>(context, listen: false);
    final topic = _topicCtrl.text.trim();
    if (_enabled && topic.isEmpty) {
      setState(() => _formError = '开启推送必须填一个 topic。建议先用上面的「一键生成并开启」拿到随机串。');
      return;
    }

    setState(() {
      _saveBusy = true;
      _formError = null;
    });
    final ok = await dsh.savePushConfig(
      enabled: _enabled,
      url: _urlCtrl.text.trim(),
      topic: topic,
      // 留空 = 不改动已保存的令牌。App 侧拿不到明文，无法"回填再保存"，
      // 传 null 才不会把一个不存在的空令牌写进去。
      token: _tokenCtrl.text.trim().isEmpty ? null : _tokenCtrl.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _saveBusy = false;
      if (ok) {
        _dirty = false;
        _tokenCtrl.clear();
      } else {
        _formError = dsh.lastError.isEmpty ? '保存失败：网关没有接受这份配置。' : dsh.lastError;
      }
    });
    if (ok) _toast('推送配置已保存');
  }

  Future<void> _testPush() async {
    final dsh = Provider.of<DshService>(context, listen: false);
    setState(() {
      _testBusy = true;
      _formError = null;
    });
    final ok = await dsh.testPush();
    if (!mounted) return;
    setState(() {
      _testBusy = false;
      // [feat 2026-10-17] Phase 4.5：推送测试失败改为**页面内常驻**错误。
      //
      // 测试推送是这一页唯一能证明"配好了"的动作，失败提示飘 4 秒就走的话，
      // 用户多半正在低头看手机通知栏 —— 等他抬头，屏幕上什么都没变，
      // 于是他以为"可能成功了吧"。失败必须留在他看得见的地方。
      if (!ok) {
        _formError = dsh.lastError.isEmpty
            ? '推送发送失败：检查地址、topic，以及是否已开启'
            : dsh.lastError;
      }
    });
    if (ok) _toast('测试推送已发出，检查手机上的 ntfy 客户端');
  }

  /// 订阅链接的两种形态：`ntfy://host/topic`（深链，直接开 App）与
  /// `https://host/topic`（浏览器）。
  ///
  /// 优先用一键生成时网关**直接给的**链接；只有在重新进页面、还没重新生成时才
  /// 用已保存的 url + topic 现场推一遍 —— ntfy 的官方深链形态就是
  /// `ntfy://<host>/<topic>`。
  ({String subscribe, String web}) _links(PushConfig? cfg) {
    final r = _result;
    if (r != null && r.subscribeUrl.isNotEmpty) {
      return (subscribe: r.subscribeUrl, web: r.webUrl);
    }
    final base = (cfg?.url ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    final topic = (cfg?.topic ?? '').trim();
    if (base.isEmpty || topic.isEmpty) return (subscribe: '', web: '');
    final web = '$base/$topic';
    return (subscribe: web.replaceFirst(RegExp(r'^https?://'), 'ntfy://'), web: web);
  }

  @override
  Widget build(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final cfg = dsh.pushConfig;
    final links = _links(cfg);

    return Scaffold(
      backgroundColor: context.c.surfaceMuted,
      appBar: AppBar(
        backgroundColor: context.c.surface,
        foregroundColor: context.c.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: context.c.border, height: 1),
        ),
        title: Text(
          '离线推送（ntfy）',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.c.textPrimary),
        ),
        actions: [
          IconButton(
            tooltip: '重新读取',
            onPressed: _loading ? null : _load,
            icon: Icon(Icons.refresh_rounded, color: context.c.textSecondary),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              children: [
                _buildStatusCard(context, cfg),
                const SizedBox(height: 16),
                _buildOneTapCard(context),
                const SizedBox(height: 16),
                if (links.subscribe.isNotEmpty) ...[
                  _buildSubscribeCard(context, cfg, links),
                  const SizedBox(height: 16),
                ],
                _buildManualCard(context, cfg),
                const SizedBox(height: 30),
              ],
            ),
    );
  }

  /// 当前状态。只显示 `hasToken` 布尔，**绝不渲染 token 值**（这是本仓库的硬规则，
  /// 网关也从不把明文发下来）。
  Widget _buildStatusCard(BuildContext context, PushConfig? cfg) {
    final configured = cfg?.configured == true;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                configured ? Icons.notifications_active_rounded : Icons.notifications_off_outlined,
                size: 17,
                color: configured ? context.c.success : context.c.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  cfg == null
                      ? '网关未上报推送配置（旧版网关？）'
                      : (configured ? '推送已开启' : '推送未开启'),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                    color: configured ? context.c.success : context.c.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '提醒只在 App 不在线（进程被杀 / 断网 / 锁屏）时经 ntfy 发送；'
            'App 活着时由它自己弹本地通知 —— 不会重复推两条。'
            '事件摘要会经该服务中转，请只在接受这一点时开启。',
            style: TextStyle(fontSize: 11.5, height: 1.45, color: context.c.textSecondary),
          ),
          const SizedBox(height: 10),
          _kv(context, 'ntfy 服务器', (cfg?.url ?? '').trim().isEmpty ? '—' : cfg!.url),
          const SizedBox(height: 6),
          _kv(context, 'Topic', (cfg?.topic ?? '').trim().isEmpty ? '—' : cfg!.topic),
          const SizedBox(height: 6),
          _kv(context, '访问令牌', cfg?.hasToken == true ? '已设置（不回显）' : '未设置'),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.c.accent,
                  side: BorderSide(color: context.c.border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _testBusy ? null : _testPush,
                icon: _testBusy
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send_rounded, size: 16),
                label: const Text('发送测试推送', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(k, style: TextStyle(fontSize: 12, color: context.c.textSecondary)),
        ),
        Expanded(
          child: Text(v, style: TextStyle(fontSize: 12, color: context.c.textPrimary, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  /// 主按钮：一键生成并开启。
  Widget _buildOneTapCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.c.accentSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 17, color: context.c.accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '一键生成并开启',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            '由网关注册一个不可猜的随机 topic（dsh-<16 位随机十六进制>）并立刻打开推送。'
            '你不需要自己想名字 —— ntfy 的 topic 在公共服务器上按名字公开，'
            '知道名字的人就能读到你的通知，所以「好记的名字」在这里恰恰是最坏的选择。',
            style: TextStyle(fontSize: 11.5, height: 1.45, color: context.c.textSecondary),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: context.c.accent,
              foregroundColor: context.c.onAccent,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
            ),
            onPressed: _autoBusy ? null : _autoConfigure,
            icon: _autoBusy
                ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.vpn_key_rounded, size: 17),
            label: Text(
              _autoBusy ? '正在生成…' : '一键生成并开启',
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold),
            ),
          ),
          if (_formError != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: context.c.dangerSurface,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: context.c.dangerBorder),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded, size: 16, color: context.c.danger),
                  const SizedBox(width: 7),
                  // 网关原文（或"没回应"这一事实）原样贴出来，不换成通用文案。
                  Expanded(
                    child: Text(
                      _formError!,
                      style: TextStyle(fontSize: 12, height: 1.45, color: context.c.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 订阅区：把"手机上还要做什么"摆在订阅链接旁边。
  Widget _buildSubscribeCard(BuildContext context, PushConfig? cfg, ({String subscribe, String web}) links) {
    final topic = (cfg?.topic ?? '').trim();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.c.success),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_rounded, size: 17, color: context.c.success),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  'Topic 已就绪',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                ),
              ),
            ],
          ),
          if (topic.isNotEmpty) ...[
            const SizedBox(height: 8),
            _kv(context, 'Topic', topic),
          ],
          const SizedBox(height: 12),
          // 还没在手机上订阅之前，"配好了"是没有意义的状态 —— 这段必须显眼。
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: context.c.warningSurface,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: context.c.warningBorder),
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
                        '还需要在手机上订阅同一个 topic',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  '① 在应用商店装一个 ntfy 客户端（官方开源 App，Android/iOS 都有）。\n'
                  '② 用下面两种方式之一订阅 —— 一个字都不能差。\n'
                  '③ 没装客户端，或 topic 对不上 → 手机不会有任何提示。',
                  style: TextStyle(fontSize: 11, height: 1.5, color: context.c.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '订阅链接（ntfy:// 深链，点开直接进 ntfy App）',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.c.textPrimary),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: context.c.surfaceMuted,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.c.border),
            ),
            child: SelectableText(
              links.subscribe,
              style: TextStyle(fontSize: 12, color: context.c.textPrimary),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: context.c.accent,
                  foregroundColor: context.c.onAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () => _openUrl(links.subscribe, '订阅链接'),
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('在 ntfy App 中订阅', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.c.accent,
                  side: BorderSide(color: context.c.border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () => _copy(links.subscribe, '订阅链接'),
                icon: const Icon(Icons.copy_rounded, size: 15),
                label: const Text('复制', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '网页订阅地址（备用）',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.c.textPrimary),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: context.c.surfaceMuted,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.c.border),
            ),
            child: SelectableText(
              links.web,
              style: TextStyle(fontSize: 12, color: context.c.textPrimary),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.c.textPrimary,
                  side: BorderSide(color: context.c.border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () => _openUrl(links.web, '网页地址'),
                icon: const Icon(Icons.public_rounded, size: 15),
                label: const Text('用浏览器打开', style: TextStyle(fontSize: 12.5)),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.c.accent,
                  side: BorderSide(color: context.c.border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () => _copy(links.web, '网页地址'),
                icon: const Icon(Icons.copy_rounded, size: 15),
                label: const Text('复制', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 二维码：本客户端**没有**生成二维码的能力 —— pubspec 里只有扫码用的
          // mobile_scanner（只解不生成），且不为这一个次要动线新增依赖。
          // 所以这里不画二维码，而是直说清楚，并把"要不要加"交回给用户。
          Text(
            '本页不显示二维码（客户端只装了扫描用的 mobile_scanner，没有生成二维码的依赖）。'
            '请用上面的深链一键订阅，或把链接粘进 ntfy 客户端。',
            style: TextStyle(fontSize: 11, height: 1.4, color: context.c.textTertiary),
          ),
        ],
      ),
    );
  }

  /// 手动配置 —— 一键生成失败、或用户要接自建 ntfy 时的兜底路径。
  Widget _buildManualCard(BuildContext context, PushConfig? cfg) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.build_outlined, size: 16, color: context.c.textSecondary),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '手动配置',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                ),
              ),
              Switch(
                value: _enabled,
                activeColor: context.c.accent,
                onChanged: _saveBusy
                    ? null
                    : (v) => setState(() {
                          _enabled = v;
                          _dirty = true;
                        }),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '一键生成走不通时（旧版网关 / 自建服务器）用这里。'
            '如果填自己的地址，先在上面的输入框写清服务器，再点「一键生成并开启」也行。',
            style: TextStyle(fontSize: 11.5, height: 1.4, color: context.c.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            onChanged: (_) {
              _dirty = true;
            },
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
            controller: _topicCtrl,
            onChanged: (_) {
              _dirty = true;
            },
            decoration: const InputDecoration(
              labelText: 'Topic（收件箱名）',
              hintText: '建议用上面的「一键生成」得到随机串',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _tokenCtrl,
            onChanged: (_) {
              _dirty = true;
            },
            obscureText: true,
            // 只提示"有没有"，绝不回显：明文从不经过 App。
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
                style: FilledButton.styleFrom(
                  backgroundColor: context.c.accent,
                  foregroundColor: context.c.onAccent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _saveBusy ? null : _saveManual,
                icon: _saveBusy
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_outlined, size: 16),
                label: const Text('保存', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.c.accent,
                  side: BorderSide(color: context.c.border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _testBusy ? null : _testPush,
                icon: const Icon(Icons.send_rounded, size: 15),
                label: const Text('发送测试推送', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
