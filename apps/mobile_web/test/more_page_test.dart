import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/gzus_design.dart';
import 'package:gzus_pro_mobile_web/models/custom_background.dart';
import 'package:gzus_pro_mobile_web/models/nav_config.dart';
import 'package:gzus_pro_mobile_web/pages/more/more_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('更多页在紧凑和宽屏布局中均可正常展示', (tester) async {
    await _setViewport(tester: tester, size: const Size(390, 844));
    await tester.pumpWidget(_morePage(
      onConfigChanged: () {},
      onNavigate: (_) {},
      onFontScaleChanged: (_) {},
    ));

    expect(find.byKey(const ValueKey('page-panel-banner')), findsOneWidget);
    expect(find.text('应用入口'), findsOneWidget);
    expect(find.text('快捷设置'), findsOneWidget);
    expect(find.text('账户'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _setViewport(tester: tester, size: const Size(1200, 844));
    await tester.pumpAndSettle();

    expect(find.text('应用入口'), findsOneWidget);
    expect(find.text('快捷设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑导航可添加应用并保存配置', (tester) async {
    var configChanged = 0;
    await tester.pumpWidget(_morePage(
      onConfigChanged: () => configChanged++,
      onNavigate: (_) {},
      onFontScaleChanged: (_) {},
    ));

    await tester.tap(find.byTooltip('编辑导航'));
    await tester.pumpAndSettle();

    expect(find.text('编辑导航'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    final savedTabs = preferences.getStringList('nav_bar_config');
    expect(configChanged, 1);
    expect(savedTabs, isNotNull);
    expect(savedTabs, contains('more'));
  });

  testWidgets('编辑导航可移除应用并恢复默认配置', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'nav_bar_config': <String>[
        'home',
        'info',
        'applications',
        'schedule',
        'more'
      ],
    });
    var configChanged = 0;
    await tester.pumpWidget(_morePage(
      onConfigChanged: () => configChanged++,
      onNavigate: (_) {},
      onFontScaleChanged: (_) {},
    ));

    await tester.tap(find.byTooltip('编辑导航'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(configChanged, 1);
    expect(preferences.getStringList('nav_bar_config'), isNull);
  });

  testWidgets('学年和学期变化后设置控件显示最新值', (tester) async {
    await tester.pumpWidget(_morePage(
      onConfigChanged: () {},
      onNavigate: (_) {},
      onFontScaleChanged: (_) {},
      year: 2026,
      term: 1,
    ));

    expect(
      tester
          .widget<EditableText>(find.descendant(
            of: find.byKey(const ValueKey('more-year-2026')),
            matching: find.byType(EditableText),
          ))
          .controller
          .text,
      '2026',
    );
    expect(
      tester
          .widget<EditableText>(find.descendant(
            of: find.byKey(const ValueKey('more-term-1')),
            matching: find.byType(EditableText),
          ))
          .controller
          .text,
      '第1学期',
    );

    await tester.pumpWidget(_morePage(
      onConfigChanged: () {},
      onNavigate: (_) {},
      onFontScaleChanged: (_) {},
      year: 2025,
      term: 2,
    ));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<EditableText>(find.descendant(
            of: find.byKey(const ValueKey('more-year-2025')),
            matching: find.byType(EditableText),
          ))
          .controller
          .text,
      '2025',
    );
    expect(find.byKey(const ValueKey('more-year-2026')), findsNothing);
    expect(
      tester
          .widget<EditableText>(find.descendant(
            of: find.byKey(const ValueKey('more-term-2')),
            matching: find.byType(EditableText),
          ))
          .controller
          .text,
      '第2学期',
    );
    expect(find.byKey(const ValueKey('more-term-1')), findsNothing);
  });

  testWidgets('字体大小选择会通知应用根部更新', (tester) async {
    double? selectedScale;
    await tester.pumpWidget(_morePage(
      onConfigChanged: () {},
      onNavigate: (_) {},
      onFontScaleChanged: (value) => selectedScale = value,
    ));

    expect(find.byKey(const ValueKey('font-scale-1.0')), findsOneWidget);
    await tester.tap(find.text('大'));
    await tester.pumpAndSettle();

    expect(selectedScale, 1.15);
  });

  testWidgets('未启用移动端背景能力时隐藏自定义背景设置', (tester) async {
    await tester.pumpWidget(_morePage(
      onConfigChanged: () {},
      onNavigate: (_) {},
      onFontScaleChanged: (_) {},
    ));

    expect(find.text('自定义背景'), findsNothing);
    expect(find.byKey(const ValueKey('custom-background-pick-button')),
        findsNothing);
  });

  testWidgets('自定义背景设置显示预览、滑块和移除入口', (tester) async {
    var pickCount = 0;
    var clearCount = 0;
    await tester.pumpWidget(_morePage(
      onConfigChanged: () {},
      onNavigate: (_) {},
      onFontScaleChanged: (_) {},
      customBackground: const CustomBackgroundSettings(
        imagePath: '/tmp/gzus-test-background.img',
        blurSigma: 12,
        darkness: 0.35,
      ),
      onPickCustomBackground: () async => pickCount++,
      onClearCustomBackground: () async => clearCount++,
      onCustomBackgroundBlurChanged: (_) async {},
      onCustomBackgroundDarknessChanged: (_) async {},
    ));
    await tester.pumpAndSettle();

    expect(find.text('自定义背景'), findsOneWidget);
    expect(find.byKey(const ValueKey('custom-background-blur-slider')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('custom-background-darkness-slider')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('custom-background-remove-button')),
        findsOneWidget);

    final pickButton =
        find.byKey(const ValueKey('custom-background-pick-button'));
    await tester.ensureVisible(pickButton);
    await tester.tap(pickButton);
    await tester.pumpAndSettle();
    final removeButton =
        find.byKey(const ValueKey('custom-background-remove-button'));
    await tester.ensureVisible(removeButton);
    await tester.tap(removeButton);
    await tester.pumpAndSettle();

    expect(pickCount, 1);
    expect(clearCount, 1);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _setViewport({
  required WidgetTester tester,
  required Size size,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

Widget _morePage({
  required VoidCallback onConfigChanged,
  required ValueChanged<String> onNavigate,
  required ValueChanged<double> onFontScaleChanged,
  int year = 2026,
  int term = 1,
  CustomBackgroundSettings? customBackground,
  Future<void> Function()? onPickCustomBackground,
  Future<void> Function()? onClearCustomBackground,
  Future<void> Function(double value)? onCustomBackgroundBlurChanged,
  Future<void> Function(double value)? onCustomBackgroundDarknessChanged,
}) {
  return MaterialApp(
    theme: gzusTheme(Brightness.light),
    home: Scaffold(
      body: MorePage(
        api: ApiClient(baseUrl: 'https://api.example.test'),
        navBarTabs: [
          NavTabConfig.all[0],
          NavTabConfig.all[1],
          NavTabConfig.all[4],
          NavTabConfig.all[5],
          NavTabConfig.moreTab,
        ],
        navBarLimit: 5,
        onNavigate: onNavigate,
        onConfigChanged: onConfigChanged,
        year: year,
        term: term,
        onLogout: () {},
        onYearChanged: (_) {},
        onTermChanged: (_) {},
        onThemeChanged: (_) {},
        onSeedColorChanged: (_) {},
        customBackground: customBackground,
        onPickCustomBackground: onPickCustomBackground,
        onClearCustomBackground: onClearCustomBackground,
        onCustomBackgroundBlurChanged: onCustomBackgroundBlurChanged,
        onCustomBackgroundDarknessChanged: onCustomBackgroundDarknessChanged,
        fontScale: 1,
        onFontScaleChanged: onFontScaleChanged,
        onAutoHideNavBarChanged: (_) {},
        onShowBackgroundGuide: () {},
      ),
    ),
  );
}
