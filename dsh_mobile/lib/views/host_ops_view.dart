import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/bridge_extras.dart';
import '../services/dsh_service.dart';
import '../theme/app_colors.dart';
import '../widgets/safe_markdown.dart';

/// 运维面板（bridge v1.16）：把"手机上能对主机做的事"收进一屏四个页签。
///
/// 四条贯穿全屏的规则先写在这里，因为每个页签都踩过同一个坑：
///
/// 1. **失败不能渲染成"空成功"**。`fetchQuickCommands` / `fetchCheckpoints`
///    在网关不可达时退化成空列表，`fetchGoalBoard` 退化成 null。如果直接把
///    "空"当答案，用户读到的是"没有命令""目录是空的""还没有目标"——全是编出来的
///    结论。所以每一屏都区分"取到了但确实为空"与"取不到"，后者一律给错误态 + 重试。
/// 2. **缓存快照必须自报家门**。`GoalBoard.source == 'cache'` 时那些数字来自会话
///    最后一次上报，不是实时值；不标出来就等于把历史当作现状，这是本仓库的硬要求。
/// 3. **引擎必然拒绝的操作不出现**。`forkable == false` 的检查点、缺 CAS ref
///    （`operable == false`）的目标操作都不发请求 —— 发出去只是把"我猜的"变成一个
///    错误提示，用户还白等一次往返。
/// 4. **这里没有任何参数输入框**。快捷命令过线的只有一个白名单 id，网关侧把它解析
///    成固定 argv，手机上不存在可注入的参数位。真加一个参数框，就是在骗自己说
///    这个面板能执行任意命令。
///
/// 颜色一律走 `context.c.<token>`：本文件里不允许出现硬编码色值，否则深色模式下
/// 会出现"深底 + 深字"。
class HostOpsView extends StatefulWidget {
  const HostOpsView({super.key});

  @override
  State<HostOpsView> createState() => _HostOpsViewState();
}

class _HostOpsViewState extends State<HostOpsView> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: context.c.background,
        appBar: AppBar(
          title: const Text('运维面板'),
          backgroundColor: context.c.surface,
          foregroundColor: context.c.textPrimary,
          elevation: 0,
          bottom: TabBar(
            // 四个中文页签在窄屏上会挤成两行，横向滚动比截断更好读。
            isScrollable: true,
            labelColor: context.c.accent,
            unselectedLabelColor: context.c.textSecondary,
            indicatorColor: context.c.accent,
            tabs: const <Widget>[
              Tab(text: '快捷命令'),
              Tab(text: '文件'),
              Tab(text: '目标'),
              Tab(text: '分支'),
            ],
          ),
        ),
        // 每个页签自己持有状态：切走再切回来时结果还在（TabBarView 保活），
        // 用户不用为了对比两条命令的输出而重跑。
        body: const TabBarView(
          children: <Widget>[
            _QuickCommandsTab(),
            _FilesTab(),
            _GoalsTab(),
            _ForksTab(),
          ],
        ),
      ),
    );
  }
}

// =====================================================================
// 页签一：快捷命令
// =====================================================================

class _QuickCommandsTab extends StatefulWidget {
  const _QuickCommandsTab();

  @override
  State<_QuickCommandsTab> createState() => _QuickCommandsTabState();
}

class _QuickCommandsTabState extends State<_QuickCommandsTab> {
  /// null = 还没取到（区分"加载中"与"确实是空目录"）。
  List<QuickCommandInfo>? _commands;
  bool _loading = true;

  /// 正在运行的那一条。非空时所有行都禁用再入：白名单命令会改工作区/占端口，
  /// 连点两次发起的是两个真实进程。
  String? _runningId;

  /// 上次运行结果，按命令 id 缓存。看完一条的输出去点另一条再回来，结果应该还在
  /// —— "对比两条命令的输出"就是这个页签的主要用法。
  final Map<String, QuickCommandResult> _results = <String, QuickCommandResult>{};

