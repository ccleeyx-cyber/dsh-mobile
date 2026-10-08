import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/dsh_service.dart';
import 'chat_view.dart';
import 'workspaces_view.dart';
import 'security_permissions_view.dart';
import 'custom_settings_view.dart';
import 'config_page.dart';

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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final dsh = Provider.of<DshService>(context, listen: false);
    if (state == AppLifecycleState.resumed) {
      dsh.handleAppResumed();
    } else if (state == AppLifecycleState.paused) {
      dsh.handleAppPaused();
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
              color: const Color(0xFFD97706),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white, width: 1.5),
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
    final dsh = Provider.of<DshService>(context);
    final pendingCount = dsh.pendingApprovals.length;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFFF9FAFB),
      body: Column(
        children: [
          if (dsh.isTokenInvalid)
            Container(
              width: double.infinity,
              color: const Color(0xFFFEF2F2),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.key_off_rounded, color: Color(0xFFDC2626), size: 16),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '访问令牌已失效 (401 Unauthorized)。请更新服务器访问令牌。',
                      style: TextStyle(color: Color(0xFF991B1B), fontSize: 12, fontWeight: FontWeight.w500),
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
                    child: const Text('更新令牌', style: TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.bold, fontSize: 12)),
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
                ),
                const SecurityPermissionsView(),
                const CustomSettingsView(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE5E7EB), width: 1.0)),
        ),
        child: SafeArea(
          child: NavigationBarTheme(
            data: NavigationBarThemeData(
              backgroundColor: Colors.white,
              indicatorColor: const Color(0xFF0078D4).withOpacity(0.12),
              labelTextStyle: MaterialStateProperty.resolveWith<TextStyle>((states) {
                if (states.contains(MaterialState.selected)) {
                  return const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF0078D4),
                  );
                }
                return const TextStyle(fontSize: 12, color: Color(0xFF6B7280));
              }),
              iconTheme: MaterialStateProperty.resolveWith<IconThemeData>((states) {
                if (states.contains(MaterialState.selected)) {
                  return const IconThemeData(color: Color(0xFF0078D4), size: 24);
                }
                return const IconThemeData(color: Color(0xFF6B7280), size: 24);
              }),
            ),
            child: NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: _setIndex,
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline_rounded),
                  selectedIcon: Icon(Icons.chat_bubble_rounded),
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
                  label: '权限安全',
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
    );
  }
}
