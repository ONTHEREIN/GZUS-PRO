import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/pages/schedule/schedule_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const cases = [
    (label: '320x568', size: Size(320, 568)),
    (label: '844x390', size: Size(844, 390)),
  ];

  for (final testCase in cases) {
    testWidgets('日历视图在 ${testCase.label}@1.5 无布局溢出且字号正常', (tester) async {
      tester.view.physicalSize = testCase.size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      SharedPreferences.setMockInitialValues({});

      const courseName = '面向超长名称与跨平台辅助功能约束的移动应用系统设计与工程实践课程';
      const classroom = '广州软件学院教学楼 A 区实验实训中心第十二层多媒体综合实验室 A-1208';
      final api = ApiClient(
        baseUrl: 'https://api.example.test',
        httpClient: MockClient((request) async {
          if (request.url.path == '/schedule') {
            return http.Response(
              jsonEncode([
                {
                  'name': courseName,
                  'teacher': '张老师',
                  'classroom': classroom,
                  'weekday': 1,
                  'startSection': 1,
                  'endSection': 2,
                  'weeks': '1-30',
                }
              ]),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 200,
              headers: const {'content-type': 'application/json'});
        }),
      );
      api.useSession('calendar-layout-test');
      api.setStudentId('2024000000');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SchedulePage(
              api: api,
              year: 2026,
              term: 2,
              currentWeek: 1,
              firstWeekStart: DateTime(2026, 2, 16),
              autoWeek: true,
              onFirstWeekChanged: (_) {},
              onCurrentWeekChanged: (_) {},
              onAutoWeekChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final nameText = tester.widget<Text>(find.text(courseName));
      expect(nameText.style?.fontSize, greaterThanOrEqualTo(14));
      final roomText = tester.widget<Text>(find.text(classroom));
      expect(roomText.style?.fontSize, greaterThanOrEqualTo(11));
    });
  }
}
