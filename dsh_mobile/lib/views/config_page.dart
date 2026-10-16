import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/server_config.dart';
import '../services/dsh_service.dart';
import '../services/storage_service.dart';
import 'main_shell.dart';
import '../theme/app_colors.dart';

class ConfigPage extends StatefulWidget {
  const ConfigPage({super.key});

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  final _formKey = GlobalKey<FormState>();
  final _hostController = TextEditingController(text: '');
  final _portController = TextEditingController(text: '3088');
  // No pre-filled token: the gateway generates a random one on first install,
  // so a hard-coded default here would only mislead the user.
  final _tokenController = TextEditingController();
  final _npsController = TextEditingController(text: ''); // 兼容旧数据保留，UI 已移除
  bool _useHttps = false;
  bool _isTesting = false;

  /// 配对成功后网关分配的本机设备 id（dev_xxxxxxxx），保存进配置。
  /// [feat 2026-10-12] 电脑端撤销广播按它命中本机。
  String _pairedDeviceId = '';

  /// Saved gateways, for the switcher at the top of the page.
  List<ServerConfig> _profiles = [];

  /// Identity of the entry the form is currently showing. Null until the async
  /// load finishes, or when nothing has ever been saved.
  String? _activeProfileId;
  String _activeName = '';

  /// Gates the "尚无已保存的网关" empty state so it cannot flash while
  /// SharedPreferences is still being read.
  bool _profilesLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadInitialConfig();
  }

  @override
  void dispose() {
    // 本页持有 5 个 TextEditingController，此前完全没有 dispose() 覆写。
    // 每个 controller 都带 ChangeNotifier 监听者与一条原生文本输入连接，
    // 而 ConfigPage 可从 MainShell 反复进入，所以是每次进入泄漏 5 个。
    _hostController.dispose();
    _portController.dispose();
    _tokenController.dispose();
    _npsController.dispose();
    super.dispose();
  }

  void _loadInitialConfig() async {
    final cfg = await StorageService.loadConfig();
    // 这三次读取都走 SharedPreferences，是异步的。若用户在它们返回之前就退出本页，
    // State 已经 dispose，此时再 setState() 会抛 "setState() called after dispose()"。
    // 必须加 mounted 守卫 —— 同文件的 _testConnection()/_saveAndConnect() 都加了，
    // 唯独这个启动路径漏了。
    final profiles = await StorageService.loadProfiles();
    final storedActiveId = await StorageService.activeProfileId();
    if (!mounted) return;

    setState(() {
      _profiles = profiles;
      _profilesLoaded = true;

      // 存下来的 active id 可能指向一个已被删除的网关，而 DropdownButton 会断言
      // value 必须存在于 items 中，所以用之前必须先校验。
      final ids = profiles.map((p) => p.id).toSet();
      String? active = (storedActiveId != null && ids.contains(storedActiveId)) ? storedActiveId : null;
      active ??= (cfg != null && ids.contains(cfg.id)) ? cfg.id : null;
      active ??= profiles.isEmpty ? null : profiles.first.id;
      _activeProfileId = active;

      ServerConfig? match;
      for (final p in profiles) {
        if (p.id == active) {
          match = p;
          break;
        }
      }
      _activeName = match?.name ?? cfg?.name ?? '';

      // 用 active config 而不是列表项来填表单：前者才是 App 真正拿去连接的那份，
      // 且可能含有列表写入之后的修改。
      final fill = cfg ?? match;
      if (fill != null) _fillForm(fill);
    });
  }

  void _fillForm(ServerConfig cfg) {
    _hostController.text = cfg.host;
    _portController.text = cfg.port.toString();
    _tokenController.text = cfg.token;
    _useHttps = cfg.useHttps;
    _npsController.text = cfg.npsAddress; // 旧数据兼容：保留但不显示
    _pairedDeviceId = cfg.deviceId;
  }

  ServerConfig _buildConfig() {
    return ServerConfig(
      // 带上当前选中的身份，这样「保存并进入聊天」是修改这个网关，
      // 而不是悄悄新建一个重复项。
      id: _activeProfileId ?? '',
      name: _activeName,
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 3088,
      token: _tokenController.text.trim(),
      useHttps: _useHttps,
      // npsAddress 透传旧值：字段已从 UI 移除，但不能把存量配置悄悄清掉。
      npsAddress: _npsController.text.trim(),
      authCode: '',
      deviceId: _pairedDeviceId,
    );
  }

  // ------------------------------------------------- 多网关：切换 / 增删改 --

  /// Loads a saved gateway into the form. Deliberately does NOT persist: merely
  /// browsing the dropdown must not silently change which gateway the app starts
  /// with next launch. `保存并进入聊天` is what commits it.
  void _onProfileSelected(String? id) {
    if (id == null) return;
    ServerConfig? found;
    for (final c in _profiles) {
      if (c.id == id) {
        found = c;
        break;
      }
    }
    // 必须先落到一个 final 局部量再进闭包：Dart 不会对「在循环里被赋值过的可空
    // 局部变量」在闭包内做类型提升（闭包可能在后续赋值之后才执行），直接用会报
    // unchecked_use_of_nullable_value。
    final p = found;
    if (p == null) return;
    setState(() {
      _activeProfileId = id;
      _activeName = p.name;
      _fillForm(p);
    });
  }

  Future<void> _saveAsNewProfile() async {
    if (!_formKey.currentState!.validate()) return;
    final name = await _promptName(title: '另存为新网关', initial: _hostController.text.trim());
    if (name == null || !mounted) return;

    final cfg = _buildConfig();
    cfg.id = ''; // 强制分配新身份，否则会覆盖正在编辑的那个
    cfg.name = name;
    final profiles = await StorageService.upsertProfile(cfg);
    if (!mounted) return;

    setState(() {
      _profiles = profiles;
      _activeProfileId = cfg.id;
      _activeName = cfg.name;
    });
    _toast('已保存为「${cfg.displayName}」，点「保存并进入聊天」即可连接');
  }

  Future<void> _renameActiveProfile() async {
    final id = _activeProfileId;
    if (id == null) return;
    final name = await _promptName(title: '重命名网关', initial: _activeName);
    if (name == null || !mounted) return;
    final profiles = await StorageService.renameProfile(id, name);
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _activeName = name;
    });
  }

  Future<void> _deleteActiveProfile() async {
    final id = _activeProfileId;
    if (id == null) return;
    ServerConfig? target;
    for (final c in _profiles) {
      if (c.id == id) {
        target = c;
        break;
      }
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除已保存的网关？'),
        content: Text('将删除「${target?.displayName ?? ''}」。这只移除手机上保存的连接信息，'
            '不会影响宿主机上的会话与数据。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final profiles = await StorageService.deleteProfile(id);
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      if (profiles.isEmpty) {
        _activeProfileId = null;
        _activeName = '';
      } else {
        _activeProfileId = profiles.first.id;
        _activeName = profiles.first.name;
        _fillForm(profiles.first);
      }
    });
    _toast(profiles.isEmpty ? '已删除，列表已空' : '已删除，切换到「${profiles.first.displayName}」');
  }

  /// Name prompt shared by 另存 and 重命名. Returns null on cancel or blank.
  Future<String?> _promptName({required String title, required String initial}) async {
    final ctrl = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '网关名称',
            hintText: '如 家里台式机 / 公司笔记本 / nps 隧道',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    // 这个 controller 由本方法创建、不属于 State，所以要在 dialog future 落定后
    // 释放 —— 和 approval_card.dart 里修掉的是同一种泄漏。
    ctrl.dispose();
    final trimmed = result?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ------------------------------------------------------------- 扫码配对 --

  /// 扫码连接（v1.15）。
  ///
  /// [feat 2026-10-12] 二维码内容是网关 /pair/qr 生成的 JSON：
  ///   {v, hosts[], host, port, pairCode, name}
  /// 其中 pairCode 是**一次性 6 位配对码**（10 分钟过期、5 次错码作废），
  /// 不是长期 token —— 安全第一。扫码后本地调用 POST /__mobile/pair
  /// 用配对码换取真正的设备 token，再填充表单并保存连接。
  Future<void> _scanAndConnect() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _QrScanPage()),
    );
    if (scanned == null || !mounted) return;

    Map<String, dynamic>? payload;
    try {
      final decoded = jsonDecode(scanned);
      if (decoded is Map) payload = Map<String, dynamic>.from(decoded);
    } catch (_) {
      _toast('二维码内容无法识别（不是 DSH 配对码）');
      return;
    }
    final port = payload?['port'];
    final pairCode = payload?['pairCode']?.toString() ?? payload?['code']?.toString() ?? '';
    // [fix 2026-10-12] hosts 列表现在按「公网在前、局域网在后」排列（v1.15.1
    // 网关）。逐个尝试配对：家里 Wi-Fi 下公网地址也通，在外面时局域网地址
    // 不通自动落到下一个 —— 哪个先配对成功用哪个。
    final hosts = (payload?['hosts'] as List?)?.map((e) => e.toString()).where((h) => h.isNotEmpty).toList() ?? const [];
    final firstHost = payload?['host']?.toString() ??
        (hosts.isNotEmpty ? hosts.first : '');
    if (firstHost.isEmpty || pairCode.isEmpty || port is! int) {
      _toast('二维码缺少网关地址/端口/配对码');
      return;
    }

    _toast('正在用配对码换取设备凭据...');
    // 用配对码走现有 /__mobile/pair 握手换设备 token。
    String? token;
    String? deviceId;
    final attempted = <String>[]; // [fix 2026-10-12] 每个地址的尝试结果，失败时全量展示，绝不静默
    String? rejectReason; // 网关明确拒绝（换地址也没用的那类）
    String? usedHost;
    final candidates = <String>{firstHost, ...hosts};
    for (final host in candidates) {
      attempted.add(host);
      try {
        final res = await http.post(
          Uri.parse('http://$host:$port/__mobile/pair'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'code': pairCode, 'name': payload?['name']?.toString() ?? '扫码配对的手机', 'platform': 'android'}),
        ).timeout(const Duration(seconds: 8));
        final body = jsonDecode(res.body);
        if (res.statusCode == 200 && body is Map && body['ok'] == true) {
          token = body['token']?.toString();
          deviceId = body['deviceId']?.toString();
          usedHost = host;
          break;
        } else {
          // 网关明确拒绝（如配对码错/过期）——换地址也没用，直接报错。
          rejectReason = body is Map ? (body['error']?.toString() ?? 'HTTP ${res.statusCode}') : 'HTTP ${res.statusCode}';
          break;
        }
      } catch (e) {
        // 该地址不可达 —— 尝试下一个 host。
      }
    }
    if (!mounted) return;
    if (token == null || token.isEmpty) {
      if (rejectReason != null) {
        _toast('配对被网关拒绝: $rejectReason');
      } else {
        _toast('配对失败：以下地址都连不上（请确认电脑端网关已启动、隧道已开启）：\n${attempted.join('\n')}');
      }
      return;
    }

    setState(() {
      _hostController.text = usedHost ?? firstHost;
      _portController.text = port.toString();
      _tokenController.text = token!;
      _pairedDeviceId = deviceId ?? '';
    });
    _toast('配对成功${deviceId != null ? "（设备 $deviceId）" : ""}，点「保存并进入聊天」完成连接');
  }

  /// 全屏二维码扫描页。返回扫描到的原始字符串，取消返回 null。

  /// The gateway switcher row. Rendered above the form so switching is the first
  /// thing available on the page.
  Widget _buildGatewaySwitcher() {
    final ids = _profiles.map((p) => p.id).toSet();
    // 再校验一次：删除后 _activeProfileId 可能短暂指向不存在的项，
    // 而 DropdownButton 对 value 不在 items 中会直接断言失败。
    final selected = (_activeProfileId != null && ids.contains(_activeProfileId)) ? _activeProfileId : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
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
              Icon(Icons.dns_outlined, size: 18, color: context.c.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: !_profilesLoaded
                    ? const SizedBox(height: 22)
                    : _profiles.isEmpty
                        ? Text('尚无已保存的网关',
                            style: TextStyle(fontSize: 13, color: context.c.textTertiary))
                        : DropdownButton<String>(
                            isExpanded: true,
                            isDense: true,
                            value: selected,
                            hint: const Text('选择已保存的网关', style: TextStyle(fontSize: 13)),
                            underline: const SizedBox.shrink(),
                            style: TextStyle(fontSize: 13.5, color: context.c.textPrimary),
                            items: _profiles
                                .map((p) => DropdownMenuItem<String>(
                                      value: p.id,
                                      child: Text(p.displayName, overflow: TextOverflow.ellipsis),
                                    ))
                                .toList(),
                            onChanged: _onProfileSelected,
                          ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.drive_file_rename_outline, size: 18),
                tooltip: '重命名',
                onPressed: selected == null ? null : _renameActiveProfile,
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: '删除',
                onPressed: selected == null ? null : _deleteActiveProfile,
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                // 一键切换：设为活动网关并立刻连接。多网关用户的主要动作。
                TextButton.icon(
                  onPressed: selected == null ? null : _switchAndConnect,
                  icon: const Icon(Icons.bolt_rounded, size: 16),
                  label: const Text('切换并连接', style: TextStyle(fontSize: 12.5)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                TextButton.icon(
                  onPressed: _saveAsNewProfile,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('把当前填写内容另存为新网关', style: TextStyle(fontSize: 12.5)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
          if (selected != null)
            Padding(
              padding: const EdgeInsets.only(left: 10, bottom: 6),
              child: Text(
                '「切换并连接」设为活动网关并立即连接；下拉切换只填入表单，'
                '点「保存并进入聊天」才会记住表单里的改动。',
                style: TextStyle(fontSize: 11, color: context.c.textTertiary),
              ),
            ),
        ],
      ),
    );
  }

  void _testConnection() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isTesting = true);

    final config = _buildConfig();
    final dshService = Provider.of<DshService>(context, listen: false);
    final ok = await dshService.testConnection(config);

    if (!mounted) return;
    setState(() => _isTesting = false);
    if (ok) {
      dshService.clearAuthError();
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? '✅ 连接成功！鉴权验证通过'
            : '❌ 连接失败: ${dshService.lastError.isEmpty ? "Token 错误或网关未响应" : dshService.lastError}'),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
  }

  /// 一键切换并连接选中的网关。
  ///
  /// 之前 `setActiveProfile` 从来没有被调用过：切换下拉框只填表单，用户还得
  /// 再找「保存并进入聊天」才真的连上，而重度的多机用法（家里/公司两台）
  /// 每次换机要多点两下。这里把"设为活动 + 连接 + 进入对话"合成一个动作，
  /// 且**不覆盖**该网关已保存的字段 —— 切换不该顺手把表单里的临时编辑写回去。
  Future<void> _switchAndConnect() async {
    final id = _activeProfileId;
    if (id == null) return;

    final cfg = await StorageService.setActiveProfile(id);
    if (!mounted) return;
    if (cfg == null) {
      _toast('该网关已不存在，请重新保存');
      return;
    }

    final dshService = Provider.of<DshService>(context, listen: false);
    dshService.clearAuthError();
    await dshService.connect(cfg);
    if (!mounted) return;

    _toast('已切换到「${cfg.displayName}」');
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainShell()),
      );
    }
  }

  void _saveAndConnect() async {
    if (!_formKey.currentState!.validate()) return;

    final config = _buildConfig();
    await StorageService.saveConfig(config);

    if (!mounted) return;
    final dshService = Provider.of<DshService>(context, listen: false);
    dshService.clearAuthError();
    await dshService.connect(config);

    if (!mounted) return;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainShell()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('连接到 DSH 宿主机'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 网关切换器放在最上面：多网关时「换一台电脑」应该是进页面第一件事，
              // 而不是先翻过说明卡再手改 host 输入框。
              _buildGatewaySwitcher(),
              Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Icon(Icons.shield_outlined, color: Colors.blueAccent, size: 28),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '推荐点下方「扫码连接」自动配对；手动填写时只需'
                          '电脑的公网地址（或局域网 IP）、端口和 Token。'
                          '配对过的手机会在电脑设置页「已配对设备」中列出，可被单独移除。',
                          style: TextStyle(fontSize: 13, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: '公网 IP 或 动态域名 (DDNS)',
                  hintText: '如 123.45.67.89 或 dsh.yourdomain.com',
                  prefixIcon: Icon(Icons.dns),
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? '请输入服务器公网地址' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _portController,
                decoration: const InputDecoration(
                  labelText: '网关端口',
                  hintText: '默认 3088',
                  prefixIcon: Icon(Icons.numbers),
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                validator: (v) => (v == null || v.trim().isEmpty) ? '请输入端口' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _tokenController,
                decoration: const InputDecoration(
                  labelText: '安全认证 Token 密钥',
                  hintText: '需与 DSH 服务端设置的一致',
                  prefixIcon: Icon(Icons.key),
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
                validator: (v) => (v == null || v.trim().isEmpty) ? '请输入安全认证 Token 密钥' : null,
              ),
              const SizedBox(height: 16),
              // [fix 2026-10-12] NPS 地址 / 授权码两个旧字段已删除：npsAddress
              // 从未参与连接（只在旧设置页拼 APK 链接），授权码与 Token 是同一
              // 凭据的重复输入框（effectiveToken = token 优先、authCode 回落）。
              // 表单只剩连接真正需要的四项。模型字段保留做旧数据兼容读。
              SwitchListTile(
                title: const Text('启用 HTTPS / WSS'),
                subtitle: Text(_useHttps
                    ? '如果使用了域名和 SSL 证书请勾选'
                    : '未启用：Token 将以明文在每个请求头里传输'),
                value: _useHttps,
                onChanged: (val) => setState(() => _useHttps = val),
              ),
              // [fix 2026-10-16] 明文告警。
              //
              // `useHttps` 默认 false，而不启用时 token 是**明文**塞进
              // Authorization / x-dsh-token 头发出去的（见 ServerConfig.httpBaseUrl
              // 与 DshService 的 _authHeaders）。同一 Wi-Fi 下的任何人、链路上
              // 任何一跳都能直接读走它。
              //
              // 真正的修法是把 token 存进 Keystore（flutter_secure_storage），
              // 但那需要放开 pubspec 里 speech_to_text 6.6.2 的版本钉 —— 它的
              // js ^0.7.1 与 secure_storage 9.x 需要的 js ^0.6.3 直接冲突，
              // 而放开那个钉又依赖升级 Flutter / plugin-loader。那是另一件事。
              //
              // 在此之前，至少让"不加密"成为一个用户看得见的选择，而不是默认
              // 悄悄发生的事。
              if (!_useHttps)
                Padding(
                  padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 16, color: context.c.warning),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '当前为明文连接：同网络下的其他人可能读到你的 Token。'
                          '有域名和证书时请启用 HTTPS / WSS。',
                          style: TextStyle(fontSize: 12, color: context.c.warning, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: _isTesting ? null : _testConnection,
                icon: _isTesting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.network_check),
                label: Text(_isTesting ? '正在测试连接...' : '测试连通性'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _scanAndConnect,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫码连接（扫电脑端二维码，自动配对）'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _saveAndConnect,
                icon: const Icon(Icons.login),
                label: const Text('保存并进入聊天'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 全屏二维码扫描页（v1.15 扫码配对）。
///
/// [feat 2026-10-12] 识别到内容即返回；同一内容只触发一次，避免对同一个码
/// 连续吐出多帧。torch/相册导入这类增强刻意不做 —— 配对是低频动作，够用就好。
class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  bool _delivered = false;
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_delivered) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      _delivered = true;
      Navigator.of(context).pop(raw);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描电脑端配对二维码'),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          Positioned(
            left: 0, right: 0, bottom: 32,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '对准电脑「设置 → 移动终端」页生成的二维码',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
