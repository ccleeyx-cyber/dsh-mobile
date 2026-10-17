import 'package:flutter/material.dart';

import '../../models/chat_message.dart';

/// 消息列表（会话流本体）。
///
/// 从 `ChatView` 抽出来的唯一理由：`ChatView.build()` 用的是
/// `Provider.of<DshService>(context)`（listen 默认 true），于是每个流式增量
/// 都会重建**整个**聊天页 —— AppBar、横幅、输入框、搜索面板全都算上，
/// 而其中只有消息列表真的需要变。
///
/// 用法：`ChatView` 里用
/// `Selector<DshService, List<ChatMessage>>((d) => d.messages)` 取到列表后
/// 传给本 widget。这样 `ChatView` 自身只在**列表身份变化**时重建，流式期间
/// 的逐 chunk 刷新被限制在这个 `ListView.builder` 内部。
///
/// 注意本 widget 故意不认识 `DshService`：渲染一条消息需要的会话上下文
/// （交付物白名单、点击回调）由 [ChatView] 通过 [buildItem] 注入，
/// 免得这里变成一个隐藏的 provider 消费者、把刚拆掉的重建又接回来。
class MessageListView extends StatelessWidget {
  const MessageListView({
    super.key,
    required this.messages,
    required this.itemCount,
    required this.buildItem,
    required this.buildHeader,
    required this.buildTrailer,
    required this.headerCount,
    required this.controller,
    required this.onScrollNotification,
    this.overlay,
  });

  /// 消息列表（已按展示顺序）。空列表时本 widget 不渲染任何东西。
  final List<ChatMessage> messages;

  /// `itemCount = messages.length + trailer(0|1) + headerCount`，
  /// 由调用方算好 —— 它同时握着 trailer 的锚点状态。
  final int itemCount;
  final int headerCount;

  /// 渲染第 [index] 条消息（index 已扣除头部）。调用方持有 key 映射、
  /// 高亮集合与点击逻辑。
  final Widget Function(BuildContext context, int index) buildItem;

  /// 上翻头部（加载圈 / 已到开头）。headerCount > 0 时才被调用。
  final Widget Function() buildHeader;

  /// 列表尾部卡片（「本轮产出」）。itemCount 含它时才被调用。
  final Widget Function() buildTrailer;

  final ScrollController controller;
  final bool Function(ScrollNotification notification) onScrollNotification;

  /// 浮在列表右边缘的一层（轮次导航刻度，v1.26.0）。
  ///
  /// 放在这里而不是 `ChatView` 外层的原因：它必须**贴着消息流**（右侧 4dp、垂直居中），
  /// 而不是贴着整个页面；由 `ChatView` 构造好组件传进来，本 widget 依旧不认识
  /// `DshService`。
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) return const SizedBox.shrink();

    final list = NotificationListener<ScrollNotification>(
      onNotification: onScrollNotification,
      child: ListView.builder(
        controller: controller,
        // 去掉了 `AlwaysScrollableScrollPhysics` 包装：它在 Android 上和
        // NotificationListener 打架，每次 overscroll 多一次布局。Bouncing
        // 本身就够 iOS 手感，Android 用默认 stretch 即可。
        physics: const BouncingScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (index < headerCount) return buildHeader();
          final msgIndex = index - headerCount;
          if (msgIndex < messages.length) return buildItem(context, msgIndex);
          return buildTrailer();
        },
      ),
    );

    if (overlay == null) return list;

    // 刻度整层 IgnorePointer 之外的部分可点：只让刻度自己吃点击，别挡住气泡上的
    // 长按/链接。Stack 里 overlay 是独立命中的，所以不需要额外包 IgnorePointer。
    //
    // [feat 2026-10-17] 刻度从**右边缘**移到**左边缘**。右边缘原本有三个抢同一块
    // 热区的东西：轮次刻度、"回到最新消息"浮钮（右下）、以及 Android 从右边缘发起
    // 的返回手势。三者叠在一起的结果是"点刻度偶尔返回上一页"。左侧没有返回手势
    // 的竞争，且单手持机时左边缘本来就在拇指/食指的顺手位。
    return Stack(
      children: [
        Positioned.fill(child: list),
        Positioned(left: 2, top: 0, bottom: 0, child: overlay!),
      ],
    );
  }
}
