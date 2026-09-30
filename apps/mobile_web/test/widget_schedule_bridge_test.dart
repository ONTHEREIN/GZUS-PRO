import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/schedule_adjustment_sync.dart';
import 'package:gzus_pro_mobile_web/widget_schedule_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cn.gzus.pro/home_widgets');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final firstWeek = DateTime(2026, 9, 7);
  final calls = <Map<String, Object?>>[];
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'updateScheduleContext');
      calls.add(Map<String, Object?>.from(call.arguments as Map));
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  ScheduleAdjustmentRecord adjustment(String id) => ScheduleAdjustmentRecord(
        clientId: id,
        year: 2026,
        term: 1,
        sourceDate: firstWeek,
        targetDate: DateTime(2026, 9, 14),
        sourceOccurrenceKeys: const [],
        targetConflictKeys: const [],
        conflictMode: 'coexist',
        status: 'active',
        revision: 1,
      );
  ApiClient api() => ApiClient(baseUrl: 'https://api.example.test')
    ..useSession('session-A')
    ..setStudentId('A');
  Future<void> sync(ApiClient client, bool Function() isCurrent) =>
      updateWidgetSchedule(
        api: client,
        year: 2026,
        term: 1,
        firstWeekStart: firstWeek,
        courses: [
          ScheduleCourse(
              name: '数学',
              weekday: 1,
              startSection: 1,
              endSection: 2,
              weeks: '1')
        ],
        adjustments: [adjustment('cloud'), adjustment('pending')],
        overrides: const [],
        isCurrent: isCurrent,
      );

  test('原生后台只收到当前账号待同步队列，已同步云端记录不进入请求', () async {
    final client = api();
    await ScheduleAdjustmentSync.enqueue('A', adjustment('pending'));
    await ScheduleAdjustmentSync.enqueue('B', adjustment('other-account'));
    await sync(client, () => true);
    final payload = calls.single;
    final context =
        jsonDecode(payload['widgetScheduleContextJson'] as String) as Map;
    expect(
        (context['pendingAdjustments'] as List).map((item) => item['clientId']),
        ['pending']);
    final courses =
        jsonDecode(payload['effectiveCoursesJson'] as String) as List;
    expect(courses.single['date'], '2026-09-14');
    expect(payload['widgetSessionId'], 'session-A');
  });

  test('账号切换或旧课表加载失效后不调用原生组件', () async {
    final client = api();
    await expectLater(sync(client, () => false), throwsA(isA<StateError>()));
    await expectLater(
        sync(client, () {
          client.setStudentId('B');
          return true;
        }),
        throwsA(isA<StateError>()));
    expect(calls, isEmpty);
  });
}
