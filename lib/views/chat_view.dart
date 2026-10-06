import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/chat_message.dart';
import '../models/workspace.dart';
import '../models/permission_config.dart';
import '../models/dsh_settings.dart';
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
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  String? _lastSessionId;
  bool _showScrollToBottom = false;
  int _lastMessageCount = 0;
  bool _wasLoadingHistory = false;

  // Keyboard & viewport avoidance state
  double _lastBottomInset = 0.0;
  bool _wasNearBottomBeforeKeyboard = true;

  // User interaction & streaming auto-scroll state
  bool _userScrolledUp = false;
  bool _isUserInteracting = false;
  bool _isAutoScrollScheduled = false;
  int _lastStreamRevision = 0;
  int _lastStreamContentLength = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _inputFocusNode.addListener(_onInputFocusChange);
  }

  @override
  void dispose() {
    _inputFocusNode.removeListener(_onInputFocusChange);
    _scrollController.removeListener(_onScroll);
    _inputFocusNode.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onInputFocusChange() {
    if (_inputFocusNode.hasFocus && !_userScrolledUp) {
      _scrollToBottom();
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentOffset = _scrollController.offset;
    final distFromBottom = maxScroll - currentOffset;
    final show = distFromBottom > 160;
    if (show != _showScrollToBottom) {
      setState(() {
        _showScrollToBottom = show;
      });
    }
    if (distFromBottom < 40 && _userScrolledUp) {
      _userScrolledUp = false;
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null) {
        _isUserInteracting = true;
      }
    } else if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails != null) {
        _isUserInteracting = true;
        final maxScroll = notification.metrics.maxScrollExtent;
        final currentOffset = notification.metrics.pixels;
        final distFromBottom = maxScroll - currentOffset;
        if (distFromBottom > 120) {
          _userScrolledUp = true;
        } else if (distFromBottom < 40) {
          _userScrolledUp = false;
        }
      }
    } else if (notification is ScrollEndNotification) {
      _isUserInteracting = false;
      final maxScroll = notification.metrics.maxScrollExtent;
      final currentOffset = notification.metrics.pixels;
      if (maxScroll - currentOffset < 40) {
        _userScrolledUp = false;
      }
    } else if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.idle) {
        _isUserInteracting = false;
      } else {
        _isUserInteracting = true;
      }
    }
    return false;
  }

  void _jumpToBottom() {
    _userScrolledUp = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _scrollToBottom({Duration duration = const Duration(milliseconds: 300), Curve curve = Curves.easeOutCubic}) {
    _userScrolledUp = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: duration,
          curve: curve,
        );
      }
    });
  }

  void _scheduleAutoScroll() {
    if (_isAutoScrollScheduled) return;
    _isAutoScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isAutoScrollScheduled = false;
      if (!mounted) return;
      if (_userScrolledUp || _isUserInteracting) return;
      if (!_scrollController.hasClients) return;

      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentOffset = _scrollController.offset;
      final diff = maxScroll - currentOffset;

      if (diff > 0) {
        if (diff > 250) {
          _scrollController.animateTo(
            maxScroll,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
          );
        } else {
          _scrollController.jumpTo(maxScroll);
        }
      }
    });
  }

  void _sendMessage(DshService dsh) {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    HapticFeedback.lightImpact();
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
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
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
                          color: const Color(0xFFD1D5DB),
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
                            color: const Color(0xFF0078D4).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFF0078D4).withOpacity(0.2)),
                          ),
                          child: const Icon(Icons.shield_outlined, color: Color(0xFF0078D4), size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '对话权限与执行策略',
                                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
                              ),
                              Text(
                                '当前对话: ${currentSession?.title ?? sessionId}',
                                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
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
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
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
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
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
                            color: const Color(0xFFF3F4F6),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFFE5E7EB)),
                          ),
                          child: Text('$maxSteps 步', style: const TextStyle(color: Color(0xFF1F2937), fontSize: 13, fontWeight: FontWeight.w600)),
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
          color: isSelected ? const Color(0xFF0078D4).withOpacity(0.08) : Colors.white,
          border: Border.all(
            color: isSelected ? const Color(0xFF0078D4) : const Color(0xFFE5E7EB),
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
                      color: isSelected ? const Color(0xFF0078D4) : const Color(0xFF1F2937),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
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
        return const Color(0xFF16A34A);
      case 'auto-read':
        return const Color(0xFF0284C7);
      case 'ask':
      default:
        return const Color(0xFFD97706);
    }
  }

  // Quick Model Selector Sheet
  void _showModelSwitchSheet(BuildContext context, DshService dsh) {
    if (dsh.settings == null || dsh.settings!.availableModels.isEmpty) {
      dsh.fetchSettings();
    }
    final settings = dsh.settings;
    final currentSession = dsh.currentSession;
    final activeModel = dsh.currentModel;
    final modelList = (settings != null && settings.availableModels.isNotEmpty)
        ? settings.availableModels
        : [
            ModelItem(id: 'cn:deepseek-v4.1-flash', name: 'DeepSeek V4.1 Flash', contextWindow: 1000000, maxTokens: 16384),
            ModelItem(id: 'cn:deepseek-v4-pro', name: 'DeepSeek V4 Pro', contextWindow: 1000000, maxTokens: 32768),
            ModelItem(id: 'cn:kimi-k3-1', name: 'Kimi K3.1', contextWindow: 1000000, maxTokens: 32768),
          ];

    String filter = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
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
                      color: const Color(0xFFD1D5DB),
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
                        color: const Color(0xFF0078D4).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.smart_toy_outlined, color: Color(0xFF0078D4), size: 20),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '切换大语言模型',
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
                          ),
                          Text(
                            '选择要在此会话中使用的 AI 模型',
                            style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (currentSession != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '当前生效会话: ${currentSession.title}',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                StatefulBuilder(
                  builder: (context, setModalState) {
                    final filtered = modelList.where((m) {
                      if (filter.isEmpty) return true;
                      return m.name.toLowerCase().contains(filter) || m.id.toLowerCase().contains(filter);
                    }).toList();

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                          decoration: InputDecoration(
                            hintText: '搜索模型 (如 deepseek, glm, gpt, qwen...)',
                            hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                            prefixIcon: const Icon(Icons.search, size: 20, color: Color(0xFF6B7280)),
                            filled: true,
                            fillColor: const Color(0xFFF3F4F6),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          onChanged: (val) {
                            setModalState(() {
                              filter = val.trim().toLowerCase();
                            });
                          },
                        ),
                        const SizedBox(height: 10),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
                          child: filtered.isEmpty
                              ? const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 24),
                                  child: Center(
                                    child: Text('未找到匹配的模型', style: TextStyle(color: Color(0xFF9CA3AF))),
                                  ),
                                )
                              : ListView.separated(
                                  shrinkWrap: true,
                                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                                  itemCount: filtered.length,
                                  itemBuilder: (context, index) {
                                    final m = filtered[index];
                      final isSelected = m.id == activeModel || (m.id.replaceFirst('cn:', '') == activeModel.replaceFirst('cn:', ''));
                      return InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () async {
                          Navigator.pop(ctx);
                          HapticFeedback.selectionClick();
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
                                  content: Text('模型切换失败: ${dsh.lastError.isNotEmpty ? dsh.lastError : "请检查网络或授权码"}'),
                                  backgroundColor: const Color(0xFFEF4444),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFF0078D4).withOpacity(0.08) : Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected ? const Color(0xFF0078D4) : const Color(0xFFE5E7EB),
                              width: isSelected ? 1.5 : 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                                color: isSelected ? const Color(0xFF0078D4) : const Color(0xFF9CA3AF),
                                size: 18,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      m.name,
                                      style: TextStyle(
                                        color: isSelected ? const Color(0xFF0078D4) : const Color(0xFF1F2937),
                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${m.id} | 上下文: ${(m.contextWindow ?? 0) ~/ 1000}k',
                                      style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280)),
                                    ),
                                  ],
                                ),
                              ),
                              if (isSelected)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0078D4).withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text('使用中', style: TextStyle(color: Color(0xFF0078D4), fontSize: 11, fontWeight: FontWeight.w600)),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
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
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
        title: const Row(
          children: [
            Icon(Icons.delete_outline_rounded, color: Color(0xFFDC2626), size: 22),
            SizedBox(width: 8),
            Text('删除当前会话', style: TextStyle(color: Color(0xFF111827), fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '确定要删除会话「${currentSession.title}」吗？\n删除后该会话的历史记录和上下文将不可恢复。',
          style: const TextStyle(color: Color(0xFF4B5563), fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Color(0xFF6B7280))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
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
                ScaffoldMessenger.of(context).clearSnackBars();
                if (ok) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('已删除会话: ${currentSession.title}'),
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('删除会话失败: ${dsh.lastError}'),
                      backgroundColor: const Color(0xFFDC2626),
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 3),
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
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
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
                      color: const Color(0xFFD1D5DB),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Row(
                  children: [
                    Icon(Icons.folder_open_rounded, color: Color(0xFF0078D4), size: 20),
                    SizedBox(width: 8),
                    Text(
                      '选择工作区 (Select Workspace)',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
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
                        tileColor: isSelected ? const Color(0xFF0078D4).withOpacity(0.08) : null,
                        title: Text(
                          ws.title,
                          style: TextStyle(
                            color: isSelected ? const Color(0xFF0078D4) : const Color(0xFF1F2937),
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          ws.path,
                          style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          '${ws.sessionCount} 会话',
                          style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
                        ),
                        onTap: () {
                          HapticFeedback.selectionClick();
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

    // Keyboard height transitions
    final currentBottomInset = MediaQuery.of(context).viewInsets.bottom;
    if (currentBottomInset != _lastBottomInset) {
      final isKeyboardOpening = currentBottomInset > _lastBottomInset;
      if (isKeyboardOpening && _lastBottomInset == 0) {
        _wasNearBottomBeforeKeyboard = !_userScrolledUp;
      }
      if (isKeyboardOpening && _wasNearBottomBeforeKeyboard && !_userScrolledUp) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients && !_userScrolledUp && !_isUserInteracting) {
            _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          }
        });
      }
      _lastBottomInset = currentBottomInset;
    }

    // Stream content growth detection (fallback alongside streamRevision)
    final lastMsg = dsh.messages.isNotEmpty ? dsh.messages.last : null;
    final isStreaming = lastMsg != null && lastMsg.isStreaming;
    final currentContentLen = (lastMsg?.content.length ?? 0) + (lastMsg?.thinking?.length ?? 0);
    final hasStreamContentGrowth = isStreaming && currentContentLen != _lastStreamContentLength;
    _lastStreamContentLength = currentContentLen;

    if (currentSessionId != _lastSessionId) {
      _lastSessionId = currentSessionId;
      _lastMessageCount = dsh.messages.length;
      _lastStreamRevision = dsh.streamRevision;
      _userScrolledUp = false;
      _jumpToBottom();
    } else if (_wasLoadingHistory && !dsh.isLoadingHistory) {
      _lastStreamRevision = dsh.streamRevision;
      _userScrolledUp = false;
      _jumpToBottom();
    } else if (dsh.messages.length != _lastMessageCount) {
      final wasNearBottom = !_userScrolledUp;
      _lastMessageCount = dsh.messages.length;
      _lastStreamRevision = dsh.streamRevision;
      if (wasNearBottom) {
        _scrollToBottom();
      }
    } else if (dsh.streamRevision != _lastStreamRevision || hasStreamContentGrowth) {
      _lastStreamRevision = dsh.streamRevision;
      if (!_userScrolledUp && !_isUserInteracting) {
        _scheduleAutoScroll();
      }
    }
    _wasLoadingHistory = dsh.isLoadingHistory;

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFFE5E7EB), height: 1),
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
                      color: const Color(0xFF0078D4).withOpacity(0.08),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF0078D4).withOpacity(0.25)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.folder_rounded, size: 12, color: Color(0xFF0078D4)),
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 110),
                          child: Text(
                            currentWs?.title ?? '选择工作区',
                            style: const TextStyle(fontSize: 11.5, color: Color(0xFF1F2937), fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(Icons.arrow_drop_down, size: 14, color: Color(0xFF6B7280)),
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
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFD1D5DB)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.smart_toy_outlined, size: 12, color: Color(0xFF4B5563)),
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 95),
                          child: Text(
                            modelName.replaceFirst('cn:', ''),
                            style: const TextStyle(fontSize: 11.5, color: Color(0xFF1F2937), fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(Icons.arrow_drop_down, size: 14, color: Color(0xFF6B7280)),
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
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF4B5563)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isSessionRunning) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0078D4).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFF0078D4).withOpacity(0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        SizedBox(
                          width: 8,
                          height: 8,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF0078D4)),
                        ),
                        SizedBox(width: 4),
                        Text('执行中', style: TextStyle(color: Color(0xFF0078D4), fontSize: 9.5, fontWeight: FontWeight.bold)),
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
            icon: const Icon(Icons.add_comment_outlined, color: Color(0xFF374151), size: 22),
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
            icon: const Icon(Icons.more_vert_rounded, color: Color(0xFF4B5563)),
            color: Colors.white,
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: Color(0xFFE5E7EB)),
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
                    Icon(Icons.smart_toy_outlined, color: Color(0xFF0078D4), size: 18),
                    SizedBox(width: 10),
                    Text('切换模型', style: TextStyle(color: Color(0xFF1F2937), fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'permission',
                child: Row(
                  children: [
                    Icon(Icons.shield_outlined, color: Color(0xFF0078D4), size: 18),
                    SizedBox(width: 10),
                    Text('对话权限', style: TextStyle(color: Color(0xFF1F2937), fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'workspaces',
                child: Row(
                  children: [
                    Icon(Icons.folder_outlined, color: Color(0xFF0078D4), size: 18),
                    SizedBox(width: 10),
                    Text('工作区与会话', style: TextStyle(color: Color(0xFF1F2937), fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 1),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline_rounded, color: Color(0xFFDC2626), size: 18),
                    SizedBox(width: 10),
                    Text('删除当前会话', style: TextStyle(color: Color(0xFFDC2626), fontSize: 13)),
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
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFCA5A5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, color: Color(0xFFDC2626), size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      dsh.lastError,
                      style: const TextStyle(color: Color(0xFF991B1B), fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => dsh.clearError(),
                    child: const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.close_rounded, color: Color(0xFF6B7280), size: 16),
                    ),
                  ),
                ],
              ),
            ),

          // Pending Tool Approvals Banner
          if (dsh.pendingApprovals.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFFFEF3C7),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '有 ${dsh.pendingApprovals.length} 个工具操作等待授权',
                      style: const TextStyle(color: Color(0xFF92400E), fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onOpenSecurity,
                    child: const Text('立即审核', style: TextStyle(color: Color(0xFFB45309), fontWeight: FontWeight.w600)),
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
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 64,
                                  height: 64,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFEFF6FC),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: const Color(0xFFCCE4F7)),
                                  ),
                                  child: const Icon(
                                    Icons.auto_awesome,
                                    color: Color(0xFF0078D4),
                                    size: 30,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  '今天想探索什么？',
                                  style: TextStyle(
                                    color: Color(0xFF111827),
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '当前工作区: ${currentWs?.title ?? "默认工作区"}',
                                  style: const TextStyle(
                                    color: Color(0xFF6B7280),
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 24),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  alignment: WrapAlignment.center,
                                  children: [
                                    _buildSuggestionChip('🛠️ 分析项目代码', () {
                                      _inputController.text = '分析当前项目代码结构并概述核心功能';
                                    }),
                                    _buildSuggestionChip('⚡ 检查潜在问题', () {
                                      _inputController.text = '检查当前项目中的潜在 Bug 或异常';
                                    }),
                                    _buildSuggestionChip('💡 生成测试建议', () {
                                      _inputController.text = '为当前模块编写单元测试用例建议';
                                    }),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        NotificationListener<ScrollNotification>(
                          onNotification: _onScrollNotification,
                          child: ListView.builder(
                            controller: _scrollController,
                            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                                    onRespond: (r, outcome, [reason]) => dsh.respondApproval(r, outcome, reason: reason),
                                  ),
                                );
                              }

                              final msgIndex = index - dsh.pendingApprovals.length;
                              final msg = dsh.messages[msgIndex];
                              return _buildMessageItem(msg);
                            },
                          ),
                        ),

                      if (_showScrollToBottom)
                        Positioned(
                          right: 16,
                          bottom: 12,
                          child: Material(
                            elevation: 2,
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

          // Modern Clean Input Bar
          _buildInputBar(dsh),
        ],
      ),
    );
  }

  Widget _buildSuggestionChip(String text, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE5E7EB)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Text(
          text,
          style: const TextStyle(color: Color(0xFF374151), fontSize: 12.5, fontWeight: FontWeight.w500),
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
                color: const Color(0xFFEFF6FC),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFCCE4F7)),
              ),
              child: const Icon(Icons.auto_awesome, color: Color(0xFF0078D4), size: 16),
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
                      color: isUser ? const Color(0xFF0078D4) : Colors.white,
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
                            ? const Color(0xFF0078D4)
                            : const Color(0xFFE5E7EB),
                        width: 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.02),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: MarkdownBody(
                      data: displayContent,
                      selectable: true,
                      styleSheet: MarkdownStyleSheet(
                        p: TextStyle(fontSize: 14, color: isUser ? Colors.white : const Color(0xFF1F2937), height: 1.45),
                        code: TextStyle(
                          color: isUser ? Colors.white : const Color(0xFF0369A1),
                          backgroundColor: isUser ? const Color(0x33FFFFFF) : const Color(0xFFF1F5F9),
                          fontFamily: 'monospace',
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: isUser ? const Color(0x1A000000) : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: isUser ? const Color(0x33FFFFFF) : const Color(0xFFE2E8F0)),
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
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0078D4)),
                        ),
                        SizedBox(width: 6),
                        Text('AI 正在思考并执行操作...', style: TextStyle(color: Color(0xFF6B7280), fontSize: 11)),
                      ],
                    ),
                  ),

                // Timestamp
                if (msg.timestamp != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _formatTime(msg.timestamp),
                      style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 10),
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
                color: const Color(0xFF0078D4),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.person_rounded, color: Colors.white, size: 17),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInputBar(DshService dsh) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Text Input Pill
            Expanded(
              child: Container(
                constraints: const BoxConstraints(minHeight: 44, maxHeight: 120),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF9FAFB),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                child: Center(
                  child: TextField(
                    controller: _inputController,
                    focusNode: _inputFocusNode,
                    style: const TextStyle(color: Color(0xFF111827), fontSize: 14),
                    maxLines: 4,
                    minLines: 1,
                    decoration: const InputDecoration(
                      hintText: '发送指令或提问...',
                      hintStyle: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13.5),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 11),
                    ),
                    onSubmitted: (_) => _sendMessage(dsh),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Send / Cancel Action Button
            if (dsh.isSending || dsh.isCanceling)
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: dsh.isCanceling ? const Color(0xFFF3F4F6) : const Color(0xFFFEE2E2),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: dsh.isCanceling ? const Color(0xFFD1D5DB) : const Color(0xFFFCA5A5),
                  ),
                ),
                child: dsh.isCanceling
                    ? const Padding(
                        padding: EdgeInsets.all(12.0),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFFDC2626),
                        ),
                      )
                    : IconButton(
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.stop_rounded, color: Color(0xFFDC2626), size: 24),
                        tooltip: '停止生成',
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          dsh.cancelActiveTurn();
                        },
                      ),
              )
            else

              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF0078D4), Color(0xFF0086F8)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x330078D4),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 22),
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
