import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/dsh_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// 「Runbook」——把电脑上写好的排障命令一键搬到手机上（v1.35 / 3.2）。
///
/// ## 为什么不是"手机终端"
///
/// 手机上真的打开一个终端去排障是不现实的：软键盘打不出管道、滚屏看不清、
/// 命令拼错还不敢确认。真正高频的动作只有几个（看日志尾、看状态、重启、回滚），
/// 它们适合被**预先写成一条条清单**，手机端只需要选和确认。
///
/// ## 安全边界
///
/// 命令在网关侧执行，白名单与"不许 shell 元字符"都在网关（runbook.mjs）判定。
/// 本页只负责两件事：高危条目**必须弹窗展示命令原文**再确认；结果如实展示
/// 退出码与输出尾部（不美化失败）。
///
/// ## 为什么现在是「会话信息里的一个 tab」
///
/// [move 2026-10-21] 这个功能原本挂在「设置 → 运维」下。问题是**命令要在哪个目录
/// 跑**：网关的规则是「会话给了 cwd 就用会话的，否则回落到 ~/.dsh」。设置页那条
/// 入口没有会话上下文，于是 `git log` / `git status` 一律 `fatal: not a git
/// repository`（真机实测 exit 128）—— 而默认模板三条里两条是 git。
///
/// 搬进会话信息面板后，[sessionId] 由宿主带上，cwd 就是那个会话的工作区，命令
/// 落在他正在干活的那个仓库里。这也是它本来该在的位置：runbook 是"对我这个会话
/// 的工程跑一条命令"，不是全局运维。
class RunbookView extends StatefulWidget {
  const RunbookView({super.key, this.sessionId, this.embedded = false});

  /// 当前会话 id。网关用它解析 cwd（`readSessionCwd`）；为空时回落到 `~/.dsh`，
  /// git 类命令会失败 —— 所以嵌入模式下宿主必须传。
  final String? sessionId;

  /// 嵌入模式：不画自己的 Scaffold/AppBar，只出列表本体（给会话信息面板当 tab）。
  final bool embedded;

  @override
  State<RunbookView> createState() => _RunbookViewState();
}

class _RunbookViewState extends State<RunbookView> {
  bool _loading = true;
  String? _error;
  String? _runningId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final dsh = Provider.of<DshService>(context, listen: false);
    final err = await dsh.refreshRunbooks();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = err;
    });
  }

  Future<void> _run(Map<String, dynamic> item) async {
    final dsh = Provider.of<DshService>(context, listen: false);
    final name = item['name']?.toString() ?? '命令';
    final command = item['command']?.toString() ?? '';
    final needsConfirm = item['confirmRequired'] == true || item['danger'] == 'high';

    if (needsConfirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认执行？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('这条命令被标记为危险操作，将在电脑上直接执行：'),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.c.surfaceMuted,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  command,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: context.c.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('执行'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _runningId = item['id']?.toString());
    final result = await dsh.runRunbookCommand(
      item['id']?.toString() ?? '',
      confirm: needsConfirm,
      // [fix 2026-10-21] 必须带会话 id：网关拿它解析 cwd，否则回落到 ~/.dsh，
      // git 类命令一律 "not a git repository"。
      sessionId: widget.sessionId,
    );
    if (!mounted) return;
    setState(() => _runningId = null);

    if (result == null) {
      setState(() => _error = '执行没有返回结果');
      return;
    }
    if (result['code'] == 'confirm-required') {
      setState(() => _error = '这条命令需要二次确认（网关没收到 confirm）');
      return;
    }
    if (result['ok'] != true) {
      setState(() => _error = result['error']?.toString() ?? '执行失败');
      return;
    }
    await _showResult(name, result);
  }

  Future<void> _showResult(String name, Map<String, dynamic> result) async {
    final output = result['outputTail']?.toString() ?? '';
    final exitCode = result['exitCode'];
    final ms = result['durationMs'];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  Text(
                    'exit $exitCode${ms != null ? ' · ${ms}ms' : ''}',
                    style: TextStyle(
                      fontSize: 12,
                      color: exitCode == 0 ? context.c.textSecondary : context.c.danger,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Flexible(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: context.c.surfaceMuted,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      output.isEmpty ? '（没有输出）' : output,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.5),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _buildBody(context);
    // [move 2026-10-21] 嵌入模式只出列表本体：会话信息面板已经提供了 Scaffold、
    // 标题栏和滚动上下文，再来一层就是双层标题。
    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: context.c.surfaceMuted,
      appBar: AppBar(
        backgroundColor: context.c.surface,
        foregroundColor: context.c.textPrimary,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text('Runbook'),
      ),
      body: body,
    );
  }

  Widget _buildBody(BuildContext context) {
    final dsh = context.watch<DshService>();
    final items = dsh.runbooks;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          widget.embedded ? 14 : 16,
          widget.embedded ? 12 : 14,
          widget.embedded ? 14 : 16,
          widget.embedded ? 12 : 28,
        ),
        children: [
          // 嵌入时这条说明压到一句：面板里空间要留给命令本身。
          Text(
            widget.embedded
                ? '命令在电脑上执行，工作目录取当前会话的工作区。'
                : '这些命令来自电脑上的 ~/.dsh/mobile-access/runbooks.yaml，改完刷新即可生效。'
                    '高危命令会先展示原文再执行。',
            style: TextStyle(
                fontSize: widget.embedded ? 11.5 : 13,
                height: 1.5,
                color: context.c.textSecondary),
          ),
          const SizedBox(height: AppSpace.m),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.m),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 12.5, color: context.c.danger, height: 1.45),
              ),
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                '还没有 Runbook。到电脑上编辑 runbooks.yaml，或在网关首次启动时使用默认模板。',
                style: TextStyle(fontSize: 13, color: context.c.textSecondary, height: 1.5),
              ),
            )
          else
            ...items.map((item) => _card(context, item)),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, Map<String, dynamic> item) {
    final id = item['id']?.toString() ?? '';
    final danger = item['danger'] == 'high';
    final running = _runningId == id;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.m),
      padding: const EdgeInsets.all(AppSpace.m),
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
              Expanded(
                child: Text(
                  item['name']?.toString() ?? '(未命名)',
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                ),
              ),
              if (danger)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: context.c.danger.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '高危',
                    style: TextStyle(fontSize: 11, color: context.c.danger, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
          if ((item['description']?.toString() ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              item['description'].toString(),
              style: TextStyle(fontSize: 12.5, color: context.c.textSecondary, height: 1.45),
            ),
          ],
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: context.c.surfaceMuted,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              item['command']?.toString() ?? '',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              key: ValueKey('runbook-run-$id'),
              onPressed: running ? null : () => _run(item),
              child: running
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('执行'),
            ),
          ),
        ],
      ),
    );
  }
}
