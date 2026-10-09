import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/chat_message.dart';
import '../models/dsh_settings.dart';
import '../services/dsh_service.dart';
import '../widgets/thinking_card.dart';
import '../widgets/tool_call_card.dart';
import '../widgets/approval_card.dart';
import '../widgets/memory_card.dart';
import '../widgets/safe_markdown.dart';
import 'widgets/question_card.dart';
import 'widgets/attachment_tile.dart';
import 'widgets/message_search.dart';
import 'widgets/message_search_panel.dart';
import 'config_page.dart';
import '../theme/app_colors.dart';
import '../main.dart';

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

  // ---- 会话内查找 (v1.4.2) ----
  final TextEditingController _searchController = TextEditingController();
  final Map<String, GlobalKey> _messageKeys = {};
  bool _searchOpen = false;
  String _searchQuery = '';

  /// 当前被高亮的命中消息 id。高亮只保留一条 —— 一次跳到第一条就够用户确认
  /// "查找能用了"，剩下的自己点；全部高亮反而让页面变成一片黄。
  final Set<String> _highlightedMessageIds = {};

  // ---- 离线草稿 (v1.4.2) ----

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        // 只清文本，不 dispose：controller 在 State 生命周期内复用，关闭再打开
        // 是常态，dispose 后再用会抛。
        _searchController.clear();
        _searchQuery = '';
        _highlightedMessageIds.clear();
      }
    });
    if (!_searchOpen) {
      _inputFocusNode.requestFocus();
    }
  }

  void _onSearchChanged(String q) {
    setState(() {
      _searchQuery = q;
      _highlightedMessageIds.clear();
    });
  }

  /// 跳到命中的消息并短暂高亮。
  void _jumpToHit(SearchHit hit, DshService dsh) {
    final msg = hit.messageIndex < dsh.messages.length ? dsh.messages[hit.messageIndex] : null;
    if (msg == null) return;
    setState(() {
      _highlightedMessageIds
        ..clear()
        ..add(msg.id);
    });
    final key = _messageKeys[msg.id];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.28,
      );
    }
    // 高亮会淡出，所以不必永久留在 _highlightedMessageIds 里。
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightedMessageIds.remove(msg.id));
    });
  }

  GlobalKey _keyForMessage(String id) => _messageKeys.putIfAbsent(id, () => GlobalKey());

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
    _searchController.dispose();
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

    // Graceful offline degradation guard (F3.4)
    if (!dsh.isConnected) {
      HapticFeedback.heavyImpact();
      ScaffoldMessenger.of(context).removeCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('网络已断开，请先重试连接'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: '点击重试',
            textColor: const Color(0xFF60A5FA),
            onPressed: () => dsh.retryConnection(),
          ),
        ),
      );
      return;
    }

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
    // NOTE: `dsh.permissions.sandboxMode` used to be read into a local here and
    // then never rendered — the session sheet only ever let the user pick an
    // execution policy. Surfacing sandboxMode/maxSteps in this sheet is a real
    // UI gap (tracked in ANALYSIS-优化与新增功能.md §1.13), not something to
    // silently reintroduce as another dead local.
    int maxSteps = dsh.permissions.maxSteps;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
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
                          color: context.c.border,
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
                            color: context.c.accent.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: context.c.accent.withOpacity(0.2)),
                          ),
                          child: Icon(Icons.shield_outlined, color: context.c.accent, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '对话权限与执行策略',
                                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                              ),
                              Text(
                                '当前对话: ${currentSession?.title ?? sessionId}',
                                style: TextStyle(fontSize: 12, color: context.c.textSecondary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '终端命令执行策略 (Execution Policy)',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.textPrimary),
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
                    Text(
                      '单轮迭代步数上限 (Max Steps)',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: maxSteps.toDouble(),
                            min: 10,
                            max: 60,
                            divisions: 10,
                            activeColor: context.c.accent,
                            label: '$maxSteps 步',
                            onChanged: (v) {
                              setModalState(() => maxSteps = v.round());
                            },
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: context.c.surfaceMuted,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: context.c.border),
                          ),
                          child: Text('$maxSteps 步', style: TextStyle(color: context.c.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: context.c.accent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          elevation: 0,
                        ),
                        onPressed: () async {
                          final currentSessions = Map<String, String>.from(dsh.permissions.sessionPolicies);
                          currentSessions[sessionId] = selectedPolicy;
                          final updatedPerms = dsh.permissions.copyWith(
                            sessionPolicies: currentSessions,
                            maxSteps: maxSteps,
                          );
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
                          await dsh.updatePermissions(updatedPerms);
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
          color: isSelected ? context.c.accent.withOpacity(0.08) : context.c.surface,
          border: Border.all(
            color: isSelected ? context.c.accent : context.c.border,
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
              activeColor: context.c.accent,
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
                      color: isSelected ? context.c.accent : context.c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: context.c.textSecondary),
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
        return context.c.success;
      case 'auto-read':
        return context.c.accent;
      case 'ask':
      default:
        return context.c.warning;
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
      backgroundColor: context.c.surface,
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
                      color: context.c.border,
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
                        color: context.c.accent.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.smart_toy_outlined, color: context.c.accent, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '切换大语言模型',
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                          ),
                          Text(
                            '选择要在此会话中使用的 AI 模型',
                            style: TextStyle(fontSize: 12, color: context.c.textSecondary),
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
                        color: context.c.surfaceMuted,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '当前生效会话: ${currentSession.title}',
                        style: TextStyle(fontSize: 12, color: context.c.textPrimary),
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
                            hintStyle: TextStyle(fontSize: 13, color: context.c.textTertiary),
                            prefixIcon: Icon(Icons.search, size: 20, color: context.c.textSecondary),
                            filled: true,
                            fillColor: context.c.surfaceMuted,
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
                              ? Padding(
                                  padding: EdgeInsets.symmetric(vertical: 24),
                                  child: Center(
                                    child: Text('未找到匹配的模型', style: TextStyle(color: context.c.textTertiary)),
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
                                  backgroundColor: context.c.success,
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('模型切换失败: ${dsh.lastError.isNotEmpty ? dsh.lastError : "请检查网络或授权码"}'),
                                  backgroundColor: context.c.danger,
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: isSelected ? context.c.accent.withOpacity(0.08) : context.c.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected ? context.c.accent : context.c.border,
                              width: isSelected ? 1.5 : 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                                color: isSelected ? context.c.accent : context.c.textTertiary,
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
                                        color: isSelected ? context.c.accent : context.c.textPrimary,
                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${m.id} | 上下文: ${(m.contextWindow ?? 0) ~/ 1000}k',
                                      style: TextStyle(fontSize: 11.5, color: context.c.textSecondary),
                                    ),
                                  ],
                                ),
                              ),
                              if (isSelected)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: context.c.accent.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text('使用中', style: TextStyle(color: context.c.accent, fontSize: 11, fontWeight: FontWeight.w600)),
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
        backgroundColor: context.c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.c.border),
        ),
        title: Row(
          children: [
            Icon(Icons.delete_outline_rounded, color: context.c.danger, size: 22),
            SizedBox(width: 8),
            Text('删除当前会话', style: TextStyle(color: context.c.textPrimary, fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '确定要删除会话「${currentSession.title}」吗？\n删除后该会话的历史记录和上下文将不可恢复。',
          style: TextStyle(color: context.c.textPrimary, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: context.c.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: context.c.danger,
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
                      backgroundColor: context.c.danger,
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
      backgroundColor: context.c.surface,
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
                      color: context.c.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(Icons.folder_open_rounded, color: context.c.accent, size: 20),
                    SizedBox(width: 8),
                    Text(
                      '选择工作区 (Select Workspace)',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.c.textPrimary),
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
                        tileColor: isSelected ? context.c.accent.withOpacity(0.08) : null,
                        title: Text(
                          ws.title,
                          style: TextStyle(
                            color: isSelected ? context.c.accent : context.c.textPrimary,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          ws.path,
                          style: TextStyle(fontSize: 11, color: context.c.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          '${ws.sessionCount} 会话',
                          style: TextStyle(color: context.c.textTertiary, fontSize: 12),
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

  /// 离线 / 正在重连状态横幅 (F3.4, F4.3)
  Widget _buildOfflineBanner(BuildContext context, DshService dsh) {
    if (dsh.isTokenInvalid) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: context.c.dangerSurface,
          border: Border(bottom: BorderSide(color: context.c.dangerBorder, width: 1.0)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: context.c.danger.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.key_off_rounded, size: 15, color: context.c.danger),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '访问令牌已失效 (HTTP 401)',
                    style: TextStyle(color: context.c.danger, fontSize: 12.5, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '服务器拒绝访问，已暂停自动重连。请前往重新配置令牌。',
                    style: TextStyle(color: context.c.danger, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: () {
                HapticFeedback.lightImpact();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ConfigPage()),
                );
              },
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: context.c.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFFCA5A5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.settings_outlined, size: 13, color: context.c.danger),
                    SizedBox(width: 4),
                    Text('前往配置', style: TextStyle(fontSize: 11.5, color: context.c.danger, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final isConnecting = dsh.status == ConnectionStatus.connecting;

    final bgColor = isConnecting ? context.c.warningSurface : context.c.dangerSurface;
    final borderColor = isConnecting ? context.c.warningBorder : context.c.dangerBorder;
    final textColor = isConnecting ? context.c.warning : context.c.danger;
    final accentColor = isConnecting ? context.c.warning : context.c.danger;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          bottom: BorderSide(color: borderColor, width: 1.0),
        ),
      ),
      child: Row(
        children: [
          // Visual Status Indicator
          Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: isConnecting
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.0,
                      color: accentColor,
                    ),
                  )
                : Icon(
                    Icons.wifi_off_rounded,
                    size: 15,
                    color: accentColor,
                  ),
          ),
          const SizedBox(width: 10),

          // Status Information
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isConnecting ? '网络已断开，正在尝试重连...' : '网络连接已断开',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!isConnecting && dsh.lastError.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      dsh.lastError,
                      style: TextStyle(
                        color: textColor.withOpacity(0.85),
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Manual Retry Button ("点击重试")
          InkWell(
            onTap: () async {
              HapticFeedback.lightImpact();
              ScaffoldMessenger.of(context).removeCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('正在尝试重新连接服务器...'),
                  duration: Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
              await dsh.retryConnection();
            },
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: isConnecting ? Colors.white.withOpacity(0.7) : Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isConnecting ? context.c.warningBorder : const Color(0xFFFCA5A5),
                  width: 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.refresh_rounded,
                    size: 13,
                    color: accentColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isConnecting ? '重连中...' : '点击重试',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: accentColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
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
    final activeApprovals = dsh.pendingApprovals.where((a) {
      if (currentSessionId == null) return false;
      final cleanCurrent = currentSessionId.replaceFirst('session-', '');
      final cleanReq = a.sessionId.replaceFirst('session-', '');
      return a.sessionId == currentSessionId || cleanReq == cleanCurrent || a.sessionId == 'default';
    }).toList();

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
      // 切会话时换草稿（v1.4.2）。先把当前输入框里的字存进它所属的会话，再读
      // 新会话的 —— 顺序反了就会把上一个会话的字写进新会话。
      dsh.updateDraft(_inputController.text);
      final restored = dsh.currentDraft;
      _inputController.text = restored;
      _inputController.selection = TextSelection.collapsed(offset: restored.length);
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
      backgroundColor: context.c.surfaceMuted,
      appBar: AppBar(
        backgroundColor: context.c.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: context.c.border, height: 1),
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
                      color: context.c.accent.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: context.c.accent.withOpacity(0.25)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_rounded, size: 12, color: context.c.accent),
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 110),
                          child: Text(
                            currentWs?.title ?? '选择工作区',
                            style: TextStyle(fontSize: 11.5, color: context.c.textPrimary, fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(Icons.arrow_drop_down, size: 14, color: context.c.textSecondary),
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
                      color: context.c.surfaceMuted,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: context.c.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.smart_toy_outlined, size: 12, color: context.c.textPrimary),
                        const SizedBox(width: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 95),
                          child: Text(
                            modelName.replaceFirst('cn:', ''),
                            style: TextStyle(fontSize: 11.5, color: context.c.textPrimary, fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(Icons.arrow_drop_down, size: 14, color: context.c.textSecondary),
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
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: context.c.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isSessionRunning) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: context.c.accent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: context.c.accent.withOpacity(0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 8,
                          height: 8,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: context.c.accent),
                        ),
                        SizedBox(width: 4),
                        Text('执行中', style: TextStyle(color: context.c.accent, fontSize: 9.5, fontWeight: FontWeight.bold)),
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
            icon: Icon(Icons.add_comment_outlined, color: context.c.textPrimary, size: 22),
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

          // 主题快速切换（v1.6.0）。与"会话内查找"并列：两个都是高频、
          // 低认知负担的图标按钮；"选一个具体主题"在设置页的分段控件里。
          IconButton(
            tooltip: '切换主题（${context.watch<ThemeController>().label}）',
            icon: Icon(
              switch (context.watch<ThemeController>().mode) {
                'dark' => Icons.dark_mode_rounded,
                'light' => Icons.light_mode_rounded,
                _ => Icons.brightness_auto_rounded,
              },
              color: context.c.textSecondary,
              size: 21,
            ),
            onPressed: () => context.read<ThemeController>().cycle(),
          ),

          // 会话内查找
          IconButton(
            tooltip: '在当前会话中查找',
            icon: Icon(
              _searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
              color: _searchOpen ? context.c.accent : context.c.textPrimary,
              size: 22,
            ),
            onPressed: _toggleSearch,
          ),

          // More Options Popup Menu
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded, color: context.c.textPrimary),
            color: context.c.surface,
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: context.c.border),
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
              PopupMenuItem(
                value: 'model',
                child: Row(
                  children: [
                    Icon(Icons.smart_toy_outlined, color: context.c.accent, size: 18),
                    SizedBox(width: 10),
                    Text('切换模型', style: TextStyle(color: context.c.textPrimary, fontSize: 13)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'permission',
                child: Row(
                  children: [
                    Icon(Icons.shield_outlined, color: context.c.accent, size: 18),
                    SizedBox(width: 10),
                    Text('对话权限', style: TextStyle(color: context.c.textPrimary, fontSize: 13)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'workspaces',
                child: Row(
                  children: [
                    Icon(Icons.folder_outlined, color: context.c.accent, size: 18),
                    SizedBox(width: 10),
                    Text('工作区与会话', style: TextStyle(color: context.c.textPrimary, fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline_rounded, color: context.c.danger, size: 18),
                    SizedBox(width: 10),
                    Text('删除当前会话', style: TextStyle(color: context.c.danger, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. Offline & Reconnecting Status Banner (F3.4)
          if (!dsh.isConnected)
            _buildOfflineBanner(context, dsh),

          // Global Error Alert Bar (Only when connected, preventing duplicate red alerts)
          if (dsh.lastError.isNotEmpty && dsh.isConnected)
            Container(
              margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: context.c.dangerSurface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFCA5A5)),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded, color: context.c.danger, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      dsh.lastError,
                      style: TextStyle(color: context.c.danger, fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => dsh.clearError(),
                    child: Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.close_rounded, color: context.c.textSecondary, size: 16),
                    ),
                  ),
                ],
              ),
            ),

          // Pending Tool Approvals Banner
          if (dsh.pendingApprovals.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [context.c.warningBadgeSurface, context.c.warningBorder],
                ),
                border: Border(
                  bottom: BorderSide(color: context.c.warning, width: 1.0),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: context.c.warning,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.priority_high_rounded, color: Colors.white, size: 14),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          activeApprovals.isNotEmpty
                              ? '当前会话有 ${activeApprovals.length} 个工具操作等待授权'
                              : '其他会话有 ${dsh.pendingApprovals.length} 个工具操作等待授权',
                          style: TextStyle(
                            color: context.c.warning,
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (activeApprovals.isNotEmpty)
                          Text(
                            '工具: ${activeApprovals.first.toolName}',
                            style: TextStyle(color: context.c.warning, fontSize: 11),
                          ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      backgroundColor: context.c.surface.withOpacity(0.8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    onPressed: activeApprovals.isNotEmpty ? _scrollToBottom : widget.onOpenSecurity,
                    icon: Icon(
                      activeApprovals.isNotEmpty ? Icons.arrow_downward_rounded : Icons.shield_rounded,
                      size: 14,
                      color: context.c.warning,
                    ),
                    label: Text(
                      activeApprovals.isNotEmpty ? '滚动查看' : '前往审核',
                      style: TextStyle(color: context.c.warning, fontWeight: FontWeight.bold, fontSize: 12),
                    ),
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
                      if (dsh.messages.isEmpty && activeApprovals.isEmpty)
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
                                    color: context.c.selectedSurface,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: const Color(0xFFCCE4F7)),
                                  ),
                                  child: Icon(
                                    Icons.auto_awesome,
                                    color: context.c.accent,
                                    size: 30,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  '今天想探索什么？',
                                  style: TextStyle(
                                    color: context.c.textPrimary,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '当前工作区: ${currentWs?.title ?? "默认工作区"}',
                                  style: TextStyle(
                                    color: context.c.textSecondary,
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
                            itemCount: dsh.messages.length + activeApprovals.length,
                            itemBuilder: (context, index) {
                              // 1. Messages first (historical and streaming assistant response)
                              if (index < dsh.messages.length) {
                                final m = dsh.messages[index];
                                // 附 GlobalKey：会话内查找要靠 ensureVisible 精确滚到
                                // 命中的那条消息。没有 key 只能按索引估算 offset，而
                                // 消息高度是可变的，估算必然滚偏。
                                final highlighted = _highlightedMessageIds.contains(m.id);
                                Widget built = _buildMessageItem(m);
                                if (highlighted) {
                                  // 高亮放在这里而不是 _buildMessageItem 内部：这样
                                  // 记忆卡、工具卡等所有分支都被同一层覆盖，不必逐个
                                  // 分支记得包一次（漏一个就是"某些消息不高亮"）。
                                  built = DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: context.c.warningBadgeSurface.withOpacity(0.5),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: context.c.warning,
                                        width: 1.2,
                                      ),
                                    ),
                                    child: built,
                                  );
                                }
                                return KeyedSubtree(
                                  key: _keyForMessage(m.id),
                                  child: built,
                                );
                              }

                              // 2. Pending approvals appended at the end of active chat stream
                              final approvalIndex = index - dsh.messages.length;
                              final req = activeApprovals[approvalIndex];
                              return Padding(
                                padding: const EdgeInsets.only(top: 8, bottom: 12),
                                child: ApprovalCard(
                                  request: req,
                                  onRespond: (r, outcome, [reason]) => dsh.respondApproval(r, outcome, reason: reason),
                                ),
                              );
                            },
                          ),
                        ),

                      if (_showScrollToBottom)
                        Positioned(
                          right: 16,
                          bottom: 12,
                          child: Material(
                            elevation: 2,
                            color: context.c.accent,
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

          // 会话内查找面板（v1.4.2）。位置在交互块之上、输入框之下：查找是会话级
          // 操作，不该被某个提问卡片挤到屏幕外。
          if (_searchOpen)
            MessageSearchPanel(
              query: _searchQuery,
              results: _searchQuery.trim().isEmpty
                  ? const []
                  : MessageSearch.collapse(MessageSearch.search(dsh.messages, _searchQuery)),
              totalHits: _searchQuery.trim().isEmpty
                  ? 0
                  : MessageSearch.search(dsh.messages, _searchQuery).length,
              onQueryChanged: _onSearchChanged,
              onClose: _toggleSearch,
              onJumpTo: (hit) => _jumpToHit(hit, dsh),
            ),

          // 提问卡片 / TODO 面板 / 图片附件（patch 0003）。
          //
          // 顺序是有意的：提问在最上面，因为它阻塞着 agent 的下一步 —— 用户
          // 必须先看到并回答它，TODO 和图片都是背景信息。附件紧贴输入框，因为
          // 它是"这轮对话里出现的图"，不是一条独立消息。
          ..._buildInteractiveBlocks(dsh),

          // Modern Clean Input Bar
          _buildInputBar(dsh),
        ],
      ),
    );
  }

  /// 提问 / TODO / 附件三块。抽出来是因为它们共享「只属于当前会话」这条约束，
  /// 放在一起比散在 build 里更容易看出这个约束。
  List<Widget> _buildInteractiveBlocks(DshService dsh) {
    final blocks = <Widget>[];
    final questions = dsh.currentSessionQuestions;

    for (final q in questions) {
      blocks.add(
        QuestionCard(
          key: ValueKey(q.eventId),
          pending: q,
          // 只有真的连着网关才允许提交：离线时 send 会静默失败，用户会对着一个
          // 按不动的按钮以为是自己没点到。
          canAnswer: dsh.isConnected,
          onSubmit: (selections, customs) => dsh.answerQuestion(
            q,
            selections: selections,
            customs: customs,
          ),
          onDismiss: () => dsh.dismissQuestion(q),
        ),
      );
    }

    final qErr = dsh.lastQuestionError;
    if (qErr != null && questions.isNotEmpty) {
      blocks.add(QuestionErrorBanner(message: qErr));
    }

    final todos = dsh.currentTodos;
    if (todos.isNotEmpty) {
      blocks.add(TodoPanel(todos: todos));
    }

    for (final att in dsh.currentAttachments) {
      blocks.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: AttachmentImageTile(ref: att, endpoint: dsh.attachmentUrl(att)),
        ),
      );
    }

    return blocks;
  }

  Widget _buildSuggestionChip(String text, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: context.c.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.c.border),
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
          style: TextStyle(color: context.c.textPrimary, fontSize: 12.5, fontWeight: FontWeight.w500),
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
                color: context.c.selectedSurface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFCCE4F7)),
              ),
              child: Icon(Icons.auto_awesome, color: context.c.accent, size: 16),
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
                      color: isUser ? context.c.accent : context.c.surface,
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
                            ? context.c.accent
                            : context.c.border,
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
                    child: SafeMarkdown(
                      data: displayContent,
                      selectable: true,
                      fallbackTextStyle: TextStyle(
                        fontSize: 14,
                        color: isUser ? Colors.white : context.c.textPrimary,
                        height: 1.45,
                      ),
                      styleSheet: MarkdownStyleSheet(
                        p: TextStyle(fontSize: 14, color: isUser ? Colors.white : context.c.textPrimary, height: 1.45),
                        code: TextStyle(
                          color: isUser ? Colors.white : const Color(0xFF0369A1),
                          backgroundColor: isUser ? const Color(0x33FFFFFF) : context.c.background,
                          fontFamily: 'monospace',
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: isUser ? const Color(0x1A000000) : context.c.background,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: isUser ? const Color(0x33FFFFFF) : context.c.border),
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
                      children: [
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2, color: context.c.accent),
                        ),
                        SizedBox(width: 6),
                        Text('AI 正在思考并执行操作...', style: TextStyle(color: context.c.textSecondary, fontSize: 11)),
                      ],
                    ),
                  ),

                // Timestamp — ChatMessage.timestamp is a non-nullable DateTime
                // (the constructor defaults it to DateTime.now()), so the old
                // `if (msg.timestamp != null)` guard was always true and the
                // timestamp always rendered. Behaviour is unchanged.
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _formatTime(msg.timestamp),
                    style: TextStyle(color: context.c.textTertiary, fontSize: 10),
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
                color: context.c.accent,
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
      decoration: BoxDecoration(
        color: context.c.surface,
        border: Border(top: BorderSide(color: context.c.border)),
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
                  color: context.c.surfaceMuted,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: context.c.border),
                ),
                child: Center(
                  child: TextField(
                    controller: _inputController,
                    focusNode: _inputFocusNode,
                    style: TextStyle(color: context.c.textPrimary, fontSize: 14),
                    maxLines: 4,
                    minLines: 1,
                    decoration: InputDecoration(
                      hintText: '发送指令或提问...',
                      hintStyle: TextStyle(color: context.c.textTertiary, fontSize: 13.5),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 11),
                    ),
                    onChanged: (v) => dsh.updateDraft(v),
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
                  color: dsh.isCanceling ? context.c.surfaceMuted : context.c.dangerSurface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: dsh.isCanceling ? context.c.border : const Color(0xFFFCA5A5),
                  ),
                ),
                child: dsh.isCanceling
                    ? Padding(
                        padding: EdgeInsets.all(12.0),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: context.c.danger,
                        ),
                      )
                    : IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(Icons.stop_rounded, color: context.c.danger, size: 24),
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
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [context.c.accent, Color(0xFF0086F8)],
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