  /// 被折叠起来的输出 id。默认展开：刚跑完的输出就是用户要看的那一段。
  final Set<String> _collapsed = <String>{};

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    // listen: false —— 结果只由本页签的 setState 驱动重绘，不跟着服务的全局通知抖。
    final dsh = Provider.of<DshService>(context, listen: false);
    final list = await dsh.fetchQuickCommands();
    if (!mounted) return;
    setState(() {
      _commands = list;
      _loading = false;
    });
  }

  Future<void> _retry() async {
    setState(() => _loading = true);
    await _fetch();
  }

  Future<void> _run(QuickCommandInfo cmd) async {
    final dsh = Provider.of<DshService>(context, listen: false);

    // 改工作区的命令先问一句。文案必须说清"会改动工作区"，而不是模糊的"确定吗"。
    if (cmd.danger) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('运行这条命令？'),
          content: Text('「${cmd.label}」会修改当前工作区（可能新增、改动或删除文件）。'
              '${cmd.description.isEmpty ? '' : '\n\n${cmd.description}'}'),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('运行')),
          ],
        ),
      );
      if (confirmed != true) return;
      if (!mounted) return;
    }

    setState(() => _runningId = cmd.id);
    try {
      final result = await dsh.runQuickCommand(cmd.id);
      if (!mounted) return;
      setState(() {
        _results[cmd.id] = result;
        _collapsed.remove(cmd.id);
      });
    } finally {
      // 无论成功、失败还是抛异常都要放开这把锁，否则这一条会永久卡在"运行中"，
      // 而这个页签里所有命令都会跟着一起被禁用。
      if (mounted) setState(() => _runningId = null);
    }
  }

  void _toggle(String id) {
    setState(() {
      if (!_collapsed.remove(id)) _collapsed.add(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cmds = _commands;

    if (cmds == null) {
      if (_loading) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      return _errorPane(
        context,
        message: '还没有取到命令目录。',
        onRetry: _retry,
      );
    }

    if (cmds.isEmpty) {
      // 空列表在这里有两种成因（目录为空 / 网关不可达），服务层不区分，文案也不许
      // 假装知道是哪种 —— 只说"没取到"，并给一个重试。
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
        children: <Widget>[
          _noticeBox(
            context,
            '没有取到快捷命令 —— 可能是网关侧的命令白名单为空，也可能是网关暂时不可达。这两件事在这一屏看不出来，重试一次再判断。',
            warning: true,
            icon: Icons.help_outline_rounded,
          ),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: _retryButton(_retry)),
        ],
      );
    }

    // 按 groupLabel 分组，保持服务端返回的顺序（用 LinkedHashMap 的插入序），
    // 不排序：命令目录的顺序是网关刻意排的（常用的在前）。
    final groups = <String, List<QuickCommandInfo>>{};
    for (final cmd in cmds) {
      groups.putIfAbsent(cmd.groupLabel, () => <QuickCommandInfo>[]).add(cmd);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: <Widget>[
        _hint(context, '这些是网关白名单里的固定命令，手机上只能选、不能拼参数。输出只显示在这一屏，不会进入对话。'),
        for (final entry in groups.entries) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
            child: Text(
              entry.key,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: context.c.textSecondary),
            ),
          ),
          for (final cmd in entry.value) _buildCommand(cmd),
        ],
      ],
    );
  }

  Widget _buildCommand(QuickCommandInfo cmd) {
    final c = context.c;
    final result = _results[cmd.id];
    final running = _runningId == cmd.id;
    final anyRunning = _runningId != null;
    final expanded = !_collapsed.contains(cmd.id);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: anyRunning ? null : () => _run(cmd),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                cmd.label.isEmpty ? cmd.id : cmd.label,
                                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.textPrimary),
                              ),
                            ),
                            if (cmd.danger) ...<Widget>[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: c.warningBadgeSurface,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: c.warningBorder),
                                ),
                                child: Text('改工作区',
                                    style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: c.warning)),
                              ),
                            ],
                          ],
                        ),
                        if (cmd.description.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 3),
                          Text(cmd.description,
                              style: TextStyle(fontSize: 11.5, height: 1.35, color: c.textSecondary)),
                        ],
                        // 上次运行的耗时/退出码放在行内：不看输出也能一眼看出
                        // "这条跑过没有、贵不贵、成没成"。
                        if (result != null) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            result.ok
                                ? '上次运行 · 耗时 ${_fmtDuration(result.durationMs)}'
                                    ' · ${result.exitCode == null ? '退出码未知' : '退出码 ${result.exitCode}'}'
                                : '上次运行失败 · ${result.error.isEmpty ? '请求失败' : result.error}',
                            style: TextStyle(fontSize: 10.5, color: c.textTertiary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: running
                        ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.play_arrow_rounded, size: 18, color: anyRunning ? c.textTertiary : c.accent),
                  ),
                ],
              ),
            ),
          ),
          if (running)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Text('运行中…（白名单命令也会真实跑满整个执行时间）',
                  style: TextStyle(fontSize: 11, color: c.textSecondary)),
            ),
          if (result != null) _buildResult(cmd, result, expanded),
        ],
      ),
    );
  }

  Widget _buildResult(QuickCommandInfo cmd, QuickCommandResult r, bool expanded) {
    final c = context.c;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: c.surfaceMuted,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: _statusLine(r)),
              InkWell(
                onTap: () => _toggle(cmd.id),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      size: 18, color: c.textTertiary),
                ),
              ),
            ],
          ),
          if (expanded) ...<Widget>[
            if (r.timedOut) ...<Widget>[
              const SizedBox(height: 6),
              _noticeBox(context, '命令超时了，网关把它掐断 —— 下面是已经收到的部分输出，后面的没有跑完。',
                  warning: true, icon: Icons.timer_off_outlined),
            ],
            if (r.truncated) ...<Widget>[
              const SizedBox(height: 6),
              _noticeBox(context, '输出太长，网关只回了前面一段。', warning: true, icon: Icons.content_cut_rounded),
            ],
            const SizedBox(height: 8),
            if (!r.ok)
              // ok == false 是"请求根本没成功"（没会话 / 鉴权失败 / 命令不存在），
              // 与"跑完了但退出码非零"是两件事，不能混成同一个红条。
              _hint(context, '这次请求没有到达命令执行阶段，所以没有输出可看。')
            else if (r.combined.trim().isEmpty)
              _hint(context, '命令没有产生任何输出。')
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: c.border),
                ),
                child: SelectableText(
                  r.combined,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.4, color: c.textSecondary),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 结果状态行。非零退出码在这里是一条**结果**，不是崩溃。
  Widget _statusLine(QuickCommandResult r) {
    final c = context.c;

    if (!r.ok) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: 15, color: c.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              r.error.isEmpty ? '请求失败' : r.error,
              style: TextStyle(fontSize: 12, height: 1.35, color: c.danger),
            ),
          ),
        ],
      );
    }

    final failed = r.failed;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            // 非零退出码用警告色而不是危险色：`git status` 在非仓库目录里就是 128，
            // 它的 stderr 才是用户真正要读的东西 —— 把它画成"崩溃"会误导。
            color: failed ? c.warningBadgeSurface : c.successSurface,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: failed ? c.warningBorder : c.border),
          ),
          child: Text(
            r.exitCode == null ? '退出码未知' : '退出码 ${r.exitCode}',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.bold,
              color: failed ? c.warning : c.success,
            ),
          ),
        ),
        Text('耗时 ${_fmtDuration(r.durationMs)}', style: TextStyle(fontSize: 11, color: c.textTertiary)),
        if (r.timedOut)
          Text('已超时', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: c.warning)),
        if (r.truncated)
          Text('输出已截断', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: c.warning)),
      ],
    );
  }
}

