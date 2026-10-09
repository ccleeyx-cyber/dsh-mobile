import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/models/chat_message.dart';
import 'package:dsh_mobile/services/draft_store.dart';
import 'package:dsh_mobile/views/widgets/message_search.dart';

/// 离线草稿（v1.4.2）+ 会话内查找（v1.4.2）的测试。
///
/// 草稿部分全部用 `setMockInitialValues` 内存 mock，不碰任何真实配置
/// （和 storage_service_profiles_test 同一个约束：不污染真实数据）。
void main() {
  group('DraftStore', () {
    late DraftStore store;
    late SharedPreferences prefs;

    setUp(() async {
      // mock 模式下 getInstance() 立即完成，但 API 是 Future，所以 setUp 必须 async。
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      store = DraftStore.instance..attach(prefs);
    });

    test('空草稿返回空串', () {
      expect(store.read('s1'), '');
      expect(store.hasDraft('s1'), isFalse);
    });

    test('写入后能读回', () {
      store.write('s1', '你好');
      expect(store.read('s1'), '你好');
      expect(store.hasDraft('s1'), isTrue);
    });

    test('按会话隔离：切会话不串内容', () {
      store.write('s-a', '给 A 的');
      store.write('s-b', '给 B 的');
      expect(store.read('s-a'), '给 A 的');
      expect(store.read('s-b'), '给 B 的');
      // 清 A 不影响 B
      store.clear('s-a');
      expect(store.read('s-a'), '');
      expect(store.read('s-b'), '给 B 的');
    });

    test('写空串等价于清除', () {
      store.write('s1', '内容');
      store.write('s1', '');
      expect(store.read('s1'), '');
      expect(store.hasDraft('s1'), isFalse);
    });

    test('纯空白不算有草稿（用户清空输入框的常见结果）', () {
      store.write('s1', '   \n  ');
      expect(store.hasDraft('s1'), isFalse);
    });

    test('flushNow 之后重启（重新 attach 同一 prefs）能读回', () {
      store.write('s1', '重要的半句话');
      store.flushNow();

      // 模拟应用重启：新建 store，attach 同一个 prefs
      final restored = DraftStore.instance..attach(prefs);
      expect(restored.read('s1'), '重要的半句话');
    });

    test('超出上限时淘汰最旧的会话', () {
      for (var i = 0; i < DraftStore.maxDrafts + 12; i++) {
        store.write('s$i', '内容 $i');
      }
      final all = store.all();
      expect(all.length, DraftStore.maxDrafts);
      // 最旧的被淘汰，最新的还在
      expect(store.read('s0'), '');
      expect(store.read('s${DraftStore.maxDrafts + 11}'), isNotEmpty);
    });

    test('session key 里的特殊字符不会破坏存储', () {
      const tricky = 'session/../weird?key=值';
      store.write(tricky, '草稿');
      expect(store.read(tricky), '草稿');
      store.flushNow();
      final restored = DraftStore.instance..attach(prefs);
      expect(restored.read(tricky), '草稿');
    });

    test('all() 返回可读的 session key', () {
      store.write('session-abc', 'x');
      expect(store.all().map((e) => e.key), contains('session-abc'));
    });

    test('dispose 会把待写内容落盘', () {
      store.write('s1', '快写我');
      store.dispose();
      final restored = DraftStore.instance..attach(prefs);
      expect(restored.read('s1'), '快写我');
    });
  });

  group('MessageSearch', () {
    ChatMessage msg(
      String id,
      String content, {
      String? thinking,
      List<ToolExecution> tools = const [],
    }) {
      return ChatMessage(
        id: id,
        role: 'assistant',
        content: content,
        thinking: thinking,
        tools: tools,
      );
    }

    test('空查询返回空结果（而不是全部消息）', () {
      final msgs = [msg('1', 'abc')];
      expect(MessageSearch.search(msgs, ''), isEmpty);
      expect(MessageSearch.search(msgs, '   '), isEmpty);
    });

    test('大小写不敏感', () {
      final msgs = [msg('1', 'Hello World')];
      expect(MessageSearch.search(msgs, 'hello'), hasLength(1));
      expect(MessageSearch.search(msgs, 'WORLD'), hasLength(1));
    });

    test('找到正文中的命中并记录偏移', () {
      final msgs = [msg('1', '前面一段中间 target 后面')];
      final hits = MessageSearch.search(msgs, 'target');
      expect(hits, hasLength(1));
      // '前面一段中间 ' 是 7 个字符
      expect(hits.first.matchStart, 7);
      expect(hits.first.matchEnd, 13);
      expect(hits.first.field, SearchField.content);
      expect(hits.first.messageIndex, 0);
    });

    test('同一条消息里的多次匹配都报告，且不重叠', () {
      final msgs = [msg('1', 'aa aa aa')];
      final hits = MessageSearch.search(msgs, 'aa');
      // 3 处不重叠匹配（"aa aa aa"）
      expect(hits.length, greaterThanOrEqualTo(3));
      for (var i = 1; i < hits.length; i++) {
        expect(hits[i].matchStart, greaterThanOrEqualTo(hits[i - 1].matchEnd));
      }
    });

    test('思考内容也可搜，字段标为 thinking', () {
      final msgs = [msg('1', '答案里没有', thinking: '思考里有 needle')];
      final hits = MessageSearch.search(msgs, 'needle');
      expect(hits, hasLength(1));
      expect(hits.first.field, SearchField.thinking);
    });

    test('工具名与输出可搜', () {
      final msgs = [
        msg('1', '', tools: [
          ToolExecution(name: 'bash', input: '', output: '删除完成'),
        ]),
      ];
      expect(MessageSearch.search(msgs, 'bash').first.field, SearchField.toolName);
      expect(MessageSearch.search(msgs, '删除完成').first.field, SearchField.toolOutput);
    });

    test('排序：正文优先于思考，思考优先于工具', () {
      final msgs = [
        msg('1', '', thinking: 'thinking-hit', tools: [
          ToolExecution(name: 'tool-hit', input: '', output: ''),
        ]),
      ];
      // 正文里也有一个命中
      final withContent = [msg('1', 'content-hit', thinking: 'thinking-hit', tools: [
        ToolExecution(name: 'tool-hit', input: '', output: ''),
      ])];
      final hits = MessageSearch.search(withContent, 'hit');
      // "content-hit" "thinking-hit" "tool-hit" 都含 "hit"
      expect(hits.first.field, SearchField.content);
      final fields = hits.map((h) => h.field).toList();
      expect(fields.indexOf(SearchField.content), lessThan(fields.indexOf(SearchField.thinking)));
      expect(fields.indexOf(SearchField.thinking), lessThan(fields.indexOf(SearchField.toolName)));
      // 正文不存在时，thinking 仍可搜
      expect(MessageSearch.search(msgs, 'hit').first.field, SearchField.thinking);
    });

    test('context 截断并加省略号，且包含命中', () {
      final long = 'x' * 200;
      final msgs = [msg('1', '$long${'needle'}$long')];
      final hit = MessageSearch.search(msgs, 'needle').first;
      final ctx = hit.context(radius: 20);
      expect(ctx, contains('needle'));
      expect(ctx.length, lessThan(200));
      expect(ctx, startsWith('…'));
      expect(ctx, endsWith('…'));
    });

    test('短文本的 context 原样返回、不加省略号', () {
      final msgs = [msg('1', 'short needle here')];
      final hit = MessageSearch.search(msgs, 'needle').first;
      expect(hit.context(radius: 40), 'short needle here');
    });

    test('collapse：同一条消息的多次命中合成一行并计数', () {
      final msgs = [msg('1', 'a a a')];
      final hits = MessageSearch.search(msgs, 'a');
      final collapsed = MessageSearch.collapse(hits);
      expect(collapsed, hasLength(1));
      expect(collapsed.first.count, greaterThanOrEqualTo(3));
      expect(collapsed.first.first.messageIndex, 0);
    });

    test('collapse：不同消息分行', () {
      final msgs = [msg('1', 'x'), msg('2', 'x'), msg('3', 'x')];
      final collapsed = MessageSearch.collapse(MessageSearch.search(msgs, 'x'));
      expect(collapsed, hasLength(3));
    });

    test('fieldLabel 返回中文标签', () {
      expect(MessageSearch.fieldLabel(SearchField.content), '正文');
      expect(MessageSearch.fieldLabel(SearchField.thinking), '思考');
      expect(MessageSearch.fieldLabel(SearchField.toolName), '工具');
      expect(MessageSearch.fieldLabel(SearchField.toolOutput), '输出');
    });

    test('查询含正则元字符时按字面匹配，不抛异常', () {
      // 用户会在搜索框里敲这些字符。若内部用正则且未转义，'.*' 会匹配一切，
      // '\d' 会报模式错误。
      final msgs = [msg('1', r'价格是 $100 和 a.c')];
      // 文本里没有字面量 '.*'，所以应当零命中 —— 若返回非零，说明内部把 '.' 当通配了。
      expect(MessageSearch.search(msgs, '.*'), isEmpty);
      // 文本里没有字面量 '\d'，零命中，且不抛异常。
      expect(MessageSearch.search(msgs, r'\d'), isEmpty);
      // 字面量 'a.c' 确实在文本里。
      expect(MessageSearch.search(msgs, 'a.c'), hasLength(1));
      expect(MessageSearch.search(msgs, r'$100'), hasLength(1));
    });

    test('collapse 的 count 与 totalHits 关系一致（供 UI 显示"N 条 / M 处"）', () {
      final msgs = [msg('1', 'a a'), msg('2', 'b')];
      final hits = MessageSearch.search(msgs, 'a');
      expect(MessageSearch.search(msgs, 'a'), hasLength(2));
      final collapsed = MessageSearch.collapse(MessageSearch.search(msgs, 'a'));
      expect(collapsed, hasLength(1));
      expect(collapsed.first.count, hits.length);
    });
  });
}