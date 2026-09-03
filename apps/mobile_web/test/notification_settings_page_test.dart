import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/gzus_design.dart';
import 'package:gzus_pro_mobile_web/pages/notifications/notification_settings_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('通知设置页可在加载完成后正常展示滚动内容', (tester) async {
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        final body = jsonEncode({
          'enabled': true,
          'courseRemindersEnabled': true,
          'lastCheckedAt': null,
          'lastError': null,
          'courseSyncError': null,
          'noticesEnabled': true,
          'gradesEnabled': true,
          'examsEnabled': true,
          'attendanceEnabled': true,
          'status': 'not_bound',
        });
        return http.Response(body, 200);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: gzusTheme(Brightness.light),
        home: NotificationSettingsPage(
          api: api,
          onOpenBackgroundGuide: () {},
          onOpenSchedule: () {},
          onOpenEcard: () {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('通知设置'), findsOneWidget);
    expect(find.text('教务动态'), findsOneWidget);
    expect(find.text('课程与生活'), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