// =====================================================================
// 页签二：文件（只读工作区浏览器）
// =====================================================================

class _FilesTab extends StatefulWidget {
  const _FilesTab();

  @override
  State<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<_FilesTab> {
  /// 相对工作区根的路径；空串就是根目录（网关的约定）。
  String _path = '';

  /// null = 还没取到 / 正在换目录。区分"取不到"与"这个目录是空的"。
  FsListing? _listing;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final dsh = Provider.of<DshService>(context, listen: false);
    // 记下这次请求对应的路径：快速连点目录时两个请求可能交错返回，只让"当前选中
    // 的那个路径"的结果落地，否则会出现"面包屑是 a/b、列出来的是 a 的内容"。
    final requested = _path;
    final listing = await dsh.fsList(requested);
    if (!mounted) return;
    if (requested != _path) return;
    setState(() {
      _listing = listing;
      _loading = false;
    });
  }

  Future<void> _go(String relPath) async {
    setState(() {
      _path = relPath;
      // 换目录时清空旧清单：否则新面包屑配旧内容会有一瞬间的不一致，
      // 而"看着像内容已经换了"比转圈更危险。
      _listing = null;
      _loading = true;
    });
    await _fetch();
  }

  Future<void> _retry() async {
    setState(() => _loading = true);
    await _fetch();
  }

