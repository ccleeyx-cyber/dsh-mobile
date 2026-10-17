import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/models/gateway_features.dart';
import 'package:dsh_mobile/services/dsh_service.dart';
import 'package:dsh_mobile/services/storage_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/custom_settings_view.dart';

/// 设置页「快捷指令」分区的界面测试（Phase 5.4）。
///
/// 钉住的是**合并展示**这条规则：本地条目排前面、带「本地」徽标、可改可删可排序；
/// 网关下发的条目只读（没有编辑/删除按钮，而不是给一个点了没反应的图标）。
///
/// 全部走内存：网关条目从 `debugRemoteSnippets` 注入、本地条目摆进
/// `SharedPreferences` 的内存 mock —— 不打真实网关、不写真实存储。
void main() {
  const kKey = 'dsh_local_snippets';

  setUp(() {
    SharedPreferences.setMockInitialValues({
      kKey: jsonEncode([
        {'id': 'local_1', 'label': '本地A', 'text': '把{a}翻成{b}', 'tag': '翻译'},
        {'id': 'local_2', 'label': '本地B', 'text': '继续'},
      ]),
    });
  });

  Future<DshService> pumpSettings(
    WidgetTester tester, {
    List<Snippet> remote = const [],
    Size size = const Size(420, 2200),
    double? textScale,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dsh = DshService();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DshService>.value(value: dsh),
          ChangeNotifierProvider<ThemeController>.value(
              value: ThemeController()),
        ],
        child: MaterialApp(
          builder: (ctx, c) {
            final content =
                ThemeScope(isDark: false, child: c ?? const SizedBox());
            if (textScale == null) return content;
            return MediaQuery(
              data: MediaQuery.of(ctx)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: content,
            );
          },
          home: CustomSettingsView(debugRemoteSnippets: remote),
        ),
      ),
    );
    // 一次 pump 让 initState 里的 load 落地，再一次让 setState 生效。
    await tester.pump();
    await tester.pump();
    return dsh;
  }

  /// 把目标滚进视野。设置页很长，且 ListView 是懒构建的 —— 先滚再点。
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 320,
        scrollable: find.byType(Scrollable).first);
    await tester.pump();
  }

  Finder inDialog(String text) =>
      find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

  testWidgets('本地条目排前面带「本地」徽标，网关条目只读带「网关」徽标', (tester) async {
    await pumpSettings(tester, remote: const [
      Snippet(id: 'gw1', label: '网关R', text: '来自网关的模板'),
    ]);

    final section = find.byKey(const ValueKey('settings-snippets-section'));
    await reveal(tester, section);
    expect(section, findsOneWidget);

    // 本地两条 + 网关一条都在
    expect(find.text('本地A'), findsOneWidget);
    expect(find.text('本地B'), findsOneWidget);
    expect(find.text('网关R'), findsOneWidget);

    expect(find.byKey(const ValueKey('snippet-local-badge-local_1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('snippet-local-badge-local_2')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('snippet-gateway-badge-gw1')),
        findsOneWidget);
    // 分类标签只挂在本地条目上
    expect(find.byKey(const ValueKey('snippet-tag-local_1')), findsOneWidget);

    // 顺序：本地在前
    final localY = tester.getTopLeft(find.text('本地B')).dy;
    final remoteY = tester.getTopLeft(find.text('网关R')).dy;
    expect(localY, lessThan(remoteY));

    // 网关条目只读：没有编辑/删除/排序按钮
    expect(find.byKey(const ValueKey('snippet-delete-gw1')), findsNothing);
    expect(find.byKey(const ValueKey('snippet-edit-gw1')), findsNothing);
    expect(find.byKey(const ValueKey('snippet-up-gw1')), findsNothing);
    // 本地条目有
    expect(
        find.byKey(const ValueKey('snippet-delete-local_1')), findsOneWidget);
  });

  testWidgets('读不到本地存储时明说"已存的内容没有被删除"，不假装没有指令', (tester) async {
    // 让 load 抛：给一个坏类型（getString 会抛 TypeError）。
    SharedPreferences.setMockInitialValues({kKey: 42});
    await pumpSettings(tester);

    await reveal(tester,
        find.byKey(const ValueKey('settings-snippets-storage-warning')));
    expect(find.byKey(const ValueKey('settings-snippets-storage-warning')),
        findsOneWidget);
    expect(find.textContaining('已经存下的内容没有被删除'), findsOneWidget);
  });

  testWidgets('下移一条后顺序写进存储（排序不是只改内存）', (tester) async {
    await pumpSettings(tester);
    await reveal(tester, find.byKey(const ValueKey('snippet-down-local_1')));

    await tester.tap(find.byKey(const ValueKey('snippet-down-local_1')));
    await tester.pump();
    await tester.pump();

    final saved = await StorageService.loadLocalSnippets();
    expect(saved.map((e) => e.id).toList(), ['local_2', 'local_1']);

    // 界面上也跟着换了：本地B 现在在本地A 上面。
    await reveal(tester, find.text('本地A'));
    expect(
      tester.getTopLeft(find.text('本地B')).dy,
      lessThan(tester.getTopLeft(find.text('本地A')).dy),
    );
  });

  testWidgets('第一条的上移与最后一条的下移不可用（不给无效动作）', (tester) async {
    await pumpSettings(tester);
    await reveal(tester, find.byKey(const ValueKey('snippet-up-local_1')));

    final up = tester
        .widget<IconButton>(find.byKey(const ValueKey('snippet-up-local_1')));
    final down = tester
        .widget<IconButton>(find.byKey(const ValueKey('snippet-down-local_2')));
    expect(up.onPressed, isNull);
    expect(down.onPressed, isNull);
  });

  testWidgets('新增一条本地指令：落进存储并出现在列表里', (tester) async {
    await pumpSettings(tester);
    await reveal(tester, find.byKey(const ValueKey('snippet-add-local')));

    await tester.tap(find.byKey(const ValueKey('snippet-add-local')));
    await tester.pump();

    await tester.enterText(
        find.byKey(const ValueKey('snippet-editor-label')), '总结');
    await tester.enterText(
        find.byKey(const ValueKey('snippet-editor-text')), '总结这段{内容}');
    await tester.enterText(
        find.byKey(const ValueKey('snippet-editor-tag')), '写作');
    await tester.pump();

    await tester.tap(find.widgetWithText(ElevatedButton, '保存'));
    await tester.pump();
    await tester.pump();

    final saved = await StorageService.loadLocalSnippets();
    expect(saved.length, 3);
    expect(saved.last.label, '总结');
    expect(saved.last.text, '总结这段{内容}');
    expect(saved.last.tag, '写作');
    expect(saved.last.id, isNotEmpty);
    // 新条目本身就在末尾（列表顺序 = 数组顺序）
    expect(saved.map((e) => e.label).toList(), ['本地A', '本地B', '总结']);
  });

  testWidgets('名称留空时回落到正文首行，空正文不保存', (tester) async {
    await pumpSettings(tester);
    await reveal(tester, find.byKey(const ValueKey('snippet-add-local')));

    // 先试空正文：对话框关掉、什么也不写。
    await tester.tap(find.byKey(const ValueKey('snippet-add-local')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('snippet-editor-label')), '只有名字');
    await tester.tap(find.widgetWithText(ElevatedButton, '保存'));
    await tester.pump();
    expect((await StorageService.loadLocalSnippets()).length, 2);

    // 再试只有正文：名字回落为正文首行。
    await reveal(tester, find.byKey(const ValueKey('snippet-add-local')));
    await tester.tap(find.byKey(const ValueKey('snippet-add-local')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('snippet-editor-text')), '解释这段代码');
    await tester.tap(find.widgetWithText(ElevatedButton, '保存'));
    await tester.pump();
    await tester.pump();

    final saved = await StorageService.loadLocalSnippets();
    expect(saved.length, 3);
    expect(saved.last.label, '解释这段代码');
  });

  testWidgets('删除要确认，确认后才从存储里删掉', (tester) async {
    await pumpSettings(tester);
    await reveal(tester, find.byKey(const ValueKey('snippet-delete-local_2')));

    await tester.tap(find.byKey(const ValueKey('snippet-delete-local_2')));
    await tester.pump();
    expect(inDialog('删除本地指令'), findsOneWidget);
    expect(find.textContaining('网关下发的同名条目'), findsOneWidget);

    // 先取消：什么都不该变
    await tester.tap(inDialog('取消'));
    await tester.pump();
    expect((await StorageService.loadLocalSnippets()).length, 2);

    await tester.tap(find.byKey(const ValueKey('snippet-delete-local_2')));
    await tester.pump();
    await tester.tap(inDialog('删除'));
    await tester.pump();
    await tester.pump();

    final saved = await StorageService.loadLocalSnippets();
    expect(saved.map((e) => e.id).toList(), ['local_1']);
  });

  testWidgets('试填：多个占位符一屏填完，预览就是最终文本，确认后复制走', (tester) async {
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpSettings(tester);
    await reveal(tester, find.byKey(const ValueKey('snippet-fill-local_1')));

    await tester.tap(find.byKey(const ValueKey('snippet-fill-local_1')));
    await tester.pump();

    // 两个占位符 → 两个字段一次出现，不是弹两次。
    expect(find.byKey(const ValueKey('snippet-param-field-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('snippet-param-field-b')), findsOneWidget);
    // 未填时预览保留占位符（不静默删）。断言限定在预览块里：列表那一行本身也
    // 显示同一段模板文字，全局 find 会命中两个。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('snippet-param-preview')),
        matching: find.text('把{a}翻成{b}'),
      ),
      findsOneWidget,
    );

    await tester.enterText(
        find.byKey(const ValueKey('snippet-param-field-a')), '中文');
    await tester.enterText(
        find.byKey(const ValueKey('snippet-param-field-b')), '英文');
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('snippet-param-preview')),
        matching: find.text('把中文翻成英文'),
      ),
      findsOneWidget,
    );

    await tester.tap(inDialog('使用'));
    await tester.pump();
    await tester.pump();

    expect(copied, '把中文翻成英文');
  });

  testWidgets('参数留空时原样保留 {名字}，预览也照实显示', (tester) async {
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpSettings(tester);
    await reveal(tester, find.byKey(const ValueKey('snippet-fill-local_1')));

    await tester.tap(find.byKey(const ValueKey('snippet-fill-local_1')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('snippet-param-field-a')), '中文');
    await tester.pump();
    expect(find.text('把中文翻成{b}'), findsOneWidget);

    await tester.tap(inDialog('使用'));
    await tester.pump();
    await tester.pump();
    expect(copied, '把中文翻成{b}');
  });

  testWidgets('没有占位符的条目「试填」不弹参数框，直接复制正文', (tester) async {
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpSettings(tester);
    await reveal(tester, find.byKey(const ValueKey('snippet-fill-local_2')));

    await tester.tap(find.byKey(const ValueKey('snippet-fill-local_2')));
    await tester.pump();
    await tester.pump();

    expect(find.byType(AlertDialog), findsNothing);
    expect(copied, '继续');
  });

  testWidgets('本地条目显示识别出来的参数名（用户能看出模板带几个参数）', (tester) async {
    await pumpSettings(tester);
    await reveal(tester, find.byKey(const ValueKey('snippet-params-local_1')));

    final params = tester
        .widget<Text>(find.byKey(const ValueKey('snippet-params-local_1')));
    expect(params.data, '参数：{a} {b}');
  });

  testWidgets('360dp 宽 + 系统字号 1.3x：分区不溢出（一行五个图标的行最容易炸）', (tester) async {
    await pumpSettings(
      tester,
      size: const Size(360, 720),
      textScale: 1.3,
      remote: const [
        Snippet(id: 'gw1', label: '网关R', text: '来自网关的模板，标题会比较长一些')
      ],
    );

    await reveal(
        tester, find.byKey(const ValueKey('settings-snippets-section')));
    // 懒构建：把每条都滚进来，确保它们的布局真的跑过一遍。
    await reveal(tester, find.byKey(const ValueKey('snippet-delete-local_2')));
    await reveal(
        tester, find.byKey(const ValueKey('snippet-gateway-badge-gw1')));

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('settings-snippets-section')),
        findsOneWidget);
  });
}
