import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 桌面小组件的数据出口（v1.35 / 3.5）。
///
/// ## 为什么由 Flutter 推、原生只负责渲染
///
/// 小组件要显示的是"此刻有没有活要处理"，而这些状态全在 Dart 侧（连接、会话、
/// 待审批）。让原生自己拉一遍网关等于把鉴权、重连、对账再实现一次，且两份状态
/// 必然漂移。所以这里是**单向**的：Dart 变了就推一份快照，原生写进
/// SharedPreferences 并刷新 RemoteViews。
///
/// ## 为什么不直接在小部件上点批准
///
/// 小组件的点击面没有"看清命令原文"的位置，一次误触就等于在完全访问策略下
/// 放行一条命令。所以小组件只做两件事：告诉你有事、点开进 App。这是刻意的
/// 能力上限，不是没做完。
class WidgetBridge {
  WidgetBridge._();

  static const MethodChannel _channel = MethodChannel('dsh_mobile/widget');

  /// 上一次推送时间与内容。节流是为了不让每次 delta 都把 RemoteViews 刷一遍。
  static DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  static Map<String, Object?>? _lastData;

  /// 最短推送间隔。低于它的连续变更合并成一次（force 时不受限）。
  static const Duration minInterval = Duration(seconds: 5);

  /// 推送一份状态快照。永不抛异常 —— 小组件不存在（多数机型默认没添加）时
  /// MethodChannel 会返回 missing_plugin，那属于正常路径。
  static Future<void> push(
    Map<String, Object?> data, {
    bool force = false,
    bool throttle = true,
  }) async {
    final now = DateTime.now();
    if (!force && throttle) {
      if (now.difference(_lastPush) < minInterval) return;
      if (_sameAs(_lastData, data)) return;
    }
    _lastPush = now;
    _lastData = Map<String, Object?>.from(data);
    try {
      await _channel.invokeMethod<void>('update', data);
    } catch (e) {
      // 没有原生实现 / 没有部件：静默。小组件是增强，不是主链路。
      debugPrint('[WidgetBridge] 推送失败（忽略）: $e');
    }
  }

  /// 清空（断开连接、删网关时用）。
  static Future<void> clear() async {
    _lastData = null;
    try {
      await _channel.invokeMethod<void>('clear');
    } catch (e) {
      debugPrint('[WidgetBridge] 清空失败（忽略）: $e');
    }
  }

  @visibleForTesting
  static void debugReset() {
    _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
    _lastData = null;
  }

  static bool _sameAs(Map<String, Object?>? a, Map<String, Object?> b) {
    if (a == null || a.length != b.length) return false;
    for (final entry in b.entries) {
      if (a[entry.key] != entry.value) return false;
    }
    return true;
  }
}