  Future<void> _openPreview(String relPath) async {
    final dsh = Provider.of<DshService>(context, listen: false);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _FilePreviewSheet(path: relPath, read: dsh.fsRead),
    );
  }

  /// 子项路径：根目录下不带前导斜杠（网关的 relPath 约定就是这样）。
  String _join(String name) => _path.isEmpty ? name : '$_path/$name';

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    return Column(
      children: <Widget>[
        _breadcrumb(listing),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _fetch,
            child: _body(listing),
          ),
        ),
      ],
    );
  }

  Widget _breadcrumb(FsListing? listing) {
    final c = context.c;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.folder_open_rounded, size: 14, color: c.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _path.isEmpty ? '工作区根目录' : _path,
              style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: c.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text('只读', style: TextStyle(fontSize: 11, color: c.textTertiary)),
        ],
      ),
    );
  }

  Widget _body(FsListing? listing) {
    // 加载中：整屏转圈，而不是给一个空列表。
    if (listing == null) {
      if (_loading) {
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const <Widget>[
            SizedBox(height: 140),
            Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        );
      }
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _noticeBox(context, '还没有取到目录内容。', warning: true, icon: Icons.help_outline_rounded),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: _retryButton(_retry)),
        ],
      );
    }

    // 读取失败：明确显示网关给的原因 + 重试。**绝不**降级成"空目录"。
    if (!listing.ok) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _noticeBox(
            context,
            listing.error.isEmpty
                ? '读取目录失败。这**不是**"目录为空"，而是这次没读到。'
                : '读取目录失败：${listing.error}',
            warning: true,
            icon: Icons.error_outline_rounded,
          ),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: _retryButton(_retry)),
        ],
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      children: <Widget>[
        if (listing.truncated) ...<Widget>[
          _noticeBox(
            context,
            '仅显示前 ${listing.entries.length} 项，共 ${listing.total} 项 —— 网关对单次列目录有条数上限。',
            warning: true,
            icon: Icons.visibility_outlined,
          ),
          const SizedBox(height: 6),
        ],
        // `parent == null` 才是"没有上级"；`parent == ''` 表示上一级就是根，
        // 此时这一行要把用户送回根目录。
        if (listing.parent != null) ...<Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _go(listing.parent!),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              child: Row(
                children: <Widget>[
                  Icon(Icons.drive_file_move_outline, size: 18, color: context.c.textSecondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('..',
                        style: TextStyle(
                            fontSize: 13, fontFamily: 'monospace', color: context.c.textPrimary)),
                  ),
                  Text(
                    listing.parent!.isEmpty ? '回到根目录' : '返回上级',
                    style: TextStyle(fontSize: 11, color: context.c.textTertiary),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: context.c.border),
        ],
        if (listing.entries.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: _hint(context, '这个目录是空的（网关确认读到了它，里面确实没有条目）。'),
          )
        else
          for (final entry in listing.entries) _entryRow(entry),
      ],
    );
  }

  Widget _entryRow(FsEntry entry) {
    final c = context.c;
    final isDir = entry.isDir;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: isDir ? () => _go(_join(entry.name)) : () => _openPreview(_join(entry.name)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(
              isDir ? Icons.folder_rounded : Icons.description_outlined,
              size: 18,
              color: isDir ? c.accent : c.textTertiary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                entry.name,
                style: TextStyle(fontSize: 13, color: c.textPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            // sizeLabel 对目录和未知大小返回空串，此时不占位（否则右边会多一截空白）。
            if (entry.sizeLabel.isNotEmpty)
              Text(entry.sizeLabel, style: TextStyle(fontSize: 11, color: c.textTertiary)),
            const SizedBox(width: 4),
            Icon(isDir ? Icons.chevron_right_rounded : Icons.visibility_outlined, size: 16, color: c.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// 文件预览弹层。自包含：数据靠 `read` 传进来，重试不依赖宿主。
class _FilePreviewSheet extends StatefulWidget {
  const _FilePreviewSheet({required this.path, required this.read});

  final String path;
  final Future<TextFileContent> Function(String relPath) read;

  @override
  State<_FilePreviewSheet> createState() => _FilePreviewSheetState();
}

class _FilePreviewSheetState extends State<_FilePreviewSheet> {
  TextFileContent? _result;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final result = await widget.read(widget.path);
    if (!mounted) return;
    setState(() {
      _result = result;
      _loading = false;
    });
  }

  Future<void> _retry() async {
    setState(() {
      _loading = true;
      _result = null;
    });
    await _fetch();
  }

  Future<void> _copy(String content) async {
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('已复制全文'),
      duration: Duration(milliseconds: 900),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final result = _result;
    final maxHeight = MediaQuery.of(context).size.height * 0.88;
    final content = result?.content;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.path,
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'monospace', color: c.textPrimary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // 二进制文件没有可复制的文本，按钮不给（而不是给一个复制 air 的按钮）。
                  if (content != null && content.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => _copy(content),
                      icon: Icon(Icons.copy_rounded, size: 14, color: c.textSecondary),
                      label: Text('复制', style: TextStyle(fontSize: 12, color: c.textSecondary)),
                    ),
                  IconButton(
                    tooltip: '关闭',
                    icon: Icon(Icons.close_rounded, size: 20, color: c.textSecondary),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.border),
            Flexible(child: _buildBody(result)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(TextFileContent? result) {
    final c = context.c;

    if (result == null) {
      if (_loading) {
        return const Padding(
          padding: EdgeInsets.all(30),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      }
      return ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _noticeBox(context, '还没有取到文件内容。', warning: true, icon: Icons.help_outline_rounded),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: _retryButton(_retry)),
        ],
      );
    }

    if (!result.ok) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _noticeBox(
            context,
            result.error.isEmpty ? '读取文件失败。' : '读取文件失败：${result.error}',
            warning: true,
            icon: Icons.error_outline_rounded,
          ),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: _retryButton(_retry)),
        ],
      );
    }

    // 二进制：只说明，不渲染。把一段 PNG 当文本画出来只会是一屏乱码。
    if (result.binary) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _noticeBox(
            context,
            result.note.isNotEmpty
                ? result.note
                : '这是二进制文件，不能当文本预览（不会尝试渲染它）。',
            warning: true,
            icon: Icons.data_object_rounded,
          ),
          const SizedBox(height: 8),
          _hint(context, '大小 ${_fmtBytes(result.size)}。需要看内容的话，请在电脑端打开它。'),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: _retryButton(_retry)),
        ],
      );
    }

    final content = result.content;
    if (content == null) {
      // ok 为真但没有 content：当成"空文件"如实说，而不是渲染一片空白。
      return ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _hint(context, '这个文件没有可显示的内容（空文件，或网关没有返回正文）。大小 ${_fmtBytes(result.size)}。'),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (result.truncated)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: _noticeBox(
              context,
              '只显示文件的前一部分（完整大小 ${_fmtBytes(result.size)}，网关对单次读取有上限）。要全文请到电脑端打开。',
              warning: true,
              icon: Icons.content_cut_rounded,
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
            child: result.isMarkdown
                // Markdown 走 SafeMarkdown：它负责补齐悬空代码围栏、转义孤立尖括号，
                // 这两件事都会让渲染器直接抛异常。
                ? SafeMarkdown(data: content)
                : SelectableText(
                    content,
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.45, color: c.textSecondary),
                  ),
          ),
        ),
      ],
    );
  }
}

