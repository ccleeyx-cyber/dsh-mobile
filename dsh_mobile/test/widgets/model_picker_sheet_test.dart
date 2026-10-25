import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/models/dsh_settings.dart';
import 'package:dsh_mobile/theme/app_colors.dart';
import 'package:dsh_mobile/views/widgets/model_picker_sheet.dart';

/// [feat 2026-10-22] 模型选择弹层：**按供应商分组显示**。
///
/// 用户原话：「模型设置没有分组，需要按不同的供应商分组显示」。这里钉住用户能
/// 看到的东西：分组标题、带条数的供应商胶囊、筛完之后只剩那一组、点一条就回调。
void main() {
  ModelItem item(String id, String name, String provider, {String? label}) => ModelItem(
        id: id,
        name: name,
        provider: provider,
        providerLabel: label ?? provider,
        contextWindow: 1000000,
        maxTokens: 32000,
      );

  final models = [
    item('cn:auto', 'cn:auto', 'wb'),
    item('cn:deepseek-v4-pro', 'DeepSeek V4 Pro', 'wb'),
    item('gpt-5.2', 'GPT-5.2', 'qwen'),
  ];

  Future<void> pumpHost(
    WidgetTester tester, {
    required List<String> picked,
    String selected = 'cn:auto',
  }) async {
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        builder: (ctx, child) => ThemeScope(isDark: false, child: child ?? const SizedBox()),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showModelPickerSheet(
                  context: context,
                  models: models,
                  selectedModelId: selected,
                  title: '切换大语言模型',
                  onPick: (m) async => picked.add(m.id),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('两个供应商各有一个分组标题，标题带条数', (tester) async {
    await pumpHost(tester, picked: []);

    expect(find.byKey(const ValueKey('model-picker-group-wb')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-picker-group-qwen')), findsOneWidget);
    // 三家信息在标题栏：3 个模型 / 2 家
    expect(find.text('3 个 · 2 家'), findsOneWidget);
    // 胶囊：全部 / wb 2 / qwen 1
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('wb 2'), findsOneWidget);
    expect(find.text('qwen 1'), findsOneWidget);
  });

  testWidgets('点供应商胶囊只留那一组的模型', (tester) async {
    await pumpHost(tester, picked: []);

    expect(find.byKey(const ValueKey('model-picker-item-cn:auto')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-picker-item-gpt-5.2')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('model-picker-chip-qwen')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('model-picker-item-gpt-5.2')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-picker-item-cn:auto')), findsNothing);
  });

  testWidgets('搜索会同时过滤供应商与模型', (tester) async {
    await pumpHost(tester, picked: []);

    await tester.enterText(find.byKey(const ValueKey('model-picker-search')), 'gpt');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('model-picker-item-gpt-5.2')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-picker-group-wb')), findsNothing);
    expect(find.text('wb 2'), findsNothing);
  });

  testWidgets('点一条模型：弹层关闭并回调选中项', (tester) async {
    final picked = <String>[];
    await pumpHost(tester, picked: picked);

    await tester.tap(find.byKey(const ValueKey('model-picker-item-cn:deepseek-v4-pro')));
    await tester.pumpAndSettle();

    expect(picked, ['cn:deepseek-v4-pro']);
    // 弹层已经关掉：列表回到了宿主页
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('当前模型标成「使用中」', (tester) async {
    await pumpHost(tester, picked: [], selected: 'gpt-5.2');
    expect(find.text('使用中'), findsOneWidget);
  });

  // [fix 2026-10-26] 用户实测反馈：「不同的供应商有相同的模型，在手机端选择的时候，
  // 两个都会选中」。本机模型目录里就有一对：wb 的 `cn:glm-5.3` 与 qwen 的 `glm-5.3`
  // （还有 `cn:deepseek-v4-pro` / `deepseek-v4-pro`）—— 去掉 `cn:` 前缀后两者同串，
  // 旧的宽松比较于是把两条都判成"使用中"。
  group('不同供应商的同名模型（去前缀同串）只能有一条选中', () {
    final collide = [
      item('cn:glm-5.3', 'GLM-5.3 (wb)', 'wb'),
      item('glm-5.3', 'GLM-5.3 (qwen)', 'qwen'),
    ];

    Future<void> pumpCollide(
      WidgetTester tester, {
      required String selected,
      String? provider,
    }) async {
      tester.view.physicalSize = const Size(420, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          builder: (ctx, child) => ThemeScope(isDark: false, child: child ?? const SizedBox()),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showModelPickerSheet(
                    context: context,
                    models: collide,
                    selectedModelId: selected,
                    selectedProviderKey: provider,
                    title: '切换大语言模型',
                    onPick: (_) async {},
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Finder inRow(String id) => find.descendant(
          of: find.byKey(ValueKey('model-picker-item-$id')),
          matching: find.text('使用中'),
        );

    testWidgets('选中 wb 的 cn:glm-5.3 时 qwen 的 glm-5.3 不得同时亮', (tester) async {
      await pumpCollide(tester, selected: 'cn:glm-5.3', provider: 'wb');

      expect(find.text('使用中'), findsOneWidget);
      expect(inRow('cn:glm-5.3'), findsOneWidget);
      expect(inRow('glm-5.3'), findsNothing);
    });

    testWidgets('选中 qwen 的 glm-5.3 时 wb 的 cn:glm-5.3 不得同时亮', (tester) async {
      await pumpCollide(tester, selected: 'glm-5.3', provider: 'qwen');

      expect(find.text('使用中'), findsOneWidget);
      expect(inRow('glm-5.3'), findsOneWidget);
      expect(inRow('cn:glm-5.3'), findsNothing);
    });

    testWidgets('老写法（名单里没有完整 id）靠供应商收敛到唯一一条', (tester) async {
      // 只有 qwen 有这条时，前缀不同的旧值也应且只应点亮它。
      await pumpCollide(tester, selected: 'qwen:glm-5.3', provider: 'qwen');

      expect(find.text('使用中'), findsOneWidget);
      expect(inRow('glm-5.3'), findsOneWidget);
      expect(inRow('cn:glm-5.3'), findsNothing);
    });
  });

  testWidgets('360dp 下不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        builder: (ctx, child) => ThemeScope(isDark: false, child: child ?? const SizedBox()),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showModelPickerSheet(
                  context: context,
                  models: models,
                  selectedModelId: 'cn:auto',
                  title: '切换大语言模型',
                  onPick: (_) async {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
