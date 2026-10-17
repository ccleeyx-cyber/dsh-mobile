import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// 思考过程 —— **引用块**，不是卡片（Phase 2.2）。
///
/// 改动前它是一张完整的卡片：`surfaceMuted` 底色 + `border` 描边 + 圆角 8，
/// 展开后体内再套一层 `surface` 底 + 描边的盒子。于是一条 AI 消息的嵌套边框层数
/// 是「气泡 1 + 思考卡 1 + 思考正文 1 = 3 层」，思考本身却只是**辅助信息**。
///
/// 现在它退化成一个引用块：左侧 2px 竖线 + 斜体浅色文字，没有任何填充背景。
/// 消息流里只剩两种视觉元素 —— 用户气泡（实心块）和审批卡（唯一需要立即决策的
/// 卡片），其余全是不描边的文字层级。
///
/// 状态机（自动跟随 / 用户手动折叠后不再自动展开）与改动前逐行一致，见
/// [didUpdateWidget] 的注释。
class ThinkingCard extends StatefulWidget {
  final String content;
  final bool isThinking;

  const ThinkingCard({
    super.key,
    required this.content,
    this.isThinking = false,
  });

  @override
  State<ThinkingCard> createState() => _ThinkingCardState();
}

class _ThinkingCardState extends State<ThinkingCard> {
  late bool _expanded;
  final ScrollController _scrollController = ScrollController();

  /// 用户是否亲手开合过这个块。
  ///
  /// 存在的唯一目的：让「思考结束自动收起」只作用于**用户没表过态**的块。
  /// 它不是一个脏标记，而是一个**权限标记** —— 一旦为 true，本组件不再对
  /// `_expanded` 做任何自动改写，开合权完全归用户。
  bool _userTouched = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.isThinking;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ThinkingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Auto-expand only when transitioning into thinking state from non-thinking
    // state. Within a single thinking phase `isThinking` stays true, so this
    // does not fire again and a user's manual collapse is preserved for the
    // rest of the stream — which is exactly what the old `_userCollapsed` flag
    // was meant to express. That flag was written in four places and read in
    // none, so it has been removed instead of being left as dead state.
    if (!oldWidget.isThinking && widget.isThinking) {
      _expanded = true;
    } else if (oldWidget.isThinking && !widget.isThinking && !_userTouched) {
      // 思考**结束**时收起 —— 但**只对用户从未干预过的块生效**。
      //
      // 动机是 Phase 2 的验收口径：一条「思考 + 3 工具 + 正文」的消息折叠态要
      // 压到 220dp 以内。展开态有 280dp 上限，光思考块就能吃掉整屏大半 ——
      // 而思考结束时用户真正要读的是答案，不是推理过程。
      //
      // `!_userTouched` 这个条件是**规则的一部分，不是例外**：本组件有一条既有
      // 约束「用户手动折叠后不自动展开」，说的是别抢用户的状态。既然折叠方向不能
      // 抢，展开方向同样不能抢 —— 用户在流式中点开思考想读，结束后被自动收掉，
      // 就是第二次抢。所以自动收起只作用于"用户没表过态"的块；表过态就完全
      // 交给人，之后不再有任何自动展开/收起。
      _expanded = false;
    }

    // Auto-scroll inside thinking box when new chunks arrive, if user is already near bottom
    if (widget.isThinking && _expanded && oldWidget.content != widget.content) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          final pos = _scrollController.position;
          if (pos.maxScrollExtent - pos.pixels < 50) {
            _scrollController.animateTo(
              pos.maxScrollExtent,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
            );
          }
        }
      });
    }
  }

  void _toggleExpanded() {
    HapticFeedback.selectionClick();
    setState(() {
      // 表过态之后，思考结束时的自动收起不再生效（见 didUpdateWidget）。
      _userTouched = true;
      _expanded = !_expanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.content.isEmpty && !widget.isThinking) {
      return const SizedBox.shrink();
    }

    final isThinking = widget.isThinking;
    final c = context.c;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.s),
      // 引用块的唯一装饰：左侧 2px 竖线。用 border 而不是 Container 背景，
      // 因为它必须贴着文字左缘，而背景块会把「一段引用」重新变成「一张卡」。
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: c.border, width: 2),
        ),
      ),
      padding: const EdgeInsets.only(left: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _toggleExpanded,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.s),
              child: Row(
                children: [
                  Icon(
                    isThinking
                        ? Icons.psychology_rounded
                        : Icons.lightbulb_outline_rounded,
                    size: 13,
                    color: c.textTertiary,
                  ),
                  const SizedBox(width: AppSpace.s),
                  Expanded(
                    child: Text(
                      _label(isThinking),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppText.caption,
                        fontStyle: FontStyle.italic,
                        color: c.textTertiary,
                        height: 1.3,
                      ),
                    ),
                  ),
                  if (isThinking) ...[
                    const SizedBox(width: AppSpace.s),
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: c.accent,
                      ),
                    ),
                  ],
                  const SizedBox(width: AppSpace.xs),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 15,
                    color: c.textTertiary,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs, bottom: AppSpace.m),
              child: Container(
                width: double.infinity,
                // 展开态限高 280 + 内部滚动：一段超长思维链不该把整条消息
                // 顶出屏幕。容器本身没有底色和描边（改动前是 surface + border），
                // 只留约束 —— 这就是「引用块」与「卡片」的全部差别。
                constraints: const BoxConstraints(maxHeight: 280),
                padding: const EdgeInsets.only(left: AppSpace.m),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Flexible(
                      child: Scrollbar(
                        controller: _scrollController,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: _scrollController,
                          child: SelectableText(
                            widget.content.isEmpty
                                ? '正在分析上下文并规划步骤...'
                                : widget.content,
                            style: TextStyle(
                              fontSize: AppText.body,
                              height: 1.6,
                              fontStyle: FontStyle.italic,
                              color: c.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (widget.content.isNotEmpty) ...[
                      const SizedBox(height: AppSpace.s),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _TextAction(
                            icon: Icons.copy_rounded,
                            label: '复制',
                            onTap: () {
                              Clipboard.setData(
                                ClipboardData(text: widget.content),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已复制思考过程'),
                                  duration: Duration(seconds: 1),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: AppSpace.m),
                          _TextAction(
                            icon: Icons.keyboard_arrow_up_rounded,
                            label: '收起',
                            onTap: () {
                              HapticFeedback.selectionClick();
                              setState(() {
                                // 底部的「收起」和点标题一样是用户动作，
                                // 同样要记进 _userTouched。
                                _userTouched = true;
                                _expanded = false;
                              });
                            },
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 折叠态的单行文案。
  ///
  /// 两种状态都要有信息量：流式中说「思考中」（用户知道它还没停），结束后说
  /// 「思考过程」并给字数（用户据此决定值不值得展开）。字数用 `content.length`
  /// 而不是真实 token —— 后者拿不到，而字数只是「值不值得点开」的粗略标尺。
  String _label(bool isThinking) {
    final chars = widget.content.length;
    return isThinking ? '思考中 · $chars 字' : '思考过程 · $chars 字';
  }
}

/// 引用块底部的小号文字动作（复制 / 收起）。
///
/// 抽出来只是因为它在同一处出现两次，样式必须逐字一致；不做成公共组件。
class _TextAction extends StatelessWidget {
  const _TextAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: context.c.textSecondary),
            const SizedBox(width: AppSpace.xs),
            Text(
              label,
              style: TextStyle(
                fontSize: AppText.caption,
                color: context.c.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
