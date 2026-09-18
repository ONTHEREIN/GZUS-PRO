import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  testWidgets('通知设置页前置课程提醒并避让底部导航区域', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    expect(find.text('课程提醒'), findsOneWidget);
    expect(find.text('上下课提醒'), findsOneWidget);
    expect(find.text('教务动态'), findsOneWidget);
    expect(find.text('课程与生活'), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    final listView = tester.widget<ListView>(find.byType(ListView));
    expect((listView.padding! as EdgeInsets).bottom, greaterThan(24));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android 未授权时展示明确状态并提供系统通知设置入口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('cn.gzus.pro/live_update');
    var openedSettings = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getPromotedNotificationStatus') {
        return 'authorization_required';
      }
      if (call.method == 'openPromotedNotificationSettings') {
        openedSettings = true;
        return true;
      }
      return null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
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
          }),
          200,
        );
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

    expect(find.text('Android 实况通知推广资格：系统未授权'), findsOneWidget);
    expect(find.text('请在系统通知设置中允许实况更新，点击此处打开设置'), findsOneWidget);
    await tester.tap(find.text('Android 实况通知推广资格：系统未授权'));
    expect(openedSettings, isTrue);
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
