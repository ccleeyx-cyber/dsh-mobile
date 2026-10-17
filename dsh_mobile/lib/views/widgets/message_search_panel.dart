import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'message_search.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// The in-session search bar and result list (v1.4.2 会话内查找).
///
/// Three rules the tests hold this to:
///
/// * **Result count means rendered rows.** `Text('N 条结果')` is only truthful if
///   the list actually has N rows. The collapsed count is computed from the
///   hits and the row builder is driven by the same list, so they cannot drift.
/// * **Empty state distinguishes "no hits" from "not searched yet".** Showing
///   "没有找到" for an empty query is a small lie that reads as a broken feature.
/// * **Prev/next never lie about being available.** The two arrows are drawn
///   whenever a query is present, but they are *disabled* when there is nothing
///   to step through — a button that swallows taps is worse than no button.
class MessageSearchPanel extends StatefulWidget {
  final String query;

  /// Null until the user types something. An empty (non-null) string means
  /// "searched, found nothing".
  final List<({SearchHit first, int count})> results;
  final int totalHits;

  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClose;
  final void Function(SearchHit hit) onJumpTo;

  const MessageSearchPanel({
    super.key,
    required this.query,
    required this.results,
    required this.totalHits,
    required this.onQueryChanged,
    required this.onClose,
    required this.onJumpTo,
  });

  @override
  State<MessageSearchPanel> createState() => _MessageSearchPanelState();
}

class _MessageSearchPanelState extends State<MessageSearchPanel> {
  late final TextEditingController _controller = TextEditingController(text: '');
  final FocusNode _focus = FocusNode();

  /// 结果列表自己的滚动条（Phase 4.3 的"当前命中要看得见"）。
  final ScrollController _listController = ScrollController();

  /// 结果行的定位锚：`messageIndex` → GlobalKey。
  ///
  /// 用**懒加载**的 Map 而不是给每行预先建 key：`ListView.builder` 只会构建视野内的
  /// 行，所以这里最多也就几条到十几条。`messageIndex` 在 collapse 之后对每一行唯一
  /// （`SearchHit` 没有 messageId，这是本面板能拿到的唯一稳定身份），因此同一行在
  /// 重建之间拿到的是**同一个 GlobalKey 实例** —— 这也是 GlobalObjectKey 那种
  /// "用一个值对象当 key"的做法在这里行不通的原因：`'${index}'` 每次 build 都是新
  /// String，`identical` 不成立，key 会一直换。
  final Map<int, GlobalKey> _rowKeys = <int, GlobalKey>{};

  /// 当前停留的命中行（Phase 4.3）。
  ///
  /// 只认**行**下标（collapse 之后的行），不是 hits 下标：界面上能看到并点到的
  /// 只有行，用 hits 下标会让 ↑/↓ 跳过屏幕上的若干行。
  int _currentHitIndex = 0;

