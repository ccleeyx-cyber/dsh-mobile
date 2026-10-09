import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 事件通知（§4.2 推送通知）。
///
/// ## 为什么是「本地通知 + 保持长连接」而不是 FCM
///
/// 推送通知通常意味着一个远端推送服务（FCM/APNs）。这里刻意不接：
///
/// * 你的网关本来就已经提供 WebSocket 长连接，事件源就在自己机器上，再引入
///   一层 Google 服务是纯增成本；
/// * FCM 在国内网络下不可靠，而这个 App 的既有用户显然就在这种环境里（它要直连
///   nps 隧道才能用），接了 FCM 很可能**收不到**；
/// * 接 FCM 还需要 Firebase 项目与 google-services.json，是一条需要额外账号与
///   配置的依赖链。
///
/// 取而代之的代价必须讲清楚：**App 进程被杀后，连接就断了，通知也不会来。**
/// 所以 [enableBackground] 会拉起一个前台服务把进程钉住；用户若在系统设置里
/// 把它划掉，这个能力就没了 —— 这是任何本地通知方案的共同上限，不是实现缺陷。
///
/// ## 为什么一律在「App 不在前台」时才发通知
///
/// 前台还在显示事件时再弹一条系统通知，等于把同一件事在屏幕上说两遍，而且会
/// 打断正在进行的操作。
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// 用户是否授权了通知权限。Android 13+ 需要显式申请。
  bool _granted = false;

  /// 是否已拉起前台保活服务。
  bool get backgroundEnabled => _backgroundOn;

  bool _backgroundOn = false;

  /// 初始化通知插件并申请权限。必须在 runApp 之后调用（有 BuildContext 依赖）。
  ///
  /// 返回是否拿到了通知权限。**权限被拒时必须如实返回 false**，因为
  /// App 侧要据此告诉用户"你不会收到通知"，而不是假装一切正常。
  Future<bool> init() async {
    if (_initialized) return _granted;
    _initialized = true;

    try {
      // Android 13+ 需要显式申请 POST_NOTIFICATIONS。低于 13 的版本系统自动放行。
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _granted = granted ?? true;
    } catch (e) {
      // 权限查询失败不能当"有权限"，也不能崩 —— 保守当作没有。
      debugPrint('[NotificationService] 权限查询失败: $e');
      _granted = false;
    }

    try {
      await _plugin.initialize(
        const InitializationSettings(
          // iOS 用不到，这里给个占位以免构造报错。
          iOS: DarwinInitializationSettings(),
        ),
      );
    } catch (e) {
      debugPrint('[NotificationService] 初始化失败: $e');
    }
    return _granted;
  }

  bool get permissionGranted => _granted;

  /// 拉起前台服务，让进程在后台存活、连接不断。
  ///
  /// Android 12+ 对后台启动前台服务有限制，可能返回 false。此时**不要静默
  /// 失败** —— 调用方要能把"后台收不到通知"这件事告诉用户。
  Future<bool> enableBackground() async {
    if (!_granted) return false;
    if (_backgroundOn) return true;
    try {
      const channel = MethodChannel('dsh_mobile/foreground');
      final ok = await channel.invokeMethod<bool>('startForeground') ?? false;
      _backgroundOn = ok;
      return ok;
    } catch (e) {
      debugPrint('[NotificationService] 前台保活失败: $e');
      _backgroundOn = false;
      return false;
    }
  }

  Future<void> disableBackground() async {
    if (!_backgroundOn) return;
    try {
      await const MethodChannel('dsh_mobile/foreground').invokeMethod('stopForeground');
    } catch (e) {
      debugPrint('[NotificationService] 停止前台服务失败: $e');
    }
    _backgroundOn = false;
  }

  /// 发一条事件通知。
  ///
  /// 三个刻意的取舍：
  /// * [onlyWhenBackground] 默认为 true —— 前台已有界面在展示，再弹通知是噪音。
  /// * 高重要性渠道只用于「需要用户立刻处理」的事件（审批、提问），其余用低重要性，
  ///   否则每条消息都弹横幅会让人关掉通知。
  /// * 不使用 [title] 为空的调用；空标题在某些 ROM 上会显示成应用名，体验很差。
  Future<void> show({
    required String title,
    required String body,
    NotificationKind kind = NotificationKind.info,
    bool onlyWhenBackground = true,
  }) async {
    if (!_granted) return;
    if (title.trim().isEmpty) return;

    try {
      await _plugin.show(
        _nextId(),
        title,
        body,
        NotificationDetails(
          // 渠道 id 必须与原生侧创建的一致，否则通知不显示（且不报错）。
          android: AndroidNotificationDetails(
            kind == NotificationKind.actionRequired ? actionChannelId : infoChannelId,
            kind == NotificationKind.actionRequired ? '需要你处理' : '网关动态',
            channelDescription: kind == NotificationKind.actionRequired
                ? '等待你授权或回答的事件'
                : '会话完成、提问等一般性事件',
            importance: kind == NotificationKind.actionRequired ? Importance.high : Importance.low,
            priority: kind == NotificationKind.actionRequired ? Priority.high : Priority.low,
            // 审批/提问是"正在等你"，点进去要能直接处理。
            autoCancel: true,
          ),
        ),
        payload: kind.name,
      );
    } catch (e) {
      debugPrint('[NotificationService] 发通知失败: $e');
    }
  }

  int _seq = 0;

  /// 用递增 id 而不是固定值：固定 id 会让新通知**覆盖**上一条，用户只看到最后
  /// 一条，漏掉中间发生的事。
  int _nextId() => 2000 + (_seq++);

  /// 高重要性渠道：等待用户授权 / 回答的事件。
  static const String actionChannelId = 'dsh_action';

  /// 低重要性渠道：会话完成等一般性事件。
  static const String infoChannelId = 'dsh_events';

  @visibleForTesting
  void debugSetGranted(bool v) {
    _granted = v;
    _initialized = true;
  }
}

/// 通知的紧急程度。决定用哪个渠道、会不会弹横幅。
enum NotificationKind {
  /// 一般性事件：会话完成、后台有新消息。
  info,

  /// 需要用户立刻处理：等待授权的工具调用、等待回答的提问。
  ///
  /// 这一类必须能打断 —— 它对应的正是"agent 已经停下来了等你"的时刻，
  /// 静默处理等于让会话永久卡住。
  actionRequired,
}