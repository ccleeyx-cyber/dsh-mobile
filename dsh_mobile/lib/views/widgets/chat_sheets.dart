/// 聊天页的底部弹层 / 对话框集合。
///
/// Phase 0 结构拆分（纯剪切）：从 `chat_view.dart` 原样搬出，逻辑与样式一字未改。
/// 每个入口都只依赖 `BuildContext` + `DshService` 和少量显式回调；跨帧状态仍然
/// 留在 `_ChatViewState`，这里不持有任何自己的状态（`StatefulBuilder` 的局部态除外）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/dsh_settings.dart';
import '../../models/trajectory.dart';
import '../../services/dsh_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/top_toast.dart';
import 'session_info_sheet.dart';
import 'session_status_strip.dart';
import 'trajectory_sheet.dart';

import '../../models/task_center.dart';

/// 选择入口：图片 / 文件。做成底部弹窗而不是两个按钮，是因为输入栏的横向
/// 空间已经很紧（输入框 + 麦克风 + 发送），再加两个图标会挤。
Future<void> showChatAttachSheet(
  BuildContext context,
  DshService dsh, {
  required void Function(String message) toast,
  required Future<void> Function({required bool asFile}) onAttach,
}) async {
  if (!dsh.isConnected) {
    toast('网络已断开，请先重试连接');
    return;
  }
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: context.c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(Icons.image_outlined, color: context.c.accent),
            title: Text('图片', style: TextStyle(color: context.c.textPrimary, fontSize: 14)),
            subtitle: Text('自动压缩到 1600px，agent 能直接看到',
                style: TextStyle(color: context.c.textTertiary, fontSize: 11.5)),
            onTap: () => Navigator.pop(ctx, 'image'),
          ),
          ListTile(
            leading: Icon(Icons.attach_file_rounded, color: context.c.accent),
            title: Text('文件', style: TextStyle(color: context.c.textPrimary, fontSize: 14)),
            subtitle: Text('任意文件，上限 32MB',
                style: TextStyle(color: context.c.textTertiary, fontSize: 11.5)),
            onTap: () => Navigator.pop(ctx, 'file'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  await onAttach(asFile: choice == 'file');
}

/// 斜杠命令 / 技能菜单 [feat 2026-10-12]。
///
/// 命令清单来自网关透传的引擎 `commands/list` RPC；引擎没有/失败时网关回空表，
/// 这里直接不弹 sheet（提示一句话），绝不用硬编码命令名伪造菜单 —— 菜单里
/// 出现引擎不认的名字等于教用户输错命令。
Future<void> showChatCommandSheet(
  BuildContext context,
  DshService dsh, {
  required TextEditingController inputController,
  required FocusNode focusNode,
  required void Function(String message) toast,
}) async {
  if (!dsh.isConnected) {
    toast('网络已断开，请先重试连接');
    return;
  }
  final commands = await dsh.fetchCommands();
  if (!context.mounted) return;
  if (commands.isEmpty) {
    toast('当前会话没有可用的斜杠命令');
    return;
  }
  final picked = await showModalBottomSheet<SlashCommand>(
    context: context,
    backgroundColor: context.c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetCtx).size.height * 0.6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text('命令',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: sheetCtx.c.textPrimary)),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: commands.length,
                itemBuilder: (_, i) {
                  final c = commands[i];
                  return ListTile(
                    dense: true,
                    title: Text('/${c.name}',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: sheetCtx.c.textPrimary)),
                    subtitle: c.description.isEmpty
                        ? null
                        : Text(c.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: sheetCtx.c.textTertiary)),
                    onTap: () => Navigator.pop(sheetCtx, c),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  // 点选把 "/name " 插入输入框（保留既有草稿），光标落到底。
  final current = inputController.text;
  inputController.text = current.startsWith('/')
      ? '/${picked.name} ${current.substring(current.indexOf(' ') + 1)}'
      : '$current/${picked.name} ';
  inputController.selection = TextSelection.collapsed(offset: inputController.text.length);
  dsh.updateDraft(inputController.text);
  focusNode.requestFocus();
}