  @override
  void initState() {
    super.initState();
    // Open with the keyboard up: the whole point is to type immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant MessageSearchPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 查询变了 / 行数变了，旧下标可能指向另一行甚至越界。归零比"尽力保留"更可
    // 预测：用户改一个字之后，他会期望"下一个命中"从第一条重新开始数。
    if (oldWidget.query != widget.query ||
        oldWidget.results.length != widget.results.length ||
        _currentHitIndex >= widget.results.length) {
      _currentHitIndex = 0;
    }
    if (oldWidget.query != widget.query) {
      // 换查询 = 换了一批行，旧 key 一个也不会再被用到。就地回收，别让它随每次
      // 输入累积（用户是边打字边搜的，一次会话能换几十次查询）。
      _rowKeys.clear();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _listController.dispose();
    super.dispose();
  }

  /// 循环跳转：到底回到 0，在 0 往上回到最后一条。
  ///
  /// 复用 `onJumpTo`（会话里的滚动 + 消息高亮），而不是在这里自己滚 —— 面板不该
  /// 知道消息列表长什么样，那会让"点一行"和"点箭头"走出两条不同的跳转路径。
  void _step(int delta) {
    final rows = widget.results.length;
    if (rows == 0) return;
    // Dart 的 `%` 对正模数恒为非负：(-1) % 3 == 2，所以不需要再补一次。
    final next = (_currentHitIndex + delta) % rows;
    setState(() => _currentHitIndex = next);
    HapticFeedback.selectionClick();
    widget.onJumpTo(widget.results[next].first);
    _revealRow(next);
  }

  void _select(int index) {
    if (index < 0 || index >= widget.results.length) return;
    setState(() => _currentHitIndex = index);
    HapticFeedback.selectionClick();
    widget.onJumpTo(widget.results[index].first);
    // 点行**不**滚：用户点的就是眼前这一行，再把它居中会变成"抢滚动条"。
  }

  GlobalKey _rowKey(int messageIndex) => _rowKeys.putIfAbsent(messageIndex, GlobalKey.new);

  /// 把第 [index] 行滚进结果列表的视野。
  ///
  /// 只在 ↑/↓ 之后调用。用户自己拖列表时没有任何代码路径会走到这里，所以"手动滚动
  /// 后不抢"不是靠某个标志位，而是靠**触发点只有按钮**这件事本身保证的。
  ///
  /// 懒加载冲突的处理：目标行离当前视野很远时，`ListView.builder` 根本没构建它，
  /// `currentContext` 是 null，`ensureVisible` 会静默什么都不做（用户按了 8 次 ↓，
  /// 面板却停在原处）。所以退化分两步：
  ///   1. 先按下标比例 `jumpTo(maxScrollExtent * i / (n-1))` 粗滚 —— 行高不等，这个
  ///      位置不准，但足以把目标行带进构建范围；
  ///   2. 下一帧（行已构建）再 `ensureVisible` 精确对齐到居中。
  /// 第二步注册在第一步的 post-frame 回调里，因此一定发生在"粗滚引发的下一次布局"
  /// 之后。
  void _revealRow(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rows = widget.results.length;
      if (index < 0 || index >= rows) return;

      final built = _rowKeys[widget.results[index].first.messageIndex]?.currentContext;
      if (built != null) {
        _ensureRowVisible(built);
        return;
      }

      if (!_listController.hasClients) return;
      final position = _listController.position;
      if (!position.hasContentDimensions) return;
      final ratio = rows <= 1 ? 0.0 : index / (rows - 1);
      final target = (position.maxScrollExtent * ratio)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      _listController.jumpTo(target);

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final retry = _rowKeys[widget.results[index].first.messageIndex]?.currentContext;
        if (retry != null) _ensureRowVisible(retry);
      });
    });
  }

  /// `alignment: 0.5` = 目标行居中：上下都留出上下文，用户能看出"第 7 条"前后还有
  /// 什么，而不是贴着某一端。160ms / easeOut 是"够快不拖沓、又能被看见"的取值：
  /// 瞬时跳变会让人以为是列表抖了一下。
  void _ensureRowVisible(BuildContext rowContext) {
    Scrollable.ensureVisible(
      rowContext,
      alignment: 0.5,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasQuery = widget.query.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: context.c.surface,
        border: Border(bottom: BorderSide(color: context.c.border)),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.search_rounded, size: 18, color: context.c.textSecondary),
                  const SizedBox(width: AppSpace.m),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      style: TextStyle(fontSize: AppText.title, color: context.c.textPrimary),
                      textInputAction: TextInputAction.search,
                      onChanged: widget.onQueryChanged,
                      decoration: InputDecoration(
                        hintText: '在当前会话中查找…',
                        hintStyle: TextStyle(fontSize: AppText.title, color: context.c.textTertiary),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 6),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.m),
                  InkWell(
                    onTap: widget.onClose,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.close_rounded, size: 18, color: context.c.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            if (hasQuery) _buildResults(),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (widget.results.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 2, 6, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '当前会话里没有包含「${widget.query}」的内容',
                style: TextStyle(fontSize: AppText.subhead, color: context.c.textTertiary),
              ),
            ),
            // 没命中时仍然画箭头，但是禁用态：让用户看得见"有这个东西、现在没得跳"，
            // 比让按钮凭空消失更不容易被读成"功能坏了"。
            _navButton(next: false),
            _navButton(next: true),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.c.surfaceMuted)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 6, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    // One number, and it is the number of rows below.
                    '${widget.results.length} 条结果'
                    '${widget.totalHits > widget.results.length ? '（${widget.totalHits} 处匹配）' : ''}',
                    style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
                  ),
                ),
                if (widget.results.length > 1)
                  // 当前位置。只在多行时出现：单行时的 "1/1" 是噪声。
                  Text(
                    '${_currentHitIndex + 1}/${widget.results.length}',
                    key: const ValueKey('search-hit-position'),
                    style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
                  ),
                _navButton(next: false),
                _navButton(next: true),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 230),
            child: ListView.builder(
              // 保持 builder（结果集可能上千行，换成 Column 就是一次性构建全部）。
              // 定位靠 `_rowKeys` 的懒加载锚点 + 这个 controller 的退化粗滚。
              controller: _listController,
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: widget.results.length,
              itemBuilder: (context, index) {
                final r = widget.results[index];
                return KeyedSubtree(
                  key: _rowKey(r.first.messageIndex),
                  child: _ResultRow(
                    hit: r.first,
                    count: r.count,
                    query: widget.query,
                    selected: index == _currentHitIndex,
                    onTap: () => _select(index),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// ↑ / ↓。禁用时 `onPressed: null`（不是空回调）—— 空回调仍然会吃掉一次点击
  /// 并给出水波纹，读起来像"点了但没反应"。
  Widget _navButton({required bool next}) {
    final enabled = widget.results.isNotEmpty;
    return IconButton(
      key: ValueKey(next ? 'search-next-hit' : 'search-prev-hit'),
      tooltip: next ? '下一个命中' : '上一个命中',
      onPressed: enabled ? () => _step(next ? 1 : -1) : null,
      icon: Icon(
        next ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
        size: 15,
        color: enabled ? context.c.textSecondary : context.c.border,
      ),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 28, height: 26),
    );
  }
}

class _ResultRow extends StatelessWidget {
  final SearchHit hit;
  final int count;
  final String query;

  /// 是否是 ↑/↓ 当前停留的那一行。底色 + 左侧色条一起表达 —— 只换底色在中性
  /// 背景上太弱，只画色条又很难看出整行的范围。
  final bool selected;

  final VoidCallback onTap;

  const _ResultRow({
    required this.hit,
    required this.count,
    required this.query,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      // 左侧色条常驻（未选中时用面板底色），这样选中一行不会让文字左右跳 2.5px。
      decoration: BoxDecoration(
        color: selected ? context.c.selectedSurface : null,
        border: Border(
          left: BorderSide(
            width: 2.5,
            color: selected ? context.c.accent : context.c.surface,
          ),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: context.c.surfaceMuted,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      MessageSearch.fieldLabel(hit.field),
                      style: TextStyle(fontSize: AppText.caption, color: context.c.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (count > 1)
                    Text(
                      '$count 处',
                      style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
                    ),
                  const Spacer(),
                  if (hit.timestamp != null)
                    Text(
                      _fmt(hit.timestamp!),
                      style: TextStyle(fontSize: AppText.caption, color: context.c.textTertiary),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              _Highlighted(
                text: hit.context(),
                query: query,
                style: TextStyle(fontSize: AppText.body, color: context.c.textPrimary, height: 1.4),
                highlightStyle: TextStyle(
                  fontSize: AppText.body,
                  color: context.c.warning,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}';
  }
}

/// Renders [text] with every case-insensitive occurrence of [query] emphasised.
///
/// Written as a plain split/round-trip rather than a regex so a query
/// containing regex metacharacters (`.`, `*`, `$`) cannot throw or mis-match —
/// users type those characters into search boxes constantly.
class _Highlighted extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle style;
  final TextStyle highlightStyle;

  const _Highlighted({
    required this.text,
    required this.query,
    required this.style,
    required this.highlightStyle,
  });

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) return Text(text, style: style, maxLines: 2, overflow: TextOverflow.ellipsis);

    final spans = <TextSpan>[];
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    var from = 0;
    while (true) {
      final at = lowerText.indexOf(lowerQuery, from);
      if (at < 0) break;
      if (at > from) spans.add(TextSpan(text: text.substring(from, at)));
      spans.add(TextSpan(text: text.substring(at, at + lowerQuery.length), style: highlightStyle));
      from = at + lowerQuery.length;
    }
    if (from < text.length) spans.add(TextSpan(text: text.substring(from)));
    if (spans.isEmpty) return Text(text, style: style);

    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
