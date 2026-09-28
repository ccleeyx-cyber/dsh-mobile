import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/workspace.dart';
import '../services/dsh_service.dart';

class WorkspacesView extends StatefulWidget {
  final VoidCallback? onSwitchToChat;

  const WorkspacesView({super.key, this.onSwitchToChat});

  @override
  State<WorkspacesView> createState() => _WorkspacesViewState();
}

class _WorkspacesViewState extends State<WorkspacesView> {
  final TextEditingController _searchController = TextEditingController();
  String _searchFilter = '';
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Provider.of<DshService>(context, listen: false).fetchWorkspaces();
        Provider.of<DshService>(context, listen: false).fetchApprovals();
      }
    });
    // Periodically refresh workspaces for real-time running animation and approvals
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) {
        Provider.of<DshService>(context, listen: false).fetchWorkspaces();
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  bool _isSessionRunning(SessionMeta s, DshService dsh) {
    final matchesCurrent = s.matchesSessionId(dsh.currentSession?.sessionId);
    return s.isRunning || (dsh.isSending && matchesCurrent);
  }

  int _getSessionPendingCount(SessionMeta s, DshService dsh) {
    final liveCount = dsh.pendingApprovals.where((a) => s.matchesSessionId(a.sessionId)).length;
    return liveCount > 0 ? liveCount : s.pendingApprovals;
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

  // Delete Session Confirmation Dialog
  void _showDeleteSessionDialog(BuildContext context, DshService dsh, Workspace ws, SessionMeta s) {
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
            Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 22),
            SizedBox(width: 8),
            Text('删除会话', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '确定要删除会话「${s.title}」吗？\n此操作将清除该会话的本地记录，无法撤销。',
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              final ok = await dsh.deleteSession(s.sessionId, ws.workspaceId);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(ok ? '会话「${s.title}」已删除' : '删除失败: ${dsh.lastError}')),
                );
              }
            },
            child: const Text('确认删除', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // View/Edit Workspace MEMORY.md
  void _openMemoryEditor(BuildContext context, DshService dsh, Workspace ws) async {
    final messenger = ScaffoldMessenger.of(context);
    final content = await dsh.fetchWorkspaceMemory(ws.path);
    final textController = TextEditingController(text: content);

    if (!context.mounted) return;

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
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 16,
              bottom: MediaQuery.of(context).viewInsets.bottom + 20,
            ),
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
                    const Icon(Icons.description_outlined, color: Color(0xFF0078D4)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '项目记忆与指令 (MEMORY.md)',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  ws.path,
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
                Container(
                  height: 220,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF333333)),
                  ),
                  child: TextField(
                    controller: textController,
                    maxLines: null,
                    expands: true,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      hintText: '# 项目背景与上下文约定\n在这里编写项目的架构背景、禁止修改的文件或个性化智能体指示...',
                      hintStyle: TextStyle(color: Colors.white24),
                      contentPadding: EdgeInsets.all(12),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () async {
                      final ok = await dsh.saveWorkspaceMemory(ws.path, textController.text);
                      if (context.mounted) {
                        Navigator.pop(ctx);
                        messenger.showSnackBar(
                          SnackBar(content: Text(ok ? '项目记忆已保存' : '保存失败，请检查网络')),
                        );
                      }
                    },
                    child: const Text('保存项目记忆', style: TextStyle(fontWeight: FontWeight.bold)),
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
    final workspaces = dsh.workspaces;
    final currentWs = dsh.currentWorkspace;

    // Filter workspaces
    final filteredWorkspaces = workspaces.where((ws) {
      if (_searchFilter.isEmpty) return true;
      final q = _searchFilter.toLowerCase();
      final matchWs = ws.title.toLowerCase().contains(q) || ws.path.toLowerCase().contains(q);
      final matchSession = ws.sessions.any((s) => s.title.toLowerCase().contains(q));
      return matchWs || matchSession;
    }).toList();

    int totalSessions = 0;
    int totalRunning = 0;
    for (final w in workspaces) {
      totalSessions += w.sessions.length;
      totalRunning += w.sessions.where((s) => _isSessionRunning(s, dsh)).length;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF252526),
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0xFF333333), height: 1),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '工作区与项目管理',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
            ),
            Text(
              '管理各工程项目与历史会话流',
              style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.55)),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70, size: 20),
            tooltip: '刷新工作区',
            onPressed: () {
              dsh.fetchWorkspaces();
              dsh.fetchApprovals();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Fluent CommandBar Stats Row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF252526),
              border: Border(bottom: BorderSide(color: Color(0xFF333333))),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildHeaderPill(
                    icon: Icons.folder_rounded,
                    label: '${workspaces.length} 个挂载项目',
                    color: const Color(0xFF0078D4),
                  ),
                  const SizedBox(width: 8),
                  _buildHeaderPill(
                    icon: Icons.chat_bubble_outline_rounded,
                    label: '$totalSessions 个历史会话',
                    color: const Color(0xFF9333EA),
                  ),
                  if (totalRunning > 0) ...[
                    const SizedBox(width: 8),
                    _buildHeaderPill(
                      icon: Icons.bolt_rounded,
                      label: '$totalRunning 个任务执行中',
                      color: const Color(0xFF0078D4),
                      animate: true,
                    ),
                  ],
                  if (dsh.pendingApprovals.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    _buildHeaderPill(
                      icon: Icons.shield_outlined,
                      label: '${dsh.pendingApprovals.length} 项待审批',
                      color: Colors.amberAccent,
                      animate: true,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Container(
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFF2D2D2D),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF3B3B3B)),
              ),
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: '搜索工作区、路径或历史对话...',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 12.5),
                  prefixIcon: Icon(Icons.search, size: 17, color: Colors.white.withOpacity(0.4)),
                  suffixIcon: _searchFilter.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear, size: 15, color: Colors.white.withOpacity(0.4)),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchFilter = '');
                          },
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 9),
                ),
                onChanged: (val) => setState(() => _searchFilter = val.trim()),
              ),
            ),
          ),

          // Workspace List
          Expanded(
            child: filteredWorkspaces.isEmpty
                ? Center(
                    child: Text('没有找到匹配的工作区', style: TextStyle(color: Colors.white.withOpacity(0.4))),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    itemCount: filteredWorkspaces.length,
                    itemBuilder: (context, index) {
                      final ws = filteredWorkspaces[index];
                      final isCurrent = ws.workspaceId == currentWs?.workspaceId;
                      return _buildWorkspaceCard(context, dsh, ws, isCurrent);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderPill({
    required IconData icon,
    required String label,
    required Color color,
    bool animate = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (animate)
            SizedBox(
              width: 9,
              height: 9,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
            )
          else
            Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildWorkspaceCard(BuildContext context, DshService dsh, Workspace ws, bool isCurrent) {
    final runningSessionsCount = ws.sessions.where((s) => _isSessionRunning(s, dsh)).length;
    final hasRunning = runningSessionsCount > 0;
    final pendingCount = ws.sessions.fold<int>(0, (sum, s) => sum + _getSessionPendingCount(s, dsh));

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF252526),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isCurrent
              ? const Color(0xFF0078D4).withOpacity(0.6)
              : (hasRunning
                  ? const Color(0xFF0078D4).withOpacity(0.4)
                  : (pendingCount > 0
                      ? Colors.amberAccent.withOpacity(0.5)
                      : const Color(0xFF333333))),
          width: 1.0,
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: isCurrent,
          leading: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: isCurrent ? const Color(0xFF0078D4).withOpacity(0.2) : Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.folder_rounded,
              color: isCurrent ? const Color(0xFF0078D4) : Colors.white70,
              size: 18,
            ),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  ws.title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: isCurrent ? const Color(0xFF60A5FA) : Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (runningSessionsCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0078D4).withOpacity(0.18),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xFF0078D4).withOpacity(0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 8,
                        height: 8,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF60A5FA)),
                      ),
                      const SizedBox(width: 4),
                      Text('$runningSessionsCount 执行中', style: const TextStyle(color: Color(0xFF60A5FA), fontSize: 9.5, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
              if (pendingCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.amberAccent.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.amberAccent.withOpacity(0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.shield_outlined, size: 10, color: Colors.amberAccent),
                      const SizedBox(width: 3),
                      Text('$pendingCount 待审批', style: const TextStyle(color: Colors.amberAccent, fontSize: 9.5, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
              if (isCurrent && !hasRunning && pendingCount == 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0078D4).withOpacity(0.18),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xFF0078D4).withOpacity(0.4)),
                  ),
                  child: const Text('当前活跃', style: TextStyle(color: Color(0xFF60A5FA), fontSize: 9.5, fontWeight: FontWeight.bold)),
                ),
              ],
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 3),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      ws.path,
                      style: const TextStyle(fontSize: 11, color: Colors.white54, fontFamily: 'monospace'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: ws.path));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('路径已复制到剪贴板'), duration: Duration(seconds: 1)),
                      );
                    },
                    child: const Icon(Icons.copy, size: 13, color: Colors.white38),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '共 ${ws.sessions.length} 个历史对话',
                style: const TextStyle(fontSize: 10.5, color: Colors.white38),
              ),
            ],
          ),
          children: [
            // Workspace Action Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                children: [
                  if (!isCurrent)
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.blueAccent,
                          side: const BorderSide(color: Colors.blueAccent),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 16),
                        label: const Text('设为活跃', style: TextStyle(fontSize: 12)),
                        onPressed: () {
                          dsh.selectWorkspace(ws);
                        },
                      ),
                    ),
                  if (!isCurrent) const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                      ),
                      icon: const Icon(Icons.add_comment_outlined, size: 15),
                      label: const Text('新建对话', style: TextStyle(fontSize: 12)),
                      onPressed: () async {
                        dsh.selectWorkspace(ws, autoSelectSession: false);
                        await dsh.createNewSession();
                        widget.onSwitchToChat?.call();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '查看/编辑项目说明 (MEMORY.md)',
                    icon: const Icon(Icons.menu_book_rounded, color: Colors.white70, size: 19),
                    onPressed: () => _openMemoryEditor(context, dsh, ws),
                  ),
                ],
              ),
            ),

            const Divider(color: Colors.white10, height: 1),

            // Sessions List inside workspace
            if (ws.sessions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('此工作区暂无会话', style: TextStyle(color: Colors.white38, fontSize: 12)),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: ws.sessions.length,
                itemBuilder: (context, sIdx) {
                  final s = ws.sessions[sIdx];
                  final isCurrentSession = isCurrent && s.matchesSessionId(dsh.currentSession?.sessionId);
                  return _buildSessionItem(context, dsh, ws, s, isCurrentSession);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionItem(
    BuildContext context,
    DshService dsh,
    Workspace ws,
    SessionMeta s,
    bool isCurrentSession,
  ) {
    final isRunning = _isSessionRunning(s, dsh);
    final pendingCount = _getSessionPendingCount(s, dsh);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2.5),
      decoration: BoxDecoration(
        color: isCurrentSession ? const Color(0xFF232A3B) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isRunning
              ? const Color(0xFF0078D4).withOpacity(0.4)
              : (pendingCount > 0
                  ? Colors.amberAccent.withOpacity(0.35)
                  : (isCurrentSession ? const Color(0xFF0078D4).withOpacity(0.3) : Colors.transparent)),
          width: 1.0,
        ),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
        leading: isRunning
            ? Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: const Color(0xFF0078D4).withOpacity(0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF60A5FA), width: 1.2),
                ),
                child: const Center(
                  child: SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF60A5FA)),
                  ),
                ),
              )
            : (pendingCount > 0
                ? Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Colors.amberAccent.withOpacity(0.15),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.amberAccent, width: 1.2),
                    ),
                    child: const Icon(Icons.shield_outlined, size: 15, color: Colors.amberAccent),
                  )
                : Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 16,
                    color: isCurrentSession ? const Color(0xFF60A5FA) : Colors.white30,
                  )),
        title: Row(
          children: [
            Expanded(
              child: Text(
                s.title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isCurrentSession ? FontWeight.w600 : FontWeight.normal,
                  color: isCurrentSession ? const Color(0xFF93C5FD) : Colors.white.withOpacity(0.9),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isRunning) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
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
            if (pendingCount > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: Colors.amberAccent.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.amberAccent.withOpacity(0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.priority_high_rounded, size: 10, color: Colors.amberAccent),
                    const SizedBox(width: 2),
                    Text('待审批 ($pendingCount)', style: const TextStyle(color: Colors.amberAccent, fontSize: 9.5, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 3),
            Text(
              s.firstPrompt.isNotEmpty ? s.firstPrompt : '无首条消息预览',
              style: const TextStyle(fontSize: 11.5, color: Colors.white54),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                if (s.model.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.purpleAccent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      s.model.replaceAll('cn:', ''),
                      style: const TextStyle(fontSize: 9.5, color: Colors.purpleAccent, fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(_formatTime(s.lastPromptAt), style: const TextStyle(fontSize: 10, color: Colors.white30)),
              ],
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Colors.white30),
              tooltip: '删除会话',
              onPressed: () => _showDeleteSessionDialog(context, dsh, ws, s),
            ),
            const Icon(Icons.chevron_right_rounded, size: 16, color: Colors.white24),
          ],
        ),
        onTap: () async {
          dsh.selectWorkspace(ws);
          await dsh.selectSession(s);
          widget.onSwitchToChat?.call();
        },
      ),
    );
  }
}