// =====================================================================
// 页签三：目标
// =====================================================================

class _GoalsTab extends StatefulWidget {
  const _GoalsTab();

  @override
  State<_GoalsTab> createState() => _GoalsTabState();
}

class _GoalsTabState extends State<_GoalsTab> {
  final TextEditingController _objectiveCtrl = TextEditingController();
  final TextEditingController _roundsCtrl = TextEditingController();

  /// null = 取不到（未连接 / 网关不可达 / 解析失败）。与"没有目标"
  /// （`present == false`）是两件事，界面必须分开。
  GoalBoard? _board;
  bool _loading = true;

  String? _formError;
  bool _submitting = false;

  /// 'pause' | 'resume' | 'complete' | 'edit' 或 null。非空时全部操作按钮禁用：
  /// 这些写都是 CAS 的，两个并发操作里必有一个拿着旧 revision，注定失败。
  String? _busyAction;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _objectiveCtrl.dispose();
    _roundsCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final dsh = Provider.of<DshService>(context, listen: false);
    final board = await dsh.fetchGoalBoard();
    if (!mounted) return;
    setState(() {
      _board = board;
      _loading = false;
    });
  }

  Future<void> _retry() async {
    setState(() => _loading = true);
    await _fetch();
  }

  Future<void> _submitCreate() async {
    final dsh = Provider.of<DshService>(context, listen: false);
    final objective = _objectiveCtrl.text.trim();
    if (objective.isEmpty) {
      setState(() => _formError = '目标描述不能为空');
      return;
    }
    final roundsText = _roundsCtrl.text.trim();
    int? rounds;
    if (roundsText.isNotEmpty) {
      rounds = int.tryParse(roundsText);
      if (rounds == null || rounds <= 0) {
        // 本地先拦一次：服务端也会拒，但让用户白等一次往返没有意义。
        setState(() => _formError = '轮数上限要填正整数，留空表示用引擎默认值');
        return;
      }
    }

    setState(() {
      _submitting = true;
      _formError = null;
    });
    final error = await dsh.createGoal(objective, maxGoalRounds: rounds);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _submitting = false;
        _formError = error;
      });
      return;
    }
    // 成功：清空表单并重新拉一次。不清空的话，用户会以为"提交没生效"而再点一次，
    // 那就变成两个目标了。
    _objectiveCtrl.clear();
    _roundsCtrl.clear();
    setState(() => _submitting = false);
    await _fetch();
  }

  Future<void> _control(GoalBoard board, String action, String label) async {
    final dsh = Provider.of<DshService>(context, listen: false);
    final revision = board.revision;
    if (board.goalId.isEmpty || revision == null) return; // 按钮只在 operable 时出现

    setState(() => _busyAction = action);
    final ok = await dsh.controlGoal(action, goalId: board.goalId, revision: revision);
    if (!mounted) return;
    setState(() => _busyAction = null);

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('引擎拒绝了「$label」—— 目标可能已被模型侧改动，revision 已过期，刷新后重试。'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    await _fetch();
  }

  Future<void> _edit(GoalBoard board) async {
    final dsh = Provider.of<DshService>(context, listen: false);
    final revision = board.revision;
    if (board.goalId.isEmpty || revision == null) return;

    final input = await showDialog<({String objective, int? maxGoalRounds})>(
      context: context,
      builder: (_) => _GoalEditDialog(objective: board.objective, maxGoalRounds: board.maxGoalRounds),
    );
    if (input == null || !mounted) return;

    setState(() => _busyAction = 'edit');
    final error = await dsh.editGoal(
      goalId: board.goalId,
      revision: revision,
      objective: input.objective,
      maxGoalRounds: input.maxGoalRounds,
    );
    if (!mounted) return;
    setState(() => _busyAction = null);

    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('编辑失败：$error'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    // 编辑成功会让 revision +1，页面上的 ref 已经过期 —— 必须重取，否则下一次
    // 暂停/继续会拿着旧 revision 打回去。
    await _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final board = _board;

    if (board == null) {
      if (_loading) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _noticeBox(
            context,
            '读不到目标状态 —— 可能是没有连接会话，也可能是网关暂时不可达。这只说明"没读到"，不代表这个会话没有目标。',
            warning: true,
            icon: Icons.help_outline_rounded,
          ),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: _retryButton(_retry)),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: _fetch,
      child: board.present ? _buildBoard(board) : _buildCreateForm(),
    );
  }

  // ------------------------------------------------------------ 有目标 ----

  Widget _buildBoard(GoalBoard board) {
    final c = context.c;
    final progress = board.progress;
    final blockedReason = board.blockedReason;
    final blockedCode = board.blockedCode;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
      children: <Widget>[
        // 缓存快照必须自己先说清楚，且要说在数字**前面**：用户先读到的是这一段。
        if (board.isSnapshot) ...<Widget>[
          _noticeBox(
            context,
            '这些数字是缓存快照（source: cache）：该会话已不在引擎内存里，显示的是最后一次上报的值，不是实时状态。'
            '任何"它现在在跑第几轮"的判断都不该基于这一屏。',
            warning: true,
            icon: Icons.history_rounded,
          ),
          const SizedBox(height: 12),
        ],
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      board.objective.isEmpty ? '（引擎没有上报目标描述）' : board.objective,
                      style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, height: 1.35, color: c.textPrimary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: c.accentSurface,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: c.border),
                    ),
                    child: Text(board.phaseLabel,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c.accent)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Text('轮次', style: TextStyle(fontSize: 12, color: c.textSecondary)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      // roundsLabel 为 null = 引擎没给轮数，显示「—」而不是 0
                      // —— 0 会被读成"一轮都没跑"。
                      board.roundsLabel ?? '—',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.textPrimary),
                    ),
                  ),
                  if (board.roundsRemaining != null)
                    Text('剩余 ${board.roundsRemaining} 轮', style: TextStyle(fontSize: 11, color: c.textTertiary)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Text('进度', style: TextStyle(fontSize: 12, color: c.textSecondary)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: progress == null
                        ? Text('—', style: TextStyle(fontSize: 12.5, color: c.textTertiary))
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 5,
                              backgroundColor: c.surfaceMuted,
                              valueColor: AlwaysStoppedAnimation<Color>(c.accent),
                            ),
                          ),
                  ),
                  if (progress != null) ...<Widget>[
                    const SizedBox(width: 8),
                    Text('${(progress * 100).round()}%', style: TextStyle(fontSize: 11, color: c.textTertiary)),
                  ],
                ],
              ),
              if (blockedReason != null) ...<Widget>[
                const SizedBox(height: 12),
                _noticeBox(
                  context,
                  '受阻：$blockedReason${blockedCode == null || blockedCode.isEmpty ? '' : '（$blockedCode）'}',
                  warning: true,
                  icon: Icons.report_problem_outlined,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (board.operable)
          Row(
            children: <Widget>[
              _actionButton('暂停', 'pause', board),
              const SizedBox(width: 8),
              _actionButton('继续', 'resume', board),
              const SizedBox(width: 8),
              _actionButton('完成', 'complete', board),
              const Spacer(),
              _actionButton('编辑', 'edit', board),
            ],
          )
        else
          // 缺 ref 就不给操作。宁可少三个按钮，也不要让用户点了之后收到一个
          // "缺少目标 ref" 的失败 —— 那个失败是我们自己凭空造出来的。
          _noticeBox(
            context,
            '引擎没有上报这个目标的操作 ref（goalId / revision），所以暂停、继续、完成与编辑都不提供。'
            '没有 ref 的写请求只能靠猜一个 revision 发出去，那不该由界面决定。',
            warning: true,
            icon: Icons.help_outline_rounded,
          ),
        if (!board.isSnapshot) ...<Widget>[
          const SizedBox(height: 10),
          _hint(context, '轮次与进度来自引擎的实时上报（source: live）。'),
        ],
      ],
    );
  }

  Widget _actionButton(String label, String action, GoalBoard board) {
    final c = context.c;
    final busy = _busyAction == action;
    // 有操作在飞时把其余按钮一起禁用：见 _busyAction 的说明。
    final enabled = _busyAction == null;
    return TextButton(
      onPressed: enabled
          ? () {
              if (action == 'edit') {
                _edit(board);
              } else {
                _control(board, action, label);
              }
            }
          : null,
      style: TextButton.styleFrom(
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: c.border),
        ),
      ),
      child: busy
          ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
          : Text(label, style: TextStyle(fontSize: 12, color: enabled ? c.textPrimary : c.textTertiary)),
    );
  }

  // ------------------------------------------------------------ 无目标 ----

  Widget _buildCreateForm() {
    final c = context.c;
    final formError = _formError;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.flag_outlined, size: 16, color: c.textSecondary),
                  const SizedBox(width: 6),
                  Text('这个会话还没有目标',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.textPrimary)),
                ],
              ),
              const SizedBox(height: 6),
              _hint(context, '建目标后，引擎会按轮推进并回报进度；手机上暂停、继续、完成都不会占一轮对话。'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _objectiveCtrl,
          minLines: 3,
          maxLines: 6,
          decoration: InputDecoration(
            labelText: '目标描述',
            hintText: '例如：把 lib/views 下的测试补齐，并保证 flutter analyze 零错误',
            alignLabelWithHint: true,
            border: const OutlineInputBorder(),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: c.accent)),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _roundsCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: '轮数上限（可选）',
            hintText: '留空 = 用引擎默认值',
            border: const OutlineInputBorder(),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: c.accent)),
          ),
        ),
        if (formError != null) ...<Widget>[
          const SizedBox(height: 12),
          _noticeBox(context, formError, warning: true, icon: Icons.error_outline_rounded),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _submitting ? null : _submitCreate,
          icon: _submitting
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.add_rounded, size: 18),
          label: Text(_submitting ? '创建中…' : '创建目标'),
        ),
      ],
    );
  }
}

