import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('登录态失效后仅保留当前学号的课表缓存', () async {
    const studentId = '20240001';
    SharedPreferences.setMockInitialValues({
      'auth.sessionId': 'session-1',
      'auth.studentId': studentId,
      'auth.studentName': '测试学生',
      'auth.account': studentId,
      'auth.credentialToken': 'credential',
      'pcache_${studentId}_schedule_2026_1': jsonEncode([
        {
          'name': '高等数学',
          'weekday': 1,
          'startSection': 1,
          'endSection': 2,
          'weeks': '1-16',
        },
      ]),
      'pcache_${studentId}_schedule_2026_1_at': '2026-08-01T00:00:00.000',
      'pcache_${studentId}_me': jsonEncode({
        'studentId': studentId,
        'name': '测试学生',
      }),
      'pcache_${studentId}_grades_2026_1': jsonEncode([]),
      'pcache_${studentId}_notices': jsonEncode([]),
    });
    final api = ApiClient(httpClient: MockClient((request) async {
      fail('课表缓存命中时不应发起网络请求: ${request.url}');
    }));
    api
      ..useSession('session-1')
      ..setStudentId(studentId);

    await api.enterScheduleOnlyMode();
    final prefs = await SharedPreferences.getInstance();
    final schedule = await api.schedule(year: 2026, term: 1);

    expect(api.sessionId, isNull);
    expect(api.studentId, isNull);
    expect(api.isScheduleOnlyMode, isTrue);
    expect(api.namespace, studentId);
    expect(prefs.containsKey('auth.sessionId'), isFalse);
    expect(prefs.containsKey('auth.studentId'), isFalse);
    expect(prefs.containsKey('auth.studentName'), isFalse);
    expect(prefs.containsKey('auth.credentialToken'), isFalse);
    expect(prefs.containsKey('pcache_${studentId}_schedule_2026_1'), isTrue);
    expect(prefs.containsKey('pcache_${studentId}_schedule_2026_1_at'), isTrue);
    expect(prefs.containsKey('pcache_${studentId}_me'), isFalse);
    expect(prefs.containsKey('pcache_${studentId}_grades_2026_1'), isFalse);
    expect(prefs.containsKey('pcache_${studentId}_notices'), isFalse);
    expect(schedule.data.items.single.name, '高等数学');
    expect(schedule.source.fromLocalCache, isTrue);
  });
}
