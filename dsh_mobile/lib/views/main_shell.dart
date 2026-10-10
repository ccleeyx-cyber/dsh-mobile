import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/dsh_service.dart';
import '../main.dart';
import 'chat_view.dart';
import 'workspaces_view.dart';
import 'security_permissions_view.dart';
import 'custom_settings_view.dart';
import 'config_page.dart';
import '../theme/app_colors.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 点按通知（后台运行态）→ 切到对话 tab 并打开对应会话。
    pendingNotificationSink = _consumePendingNotification;
    // 冷启动 / 已停后台时点按通知，MainShell 一挂载就消费。
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumePendingNotification());
  }

  void _consumePendingNotification() {
    final sid = pendingNotificationSessionId;
    if (sid == null || sid.isEmpty || !mounted) return;
    pendingNotificationSessionId = null;
    setState(() => _currentIndex = 0);
    Provider.of<DshService>(context, listen: false).openSessionById(sid);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(pendingNotificationSink, _consumePendingNotification)) {
      pendingNotificationSink = null;
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final dsh = Provider.of<DshService>(context, listen: false);
    if (state == AppLifecycleState.resumed) {
      dsh.handleAppResumed();
      _consumePendingNotification(); // 点通知回前台时消费跳转
      // 回到前台：停止后台保活（前台不需要它），并且此后不再发通知 ——
      // 界面就在眼前，再弹通知是噪音。
      dsh.setAppForeground(true);
    } else if (state == AppLifecycleState.paused) {
      dsh.handleAppPaused();
      // 进后台：此后才需要通知。同时尝试拉起前台服务把进程钉住，否则系统
      // 随时可能回收它，WebSocket 随之断开，通知就永远不会来。
      dsh.setAppForeground(false);
      dsh.enableBackgroundNotifications();
    } else if (state == AppLifecycleState.hidden) {
      // Android 上从后台划掉任务会先走 hidden 再走 paused；这里只标记状态，
      // 不重复拉起服务。
      dsh.setAppForeground(false);
    }
  }

  void _setIndex(int index) {
    setState(() {
      _currentIndex = index;
    });
    final dsh = Provider.of<DshService>(context, listen: false);
    if (index == 1) {
      dsh.fetchWorkspaces();
      dsh.fetchApprovals();
    } else if (index == 2) {
      dsh.fetchApprovals();
    } else if (index == 3) {
      dsh.fetchSettings();
    }
  }

  Widget _buildNavBadge(Widget icon, int count) {
    if (count <= 0) return icon;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          right: -8,
          top: -4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: context.c.warning,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.c.surface, width: 1.5),
            ),
            constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
            child: Text(
              count > 9 ? '9+' : '$count',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9.5,
                fontWeight: FontWeight.bold,
                height: 1.0,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 只订阅 build() 真正用到的两个值。
    //
    // 原来这里是 Provider.of<DshService>(context)（listen: true），意味着
    // DshService 每调一次 notifyListeners() 就重建整个 MainShell —— 而流式输出
    // 期间它是按 token 触发的。每次重建都会重新构造 IndexedStack 的全部 4 个
    // 子树（ChatView / WorkspacesView / SecurityPermissionsView /
    // CustomSettingsView），而这些子页自己本来就在监听 DshService，于是同一份
    // 数据被重复构建两遍。context.select 只在被选中的值变化时才重建。
    final pendingCount = context.select<DshService, int>((d) => d.pendingApprovals.length);
    // 对话页的徽标要**连提问一起算**：提问同样是"agent 停下来等你"，
    // 而且此前它只在当前会话的输入框上方出现 —— 你在别的会话/别的 tab 时
    // 完全看不到任何提示（用户实测："提问没显示、也没通知"）。
    final waitingCount = context.select<DshService, int>(
      (d) => d.pendingApprovals.length + d.pendingQuestions.length,
    );
    // 这里**曾经**有一个"任务" tab 的角标：排队消息 + 活着的后台作业。
    // 它删掉的原因是它从设计上就不可能对：`jobs` 只有"任务页被打开"这一条写入
    // 路径（而 index 只有面板打开才拉），所以没进过页面时它恒为 0，进过一次之后
    // 又永远停在那一刻 —— 两个方向都是错的。删除后：
    //   * 排队消息的信号由会话的输入框（dock）与状态条承载：队列是**单会话**的，
    //     放在 tab 上反而误导（"这是哪个会话的队列？"）；
    //   * 作业状态只出现在当前会话的状态条与信息面板里。
    final isTokenInvalid = context.select<DshService, bool>((d) => d.isTokenInvalid);

    // 键盘弹出时隐藏底部导航栏 —— 这是修一个真实的布局缺陷，不是装饰性调整。
    //
    // 成因：chat_view 内部有自己的 Scaffold（未显式设置，因此
    // resizeToAvoidBottomInset 取默认的 true），它会按**完整**键盘高度抬高内容；
    // 而外层这个 Scaffold 关掉了 resize，底部导航栏仍占着屏幕最下方。于是内层
    // Scaffold 的底边比屏幕底边高出一个导航栏的高度，却仍按整段键盘高度抬高 →
    // 输入框被多抬了"一个导航栏"的高度，输入框与键盘之间就空出一条和导航栏
    // 一样高的空白。
    //
    // 去掉导航栏后，内层底边 == 屏幕底边，抬高量恰好等于键盘高度，空白消失。
    // 顺带这也是聊天类 App 的常规行为（打字时让出空间）。
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;

    // 侧滑返回拦截：MainShell 是 home 路由，没有可 pop 的上一级 —— 系统
    // 预测性返回手势会直接退出 App。用户预期是"回到工作区"（聊天 App 的
    // 常规动线），所以**除对话页之外**的 tab 侧滑 = 切到工作区（index 1）；
    // 已经在别的 tab（工作区/安全策略/设置）时才放行为真正的退出。
    //
    // 这里顺带改了旧代码与它自己的注释不一致的地方：旧条件是
    // `index == 1 || index == 2 || index == 3`（工作区/任务/安全策略），把**设置页**
    // 排除在外，于是从设置页侧滑会跳到工作区而不是退出 —— 与注释描述的意图相反。
    // 「任务」tab 删掉后索引变成 0 对话 / 1 工作区 / 2 安全策略 / 3 设置，
    // 直接表达成"不在对话页就可以退出"。
    final canExit = _currentIndex != 0;

    return PopScope(
      canPop: canExit,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _setIndex(1);
      },
      child: Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: context.c.surfaceMuted,
      body: Column(
        children: [
          if (isTokenInvalid)
            Container(
              width: double.infinity,
              color: context.c.dangerSurface,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.key_off_rounded, color: context.c.danger, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '访问令牌已失效 (401 Unauthorized)。请更新服务器访问令牌。',
                      style: TextStyle(color: context.c.danger, fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ConfigPage()),
                      );
                    },
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text('更新令牌', style: TextStyle(color: context.c.danger, fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ],
              ),
            ),
          Expanded(
            child: IndexedStack(
              index: _currentIndex,
              children: [
                ChatView(
                  onOpenWorkspaces: () => _setIndex(1),
                  onOpenSecurity: () => _setIndex(2),
                ),
                WorkspacesView(
                  onSwitchToChat: () => _setIndex(0),
                  // IndexedStack 会保活全部 4 个子页，必须显式告知可见性，
                  // 否则本页的 3 秒轮询会在用户处于其它 tab 时继续跑。
                  active: _currentIndex == 1,
                ),
                SecurityPermissionsView(onOpenChat: () => _setIndex(0)),
                const CustomSettingsView(),
              ],
            ),
          ),
        ],
      ),
      // 键盘弹出时置空 —— 见上面 keyboardOpen 处的说明，这是修输入框下方
      // 那条空白的必要一步。
      bottomNavigationBar: keyboardOpen ? null : Container(
        decoration: BoxDecoration(
          color: context.c.surface,
          border: Border(top: BorderSide(color: context.c.border, width: 1.0)),
        ),
        child: SafeArea(
          child: NavigationBarTheme(
            data: NavigationBarThemeData(
              backgroundColor: context.c.surface,
              indicatorColor: context.c.accent.withOpacity(0.12),
              labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>((states) {
                if (states.contains(WidgetState.selected)) {
                  return TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.c.accent,
                  );
                }
                return TextStyle(fontSize: 12, color: context.c.textSecondary);
              }),
              iconTheme: WidgetStateProperty.resolveWith<IconThemeData>((states) {
                if (states.contains(WidgetState.selected)) {
                  return IconThemeData(color: context.c.accent, size: 24);
                }
                return IconThemeData(color: context.c.textSecondary, size: 24);
              }),
            ),
            child: NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: _setIndex,
              destinations: [
                NavigationDestination(
                  icon: _buildNavBadge(const Icon(Icons.chat_bubble_outline_rounded), waitingCount),
                  selectedIcon: _buildNavBadge(const Icon(Icons.chat_bubble_rounded), waitingCount),
                  label: '对话',
                ),
                NavigationDestination(
                  icon: _buildNavBadge(const Icon(Icons.folder_outlined), pendingCount),
                  selectedIcon: _buildNavBadge(const Icon(Icons.folder_rounded), pendingCount),
                  label: '工作区',
                ),
                NavigationDestination(
                  icon: _buildNavBadge(const Icon(Icons.security_outlined), pendingCount),
                  selectedIcon: _buildNavBadge(const Icon(Icons.security_rounded), pendingCount),
                  label: '安全策略',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.tune_rounded),
                  selectedIcon: Icon(Icons.tune_rounded),
                  label: '设置',
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}