/// 编辑目标的对话框。它自己校验，失败就地显示，不关窗把用户填的字丢掉。
///
/// 返回 `null`（取消）或一条 record —— 用 record 而不是把校验也放回页面，
/// 是为了让"哪条输入不合法"这件事只在一个地方判断。
class _GoalEditDialog extends StatefulWidget {
  const _GoalEditDialog({required this.objective, required this.maxGoalRounds});

  final String objective;
  final int? maxGoalRounds;

  @override
  State<_GoalEditDialog> createState() => _GoalEditDialogState();
}

class _GoalEditDialogState extends State<_GoalEditDialog> {
  final TextEditingController _objectiveCtrl = TextEditingController();
  final TextEditingController _roundsCtrl = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _objectiveCtrl.text = widget.objective;
    _roundsCtrl.text = widget.maxGoalRounds?.toString() ?? '';
  }

  @override
  void dispose() {
    _objectiveCtrl.dispose();
    _roundsCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final objective = _objectiveCtrl.text.trim();
    if (objective.isEmpty) {
      setState(() => _error = '目标描述不能为空');
      return;
    }
    final roundsText = _roundsCtrl.text.trim();
    int? rounds;
    if (roundsText.isNotEmpty) {
      rounds = int.tryParse(roundsText);
      if (rounds == null || rounds <= 0) {
        setState(() => _error = '轮数上限要填正整数，或留空');
        return;
      }
    }
    Navigator.pop(context, (objective: objective, maxGoalRounds: rounds));
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return AlertDialog(
      title: const Text('编辑目标'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 为什么必须说这句：编辑是 CAS 写，成功一次 revision 就 +1，
            // 别的屏幕上拿着旧 revision 的按钮会因此全部失效。
            _hint(context, '保存后引擎会把该目标的 revision +1；其它拿着旧 revision 的界面（包括本页）会重新拉一次。'),
            const SizedBox(height: 12),
            TextField(
              controller: _objectiveCtrl,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(labelText: '目标描述', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _roundsCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: '轮数上限', border: OutlineInputBorder()),
            ),
            if (error != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(error, style: TextStyle(fontSize: 12, color: context.c.danger)),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

// =====================================================================
// 页签四：分支
// =====================================================================

class _ForksTab extends StatefulWidget {
  const _ForksTab();

  @override
  State<_ForksTab> createState() => _ForksTabState();
}

class _ForksTabState extends State<_ForksTab> {
  /// null = 取不到（网关不可达 / 未连接）。空列表也可能是"没有已结束的回合"，
  /// 但服务层不区分这两者，所以文案必须同时承认两种可能。
  List<SessionCheckpoint>? _items;
  bool _loading = true;

  int? _busySeq;
  bool _busyWhole = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final dsh = Provider.of<DshService>(context, listen: false);
    final items = await dsh.fetchCheckpoints();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _retry() async {
    setState(() => _loading = true);
    await _fetch();
  }

  Future<void> _forkAt(SessionCheckpoint cp) async {
    final dsh = Provider.of<DshService>(context, listen: false);
    final seq = cp.seq;
    if (seq == null) return; // 列表已过滤 null seq，这里只是防御

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从这里分支出新会话？'),
        content: Text('将从该轮结束处分支出一个新会话（${cp.title}）。'
            '原会话保持原样不动，新会话会带上到这一轮为止的完整历史。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('分支')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busySeq = seq);
    final outcome = await dsh.forkSession(atSeq: seq);
    if (!mounted) return;
    setState(() => _busySeq = null);
    await _reportFork(outcome);
  }

  Future<void> _forkWhole() async {
    final dsh = Provider.of<DshService>(context, listen: false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('整段分支？'),
        content: const Text('不指定分叉点，把当前会话到此刻为止的完整历史复制成一个新会话。原会话不动。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('分支')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyWhole = true);
    final outcome = await dsh.forkSession();
    if (!mounted) return;
    setState(() => _busyWhole = false);
    await _reportFork(outcome);
  }

  /// 统一的收尾：成功给新会话 id + 复制，失败把引擎的原话摊开。
  Future<void> _reportFork(ForkOutcome outcome) async {
    if (!mounted) return;

    if (!outcome.ok) {
      // 409 `fork-unavailable` 是竞态（挑的那一刻该轮还没结束），不是用户填错了东西，
      // 所以要说清"该轮还没结束"，而不是丢一句笼统的失败。
      final message = outcome.unavailable
          ? '该轮还没有结束，引擎拒绝从这里分支（fork-unavailable）。等这一轮跑完再选它。'
          : (outcome.error.isEmpty ? '分支失败，引擎没有给出原因。' : '分支失败：${outcome.error}');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    final sessionId = outcome.sessionId;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('已分支出新会话'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('新会话已创建。在会话列表里打开它就能从这里继续往下走。'),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: context.c.surfaceMuted,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: context.c.border),
              ),
              child: SelectableText(
                sessionId,
                style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: context.c.textPrimary),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: sessionId));
              if (!mounted) return;
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('新会话 id 已复制'),
                duration: Duration(milliseconds: 900),
                behavior: SnackBarBehavior.floating,
              ));
            },
            icon: Icon(Icons.copy_rounded, size: 15, color: context.c.textSecondary),
            label: Text('复制', style: TextStyle(fontSize: 12.5, color: context.c.textSecondary)),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;

    if (items == null) {
      if (_loading) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _noticeBox(context, '还没有取到检查点。', warning: true, icon: Icons.help_outline_rounded),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: _retryButton(_retry)),
        ],
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: _hint(context, '每个正常结束的回合都是一个可分叉点。检查点按新到旧排列；新会话会带上到该轮为止的历史，原会话不变。'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              // 整段分支不需要任何检查点，所以即使列表为空也保留这个入口。
              onPressed: (_busyWhole || _busySeq != null) ? null : _forkWhole,
              icon: _busyWhole
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.call_split_rounded, size: 16),
              label: const Text('整段分支'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          _noticeBox(
            context,
            '读不到任何检查点 —— 可能是这个会话还没有正常结束的回合，也可能是网关暂时不可达。重试一次再判断，别把它当成"这个会话不能分支"。',
            warning: true,
            icon: Icons.help_outline_rounded,
          )
        else
          for (final cp in items) _row(cp),
      ],
    );
  }

  Widget _row(SessionCheckpoint cp) {
    final c = context.c;
    final seq = cp.seq;
    final forkable = cp.forkable && seq != null;
    final busy = seq != null && _busySeq == seq;
    final blockReason = cp.blockReason;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        // 不可分支的行**不给 onTap**：引擎对未正常结束的轮次一定回 409，
        // 让用户点出一个注定失败的请求，比直接禁用更糟。
        onTap: (forkable && _busySeq == null && !_busyWhole) ? () => _forkAt(cp) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      cp.title,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: forkable ? c.textPrimary : c.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      cp.label.isEmpty ? '（这一轮没有记录用户输入）' : cp.label,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, height: 1.35, color: forkable ? c.textSecondary : c.textTertiary),
                    ),
                    if (!forkable) ...<Widget>[
                      const SizedBox(height: 5),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(Icons.block_rounded, size: 13, color: c.warning),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              blockReason ?? '该轮不可分支',
                              style: TextStyle(fontSize: 11.5, color: c.warning),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: busy
                    ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(
                        forkable ? Icons.call_split_rounded : Icons.lock_outline_rounded,
                        size: 16,
                        color: forkable ? c.accent : c.textTertiary,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// 全屏共用的小件
// =====================================================================

/// 说明性文字。所有"为什么看不到"的句子都走这里，保证字号/行距一致。
Widget _hint(BuildContext context, String text) => Text(
      text,
      style: TextStyle(fontSize: 11.5, height: 1.4, color: context.c.textTertiary),
    );

/// 带图标的一行提示框。warning = 警告色，否则用品牌浅蓝底。
Widget _noticeBox(
  BuildContext context,
  String text, {
  bool warning = false,
  IconData icon = Icons.info_outline_rounded,
}) {
  final c = context.c;
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: warning ? c.warningSurface : c.accentSurface,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: warning ? c.warningBorder : c.border),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 15, color: warning ? c.warning : c.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, height: 1.38, color: warning ? c.warning : c.textSecondary),
          ),
        ),
      ],
    ),
  );
}

Widget _retryButton(Future<void> Function() onRetry, {String label = '重试'}) => OutlinedButton.icon(
      onPressed: () => onRetry(),
      icon: const Icon(Icons.refresh_rounded, size: 16),
      label: Text(label),
    );

Widget _errorPane(BuildContext context, {required String message, required Future<void> Function() onRetry}) {
  return ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.all(16),
    children: <Widget>[
      _noticeBox(context, message, warning: true, icon: Icons.error_outline_rounded),
      const SizedBox(height: 12),
      Align(alignment: Alignment.centerLeft, child: _retryButton(onRetry)),
    ],
  );
}

/// 耗时：一秒钟以下给毫秒（`git status` 常常几十毫秒，写成 0.1 s 反而丢信息）。
String _fmtDuration(int? ms) {
  if (ms == null) return '—';
  if (ms < 1000) return '$ms ms';
  return '${(ms / 1000).toStringAsFixed(1)} s';
}

/// 字节数。未知大小显示「—」而不是 0 —— 0 会被读成"空文件"。
String _fmtBytes(int? bytes) {
  if (bytes == null) return '—';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
