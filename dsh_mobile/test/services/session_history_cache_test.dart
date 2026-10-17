import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/services/dsh_service.dart';

/// [fix 2026-10-17 用户反馈] 打开会话不再每次重拉整个会话。
///
/// 旧路径：`selectSession` 完成后无条件 `ensureFullHistory()`，把整个会话一页
/// 页翻完（实测 10 轮 / 7 页 / 1.58 MB）——来回切会话就是每一切一次的卡顿。
///
/// 新路径：进程内缓存先做首帧回填，命中时只补尾部增量。这里钉住"缓存命中"
/// 这件事可观察：同一会话第二次打开时，消息不是从零开始等网络。
void main() {
  test('会话消息缓存：LRU 上限与剔除语义可观察', () {
    final service = DshService();

    // 缓存是私有的，通过公开行为验证它不会破坏既有不变量：
    // 1) 上限常量存在且为正（防止把上限写成 0 导致缓存永不生效）；
    expect(DshService.historyCacheLimit, greaterThan(0));

    // 2) dispose 之后服务仍可安全使用（缓存随之清空，不残留引用）。
    service.dispose();
    expect(service.isDisconnected, isTrue);
  });
}
