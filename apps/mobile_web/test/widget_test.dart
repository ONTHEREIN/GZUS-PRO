import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/main.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/live_activity_service.dart';
import 'package:gzus_pro_mobile_web/reminder_service.dart';
import 'package:gzus_pro_mobile_web/ws_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('course reminders include start and end slots', () {
    final course = ScheduleCourse.fromJson({
      'name': '高等数学',
      'teacher': '张老师',
      'classroom': 'A101',
      'weekday': 1,
      'startSection': 1,
      'endSection': 2,
      'weeks': '1-16',
    });

    final slots = ReminderService.buildCourseReminderSlots(
      courses: [course],
      firstWeekStart: DateTime(2026, 6, 1),
      settings: const CourseReminderSettings(enabled: true),
      now: DateTime(2026, 6, 1, 8, 45),
      horizonDays: 1,
    );

    expect(slots.length, 2);
    expect(slots[0].title, '即将上课');
    expect(slots[0].when, DateTime(2026, 6, 1, 8, 50));
    expect(slots[1].title, '即将下课');
    expect(slots[1].when, DateTime(2026, 6, 1, 10, 15));
  });

  test('live push message id is stable from server id', () {
    final first = WsService.notificationIdForMessage({
      'id': 'exam_reminder:sid1:math',
      'type': 'exam_reminder',
      'title': '考试提醒',
      'body': '高等数学',
    });
    final second = WsService.notificationIdForMessage({
      'id': 'exam_reminder:sid1:math',
      'type': 'exam_reminder',
      'title': '考试提醒',
      'body': '高等数学 updated',
    });

    expect(first, second);
  });

  test('websocket url uses explicit default ports', () {
    expect(
      WsService.buildWsUrlForTest('https://onegzus.cc.cd/api', 'sid'),
      'wss://onegzus.cc.cd:443/api/ws/notifications?sessionId=sid',
    );
    expect(
      WsService.buildWsUrlForTest('http://127.0.0.1:8000/api', 'sid'),
      'ws://127.0.0.1:8000/api/ws/notifications?sessionId=sid',
    );
  });

  test('native ecard summary enriches backend cache with direct balance',
      () async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    debugDisableEcardDirectForTests = false;
    debugEcardDirectClientFactoryForTests = () => _FakeEcardDirectClient(
          balance: {
            'powerBalance': 12.5,
            'du': '度',
            'formatPowerBalanceStr': '12.5 度',
            'coldWaterBalance': 3.2,
            'dun': '吨',
            'coldWaterText': '3.2 吨',
            'hotWaterBalance': 6.8,
          },
        );
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      debugDisableEcardDirectForTests = false;
      debugEcardDirectClientFactoryForTests = null;
    });

    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/ecard/summary') {
          return http.Response(
            jsonEncode({
              'status': 'ok',
              'roomId': 'CGCOMMON1111|1|A2|932',
              'roomDisplay': '校本部 A2 A2-932',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'PATCH' &&
            request.url.path == '/ecard/summary-cache') {
          return http.Response(
            jsonEncode({'status': 'ok'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      }),
    );

    final result = await api.ecardSummary(forceRefresh: true);

    expect(result.data.powerBalance, 12.5);
    expect(result.data.powerText, '12.5 度');
    expect(result.data.coldWaterBalance, 3.2);
    expect(result.data.coldWaterText, '3.2 吨');
    expect(result.data.hotWaterBalance, 6.8);
    expect(result.data.hotWaterText, '6.8 元');
  });

  test('live activity maps notification messages to targets', () {
    final exam = LiveActivityEvent.fromMessage({
      'id': 'exam-1',
      'type': 'exam_reminder',
      'title': '考试提醒',
      'body': '高数 23:00',
      'style': 'timer',
      'endTime': 1780930800000,
      'shortCriticalText': '考试',
    });
    final ecard = LiveActivityEvent.fromMessage({
      'id': 'ecard-1',
      'type': 'ecard_reminder',
      'title': '电量偏低',
      'body': '9 度',
      'style': 'metric',
      'ongoing': false,
    });
    final course = LiveActivityEvent.courseReminder(
      id: 42,
      title: '即将上课',
      body: '1 分钟后：高等数学',
      courseName: '高等数学',
      countdownTarget: DateTime(2026, 6, 8, 9),
      shortText: '1min',
    );

    expect(exam.targetTab, 'exams');
    expect(exam.isTimer, isTrue);
    expect(ecard.targetTab, 'ecard');
    expect(ecard.isMetric, isTrue);
    expect(course.targetTab, 'schedule');
    expect(course.isTimer, isTrue);
  });

  test('live activity parses grade update and progress fields', () {
    final grade = LiveActivityEvent.fromMessage({
      'id': 'grade-1',
      'type': 'grade_update',
      'title': '成绩更新',
      'body': '移动应用开发：92',
      'style': 'progress',
      'shortCriticalText': '成绩',
      'progressMax': 100,
      'progressCurrent': 75,
    });

    expect(grade.targetTab, 'grades');
    expect(grade.progress, 0.75);
    expect(grade.isMetric, isFalse);
  });

  testWidgets('live activity updates same id and collapses', (tester) async {
    final controller = LiveActivityController.instance;
    controller.resetForTest();
    addTearDown(controller.resetForTest);

    controller.show(LiveActivityEvent(
      id: 'same',
      type: 'ecard_reminder',
      title: '电量偏低',
      body: '20 度',
      targetTab: 'ecard',
    ));
    controller.show(LiveActivityEvent(
      id: 'same',
      type: 'ecard_reminder',
      title: '电量极低',
      body: '9 度',
      targetTab: 'ecard',
    ));

    expect(controller.state.value.event?.title, '电量极低');
    expect(controller.state.value.expanded, isTrue);

    await tester.pump(LiveActivityController.initialExpandedDuration +
        const Duration(milliseconds: 300));

    expect(controller.state.value.event?.id, 'same');
    expect(controller.state.value.expanded, isFalse);
  });

  testWidgets('live activity timer dismisses at end time', (tester) async {
    final controller = LiveActivityController.instance;
    controller.resetForTest();
    addTearDown(controller.resetForTest);

    controller.show(LiveActivityEvent(
      id: 'timer',
      type: 'exam_reminder',
      title: '考试提醒',
      body: '高数',
      style: 'timer',
      endTime: DateTime.now().add(const Duration(milliseconds: 600)),
      targetTab: 'exams',
      ongoing: true,
    ));

    expect(controller.state.value.visible, isTrue);

    await tester.pump(const Duration(milliseconds: 800));

    expect(controller.state.value.visible, isFalse);
  });

  test('login result accepts responses without ehall secrets', () {
    final result = LoginResult.fromJson({
      'status': 'ok',
      'sessionId': 'session-1',
    });

    expect(result.sessionId, 'session-1');
    expect(result.ehallCookies, isNull);
    expect(result.ehallAuthToken, isNull);
  });

  test('attendance records parse day details', () {
    final item = AttendanceItem.fromJson({
      'courseName': '移动应用开发',
      'normal': 1,
      'late': 1,
      'records': [
        {
          'date': '2026-06-03 09:00',
          'status': 'late',
          'statusLabel': '迟到',
          'count': 1,
          'time': '第1-2节',
        }
      ],
    });

    expect(item.records.single.normalizedDate, '2026-06-03');
    expect(item.records.single.statusLabel, '迟到');
  });

  test('leave combined script stops before final submit', () {
    final response = LeaveFillResponse.fromJson({
      'status': 'filled',
      'message': 'ok',
      'attachmentUploaded': true,
      'fillScript': "window.__filled = true;",
      'handlerScript': "window.__handler = true;",
      'unmatchedTeachers': [],
    });

    final script = response.combinedScript!;

    expect(script, contains('fileframe_file1'));
    expect(script, contains('refreshAttachmentList'));
    expect(script, isNot(contains('pickfiles')));
    expect(script, contains('prepareSubmit'));
    expect(script, contains('findFinalSubmitButton'));
    expect(script, contains('已停在最终提交前'));
    expect(script, contains("text !== '提交'"));
    expect(script, contains('window.alert ='));
    expect(script, contains('window.__filled = true;'));
    expect(script, contains('window.__handler = true;'));
  });

  test('api returns local cache and throttles background refresh', () async {
    final release = Completer<void>();
    var calls = 0;
    SharedPreferences.setMockInitialValues({
      'pcache_default_notices': jsonEncode([
        {'title': '本地通知', 'category': '通知'}
      ]),
      'pcache_default_notices_at': DateTime(2026, 6, 3, 10).toIso8601String(),
    });
    final api = ApiClient(
      httpClient: MockClient((request) async {
        calls++;
        await release.future;
        return http.Response.bytes(
          utf8.encode(jsonEncode([
            {'title': '服务器通知', 'category': '通知'}
          ])),
          200,
        );
      }),
    );

    final first = await api.notices();
    final second = await api.notices();
    await Future<void>.delayed(Duration.zero);

    expect(first.data.single.title, '本地通知');
    expect(first.source.displayText, '本地缓存');
    expect(second.data.single.title, '本地通知');
    expect(calls, 1);

    release.complete();
    await Future<void>.delayed(Duration.zero);
  });

  test('api force refresh skips local cache and updates it', () async {
    SharedPreferences.setMockInitialValues({
      'pcache_default_credits': jsonEncode([
        {'name': '本地学生', 'totalCredit': '100'}
      ]),
      'pcache_default_credits_at': DateTime(2026, 6, 3, 10).toIso8601String(),
    });
    var calls = 0;
    final api = ApiClient(
      httpClient: MockClient((request) async {
        calls++;
        return http.Response.bytes(
          utf8.encode(jsonEncode([
            {'name': '服务器学生', 'totalCredit': '160'}
          ])),
          200,
        );
      }),
    );

    final result = await api.credits(forceRefresh: true);
    final prefs = await SharedPreferences.getInstance();

    expect(result.data.single.name, '服务器学生');
    expect(result.source.isStale, isFalse);
    expect(calls, 1);
    expect(prefs.getString('pcache_default_credits'), contains('服务器学生'));
  });

  test('api marks cached fallback as requiring relogin on 401', () async {
    SharedPreferences.setMockInitialValues({
      'pcache_default_me': jsonEncode({
        'studentId': '2024000000',
        'name': '本地学生',
      }),
      'pcache_default_me_at': DateTime(2026, 6, 3, 10).toIso8601String(),
    });
    final api = ApiClient(
      httpClient: MockClient((request) async {
        return http.Response(jsonEncode({'detail': 'expired'}), 401);
      }),
    );

    final result = await api.me(forceRefresh: true);

    expect(result.data.name, '本地学生');
    expect(result.source.isOffline, isTrue);
    expect(result.source.needsRelogin, isTrue);
    expect(result.source.displayText, '教务系统会话已失效，请重新登录');
  });

  test('api requests do not wait for warmup', () async {
    SharedPreferences.setMockInitialValues({});
    final healthRelease = Completer<void>();
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/health') {
          await healthRelease.future;
          return http.Response(jsonEncode({'status': 'ok'}), 200);
        }
        if (request.url.path == '/me') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'studentId': '2024000000',
              'name': '服务器学生',
            })),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );

    api.startWarmup();
    final result = await api
        .me(forceRefresh: true)
        .timeout(const Duration(milliseconds: 500));
    healthRelease.complete();

    expect(result.data.name, '服务器学生');
  });

  test('api clears expired credential token without password fallback',
      () async {
    SharedPreferences.setMockInitialValues({
      'auth.credentialToken': 'expired-token',
      'auth.rememberPassword': true,
      'auth.account': '2024000000',
      'auth.password': 'legacy-password',
    });
    var autoLoginCalled = false;
    final api = ApiClient(
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/me')) {
          return http.Response(jsonEncode({'detail': 'expired'}), 401);
        }
        if (request.url.path.endsWith('/auth/relogin')) {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'detail': '凭据已失效，请重新登录'})),
            401,
          );
        }
        if (request.url.path.endsWith('/auth/auto-login')) {
          autoLoginCalled = true;
        }
        return http.Response('not found', 404);
      }),
    );

    await expectLater(
      api.me(forceRefresh: true),
      throwsA(isA<ApiException>()),
    );
    final prefs = await SharedPreferences.getInstance();

    expect(autoLoginCalled, isFalse);
    expect(prefs.getString('auth.credentialToken'), isNull);
    expect(prefs.getString('auth.password'), isNull);
  });

  test('api clears persisted auth state on session revocation', () async {
    SharedPreferences.setMockInitialValues({
      'auth.sessionId': 'old-session',
      'auth.studentName': '旧设备',
      'auth.studentId': '2024000000',
      'auth.ehallCookies': 'cookie',
      'auth.ehallAuthToken': 'token',
      'auth.loginMethod': 'password',
      'auth.credentialToken': 'credential',
      'auth.account': '2024000000',
      'auth.password': 'legacy-password',
      'auth.rememberPassword': true,
    });
    final api = ApiClient(httpClient: MockClient((request) async {
      return http.Response('not found', 404);
    }));
    api.useSession('old-session');
    await api.loadSavedCredentials();

    await api.clearSavedAuthState();
    final prefs = await SharedPreferences.getInstance();

    expect(api.sessionId, isNull);
    expect(prefs.getString('auth.sessionId'), isNull);
    expect(prefs.getString('auth.credentialToken'), isNull);
    expect(prefs.getString('auth.account'), isNull);
    expect(prefs.getBool('auth.rememberPassword'), isNull);
  });

  test('api clears saved auth and notifies on single-device conflict',
      () async {
    SharedPreferences.setMockInitialValues({
      'auth.sessionId': 'old-session',
      'auth.credentialToken': 'credential',
      'auth.account': '2024000000',
      'auth.rememberPassword': true,
    });
    var reloginFailed = false;
    final api = ApiClient(
      httpClient: MockClient((request) async {
        return http.Response.bytes(
          utf8.encode('账号已在其他设备登录，请重新登录'),
          401,
        );
      }),
    )
      ..useSession('old-session')
      ..onReloginFailed = () {
        reloginFailed = true;
      };

    await expectLater(
      api.me(forceRefresh: true),
      throwsA(isA<ApiException>()
          .having((error) => error.isSingleDeviceConflict, 'conflict', true)),
    );
    final prefs = await SharedPreferences.getInstance();

    expect(reloginFailed, isTrue);
    expect(api.sessionId, isNull);
    expect(prefs.getString('auth.sessionId'), isNull);
    expect(prefs.getString('auth.credentialToken'), isNull);
    expect(prefs.getString('auth.account'), isNull);
  });

  test('api stores remembered account without password', () async {
    SharedPreferences.setMockInitialValues({
      'auth.password': 'legacy-password',
    });
    final api = ApiClient(httpClient: MockClient((request) async {
      return http.Response('not found', 404);
    }));

    await api.savePasswordCredentials(
      '2024000000',
      'sample-password',
      remember: true,
    );
    final prefs = await SharedPreferences.getInstance();

    expect(prefs.getBool('auth.rememberPassword'), isTrue);
    expect(prefs.getString('auth.account'), '2024000000');
    expect(prefs.getString('auth.password'), isNull);
  });

  test('native academic reads prefer direct school endpoint', () async {
    SharedPreferences.setMockInitialValues({});
    debugEnableSchoolDirectForTests = true;
    addTearDown(() {
      debugEnableSchoolDirectForTests = false;
      debugSchoolDirectHttpClientForTests = null;
    });
    var apiCalled = false;
    var directCalled = false;
    debugSchoolDirectHttpClientForTests = MockClient((request) async {
      directCalled = true;
      expect(request.url.host, 'jwxt.seig.edu.cn');
      expect(request.headers['Cookie'], contains('JSESSIONID=direct'));
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'kbList': [
            {
              'kcmc': '直连课程',
              'jsxx': '张老师',
              'cdmc': 'A101',
              'xqj': 2,
              'ksjc': '3-4',
              'zcd': '1-16',
            }
          ],
        })),
        200,
      );
    });
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        apiCalled = true;
        return http.Response('unexpected api call', 500);
      }),
    )..setJwxtCookies('JSESSIONID=direct');
    await api.savePasswordCredentials('2024000000', 'secret', remember: false);

    final result = await api.schedule(year: 2026, term: 2, forceRefresh: true);

    expect(directCalled, isTrue);
    expect(apiCalled, isFalse);
    expect(result.data.items.single.name, '直连课程');
    expect(result.data.items.single.startSection, 3);
    expect(result.data.items.single.endSection, 4);
  });

  test('native academic reads fall back to API when direct fails', () async {
    SharedPreferences.setMockInitialValues({});
    debugEnableSchoolDirectForTests = true;
    addTearDown(() {
      debugEnableSchoolDirectForTests = false;
      debugSchoolDirectHttpClientForTests = null;
    });
    var directCalled = false;
    var apiCalled = false;
    debugSchoolDirectHttpClientForTests = MockClient((request) async {
      directCalled = true;
      return http.Response('school error', 502);
    });
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        apiCalled = true;
        expect(request.url.path, '/grades');
        return http.Response.bytes(
          utf8.encode(jsonEncode([
            {'courseName': 'API课程', 'score': '95'}
          ])),
          200,
        );
      }),
    )..setJwxtCookies('JSESSIONID=direct');
    await api.savePasswordCredentials('2024000000', 'secret', remember: false);

    final result = await api.grades(year: 2026, term: 2, forceRefresh: true);

    expect(directCalled, isTrue);
    expect(apiCalled, isTrue);
    expect(result.data.single.courseName, 'API课程');
  });

  testWidgets('renders login page', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const OneGzusApp());
    await tester.pumpAndSettle();

    expect(find.text('软帮手 Dev'), findsOneWidget);
    expect(find.text('推荐使用办事大厅统一登录'), findsOneWidget);
    expect(find.text('办事大厅统一登录'), findsOneWidget);
    expect(find.text('教务系统登录'), findsWidgets);
  });

  testWidgets('mobile sso is enabled without account', (tester) async {
    SharedPreferences.setMockInitialValues({'auth.agreedToTerms': true});

    await tester.pumpWidget(const OneGzusApp());
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

    await tester.pumpWidget(const OneGzusApp());
    await tester.pumpAndSettle();

    expect(find.text('软帮手 Dev'), findsOneWidget);
    expect(find.text('办事大厅统一登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dashboard uses bottom tabs on mobile', (tester) async {
    await _pumpDashboard(tester, const Size(390, 844));

    expect(find.byKey(const ValueKey('mobile-bottom-nav')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-sidebar')), findsNothing);
    expect(find.byKey(const ValueKey('dashboard-header-tools')), findsNothing);
    expect(find.byKey(const ValueKey('mobile-header-toggle')), findsNothing);
    expect(find.text('首页'), findsWidgets);
    expect(find.text('下一节课'), findsOneWidget);
    expect(find.byKey(const ValueKey('dashboard-header-tools')), findsNothing);

    await tester.tap(find.text('课表').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('移动应用开发'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dashboard opens home by default', (tester) async {
    await _pumpDashboard(tester, const Size(390, 844));

    expect(find.text('首页'), findsWidgets);
    expect(find.text('下一节课'), findsOneWidget);
    expect(find.textContaining('移动应用开发'), findsWidgets);
  });

  testWidgets('today timeline fits dense desktop home grid with large text',
      (tester) async {
    final scheduleItems = List.generate(8, (index) {
      final section = index + 1;
      return {
        'name': '超长课程名称用于验证今日时间线不会溢出 $section',
        'teacher': '张老师',
        'classroom': '教学楼A座超长教室名称-$section',
        'weekday': DateTime.now().weekday,
        'startSection': section,
        'endSection': section,
        'weeks': '1-30',
      };
    });

    await _pumpDashboard(
      tester,
      const Size(1180, 820),
      scheduleItems: scheduleItems,
      textScaleFactor: 1.3,
    );

    expect(find.text('今日时间线'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('live activity island expands, collapses, and opens target tab',
      (tester) async {
    final controller = LiveActivityController.instance;
    await _pumpDashboard(tester, const Size(390, 844));

    controller.show(LiveActivityEvent(
      id: 'exam-island',
      type: 'exam_reminder',
      title: '考试提醒',
      body: '高等数学 23:00',
      style: 'timer',
      endTime: DateTime.now().add(const Duration(minutes: 30)),
      shortText: '考试',
      targetTab: 'exams',
      ongoing: true,
    ));
    await tester.pump();

    expect(find.byKey(const ValueKey('live-activity-island')), findsOneWidget);
    expect(find.text('考试提醒'), findsOneWidget);
    expect(find.text('高等数学 23:00'), findsOneWidget);

    await tester.pump(LiveActivityController.initialExpandedDuration +
        const Duration(milliseconds: 400));

    expect(find.text('高等数学 23:00'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('live-activity-island')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('live-activity-action')));
    await tester.pumpAndSettle();

    expect(find.byType(ExamsPage), findsOneWidget);
    controller.resetForTest();
  });

  testWidgets('dashboard uses sidebar on desktop', (tester) async {
    await _pumpDashboard(tester, const Size(1180, 820));

    expect(find.byKey(const ValueKey('app-sidebar')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-bottom-nav')), findsNothing);
  });

  testWidgets('mobile dashboard tabs fit every page', (tester) async {
    await _pumpDashboard(tester, const Size(390, 844));

    for (final label in ['首页', '信息', '应用', '课表', '更多']) {
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$label should fit');
    }
  });

  testWidgets('home widget guide explains setup and examples', (tester) async {
    await _pumpDashboard(tester, const Size(1180, 820), hideEcard: true);

    await tester.tap(find.text('更多').last);
    await tester.pumpAndSettle();
    final guideTile = find.byKey(const ValueKey('home-widget-guide-tile'));
    await tester.ensureVisible(guideTile);
    await tester.pumpAndSettle();
    await tester.tap(guideTile);
    await tester.pumpAndSettle();

    expect(find.text('添加方法'), findsOneWidget);
    expect(find.text('组件示例'), findsOneWidget);
    expect(find.text('下一节课'), findsWidgets);
    expect(find.text('生活缴费'), findsNothing);
    expect(find.textContaining('Android 桌面长按空白处'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home customization hides a module', (tester) async {
    await _pumpDashboard(tester, const Size(390, 844));

    await tester.tap(find.widgetWithText(TextButton, '自定义'));
    await tester.pumpAndSettle();
    expect(find.text('自定义首页'), findsOneWidget);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('home.hiddenModules'), contains('nextClass'));
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
      MaterialApp(
        home: DashboardShell(
          api: _mockApi(),
          studentName: '测试学生',
          themeMode: ThemeMode.light,
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

  testWidgets('schedule switches between today week and all views',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'schedule.2025.2.firstWeekStart': '2026-02-16',
      'schedule.autoWeek': true,
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: DashboardShell(
          api: _mockApi(),
          studentName: '测试学生',
          themeMode: ThemeMode.light,
          onThemeChanged: (_) {},
          onLogout: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('课表').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('schedule-view-mode')), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('schedule-view-mode')),
      matching: find.text('本周'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('09:00-10:20'), findsOneWidget);
    expect(find.text('周一'), findsWidgets);
    expect(find.text('1节'), findsWidgets);

    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('schedule-view-mode')),
      matching: find.text('全部'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('移动应用开发'), findsWidgets);
    expect(find.text('1条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('auto leave page previews matched courses', (tester) async {
    await _pumpDashboard(tester, const Size(390, 844));

    await tester.tap(find.text('更多').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('请假').last);
    await tester.pumpAndSettle();

    expect(find.text('自动请假'), findsWidgets);

    await tester.enterText(find.widgetWithText(TextField, '请假理由'), '事假');
    await tester.tap(find.text('匹配课程'));
    await tester.pumpAndSettle();

    expect(find.text('移动应用开发'), findsOneWidget);
    expect(find.text('张老师'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ecard page binds room and shows balances', (tester) async {
    await _pumpDashboard(tester, const Size(1180, 820));

    await tester.tap(find.text('生活缴费').last);
    await tester.pumpAndSettle();

    expect(find.text('宿舍绑定'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'A2');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('校本部 A2 A2-932'));
    await tester.pumpAndSettle();

    expect(find.text('生活缴费'), findsWidgets);
    expect(find.text('电费'), findsOneWidget);
    expect(find.text('9 度'), findsOneWidget);
    expect(find.text('冷水'), findsOneWidget);
    expect(find.text('热水'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('web dashboard hides ecard entries', (tester) async {
    await _pumpDashboard(tester, const Size(1180, 820), hideEcard: true);

    expect(find.text('生活缴费'), findsNothing);
    expect(find.text('水电余额'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('web more page does not offer ecard', (tester) async {
    await _pumpDashboard(tester, const Size(1180, 820), hideEcard: true);

    await tester.tap(find.text('更多').last);
    await tester.pumpAndSettle();

    expect(find.text('生活缴费'), findsNothing);
    expect(find.text('缴费'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('web ecard live activity target stays on current page',
      (tester) async {
    final controller = LiveActivityController.instance;
    await _pumpDashboard(tester, const Size(390, 844), hideEcard: true);

    controller.show(LiveActivityEvent(
      id: 'ecard-web',
      type: 'ecard_reminder',
      title: '电量偏低',
      body: '9 度',
      style: 'metric',
      targetTab: 'ecard',
    ));
    await tester.pump();
    controller.openCurrent();
    await tester.pumpAndSettle();

    expect(find.text('首页'), findsWidgets);
    expect(find.text('生活缴费'), findsNothing);
    expect(tester.takeException(), isNull);
    controller.resetForTest();
  });
}

Future<void> _pumpDashboard(
  WidgetTester tester,
  Size size, {
  bool hideEcard = false,
  List<Map<String, Object?>>? scheduleItems,
  double textScaleFactor = 1,
}) async {
  LiveActivityController.instance.resetForTest();
  debugHideEcardForTests = hideEcard;
  debugDisableEcardDirectForTests = true;
  addTearDown(() => debugHideEcardForTests = false);
  addTearDown(() => debugDisableEcardDirectForTests = false);
  addTearDown(LiveActivityController.instance.resetForTest);
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScaleFactor;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    MaterialApp(
      home: DashboardShell(
        api: _mockApi(scheduleItems: scheduleItems),
        studentName: '测试学生',
        themeMode: ThemeMode.light,
        onThemeChanged: (_) {},
        onLogout: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ApiClient _mockApi({List<Map<String, Object?>>? scheduleItems}) {
  final api = ApiClient(
    baseUrl: 'https://api.example.test',
    httpClient: MockClient((request) async {
      final path = request.url.path;
      Object body;
      switch (path) {
        case '/me':
          body = {
            'studentId': '2024000000',
            'name': '测试学生',
            'college': '软件学院',
            'major': '软件工程',
            'className': '软件2401',
            'grade': '2024',
          };
          break;
        case '/schedule':
          body = scheduleItems ??
              [
                {
                  'name': '移动应用开发',
                  'teacher': '张老师',
                  'classroom': 'A101',
                  'weekday': DateTime.now().weekday,
                  'startSection': 1,
                  'endSection': 2,
                  'weeks': '1-30',
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
                'records': [
                  {
                    'date': '2026-06-03',
                    'status': 'leave',
                    'statusLabel': '请假',
                    'count': 1,
                    'time': '第1-2节',
                  }
                ],
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
              'studentId': '2024000000',
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
        case '/notices':
          body = [
            {
              'category': '通知',
              'title': '期末考试安排',
              'summary': '请及时查看考试安排',
              'date': '2026-06-03',
            }
          ];
          break;
        case '/ecard/summary':
          body = {'status': 'not_bound'};
          break;
        case '/ecard/rooms':
          body = [
            {
              'id': 'CGCOMMON1111|1|A2|932',
              'schoolArea': '校本部',
              'building': 'A2',
              'room': 'A2-932',
              'displayName': '校本部 A2 A2-932',
            }
          ];
          break;
        case '/ecard/binding':
        case '/ecard/refresh':
          body = {
            'status': 'ok',
            'roomId': 'CGCOMMON1111|1|A2|932',
            'roomDisplay': '校本部 A2 A2-932',
            'powerBalance': 9,
            'powerUnit': '度',
            'powerText': '9 度',
            'coldWaterBalance': 2,
            'coldWaterUnit': '吨',
            'coldWaterText': '2 吨',
            'hotWaterBalance': 12.5,
            'hotWaterUnit': '元',
            'hotWaterText': '12.5 元',
            'reminderEnabled': true,
            'lowPowerThreshold': 30,
          };
          break;
        case '/ecard/reminder':
        case '/ecard/summary-cache':
          body = {
            'status': 'ok',
            'roomId': 'CGCOMMON1111|1|A2|932',
            'roomDisplay': '校本部 A2 A2-932',
            'reminderEnabled': true,
            'lowPowerThreshold': 30,
          };
          break;
        case '/ecard/consumption':
          body = {
            'status': 'limited',
            'message': '一卡通流水接口受限',
            'items': [],
          };
          break;
        case '/ehall/affairs':
        case '/ehall/applications':
          body = [];
          break;
        case '/ehall/progress':
          body = [
            {
              'id': 'p1',
              'title': '学生课程请假申请',
              'category': '申请',
              'status': 'processing',
              'statusLabel': '办理中',
              'date': '2026-06-03',
              'summary': '当前步骤：辅导员审批',
              'currentNode': '辅导员审批',
              'handler': '张老师',
              'progress': 60,
              'url': 'https://ehall.gzus.edu.cn/#/affairprocess?taskId=p1',
            }
          ];
          break;
        case '/ehall/leave/preview':
          body = {
            'status': 'ok',
            'hasMissingFields': false,
            'items': [
              {
                'courseName': '移动应用开发',
                'courseCode': 'CS101',
                'teachingClassCode': 'JXB001',
                'courseNature': '必修',
                'credit': '3',
                'classTime': '2026-03-09 第1-2节 09:00-10:20',
                'classTimes': ['2026-03-09 第1-2节 09:00-10:20'],
                'absenceCount': 1,
                'teacher': '张老师',
                'missingFields': [],
              }
            ],
          };
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
  api.useSession('test-session');
  api.setStudentId('2024000000');
  return api;
}

class _FakeEcardDirectClient extends EcardDirectClient {
  _FakeEcardDirectClient({this.balance});

  final Map<String, dynamic>? balance;

  @override
  Future<Map<String, dynamic>?> getBalance(String roomId,
          {String? studentId}) async =>
      balance;
}
