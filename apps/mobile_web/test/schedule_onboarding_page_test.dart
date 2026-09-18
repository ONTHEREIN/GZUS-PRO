import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/gzus_design.dart';
import 'package:gzus_pro_mobile_web/onboarding_preferences.dart';
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
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient(
        (request) async => http.Response(
          request.url.path == '/schedule'
              ? '[]'
              : jsonEncode(<String, Object>{}),
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: gzusTheme(Brightness.light),
        home: ScheduleOnboardingPage(
          api: api,
          studentName: '测试同学',
          onComplete: () => completed = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('上下课提醒'), findsOneWidget);
    expect(find.text('按课表在上课和下课前提醒你'), findsOneWidget);
    expect(find.text('上课前提醒'), findsNothing);

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.text('上课前提醒'), findsOneWidget);
    expect(find.text('下课前提醒'), findsOneWidget);
    await tester.ensureVisible(find.text('完成，开始使用'));
    await tester.tap(find.text('完成，开始使用'));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;

    final prefs = await SharedPreferences.getInstance();
    expect(completed, isTrue);
    expect(
      prefs.getBool(onboardingPreferenceKey(api.namespace, 'completed')),
      isNull,
    );
    expect(
      prefs.getBool(
        schedulePreferenceKey(api.namespace, 'courseRemindersEnabled'),
      ),
      isTrue,
    );
    expect(
      prefs.getInt(
        schedulePreferenceKey(api.namespace, 'courseStartReminderMinutes'),
      ),
      10,
    );
    expect(
      prefs.getInt(
        schedulePreferenceKey(api.namespace, 'courseEndReminderMinutes'),
      ),
      5,
    );
    expect(tester.takeException(), isNull);
  });
}
