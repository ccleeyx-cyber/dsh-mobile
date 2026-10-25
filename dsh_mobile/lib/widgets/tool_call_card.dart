import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/chat_message.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import 'tool_input_view.dart';

/// 工具执行是否「看起来失败」—— 全 App 只有这一处判定。
///
/// [ToolExecution] 没有 status 字段：引擎只把输出文本交给 App，成功/失败不是一个
/// 独立信号。所以只能读输出里的失败标记。
///
/// 判定规则刻意**偏保守**：只有明确的失败标记（非零退出码 / traceback /
/// 行首 error|failed|fatal|exception / 常见拒绝文案）才点红点。理由是误报的代价
/// 比漏报高得多 —— 一个红点会让用户去翻一段其实成功的输出，而漏报只是少一个绿点。
///
/// 这也解释了为什么它不做「退出码为 0 才绿」的反向判定：没打印退出码的工具
/// （绝大多数文件类工具）会全部变成失败态。
bool looksFailedToolOutput(ToolExecution tool) {
  if (tool.isRunning || tool.output.isEmpty) return false;
  final raw = tool.output;
  // 只看尾部：出错信息总在最后，而一条 100KB 的构建日志前面必然有大量
  // "error" 字样（像在编译自己）—— 读全文会把它判成失败。
  final tail = raw.length > 600 ? raw.substring(raw.length - 600) : raw;
  final lower = tail.toLowerCase();
  if (lower.contains('traceback (most recent call last)')) return true;
  // 非零退出码：`exit code: 1` / `exit status 2` / `exited with code=127`
  if (RegExp(r'(exit|exited)[ _a-z]*code[=: ]+[1-9]').hasMatch(lower)) {
    return true;
  }
  if (RegExp(r'^(error|failed|fatal|exception)\b', multiLine: true)
      .hasMatch(lower)) {
    return true;
  }
  const markers = [
    'permission denied',
    'command not found',
    'no such file or directory',
    'is not a git repository',
  ];
  return markers.any(lower.contains);
}

/// 单个工具的紧凑行 + 就地展开（Phase 2.3）。
///
/// 改动前：每个工具调用是一张带底色、带描边、带圆角的卡片，头部有「工具调用: xxx」
/// 前缀 + 一个 tint 徽章，高度约 40dp。一条 AI 消息挂 3 个工具就是 3 张卡片，
/// 消息流 60% 的视觉面积被工具调用占了。
///
/// 现在：**单行 28dp 紧凑条**，无底色无边框，只有一条 0.5px 底部 hairline。
/// 状态从徽章+文案降级成一个 6px 圆点（运行中=accent 呼吸 / 成功=terminalGreen /
/// 失败=danger）；摘要「N 行 · X KB」降级到展开态 —— 折叠时用户只关心「跑了什么、
/// 跑完没有」，行数在展开那一刻才有意义。
class ToolCallCard extends StatefulWidget {
  final ToolExecution tool;

  const ToolCallCard({super.key, required this.tool});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  /// 输出是否已展开全文（终端式折叠，Phase 4.4）。
  ///
  /// 与 [_expanded] 正交：先展开卡片 → 长输出仍是头 5 + 尾 5 行 → 再点省略行看全文。
  /// 两级折叠是为了让「有 800 行输出」这件事本身也有一个体积上限。
  bool _outputExpanded = false;

  /// 原始 JSON 默认不展开；只有用户明确要看协议原文时才显示。
  bool _showRawInput = false;

  /// 输入通常在一次运行内不变，但流式重建很频繁 —— 缓存解析结果，避免每条
  /// 增量都把整段 JSON 重新扫一遍。
  ToolInputView? _inputView;
  String? _inputViewSource;

  ToolInputView get _input {
    if (_inputViewSource != widget.tool.input) {
      _inputViewSource = widget.tool.input;
      _inputView = ToolInputView.parse(widget.tool.input);
    }
    return _inputView!;
  }

  final ScrollController _inputScrollController = ScrollController();
  final ScrollController _rawScrollController = ScrollController();
  final ScrollController _outputScrollController = ScrollController();

