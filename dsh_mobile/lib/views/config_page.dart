import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/server_config.dart';
import '../services/dsh_service.dart';
import '../services/storage_service.dart';
import 'main_shell.dart';

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
  final _npsController = TextEditingController(text: '');
  final _authCodeController = TextEditingController(text: '');
  bool _useHttps = false;
  bool _isTesting = false;

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
    _authCodeController.dispose();
    super.dispose();
  }

  void _loadInitialConfig() async {
    final cfg = await StorageService.loadConfig();
    // loadConfig() 读 SharedPreferences，是异步的。若用户在它返回之前就退出本页，
    // State 已经 dispose，此时再 setState() 会抛 "setState() called after dispose()"。
    // 必须加 mounted 守卫 —— 同文件的 _testConnection()/_saveAndConnect() 都加了，
    // 唯独这个启动路径漏了。
    if (!mounted || cfg == null) return;
    setState(() {
      _hostController.text = cfg.host;
      _portController.text = cfg.port.toString();
      _tokenController.text = cfg.token;
      _useHttps = cfg.useHttps;
      _npsController.text = cfg.npsAddress;
      _authCodeController.text = cfg.authCode;
    });
  }

  ServerConfig _buildConfig() {
    final tokenText = _tokenController.text.trim();
    final authText = _authCodeController.text.trim();
    final effectiveToken = tokenText.isNotEmpty ? tokenText : authText;

    return ServerConfig(
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 3088,
      token: effectiveToken,
      useHttps: _useHttps,
      npsAddress: _npsController.text.trim(),
      authCode: authText,
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
                          '请输入你的公网 IP 及 DSH 安全网关配置，Token 用于验证手机身份以保证安全。',
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
                validator: (v) {
                  final token = v?.trim() ?? '';
                  final authCode = _authCodeController.text.trim();
                  if (token.isEmpty && authCode.isEmpty) {
                    return '请输入安全认证 Token 密钥或授权码';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              // NPS 地址 field
              TextFormField(
                controller: _npsController,
                decoration: const InputDecoration(
                  labelText: 'NPS 地址 (可选)',
                  hintText: '例如 10.0.0.1 或 domain.nps.com',
                  prefixIcon: Icon(Icons.network_check),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              // Auth Code field
              TextFormField(
                controller: _authCodeController,
                decoration: const InputDecoration(
                  labelText: '授权码 (可选)',
                  hintText: '用于额外授权或审计',
                  prefixIcon: Icon(Icons.lock),
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                title: const Text('启用 HTTPS / WSS'),
                subtitle: const Text('如果使用了域名和 SSL 证书请勾选'),
                value: _useHttps,
                onChanged: (val) => setState(() => _useHttps = val),
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
