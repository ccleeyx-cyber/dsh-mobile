import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../models/workspace.dart';
import '../models/gateway_features.dart';
import '../services/dsh_service.dart';
import '../theme/app_colors.dart';

class WorkspacesView extends StatefulWidget {
  final VoidCallback? onSwitchToChat;

  /// 本页当前是否可见。
  ///
  /// MainShell 用 IndexedStack 同时保活 4 个子页，子页的 State 与 MainShell 同
  /// 生命周期、永不 dispose，所以可见性必须由父级显式传进来，否则轮询会在用户
  /// 处于其它 tab 时照跑。默认 true，以便单独使用本页时行为不变。
  final bool active;

  const WorkspacesView({super.key, this.onSwitchToChat, this.active = true});

  @override
  State<WorkspacesView> createState() => _WorkspacesViewState();
}

class _WorkspacesViewState extends State<WorkspacesView> with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  String _searchFilter = '';
  Timer? _refreshTimer;
  bool _appResumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Provider.of<DshService>(context, listen: false).fetchWorkspaces();
      Provider.of<DshService>(context, listen: false).fetchApprovals();
    });
    _syncRefreshTimer();
  }

  @override
  void didUpdateWidget(covariant WorkspacesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _syncRefreshTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed == _appResumed) return;
    _appResumed = resumed;
    _syncRefreshTimer();
    // 回到前台时立刻补一次，避免用户看到最长 3 秒的过期数据。
    if (resumed && widget.active && mounted) {
      Provider.of<DshService>(context, listen: false).fetchWorkspaces();
    }
  }

  /// 只在「本页可见 且 App 在前台 且 处于未归档视图」时运行 3 秒轮询
  /// （驱动运行中动画与审批角标）。
  ///
  /// 此前 Timer.periodic 在 initState 里无条件启动，而 IndexedStack 让本页 State
  /// 永不 dispose，结果是：
  ///   - 用户停在对话/权限/设置 tab 时，仍然每 3 秒拉一次全量工作区；
  ///   - App 切到后台也照拉不误 —— MainShell 的 didChangeAppLifecycleState 只调
  ///     DshService.handleAppPaused()，而后者仅取消服务自己的 _sessionPollTimer
  ///     （dsh_service.dart:1677-1681），管不到这里 widget 级的 Timer。
  /// 代价不只是流量：网关侧 getWorkspacesData() 是全同步扫描（见 ANALYSIS §1.7），
  /// 期间阻塞 Node 事件循环。
  ///
  /// 归档视图额外停掉轮询，理由有两条且都成立：
  ///   - 已归档会话按定义不在运行，实时刷新不会产生任何变化；
  ///   - 本机 2322 个会话里 1338 个已归档，归档响应约为未归档的 2.4 倍，
  ///     每 3 秒重传一次纯属浪费。
  /// 归档视图改为进入时拉一次 + 下拉/手动刷新，语义上完全够用。
  ///
  /// 本方法是幂等的：条件满足且已在跑就立即返回，条件不满足就取消（取消 null
  /// 计时器是 no-op），所以可以安全地从 build() 里调用以响应筛选模式变化。
  void _syncRefreshTimer() {
    final dsh = context.mounted ? Provider.of<DshService>(context, listen: false) : null;
    final archivedMode = dsh?.archivedFilter ?? 'exclude';
    final shouldRun = widget.active && _appResumed && archivedMode == 'exclude';

    if (shouldRun) {
      if (_refreshTimer != null) return;
      _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (!mounted) {
          _stopRefreshTimer();
          return;
        }
        Provider.of<DshService>(context, listen: false).fetchWorkspaces();
      });
    } else {
      _stopRefreshTimer();
    }
  }

  void _stopRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopRefreshTimer();
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

  /// 全库搜索浮层：网关 /api/mobile/sessions/search，命中即跳转会话。
  ///
  /// [initialQuery] 非空时打开即自动执行一次搜索（从搜索框回车进来就是这个
  /// 路径），不用再点一次。
  Future<void> _showGlobalSearchSheet(BuildContext context, DshService dsh, {String? initialQuery}) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // backgroundColor 透明 + sheet 自己画圆角容器，保证 20px 圆角可见。
      builder: (sheetCtx) => _GlobalSearchSheet(
        dsh: dsh,
        initialQuery: initialQuery,
        onOpenSession: (sessionId, title) {
          Navigator.pop(sheetCtx);
          dsh.openSessionById(sessionId, title: title);
          widget.onSwitchToChat?.call();
        },
      ),
    );
  }

  /// 重命名会话：调网关 /api/mobile/sessions/rename。
  ///
  /// 失败要如实说（改的是 projcache 标题行，网关读不到缓存文件时会失败），
  /// 不能像删除那样静默乐观。
  Future<void> _showRenameDialog(BuildContext context, DshService dsh, SessionMeta s) async {
    final controller = TextEditingController(text: s.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.c.border),
        ),
        title: Text('重命名会话', style: TextStyle(color: context.c.textPrimary, fontSize: 17, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: InputDecoration(
            hintText: '输入新名称',
            counterText: '',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: context.c.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: context.c.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              elevation: 0,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    final newText = controller.text.trim();
    controller.dispose();
    if (ok != true || newText.isEmpty || newText == s.title) return;
    final success = await dsh.renameSession(s.sessionId, newText);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(success ? '已重命名为「$newText」' : '重命名失败: ${dsh.lastError}'),
      backgroundColor: success ? context.c.success : context.c.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // Delete Session Confirmation Dialog
  void _showDeleteSessionDialog(BuildContext context, DshService dsh, Workspace ws, SessionMeta s) {
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
            Icon(Icons.warning_amber_rounded, color: context.c.danger, size: 22),
            const SizedBox(width: 8),
            Text('删除会话', style: TextStyle(color: context.c.textPrimary, fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '确定要删除会话「${s.title}」吗？\n此操作将清除该会话的本地记录，无法撤销。',
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
              final ok = await dsh.deleteSession(s.sessionId, ws.workspaceId);
              if (context.mounted) {
                ScaffoldMessenger.of(context).clearSnackBars();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(ok ? '会话「${s.title}」已删除' : '删除失败: ${dsh.lastError}'),
                    duration: const Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
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

    if (!context.mounted) {
      textController.dispose();
      return;
    }

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
                      color: context.c.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(Icons.description_outlined, color: context.c.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '项目记忆与指令 (MEMORY.md)',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  ws.path,
                  style: TextStyle(fontSize: 11, color: context.c.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 16),
                Container(
                  height: 220,
                  decoration: BoxDecoration(
                    color: context.c.surfaceMuted,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: context.c.border),
                  ),
                  child: TextField(
                    controller: textController,
                    maxLines: null,
                    expands: true,
                    style: TextStyle(color: context.c.textPrimary, fontSize: 13, fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: '# 项目背景与上下文约定\n在这里编写项目的架构背景、禁止修改的文件或个性化智能体指示...',
                      hintStyle: TextStyle(color: context.c.textTertiary),
                      contentPadding: const EdgeInsets.all(12),
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
                      backgroundColor: context.c.accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      elevation: 0,
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
    ).whenComplete(() => textController.dispose());
  }

  /// 归档筛选分段控件（未归档 / 已归档 / 全部）。
  ///
  /// 「已归档」那一片带上总数：`archivedCount` 是网关在**所有模式**下都返回的、
  /// 与当前筛选无关的工作区级计数，所以这个数字在任何视图下都准确，用户不必
  /// 先切过去才知道有多少条。
  Widget _buildArchivedFilter(DshService dsh) {
    const modes = <String, String>{
      'exclude': '未归档',
      'only': '已归档',
      'include': '全部',
    };
    final totalArchived = dsh.workspaces.fold<int>(0, (sum, w) => sum + w.archivedCount);

    return Row(
      children: [
        Icon(Icons.inventory_2_outlined, size: 15, color: context.c.textTertiary),
        const SizedBox(width: 8),
        for (final entry in modes.entries) ...[
          ChoiceChip(
            label: Text(
              entry.key == 'only' && totalArchived > 0
                  ? '${entry.value} · $totalArchived'
                  : entry.value,
            ),
            selected: dsh.archivedFilter == entry.key,
            onSelected: (_) => dsh.setArchivedFilter(entry.key),
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            labelStyle: const TextStyle(fontSize: 11.5),
            backgroundColor: context.c.surface,
            side: BorderSide(color: context.c.border),
          ),
          const SizedBox(width: 6),
        ],
      ],
    );
  }

  /// 网关不支持归档筛选时的显式降级提示。
  ///
  /// 只在用户真的切到了非默认模式时才出现，所以旧网关 + 默认视图下没有任何
  /// 视觉噪音。出现时必须说清一件事：**下面列出的并不是已归档会话** ——
  /// 旧网关会静默忽略 `?archived=` 参数、照常返回未归档列表，如果客户端不校验
  /// 回显就直接渲染，等于把未归档会话贴上「已归档」标签骗用户。
  Widget _buildArchivedUnsupportedNotice() {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.c.warningSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.c.warningBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: context.c.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '网关没有回显归档筛选模式，说明它仍是旧版本：它忽略了这个参数，'
              '返回的还是未归档会话。下面列出的并不是已归档内容。\n'
              '需要在宿主机上重启 dsh web，让新版网关生效后此筛选才可用。',
              style: TextStyle(fontSize: 11.5, height: 1.5, color: context.c.warning),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    final workspaces = dsh.workspaces;
    final currentWs = dsh.currentWorkspace;

    // 幂等，用于响应归档筛选模式的变化：切到 only/include 时停掉 3 秒轮询，
    // 切回 exclude 时恢复。放在 build 里是因为筛选状态在 DshService 上，
    // 本页正是通过 listen:true 的 Provider.of 收到它的变更通知。
    _syncRefreshTimer();

    // Filter workspaces（本地即时过滤：工作区名/路径/会话标题/首条消息）
    final filteredWorkspaces = workspaces.where((ws) {
      if (_searchFilter.isEmpty) return true;
      final q = _searchFilter.toLowerCase();
      final matchWs = ws.title.toLowerCase().contains(q) || ws.path.toLowerCase().contains(q);
      final matchSession = ws.sessions.any(
        (s) => s.title.toLowerCase().contains(q) || s.firstPrompt.toLowerCase().contains(q),
      );
      return matchWs || matchSession;
    }).toList();

    int totalSessions = 0;
    int totalRunning = 0;
    for (final w in workspaces) {
      totalSessions += w.sessions.length;
      totalRunning += w.sessions.where((s) => _isSessionRunning(s, dsh)).length;
    }

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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '工作区与项目管理',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: context.c.textPrimary),
            ),
            Text(
              '管理各工程项目与历史会话流',
              style: TextStyle(fontSize: 11, color: context.c.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: context.c.textPrimary, size: 20),
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
            decoration: BoxDecoration(
              color: context.c.surface,
              border: Border(bottom: BorderSide(color: context.c.border)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildHeaderPill(
                    icon: Icons.folder_rounded,
                    label: '${workspaces.length} 个挂载项目',
                    color: context.c.accent,
                  ),
                  const SizedBox(width: 8),
                  _buildHeaderPill(
                    icon: Icons.chat_bubble_outline_rounded,
                    label: '$totalSessions 个历史会话',
                    color: context.c.accent,
                  ),
                  if (totalRunning > 0) ...[
                    const SizedBox(width: 8),
                    _buildHeaderPill(
                      icon: Icons.bolt_rounded,
                      label: '$totalRunning 个任务执行中',
                      color: context.c.accent,
                      animate: true,
                    ),
                  ],
                  if (dsh.pendingApprovals.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    _buildHeaderPill(
                      icon: Icons.shield_outlined,
                      label: '${dsh.pendingApprovals.length} 项待审批',
                      color: context.c.warning,
                      animate: true,
                    ),
                  ],
                ],
              ),
            ),
          ),

          // Search Bar：统一的搜索入口。
          //
          // 两种模式用同一根输入框：
          //  * 边打字边本地过滤（当前列表里筛工作区/标题）；
          //  * 点右侧「全库搜」或键盘搜索键 → 网关全库搜索（含已归档），
          //    结果以浮层展示。两个概念分两个按钮曾经让人分不清"搜哪个"。
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 42,
                    decoration: BoxDecoration(
                      color: context.c.surface,
                      borderRadius: BorderRadius.circular(21),
                      border: Border.all(color: context.c.border),
                    ),
                    child: TextField(
                      controller: _searchController,
                      style: TextStyle(color: context.c.textPrimary, fontSize: 13.5),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (q) {
                        if (q.trim().isNotEmpty) _showGlobalSearchSheet(context, dsh, initialQuery: q.trim());
                      },
                      decoration: InputDecoration(
                        hintText: '搜索会话：本页即时筛选，回车全库搜索',
                        hintStyle: TextStyle(color: context.c.textTertiary, fontSize: 12.5),
                        prefixIcon: Icon(Icons.search_rounded, size: 19, color: context.c.textTertiary),
                        suffixIcon: _searchFilter.isNotEmpty
                            ? IconButton(
                                icon: Icon(Icons.cancel_rounded, size: 18, color: context.c.textTertiary),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchFilter = '');
                                },
                              )
                            : null,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 11),
                      ),
                      onChanged: (val) => setState(() => _searchFilter = val.trim()),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 42,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: context.c.accent.withOpacity(0.12),
                      foregroundColor: context.c.accent,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(21)),
                    ),
                    onPressed: () {
                      final q = _searchController.text.trim();
                      _showGlobalSearchSheet(context, dsh, initialQuery: q);
                    },
                    icon: const Icon(Icons.travel_explore_rounded, size: 17),
                    label: const Text('全库搜', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),

          // 归档筛选：未归档 / 已归档 / 全部
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
            child: _buildArchivedFilter(dsh),
          ),

          // 只有「用户切到了非默认模式」且「网关没回显 mode」时才出现，
          // 所以旧网关配默认视图时页面与改动前完全一致，没有多余噪音。
          if (dsh.archivedFilter != 'exclude' && !dsh.archivedFilterSupported)
            _buildArchivedUnsupportedNotice(),

          // Workspace List
          Expanded(
            child: filteredWorkspaces.isEmpty
                ? Center(
                    child: Text('没有找到匹配的工作区', style: TextStyle(color: context.c.textTertiary)),
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
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.25)),
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
        color: context.c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isCurrent
              ? context.c.accent
              : (hasRunning
                  ? context.c.accent.withOpacity(0.5)
                  : (pendingCount > 0
                      ? context.c.warning
                      : context.c.border)),
          width: isCurrent ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: isCurrent,
          leading: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: isCurrent ? context.c.accent.withOpacity(0.12) : context.c.surfaceMuted,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.folder_rounded,
              color: isCurrent ? context.c.accent : context.c.textSecondary,
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
                    color: isCurrent ? context.c.accent : context.c.textPrimary,
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
                    color: context.c.accent.withOpacity(0.1),
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
                      const SizedBox(width: 4),
                      Text('$runningSessionsCount 执行中', style: TextStyle(color: context.c.accent, fontSize: 9.5, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
              if (pendingCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: context.c.warningBadgeSurface,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: context.c.warningBorder),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.shield_outlined, size: 10, color: context.c.warning),
                      const SizedBox(width: 3),
                      Text('$pendingCount 待审批', style: TextStyle(color: context.c.warning, fontSize: 9.5, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
              if (isCurrent && !hasRunning && pendingCount == 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: context.c.accent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: context.c.accent.withOpacity(0.3)),
                  ),
                  child: Text('当前活跃', style: TextStyle(color: context.c.accent, fontSize: 9.5, fontWeight: FontWeight.bold)),
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
                      style: TextStyle(fontSize: 11, color: context.c.textSecondary, fontFamily: 'monospace'),
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
                    child: Icon(Icons.copy, size: 13, color: context.c.textTertiary),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              // 工作区卡片默认是折叠的（initiallyExpanded: isCurrent），所以这行
              // subtitle 往往是不点开就能看到的唯一信息 —— 它必须说清楚这个数字
              // 数的是什么，否则「已归档」视图下显示「共 1275 个历史对话」会让人
              // 以为未归档的会话凭空多出来了。
              Text(
                dsh.archivedFilter == 'only'
                    ? '共 ${ws.sessions.length} 个已归档对话'
                    : dsh.archivedFilter == 'include'
                        ? '共 ${ws.sessions.length} 个对话（含已归档）'
                        : '共 ${ws.sessions.length} 个历史对话',
                style: TextStyle(fontSize: 10.5, color: context.c.textTertiary),
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
                          foregroundColor: context.c.accent,
                          side: BorderSide(color: context.c.accent),
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
                        backgroundColor: context.c.accent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        elevation: 0,
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
                    icon: Icon(Icons.menu_book_rounded, color: context.c.textSecondary, size: 19),
                    onPressed: () => _openMemoryEditor(context, dsh, ws),
                  ),
                ],
              ),
            ),

            Divider(color: context.c.border, height: 1),

            // Sessions List inside workspace
            if (ws.sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  // 「已归档」视图下必须换说法：本机 GZ 工作区一条归档都没有，
                  // 若仍显示「暂无会话」会让人以为会话丢了。
                  dsh.archivedFilter == 'only' ? '此工作区没有已归档的会话' : '此工作区暂无会话',
                  style: TextStyle(color: context.c.textTertiary, fontSize: 12),
                ),
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
        color: isCurrentSession ? context.c.selectedSurface : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isRunning
              ? context.c.accent.withOpacity(0.4)
              : (pendingCount > 0
                  ? context.c.warning.withOpacity(0.35)
                  : (isCurrentSession ? context.c.accent.withOpacity(0.3) : Colors.transparent)),
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
                  color: context.c.accent.withOpacity(0.12),
                  shape: BoxShape.circle,
                  border: Border.all(color: context.c.accent, width: 1.2),
                ),
                child: Center(
                  child: SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: context.c.accent),
                  ),
                ),
              )
            : (pendingCount > 0
                ? Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: context.c.warningBadgeSurface,
                      shape: BoxShape.circle,
                      border: Border.all(color: context.c.warning, width: 1.2),
                    ),
                    child: Icon(Icons.shield_outlined, size: 15, color: context.c.warning),
                  )
                : Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 16,
                    color: isCurrentSession ? context.c.accent : context.c.textTertiary,
                  )),
        title: Row(
          children: [
            Expanded(
              child: Text(
                s.title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isCurrentSession ? FontWeight.w600 : FontWeight.normal,
                  color: isCurrentSession ? context.c.accent : context.c.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // 只在「全部」视图下打标：在「已归档」视图里每一行都是归档的，
            // 1338 行全部挂一个「已归档」徽章纯属噪音。
            if (s.archived && dsh.archivedFilter == 'include') ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: context.c.surfaceMuted,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: context.c.border),
                ),
                child: Text(
                  '已归档',
                  style: TextStyle(fontSize: 10, color: context.c.textSecondary),
                ),
              ),
            ],
            if (isRunning) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: context.c.accent.withOpacity(0.1),
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
                    const SizedBox(width: 4),
                    Text('执行中', style: TextStyle(color: context.c.accent, fontSize: 9.5, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
            if (pendingCount > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: context.c.warningBadgeSurface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: context.c.warningBorder),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.priority_high_rounded, size: 10, color: context.c.warning),
                    const SizedBox(width: 2),
                    Text('待审批 ($pendingCount)', style: TextStyle(color: context.c.warning, fontSize: 9.5, fontWeight: FontWeight.bold)),
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
              style: TextStyle(fontSize: 11.5, color: context.c.textSecondary),
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
                      color: context.c.surfaceMuted,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: context.c.border),
                    ),
                    child: Text(
                      s.model.replaceAll('cn:', ''),
                      style: TextStyle(fontSize: 9.5, color: context.c.textPrimary, fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(_formatTime(s.lastPromptAt), style: TextStyle(fontSize: 10, color: context.c.textTertiary)),
              ],
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(
                s.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
                size: 18,
                color: context.c.textTertiary,
              ),
              tooltip: s.archived ? '取消归档' : '归档',
              onPressed: () async {
                HapticFeedback.selectionClick();
                final ok = await dsh.setSessionArchived(s.sessionId, !s.archived);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(ok
                      ? (s.archived ? '已取消归档' : '已归档「${s.title}」')
                      : '${s.archived ? '取消归档' : '归档'}失败: ${dsh.lastError}'),
                  backgroundColor: ok ? context.c.success : context.c.danger,
                  behavior: SnackBarBehavior.floating,
                ));
              },
            ),
            IconButton(
              icon: Icon(Icons.edit_outlined, size: 18, color: context.c.textTertiary),
              tooltip: '重命名',
              onPressed: () => _showRenameDialog(context, dsh, s),
            ),
            IconButton(
              icon: Icon(Icons.delete_outline_rounded, size: 18, color: context.c.textTertiary),
              tooltip: '删除会话',
              onPressed: () => _showDeleteSessionDialog(context, dsh, ws, s),
            ),
            Icon(Icons.chevron_right_rounded, size: 16, color: context.c.border),
          ],
        ),
        onTap: () async {
          HapticFeedback.selectionClick();
          dsh.selectWorkspace(ws);
          await dsh.selectSession(s);
          widget.onSwitchToChat?.call();
        },
      ),
    );
  }
}

