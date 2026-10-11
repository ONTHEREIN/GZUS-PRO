import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/main.dart';
import 'package:gzus_pro_mobile_web/pages/login/login_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues(
        {'auth.deviceToken': 'test-device-token'});
    SharedPreferences.setMockInitialValues({
      'notification.installationId': 'installation-test-0001',
      'auth.sessionId': 'expired-session',
      'auth.studentId': 'test-account',
    });
  });

  test('临时恢复故障保留设备凭据', () async {
    final api = ApiClient(httpClient: MockClient((request) async {
      expect(request.url.path, '/api/auth/device/restore');
      expect(jsonDecode(request.body)['deviceToken'], 'test-device-token');
      return http.Response(
          jsonEncode({'detail': 'school temporarily unavailable'}), 503);
    }));
    await expectLater(
        api.relogin(),
        throwsA(isA<ApiException>()
            .having((error) => error.statusCode, 'status', 503)));
    const storage = FlutterSecureStorage();
    expect(await storage.read(key: 'auth.deviceToken'), 'test-device-token');
  });

  test('退出后迟到的设备恢复响应不能写回登录态', () async {
    final pending = Completer<http.Response>();
    final started = Completer<void>();
    final api = ApiClient(httpClient: MockClient((request) {
      started.complete();
      return pending.future;
    }));
    final restoring = api.relogin();
    final expectation = expectLater(
        restoring,
        throwsA(isA<ApiException>().having(
            (error) => error.code, 'code', 'authentication_cancelled')));
    await started.future;
    await api.clearSavedAuthState();
    pending.complete(http.Response(
        jsonEncode({
          'status': 'ok',
          'sessionId': 'late-session',
          'studentId': 'test-account',
        }),
        200));
    await expectation;
    expect(api.sessionId, isNull);
    expect(api.deviceToken, isNull);
    const storage = FlutterSecureStorage();
    expect(await storage.read(key: 'auth.deviceToken'), isNull);
  });

  testWidgets('启动恢复超过八秒仍显示恢复状态，失败后可重试', (tester) async {
    final pending = Completer<http.Response>();
    final started = Completer<void>();
    final api = ApiClient(httpClient: MockClient((request) {
      if (request.url.path.endsWith('/auth/device/restore')) {
        if (!started.isCompleted) started.complete();
        return pending.future;
      }
      return Future.value(http.Response('{}', 200));
    }));
    await tester.pumpWidget(
        OneGzusApp.withApi(api: api, onAuthenticationChanged: null));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(seconds: 9));
    expect(find.byType(LoginPage), findsNothing);
    expect(find.byType(LoadingPage), findsOneWidget);
    pending
        .complete(http.Response(jsonEncode({'detail': 'school timeout'}), 503));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('auth-restore-retry')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
