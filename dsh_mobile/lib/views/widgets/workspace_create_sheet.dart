import 'package:flutter/material.dart';

import '../../models/workspace.dart';
import '../../services/dsh_service.dart';
import '../../theme/app_colors.dart';


/// 新建工作区 —— **点选目录**，不再手写路径（[feat 2026-10-22]）。
///
/// ## 为什么改
///
/// 用户原话：「新建工作区目前是手写，这个要改成点选」。手写的问题不是打字慢，而是
/// **手机上根本看不见电脑的目录树**：路径要么凭记忆拼（错一层就建到别处），要么
/// 先回电脑上看一眼。点选把"记得住路径"换成"认得出来目录"。
///
/// ## 数据从哪来
///
/// 网关 `GET /api/mobile/workspaces/{roots,browse}`，只列**子目录**，范围限定在
/// 主目录 / 已登记工作区的上级 / 工作区本身 / 用到的盘。客户端不能扩面。
///
/// ## 老网关怎么办
///
/// 那两个接口是 1.15.0 才有的。探测失败（404/超时/`ok:false`）就**自动切到手动
/// 输入**，并把原因写在输入框上方 —— 宁可退化成旧行为，也不能让用户对着一个永远
/// 空着的列表发呆。
/// 取目录选择器的数据源。默认直接打网关；测试可以注入替身，从而在**不打网络**的
/// 前提下验证"点选"本身的行为（分组、下钻、上一级、提交哪个路径）。
typedef WorkspaceRootsLoader = Future<WorkspaceDirListing> Function(String? path);

Future<bool?> showWorkspaceCreateSheet(
  BuildContext context,
  DshService dsh, {
  WorkspaceRootsLoader? browse,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _WorkspaceCreateSheet(dsh: dsh, browse: browse),
    ),
  );
}

class _WorkspaceCreateSheet extends StatefulWidget {
  const _WorkspaceCreateSheet({required this.dsh, this.browse});

  final DshService dsh;

  /// null / 路径为 null = 只要起点清单。
  final WorkspaceRootsLoader? browse;

  @override
  State<_WorkspaceCreateSheet> createState() => _WorkspaceCreateSheetState();
}

