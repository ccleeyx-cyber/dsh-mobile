import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/gateway_features.dart';
import '../../models/local_snippet.dart';
import '../../services/dsh_service.dart';
import '../../services/storage_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../widgets/snippet_param_dialog.dart';
import 'settings_widgets.dart';

/// 「快捷指令」二级页（v1.27 Phase 5.4 的内容，v1.33 搬成独立页）。
///
/// ## 列表 = 本地 + 网关，一个答案
///
/// 对用户来说"我有哪些快捷指令"只有一个答案。分两块展示，他就得猜哪一份才是
/// 真正会出现在输入框里的，而两份的名字还可能撞车。顺序（本地优先）与可编辑性
/// （网关只读）都在这一层表达，模型层不掺和。
///
/// ## 为什么从设置首页搬出来
///
/// 这是一整块**内容管理**（增删改 + 排序 + 试填），不是"设置一个开关"。放在首页
/// 意味着每个只想改主题的人都要滚过一屏列表；而它自己又需要一个能放下五枚图标
/// 按钮的宽度，挤在首页里反而更紧。
///
/// ## 页面顶部必须写清"在哪里用"
///
/// 这份内容曾经最大的问题不是能不能编辑，而是**用户建完不知道去哪用**：输入框
/// 那个 ⚡ 图标没有任何文字，面板在"本地和网关都空"时又退化成只有斜杠命令。
/// 现在入口在本页顶部写死一句话，对话页的空态也给"去设置"按钮，两头都能走到。
class SnippetsView extends StatefulWidget {
  /// 测试注入口：用内存里的「网关下发条目」替代 `dsh.snippets`。
  ///
  /// 合并列表那条规则（本地在前、网关只读）只有在两边条目同时存在时才看得见，
  /// 而 `DshService.snippets` 只能由一次真实 HTTP 抓取填充 —— widget 测试不该为了
  /// 一行顺序去打真网关。生产路径永远不传它。
  @visibleForTesting
  final List<Snippet>? debugRemoteSnippets;

  const SnippetsView({super.key, this.debugRemoteSnippets});

  @override
  State<SnippetsView> createState() => _SnippetsViewState();
}

class _SnippetsViewState extends State<SnippetsView> {
  /// 只读一份内存副本：本地条目是"少数几条、一次性改完"的东西，不值得为它引
  /// 状态管理。真源在 StorageService 的 `dsh_local_snippets`，任何一次改动都
  /// **先写盘再更新内存**（写失败会留在屏幕上并如实提示）。
  List<LocalSnippet> _localSnippets = const [];
  bool _snippetsLoading = true;
  String? _localSnippetsError;

  @override
  void initState() {
    super.initState();
    _loadLocalSnippets();
  }

  Future<void> _loadLocalSnippets() async {
    var list = const <LocalSnippet>[];
    String? error;
    try {
      list = await StorageService.loadLocalSnippets();
    } on MissingPluginException {
      // 没有本地存储后端（widget 测试、或极早期启动还没挂上插件）：当成"还没有
      // 本地指令"。这不是数据丢失，写的时候会照实报错。
      error = null;
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() {
      _localSnippets = list;
      _snippetsLoading = false;
      _localSnippetsError = error;
    });
  }

