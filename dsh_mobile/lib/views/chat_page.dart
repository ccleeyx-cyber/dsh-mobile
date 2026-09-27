import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/chat_message.dart';
import '../models/workspace.dart';
import '../services/dsh_service.dart';
import '../widgets/thinking_card.dart';
import '../widgets/tool_call_card.dart';
import '../widgets/approval_card.dart';
import 'settings_view.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String _sessionSearchFilter = '';

  @override
  void dispose() {
    _inputController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
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

  String _formatTime(int? timestamp) {
    if (timestamp == null || timestamp == 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return DateFormat('HH:mm').format(dt);
    }
    return DateFormat('MM-dd HH:mm').format(dt);
  }

  // Workspace and Session Drawer
  Widget _buildWorkspaceDrawer(DshService dsh) {
    final workspaces = dsh.workspaces;
    final currentWs = dsh.currentWorkspace;
    final currentSession = dsh.currentSession;

    // Filter sessions
    final filteredSessions = (currentWs?.sessions ?? []).filter((s) {
      if (_sessionSearchFilter.isEmpty) return true;
      final q = _sessionSearchFilter.toLowerCase();
      return s.title.toLowerCase().contains(q) || s.firstPrompt.toLowerCase().contains(q);
    }).toList();

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            // 1. Workspace Header & Selector
            Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.4),
                border: Border(bottom: BorderSide(color: Colors.grey.withOpacity(0.2))),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.folder_shared_rounded, color: Colors.blueAccent),
                      const SizedBox(width: 8),
                      const Text(
                        '工作区 (Workspace)',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                        tooltip: '刷新工作区',
                        onPressed: () => dsh.fetchWorkspaces(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Workspace Switcher Dropdown
                  if (workspaces.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey.withOpacity(0.3)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: currentWs?.workspaceId,
                          isExpanded: true,
                          icon: const Icon(Icons.arrow_drop_down_rounded),
                          items: workspaces.map((ws) {
                            return DropdownMenuItem<String>(
                              value: ws.workspaceId,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      ws.title,
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.blue.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '${ws.sessionCount} 会话',
                                      style: const TextStyle(fontSize: 11, color: Colors.blueAccent),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                          onChanged: (id) {
                            if (id != null) {
                              final target = workspaces.firstWhere((w) => w.workspaceId == id);
                              dsh.selectWorkspace(target);
                            }
                          },
                        ),
                      ),
                    ),
                  if (currentWs != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      currentWs.path,
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),

            // 2. New Session & Search Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
              child: Column(
                children: [
                  ElevatedButton.icon(
                    onPressed: () async {
                      Navigator.pop(context);
                      await dsh.createNewSession();
                    },
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('新建对话 (New Session)'),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size.fromHeight(42),
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: '搜索会话历史...',
                      hintStyle: const TextStyle(fontSize: 13),
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      suffixIcon: _sessionSearchFilter.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _sessionSearchFilter = '');
                              },
                            )
                          : null,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.grey.withOpacity(0.3)),
                      ),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _sessionSearchFilter = v.trim()),
                  ),
                ],
              ),
            ),

            // 3. Sessions List
            Expanded(
              child: filteredSessions.isEmpty
                  ? Center(
                      child: Text(
                        currentWs == null
                            ? '暂无工作区'
                            : (currentWs.sessions.isEmpty ? '暂无历史对话' : '未找到匹配会话'),
                        style: const TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filteredSessions.length,
                      itemBuilder: (ctx, idx) {
                        final session = filteredSessions[idx];
                        final isSelected = session.sessionId == currentSession?.sessionId;

                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.blueAccent.withOpacity(0.15)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: isSelected
                                ? Border.all(color: Colors.blueAccent.withOpacity(0.5))
                                : null,
                          ),
                          child: ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                            leading: Icon(
                              Icons.chat_bubble_outline_rounded,
                              size: 18,
                              color: isSelected ? Colors.blueAccent : Colors.grey,
                            ),
                            title: Text(
                              session.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                color: isSelected ? Colors.blueAccent : null,
                                fontSize: 13,
                              ),
                            ),
                            subtitle: session.firstPrompt.isNotEmpty
                                ? Text(
                                    session.firstPrompt,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade400,
                                    ),
                                  )
                                : null,
                            trailing: Text(
                              _formatTime(session.lastPromptAt),
                              style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              if (!isSelected) {
                                dsh.selectSession(session);
                              }
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final currentWs = dsh.currentWorkspace;
    final currentSession = dsh.currentSession;
    final modelName = dsh.settings?.currentModel ?? 'DeepSeek';

    return Scaffold(
      drawer: _buildWorkspaceDrawer(dsh),
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu_rounded),
            tooltip: '工作区与会话',
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  currentWs != null ? '${currentWs.title} / ' : '',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
                Expanded(
                  child: Text(
                    currentSession?.title ?? 'DSH 对话',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    modelName,
                    style: const TextStyle(fontSize: 10, color: Colors.blueAccent),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: dsh.isConnected ? Colors.green : Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          // Pending Approvals Badge Button
          if (dsh.pendingApprovals.isNotEmpty)
            Stack(
              alignment: Alignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.security_rounded, color: Colors.amber),
                  tooltip: '有 ${dsh.pendingApprovals.length} 项授权等待处理',
                  onPressed: () {
                    // Scroll to top where approval cards are shown
                    _scrollController.animateTo(
                      0,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                    );
                  },
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${dsh.pendingApprovals.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),

          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '模型与配置',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsView()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. Pending Approvals Sticky Area
          if (dsh.pendingApprovals.isNotEmpty)
            Container(
              color: Colors.black12,
              child: Column(
                children: dsh.pendingApprovals.map((req) {
                  return ApprovalCard(
                    request: req,
                    onRespond: (r, outcome) => dsh.respondApproval(r, outcome),
                  );
                }).toList(),
              ),
            ),

          // 2. Chat Messages Area
          Expanded(
            child: dsh.isLoadingHistory
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('正在加载对话记录...', style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 12.0),
                    itemCount: dsh.messages.length,
                    itemBuilder: (ctx, index) {
                      final msg = dsh.messages[index];
                      return _buildMessageBubble(msg);
                    },
                  ),
          ),

          // 3. Input Bar
          _buildInputBar(dsh),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    final theme = Theme.of(context);
    final isUser = msg.isUser;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Role header & avatar
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: isUser ? Colors.blueAccent : Colors.teal,
                child: Icon(
                  isUser ? Icons.person : Icons.smart_toy_rounded,
                  size: 14,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isUser ? '我' : 'DSH Agent',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade400,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Thinking Card (if assistant reasoned)
          if (!isUser && msg.thinking != null && msg.thinking!.isNotEmpty)
            ThinkingCard(
              content: msg.thinking!,
              isThinking: msg.isStreaming && msg.content.isEmpty,
            ),

          // Tool calls
          if (!isUser && msg.tools.isNotEmpty)
            Column(
              children: msg.tools.map((t) => ToolCallCard(tool: t)).toList(),
            ),

          // Message Content Body
          if (msg.content.isNotEmpty)
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.88,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
              decoration: BoxDecoration(
                color: isUser
                    ? Colors.blueAccent.withOpacity(0.9)
                    : theme.cardColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.06),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  )
                ],
              ),
              child: isUser
                  ? Text(
                      msg.content,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                    )
                  : MarkdownBody(
                      data: msg.content,
                      selectable: true,
                      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                        p: theme.textTheme.bodyMedium?.copyWith(fontSize: 15, height: 1.45),
                        code: const TextStyle(
                          fontFamily: 'monospace',
                          backgroundColor: Colors.black26,
                          fontSize: 13,
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: Colors.black38,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
            ),

          // Streaming progress indicator
          if (msg.isStreaming && !isUser && msg.content.isEmpty && (msg.thinking == null || msg.thinking!.isEmpty))
            Padding(
              padding: const EdgeInsets.only(top: 6.0),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '智能体正在思考并组织响应...',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInputBar(DshService dsh) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 8.0),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: Colors.grey.withOpacity(0.2))),
      ),
      child: SafeArea(
        child: Row(
          children: [
            // Stop / Cancel active turn button if generating
            if (dsh.isSending || (dsh.messages.isNotEmpty && dsh.messages.last.isStreaming))
              IconButton(
                icon: const Icon(Icons.stop_circle_outlined, color: Colors.redAccent),
                tooltip: '停止当前生成',
                onPressed: () => dsh.cancelActiveTurn(),
              ),

            // Input field
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Colors.grey.withOpacity(0.25)),
                ),
                child: TextField(
                  controller: _inputController,
                  maxLines: 4,
                  minLines: 1,
                  decoration: const InputDecoration(
                    hintText: '向 DSH 智能体下达指令...',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                  onSubmitted: (_) => _sendMessage(dsh),
                ),
              ),
            ),
            const SizedBox(width: 6),

            // Send button
            IconButton.filled(
              onPressed: () => _sendMessage(dsh),
              icon: const Icon(Icons.send_rounded, size: 18),
              style: IconButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension FilterExt<T> on Iterable<T> {
  Iterable<T> filter(bool Function(T) test) sync* {
    for (var element in this) {
      if (test(element)) yield element;
    }
  }
}
