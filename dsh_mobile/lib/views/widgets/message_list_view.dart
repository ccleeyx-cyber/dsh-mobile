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
///
/// ----
/// [fix 2026-10-18] 列表改为 `reverse: true`（聊天 UI 标准形态，微信/Telegram 同款）。
///
/// 此前是正序列表：挂载后落在 offset 0（视觉**顶部** = 最旧消息），再靠
/// postFrame `jumpToBottom()` 跳到底 —— 打开会话时用户看到"从上往下滚一下"
/// 就是这一跳；缓存未命中时还要逐页补历史，每页一跳。1.32.1 的"贴底窗口"
/// 只是把 300ms 动画换成瞬时跳，闪跳本身没消除。
///
/// 反转后：
/// * offset 0 = 视觉**底部**：挂载即最新消息，零滚动、零补偿；
/// * 数据倒序喂入（index 0 = 最新），`buildItem` 收到的消息索引已翻回正序语义；
/// * 新消息到达时用户在上翻也不被拖走（列表锚定底边，探针用例 2 已验证）；
/// * 顶部加载更早历史时现有内容视觉位置天然不动（探针用例 3 已验证）——
///   正序时代那套 `oldMax/newMax` delta 平移补偿整个不再需要。
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

  /// 消息列表（**正序**：oldest → newest）。空列表时本 widget 不渲染任何东西。
  ///
  /// widget 内部自己倒序喂给 reverse ListView —— 调用方（ChatView / 搜索 /
  /// 轮次刻度）继续按正序索引工作，不必跟着翻。
  final List<ChatMessage> messages;

  /// `itemCount = messages.length + trailer(0|1) + headerCount`，
  /// 由调用方算好 —— 它同时握着 trailer 的锚点状态。
  final int itemCount;
  final int headerCount;

  /// 渲染第 [index] 条消息（**正序索引**，0 = 最旧；widget 内部已翻转）。
  /// 调用方持有 key 映射、高亮集合与点击逻辑。
  final Widget Function(BuildContext context, int index) buildItem;

  /// 上翻头部（加载圈 / 已到开头）。headerCount > 0 时才被调用。
  final Widget Function() buildHeader;

  /// 列表尾部卡片（「本轮产出」）。itemCount 含它时才被调用。
  ///
  /// reverse 列表里它出现在**视觉顶部之上**？不 —— 见 [_visualIndexFor]，
  /// trailer 永远渲染在视觉最底部（最新消息之后），反转只是索引方向的翻转。
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
        reverse: true,
        // 去掉了 `AlwaysScrollableScrollPhysics` 包装：它在 Android 上和
        // NotificationListener 打架，每次 overscroll 多一次布局。Bouncing
        // 本身就够 iOS 手感，Android 用默认 stretch 即可。
        physics: const BouncingScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        itemCount: itemCount,
        itemBuilder: (context, visualIndex) {
          // 自下而上：trailer（本轮产出卡）→ 消息（新→旧）→ 上翻头部（视觉顶部）。
          final trailerCount = itemCount - messages.length - headerCount; // 0 或 1
          if (visualIndex < trailerCount) return buildTrailer();
          final msgVisual = visualIndex - trailerCount; // 0 = 最新一条
          if (msgVisual < messages.length) {
            return buildItem(context, messages.length - 1 - msgVisual);
          }
          return buildHeader();
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
