import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/dsh_service.dart';
import 'chat_view.dart';
import 'workspaces_view.dart';
import 'security_permissions_view.dart';
import 'custom_settings_view.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  void _setIndex(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final pendingCount = dsh.pendingApprovals.length;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      body: IndexedStack(
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
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF131B2E),
          border: Border(top: BorderSide(color: Colors.white10, width: 0.8)),
        ),
        child: SafeArea(
          child: NavigationBarTheme(
            data: NavigationBarThemeData(
              backgroundColor: Colors.transparent,
              indicatorColor: Colors.blueAccent.withOpacity(0.2),
              labelTextStyle: MaterialStateProperty.resolveWith<TextStyle>((states) {
                if (states.contains(MaterialState.selected)) {
                  return const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.blueAccent,
                  );
                }
                return const TextStyle(fontSize: 12, color: Colors.white54);
              }),
              iconTheme: MaterialStateProperty.resolveWith<IconThemeData>((states) {
                if (states.contains(MaterialState.selected)) {
                  return const IconThemeData(color: Colors.blueAccent, size: 24);
                }
                return const IconThemeData(color: Colors.white54, size: 24);
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
                const NavigationDestination(
                  icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder_rounded),
                  label: '工作区',
                ),
                NavigationDestination(
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.security_outlined),
                      if (pendingCount > 0)
                        Positioned(
                          right: -6,
                          top: -4,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: Colors.amberAccent,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '$pendingCount',
                              style: const TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                    ],
                  ),
                  selectedIcon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.security_rounded),
                      if (pendingCount > 0)
                        Positioned(
                          right: -6,
                          top: -4,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: Colors.amberAccent,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '$pendingCount',
                              style: const TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                    ],
                  ),
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
