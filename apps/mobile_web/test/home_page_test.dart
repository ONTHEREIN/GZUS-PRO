import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/main.dart';
import 'package:gzus_pro_mobile_web/pages/home/home_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('单个 dashboard 模块失败时保留其他首页模块', (tester) async {
    final api = _homeApi(
      transform: (body, requestIndex) {
        final modules = Map<String, Object?>.from(
          body['modules']! as Map<String, Object?>,
        );
        modules['exams'] = {
          'status': 'error',
          'data': <Object>[],
          'error': '考试服务暂时不可用',
        };
        return {...body, 'modules': modules};
      },
    );

    await _pumpHome(tester, api, const Size(800, 1400));

    final scheduleCard = find.byKey(const ValueKey('home-card-下一节课'));
    expect(scheduleCard, findsOneWidget);
    expect(find.descendant(of: scheduleCard, matching: find.text('焦点')),
        findsOneWidget);
    expect(find.textContaining('考试模块加载失败'), findsOneWidget);
    expect(find.textContaining('考试服务暂时不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('天气预报不足四天时首页正常展示', (tester) async {
    final api = _homeApi(
      transform: (body, requestIndex) {
        final modules = Map<String, Object?>.from(
          body['modules']! as Map<String, Object?>,
        );
        modules['weather'] = {
          'status': 'ok',
          'data': {
            'city': '广州',
            'weather': '晴',
            'temperature': 28,
            'humidity': 68,
            'wind_direction': '东北风',
            'wind_power': '≤3级',
            'forecast': [
              {'week': '今天', 'temp_max': 30, 'weather_day': '晴'},
              {'week': '明天', 'temp_max': 31, 'weather_day': '多云'},
              {'week': '后天', 'temp_max': 29, 'weather_day': '阵雨'},
            ],
          },
        };
        return {...body, 'modules': modules};
      },
    );

    await _pumpHome(tester, api, const Size(390, 844));

    final weatherCard = find.byKey(const ValueKey('home-card-天气'));
    await tester.scrollUntilVisible(
      weatherCard,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(weatherCard, findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dashboard 整体失败后重试会创建新的强制刷新请求', (tester) async {
    var requestCount = 0;
    final api = _homeApi(
      transform: (body, requestIndex) {
        requestCount++;
        if (requestIndex == 0) return {...body, 'status': 'error'};
        return body;
      },
    );

    await _pumpHome(tester, api, const Size(800, 1400));

    expect(find.textContaining('首页数据加载失败'), findsWidgets);
    await tester.tap(find.text('重试').first);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    expect(requestCount, greaterThanOrEqualTo(2));
    expect(find.byKey(const ValueKey('home-card-下一节课')), findsOneWidget);
    expect(find.text('焦点'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页标题横幅和首个模块共用移动端内容边线', (tester) async {
    await _pumpDashboardShell(
      tester,
      const Size(390, 844),
      false,
      TextScaler.noScaling,
    );

    final greeting = find.text('你好，测试学生');
    final banner = find.byKey(const ValueKey('page-panel-banner'));
    final firstCard = find.byKey(const ValueKey('home-card-下一节课'));

    expect(greeting, findsOneWidget);
    expect(banner, findsOneWidget);
    expect(firstCard, findsOneWidget);
    expect(tester.getTopLeft(greeting).dx, 12);
    expect(tester.getTopLeft(banner).dx, 12);
    expect(tester.getTopLeft(firstCard).dx, 12);
    expect(tester.takeException(), isNull);
  });

  testWidgets('移动端首页上滑收起问候区并悬浮玻璃标题栏', (tester) async {
    await _pumpDashboardShell(
      tester,
      const Size(390, 844),
      false,
      TextScaler.noScaling,
    );

    final greeting = find.byKey(const ValueKey('mobile-home-greeting'));
    final banner = find.byKey(const ValueKey('page-panel-banner'));
    final homeScrollView = find.byType(ListView).first;
    final initialGreetingHeight = tester.getSize(greeting).height;
    final initialBannerTop = tester.getTopLeft(banner).dy;
    final glass = find.byKey(const ValueKey('page-panel-glass-surface'));

    expect(_glassOpacity(tester, glass), 0);

    await tester.drag(homeScrollView, const Offset(0, -36));
    await tester.pumpAndSettle();

    expect(tester.getSize(greeting).height, greaterThan(0));
    expect(tester.getSize(greeting).height, lessThan(initialGreetingHeight));
    expect(_glassOpacity(tester, glass), closeTo(0.5, 0.08));

    await tester.drag(homeScrollView, const Offset(0, -96));
    await tester.pumpAndSettle();

    expect(tester.getSize(greeting).height, 0);
    expect(_glassOpacity(tester, glass), 1);
    expect(tester.getTopLeft(banner).dy, lessThan(initialBannerTop));
    expect(
      tester.widget<ListView>(homeScrollView).clipBehavior,
      Clip.none,
    );

    await tester.drag(homeScrollView, const Offset(0, 160));
    await tester.pumpAndSettle();

    expect(tester.getSize(greeting).height, initialGreetingHeight);
    expect(_glassOpacity(tester, glass), 0);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('离开首页后返回会重置问候区收起进度', (tester) async {
    await _pumpDashboardShell(
      tester,
      const Size(390, 844),
      false,
      TextScaler.noScaling,
    );

    final greeting = find.byKey(const ValueKey('mobile-home-greeting'));
    final homeScrollView = find.descendant(
      of: find.byKey(const ValueKey('mobile-dashboard-content')),
      matching: find.byType(ListView),
    );
    await tester.drag(homeScrollView, const Offset(0, -96));
    await tester.pumpAndSettle();
    expect(tester.getSize(greeting).height, 0);

    await tester.drag(homeScrollView, const Offset(0, 20));
    await tester.pumpAndSettle();
    await tester.tap(find.text('信息').last);
    await tester.pumpAndSettle();
    expect(greeting, findsNothing);

    await tester.tap(find.text('首页').last);
    await tester.pumpAndSettle();
    expect(tester.getSize(greeting).height, greaterThan(0));
    expect(
      _glassOpacity(
        tester,
        find.byKey(const ValueKey('page-panel-glass-surface')),
      ),
      lessThan(1),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页标题横幅和首个模块共用桌面端内容边线', (tester) async {
    await _pumpDashboardShell(
      tester,
      const Size(1280, 800),
      false,
      TextScaler.noScaling,
    );

    final banner = find.byKey(const ValueKey('page-panel-banner'));
    final firstCard = find.byKey(const ValueKey('home-card-下一节课'));

    expect(banner, findsOneWidget);
    expect(firstCard, findsOneWidget);
    expect(tester.getTopLeft(banner).dx, 280);
    expect(tester.getTopLeft(firstCard).dx, 280);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面端首页滚动启用悬浮标题栏', (tester) async {
    await _pumpDashboardShell(
      tester,
      const Size(1280, 800),
      false,
      TextScaler.noScaling,
    );

    final homeScrollView = find
        .ancestor(
          of: find.byKey(const ValueKey('home-card-下一节课')),
          matching: find.byType(Scrollable),
        )
        .first;
    final glass = find.byKey(const ValueKey('page-panel-glass-surface'));
    await tester.drag(homeScrollView, const Offset(0, -96));
    await tester.pumpAndSettle();

    expect(_glassOpacity(tester, glass), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字号管理员首页可收起且不溢出', (tester) async {
    await _pumpDashboardShell(
      tester,
      const Size(320, 568),
      true,
      const TextScaler.linear(1.5),
    );

    final homeScrollView = find.byType(ListView).first;
    await tester.drag(homeScrollView, const Offset(0, -96));
    await tester.pumpAndSettle();

    expect(
      _glassOpacity(
        tester,
        find.byKey(const ValueKey('page-panel-glass-surface')),
      ),
      1,
    );
    expect(tester.takeException(), isNull);
  });
}

double _glassOpacity(WidgetTester tester, Finder glass) {
  final opacity =
      find.ancestor(of: glass, matching: find.byType(Opacity)).first;
  return tester.widget<Opacity>(opacity).opacity;
}

void _stubHomeWidgetChannel() {
  const homeWidgetChannel = MethodChannel('cn.gzus.pro/home_widgets');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(homeWidgetChannel, (call) async => null);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(homeWidgetChannel, null);
  });
}

Future<void> _pumpDashboardShell(
  WidgetTester tester,
  Size size,
  bool isAdmin,
  TextScaler textScaler,
) async {
  _stubHomeWidgetChannel();
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final api = ApiClient(
    baseUrl: 'https://api.example.test',
    httpClient: MockClient((_) async => http.Response('服务器错误', 500)),
  );
  api.useSession('layout-test-session');
  api.setStudentId('2024000000');
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: DashboardShell(
          api: api,
          studentName: '测试学生',
          themeMode: ThemeMode.light,
          onThemeChanged: (_) {},
          onLogout: () {},
          isAdmin: isAdmin,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpHome(WidgetTester tester, ApiClient api, Size size) async {
  _stubHomeWidgetChannel();
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final now = DateTime.now();
  final firstWeekStart = DateTime(now.year, now.month, now.day)
      .subtract(Duration(days: now.weekday - DateTime.monday));
  await tester.pumpWidget(
    MaterialApp(
      home: HomePage(
        api: api,
        year: now.year,
        term: 1,
        currentWeek: 1,
        firstWeekStart: firstWeekStart,
        onNavigate: (_) {},
        studentName: '测试学生',
        studentId: '2024000000',
      ),
    ),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pumpAndSettle();
}

ApiClient _homeApi({
  required Map<String, Object?> Function(
    Map<String, Object?> body,
    int requestIndex,
  ) transform,
}) {
  var requestIndex = 0;
  final api = ApiClient(
    baseUrl: 'https://api.example.test',
    httpClient: MockClient((request) async {
      final body = transform(_dashboardBody(), requestIndex);
      requestIndex++;
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  api.useSession('home-test-session');
  api.setStudentId('2024000000');
  return api;
}

Map<String, Object?> _dashboardBody() {
  final now = DateTime.now();
  return {
    'status': 'ok',
    'generatedAt': now.toIso8601String(),
    'modules': <String, Object?>{
      'me': {
        'status': 'ok',
        'data': {
          'studentId': '2024000000',
          'name': '测试学生',
        },
      },
      'schedule': {
        'status': 'ok',
        'data': [
          {
            'name': '移动应用开发',
            'teacher': '张老师',
            'classroom': 'A101',
            'weekday': now.weekday,
            'startSection': 1,
            'endSection': 2,
            'weeks': '1',
          },
        ],
      },
      'notices': {'status': 'empty', 'data': <Object>[]},
      'attendance': {
        'status': 'empty',
        'data': {'status': 'empty', 'items': <Object>[]},
      },
      'credits': {'status': 'empty', 'data': <Object>[]},
      'ecard': {
        'status': 'empty',
        'data': {'status': 'not_bound'},
      },
      'apps': {'status': 'empty', 'data': <Object>[]},
      'progress': {
        'status': 'empty',
        'data': {'items': <Object>[]},
      },
      'weather': {'status': 'empty', 'data': null},
      'grades': {'status': 'empty', 'data': <Object>[]},
      'exams': {'status': 'empty', 'data': <Object>[]},
    },
  };
}