  /// 运行中状态圆点的呼吸动画。
  ///
  /// 只有一个 6px 的点在呼吸 —— 不用 `CircularProgressIndicator` 是因为后者在
  /// 单行 28dp 的条里会撑高行，也会让所有「等待态」看起来一样重。
  ///
  /// ⚠ **给后续写测试的人**：这个 controller 在 `isRunning == true` 期间是
  /// `repeat(reverse: true)`，属于永久重复动画 —— 工具处于运行态时**不能用**
  /// `pumpAndSettle()`（会一直推进到超时并抛错），必须用 `pump()`；
  /// `isRunning == false` 时不会启动动画，`pumpAndSettle()` 安全。
  late final AnimationController _pulse;

  static const double _rowHeight = 28;
  static const double _codeBoxMaxHeight = 220;

  /// 输出超过这个行数就进入终端式折叠。
  static const int _foldThreshold = 50;
  static const int _foldHeadLines = 5;
  static const int _foldTailLines = 5;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.tool.isRunning) _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    // 呼吸动画必须先停再 dispose：一直 repeat 的 controller 在 dispose 时会抛
    // "AnimationController.dispose() called more than once" 之外，更常见的是
    // 泄漏一个 Ticker。这里显式 stop。
    _pulse.stop();
    _pulse.dispose();
    _inputScrollController.dispose();
    _rawScrollController.dispose();
    _outputScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ToolCallCard oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 运行态切换时起停呼吸动画。停的时候顺手把值归到 1.0，
    // 否则圆点会停在某个中间透明度上，看起来像"半成功"。
    final wasRunning = oldWidget.tool.isRunning;
    final isRunning = widget.tool.isRunning;
    if (isRunning && !wasRunning) {
      _pulse.repeat(reverse: true);
    } else if (!isRunning && wasRunning) {
      _pulse.stop();
      _pulse.value = 1;
    }

    // Follow streaming output if expanded and user is near bottom
    if (_expanded &&
        widget.tool.output.isNotEmpty &&
        widget.tool.output != oldWidget.tool.output) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_outputScrollController.hasClients) {
          final pos = _outputScrollController.position;
          if (pos.maxScrollExtent - pos.pixels < 40) {
            _outputScrollController.jumpTo(pos.maxScrollExtent);
          }
        }
      });
    }
  }

  void _toggleExpanded() {
    HapticFeedback.selectionClick();
    setState(() {
      _expanded = !_expanded;
      if (!_expanded) _showRawInput = false;
    });
  }

  String _formatSummary(ToolExecution tool) {
    if (tool.isRunning) return '运行中...';
    if (tool.output.isEmpty) return '完成 (无输出)';
    final lines = tool.output.split('\n').length;
    final chars = tool.output.length;
    final sizeStr =
        chars >= 1024 ? '${(chars / 1024).toStringAsFixed(1)} KB' : '$chars B';
    return '$lines 行 · $sizeStr';
  }

  IconData _getToolIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('bash') ||
        lower.contains('sh') ||
        lower.contains('cmd') ||
        lower.contains('terminal') ||
        lower.contains('exec')) {
      return Icons.terminal_rounded;
    }
    if (lower.contains('read') ||
        lower.contains('cat') ||
        lower.contains('file')) {
      return Icons.description_outlined;
    }
    if (lower.contains('search') ||
        lower.contains('grep') ||
        lower.contains('find')) {
      return Icons.search_rounded;
    }
    if (lower.contains('edit') ||
        lower.contains('write') ||
        lower.contains('patch')) {
      return Icons.edit_note_rounded;
    }
    return Icons.build_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final tool = widget.tool;
    final isRunning = tool.isRunning;
    final failed = looksFailedToolOutput(tool);
    final input = _input;
    final preview = input.preview;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: _toggleExpanded,
          child: Container(
            constraints: const BoxConstraints(minHeight: _rowHeight),
            padding: EdgeInsets.symmetric(
              vertical: preview == null || preview.isEmpty ? 0 : 4,
            ),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: context.c.border.withOpacity(0.5),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _getToolIcon(tool.name),
                  size: 13,
                  color: isRunning ? context.c.accent : context.c.textSecondary,
                ),
                const SizedBox(width: AppSpace.s),
                Expanded(
                  child: _headerTitle(context, tool.name, preview),
                ),
                const SizedBox(width: AppSpace.s),
                _statusDot(isRunning: isRunning, failed: failed),
                const SizedBox(width: AppSpace.s),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 14,
                  color: context.c.textTertiary,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.m,
              AppSpace.m,
              AppSpace.m,
              AppSpace.m,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _metaRow(
                  context,
                  label: input.hasCommands
                      ? (input.commandCount > 1
                          ? '执行的命令 · ${input.commandCount} 条'
                          : '执行的命令')
                      : '输入参数',
                  copyText: input.hasCommands ? input.copyText : tool.input,
                  copyToast: input.hasCommands ? '已复制命令' : '已复制输入参数',
                  showCopy: tool.input.isNotEmpty,
                ),
                const SizedBox(height: AppSpace.xs),
                if (input.hasCommands)
                  _codeBox(
                    context,
                    controller: _inputScrollController,
                    child: _buildCommandBody(context, input),
                  )
                else
                  _codeBox(
                    context,
                    controller: _inputScrollController,
                    child: SelectableText(
                      tool.input,
                      style: _monoStyle(context),
                    ),
                  ),
                if (input.hasCommands) ...[
                  const SizedBox(height: AppSpace.xs),
                  Align(
                    alignment: Alignment.centerRight,
                    child: InkWell(
                      key: const ValueKey('tool-raw-input-toggle'),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _showRawInput = !_showRawInput);
                      },
                      borderRadius: BorderRadius.circular(AppSpace.s),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Text(
                          _showRawInput ? '隐藏原始参数' : '查看原始参数',
                          style: TextStyle(
                            fontSize: AppText.caption,
                            color: context.c.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_showRawInput) ...[
                    const SizedBox(height: AppSpace.xs),
                    _codeBox(
                      context,
                      controller: _rawScrollController,
                      child: SelectableText(
                        input.raw,
                        style: _monoStyle(context).copyWith(
                          color: context.c.textSecondary,
                          fontSize: AppText.caption,
                        ),
                      ),
                    ),
                  ],
                ],
                if (tool.output.isNotEmpty || isRunning) ...[
                  const SizedBox(height: AppSpace.m),
                  _metaRow(
                    context,
                    // 摘要（N 行 · X KB）只在这里出现 —— 折叠态不再显示它。
                    label: '执行输出 · ${_formatSummary(tool)}',
                    copyText: tool.output,
                    copyToast: '已复制执行输出',
                    showCopy: tool.output.isNotEmpty,
                  ),
                  const SizedBox(height: AppSpace.xs),
                  _codeBox(
                    context,
                    controller: _outputScrollController,
                    child: _buildOutputBody(context),
                  ),
                ],
                const SizedBox(height: AppSpace.m),
                InkWell(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _expanded = false;
                      _showRawInput = false;
                    });
                  },
                  borderRadius: BorderRadius.circular(AppSpace.s),
                  child: SizedBox(
                    width: double.infinity,
                    height: 24,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.keyboard_arrow_up_rounded,
                          size: 14,
                          color: context.c.textSecondary,
                        ),
                        const SizedBox(width: AppSpace.s),
                        Text(
                          '收起工具调用',
                          style: TextStyle(
                            fontSize: AppText.caption,
                            color: context.c.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 折叠态的两行标题：工具名 + 第一条命令/说明。
  ///
  /// 以前只有工具名，用户必须点开才能知道到底跑了什么；而一张展开后的原始
  /// JSON 卡片又长到占满一屏。命令摘要放在折叠态，恰恰是最省信息量的位置。
  Widget _headerTitle(BuildContext context, String name, String? preview) {
    final title = Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: AppText.body,
        fontWeight: FontWeight.w600,
        color: context.c.textPrimary,
      ),
    );
    if (preview == null || preview.isEmpty) return title;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        title,
        const SizedBox(height: 1),
        Text(
          preview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppText.caption,
            color: context.c.textTertiary,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  /// 6px 状态圆点。运行中呼吸（accent），成功 terminalGreen，失败 danger。
  ///
  /// key 是稳定的、**不带工具名**的三选一：测试要断言状态时不该拼装字符串，
  /// 而颜色在 widget test 里无法可靠断言（得读 RenderObject + Paint）。
  Widget _statusDot({required bool isRunning, required bool failed}) {
    final color = isRunning
        ? context.c.accent
        : (failed ? context.c.danger : context.c.terminalGreen);
    final dot = Container(
      key: ValueKey(
        isRunning
            ? 'tool-status-dot-running'
            : (failed ? 'tool-status-dot-failed' : 'tool-status-dot-done'),
      ),
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (!isRunning) return dot;
    return FadeTransition(
      opacity: _pulse.drive(Tween<double>(begin: 0.3, end: 1.0)),
      child: dot,
    );
  }

  TextStyle _monoStyle(BuildContext context) => TextStyle(
        fontSize: AppText.subhead,
        fontFamily: 'monospace',
        color: context.c.textPrimary,
        height: 1.45,
      );

  /// 输入/输出/命令的公共容器：codeBackground 底 + radius 8 + 限高 220 + 内部滚动。
  Widget _codeBox(
    BuildContext context, {
    required ScrollController controller,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: _codeBoxMaxHeight),
      padding: const EdgeInsets.all(AppSpace.m),
      decoration: BoxDecoration(
        color: context.c.codeBackground,
        borderRadius: BorderRadius.circular(8),
        // 一条极淡的 hairline 是**深色模式的必需品**：深色下 `codeBackground`
        // 与页面底 `background` 是同一个取值（#0D1117），没有描边时输入/输出区
        // 就是一块看不见的空白，用户分不清"哪几行是工具输出"。
        border:
            Border.all(color: context.c.border.withOpacity(0.5), width: 0.5),
      ),
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: controller,
          child: child,
        ),
      ),
    );
  }

  /// 小标题 + 复制入口。
  Widget _metaRow(
    BuildContext context, {
    required String label,
    required String copyText,
    required String copyToast,
    required bool showCopy,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppText.caption,
              color: context.c.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (showCopy)
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: copyText));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(copyToast),
                  duration: const Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            borderRadius: BorderRadius.circular(AppSpace.s),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  Icon(
                    Icons.copy_rounded,
                    size: 11,
                    color: context.c.textSecondary,
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Text(
                    '复制',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: context.c.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 把结构化输入渲染成命令列表。
  ///
  /// 一次并行 bash 可能带多条命令；直接展示 JSON 会丢掉最重要的“执行了什
  /// 么”这个信息。命令和说明分组显示，序号只在多于一条时出现。
  Widget _buildCommandBody(BuildContext context, ToolInputView input) {
    final items = input.invocations;
    final showOrdinal = input.commandCount > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.s),
              child: Divider(
                height: 0.5,
                thickness: 0.5,
                color: context.c.border.withOpacity(0.5),
              ),
            ),
          if ((items[i].description?.isNotEmpty ?? false) || showOrdinal) ...[
            Text(
              [
                if (showOrdinal) '#${i + 1}',
                if (items[i].description?.isNotEmpty ?? false)
                  items[i].description!,
              ].join(' · '),
              style: TextStyle(
                fontSize: AppText.caption,
                color: context.c.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 2),
          ],
          if (items[i].hasCommand)
            SelectableText(
              items[i].command!,
              style: _monoStyle(context),
            ),
          if (items[i].details.isNotEmpty) ...[
            if (items[i].hasCommand) const SizedBox(height: 2),
            Text(
              items[i]
                  .details
                  .entries
                  .map((e) => '${e.key}: ${e.value}')
                  .join(' · '),
              style: TextStyle(
                fontSize: AppText.caption,
                color: context.c.textTertiary,
              ),
            ),
          ],
        ],
      ],
    );
  }

  /// 输出正文 —— 超过 [_foldThreshold] 行时终端式折叠（Phase 4.4）。
  ///
  /// 头 5 行 + 省略行 + 尾 5 行。这个组合是刻意的：命令输出里**开头**是它在做什么
  /// （`$ npm test`、`Compiling…`），**结尾**是结果（`Tests: 651 passed`、报错
  /// 栈尾），中间是被折叠的那几百行进度噪音 —— 恰好是用户最不需要的那一段。
  Widget _buildOutputBody(BuildContext context) {
    final output = widget.tool.output;
    final style = _monoStyle(context);
    if (output.isEmpty) {
      return SelectableText('等待执行结果输出...', style: style);
    }

    final lines = output.split('\n');
    final canFold = lines.length > _foldThreshold;

    if (!canFold || _outputExpanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(output, style: style),
          if (canFold)
            _foldLine(
              context,
              label: '收起全文',
              onTap: () => setState(() => _outputExpanded = false),
            ),
        ],
      );
    }

    final head = lines.take(_foldHeadLines).join('\n');
    final tail = lines.skip(lines.length - _foldTailLines).join('\n');
    final hidden = lines.length - _foldHeadLines - _foldTailLines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectableText(head, style: style),
        _foldLine(
          context,
          label: '… 中间省略 $hidden 行 · 点击展开 …',
          onTap: () => setState(() => _outputExpanded = true),
        ),
        SelectableText(tail, style: style),
      ],
    );
  }

  Widget _foldLine(
    BuildContext context, {
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpace.s),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.s),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: AppText.caption,
            color: context.c.textTertiary,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }
}