  /// 写盘并同步内存。失败时保留屏幕上的改动但明说"没能存住" —— 静默把它改回去，
  /// 用户会以为点保存没反应。
  Future<void> _persistLocalSnippets(List<LocalSnippet> next) async {
    setState(() => _localSnippets = next);
    try {
      await StorageService.saveLocalSnippets(next);
      if (_localSnippetsError != null && mounted) {
        setState(() => _localSnippetsError = null);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _localSnippetsError = '$e');
      _toast('没能写入本地存储，这条改动重启后会丢');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final dsh = context.watch<DshService>();
    final remote = widget.debugRemoteSnippets ?? dsh.snippets;

    return Scaffold(
      backgroundColor: context.c.surfaceMuted,
      appBar: settingsAppBar(context, '快捷指令'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        children: [
          // 「在哪儿用」先说，因为它比"怎么编辑"更常被问。
          Container(
            key: const ValueKey('snippets-usage-hint'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.c.accent.withOpacity(0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.c.accent.withOpacity(0.22)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.bolt_rounded, size: 16, color: context.c.accent),
                const SizedBox(width: AppSpace.m),
                Expanded(
                  child: Text(
                    '在对话页的输入框底部，点 ⚡（斜杠与模板）就能选一条插入；'
                    '输入框里直接打一个 / 也会自动弹出同一个面板。'
                    '带 {参数} 的条目会先让你一屏填完再插入。',
                    style: TextStyle(fontSize: AppText.body, height: 1.4, color: context.c.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.xl),
          _buildSnippetsSection(context, remote),
        ],
      ),
    );
  }

  Widget _buildSnippetsSection(BuildContext context, List<Snippet> remote) {
    final local = _localSnippets;

    return Container(
      key: const ValueKey('settings-snippets-section'),
      padding: const EdgeInsets.all(16),
      decoration: settingsCardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '本地条目排在最前面、可改可删可排序，只存在这台手机上；'
            '网关下发的条目在这里只读（真源在服务端）。'
            '正文里的 {参数} 会在插入前让你一屏填完。',
            style: TextStyle(
              color: context.c.textSecondary,
              fontSize: AppText.body,
              height: 1.35,
            ),
          ),
          const SizedBox(height: AppSpace.l),
          if (_snippetsLoading)
            Row(
              key: const ValueKey('settings-snippets-loading'),
              children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: AppSpace.m),
                Text(
                  '正在读取本地快捷指令…',
                  style: TextStyle(fontSize: AppText.caption, color: context.c.textSecondary),
                ),
              ],
            )
          else ...[
            if (_localSnippetsError != null) ...[
              _buildSnippetsStorageWarning(context),
              const SizedBox(height: AppSpace.l),
            ],
            if (local.isEmpty && remote.isEmpty)
              Text(
                '还没有快捷指令。点下面「新增本地指令」建一条 —— 它只存在这台手机上，删网关也不会丢。',
                style: TextStyle(fontSize: AppText.body, color: context.c.textTertiary, height: 1.35),
              ),
            for (var i = 0; i < local.length; i++) _buildLocalSnippetRow(context, i),
            for (final s in remote) _buildRemoteSnippetRow(context, s),
            if (local.isNotEmpty && remote.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.s),
                child: Text(
                  '网关还没有下发过模板；这一屏的本地条目不会上传到网关。',
                  style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('snippet-add-local'),
                icon: Icon(Icons.add_rounded, size: 16, color: context.c.accent),
                label: Text(
                  '新增本地指令',
                  style: TextStyle(
                    color: context.c.accent,
                    fontSize: AppText.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => _showLocalSnippetEditor(context),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 读/写本地存储失败时的诚实提示。
  ///
  /// 它不写"出错了"了事，而是说明**已保存的内容没有被动过** —— 用户最怕的是
  /// "我的东西是不是被删了"，而这一屏确实没删。
  Widget _buildSnippetsStorageWarning(BuildContext context) {
    return Container(
      key: const ValueKey('settings-snippets-storage-warning'),
      padding: const EdgeInsets.all(AppSpace.l),
      decoration: BoxDecoration(
        color: context.c.warningSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.c.warningBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 15, color: context.c.warning),
          const SizedBox(width: AppSpace.m),
          Expanded(
            child: Text(
              '本地存储不可用：这一屏现在读不到/存不住本地指令，'
              '但已经存下的内容没有被删除，其余设置也不受影响。',
              style: TextStyle(fontSize: AppText.caption, height: 1.35, color: context.c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSnippetBadge(BuildContext context, String text, Color color, Key key) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: AppText.caption, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  /// 本地条目：整行可编辑 + 上移/下移（不做拖拽 —— 手机上一屏能放几条，拖拽的
  /// 命中成本比点两下箭头高得多）。
  Widget _buildLocalSnippetRow(BuildContext context, int index) {
    final s = _localSnippets[index];
    final placeholders = s.placeholders;
    final label = s.label.trim().isEmpty ? LocalSnippet.autoLabel(s.text) : s.label.trim();

    return Container(
      key: ValueKey('snippet-row-${s.id}'),
      margin: const EdgeInsets.only(bottom: AppSpace.m),
      padding: const EdgeInsets.fromLTRB(AppSpace.l, AppSpace.m, AppSpace.s, AppSpace.s),
      decoration: BoxDecoration(
        color: context.c.surfaceMuted,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppText.body,
                    fontWeight: FontWeight.w600,
                    color: context.c.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.m),
              _buildSnippetBadge(context, '本地', context.c.accent, ValueKey('snippet-local-badge-${s.id}')),
              if (s.tag.trim().isNotEmpty) ...[
                const SizedBox(width: AppSpace.s),
                _buildSnippetBadge(
                  context,
                  '#${s.tag.trim()}',
                  context.c.purple,
                  ValueKey('snippet-tag-${s.id}'),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            s.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppText.subhead, height: 1.35, color: context.c.textSecondary),
          ),
          if (placeholders.isNotEmpty) ...[
            const SizedBox(height: AppSpace.xs),
            Text(
              '参数：${placeholders.map((p) => '{$p}').join(' ')}',
              key: ValueKey('snippet-params-${s.id}'),
              style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
            ),
          ],
          const SizedBox(height: AppSpace.xs),
          Row(
            children: [
              Expanded(
                child: Text(
                  placeholders.isEmpty ? '' : '插入前会弹一屏填参数',
                  style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
                ),
              ),
              _snippetIconButton(
                context,
                key: ValueKey('snippet-fill-${s.id}'),
                icon: Icons.playlist_add_check_rounded,
                tooltip: '试填并复制',
                onPressed: () => _previewLocalSnippet(context, s),
              ),
              _snippetIconButton(
                context,
                key: ValueKey('snippet-up-${s.id}'),
                icon: Icons.arrow_upward_rounded,
                tooltip: '上移',
                onPressed: index == 0 ? null : () => _moveLocalSnippet(index, -1),
              ),
              _snippetIconButton(
                context,
                key: ValueKey('snippet-down-${s.id}'),
                icon: Icons.arrow_downward_rounded,
                tooltip: '下移',
                onPressed: index == _localSnippets.length - 1 ? null : () => _moveLocalSnippet(index, 1),
              ),
              _snippetIconButton(
                context,
                key: ValueKey('snippet-edit-${s.id}'),
                icon: Icons.edit_outlined,
                tooltip: '编辑',
                onPressed: () => _showLocalSnippetEditor(context, existing: s),
              ),
              _snippetIconButton(
                context,
                key: ValueKey('snippet-delete-${s.id}'),
                icon: Icons.delete_outline_rounded,
                tooltip: '删除',
                color: context.c.danger,
                onPressed: () => _deleteLocalSnippet(context, s),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 网关下发的条目：**只读**。没有编辑/删除按钮，而不是给一个点了没反应的图标。
  Widget _buildRemoteSnippetRow(BuildContext context, Snippet s) {
    final placeholders = LocalSnippet.placeholderNames(s.text);
    final label = s.label.trim().isEmpty ? LocalSnippet.autoLabel(s.text) : s.label.trim();

    return Container(
      key: ValueKey('snippet-row-gateway-${s.id}'),
      margin: const EdgeInsets.only(bottom: AppSpace.m),
      padding: const EdgeInsets.all(AppSpace.l),
      decoration: BoxDecoration(
        color: context.c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppText.body,
                    fontWeight: FontWeight.w600,
                    color: context.c.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.m),
              _buildSnippetBadge(context, '网关', context.c.textTertiary, ValueKey('snippet-gateway-badge-${s.id}')),
              const SizedBox(width: AppSpace.s),
              Icon(Icons.lock_outline_rounded, size: 13, color: context.c.textTertiary),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            s.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppText.subhead, height: 1.35, color: context.c.textSecondary),
          ),
          if (placeholders.isNotEmpty) ...[
            const SizedBox(height: AppSpace.xs),
            Text(
              '参数：${placeholders.map((p) => '{$p}').join(' ')}',
              style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _snippetIconButton(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      icon: Icon(
        icon,
        size: 16,
        color: onPressed == null ? context.c.textTertiary : (color ?? context.c.textSecondary),
      ),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      onPressed: onPressed,
    );
  }

  /// 新增/编辑本地指令。空名称回落为正文首行，空正文拒绝。
  Future<void> _showLocalSnippetEditor(BuildContext context, {LocalSnippet? existing}) async {
    final labelController = TextEditingController(text: existing?.label ?? '');
    final textController = TextEditingController(text: existing?.text ?? '');
    final tagController = TextEditingController(text: existing?.tag ?? '');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.c.border),
        ),
        title: Text(
          existing == null ? '新增本地指令' : '编辑本地指令',
          style: TextStyle(
            fontSize: AppText.title,
            fontWeight: FontWeight.bold,
            color: context.c.textPrimary,
          ),
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '只保存在这台手机上，不上传网关。正文里的 {参数} 会在插入前让你一屏填完。',
                  style: TextStyle(fontSize: AppText.caption, height: 1.35, color: context.c.textSecondary),
                ),
                const SizedBox(height: AppSpace.l),
                TextField(
                  key: const ValueKey('snippet-editor-label'),
                  controller: labelController,
                  autofocus: true,
                  maxLength: 24,
                  style: TextStyle(fontSize: AppText.body, color: context.c.textPrimary),
                  decoration: InputDecoration(
                    labelText: '名称',
                    hintText: '如：翻译成英文',
                    counterText: '',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: AppSpace.l),
                TextField(
                  key: const ValueKey('snippet-editor-text'),
                  controller: textController,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 2000,
                  keyboardType: TextInputType.multiline,
                  style: TextStyle(fontSize: AppText.body, color: context.c.textPrimary, height: 1.35),
                  decoration: InputDecoration(
                    labelText: '正文',
                    hintText: '如：把下面这段翻成{lang}：',
                    counterText: '',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                const SizedBox(height: AppSpace.l),
                TextField(
                  key: const ValueKey('snippet-editor-tag'),
                  controller: tagController,
                  maxLength: 12,
                  style: TextStyle(fontSize: AppText.body, color: context.c.textPrimary),
                  decoration: InputDecoration(
                    labelText: '分类标签（可选）',
                    hintText: '如：翻译',
                    counterText: '',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
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
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    final label = labelController.text.trim();
    final body = textController.text.trim();
    final tag = tagController.text.trim();
    labelController.dispose();
    textController.dispose();
    tagController.dispose();
    if (ok != true) return;
    if (body.isEmpty) {
      _toast('正文为空，没有保存');
      return;
    }

    final resolvedLabel = label.isEmpty ? LocalSnippet.autoLabel(body) : label;
    final next = [..._localSnippets];
    if (existing == null) {
      if (next.length >= StorageService.maxLocalSnippets) {
        _toast('本地指令最多 ${StorageService.maxLocalSnippets} 条');
        return;
      }
      next.add(LocalSnippet(
        id: 'local_${DateTime.now().microsecondsSinceEpoch}',
        label: resolvedLabel,
        text: body,
        tag: tag,
      ));
    } else {
      final i = next.indexWhere((x) => x.id == existing.id);
      if (i < 0) return;
      next[i] = next[i].copyWith(label: resolvedLabel, text: body, tag: tag);
    }
    await _persistLocalSnippets(next);
    _toast(existing == null ? '已新增本地指令' : '已保存');
  }

  Future<void> _moveLocalSnippet(int index, int delta) async {
    final j = index + delta;
    if (j < 0 || j >= _localSnippets.length) return;
    final next = [..._localSnippets];
    final moved = next.removeAt(index);
    next.insert(j, moved);
    await _persistLocalSnippets(next);
  }

  Future<void> _deleteLocalSnippet(BuildContext context, LocalSnippet snippet) async {
    final label = snippet.label.trim().isEmpty ? LocalSnippet.autoLabel(snippet.text) : snippet.label.trim();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.c.border),
        ),
        title: Text(
          '删除本地指令',
          style: TextStyle(fontSize: AppText.title, fontWeight: FontWeight.bold, color: context.c.textPrimary),
        ),
        content: Text(
          '「$label」会从这台手机上删掉；网关下发的同名条目（如果有）不受影响。',
          style: TextStyle(fontSize: AppText.body, height: 1.4, color: context.c.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: context.c.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: context.c.danger,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final next = [..._localSnippets]..removeWhere((x) => x.id == snippet.id);
    await _persistLocalSnippets(next);
    _toast('已删除');
  }

  /// 「试填」：走和输入框**同一条**参数对话框（`showSnippetParamDialog`），
  /// 填完把结果复制走。
  ///
  /// 为什么要能在这里试填：用户写 `{参数}` 时，唯一能验证"这条指令填出来是什么
  /// 样"的机会就在这一屏。
  Future<void> _previewLocalSnippet(BuildContext context, LocalSnippet snippet) async {
    final label = snippet.label.trim().isEmpty ? LocalSnippet.autoLabel(snippet.text) : snippet.label.trim();
    final rendered = await showSnippetParamDialog(context, title: label, template: snippet.text);
    if (rendered == null) return;
    await Clipboard.setData(ClipboardData(text: rendered));
    _toast(snippet.placeholders.isEmpty ? '已复制指令正文' : '已复制填好参数的正文');
  }
}
