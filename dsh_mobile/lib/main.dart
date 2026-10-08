import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/server_config.dart';
import 'services/dsh_service.dart';
import 'services/storage_service.dart';
import 'views/config_page.dart';
import 'views/main_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // F4.2: Defensive error boundary preventing red screen of death
  ErrorWidget.builder = (FlutterErrorDetails details) {
    debugPrint('[ErrorWidget.builder] Handled layout/rendering error: ${details.exception}');
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: SelectableText(
          details.exceptionAsString(),
          style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), fontFamily: 'monospace'),
        ),
      ),
    );
  };
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

class MyApp extends StatefulWidget {
  final ServerConfig? initialConfig;

  const MyApp({super.key, this.initialConfig});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _connectScheduled = false;

  @override
  void initState() {
    super.initState();
    final cfg = widget.initialConfig;
    if (cfg != null && cfg.host.isNotEmpty) {
      // 启动时在后台尝试连接。
      // 这里必须放在 initState 的首帧回调，而不是 build()：在 build() 中注册
      // addPostFrameCallback 属于「构建期安排副作用」，每次重建都会再排一次
      // connect()。_connectScheduled 再兜一层，确保整个生命周期只连一次。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _connectScheduled) return;
        _connectScheduled = true;
        Provider.of<DshService>(context, listen: false).connect(cfg);
      });
    }
  }

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
          // `background:` 自 v3.18 起废弃，职责已由 `surface:` 承担；而脚手架
          // 底色上面已用 scaffoldBackgroundColor 显式指定，故直接删除该参数，
          // 不再重复赋一个同色值。
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
      // darkTheme 已移除（原为安慰剂）。
      //
      // 原来这里的 darkTheme 是亮色主题的逐字副本：brightness: Brightness.light、
      // surface: Colors.white、scaffoldBackgroundColor: 0xFFF9FAFB，再配合硬编码的
      // themeMode: ThemeMode.light —— 它永远不可能被使用，只是让读代码的人以为
      // 「支持深色模式」。
      //
      // 之所以不直接换成真的深色主题：lib/ 下有约 481 处硬编码色值（Colors.white、
      // Color(0xFFF9FAFB) 等，详见 ANALYSIS-优化与新增功能.md §6.9），它们不经过
      // Theme 取值。只改 darkTheme 会得到「深色脚手架 + 白色卡片 + 深色文字」的
      // 花屏结果，比现在诚实地恒为亮色更糟，而且无法在不跑真机的情况下验证。
      //
      // 正确顺序是先做色值 token 化，再引入深色主题。themeMode 保持 light，
      // 渲染行为与移除前逐像素一致。
      themeMode: ThemeMode.light,
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    final cfg = widget.initialConfig;
    if (cfg != null && cfg.host.isNotEmpty) return const MainShell();
    return const ConfigPage();
  }
}
