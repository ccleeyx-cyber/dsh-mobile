import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/gateway_features.dart';

/// 跨会话搜索命中的解析（2026-11-18 搜索扩到正文）。
///
/// 守两件事：
/// 1. 新字段（matchField/snippet/turn）能读进来，正文命中能露出上下文；
/// 2. **老网关不返回这些键时**不炸、不显示空行，退回原来的「首条 prompt」。
///    这条比第 1 条更重要：App 与网关是分开升级的，混搭是常态。
void main() {
  group('SessionSearchHit 新字段', () {
    test('正文命中：带 snippet 与轮次，预览优先用正文摘要', () {
      final hit = SessionSearchHit.fromJson({
        'workspaceId': 'w1',
        'workspaceTitle': 'dsh_mobile',
        'sessionId': 's1',
        'title': '顶栏改造',
        'firstPrompt': '帮我把顶栏改一下',
        'lastPromptAt': 100,
        'archived': false,
        'matchField': 'body',
        'snippet': '…改完了，AppBar 的高度从 90dp 降到 53dp…',
        'turn': 3,
      });

      expect(hit.matchedInBody, isTrue);
      expect(hit.turn, 3);
      expect(hit.matchLabel, '第 3 轮');
      expect(hit.previewText, contains('AppBar'));
    });

    test('标题命中：没有 snippet 时回退到首条 prompt，标签说"标题"', () {
      final hit = SessionSearchHit.fromJson({
        'sessionId': 's1',
        'title': '顶栏改造',
        'firstPrompt': '第一句话',
        'matchField': 'title',
      });

      expect(hit.matchedInBody, isFalse);
      expect(hit.matchLabel, '标题');
      expect(hit.previewText, '第一句话');
    });

    test('老网关：三个新键都不在时按旧口径渲染，不产生空摘要', () {
      final hit = SessionSearchHit.fromJson({
        'sessionId': 's1',
        'title': '旧会话',
        'firstPrompt': '旧的首条消息',
      });

      expect(hit.matchField, isNull);
      expect(hit.snippet, isEmpty);
      expect(hit.turn, isNull);
      expect(hit.matchLabel, isEmpty, reason: '没有命中位置概念时不要编一个标签');
      expect(hit.previewText, '旧的首条消息');
    });

    test('首条 prompt 也为空时，预览退到工作区名（不能是空白行）', () {
      final hit = SessionSearchHit.fromJson({
        'sessionId': 's1',
        'title': '标题',
        'workspaceTitle': '个人',
      });

      expect(hit.previewText, '个人');
    });
  });
}
