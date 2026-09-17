import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/gzus_design.dart';
import 'package:gzus_pro_mobile_web/pages/schedule/schedule_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('首次课表引导可直接配置上下课提醒', (tester) async {
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: gzusTheme(Brightness.light),
        home: ScheduleOnboardingPage(
          api: ApiClient(
            baseUrl: 'https://api.example.test',
            httpClient: MockClient(
              (request) async =>
                  http.Response(jsonEncode(<String, Object>{}), 200),
            ),
          ),
          studentName: '测试同学',
          onComplete: () => completed = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('上下课提醒'), findsOneWidget);
    expect(find.text('按课表在上课和下课前提醒你'), findsOneWidget);
    expect(find.text('上课前提醒'), findsNothing);

    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.text('上课前提醒'), findsOneWidget);
    expect(find.text('下课前提醒'), findsOneWidget);
    await tester.ensureVisible(find.text('完成，开始使用'));
    await tester.tap(find.text('完成，开始使用'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(completed, isTrue);
    expect(prefs.getBool('schedule.courseRemindersEnabled'), isTrue);
    expect(prefs.getInt('schedule.courseStartReminderMinutes'), 10);
    expect(prefs.getInt('schedule.courseEndReminderMinutes'), 5);
    expect(tester.takeException(), isNull);
  });
}
