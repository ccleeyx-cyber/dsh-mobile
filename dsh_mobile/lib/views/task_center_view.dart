import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../models/task_center.dart';
import '../services/dsh_service.dart';
import '../services/platform_services.dart';
import '../theme/app_colors.dart';

/// 「任务」页：一个会话"在等什么 / 改了什么 / 产出什么 / 烧了多少"的统一视图。
///
/// 为什么这些放在一起而不是各开一页：它们回答的是**同一个问题**——“我这台
/// 手机上放着的这个任务，现在处于什么状态”。分成五个页面意味着用户在五个
/// 入口之间来回翻。
///
/// 数据全部来自网关注册的新路由（交付物 / 变更 / 定时 / 作业 / 用量），
/// 每块都能单独失败：某一块读不到只显示它自己的错误，不影响其余五块。
class TaskCenterView extends StatefulWidget {
  /// 切到对话页（排队消息/提问都在那里处理）。
  final VoidCallback? onOpenChat;

  const TaskCenterView({super.key, this.onOpenChat});

  @override
  State<TaskCenterView> createState() => _TaskCenterViewState();
}

class _TaskCenterViewState extends State<TaskCenterView> {
  bool _loading = false;
  String? _loadedSessionId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final dsh = Provider.of<DshService>(context, listen: false);
    if (dsh.currentSession == null) return;
    setState(() => _loading = true);
    await dsh.refreshTaskCenter();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loadedSessionId = dsh.currentSession?.sessionId;
    });
  }

  @override
  Widget build(BuildContext context) {
    final dsh = Provider.of<DshService>(context);
    // 会话切换后本页的数据属于上一个会话，必须重新拉 —— 否则会把 A 会话的
    // 交付物挂在 B 会话的标题下，那是主动误导。
    final sessionId = dsh.currentSession?.sessionId;
    if (sessionId != null && sessionId != _loadedSessionId && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_loading) _refresh();
      });
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
        title: Row(
          children: [
            Icon(Icons.dashboard_customize_rounded, color: context.c.accent),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('任务', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.c.textPrimary)),
                Text(
                  dsh.currentSession?.title ?? '未选择会话',
                  style: TextStyle(fontSize: 10.5, color: context.c.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            IconButton(
              icon: Icon(Icons.refresh_rounded, color: context.c.textPrimary),
              tooltip: '刷新',
              onPressed: _refresh,
            ),
        ],
      ),
      body: dsh.currentSession == null
          ? _emptyState('先在「对话」或「工作区」里打开一个会话')
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
                children: [
                  _buildQueueCard(dsh),
                  const SizedBox(height: 14),
                  _buildUsageCard(dsh),
                  const SizedBox(height: 14),
                  _buildJobsCard(dsh),
                  const SizedBox(height: 14),
                  _buildSchedulesCard(dsh),
                  const SizedBox(height: 14),
                  _buildDeliverablesCard(dsh),
                  const SizedBox(height: 14),
                  _buildChangesCard(dsh),
                ],
              ),
            ),
    );
  }

  Widget _emptyState(String text) => Center(
        child: Text(text, style: TextStyle(color: context.c.textSecondary, fontSize: 13.5)),
      );

  Widget _sectionCard({required String title, required IconData icon, required List<Widget> children, Widget? trailing}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: context.c.textSecondary),
              const SizedBox(width: 7),
              Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: context.c.textPrimary)),
              const Spacer(),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Widget _hint(String text) => Text(text, style: TextStyle(fontSize: 12, color: context.c.textSecondary, height: 1.35));

  // ------------------------------------------------------------- queue ----

  Widget _buildQueueCard(DshService dsh) {
    final rows = dsh.queueItems;
    return _sectionCard(
      title: '排队消息',
      icon: Icons.queue_rounded,
      trailing: rows.isEmpty
          ? null
          : TextButton(
              onPressed: () => widget.onOpenChat?.call(),
              style: TextButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
              child: const Text('去处理', style: TextStyle(fontSize: 12)),
            ),
      children: [
        if (dsh.queueError.isNotEmpty) ...[
          _hint(dsh.queueError),
          const SizedBox(height: 6),
        ],
        if (rows.isEmpty)
          _hint(dsh.isSessionRunning ? '没有排队消息 —— 这一轮跑完后不会有新指令。' : '会话空闲，没有排队消息。')
        else
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.subdirectory_arrow_right_rounded, size: 15, color: context.c.textTertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(row.label, style: TextStyle(fontSize: 12.5, color: context.c.textPrimary), maxLines: 3, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  // ------------------------------------------------------------- usage ----

  Widget _buildUsageCard(DshService dsh) {
    final stats = dsh.sessionStats;
    final goal = stats?.goal;

    final children = <Widget>[];
    if (stats == null || stats.source == 'none') {
      children.add(_hint('还没有用量记录 —— 这个会话还没跑过模型请求。'));
    } else {
      children.add(Row(
        children: [
          _metric('总 token', stats.totalTokens?.toString() ?? '—'),
          _metric('输入(未缓存)', stats.uncachedInputTokens?.toString() ?? '—'),
          _metric('输出', stats.outputTokens?.toString() ?? '—'),
        ],
      ));
      children.add(const SizedBox(height: 8));
      children.add(Row(
        children: [
          _metric('缓存读', stats.cacheReadTokens?.toString() ?? '—'),
          _metric('缓存写', stats.cacheWriteTokens?.toString() ?? '—'),
          _metric('上下文占用', stats.pressureTokens?.toString() ?? '—'),
        ],
      ));
      final fraction = stats.contextFraction;
      if (fraction != null) {
        children.add(const SizedBox(height: 10));
        children.add(ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 5,
            backgroundColor: context.c.surfaceMuted,
            valueColor: AlwaysStoppedAnimation(
              fraction > 0.85 ? context.c.danger : (fraction > 0.6 ? context.c.warning : context.c.success),
            ),
          ),
        ));
        children.add(const SizedBox(height: 4));
        children.add(_hint('已用 ${stats.pressureTokens} / 窗口 ${stats.contextWindow}'
            '${stats.projectedTokens != null ? ' · 下一轮预计 ${stats.projectedTokens}' : ''}'));
      }
      children.add(const SizedBox(height: 6));
      children.add(_hint(stats.source == 'cache'
          ? '数值来自投影缓存（会话当前不在内存中，可能是最后一次上报的快照）。'
          : '数值来自引擎的 token 计量投影（提供方上报值）。'));
    }

    if (goal != null) {
      children.add(const SizedBox(height: 12));
      children.add(Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: context.c.surfaceMuted,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.c.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.flag_rounded, size: 14, color: context.c.accent),
                const SizedBox(width: 6),
                Text('目标 · ${goal.phaseLabel}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.c.textPrimary)),
                const Spacer(),
                if (goal.roundsStarted != null)
                  Text(
                    '第 ${goal.roundsStarted}${goal.maxGoalRounds != null ? '/${goal.maxGoalRounds}' : ''} 轮',
                    style: TextStyle(fontSize: 11, color: context.c.textTertiary),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(goal.objective, style: TextStyle(fontSize: 12, color: context.c.textSecondary, height: 1.35)),
            if (goal.blockedReason != null) ...[
              const SizedBox(height: 4),
              Text('受阻：${goal.blockedReason}', style: TextStyle(fontSize: 11.5, color: context.c.danger)),
            ],
          ],
        ),
      ));
    }

    return _sectionCard(title: '用量与上下文', icon: Icons.data_usage_rounded, children: children);
  }

  Widget _metric(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: context.c.textPrimary)),
          Text(label, style: TextStyle(fontSize: 10.5, color: context.c.textTertiary)),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- jobs ----

  Widget _buildJobsCard(DshService dsh) {
    final jobs = dsh.jobs;
    return _sectionCard(
      title: '后台作业',
      icon: Icons.memory_rounded,
      children: [
        if (jobs.isEmpty)
          _hint('没有后台作业。长时间命令与子代理会在这里出现。')
        else
          for (final job in jobs)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 2),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: (job.isLive ? context.c.accent : context.c.textTertiary).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: (job.isLive ? context.c.accent : context.c.border).withOpacity(0.5)),
                    ),
                    child: Text(
                      job.statusLabel,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: job.isLive ? context.c.accent : context.c.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(job.label.isEmpty ? job.id : job.label,
                            style: TextStyle(fontSize: 12.5, color: context.c.textPrimary), maxLines: 2, overflow: TextOverflow.ellipsis),
                        Text(
                          [job.kind, if ((job.progress ?? '').isNotEmpty) job.progress!, if ((job.detail ?? '').isNotEmpty) job.detail!].join(' · '),
                          style: TextStyle(fontSize: 11, color: context.c.textTertiary),
                        ),
                      ],
                    ),
                  ),
                  if (job.isLive)
                    TextButton(
                      onPressed: () => _killJob(dsh, job),
                      style: TextButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                      child: Text('终止', style: TextStyle(fontSize: 12, color: context.c.danger)),
                    ),
                ],
              ),
            ),
      ],
    );
  }

  Future<void> _killJob(DshService dsh, JobItem job) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('终止这个后台作业？'),
        content: Text('将请求引擎终止「${job.label.isEmpty ? job.id : job.label}」。'
            '已经产生的输出仍保留在会话日志里。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('终止')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await dsh.killJob(job.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(done ? '已请求终止' : '终止失败'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  // --------------------------------------------------------- schedules ----

  Widget _buildSchedulesCard(DshService dsh) {
    final rows = dsh.schedules;
    return _sectionCard(
      title: '定时任务',
      icon: Icons.schedule_rounded,
      children: [
        if (rows.isEmpty)
          _hint('没有定时任务。可以让 agent 用 schedule 建一个，这里就能看到与撤销。')
        else
          for (final s in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.title.isEmpty ? s.id : s.title,
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: context.c.textPrimary)),
                        Text(
                          [s.schedule, if (s.scheduledAt != null) '下次 ${_shortTime(s.scheduledAt!)}'].join(' · '),
                          style: TextStyle(fontSize: 11, color: context.c.textTertiary),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => _deleteSchedule(dsh, s),
                    style: TextButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                    child: Text('删除', style: TextStyle(fontSize: 12, color: context.c.danger)),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  String _shortTime(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    final local = dt.toLocal();
    return '${local.month}-${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _deleteSchedule(DshService dsh, ScheduleItem s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除定时任务？'),
        content: Text('将删除「${s.title.isEmpty ? s.id : s.title}」。之后不会再触发提醒。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await dsh.deleteSchedule(s.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(done ? '已删除' : '删除失败'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  // ------------------------------------------------------ deliverables ----

  Widget _buildDeliverablesCard(DshService dsh) {
    final files = dsh.deliverables;
    return _sectionCard(
      title: '交付物',
      icon: Icons.folder_special_rounded,
      children: [
        if (files.isEmpty)
          _hint('这次任务还没有声明交付文件。agent 交付 docx/xlsx/pdf 时会出现在这里。')
        else
          for (final f in files)
            InkWell(
              onTap: () => _openDeliverable(dsh, f),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(_iconFor(f.extension), size: 20, color: context.c.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(f.fileName, style: TextStyle(fontSize: 12.5, color: context.c.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(
                            f.description.isNotEmpty ? f.description : f.display,
                            style: TextStyle(fontSize: 10.5, color: context.c.textTertiary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    _busyDeliverable == f.path
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.download_rounded, size: 18, color: context.c.textSecondary),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  IconData _iconFor(String ext) {
    switch (ext) {
      case 'docx':
      case 'doc':
        return Icons.description_rounded;
      case 'xlsx':
      case 'xls':
      case 'csv':
        return Icons.table_chart_rounded;
      case 'pptx':
      case 'ppt':
        return Icons.slideshow_rounded;
      case 'pdf':
        return Icons.picture_as_pdf_rounded;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'webp':
      case 'gif':
        return Icons.image_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  /// 下载交付物并交给系统应用打开。
  ///
  /// 走原生通道而不是写入 App 私有目录后给个路径：Android 上文件要能被外部
  /// 应用打开必须过 FileProvider，而缓存目录只有原生侧知道。字节在这里读齐
  /// （带鉴权头），原生只负责落盘 + 拉起 Intent。
  Future<void> _openDeliverable(DshService dsh, DeliverableItem item) async {
    final uri = dsh.deliverableUrl(item);
    if (uri == null) return;

    setState(() => _busyDeliverable = item.path);
    try {
      final res = await http.get(uri, headers: dsh.authHeadersForDownload).timeout(const Duration(seconds: 60));
      if (!mounted) return;
      if (res.statusCode != 200) {
        _toast('下载失败 (HTTP ${res.statusCode})');
        return;
      }
      final ok = await _openBytesNative(item.fileName, res.bodyBytes);
      if (!mounted) return;
      if (!ok) _toast('已下载，但没有应用能打开 ${item.fileName}');
    } catch (e) {
      if (mounted) _toast('下载失败: $e');
    } finally {
      if (mounted) setState(() => _busyDeliverable = null);
    }
  }

  Future<bool> _openBytesNative(String name, List<int> bytes) => FileOpener.openBytes(name, bytes);

  String? _busyDeliverable;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  // --------------------------------------------------------- changes ------

  Widget _buildChangesCard(DshService dsh) {
    final files = dsh.workspaceChanges;
    return _sectionCard(
      title: '本次变更',
      icon: Icons.difference_rounded,
      children: [
        if (!dsh.workspaceChangesAvailable && files.isEmpty)
          _hint(dsh.workspaceChangesReason == 'not-a-git-repository'
              ? '这个工作区不是 git 仓库，无法列出改动（引擎侧的变更快照不通过 RPC 暴露）。'
              : '还没有变更记录。')
        else if (files.isEmpty)
          _hint('工作区是干净的 —— 没有未提交改动。')
        else
          for (final change in files)
            InkWell(
              onTap: () => _showDiff(dsh, change),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 34,
                      child: Text(change.label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: context.c.warning)),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        change.path,
                        style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: context.c.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(change.delta, style: TextStyle(fontSize: 10.5, color: context.c.textTertiary)),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right_rounded, size: 16, color: context.c.textTertiary),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  Future<void> _showDiff(DshService dsh, WorkspaceChange change) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _DiffSheet(change: change, loader: () => dsh.fetchDiff(change.path)),
    );
  }
}

/// diff 面板：先异步取 hunk，再逐行渲染。加载中/空/二进制都有明确文案。
class _DiffSheet extends StatefulWidget {
  final WorkspaceChange change;
  final Future<List<DiffHunk>> Function() loader;

  const _DiffSheet({required this.change, required this.loader});

  @override
  State<_DiffSheet> createState() => _DiffSheetState();
}

class _DiffSheetState extends State<_DiffSheet> {
  List<DiffHunk>? _hunks;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.loader().then((h) {
      if (mounted) setState(() => _hunks = h);
    }).catchError((Object e) {
      debugPrint('[TaskCenter] diff 加载失败: $e');
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.75;
    final hunks = _hunks;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.change.path,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'monospace', color: context.c.textPrimary),
                      maxLines: 2,
                    ),
                  ),
                  Text(widget.change.delta, style: TextStyle(fontSize: 11, color: context.c.textTertiary)),
                ],
              ),
            ),
            Divider(height: 1, color: context.c.border),
            Flexible(
              child: _failed
                  ? Padding(padding: const EdgeInsets.all(20), child: Text('diff 读取失败', style: TextStyle(color: context.c.danger)))
                  : hunks == null
                      ? const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                      : hunks.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(
                                widget.change.status == '??'
                                    ? '未跟踪的新文件，git 没有可比对的旧版本。'
                                    : '没有文本差异（可能是二进制或仅权限变更）。',
                                style: TextStyle(fontSize: 12.5, color: context.c.textSecondary),
                              ),
                            )
                          : ListView(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                              children: [
                                for (final hunk in hunks) ...[
                                  Padding(
                                    padding: const EdgeInsets.only(top: 6, bottom: 4),
                                    child: Text(
                                      hunk.header,
                                      style: TextStyle(fontSize: 11, color: context.c.accent, fontFamily: 'monospace'),
                                    ),
                                  ),
                                  for (final line in hunk.lines)
                                    Container(
                                      width: double.infinity,
                                      color: line.kind == 'add'
                                          ? context.c.success.withOpacity(0.10)
                                          : line.kind == 'del'
                                              ? context.c.danger.withOpacity(0.10)
                                              : null,
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                      child: Text(
                                        '${line.kind == 'add' ? '+' : line.kind == 'del' ? '-' : ' '}${line.text}',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontFamily: 'monospace',
                                          height: 1.35,
                                          color: line.kind == 'add'
                                              ? context.c.success
                                              : line.kind == 'del'
                                                  ? context.c.danger
                                                  : context.c.textSecondary,
                                        ),
                                      ),
                                    ),
                                ],
                              ],
                            ),
            ),
          ],
        ),
      ),
    );
  }
}
