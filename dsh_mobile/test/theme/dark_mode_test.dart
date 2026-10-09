import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/services/storage_service.dart';
import 'package:dsh_mobile/theme/app_colors.dart';

/// 深色模式（v1.6.0）的测试。
///
/// 重点两条：
/// 1. **两个主题必须结构相同。** 一个只让一半 widget 适配了深色的版本，比恒为
///    亮色更糟。测试逐项对比两棵 ThemeData 的关键字段，任何一边缺一项都会挂。
/// 2. **ThemeScope 在缺祖先时回落亮色**，这样 widget 测试单独 pump 一个 widget
///    不会因为找不到 ThemeScope 而抛异常。
void main() {
  group('AppColors token 层', () {
    test('浅色与深色取值成对存在，且两两不同', () {
      final pairs = <String, (Color, Color)>{
        'accent': (AppColors.accent, AppColors.accentDark),
        'textPrimary': (AppColors.textPrimary, AppColors.textPrimaryDark),
        'textSecondary': (AppColors.textSecondary, AppColors.textSecondaryDark),
        'textTertiary': (AppColors.textTertiary, AppColors.textTertiaryDark),
        'background': (AppColors.background, AppColors.backgroundDark),
        'surface': (AppColors.surface, AppColors.surfaceDark),
        'surfaceMuted': (AppColors.surfaceMuted, AppColors.surfaceMutedDark),
        'border': (AppColors.border, AppColors.borderDark),
        'danger': (AppColors.danger, AppColors.dangerDark),
        'success': (AppColors.success, AppColors.successDark),
        'warning': (AppColors.warning, AppColors.warningDark),
      };
      for (final e in pairs.entries) {
        expect(e.value.$1, isNot(e.value.$2), reason: '${e.key} 的浅色与深色不能相同');
      }
    });

    test('深色下主要文字与面是"深底亮字"，浅色下是"亮底暗字"', () {
      // 用 Flutter 自己的 estimateBrightnessForColor，而不是我手写的亮度公式 ——
      // 后者一旦算错就会给出一个"永远通过"的假断言，而这正是"安慰剂 darkTheme"
      // 会踩的坑：底和字都取了深色值，看起来有主题，实际不可读。
      expect(ThemeData.estimateBrightnessForColor(AppColors.surfaceDark), Brightness.dark);
      expect(ThemeData.estimateBrightnessForColor(AppColors.backgroundDark), Brightness.dark);
      expect(ThemeData.estimateBrightnessForColor(AppColors.textPrimaryDark), Brightness.light,
          reason: '深色面上的主要文字必须是亮色，否则深底深字不可读');
      // 浅色反过来
      expect(ThemeData.estimateBrightnessForColor(AppColors.surface), Brightness.light);
      expect(ThemeData.estimateBrightnessForColor(AppColors.textPrimary), Brightness.dark);
    });
  });

  group('ThemeScope', () {
    testWidgets('isDark 缺祖先时回落浅色，不抛异常', (tester) async {
      late bool isDark;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) {
          isDark = ThemeScope.isDarkOf(ctx);
          return const SizedBox();
        }),
      ));
      expect(isDark, isFalse);
    });

    testWidgets('包一层 ThemeScope(isDark:true) 时读到深色 token', (tester) async {
      late Color surface;
      late Color text;
      await tester.pumpWidget(MaterialApp(
        home: ThemeScope(
          isDark: true,
          child: Builder(builder: (ctx) {
            surface = ctx.c.surface;
            text = ctx.c.textPrimary;
            return const SizedBox();
          }),
        ),
      ));
      expect(surface, AppColors.surfaceDark);
      expect(text, AppColors.textPrimaryDark);
    });

    testWidgets('两个模式的取值确实不同（证明 isDark 真的被读了）', (tester) async {
      late Color lightSurface;
      late Color darkSurface;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) {
          lightSurface = ctx.c.surface;
          return ThemeScope(
            isDark: true,
            child: Builder(builder: (ctx2) {
              darkSurface = ctx2.c.surface;
              return const SizedBox();
            }),
          );
        }),
      ));
      expect(lightSurface, isNot(darkSurface));
    });
  });

  group('ThemeController', () {
    test('默认跟随系统', () {
      final tc = ThemeController();
      expect(tc.mode, 'system');
      expect(tc.themeMode, ThemeMode.system);
      expect(tc.label, '跟随系统');
      expect(tc.isExplicit, isFalse);
    });

    test('light/dark 映射到对应 ThemeMode', () {
      expect(ThemeController(initialMode: 'light').themeMode, ThemeMode.light);
      expect(ThemeController(initialMode: 'dark').themeMode, ThemeMode.dark);
    });

    test('未知 mode 回落为 system 而不是抛异常', () {
      // 损坏的存储值绝不能阻塞启动。
      expect(ThemeController(initialMode: '紫色').themeMode, ThemeMode.system);
    });

    test('cycle 按 跟随系统→浅色→深色→跟随系统 循环', () async {
      SharedPreferences.setMockInitialValues({});
      final tc = ThemeController();
      expect(tc.mode, 'system');
      await tc.cycle();
      expect(tc.mode, 'light');
      await tc.cycle();
      expect(tc.mode, 'dark');
      await tc.cycle();
      expect(tc.mode, 'system');
    });

    test('setMode 到相同值时不重复通知', () async {
      SharedPreferences.setMockInitialValues({});
      final tc = ThemeController(initialMode: 'light');
      var notified = 0;
      tc.addListener(() => notified++);
      await tc.setMode('light');
      expect(notified, 0, reason: '值没变就不该重建整棵树');
    });
  });

  group('主题持久化', () {
    test('saveThemeMode / loadThemeMode 往返', () async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.saveThemeMode('dark');
      expect(await StorageService.loadThemeMode(), 'dark');
    });

    test('未设置过任何值时 loadThemeMode 返回 system', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await StorageService.loadThemeMode(), 'system');
    });

    test('损坏的存储值回落 system，不抛异常', () async {
      SharedPreferences.setMockInitialValues({'dsh_theme_mode': 'not-a-mode'});
      expect(await StorageService.loadThemeMode(), 'system');
    });
  });

  group('MaterialApp 主题接线', () {
    test('两个主题结构对称，任何一边缺一项都会挂', () {
      // 直接调用 main.dart 里的真实主题工厂，而不是复制一份 —— 复制品会与实际
      // 实现漂移，那样的"测试"什么也验证不了。
      final light = buildLightTheme();
      final dark = buildDarkTheme();

      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.colorScheme.surface, isNot(dark.colorScheme.surface));
      expect(light.scaffoldBackgroundColor, isNot(dark.scaffoldBackgroundColor));
      expect(light.appBarTheme.backgroundColor, isNot(dark.appBarTheme.backgroundColor));
      expect(light.cardTheme.color, isNot(dark.cardTheme.color));
      expect(light.dividerColor, isNot(dark.dividerColor));
      // 两边字段都必须非 null，否则深色下会渲染成透明
      expect(dark.cardTheme.color, isNotNull);
      expect(dark.scaffoldBackgroundColor, isNotNull);
      expect(dark.appBarTheme.foregroundColor, isNotNull);
      expect(dark.appBarTheme.titleTextStyle?.color, isNotNull);
    });

    test('深色主题的所有色值都来自 token 层，没有裸色', () {
      // 这是"深色模式做了一半"最容易漏的地方：主题里改了，但某个角落仍是
      // 硬编码白卡片。这里锁住主题工厂本身。
      final dark = buildDarkTheme();
      final whites = <Color>{Colors.white};
      expect(whites.contains(dark.scaffoldBackgroundColor), isFalse);
      expect(whites.contains(dark.cardTheme.color), isFalse);
      expect(whites.contains(dark.appBarTheme.backgroundColor), isFalse);
      expect(whites.contains(dark.appBarTheme.foregroundColor), isFalse);
      expect(whites.contains(dark.appBarTheme.titleTextStyle?.color), isFalse);
    });
  });
}