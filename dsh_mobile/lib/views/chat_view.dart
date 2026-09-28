import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/chat_message.dart';
import '../models/workspace.dart';
import '../models/permission_config.dart';
import '../services/dsh_service.dart';
import '../widgets/thinking_card.dart';
import '../widgets/tool_call_card.dart';
import '../widgets/approval_card.dart';
import '../widgets/memory_card.dart';

class ChatView extends StatefulWidget {
  final VoidCallback? onOpenWorkspaces;
  final VoidCallback? onOpenSecurity;

  const ChatView({
    super.key,
    this.onOpenWorkspaces,
    this.onOpenSecurity,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String? _lastSessionId;
  bool _showScrollToBottom = false;
  int _lastMessageCount = 0;
  bool _wasLoadingHistory = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentOffset = _scrollController.offset;
    final show = (maxScroll - currentOffset) > 160;
    if (show != _showScrollToBottom) {
      setState(() {
        _showScrollToBottom = show;
      });
    }
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendMessage(DshService dsh) {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    _inputController.clear();
    dsh.sendChatMessage(text);
    _scrollToBottom();
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return DateFormat('HH:mm').format(dt);
    }
    return DateFormat('MM-dd HH:mm').format(dt);
  }

  // Session Permission Dialog / BottomSheet
  void _showSessionPermissionSheet(BuildContext context, DshService dsh) {
    final currentSession = dsh.currentSession;
    final sessionId = currentSession?.sessionId ?? 'default';
    final currentPolicy = dsh.getSessionPermission(sessionId);
    String selectedPolicy = currentPolicy;
    String sandboxMode = dsh.permissions.sandboxMode;
    int maxSteps = dsh.permissions.maxSteps;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF252526),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0078D4).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFF0078D4).withOpacity(0.3)),
                          ),
                          child: const Icon(Icons.shield_outlined, color: Color(0xFF60A5FA), size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '对话权限与执行策略',
                                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
                              ),
                              Text(
                                '当前对话: ${currentSession?.title ?? sessionId}',
                                style: const TextStyle(fontSize: 12, color: Colors.white54),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      '终端命令执行策略 (Execution Policy)',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white70),
                    ),
                    const SizedBox(height: 10),

                    // Policy Option: Ask
                    _buildPolicyOption(
                      title: '🛡️ 每次询问 (Ask Every Time)',
                      subtitle: '最安全。任何 Shell / 脚本执行都需在手机端审批确认',
                      value: 'ask',
                      groupValue: selectedPolicy,
                      onChanged: (val) {
                        setModalState(() => selectedPolicy = val!);
                      },
                    ),

                    // Policy Option: Auto Read-Only
                    _buildPolicyOption(
                      title: '🔍 自动放行只读 (Auto Read-Only)',
                      subtitle: '推荐。ls, grep, cat, git status 等只读指令直接运行，写操作拦截确认',
                      value: 'auto-read',
                      groupValue: selectedPolicy,
                      onChanged: (val) {
                        setModalState(() => selectedPolicy = val!);
                      },
                    ),

                    // Policy Option: Danger Full Access
                    _buildPolicyOption(
                      title: '⚡ 完全信任模式 (Danger Full Access)',
                      subtitle: '全自动无阻塞运行。所有命令免审批执行，适合无人值守任务',
                      value: 'danger-full-access',
                      groupValue: selectedPolicy,
                      onChanged: (val) {
                        setModalState(() => selectedPolicy = val!);
                      },
                    ),

                    const SizedBox(height: 16),
                    const Text(
                      '单轮迭代步数上限 (Max Steps)',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white70),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: maxSteps.toDouble(),
                            min: 10,
                            max: 60,
                            divisions: 10,
                            activeColor: const Color(0xFF0078D4),
                            label: '$maxSteps 步',
                            onChanged: (v) {
                              setModalState(() => maxSteps = v.round());
                            },
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.white.withOpacity(0.08)),
                          ),
                          child: Text('$maxSteps 步', style: const TextStyle(color: Colors.white, fontSize: 13)),
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0078D4),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          elevation: 0,
                        ),
                        onPressed: () async {
                          await dsh.setSessionPermission(sessionId, selectedPolicy);
                          final updatedPerms = dsh.permissions.copyWith(maxSteps: maxSteps);
                          await dsh.updatePermissions(updatedPerms);
                          if (context.mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('已更新会话权限策略: ${_getPolicyLabel(selectedPolicy)}'),
                                duration: const Duration(seconds: 2),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        },
                        child: const Text('保存权限策略', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPolicyOption({
    required String title,
    required String subtitle,
    required String value,
    required String groupValue,
    required ValueChanged<String?> onChanged,
  }) {
    final isSelected = value == groupValue;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0078D4).withOpacity(0.14) : const Color(0xFF2D2D2D),
          border: Border.all(
            color: isSelected ? const Color(0xFF0078D4) : const Color(0xFF3B3B3B),
            width: isSelected ? 1.5 : 1.0,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Radio<String>(
              value: value,
              groupValue: groupValue,
              onChanged: onChanged,
              activeColor: const Color(0xFF0078D4),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? Colors.blueAccent : Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getPolicyLabel(String policy) {
    switch (policy) {
      case 'danger-full-access':
        return '⚡ 完全放行';
      case 'auto-read':
        return '🔍 只读放行';
      case 'ask':
      default:
        return '🛡️ 每次询问';
    }
  }

  Color _getPolicyColor(String policy) {
    switch (policy) {
      case 'danger-full-access':
        return Colors.greenAccent;
      case 'auto-read':
        return Colors.cyanAccent;
      case 'ask':
      default:
        return Colors.amberAccent;
    }
  }

  // Quick Model Selector Sheet
  void _showModelSwitchSheet(BuildContext context, DshService dsh) {
    final settings = dsh.settings;
    final currentSession = dsh.currentSession;
    final activeModel = dsh.currentModel;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF252526),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: const [
                    Icon(Icons.smart_toy_outlined, color: Color(0xFFC084FC), size: 20),
                    SizedBox(width: 8),
                    Text(
                      '切换大语言模型 (Switch Model)',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ],
                ),
                if (currentSession != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 28),
                    child: Text(
                      '生效会话: ${currentSession.title}',
                      style: const TextStyle(fontSize: 12, color: Colors.white54),
                    ),
                  ),
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: settings?.availableModels.length ?? 0,
                    itemBuilder: (context, index) {
                      final m = settings!.availableModels[index];
                      final isSelected = m.id == activeModel;
                      return ListTile(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        tileColor: isSelected ? const Color(0xFF0078D4).withOpacity(0.14) : null,
                        title: Text(
                          m.name,
                          style: TextStyle(
                            color: isSelected ? const Color(0xFF60A5FA) : Colors.white,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          '${m.id} | 上下文: ${(m.contextWindow ?? 0) ~/ 1000}k',
                          style: const TextStyle(fontSize: 12, color: Colors.white54),
                        ),
                        trailing: isSelected ? const Icon(Icons.check_circle, color: Color(0xFF60A5FA), size: 18) : null,
                        onTap: () async {
                          Navigator.pop(ctx);
                          final ok = await dsh.switchModel(m.id, sessionId: currentSession?.sessionId);
                          if (context.mounted) {
                            if (ok) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('已成功切换模型为: ${m.name}'),
                                  backgroundColor: const Color(0xFF10B981),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('模型切换失败: ${dsh.lastError.isNotEmpty ? dsh.lastError : "请检查网络"}'),
                                  backgroundColor: const Color(0xFFEF4444),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Delete Current Session Dialog
  void _showDeleteCurrentSessionDialog(BuildContext context, DshService dsh) {
    final currentSession = dsh.currentSession;
    if (currentSession == null) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF252526),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF333333)),
        ),
        title: const Row(
          children: [
            Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 22),
            SizedBox(width: 8),
            Text('删除当前会话', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '确定要删除会话「${currentSession.title}」吗？\n删除后该会话的历史记录和上下文将不可恢复。',
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              elevation: 0,
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              final ok = await dsh.deleteSession(
                currentSession.sessionId,
                dsh.currentWorkspace?.workspaceId,
              );
              if (context.mounted) {
                if (ok) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('已删除会话: ${currentSession.title}'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('删除会话失败: ${dsh.lastError}'),
                      backgroundColor: Colors.redAccent,
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              }
            },
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
  }

  // Quick Workspace Switcher Sheet
  void _showWorkspaceSwitchSheet(BuildContext context, DshService dsh) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF252526),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Row(
                  children: [
                    Icon(Icons.folder_open_rounded, color: Color(0xFF60A5FA), size: 20),
                    SizedBox(width: 8),
                    Text(
                      '选择工作区 (Select Workspace)',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: dsh.workspaces.length,
                    itemBuilder: (context, index) {
                      final ws = dsh.workspaces[index];
                      final isSelected = ws.workspaceId == dsh.currentWorkspace?.workspaceId;
                      return ListTile(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        tileColor: isSelected ? const Color(0xFF0078D4).withOpacity(0.14) : null,
                        title: Text(
                          ws.title,
                          style: TextStyle(
                            color: isSelected ? const Color(0xFF60A5FA) : Colors.white,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          ws.path,
                          style: const TextStyle(fontSize: 11, color: Colors.white54),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          '${ws.sessionCount} 会话',
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          dsh.selectWorkspace(ws);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final currentSession = dsh.currentSession;
    final currentWs = dsh.currentWorkspace;
    final sessionId = currentSession?.sessionId ?? 'default';
    final policy = dsh.getSessionPermission(sessionId);
    final modelName = dsh.currentModel;
    final currentSessionId = currentSession?.sessionId;
    final isSessionRunning = (currentSession?.isRunning ?? false) ||
        (dsh.isSending && (currentSession?.matchesSessionId(dsh.currentSession?.sessionId) ?? false));

    // Auto-scroll logic: jump to bottom on session change or after history loaded
    if (currentSessionId != _lastSessionId) {
      _lastSessionId = currentSessionId;
      _lastMessageCount = dsh.messages.length;
      _jumpToBottom();
    } else if (_wasLoadingHistory && !dsh.isLoadingHistory) {
      _jumpToBottom();
    } else if (dsh.messages.length != _lastMessageCount) {
      final wasNearBottom = !_showScrollToBottom;
      _lastMessageCount = dsh.messages.length;
      if (wasNearBottom) {
        _scrollToBottom();
      }
    }
    _wasLoadingHistory = dsh.isLoadingHistory;

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF252526),
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFF333333), height: 1),
        ),
        titleSpacing: 12,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Workspace Selector Pill (Fluent Command Style)
                GestureDetector(
                  onTap: () => _showWorkspaceSwitchSheet(context, dsh),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0078D4).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF0078D4).withOpacity(0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.folder_rounded, size: 12, color: Color(0xFF60A5FA)),
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 110),
                          child: Text(
                            currentWs?.title ?? '选择工作区',
                            style: const TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(Icons.arrow_drop_down, size: 14, color: Colors.white.withOpacity(0.6)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),

                // Model Selector Pill (Fluent Command Style)
                GestureDetector(
                  onTap: () => _showModelSwitchSheet(context, dsh),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF744DA9).withOpacity(0.14),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF744DA9).withOpacity(0.32)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.smart_toy_outlined, size: 12, color: Color(0xFFC084FC)),
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 95),
                          child: Text(
                            modelName.replaceFirst('cn:', ''),
                            style: const TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(Icons.arrow_drop_down, size: 14, color: Colors.white.withOpacity(0.6)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    currentSession?.title ?? '新会话',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.white.withOpacity(0.85)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isSessionRunning) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0078D4).withOpacity(0.18),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFF0078D4).withOpacity(0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        SizedBox(
                          width: 8,
                          height: 8,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF60A5FA)),
                        ),
                        SizedBox(width: 4),
                        Text('执行中', style: TextStyle(color: Color(0xFF60A5FA), fontSize: 9.5, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
        actions: [
          // Session Permission Shield Button
          IconButton(
            tooltip: '设置对话权限',
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(Icons.shield_rounded, color: _getPolicyColor(policy), size: 22),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: _getPolicyColor(policy),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
            onPressed: () => _showSessionPermissionSheet(context, dsh),
          ),

          // New Session Button
          IconButton(
            tooltip: '新建对话',
            icon: const Icon(Icons.add_comment_outlined, color: Colors.white, size: 22),
            onPressed: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('正在新建对话...'),
                  duration: Duration(milliseconds: 1000),
                  behavior: SnackBarBehavior.floating,
                ),
              );
              await dsh.createNewSession();
              _scrollToBottom();
            },
          ),

          // More Options Popup Menu
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: Colors.white70),
            color: const Color(0xFF252526),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: Color(0xFF333333)),
            ),
            onSelected: (value) {
              switch (value) {
                case 'model':
                  _showModelSwitchSheet(context, dsh);
                  break;
                case 'permission':
                  _showSessionPermissionSheet(context, dsh);
                  break;
                case 'workspaces':
                  widget.onOpenWorkspaces?.call();
                  break;
                case 'clear':
                  dsh.createNewSession();
                  break;
                case 'delete':
                  _showDeleteCurrentSessionDialog(context, dsh);
                  break;
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'model',
                child: Row(
                  children: [
                    Icon(Icons.smart_toy_outlined, color: Colors.purpleAccent, size: 18),
                    SizedBox(width: 10),
                    Text('切换模型', style: TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'permission',
                child: Row(
                  children: [
                    Icon(Icons.shield_outlined, color: Colors.blueAccent, size: 18),
                    SizedBox(width: 10),
                    Text('对话权限', style: TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'workspaces',
                child: Row(
                  children: [
                    Icon(Icons.folder_outlined, color: Colors.tealAccent, size: 18),
                    SizedBox(width: 10),
                    Text('工作区与会话', style: TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 1),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 18),
                    SizedBox(width: 10),
                    Text('删除当前会话', style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Global Error Alert Bar
          if (dsh.lastError.isNotEmpty)
            Container(
              margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444).withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, color: Color(0xFFF87171), size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      dsh.lastError,
                      style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => dsh.clearError(),
                    child: const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.close_rounded, color: Colors.white70, size: 16),
                    ),
                  ),
                ],
              ),
            ),

          // Pending Tool Approvals Banner
          if (dsh.pendingApprovals.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.amber.withOpacity(0.15),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.amberAccent, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '有 ${dsh.pendingApprovals.length} 个工具操作等待授权',
                      style: const TextStyle(color: Colors.amberAccent, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onOpenSecurity,
                    child: const Text('立即审核', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ),

          // Chat Body with Floating Jump to Latest Button
          Expanded(
            child: dsh.isLoadingHistory
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      if (dsh.messages.isEmpty && dsh.pendingApprovals.isEmpty)
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0078D4).withOpacity(0.12),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.chat_bubble_outline_rounded,
                                  color: Color(0xFF0078D4),
                                  size: 28,
                                ),
                              ),
                              const SizedBox(height: 14),
                              const Text(
                                '新对话已就绪',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '在下方输入框中发送消息开始',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.45),
                                  fontSize: 12.5,
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          itemCount: dsh.messages.length + dsh.pendingApprovals.length,
                          itemBuilder: (context, index) {
                            // Inline pending approvals first
                            if (index < dsh.pendingApprovals.length) {
                              final req = dsh.pendingApprovals[index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: ApprovalCard(
                                  request: req,
                                  onRespond: (r, outcome) => dsh.respondApproval(r, outcome),
                                ),
                              );
                            }

                            final msgIndex = index - dsh.pendingApprovals.length;
                            final msg = dsh.messages[msgIndex];
                            return _buildMessageItem(msg);
                          },
                        ),
                      if (_showScrollToBottom)
                        Positioned(
                          right: 16,
                          bottom: 12,
                          child: Material(
                            elevation: 3,
                            color: const Color(0xFF0078D4),
                            borderRadius: BorderRadius.circular(8),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: _scrollToBottom,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.arrow_downward_rounded, size: 15, color: Colors.white),
                                    SizedBox(width: 4),
                                    Text(
                                      '回到最新消息',
                                      style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),

          // Quick Action Chips (Fluent Command Style)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(
              color: Color(0xFF252526),
              border: Border(top: BorderSide(color: Color(0xFF333333))),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildQuickChip(
                    icon: Icons.shield_outlined,
                    label: _getPolicyLabel(policy),
                    color: _getPolicyColor(policy),
                    onTap: () => _showSessionPermissionSheet(context, dsh),
                  ),
                  const SizedBox(width: 6),
                  _buildQuickChip(
                    icon: Icons.smart_toy_outlined,
                    label: '更换模型',
                    color: const Color(0xFFC084FC),
                    onTap: () => _showModelSwitchSheet(context, dsh),
                  ),
                  const SizedBox(width: 6),
                  _buildQuickChip(
                    icon: Icons.folder_outlined,
                    label: '项目工作区',
                    color: const Color(0xFF60A5FA),
                    onTap: widget.onOpenWorkspaces,
                  ),
                  const SizedBox(width: 6),
                  _buildQuickChip(
                    icon: Icons.cleaning_services_outlined,
                    label: '清屏新建',
                    color: const Color(0xFFFBBF24),
                    onTap: () async {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('正在新建对话...'),
                          duration: Duration(milliseconds: 1200),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                      await dsh.createNewSession();
                    },
                  ),
                  const SizedBox(width: 6),
                  _buildQuickChip(
                    icon: Icons.delete_outline_rounded,
                    label: '删除会话',
                    color: const Color(0xFFF87171),
                    onTap: () => _showDeleteCurrentSessionDialog(context, dsh),
                  ),
                ],
              ),
            ),
          ),

          // Rich Input Bar
          _buildInputBar(dsh),
        ],
      ),
    );
  }

  Widget _buildQuickChip({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.28)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageItem(ChatMessage msg) {
    // 1. Standalone context or memory snapshot message -> Collapsed MemoryCard
    if (msg.isContextOrMemory) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: MemoryCard(content: msg.content),
      );
    }

    // 2. Embedded context markers in message -> Split prompt and collapse context part
    const contextMarkers = [
      '<system-reminder>',
      '<runtime-memory-file',
      'MNEMON RUNTIME MEMORY SNAPSHOT',
      '[MNEMON]',
      'Current runtime context.',
      'Instructions from:',
      '<available_skills>',
      'Contents of ',
    ];

    int earliestMarkerIndex = -1;
    for (final marker in contextMarkers) {
      final idx = msg.content.indexOf(marker);
      if (idx != -1) {
        if (earliestMarkerIndex == -1 || idx < earliestMarkerIndex) {
          earliestMarkerIndex = idx;
        }
      }
    }

    String displayContent = msg.content;
    String? embeddedContext;
    if (earliestMarkerIndex == 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: MemoryCard(content: msg.content),
      );
    } else if (earliestMarkerIndex > 0) {
      displayContent = msg.content.substring(0, earliestMarkerIndex).trim();
      embeddedContext = msg.content.substring(earliestMarkerIndex).trim();
    }

    if (displayContent.isEmpty && (embeddedContext != null && embeddedContext.isNotEmpty)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: MemoryCard(content: embeddedContext),
      );
    }

    final isUser = msg.role == 'user';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: const Color(0xFF252526),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF0078D4).withOpacity(0.35)),
              ),
              child: const Icon(Icons.auto_awesome, color: Color(0xFF60A5FA), size: 16),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                // Thinking Fold Card
                if ((msg.thinking != null && msg.thinking!.isNotEmpty) || (msg.isStreaming && msg.content.isEmpty))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ThinkingCard(
                      content: msg.thinking ?? '',
                      isThinking: msg.isStreaming,
                    ),
                  ),

                // Tool Executions
                for (final tool in msg.tools)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ToolCallCard(tool: tool),
                  ),

                // Content Bubble
                if (displayContent.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                    decoration: BoxDecoration(
                      color: isUser ? const Color(0xFF0078D4) : const Color(0xFF252526),
                      borderRadius: isUser
                          ? const BorderRadius.only(
                              topLeft: Radius.circular(10),
                              bottomLeft: Radius.circular(10),
                              bottomRight: Radius.circular(10),
                              topRight: Radius.circular(3),
                            )
                          : const BorderRadius.only(
                              topRight: Radius.circular(10),
                              bottomLeft: Radius.circular(10),
                              bottomRight: Radius.circular(10),
                              topLeft: Radius.circular(3),
                            ),
                      border: Border.all(
                        color: isUser
                            ? const Color(0xFF60A5FA).withOpacity(0.28)
                            : const Color(0xFF333333),
                        width: 1.0,
                      ),
                    ),
                    child: MarkdownBody(
                      data: displayContent,
                      selectable: true,
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(fontSize: 14, color: Colors.white, height: 1.45),
                        code: const TextStyle(
                          color: Color(0xFF38BDF8),
                          backgroundColor: Color(0xFF1E1E1E),
                          fontFamily: 'monospace',
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: const Color(0xFF1E1E1E),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF333333)),
                        ),
                      ),
                    ),
                  ),

                // Embedded Context Card if present
                if (embeddedContext != null && embeddedContext.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: MemoryCard(content: embeddedContext),
                  ),

                // Streaming Indicator
                if (msg.isStreaming)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF60A5FA)),
                        ),
                        SizedBox(width: 6),
                        Text('AI 正在思考并执行操作...', style: TextStyle(color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  ),

                // Timestamp
                if (msg.timestamp != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _formatTime(msg.timestamp),
                      style: const TextStyle(color: Colors.white30, fontSize: 10),
                    ),
                  ),
              ],
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: const Color(0xFF0078D4).withOpacity(0.18),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF0078D4).withOpacity(0.4)),
              ),
              child: const Icon(Icons.person_outline_rounded, color: Color(0xFF60A5FA), size: 17),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInputBar(DshService dsh) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF252526),
        border: Border(top: BorderSide(color: Color(0xFF333333))),
      ),
      child: SafeArea(
        child: Row(
          children: [
            // Voice / Mic Mock Button
            IconButton(
              icon: const Icon(Icons.mic_none_rounded, color: Colors.white60, size: 22),
              tooltip: '语音输入',
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('语音听写已就绪，正在聆听...'), duration: Duration(seconds: 1)),
                );
              },
            ),
            // Text Input
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF2D2D2D),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF3B3B3B)),
                ),
                child: TextField(
                  controller: _inputController,
                  style: const TextStyle(color: Colors.white, fontSize: 13.5),
                  maxLines: 4,
                  minLines: 1,
                  decoration: const InputDecoration(
                    hintText: '发送消息...',
                    hintStyle: TextStyle(color: Colors.white38, fontSize: 13.5),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  ),
                  onSubmitted: (_) => _sendMessage(dsh),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Send / Cancel Button
            if (dsh.isSending)
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.35)),
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.stop_rounded, color: Color(0xFFEF4444), size: 22),
                  tooltip: '停止生成',
                  onPressed: () => dsh.cancelActiveTurn(),
                ),
              )
            else
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF0078D4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 20),
                  tooltip: '发送',
                  onPressed: () => _sendMessage(dsh),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
