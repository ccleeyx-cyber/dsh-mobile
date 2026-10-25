import 'dart:convert';

/// 是否是一条 GenUI 动作回传消息。
///
/// 这个前缀是与 Web 端的协议约定，不是展示文案；历史消息要用它识别并折叠，
/// 否则用户会在对话里看到一大段发给模型的指令。
bool isGenuiActionMessage(String text) =>
    text.trimLeft().startsWith('[genui-action]');

/// 构造一条 `[genui-action]` 用户消息。
///
/// 只复用 Web 端的可见约定（动作名 + 组件数据），不复制整段长提示：手机端
/// 只需要模型知道"这是组件动作、请据此重渲染"，多余的解释只会挤占上下文。
String buildGenuiActionPrompt(String action, Map<String, dynamic> data) {
  final payload = data.isEmpty ? '' : ' 组件数据: ${jsonEncode(data)}';
  return '[genui-action] $action。用户刚刚在界面中触发了动作 "$action"，'
      '请根据组件数据执行相应操作，并用 dsh-ui 输出更新后的界面。$payload';
}
