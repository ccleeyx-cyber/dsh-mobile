import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/server_config.dart';
import 'services/dsh_service.dart';
import 'services/draft_store.dart';
import 'services/notification_service.dart';
import 'services/storage_service.dart';
import 'theme/app_colors.dart';
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
          // 错误边界的颜色刻意固定取浅色值：ErrorWidget.builder 是一个全局回调，
          // 签名里没有 BuildContext，拿不到 ThemeScope。这里的深色下会是一块浅色
          // 面板，但它只在渲染崩溃时出现一次 —— 为此引入一个全局主题单例
          // （以及它带来的初始化顺序问题）不值得。正常路径永远走不到这里。
          color: AppColors.background,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.border),
        ),
        child: SelectableText(
          details.exceptionAsString(),
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontFamily: 'monospace'),
        ),
      ),
    );
  };
  final savedConfig = await StorageService.loadConfig();
  final savedThemeMode = await StorageService.loadThemeMode();

  // 草稿存储要在 runApp 之前接好 SharedPreferences（v1.4.2）。DshService 构造时
  // 就 new 出了 DraftStore，所以这里只挂实例、不改 provider 结构 —— 让
  // DraftStore 先在内存里可用（早期打的字不丢），再补上持久化。
  final prefs = await SharedPreferences.getInstance();
  DraftStore.instance.attach(prefs);

  // 通知权限必须在 runApp 之后申请（Android 需要 Activity），所以结果通过
  // ThemeController 之外的一条路径回填 —— 这里只启动异步探测，实际状态由
  // NotificationService 自己持有。
  unawaited(NotificationService.instance.init());

  // 点按通知 → 直达对应会话。payload 形如 `session:<kind>:<sessionId>`。
  // 回调先暂存到静态字段：navigatorKey 在 runApp 之后才可用（冷启动时点按
  // 通知到达得比第一帧还早），MainShell 挂载后第一件事消费它。
  NotificationService.instance.onSelectNotification = (payload) {
    if (payload.startsWith('session:')) {
      final parts = payload.split(':');
      if (parts.length >= 3) {
        pendingNotificationSessionId = parts.sublist(2).join(':');
      }
    }
    // MainShell 处于运行态时立即触发一次消费（后台点击）。
    pendingNotificationSink?.call();
  };

  // 冷启动点通知（进程被杀后由通知拉起）在 Android 上不会走
  // onDidReceiveNotificationResponse —— payload 只能从
  // getNotificationAppLaunchDetails() 里取。不补这一步，跳转会话的
  // session id 直接丢失，用户"点进去没有操作选项"。
  // 等 init() 完成（插件就绪）后再查，避免在未初始化的插件上抛异常。
  unawaited(NotificationService.instance.init().then((_) {
    return NotificationService.instance.consumeLaunchNotification();
  }));

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => DshService()),
        ChangeNotifierProvider(create: (_) => ThemeController(initialMode: savedThemeMode)),
      ],
      child: MyApp(initialConfig: savedConfig),
    ),
  );
}

/// 待跳转的会话 id（来自点按的通知）。消费后置 null。
String? pendingNotificationSessionId;

/// MainShell 注册的"有新跳转"触发器（后台点击通知时，App 已在前台运行）。
void Function()? pendingNotificationSink;

/// 全局 navigator key —— 通知跳转需要无 BuildContext 的导航出口。
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// 主题模式控制器（v1.6.0 深色模式）。
///
/// 存在 service 层而不是 widget 本地 state，是为了让主题切换在**整个应用**生效
/// —— 很多页面各自维护 rebuild 会漏掉一些，导致只切换了一半。
class ThemeController extends ChangeNotifier {
  /// 'system' | 'light' | 'dark'
  String _mode;

  ThemeController({String initialMode = 'system'}) : _mode = initialMode;

  String get mode => _mode;

  ThemeMode get themeMode => switch (_mode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  bool get isExplicit => _mode != 'system';

  Future<void> setMode(String mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    await StorageService.saveThemeMode(mode);
  }

  /// 循环切换：跟随系统 → 浅色 → 深色 → 跟随系统。
  ///
  /// 单按钮循环而不是三选一的下拉：主题切换是一个低频、高频重复的操作，一个
  /// 按钮点三下比打开下拉更快。
  Future<void> cycle() async {
    final next = switch (_mode) {
      'system' => 'light',
      'light' => 'dark',
      _ => 'system',
    };
    await setMode(next);
  }

  String get label => switch (_mode) {
        'light' => '浅色',
        'dark' => '深色',
        _ => '跟随系统',
      };
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
    final themeMode = context.watch<ThemeController>().themeMode;
    final isDark = themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);

    return MaterialApp(
      title: 'DSH Mobile',
      debugShowCheckedModeBanner: false,
      // 通知点按跳转需要无 context 的导航出口。
      navigatorKey: navigatorKey,
      theme: buildLightTheme(),
      // 真的深色主题（v1.6.0）。此前这里是一个亮色主题的逐字副本，永远不会被
      // 使用，只让读代码的人以为支持深色。
      //
      // 之所以那时不能直接换成真的：lib/ 下有 592 处硬编码 Color(0x...)，它们
      // 不经过 Theme 取值，只改 darkTheme 会得到「深色脚手架 + 白色卡片 +
      // 深色文字」的花屏，比诚实地恒为亮色更糟。正确顺序是先 token 化
      // （lib/theme/app_colors.dart），再引入深色主题，最后放开 themeMode。
      darkTheme: buildDarkTheme(),
      themeMode: themeMode,
      // 让 ThemeScope 覆盖整棵树：widget 测试可以直接包一层 ThemeScope 来
      // 断言深色取值，不需要 singleton 或 mockito。
      builder: (context, child) => ThemeScope(isDark: isDark, child: child ?? const SizedBox()),
      home: _buildHome(),
    );
  }

  /// 浅色主题。作为顶层函数而非 State 方法，是为了让 widget 测试能直接调用并逐项
/// 比对两个主题的结构 —— 挂在 State 上就只能通过 pump 一个 widget 绕着测，
  Widget _buildHome() {
    final cfg = widget.initialConfig;
    if (cfg != null && cfg.host.isNotEmpty) return const MainShell();
    return const ConfigPage();
  }
}

/// 浅色主题。作为顶层函数而非 State 方法，是为了让 widget 测试能直接调用并逐项
/// 比对两个主题的结构 —— 挂在 State 上就只能通过 pump 一个 widget 绕着测，
/// 而那种测法无法保证对比的是真实实现。
ThemeData buildLightTheme() => ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.accent,
        brightness: Brightness.light,
        surface: AppColors.surface,
        primary: AppColors.accent,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: AppColors.textSecondary),
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardTheme(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.border, width: 1),
        ),
      ),
      dividerColor: AppColors.border,
    );

/// 深色主题。与浅色主题**结构相同、只换取值**，不做删减 —— 一个只有一半 widget
/// 适配了深色的版本，比恒为亮色更糟。
ThemeData buildDarkTheme() => ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.backgroundDark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.accentDark,
        brightness: Brightness.dark,
        surface: AppColors.surfaceDark,
        primary: AppColors.accentDark,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surfaceDark,
        foregroundColor: AppColors.textPrimaryDark,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: AppColors.textSecondaryDark),
        titleTextStyle: TextStyle(
          color: AppColors.textPrimaryDark,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardTheme(
        color: AppColors.surfaceDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.borderDark, width: 1),
        ),
      ),
      dividerColor: AppColors.borderDark,
    );