class _WorkspaceCreateSheetState extends State<_WorkspaceCreateSheet> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _manualController = TextEditingController();

  bool _loadingRoots = true;
  bool _loadingDirs = false;

  /// 老网关 / 网络失败 → 退回手写路径。
  bool _manual = false;
  String _manualReason = '';

  List<WorkspaceRoot> _roots = const [];
  String? _current;
  String? _parent;
  List<WorkspaceDirEntry> _entries = const [];
  bool _truncated = false;
  String? _registeredId;
  String? _registeredTitle;

  /// 用户改过名称就不要在被选目录时覆盖它（覆盖等于把刚打的字吃了）。
  bool _titleTouched = false;

  /// 正在由代码写名称（不是用户输入）—— 见 initState 里的监听器。
  bool _settingTitle = false;

  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _titleController.addListener(() {
      // 程序自己写的值（选目录时自动带出来的名字）不算"用户改过"，否则第一次
      // 自动填充之后，再换目录名称就再也不跟着变了。
      if (_settingTitle) return;
      if (_titleController.text.trim().isNotEmpty) _titleTouched = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadRoots());
  }

  @override
  void dispose() {
    _titleController.dispose();
    _manualController.dispose();
    super.dispose();
  }

  /// 路径尾段（同时吃 `/` 与 `\`）。
  String _leafOf(String p) {
    final cleaned = p.replaceAll(RegExp(r'[\\/]+$'), '');
    if (cleaned.isEmpty) return p;
    final idx = cleaned.lastIndexOf(RegExp(r'[\\/]'));
    return idx >= 0 ? cleaned.substring(idx + 1) : cleaned;
  }

  bool _looksAbsolute(String p) =>
      p.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p);

  void _maybeFillTitle(String path) {
    if (_titleTouched) return;
    _settingTitle = true;
    _titleController.text = _leafOf(path);
    _settingTitle = false;
  }

  Future<void> _loadRoots() async {
    final loader = widget.browse;
    final listing = loader != null
        ? await loader(null)
        : await widget.dsh.fetchWorkspaceRoots();
    if (!mounted) return;
    if (!listing.ok || listing.roots.isEmpty) {
      setState(() {
        _loadingRoots = false;
        _manual = true;
        _manualReason = listing.error.isNotEmpty
            ? listing.error
            : '网关没有给出可浏览的位置';
      });
      return;
    }
    setState(() {
      _loadingRoots = false;
      _roots = listing.roots;
    });
    // 起点里第一个是"已登记工作区的上级"（最常见），直接进去列一层。
    final start = listing.roots.first.path;
    _manualController.text = start;
    await _browse(start);
  }

  Future<void> _browse(String path) async {
    setState(() {
      _loadingDirs = true;
      _error = null;
    });
    final loader = widget.browse;
    final listing = loader != null
        ? await loader(path)
        : await widget.dsh.browseWorkspaceDirs(path);
    if (!mounted) return;
    if (!listing.ok) {
      setState(() {
        _loadingDirs = false;
        // 列不出来就留着当前目录，只报原因：把用户踢回根目录会让他再点一遍。
        _error = listing.error.isNotEmpty ? listing.error : '读不了这个目录';
        if (_current == null) {
          _current = path;
          _maybeFillTitle(path);
          _manualController.text = path;
        }
      });
      return;
    }
    setState(() {
      _loadingDirs = false;
      _current = listing.path;
      _parent = listing.parent;
      _entries = listing.entries;
      _truncated = listing.truncated;
      _registeredId = listing.registeredWorkspaceId;
      _registeredTitle = listing.registeredTitle;
      if (listing.path != null) {
        _maybeFillTitle(listing.path!);
        _manualController.text = listing.path!;
      }
    });
  }

  /// 从选择器切到手写时，把当前目录带过去（不让人从零开始打）。
  void _switchToManual() {
    setState(() {
      _manual = true;
      if (_current != null) _manualController.text = _current!;
    });
  }

  Future<void> _submit() async {
    final path = (_manual ? _manualController.text : (_current ?? '')).trim();
    if (path.isEmpty) {
      setState(() => _error = _manual ? '先填一个路径' : '先选一个目录');
      return;
    }
    if (!_looksAbsolute(path)) {
      setState(() => _error = r'要电脑上的绝对路径（如 /home/me/proj 或 E:\workspace\proj）');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final failure = await widget.dsh.createWorkspace(
      path: path,
      title: _titleController.text,
    );
    if (!mounted) return;
    if (failure == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _submitting = false;
      // 失败留在弹层里：路径已经选好了，关掉等于让用户重来一遍。
      _error = failure;
    });
  }

  /// 在当前目录下新建一个子目录（"工作区目录还不存在"这个真实场景）。
  Future<void> _createSubfolder() async {
    final base = _current;
    if (base == null) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.surface,
        title: Text('在「${_leafOf(base)}」下新建文件夹',
            style: TextStyle(fontSize: 16, color: context.c.textPrimary)),
        content: TextField(
          key: const ValueKey('workspace-create-subfolder-name'),
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(counterText: '', hintText: '文件夹名'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            key: const ValueKey('workspace-create-subfolder-ok'),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('新建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    if (name.contains('/') || name.contains(r'\')) {
      setState(() => _error = '文件夹名不能带斜杠');
      return;
    }
    final sep = base.contains(r'\') ? r'\' : '/';
    final path = base.endsWith('/') || base.endsWith(r'\') ? '$base$name' : '$base$sep$name';
    setState(() {
      _submitting = true;
      _error = null;
    });
    final failure = await widget.dsh.createWorkspace(path: path, title: name);
    if (!mounted) return;
    if (failure == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _submitting = false;
      _error = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.86;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(context),
          if (_loadingRoots)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            if (_manual) _manualBody(context) else _pickerBody(context),
            _footer(context),
          ],
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('新建工作区',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: context.c.textPrimary)),
                const SizedBox(height: 2),
                Text('选一个电脑上的目录',
                    style: TextStyle(fontSize: 12, color: context.c.textSecondary)),
              ],
            ),
          ),
          if (!_loadingRoots && !_manual)
            TextButton(
              key: const ValueKey('workspace-create-manual-toggle'),
              onPressed: _switchToManual,
              child: Text('手动输入', style: TextStyle(fontSize: 12.5, color: context.c.textSecondary)),
            ),
          if (!_loadingRoots && _manual && _roots.isNotEmpty)
            TextButton(
              key: const ValueKey('workspace-create-picker-toggle'),
              onPressed: () => setState(() => _manual = false),
              child: Text('返回点选', style: TextStyle(fontSize: 12.5, color: context.c.accent)),
            ),
          IconButton(
            icon: Icon(Icons.close, size: 20, color: context.c.textTertiary),
            onPressed: () => Navigator.pop(context, false),
          ),
        ],
      ),
    );
  }

  Widget _errorBox(BuildContext context) {
    if (_error == null) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('workspace-create-error'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(18, 0, 18, 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.c.dangerSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.c.dangerBorder),
      ),
      child: Text(_error!, style: TextStyle(fontSize: 12, color: context.c.danger, height: 1.4)),
    );
  }

  Widget _pickerBody(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 起点胶囊
          SizedBox(
            height: 32,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              itemCount: _roots.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (ctx, index) {
                final root = _roots[index];
                final active = _current != null && _isSamePath(_current!, root.path);
                return InkWell(
                  key: ValueKey('workspace-create-root-${root.kind}-$index'),
                  borderRadius: BorderRadius.circular(16),
                  onTap: _loadingDirs ? null : () => _browse(root.path),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                    decoration: BoxDecoration(
                      color: active ? context.c.accent.withOpacity(0.12) : context.c.surfaceMuted,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: active ? context.c.accent : context.c.border,
                        width: active ? 1.2 : 1,
                      ),
                    ),
                    child: Text(
                      root.label,
                      style: TextStyle(
                        fontSize: 12,
                        color: active ? context.c.accent : context.c.textSecondary,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          // 当前目录 + 上一级
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('workspace-create-up'),
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  tooltip: '上一级',
                  visualDensity: VisualDensity.compact,
                  onPressed: (_parent == null || _loadingDirs) ? null : () => _browse(_parent!),
                ),
                Expanded(
                  child: Container(
                    key: const ValueKey('workspace-create-path'),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: context.c.surfaceMuted,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _current ?? '（未选）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                    ),
                  ),
                ),
                if (_loadingDirs) ...[
                  const SizedBox(width: 8),
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ],
            ),
          ),
          if (_registeredId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
              child: Text(
                '这个目录已经是工作区「${_registeredTitle ?? ''}」',
                style: TextStyle(fontSize: 11.5, color: context.c.warning),
              ),
            ),
          _errorBox(context),
          const SizedBox(height: 4),
          Expanded(
            child: _entries.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
                    child: Text(
                      _loadingDirs ? '正在读目录…' : '这个目录下没有子目录（可以直接用当前目录）',
                      style: TextStyle(fontSize: 12.5, color: context.c.textTertiary, height: 1.5),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _entries.length + (_truncated ? 1 : 0),
                    itemBuilder: (ctx, index) {
                      if (index >= _entries.length) {
                        return Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text('目录太多，只显示了前 ${_entries.length} 个',
                              style: TextStyle(fontSize: 11.5, color: context.c.textTertiary)),
                        );
                      }
                      final dir = _entries[index];
                      return ListTile(
                        key: ValueKey('workspace-create-dir-${dir.name}'),
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: Icon(Icons.folder_outlined, size: 19, color: context.c.accent),
                        title: Text(dir.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13.5, color: context.c.textPrimary)),
                        trailing: Icon(Icons.chevron_right, size: 18, color: context.c.textTertiary),
                        onTap: _loadingDirs ? null : () => _browse(dir.path),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _manualBody(BuildContext context) {
    return Expanded(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_manualReason.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '目录选择不可用（$_manualReason），可以直接填路径。',
                  style: TextStyle(fontSize: 11.5, color: context.c.textTertiary, height: 1.4),
                ),
              ),
            TextField(
              key: const ValueKey('workspace-create-manual-path'),
              controller: _manualController,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                labelText: '目录路径（电脑上的）',
                hintText: r'E:\workspace\my-project',
                hintStyle: TextStyle(
                    fontFamily: 'monospace', fontSize: 12.5, color: context.c.textTertiary),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onChanged: (val) {
                if (!_titleTouched) _titleController.text = _leafOf(val.trim());
              },
            ),
            const SizedBox(height: 6),
            Text('目录不存在时会自动创建；同一路径重复新建不会生成重复工作区。',
                style: TextStyle(fontSize: 11.5, color: context.c.textTertiary)),
            _errorBox(context),
          ],
        ),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('workspace-create-title'),
                  controller: _titleController,
                  maxLength: 40,
                  style: TextStyle(fontSize: 13.5, color: context.c.textPrimary),
                  decoration: InputDecoration(
                    labelText: '显示名称（可留空）',
                    hintText: '默认取目录名',
                    counterText: '',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              if (!_manual && _current != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  key: const ValueKey('workspace-create-subfolder'),
                  tooltip: '在当前目录下新建文件夹',
                  icon: Icon(Icons.create_new_folder_outlined,
                      size: 20, color: context.c.accent),
                  onPressed: _submitting ? null : _createSubfolder,
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('workspace-create-submit'),
              style: FilledButton.styleFrom(
                backgroundColor: context.c.accent,
                foregroundColor: context.c.onAccent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(
                      _manual
                          ? '创建工作区'
                          : '用「${_current != null ? _leafOf(_current!) : '这个目录'}」创建工作区',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isSamePath(String a, String b) =>
      a.replaceAll(r'\', '/').toLowerCase() == b.replaceAll(r'\', '/').toLowerCase();
}



