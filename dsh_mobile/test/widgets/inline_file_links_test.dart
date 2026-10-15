import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/task_center.dart';
import 'package:dsh_mobile/widgets/inline_file_links.dart';

/// 正文产物链接化的回归测试。
///
/// 这一层的失败模式不是"崩了"，而是**多链**（把正文里不相干的路径变成链接，用户
/// 点开得到一次报错）和**漏链**（反引号里那个最常见写法没被认出来）。所以下面
/// 每组断言都成对：该变的必须变，不该动的一个字符都不能动。
void main() {
  // 测试数据一律用 REST 返回的形状：绝对路径 + 保留下来的相对 display，
  // 且 display 用反斜杠（这正是网关回传的形态，见 extractDeliverables）。
  const report = DeliverableItem(
    path: r'E:\workspace\个人\dsh_mobile\out\报表.xlsx',
    display: r'out\报表.xlsx',
    description: '本月汇总',
    turn: 3,
    seq: 30,
  );
  const readme = DeliverableItem(
    path: r'E:\workspace\个人\dsh_mobile\README.md',
    display: 'README.md',
    description: '',
    turn: 2,
    seq: 20,
  );
  const paren = DeliverableItem(
    path: r'E:\workspace\个人\dsh_mobile\out\报告(1).docx',
    display: r'out\报告(1).docx',
    description: '',
    turn: 4,
    seq: 40,
  );
  const all = <DeliverableItem>[report, readme, paren];

  /// 取第一个链接的 href —— 用它把"链到了哪个文件"断言成路径，而不是断言一长串
  /// 百分号编码（那种断言改一次编码方式就全红，且看不出到底链对了没有）。
  String firstHref(String markdown) {
    final m = RegExp(r'\]\(([^)]*)\)').firstMatch(markdown);
    expect(m, isNotNull, reason: '这段文本里应该产出了一个链接：$markdown');
    return m!.group(1)!;
  }

  group('href 编解码：路径原样往返', () {
    test('绝对路径往返一致', () {
      final href = encodeDshFileHref(report.path);
      expect(decodeDshFileHref(href), report.path);
    });

    test('带括号的路径必须完整往返（括号不编码就会截断 markdown 链接）', () {
      final href = encodeDshFileHref(paren.path);
      expect(href, isNot(contains('(')));
      expect(href, isNot(contains(')')));
      expect(decodeDshFileHref(href), paren.path);
    });

    test('不是本 scheme 的 href 一律不认', () {
      expect(decodeDshFileHref('https://example.com/a.md'), isNull);
      expect(decodeDshFileHref(null), isNull);
      expect(isDshFileHref(encodeDshFileHref(report.path)), isTrue);
      expect(isDshFileHref('https://example.com'), isFalse);
    });

    test('坏编码返回 null 而不是抛进渲染帧', () {
      expect(decodeDshFileHref('dsh-file:%E6%8A'), isNull);
    });

    test('空路径不算产物链接', () {
      expect(decodeDshFileHref('dsh-file:'), isNull);
    });
  });

  group('linkify：该变的必须变', () {
    test('裸文件名变成链接，显示文字保持原样', () {
      final out = linkifyDeliverableRefs('已生成 报表.xlsx 文件', all);
      expect(out, startsWith('已生成 [报表.xlsx](dsh-file:'));
      expect(out, endsWith(') 文件'));
      expect(decodeDshFileHref(firstHref(out)), report.path);
    });

    test('正文写正斜杠、清单里是反斜杠时也认（同一个文件的两种写法）', () {
      final out = linkifyDeliverableRefs('见 out/报表.xlsx 这一份', all);
      expect(decodeDshFileHref(firstHref(out)), report.path);
    });

    test('相对路径按最长优先，不会被文件名吃掉一半', () {
      final out = linkifyDeliverableRefs('见 out/报表.xlsx', all);
      expect(out, startsWith('见 [out/报表.xlsx](dsh-file:'));
      expect(decodeDshFileHref(firstHref(out)), report.path);
    });

    test('行内 code 里整段就是产物名：连反引号一起换成链接', () {
      // agent 提产物最常见的写法就是这个，而反引号内不解析 markdown ——
      // 留着反引号用户看到的会是一串源码。
      final out = linkifyDeliverableRefs('已生成 `报表.xlsx`', all);
      expect(out, startsWith('已生成 [报表.xlsx](dsh-file:'));
      expect(out, isNot(contains('`')));
      expect(decodeDshFileHref(firstHref(out)), report.path);
    });

    test('带括号的文件名也能链接化，且不破坏链接语法', () {
      final out = linkifyDeliverableRefs('发你了 报告(1).docx', all);
      expect(out, contains('[报告(1).docx]('));
      expect(decodeDshFileHref(firstHref(out)), paren.path);
    });

    test('同名文件出现多次时每一处都链上', () {
      final out = linkifyDeliverableRefs('先看 报表.xlsx，再看 报表.xlsx', all);
      expect(RegExp(r'\]\(dsh-file:').allMatches(out).length, 2);
    });
  });

  group('linkify：不该动的一个字符都不动', () {
    test('不在清单里的文件原样保留（白名单之外零误伤）', () {
      const text = '见 other.xlsx 和 out/别的.md';
      expect(linkifyDeliverableRefs(text, all), text);
    });

    test('空清单时不改任何东西', () {
      const text = '已生成 报表.xlsx';
      expect(linkifyDeliverableRefs(text, const <DeliverableItem>[]), text);
    });

    test('围栏代码块里的路径保持字面量', () {
      const text = '```bash\ncat 报表.xlsx\n```';
      expect(linkifyDeliverableRefs(text, all), text);
    });

    test('行内 code 里还有别的字符时整段不动', () {
      const text = '见 `out/报表.xlsx 说明`';
      expect(linkifyDeliverableRefs(text, all), text);
    });

    test('已经是链接的地方不重复处理', () {
      const text = '[报表.xlsx](https://example.com/a)';
      expect(linkifyDeliverableRefs(text, all), text);
    });

    test('裸 URL 不动（URL 里出现文件名不等于产物引用）', () {
      const text = '见 https://example.com/报表.xlsx 下载';
      expect(linkifyDeliverableRefs(text, all), text);
    });

    test('词内命中不算：my报表.xlsx 不是 out\\报表.xlsx', () {
      const text = 'my报表.xlsx';
      expect(linkifyDeliverableRefs(text, all), text);
    });

    test('作为更长路径前缀时不算：out\\报表.xlsx\\bak', () {
      const text = r'out\报表.xlsx\bak';
      expect(linkifyDeliverableRefs(text, all), text);
    });

    test('幂等：对已处理过的文本再跑一次结果相同', () {
      final once = linkifyDeliverableRefs('已生成 `报表.xlsx` 和 out/报表.xlsx', all);
      expect(linkifyDeliverableRefs(once, all), once);
    });
  });

  group('matchDeliverableByRef：从用户写下的字样回到清单行', () {
    test('绝对路径精确命中', () {
      expect(matchDeliverableByRef(all, report.path)?.path, report.path);
    });

    test('正斜杠写法也命中', () {
      expect(matchDeliverableByRef(all, r'out/报表.xlsx')?.path, report.path);
    });

    test('只给文件名也命中', () {
      expect(matchDeliverableByRef(all, 'README.md')?.path, readme.path);
    });

    test('绝对路径后缀命中', () {
      expect(matchDeliverableByRef(all, r'dsh_mobile\out\报表.xlsx')?.path, report.path);
    });

    test('后缀必须落在目录分隔符上：myreport.md ≠ report.md', () {
      const md = DeliverableItem(path: r'E:\w\report.md', display: 'report.md', description: '');
      expect(matchDeliverableByRef(const [md], 'myreport.md'), isNull);
    });

    test('空字样返回 null（不能悄悄链到清单第一行）', () {
      expect(matchDeliverableByRef(all, '   '), isNull);
    });
  });
}
