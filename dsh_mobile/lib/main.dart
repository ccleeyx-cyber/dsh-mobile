import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/server_config.dart';
import 'services/dsh_service.dart';
import 'services/storage_service.dart';
import 'views/config_page.dart';
import 'views/main_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final savedConfig = await StorageService.loadConfig();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => DshService()),
      ],
      child: MyApp(initialConfig: savedConfig),
    ),
  );
}

class MyApp extends StatelessWidget {
  final ServerConfig? initialConfig;

  const MyApp({super.key, this.initialConfig});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WorkBuddy Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.dark,
          surface: const Color(0xFF131B2E),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.dark,
          surface: const Color(0xFF131B2E),
        ),
      ),
      themeMode: ThemeMode.dark,
      home: _buildHome(context),
    );
  }

  Widget _buildHome(BuildContext context) {
    if (initialConfig != null && initialConfig!.host.isNotEmpty) {
      // 启动时在后台尝试连接
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Provider.of<DshService>(context, listen: false).connect(initialConfig!);
      });
      return const MainShell();
    }
    return const ConfigPage();
  }
}
