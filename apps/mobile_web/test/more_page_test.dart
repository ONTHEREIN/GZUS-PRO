import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/gzus_design.dart';
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
  int year = 2026,
  int term = 1,
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
        onAutoHideNavBarChanged: (_) {},
        onShowBackgroundGuide: () {},
      ),
    ),
  );
}