/// 同一消息内连续多个工具调用的聚合折叠（Phase 2.3）。
///
/// 一条「装上依赖 → 跑测试 → 改文件 → 再跑测试」的消息会挂 4~8 个工具调用。
/// 逐个渲染时它们是 4~8 条 hairline 相隔的窄条，占了整屏却全是同一种形状；
/// 合并成一行「执行了 N 个工具 · 全部成功」后，消息流的重心回到正文。
///
/// 阈值 3 是刻意的：2 个工具调用还看得出是"两件事"（各自的名字有意义），
/// 3 个开始就是"一批流水线"，逐个列出只是噪音。
class AggregatedToolCalls extends StatefulWidget {
  const AggregatedToolCalls({
    super.key,
    required this.tools,
    this.threshold = 3,
  });

  final List<ToolExecution> tools;

  /// 低于这个数量时逐条渲染。
  final int threshold;

  @override
  State<AggregatedToolCalls> createState() => _AggregatedToolCallsState();
}

class _AggregatedToolCallsState extends State<AggregatedToolCalls> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tools = widget.tools;
    if (tools.isEmpty) return const SizedBox.shrink();

    // 不到阈值：逐条渲染（每条自己可展开，保持局部可控）。
    if (tools.length < widget.threshold) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final tool in tools)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.s),
              child: ToolCallCard(tool: tool),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: const ValueKey('tool-aggregate-toggle'),
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() => _expanded = !_expanded);
          },
          child: Container(
            height: 28,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: context.c.border.withOpacity(0.5),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.settings_rounded,
                  size: 13,
                  color: context.c.textSecondary,
                ),
                const SizedBox(width: AppSpace.s),
                Expanded(
                  child: Text(
                    _summary(tools),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.body,
                      fontWeight: FontWeight.w600,
                      color: context.c.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.s),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 14,
                  color: context.c.textTertiary,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: AppSpace.m, top: AppSpace.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final tool in tools)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.s),
                    child: ToolCallCard(tool: tool),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// 「⚙ 执行了 N 个工具 · 全部成功 / 2 个失败 / 1 个运行中」。
  ///
  /// 运行中优先于失败：一批工具还在跑的时候，报「1 个失败」会让用户以为已经结束了，
  /// 而实际上后面还有几个没跑完。
  String _summary(List<ToolExecution> tools) {
    final running = tools.where((t) => t.isRunning).length;
    final failed = tools.where(looksFailedToolOutput).length;
    final outcome =
        running > 0 ? '$running 个运行中' : (failed > 0 ? '$failed 个失败' : '全部成功');
    return '执行了 ${tools.length} 个工具 · $outcome';
  }
}
