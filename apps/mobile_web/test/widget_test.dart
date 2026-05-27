import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/main.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('renders login page', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const GzusProApp());
    await tester.pumpAndSettle();

    expect(find.text('GZUS-PRO'), findsOneWidget);
    expect(find.text('推荐使用办事大厅统一登录'), findsOneWidget);
    expect(find.text('办事大厅统一登录'), findsOneWidget);
    expect(find.text('教务系统登录'), findsWidgets);
  });

  testWidgets('mobile sso is enabled without account', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const GzusProApp());
    await tester.pumpAndSettle();

    final ssoButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '办事大厅统一登录'),
    );
    expect(ssoButton.onPressed, isNotNull);
    expect(find.text('请先输入学号'), findsNothing);
  });

  testWidgets('login page fits mobile viewport', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const GzusProApp());
    await tester.pumpAndSettle();

    expect(find.text('GZUS-PRO'), findsOneWidget);
    expect(find.text('办事大厅统一登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dashboard uses bottom tabs on mobile', (tester) async {
    await _pumpDashboard(tester, const Size(390, 844));

    expect(find.byKey(const ValueKey('mobile-bottom-nav')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-sidebar')), findsNothing);
    expect(find.byKey(const ValueKey('dashboard-header-tools')), findsNothing);
    expect(find.byKey(const ValueKey('mobile-header-toggle')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mobile-header-toggle')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('dashboard-header-tools')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mobile-header-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dashboard-header-tools')), findsNothing);

    await tester.tap(find.text('课表').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('移动应用开发'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dashboard uses sidebar on desktop', (tester) async {
    await _pumpDashboard(tester, const Size(1180, 820));

    expect(find.byKey(const ValueKey('app-sidebar')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-bottom-nav')), findsNothing);
  });

  testWidgets('mobile dashboard tabs fit every page', (tester) async {
    await _pumpDashboard(tester, const Size(390, 844));

    for (final label in ['信息', '课表', '考勤', '考试', '成绩', '学分']) {
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$label should fit');
    }
  });

  testWidgets('schedule remembers first week and opens compact tools',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'schedule.2025.2.firstWeekStart': '2026-02-16',
      'schedule.autoWeek': true,
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      FluentApp(
        home: DashboardShell(
          api: _mockApi(),
          studentName: '测试学生',
          darkMode: false,
          onThemeChanged: (_) {},
          onLogout: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('课表').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('首周2026-02-16'), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-tools-button')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('schedule-tools-button')));
    await tester.pumpAndSettle();

    expect(find.text('课表工具'), findsWidgets);
    expect(find.text('2026-02-16'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpDashboard(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    FluentApp(
      home: DashboardShell(
        api: _mockApi(),
        studentName: '测试学生',
        darkMode: false,
        onThemeChanged: (_) {},
        onLogout: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ApiClient _mockApi() {
  return ApiClient(
    httpClient: MockClient((request) async {
      final path = request.url.path;
      Object body;
      switch (path) {
        case '/me':
          body = {
            'studentId': '2540232101',
            'name': '测试学生',
            'college': '软件学院',
            'major': '软件工程',
            'className': '软件2401',
            'grade': '2024',
          };
          break;
        case '/schedule':
          body = [
            {
              'name': '移动应用开发',
              'teacher': '张老师',
              'classroom': 'A101',
              'weekday': 1,
              'startSection': 1,
              'endSection': 2,
              'weeks': '1-16',
            }
          ];
          break;
        case '/attendance':
          body = {
            'status': 'ok',
            'items': [
              {
                'courseName': '移动应用开发',
                'normal': 12,
                'late': 0,
                'leaveEarly': 0,
                'absent': 0,
                'leave': 1,
                'total': 13,
              }
            ],
          };
          break;
        case '/exams':
          body = [
            {
              'courseName': '移动应用开发',
              'time': '2026-06-20 09:00',
              'location': 'A101',
              'seat': '12',
              'type': '期末',
            }
          ];
          break;
        case '/grades':
          body = [
            {
              'courseName': '移动应用开发',
              'score': '92',
              'credit': '3',
              'gradePoint': '4.0',
            }
          ];
          break;
        case '/credits':
          body = [
            {
              'studentId': '2540232101',
              'name': '测试学生',
              'major': '软件工程',
              'totalCredit': '160',
              'selectedCredit': '24',
              'requiredExpected': 100,
              'electiveExpected': 40,
              'otherExpected': 20,
              'requiredEarned': 50,
              'electiveEarned': 15,
              'otherEarned': 5,
            }
          ];
          break;
        default:
          body = {};
      }
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
}
