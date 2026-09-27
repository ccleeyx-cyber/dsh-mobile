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
  final _tokenController = TextEditingController(text: 'DSH_SECURE_TOKEN_2026');
  bool _useHttps = false;
  bool _isTesting = false;

  @override
  void initState() {
    super.initState();
    _loadInitialConfig();
  }

  void _loadInitialConfig() async {
    final cfg = await StorageService.loadConfig();
    if (cfg != null) {
      setState(() {
        _hostController.text = cfg.host;
        _portController.text = cfg.port.toString();
        _tokenController.text = cfg.token;
        _useHttps = cfg.useHttps;
      });
    }
  }

  ServerConfig _buildConfig() {
    return ServerConfig(
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 3088,
      token: _tokenController.text.trim(),
      useHttps: _useHttps,
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
    await dshService.connect(config);

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MainShell()),
    );
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
                validator: (v) => (v == null || v.trim().isEmpty) ? '请输入 Token' : null,
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
