import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import '../services/dsh_service.dart';
import '../widgets/thinking_card.dart';
import '../widgets/tool_call_card.dart';
import 'config_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  StreamSubscription? _msgSub;
  final _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    final dsh = Provider.of<DshService>(context, listen: false);
    _msgSub = dsh.messageStream.listen(_handleIncomingPayload);

    // 默认添加欢迎消息
    _messages.add(ChatMessage(
      id: _uuid.v4(),
      role: 'assistant',
      content: '你好！我是运行在宿主机上的 DeepSeek Harness (DSH) 智能体助手。你可以直接向我下达指令，或让我执行终端任务。',
    ));
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // 解析 DSH 服务端返回的数据流
  void _handleIncomingPayload(Map<String, dynamic> data) {
    setState(() {
      // 1. 如果没有当前未完成的助手消息，新建一条
      if (_messages.isEmpty || !_messages.last.isAssistant || !_messages.last.isStreaming) {
        _messages.add(ChatMessage(
          id: _uuid.v4(),
          role: 'assistant',
          content: '',
          isStreaming: true,
        ));
      }

      final current = _messages.last;

      // 适配不同的 DSH / Cordis 事件结构
      final type = data['type'] ?? data['event'];
      
      // 思考过程 (Thinking)
      if (type == 'thinking' || data.containsKey('thinking')) {
        final text = data['delta'] ?? data['thinking'] ?? '';
        current.thinking = (current.thinking ?? '') + text.toString();
      }
      // 正文流式 Token
      else if (type == 'token' || type == 'delta' || data.containsKey('delta')) {
        final text = data['delta'] ?? data['content'] ?? data['text'] ?? '';
        current.content += text.toString();
      }
      // 工具调用开始
      else if (type == 'tool_start' || type == 'tool_call') {
        final toolName = data['tool'] ?? data['name'] ?? 'tool';
        final toolInput = data['input'] ?? data['args']?.toString() ?? '';
        current.tools.add(ToolExecution(
          name: toolName,
          input: toolInput,
        ));
      }
      // 工具调用输出结果
      else if (type == 'tool_result' || type == 'tool_end') {
        if (current.tools.isNotEmpty) {
          final lastTool = current.tools.last;
          lastTool.isRunning = false;
          lastTool.output = data['output']?.toString() ?? data['result']?.toString() ?? '完成';
        }
      }
      // 单次生成结束
      else if (type == 'done' || type == 'end') {
        current.isStreaming = false;
        for (var t in current.tools) {
          t.isRunning = false;
        }
      }
      // 兜底直接带 content 的对象
      else if (data.containsKey('content') && data['content'] is String) {
        current.content += data['content'];
      }
    });

    _scrollToBottom();
  }

  void _sendMessage([String? presetText]) {
    final text = (presetText ?? _inputController.text).trim();
    if (text.isEmpty) return;

    final dsh = Provider.of<DshService>(context, listen: false);
    if (!dsh.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠️ 尚未连接到 DSH 服务器，请先检查连接状态')),
      );
      return;
    }

    setState(() {
      _messages.add(ChatMessage(
        id: _uuid.v4(),
        role: 'user',
        content: text,
      ));
      if (presetText == null) {
        _inputController.clear();
      }
    });

    _scrollToBottom();
    dsh.sendPrompt(text);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('DSH Mobile', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: dsh.status == ConnectionStatus.connected
                      ? Colors.green
                      : (dsh.status == ConnectionStatus.connecting ? Colors.orange : Colors.red),
                ),
                const SizedBox(width: 5),
                Text(
                  dsh.status == ConnectionStatus.connected
                      ? '已连接宿主机'
                      : (dsh.status == ConnectionStatus.connecting ? '正在连接...' : '连接已断开'),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            )
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空聊天',
            onPressed: () => setState(() => _messages.clear()),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '服务器配置',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ConfigPage()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 快捷指令横幅
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              children: [
                _buildQuickActionChip('查看服务器负载', '请检查并输出当前宿主机的 CPU、内存占用以及系统负载状态。'),
                _buildQuickActionChip('查看当前运行容器', '运行 docker ps 检查当前宿主机运行的容器。'),
                _buildQuickActionChip('列出工作目录', '请列出当前工作目录下的文件结构。'),
              ],
            ),
          ),
          const Divider(height: 1),
          // 消息列表
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(14),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return _buildMessageRow(msg, isDark);
              },
            ),
          ),
          // 底部输入栏
          _buildInputBar(dsh),
        ],
      ),
    );
  }

  Widget _buildQuickActionChip(String label, String prompt) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        avatar: const Icon(Icons.bolt, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        onPressed: () => _sendMessage(prompt),
      ),
    );
  }

  Widget _buildMessageRow(ChatMessage msg, bool isDark) {
    if (msg.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.blueAccent,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(4),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(16),
            ),
          ),
          child: SelectableText(
            msg.content,
            style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
          ),
        ),
      );
    }

    // 助手角色消息
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16, right: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 思考过程卡片
            if (msg.thinking != null && msg.thinking!.isNotEmpty)
              ThinkingCard(
                content: msg.thinking!,
                isThinking: msg.isStreaming && msg.content.isEmpty,
              ),

            // 工具调用卡片
            if (msg.tools.isNotEmpty)
              for (var tool in msg.tools) ToolCallCard(tool: tool),

            // 正文 Markdown 渲染
            if (msg.content.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E222A) : Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    )
                  ],
                ),
                child: MarkdownBody(
                  data: msg.content,
                  selectable: true,
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                    p: const TextStyle(fontSize: 15, height: 1.5),
                    code: TextStyle(
                      fontFamily: 'monospace',
                      backgroundColor: isDark ? Colors.black38 : const Color(0xFFF1F5F9),
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: isDark ? Colors.black54 : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
                    ),
                  ),
                ),
              )
            else if (msg.isStreaming && msg.thinking == null && msg.tools.isEmpty)
              const Padding(
                padding: EdgeInsets.all(8.0),
                child: Row(
                  children: [
                    SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 8),
                    Text('DSH 正在准备回复...', style: TextStyle(fontSize: 13, color: Colors.grey)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar(DshService dsh) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          border: const Border(top: BorderSide(color: Colors.black12, width: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _inputController,
                minLines: 1,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: '向宿主机 DSH 发送指令...',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              icon: const Icon(Icons.arrow_upward),
              onPressed: () => _sendMessage(),
            ),
          ],
        ),
      ),
    );
  }
}
