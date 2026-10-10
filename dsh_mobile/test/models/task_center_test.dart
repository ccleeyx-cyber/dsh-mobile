import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/task_center.dart';

/// 任务中心模型的解析测试（v1.13）。
///
/// 这些模型直接对着网关 JSON，所以两类错误最值得钉住：
///  1. **不该抛**：一个畸形字段不能让整页崩掉 —— 十行里有一行形状不对，
///     另外九行必须照常显示。
///  2. **unknown ≠ 0**：不知道的数值必须是 null，界面上渲染成 "—"。
///     把未知当 0 是主动误导（"这次改了 0 行" vs "行数未知"）。
void main() {
  group('QueueItem', () {
    test('解析文本与附件数', () {
      final q = QueueItem.fromJson({'id': 'm1', 'text': '部署', 'attachments': 2});
      expect(q.id, 'm1');
      expect(q.text, '部署');
      expect(q.attachments, 2);
    });

    test('缺字段不抛，附件数视为 0', () {
      final q = QueueItem.fromJson(const {});
      expect(q.id, '');
      expect(q.text, '');
      expect(q.attachments, 0);
    });

    test('纯附件消息用附件数当标签', () {
      expect(QueueItem.fromJson({'id': 'm', 'text': '', 'attachments': 3}).label, '（3 个附件）');
      expect(QueueItem.fromJson({'id': 'm', 'text': '你好'}).label, '你好');
    });
  });

  group('DeliverableItem', () {
    test('取出文件名与扩展名（两种路径分隔符都要认）', () {
      final a = DeliverableItem.fromJson({'path': 'C:/w/out/report.docx', 'display': 'out/report.docx'});
      expect(a.fileName, 'report.docx');
      expect(a.extension, 'docx');
      final b = DeliverableItem.fromJson({'path': r'C:\w\out\表.xlsx'});
      expect(b.fileName, '表.xlsx');
      expect(b.extension, 'xlsx');
    });

    test('没有扩展名时不是空指针也不是异常', () {
      expect(DeliverableItem.fromJson({'path': 'README'}).extension, '');
      expect(DeliverableItem.fromJson({'path': 'a.'}).extension, '');
    });
  });

  group('WorkspaceChange', () {
    test('未跟踪文件没有行数时显示破折号，而不是 +0 −0', () {
      final c = WorkspaceChange.fromJson({'path': 'new.txt', 'status': '??'});
      expect(c.delta, '—');
      expect(c.label, '新增(未跟踪)');
    });

    test('有行数时按 +a −d 渲染', () {
      final c = WorkspaceChange.fromJson({'path': 'a.ts', 'status': 'M', 'added': 5, 'deleted': 2});
      expect(c.delta, '+5 −2');
      expect(c.label, '修改');
    });

    test('二进制文件显式标注', () {
      final c = WorkspaceChange.fromJson({'path': 'logo.png', 'status': 'M', 'binary': true});
      expect(c.delta, '二进制');
    });
  });

  group('SessionStats', () {
    test('未知总量保持 null（不是 0）', () {
      final s = SessionStats.fromJson(const {'source': 'none'});
      expect(s.source, 'none');
      expect(s.totalTokens, isNull);
      expect(s.hasUsage, isFalse);
      expect(s.contextFraction, isNull);
    });

    test('有窗口时给出占用比例，且被夹在 0..1', () {
      final s = SessionStats.fromJson({
        'source': 'live',
        'totalTokens': 150,
        'pressureTokens': 64000,
        'contextWindow': 128000,
      });
      expect(s.hasUsage, isTrue);
      expect(s.contextFraction, closeTo(0.5, 0.001));

      final over = SessionStats.fromJson({
        'source': 'live',
        'pressureTokens': 200000,
        'contextWindow': 128000,
      });
      expect(over.contextFraction, 1.0);
    });

    test('窗口为 0 时不除零', () {
      final s = SessionStats.fromJson({'source': 'live', 'pressureTokens': 10, 'contextWindow': 0});
      expect(s.contextFraction, isNull);
    });

    test('goal 解析出阶段中文标签', () {
      final s = SessionStats.fromJson({
        'source': 'cache',
        'goal': {'objective': '跑通部署', 'phase': 'blocked', 'roundsStarted': 3, 'maxGoalRounds': 40, 'blockedReason': '卡在编译'},
      });
      expect(s.goal?.phaseLabel, '受阻');
      expect(s.goal?.objective, '跑通部署');
      expect(s.goal?.roundsStarted, 3);
    });
  });

  group('ScheduleItem / JobItem', () {
    test('定时任务与作业字段解析', () {
      final s = ScheduleItem.fromJson({'id': 's1', 'kind': 'daily', 'title': '日报', 'schedule': '每天 09:00'});
      expect(s.title, '日报');
      expect(s.schedule, '每天 09:00');

      final j = JobItem.fromJson({'id': 'bash-1', 'kind': 'bash', 'label': 'npm test', 'status': 'running'});
      expect(j.isLive, isTrue);
      expect(j.statusLabel, '运行中');
      expect(JobItem.fromJson({'id': 'x', 'status': 'killed'}).isLive, isFalse);
      expect(JobItem.fromJson({'id': 'x', 'status': 'killed'}).statusLabel, '已终止');
    });
  });

  group('PushConfig', () {
    test('三项齐全才算配置完成', () {
      expect(PushConfig.fromJson({'enabled': true, 'url': 'https://ntfy.sh', 'topic': 't'}).configured, isTrue);
      expect(PushConfig.fromJson({'enabled': true, 'url': 'https://ntfy.sh', 'topic': ''}).configured, isFalse);
      expect(PushConfig.fromJson({'enabled': false, 'url': 'https://ntfy.sh', 'topic': 't'}).configured, isFalse);
      expect(PushConfig.fromJson(const {}).configured, isFalse);
    });
  });
}
