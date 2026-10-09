import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/user_question.dart';

/// 提问 / TODO / 附件的数据契约测试。
///
/// 这些字段直接对应引擎的 `AskUserQuestionRequestEvent`，所以测试重点是
/// **拒绝坏数据**，而不是"能解析好数据"—— 引擎会校验，客户端不校验就会把
/// 一个被上游拒掉的请求当成有效请求提交，最后 agent 收到一个它不认的答案。
void main() {
  group('AskUserQuestionOption', () {
    test('正常解析 label 与 description', () {
      final o = AskUserQuestionOption.fromJson({'label': '继续', 'description': '按原计划执行'});
      expect(o.label, '继续');
      expect(o.description, '按原计划执行');
    });

    test('缺 label 必须抛异常，不能渲染成一个空白按钮', () {
      expect(
        () => AskUserQuestionOption.fromJson({'description': '无 label'}),
        throwsA(isA<FormatException>()),
      );
      expect(() => AskUserQuestionOption.fromJson({'label': ''}), throwsA(isA<FormatException>()));
    });

    test('description 缺失时为 null，且 toJson 不输出空键', () {
      final o = AskUserQuestionOption.fromJson({'label': 'A'});
      expect(o.description, isNull);
      expect(o.toJson().containsKey('description'), isFalse);
    });
  });

  group('AskUserQuestionIntent（批准项按名指定，不靠顺序）', () {
    test('正常解析 kind 与 approve', () {
      final i = AskUserQuestionIntent.fromJson({'kind': 'plan-review', 'approve': '批准'});
      expect(i.kind, 'plan-review');
      expect(i.approve, '批准');
    });

    test('缺 approve 必须抛异常', () {
      // 引擎会拒绝 approve 指向不存在选项的 intent。若客户端容忍它，用户就会
      // 看到一张普通的单选题，而点「批准」其实会被当成否决。
      expect(
        () => AskUserQuestionIntent.fromJson({'kind': 'plan-review'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AskUserQuestionIntent.fromJson({'kind': 'plan-review', 'approve': ''}),
        throwsA(isA<FormatException>()),
      );
    });

    test('approve 按名称匹配，不受选项顺序影响', () {
      final item = AskUserQuestionItem.fromJson({
        'id': 'q1',
        'question': '批准吗',
        'options': [
          {'label': '否决'},
          {'label': '批准'},
        ],
        'intent': {'kind': 'plan-review', 'approve': '批准'},
      });
      // 「批准」排在第二位，依然必须被认出来
      expect(item.approvesWith('批准'), isTrue);
      expect(item.approvesWith('否决'), isFalse);
    });
  });

  group('AskUserQuestionItem', () {
    test('完整结构往返', () {
      final src = {
        'id': 'q1',
        'question': '选哪个数据库?',
        'detail': '当前有 2322 个会话',
        'header': '数据存储',
        'options': [
          {'label': 'SQLite', 'description': '单文件'},
          {'label': 'Postgres'},
        ],
        'multiSelect': true,
        'intent': {'kind': 'plan-review', 'approve': 'Postgres'},
      };
      final item = AskUserQuestionItem.fromJson(src);
      expect(item.id, 'q1');
      expect(item.question, '选哪个数据库?');
      expect(item.detail, '当前有 2322 个会话');
      expect(item.header, '数据存储');
      expect(item.options, hasLength(2));
      expect(item.multiSelect, isTrue);
      expect(item.approvesWith('Postgres'), isTrue);

      final rt = AskUserQuestionItem.fromJson(item.toJson());
      expect(rt.id, item.id);
      expect(rt.options.map((o) => o.label).toList(), ['SQLite', 'Postgres']);
      expect(rt.approvesWith('Postgres'), isTrue);
    });

    test('缺 id 或 question 必须抛异常', () {
      expect(() => AskUserQuestionItem.fromJson({'question': 'x'}), throwsA(isA<FormatException>()));
      expect(() => AskUserQuestionItem.fromJson({'id': 'q1'}), throwsA(isA<FormatException>()));
    });

    test('缺字段一律回落而不是崩（旧网关不一定会给全）', () {
      final item = AskUserQuestionItem.fromJson({'id': 'q1', 'question': '继续?'});
      expect(item.options, isEmpty);
      expect(item.detail, isNull);
      expect(item.header, isNull);
      expect(item.intent, isNull);
      // 引擎默认单选
      expect(item.multiSelect, isFalse);
      expect(item.hasApproveOption, isTrue, reason: '无 intent 时不该声称有批准项');
    });

    test('hasApproveOption：approve 指向不存在的选项时为 false', () {
      final item = AskUserQuestionItem.fromJson({
        'id': 'q1',
        'question': '继续?',
        'options': [
          {'label': 'A'}
        ],
        'intent': {'kind': 'plan-review', 'approve': 'B'},
      });
      expect(item.hasApproveOption, isFalse);
    });
  });

  group('PendingQuestion', () {
    test('正常解析', () {
      final q = PendingQuestion.fromJson({
        'eventId': 'evt-1',
        'sessionId': 'session-abc',
        'questions': [
          {'id': 'q1', 'question': '继续?'}
        ],
      });
      expect(q.eventId, 'evt-1');
      expect(q.sessionId, 'session-abc');
      expect(q.questions, hasLength(1));
    });

    test('缺 eventId 必须抛异常（否则无法把答案送回去）', () {
      expect(
        () => PendingQuestion.fromJson({'questions': [
          {'id': 'q1', 'question': 'x'}
        ]}),
        throwsA(isA<FormatException>()),
      );
    });

    test('questions 为空必须抛异常', () {
      // 引擎保证至少一道题；空批次意味着帧是坏的，而回一个空答案等于告诉
      // agent「人回答了空内容」。
      expect(
        () => PendingQuestion.fromJson({'eventId': 'e', 'questions': <dynamic>[]}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => PendingQuestion.fromJson({'eventId': 'e'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('单个题目坏掉时整批失败，而不是悄悄丢掉那道题', () {
      // 丢掉一道会让 agent 拿到残缺的答案批次，比整批失败更难排查。
      expect(
        () => PendingQuestion.fromJson({
          'eventId': 'e',
          'questions': [
            {'id': 'q1', 'question': '好'},
            {'question': '缺 id'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('sessionId 缺省为 default', () {
      final q = PendingQuestion.fromJson({
        'eventId': 'e',
        'questions': [
          {'id': 'q1', 'question': 'x'}
        ],
      });
      expect(q.sessionId, 'default');
    });
  });

  group(r'AskUserQuestionAnswer（这就是 $events/result 里的 outcome.value）', () {
    test('形状与引擎契约一致', () {
      final batch = const AskUserQuestionAnswer([
        AskUserQuestionAnswerItem(id: 'q1', selected: ['继续']),
        AskUserQuestionAnswerItem(id: 'q2', selected: ['A', 'B'], custom: '都要'),
      ]).toJson();

      expect(batch['answers'], hasLength(2));
      final a0 = (batch['answers'] as List)[0] as Map<String, dynamic>;
      expect(a0['id'], 'q1');
      expect(a0['selected'], ['继续']);
      // 空 custom 不该出现在线上，省 token 也避免上游误判为"填了空字符串"
      expect(a0.containsKey('custom'), isFalse);

      final a1 = (batch['answers'] as List)[1] as Map<String, dynamic>;
      expect(a1['selected'], ['A', 'B']);
      expect(a1['custom'], '都要');
    });

    test('custom 会被 trim，且只有空白时不输出', () {
      const t = AskUserQuestionAnswerItem(id: 'q', selected: [], custom: '  hi  ');
      expect(t.toJson()['custom'], 'hi');
      const blank = AskUserQuestionAnswerItem(id: 'q', selected: [], custom: '   ');
      expect(blank.toJson().containsKey('custom'), isFalse);
    });

    test('isAnswered：空 selected + 空 custom = 未作答', () {
      expect(
        const AskUserQuestionAnswerItem(id: 'q', selected: []).isAnswered,
        isFalse,
        reason: '这正是 answerQuestion 要拒绝提交的状态',
      );
      expect(
        const AskUserQuestionAnswerItem(id: 'q', selected: [], custom: '   ').isAnswered,
        isFalse,
      );
      expect(
        const AskUserQuestionAnswerItem(id: 'q', selected: ['A']).isAnswered,
        isTrue,
      );
      expect(
        const AskUserQuestionAnswerItem(id: 'q', selected: [], custom: '自己写').isAnswered,
        isTrue,
      );
    });
  });

  group('TodoItem', () {
    test('正常解析并往返', () {
      final t = TodoItem.fromJson({'content': '读源码', 'status': 'in_progress'});
      expect(t.content, '读源码');
      expect(t.isActive, isTrue);
      expect(t.isDone, isFalse);
      expect(t.toJson(), {'content': '读源码', 'status': 'in_progress'});
    });

    test('completed / pending 判定', () {
      expect(TodoItem.fromJson({'content': 'a', 'status': 'completed'}).isDone, isTrue);
      expect(TodoItem.fromJson({'content': 'a', 'status': 'pending'}).isDone, isFalse);
      expect(TodoItem.fromJson({'content': 'a', 'status': 'pending'}).isActive, isFalse);
    });

    test('不认识的状态回落成 pending，而不是抛异常', () {
      // 一个未知状态不该让整个面板消失 —— 引擎以后加新状态时也不能白屏。
      final t = TodoItem.fromJson({'content': 'a', 'status': 'blocked'});
      expect(t.status, 'pending');
    });

    test('缺 content 必须抛异常（空任务项没有意义）', () {
      expect(() => TodoItem.fromJson({'status': 'pending'}), throwsA(isA<FormatException>()));
      expect(() => TodoItem.fromJson({'content': ''}), throwsA(isA<FormatException>()));
    });

    test('缺 status 回落成 pending', () {
      expect(TodoItem.fromJson({'content': 'a'}).status, 'pending');
    });
  });

  group('AttachmentRef', () {
    test('正常解析，且支持 attachmentId 别名', () {
      final a = AttachmentRef.fromJson({
        'id': 'att-1',
        'mimeType': 'image/png',
        'width': 800,
        'height': 600,
        'bytes': 20480,
      });
      expect(a.id, 'att-1');
      expect(a.mimeType, 'image/png');
      expect(a.width, 800);
      expect(a.byteSize, 20480);
      expect(a.isImage, isTrue);
    });

    test('缺 id 必须抛异常', () {
      expect(() => AttachmentRef.fromJson({'mimeType': 'image/png'}), throwsA(isA<FormatException>()));
    });

    test('非图片不算图片', () {
      expect(AttachmentRef.fromJson({'id': 'a', 'mimeType': 'application/pdf'}).isImage, isFalse);
      expect(AttachmentRef.fromJson({'id': 'a', 'mimeType': 'image/webp'}).isImage, isTrue);
    });

    test('尺寸缺失时为 null 而不是 0（0 会渲染成 0×0 的坏图）', () {
      final a = AttachmentRef.fromJson({'id': 'a'});
      expect(a.width, isNull);
      expect(a.height, isNull);
      expect(a.byteSize, isNull);
      expect(a.mimeType, 'application/octet-stream');
    });

    test('字符串数字被解析（网关透传的 JSON 形状不保证）', () {
      final a = AttachmentRef.fromJson({'id': 'a', 'width': '640', 'bytes': '1024'});
      expect(a.width, 640);
      expect(a.byteSize, 1024);
    });
  });
}