/// 会话权限与执行策略弹层。只负责本会话的执行策略 —— 那是唯一真的生效的旋钮。
void showChatPermissionSheet(BuildContext context, DshService dsh) {
  // 弹层可能在 await 之后已经被 pop 掉，届时它的 context 就取不到 overlay 了
  // （见 TopToastHandle 的说明）。这里先抓住出口。
  final toast = TopToastHandle.capture(context);
  final currentSession = dsh.currentSession;
  final sessionId = currentSession?.sessionId ?? 'default';
  final currentPolicy = dsh.getSessionPermission(sessionId);
  String selectedPolicy = currentPolicy;
  // 这里曾有一个「单轮迭代步数上限 (Max Steps)」滑块：它改写 `maxSteps`，而那个
  // 字段全链路无人消费（详见 PermissionConfig 的说明），所以滑块动了也不影响
  // 任何行为，已移除。本弹窗只负责本会话的执行策略 —— 那也是唯一真的生效的旋钮。

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (context, setModalState) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: context.c.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: context.c.accent.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: context.c.accent.withOpacity(0.2)),
                        ),
                        child: Icon(Icons.shield_outlined, color: context.c.accent, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '对话权限与执行策略',
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                            ),
                            Text(
                              '当前对话: ${currentSession?.title ?? sessionId}',
                              style: TextStyle(fontSize: 12, color: context.c.textSecondary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '终端命令执行策略 (Execution Policy)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.textPrimary),
                  ),
                  const SizedBox(height: 10),

                  // Policy Option: Ask
                  _buildPolicyOption(context, 
                    title: '🛡️ 每次询问 (Ask Every Time)',
                    subtitle: '最安全。任何 Shell / 脚本执行都需在手机端审批确认',
                    value: 'ask',
                    groupValue: selectedPolicy,
                    onChanged: (val) {
                      setModalState(() => selectedPolicy = val!);
                    },
                  ),

                  // Policy Option: Auto Read-Only
                  _buildPolicyOption(context, 
                    title: '🔍 自动放行只读 (Auto Read-Only)',
                    subtitle: '推荐。ls, grep, cat, git status 等只读指令直接运行，写操作拦截确认',
                    value: 'auto-read',
                    groupValue: selectedPolicy,
                    onChanged: (val) {
                      setModalState(() => selectedPolicy = val!);
                    },
                  ),

                  // Policy Option: Danger Full Access
                  _buildPolicyOption(context, 
                    title: '⚡ 完全信任模式 (Danger Full Access)',
                    subtitle: '全自动无阻塞运行。所有命令免审批执行，适合无人值守任务',
                    value: 'danger-full-access',
                    groupValue: selectedPolicy,
                    onChanged: (val) {
                      setModalState(() => selectedPolicy = val!);
                    },
                  ),

                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: context.c.accent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        elevation: 0,
                      ),
                      onPressed: () async {
                        // 危险档（完全信任）二次确认：与安全页的危险预设保持
                        // 一致。它会让本会话的工具调用**全部免审批**，而这在
                        // 聊天流里只是一次点击的距离 —— 值得多问一句。
                        if (selectedPolicy == 'danger-full-access') {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: context.c.surface,
                              title: Row(
                                children: [
                                  Icon(Icons.warning_amber_rounded, color: context.c.danger, size: 22),
                                  const SizedBox(width: 8),
                                  Text('确认开启完全信任？', style: TextStyle(color: context.c.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
                                ],
                              ),
                              content: Text(
                                '本会话后续的工具调用将不再逐条请求你的授权，包括删除文件、执行脚本等写操作。\n\n只在无人值守、且你清楚后果时使用。',
                                style: TextStyle(color: context.c.textSecondary, fontSize: 13, height: 1.5),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: Text('取消', style: TextStyle(color: context.c.textSecondary)),
                                ),
                                FilledButton(
                                  style: FilledButton.styleFrom(backgroundColor: context.c.danger),
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('仍要开启', style: TextStyle(fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                          );
                          if (confirmed != true || !context.mounted) return;
                        }
                        final currentSessions = Map<String, String>.from(dsh.permissions.sessionPolicies);
                        currentSessions[sessionId] = selectedPolicy;
                        final updatedPerms = dsh.permissions.copyWith(
                          sessionPolicies: currentSessions,
                        );
                        if (context.mounted) {
                          Navigator.pop(context);
                        }
                        await dsh.updatePermissions(updatedPerms);
                        // 提示放在**提交之后**：之前是先弹提示再发请求，失败了
                        // 也会说"已更新"（乐观提示是会骗人的）。
                        toast.show(
                          '对话权限已更新为 ${_getPolicyLabel(selectedPolicy)}',
                          icon: Icons.shield_outlined,
                        );
                      },
                      child: const Text('保存权限策略', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

Widget _buildPolicyOption(
  BuildContext context, {
  required String title,
  required String subtitle,
  required String value,
  required String groupValue,
  required ValueChanged<String?> onChanged,
}) {
  final isSelected = value == groupValue;
  return GestureDetector(
    onTap: () => onChanged(value),
    child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isSelected ? context.c.accent.withOpacity(0.08) : context.c.surface,
        border: Border.all(
          color: isSelected ? context.c.accent : context.c.border,
          width: isSelected ? 1.5 : 1.0,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Radio<String>(
            value: value,
            groupValue: groupValue,
            onChanged: onChanged,
            activeColor: context.c.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isSelected ? context.c.accent : context.c.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: context.c.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

String _getPolicyLabel(String policy) {
  switch (policy) {
    case 'danger-full-access':
      return '⚡ 完全放行';
    case 'auto-read':
      return '🔍 只读放行';
    case 'ask':
    default:
      return '🛡️ 每次询问';
  }
}

/// 快速模型选择：只影响本会话，全局默认在设置页改。
void showChatModelSwitchSheet(BuildContext context, DshService dsh) {
  // 同权限弹层：先抓住 toast 出口，弹层 pop 之后仍能提示。
  final toast = TopToastHandle.capture(context);
  if (dsh.settings == null || dsh.settings!.availableModels.isEmpty) {
    dsh.fetchSettings();
  }
  final settings = dsh.settings;
  final currentSession = dsh.currentSession;
  final activeModel = dsh.currentModel;
  final modelList = (settings != null && settings.availableModels.isNotEmpty)
      ? settings.availableModels
      : [
          ModelItem(id: 'cn:deepseek-v4.1-flash', name: 'DeepSeek V4.1 Flash', contextWindow: 1000000, maxTokens: 16384),
          ModelItem(id: 'cn:deepseek-v4-pro', name: 'DeepSeek V4 Pro', contextWindow: 1000000, maxTokens: 32768),
          ModelItem(id: 'cn:kimi-k3-1', name: 'Kimi K3.1', contextWindow: 1000000, maxTokens: 32768),
        ];

  String filter = '';

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: context.c.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: context.c.accent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.smart_toy_outlined, color: context.c.accent, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '切换大语言模型',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                        ),
                        Text(
                          '选择要在此会话中使用的 AI 模型',
                          style: TextStyle(fontSize: 12, color: context.c.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (currentSession != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: context.c.surfaceMuted,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '当前生效会话: ${currentSession.title}',
                      style: TextStyle(fontSize: 12, color: context.c.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              Text(
                '切换只对本次会话生效，立即生效；全局默认模型在「设置」页修改。',
                style: TextStyle(fontSize: 11.5, color: context.c.textTertiary),
              ),
              const SizedBox(height: 12),
              StatefulBuilder(
                builder: (context, setModalState) {
                  final filtered = modelList.where((m) {
                    if (filter.isEmpty) return true;
                    return m.name.toLowerCase().contains(filter) || m.id.toLowerCase().contains(filter);
                  }).toList();

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        decoration: InputDecoration(
                          hintText: '搜索模型 (如 deepseek, glm, gpt, qwen...)',
                          hintStyle: TextStyle(fontSize: 13, color: context.c.textTertiary),
                          prefixIcon: Icon(Icons.search, size: 20, color: context.c.textSecondary),
                          filled: true,
                          fillColor: context.c.surfaceMuted,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: (val) {
                          setModalState(() {
                            filter = val.trim().toLowerCase();
                          });
                        },
                      ),
                      const SizedBox(height: 10),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
                        child: filtered.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.symmetric(vertical: 24),
                                child: Center(
                                  child: Text('未找到匹配的模型', style: TextStyle(color: context.c.textTertiary)),
                                ),
                              )
                            : ListView.separated(
                                shrinkWrap: true,
                                separatorBuilder: (_, __) => const SizedBox(height: 6),
                                itemCount: filtered.length,
                                itemBuilder: (itemCtx, index) {
                                  final m = filtered[index];
                    final isSelected = m.id == activeModel || (m.id.replaceFirst('cn:', '') == activeModel.replaceFirst('cn:', ''));
                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () async {
                        Navigator.pop(ctx);
                        HapticFeedback.selectionClick();
                        // 只切本会话。以前这里调的是 switchModel，它除了写会话级
                        // 还顺手把全局默认也改了 —— 一个"给这个会话换模型"的动作
                        // 不该影响别的会话。现在全局默认只在设置页改。
                        final ok = await dsh.selectSessionModel(m.id, sessionId: currentSession?.sessionId);
                        // [fix 2026-10-11] Guard the OUTER sheet/chat context,
                        // not the list item's: after Navigator.pop the item
                        // context is unmounted, so the SnackBar here was dead
                        // code and a failed switch showed no feedback at all.
                        if (!itemCtx.mounted) return;
                        if (ok) {
                          // [feat 2026-10-17] 成功提示走**顶部**浮层，不用底部
                          // SnackBar：底部是输入卡片/状态胶囊/审批 dock 的地盘，
                          // 一条贴底的提示会盖住用户正在打的字（用户明确要求）。
                          toast.show('本会话模型已切换为 ${m.name}（立即生效）');
                        } else {
                          // 失败仍然留在原地可见：这里不自己消失。
                          ScaffoldMessenger.of(itemCtx).showSnackBar(
                            SnackBar(
                              content: Text('模型切换失败: ${dsh.lastError.isNotEmpty ? dsh.lastError : "请检查网络或授权码"}'),
                              backgroundColor: itemCtx.c.danger,
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: isSelected ? context.c.accent.withOpacity(0.08) : context.c.surface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSelected ? context.c.accent : context.c.border,
                            width: isSelected ? 1.5 : 1.0,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                              color: isSelected ? context.c.accent : context.c.textTertiary,
                              size: 18,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    m.name,
                                    style: TextStyle(
                                      color: isSelected ? context.c.accent : context.c.textPrimary,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${m.id} | 上下文: ${(m.contextWindow ?? 0) ~/ 1000}k',
                                    style: TextStyle(fontSize: 11.5, color: context.c.textSecondary),
                                  ),
                                ],
                              ),
                            ),
                            if (isSelected)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: context.c.accent.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text('使用中', style: TextStyle(color: context.c.accent, fontSize: 11, fontWeight: FontWeight.w600)),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    ],
          ),
        ),
      );
    },
  );
}

/// 删除当前会话的二次确认。
void showChatDeleteCurrentSessionDialog(BuildContext context, DshService dsh) {
  final currentSession = dsh.currentSession;
  if (currentSession == null) return;

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: context.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: context.c.border),
      ),
      title: Row(
        children: [
          Icon(Icons.delete_outline_rounded, color: context.c.danger, size: 22),
          const SizedBox(width: 8),
          Text('删除当前会话', style: TextStyle(color: context.c.textPrimary, fontSize: 17, fontWeight: FontWeight.bold)),
        ],
      ),
      content: Text(
        '确定要删除会话「${currentSession.title}」吗？\n删除后该会话的历史记录和上下文将不可恢复。',
        style: TextStyle(color: context.c.textPrimary, fontSize: 13, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text('取消', style: TextStyle(color: context.c.textSecondary)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: context.c.danger,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            elevation: 0,
          ),
          onPressed: () async {
            Navigator.pop(ctx);
            final ok = await dsh.deleteSession(
              currentSession.sessionId,
              dsh.currentWorkspace?.workspaceId,
            );
            if (context.mounted) {
              ScaffoldMessenger.of(context).clearSnackBars();
              if (ok) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('已删除会话: ${currentSession.title}'),
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 2),
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('删除会话失败: ${dsh.lastError}'),
                    backgroundColor: context.c.danger,
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 3),
                  ),
                );
              }
            }
          },
          child: const Text('确认删除'),
        ),
      ],
    ),
  );
}

/// 快速工作区切换。
void showChatWorkspaceSwitchSheet(BuildContext context, DshService dsh) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: context.c.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(Icons.folder_open_rounded, color: context.c.accent, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '选择工作区 (Select Workspace)',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.c.textPrimary),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: dsh.workspaces.length,
                  itemBuilder: (context, index) {
                    final ws = dsh.workspaces[index];
                    final isSelected = ws.workspaceId == dsh.currentWorkspace?.workspaceId;
                    return ListTile(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      tileColor: isSelected ? context.c.accent.withOpacity(0.08) : null,
                      title: Text(
                        ws.title,
                        style: TextStyle(
                          color: isSelected ? context.c.accent : context.c.textPrimary,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        ws.path,
                        style: TextStyle(fontSize: 11, color: context.c.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        '${ws.sessionCount} 会话',
                        style: TextStyle(color: context.c.textTertiary, fontSize: 12),
                      ),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.pop(ctx);
                        dsh.selectWorkspace(ws);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 打开本会话的轨迹面板（v1.22）：轮 → 事件的时间线。
///
/// 数据从 `dsh.messages` **当场重建**，并且让弹层在自己的路由里订阅一次
/// DshService —— 正在跑的那一轮会随流式事件推进。这和 `_openSessionInfo`
/// 是同一条理由：会话域的数据随时在变，冻住打开那一刻的快照只会让人以为卡死了。
///
/// token 传的是 `lastTurnTokens`：引擎只上报**本轮**的增量，历史轮没有数据源，
/// 面板对拿不到的那些轮显示 `—`（见 `models/trajectory.dart` 的诚实规则 2）。
Future<void> showChatTrajectorySheet(
  BuildContext context,
  DshService dsh, {
  required void Function(String messageId, int? index, int total) onJumpToMessage,
}) async {
  // 先取 NavigatorState：下面闭包里 `context` 是弹层自己的，弹层关掉之后它就失效了。
  final navigator = Navigator.of(context);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => Consumer<DshService>(
      builder: (_, d, __) {
        final messages = d.messages;
        return TrajectorySheet(
          trajectory: Trajectory.build(
            messages,
            liveTurnTokens: d.lastTurnTokens,
            running: d.isSending || d.isSessionRunning,
          ),
          onJumpToMessage: (id) {
            // 关掉面板再滚：轨迹与消息流是同一屏的两个视图，留在面板上看不到
            // 滚动效果，用户会以为"点了没反应"。
            navigator.pop();
            final index = messages.indexWhere((m) => m.id == id);
            onJumpToMessage(id, index >= 0 ? index : null, messages.length);
          },
        );
      },
    ),
  );
}


/// 打开会话信息面板：状态条的任意一段、产出卡的「查看全部」都走这里。
///
/// 面板自己会发一次第三档加载（`jobs` + `schedules` —— 全链路最贵的两个请求，
/// 只在用户明确要看的时候拉），所以这里不重复发，只负责把弹层推起来。
///
/// 面板里的数据是**会话域**的，随时可能被事件刷新（例如作业列表刚拉回来），
/// 所以让它在自己的路由里订阅一次 DshService —— 否则弹层会冻结在打开那一刻的
/// 快照上，懒加载的结果永远看不见。
Future<void> showChatSessionInfoSheet(
  BuildContext context, {
  required SessionInsightSection section,
  required ValueNotifier<String?> deliverableBusy,
  required Future<void> Function(DshService d, DeliverableItem item) openDeliverable,

  /// 归属工作区名（显示在「会话操作」分区的切换项副标题上）。
  /// null 时该项仍可点，只是不显示"当前是哪个工作区"。
  String? workspaceLabel,

  /// 打开运行轨迹面板（旧入口，保留给"从消息长按菜单直接看轨迹"那种场景）。
  /// 为 null 时不影响面板里的「轨迹」tab —— 那是内联渲染的。
  Future<void> Function()? onOpenTrajectory,

  /// 轨迹 tab 里点"跳到消息"时的回调（同 `TrajectorySheet` 的签名）。
  ///
  /// 必须由父级传：滚动与高亮能力在 `chat_view` 手里。
  void Function(String messageId, int? index, int total)? onJumpToMessage,
}) async {
    // 下面这些动作都在**弹层关掉之后**执行，所以要提前取好 Navigator：弹层的
    // context 在 pop 之后已失效。取外层 `context` 的 Navigator 才是安全的。
    final navigator = Navigator.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.c.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      // 面板里的数据是**会话域**的，随时可能被事件刷新（例如作业列表刚拉回来），
      // 所以让它在自己的路由里订阅一次 DshService —— 否则弹层会冻结在打开那一刻
      // 的快照上，懒加载的结果永远看不见。
      builder: (_) => Consumer<DshService>(
        builder: (_, d, __) => ValueListenableBuilder<String?>(
          valueListenable: deliverableBusy,
          builder: (_, busyPath, __) => SessionInfoSheet(
            stats: d.sessionStats,
            turnBurnTokens: d.lastTurnTokens,
            deliverables: d.deliverables,
            changes: d.workspaceChanges,
            changesAvailable: d.workspaceChangesAvailable,
            changesReason: d.workspaceChangesReason,
            // [feat 2026-10-13] 变更清单的来源与"为什么 git 答不出来"。
            // 工作区不是仓库时（多项目工作区的常见形态），面板必须说清原因并给出
            // 相邻仓库，而不是留一片空白。
            changesSource: d.workspaceChangesSource,
            changesNote: d.workspaceChangesNote,
            repoCandidates: d.workspaceRepos,
            jobs: d.jobs,
            jobsUnavailable: d.jobsDegraded.isNotEmpty,
            schedules: d.schedules,
            busyDeliverablePath: busyPath,
            initialSection: section,
            onOpenDeliverable: (item) => openDeliverable(d, item),
            // [feat 2026-10-13] 主点击改为文本预览（下载退到长按），回调为 null 时
            // 面板自动退回旧行为，所以这里不做能力探测。
            onPreviewDeliverable: (item) => d.fetchDeliverableText(item.path),
            onLoadDiff: d.fetchDiff,
            onKillJob: (job) => d.stopJob(job.id),
            // [feat 2026-10-13] 后台任务输出查看器（引擎 `job/follow` 的可续读环）。
            // 传回调即开启入口；null 时面板整块隐藏。
            onLoadJobOutput: (job, from) => d.fetchJobOutput(job.id, from: from),
            onDeleteSchedule: (s) => d.deleteSchedule(s.id),
            onRefresh: d.fetchSessionExtras,
            // [feat 2026-10-12] 子代理 / goal 控制 / 一键诊断。子代理列表属于
            // 第三档懒加载（面板 onRefresh 一起拉）；拉不到（null）整块隐藏。
            subagents: d.subagents,
            subagentsUnavailable: d.subagentsUnavailable,
            onInterruptSubagent: (sub) async {
              final ok = await d.interruptSubagent(sub.id);
              if (ok) await d.fetchSubagents();
              return ok;
            },
            // [feat 2026-10-16] 智能体团队（Lead + 队友 + 共享任务板）。与子代理
            // 同属面板懒加载，同一批拉取。
            team: d.team,
            teamUnavailable: d.teamUnavailable,
            onControlGoal: (action, goal) => d.controlGoal(
                  action,
                  goalId: goal.goalId ?? '',
                  revision: goal.revision ?? 0,
                ),
            onRunDiagnostics: () => d.runDiagnostics(),
            diagnostics: d.diagnostics,
            diagnosticsBusy: d.diagnosticsBusy,
            // [feat 2026-10-17] 「会话操作」分区：顶栏那个 8 项「更多」菜单被删掉后，
            // 这些动作必须有新家 —— 它们都是**会话域**操作，信息面板正是会话域
            // 的唯一总入口。每一项都为 null 时面板不渲染该行（不给死入口）。
            modelLabel: d.currentModel.replaceFirst('cn:', ''),
            permissionLabel: _getPolicyLabel(
              d.getSessionPermission(d.currentSession?.sessionId ?? 'default'),
            ),
            workspaceLabel: workspaceLabel,
            onNewSession: () async => d.createNewSession(),
            onSwitchModel: () async => showChatModelSwitchSheet(context, d),
            onEditPermission: () async => showChatPermissionSheet(context, d),
            // 先 pop 面板再推下一个弹层（`SessionInfoSheet` 内部已保证这一点），
            // 否则两个 bottom sheet 会叠在一起，返回时先看到的是被盖住的那个。
            onSwitchWorkspace: () async => showChatWorkspaceSwitchSheet(context, d),
            onDeleteSession: () async => showChatDeleteCurrentSessionDialog(context, d),
            onOpenTrajectory: onOpenTrajectory,
            // [feat 2026-10-17] 轨迹 tab：把 TrajectorySheet 原样嵌进去。
            //
            // 复用而不是重写：空态、`—` 规则、进行中不封口、上下文块默认折叠、
            // 导出 Markdown 全在它里面，重写一份就是第二套会漂移的规则。
            trajectoryTab: TrajectorySheet(
              trajectory: Trajectory.build(
                d.messages,
                liveTurnTokens: d.lastTurnTokens,
                running: d.isSending || d.isSessionRunning,
              ),
              onJumpToMessage: onJumpToMessage == null
                  ? null
                  : (id) {
                      // 先关面板再滚：轨迹与消息流是同一屏的两个视角，留在面板上
                      // 看不到滚动效果，用户会以为"点了没反应"。
                      navigator.pop();
                      final index = d.messages.indexWhere((m) => m.id == id);
                      onJumpToMessage(id, index >= 0 ? index : null, d.messages.length);
                    },
            ),
            // [fix 2026-10-17] 运维面板不再是会话信息面板的入口。
            //
            // 它是**主机/引擎级**的东西（白名单命令、文件浏览器、连接诊断、目标板），
            // 与会话域无关；挂在会话面板里等于把"服务端运维"伪装成"这个会话的功能"。
            // 已移到「设置 → 诊断与运维」，这里传 null = 该行不渲染。
            onOpenHostOps: null,
          ),
        ),
      ),
    );
}
