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
      title: 'DSH Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF9FAFB),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0078D4),
          brightness: Brightness.light,
          surface: Colors.white,
          primary: const Color(0xFF0078D4),
          background: const Color(0xFFF9FAFB),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF1F2937),
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: IconThemeData(color: Color(0xFF374151)),
          titleTextStyle: TextStyle(
            color: Color(0xFF111827),
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        cardTheme: CardTheme(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFFE5E7EB), width: 1),
          ),
        ),
        dividerColor: const Color(0xFFE5E7EB),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF9FAFB),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0078D4),
          brightness: Brightness.light,
          surface: Colors.white,
          primary: const Color(0xFF0078D4),
          background: const Color(0xFFF9FAFB),
        ),
      ),
      themeMode: ThemeMode.light,
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
