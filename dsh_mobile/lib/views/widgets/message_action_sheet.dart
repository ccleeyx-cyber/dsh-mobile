/// 统一的消息 action sheet（Phase 4.7）。
///
/// ## 为什么要有这个文件
///
/// 改动前，"长按一条消息/一个附件/一行产出"各自绑着**不同的**语义：产出卡长按 =
/// 下载，附件根本没有长按，正文长按 = 系统选词。用户没法从界面上学到任何一致
/// 的手势，而每个新动作进来时都得再挑一次"这次长按该干谁"。
///
/// 现在只有**一个**底部弹层（本类）。上下文差异只体现在**动作列表**上：
///
/// | 上下文 | 动作 |
/// |---|---|
/// | 消息（有正文） | 复制原文 / 引用 / [仅用户] 重新发送 / [仅 AI] 查看本轮轨迹 |
/// | 附件 | [仅图片] 打开图片 / 复制文件名 / 复制附件 ID |
/// | 产出卡 | 打开预览 / 下载并打开 / 复制路径 |
///
/// ## 为什么弹层只**返回动作 id**，不自己执行
///
/// 所有动作都要用到 `chat_view` 手里的东西（输入框 controller/focus、轨迹面板、
/// 下载链路）。让弹层持有那些回调等于把会话级状态复制一份进来，而这个文件刻意
/// 只依赖 `BuildContext` + 一串纯数据 —— 所以它是可以被单测直接 pump 的。
///
/// 另外，动作一律在**弹层关掉之后**执行（调用方 `await` 到 id 再动手）：在弹层的
/// route 里推下一个页面/pop 会把两层导航叠在一起，Android 返回手势会先关错的
/// 那一层。
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// 一条可选动作。[id] 是调用方 switch 用的稳定标识，也是测试定位用的 key 后缀
/// （`message-action-<id>`）。**不要**在文案变化时改 id。
class MessageActionSpec {
  const MessageActionSpec({
    required this.id,
    required this.label,
    required this.icon,
    this.hint,
  });

  final String id;
  final String label;
  final IconData icon;

  /// 一行副文案。只给"不写出来用户猜不到"的动作（长按完全不可发现，同理）。
  final String? hint;
}

/// 弹出统一 action sheet，返回被选中的动作 [MessageActionSpec.id]。
///
/// 返回 null 表示用户点了遮罩/返回键取消 —— 与"选中了但动作失败"是两件不同的事，
/// 所以这里**不**吞掉取消。
Future<String?> showMessageActionSheet(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<MessageActionSpec> actions,
}) async {
  // 没有动作就别弹一个空壳：空 sheet 会让人以为长按坏了。
  if (actions.isEmpty) return null;

  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: context.c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: Column(
        key: const ValueKey('message-actions-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 头部：标题 + 被操作内容的摘要。摘要不是装饰 —— 长按的命中区可能盖住
          // 相邻两条（尤其是流式拆出来的短消息），不显示"操作的是哪条"就会
          // 复制错东西。
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpace.xl, AppSpace.l, AppSpace.xl, AppSpace.s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppText.heading,
                    fontWeight: FontWeight.w600,
                    color: sheetCtx.c.textPrimary,
                  ),
                ),
                if (subtitle != null && subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.xs),
                    child: Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppText.caption,
                        height: 1.35,
                        color: sheetCtx.c.textTertiary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: sheetCtx.c.border),
          for (final action in actions)
            ListTile(
              key: ValueKey('message-action-${action.id}'),
              dense: true,
              leading: Icon(action.icon, size: 20, color: sheetCtx.c.accent),
              title: Text(
                action.label,
                style: TextStyle(
                  fontSize: AppText.title,
                  color: sheetCtx.c.textPrimary,
                ),
              ),
              subtitle: action.hint == null
                  ? null
                  : Text(
                      action.hint!,
                      style: TextStyle(
                        fontSize: AppText.caption,
                        color: sheetCtx.c.textTertiary,
                      ),
                    ),
              onTap: () => Navigator.pop(sheetCtx, action.id),
            ),
          const SizedBox(height: AppSpace.s),
        ],
      ),
    ),
  );
}

/// 把一段正文压成一行摘要（sheet 头部的副标题，也是长按时"我在操作哪条"的凭据）。
///
/// 折叠空白而不是原样截断：Markdown 正文里的换行/缩进在单行 Text 里会变成一串
/// 无意义的空白，反而让摘要看不出是哪条消息。
String messageActionSnippet(String content, {int maxChars = 90}) {
  final flat = content.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= maxChars) return flat;
  return '${flat.substring(0, maxChars)}…';
}