/// 全库搜索浮层（StatefulWidget）。
///
/// 拆成独立 State 而不是 StatefulBuilder 闭包，是因为 initialQuery 的自动
/// 首搜需要 postFrameCallback + 受控的生命周期：闭包版在浮层被秒关时对
/// 已 dispose 的 controller/text 触发更新，只能靠 try/catch 兜底；State
/// 版 `mounted` 检查就够了。
class _GlobalSearchSheet extends StatefulWidget {
  final DshService dsh;
  final String? initialQuery;
  final void Function(String sessionId, String title) onOpenSession;

  const _GlobalSearchSheet({
    required this.dsh,
    required this.onOpenSession,
    this.initialQuery,
  });

  @override
  State<_GlobalSearchSheet> createState() => _GlobalSearchSheetState();
}

class _GlobalSearchSheetState extends State<_GlobalSearchSheet> {
  final TextEditingController _controller = TextEditingController();
  final List<SessionSearchHit> _results = [];
  bool _searched = false;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuery;
    if (q != null && q.isNotEmpty) {
      _controller.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) => _search(q));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) return;
    setState(() => _searching = true);
    final hits = await widget.dsh.searchSessions(q);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _searched = true;
      _results
        ..clear()
        ..addAll(hits);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.8,
        decoration: BoxDecoration(
          color: context.c.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // 抓手 + 标题
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: context.c.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 12, 4),
              child: Row(
                children: [
                  Icon(Icons.travel_explore_rounded, size: 20, color: context.c.accent),
                  const SizedBox(width: 8),
                  Text('全库搜索', style: TextStyle(color: context.c.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  Text('含已归档 · 按标题与首条消息', style: TextStyle(color: context.c.textTertiary, fontSize: 11)),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.close_rounded, size: 20, color: context.c.textTertiary),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // 搜索输入
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 8),
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: context.c.surfaceMuted,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: context.c.border),
                ),
                child: TextField(
                  controller: _controller,
                  autofocus: widget.initialQuery == null || widget.initialQuery!.isEmpty,
                  style: TextStyle(color: context.c.textPrimary, fontSize: 14),
                  textInputAction: TextInputAction.search,
                  onSubmitted: _search,
                  decoration: InputDecoration(
                    hintText: '输入关键词，回车搜索全部会话',
                    hintStyle: TextStyle(color: context.c.textTertiary, fontSize: 13),
                    prefixIcon: Icon(Icons.search_rounded, size: 20, color: context.c.textTertiary),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ),
            // 结果区
            Expanded(
              child: _searching
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
                  : !_searched
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.manage_search_rounded, size: 44, color: context.c.textTertiary.withOpacity(0.5)),
                              const SizedBox(height: 10),
                              Text('搜索全部工作区的历史会话', style: TextStyle(color: context.c.textTertiary, fontSize: 13)),
                            ],
                          ),
                        )
                      : _results.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.search_off_rounded, size: 44, color: context.c.textTertiary.withOpacity(0.5)),
                                  const SizedBox(height: 10),
                                  Text('没有命中会话', style: TextStyle(color: context.c.textTertiary, fontSize: 13)),
                                ],
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
                              itemCount: _results.length,
                              separatorBuilder: (_, __) => Divider(height: 1, color: context.c.border.withOpacity(0.5)),
                              itemBuilder: (itemCtx, i) {
                                final hit = _results[i];
                                return ListTile(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                                  leading: CircleAvatar(
                                    radius: 17,
                                    backgroundColor: (hit.archived ? context.c.textTertiary : context.c.accent).withOpacity(0.12),
                                    child: Icon(
                                      hit.archived ? Icons.archive_outlined : Icons.chat_bubble_outline_rounded,
                                      size: 17,
                                      color: hit.archived ? context.c.textTertiary : context.c.accent,
                                    ),
                                  ),
                                  title: Text(
                                    hit.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: context.c.textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            hit.firstPrompt.isEmpty ? hit.workspaceTitle : hit.firstPrompt,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(color: context.c.textSecondary, fontSize: 12),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          hit.archived ? '· 已归档' : '· ${hit.workspaceTitle}',
                                          style: TextStyle(color: context.c.textTertiary, fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  ),
                                  onTap: () => widget.onOpenSession(hit.sessionId, hit.title),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}
