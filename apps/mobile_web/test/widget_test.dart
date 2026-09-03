import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/main.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/live_activity_service.dart';
import 'package:gzus_pro_mobile_web/pages/ecard/ecard_page.dart';
import 'package:gzus_pro_mobile_web/pages/exams/exams_page.dart';
import 'package:gzus_pro_mobile_web/pages/login/login_page.dart';
import 'package:gzus_pro_mobile_web/reminder_service.dart';
import 'package:gzus_pro_mobile_web/schedule_utils.dart';
import 'package:gzus_pro_mobile_web/widgets/async_panel.dart';
import 'package:gzus_pro_mobile_web/ws_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

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
      WsService.buildWsUrlForTest('https://onegzus.onrein.top/api', 'sid'),
      'wss://onegzus.onrein.top:443/api/ws/notifications?sessionId=sid',
    );
    expect(
      WsService.buildWsUrlForTest('http://127.0.0.1:8000/api', 'sid'),
      'ws://127.0.0.1:8000/api/ws/notifications?sessionId=sid',
    );
  });

  test(
      'electricity consumption requests the selected month and parses overview',
      () async {
    String? requestedMonth;
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/ecard/consumption') {
          requestedMonth = request.url.queryParameters['month'];
          return http.Response(
            jsonEncode({
              'status': 'ok',
              'cachedAt': '2026-06-03T08:00:00+08:00',
              'items': [
                {
                  'title': '剩余 100 度',
                  'amount': '2.5 度',
                  'time': '2026-06-03',
                  'date': '2026-06-03',
                  'usage': 2.5,
                  'unit': '度',
                }
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/ecard/consumption/overview') {
          return http.Response(
            jsonEncode({
              'status': 'ok',
              'months': [
                {
                  'month': '2026-06',
                  'recordedDays': 3,
                  'totalUsage': 8.5,
                  'averageDailyUsage': 2.83,
                  'peakDate': '2026-06-03',
                  'peakUsage': 4.0,
                  'unit': '度',
                  'cachedAt': '2026-06-03T08:00:00+08:00',
                }
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      }),
    );

    final consumption = await api.ecardConsumption(month: '2026-06');
    final overview = await api.ecardConsumptionOverview();

    expect(requestedMonth, '2026-06');
    expect(consumption.items.single.usage, 2.5);
    expect(overview.months.single.peakDate, '2026-06-03');
  });

  test('electricity consumption supports every requested sort order', () {
    final items = [
      EcardConsumptionItem.fromJson({
        'title': '6 月 1 日',
        'date': '2026-06-01',
        'usage': 1.0,
      }),
      EcardConsumptionItem.fromJson({
        'title': '6 月 2 日',
        'date': '2026-06-02',
        'usage': 4.0,
      }),
    ];

    expect(
      sortEcardConsumptionItems(items, EcardConsumptionSort.dateNewest)
          .map((item) => item.title),
      ['6 月 2 日', '6 月 1 日'],
    );
    expect(
      sortEcardConsumptionItems(items, EcardConsumptionSort.dateOldest)
          .map((item) => item.title),
      ['6 月 1 日', '6 月 2 日'],
    );
    expect(
      sortEcardConsumptionItems(items, EcardConsumptionSort.usageHighest)
          .map((item) => item.title),
      ['6 月 2 日', '6 月 1 日'],
    );
    expect(
      sortEcardConsumptionItems(items, EcardConsumptionSort.usageLowest)
          .map((item) => item.title),
      ['6 月 1 日', '6 月 2 日'],
    );
  });

  test(
      'native ecard summary uses cached backend balance without direct refresh',
      () async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    debugDisableEcardDirectForTests = false;
    final directClient = _FakeEcardDirectClient(
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
    debugEcardDirectClientFactoryForTests = () => directClient;
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
              'powerBalance': 9.0,
              'powerText': '9.0 度',
              'coldWaterBalance': 2.0,
              'coldWaterText': '2.0 吨',
              'hotWaterBalance': 5.0,
              'hotWaterText': '5.0 元',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      }),
    );

    final result = await api.ecardSummary(forceRefresh: true);

    expect(result.data.powerBalance, 9.0);
    expect(result.data.powerText, '9.0 度');
    expect(result.data.coldWaterBalance, 2.0);
    expect(result.data.coldWaterText, '2.0 吨');
    expect(result.data.hotWaterBalance, 5.0);
    expect(result.data.hotWaterText, '5.0 元');
    expect(directClient.balanceCalls, 0);
  });

  test('native ecard refresh skips stale local summary cache', () async {
    SharedPreferences.setMockInitialValues({
      'pcache_2024000000_ecard_summary': jsonEncode({
        'status': 'ok',
        'studentId': '2024000000',
        'roomId': 'CGCOMMON1111|1|A2|932',
        'roomDisplay': '校本部 A2 A2-932',
        'powerBalance': 1.0,
        'powerText': '1.0 度',
      }),
      'pcache_2024000000_ecard_summary_at':
          DateTime(2026, 1, 1).toIso8601String(),
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    debugDisableEcardDirectForTests = false;
    final directClient = _FakeEcardDirectClient(
      balance: {
        'powerBalance': 22.0,
        'du': '度',
        'formatPowerBalanceStr': '22.0 度',
        'coldWaterBalance': 4.5,
        'dun': '吨',
        'hotWaterBalance': 8.0,
      },
    );
    debugEcardDirectClientFactoryForTests = () => directClient;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      debugDisableEcardDirectForTests = false;
      debugEcardDirectClientFactoryForTests = null;
    });

    var summaryRequests = 0;
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/ecard/summary') {
          summaryRequests++;
          return http.Response(
            jsonEncode({
              'status': 'ok',
              'studentId': '2024000000',
              'roomId': 'CGCOMMON1111|1|A2|932',
              'roomDisplay': '校本部 A2 A2-932',
              'powerBalance': 1.0,
              'powerText': '1.0 度',
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
    api.useSession('test-session');
    api.setStudentId('2024000000');

    final summary = await api.refreshEcard();

    expect(summaryRequests, 0);
    expect(summary.powerBalance, 22.0);
    expect(summary.powerText, '22.0 度');
    expect(summary.coldWaterBalance, 4.5);
    expect(summary.hotWaterBalance, 8.0);
    expect(directClient.balanceCalls, 1);
  });

  test('binding a room invalidates the stale home dashboard snapshot',
      () async {
    SharedPreferences.setMockInitialValues({});
    var dashboardRequests = 0;
    var isBound = false;
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/dashboard') {
          dashboardRequests++;
          return http.Response(
            jsonEncode({
              'status': 'ok',
              'generatedAt': '2026-08-30T12:00:00Z',
              'modules': {
                'ecard': {
                  'status': isBound ? 'ok' : 'empty',
                  'data': isBound
                      ? {
                          'status': 'ok',
                          'roomId': 'CGCOMMON1111|1|A2|932',
                          'roomDisplay': '校本部 A2 A2-932',
                          'powerText': '9 度',
                        }
                      : {'status': 'not_bound'},
                },
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST' && request.url.path == '/ecard/binding') {
          isBound = true;
          return http.Response(
            jsonEncode({
              'status': 'ok',
              'roomId': 'CGCOMMON1111|1|A2|932',
              'roomDisplay': '校本部 A2 A2-932',
              'powerText': '9 度',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      }),
    );
    api.useSession('test-session');
    api.setStudentId('2024000000');

    final beforeBinding = await api.dashboard(year: 2026, term: 1, week: 1);
    expect(beforeBinding.data.module('ecard').objectData()?['status'],
        'not_bound');

    await api.bindEcardRoom(EcardRoomItem.fromJson({
      'id': 'CGCOMMON1111|1|A2|932',
      'displayName': '校本部 A2 A2-932',
    }));
    final afterBinding = await api.dashboard(year: 2026, term: 1, week: 1);

    expect(dashboardRequests, 2);
    expect(afterBinding.data.module('ecard').objectData()?['status'], 'ok');
    expect(afterBinding.data.module('ecard').objectData()?['powerText'], '9 度');
  });

  testWidgets(
      'ecard page keeps cached balance visible during background refresh',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    debugDisableEcardDirectForTests = false;
    final directClient = _DeferredEcardDirectClient();
    debugEcardDirectClientFactoryForTests = () => directClient;
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
              'studentId': '2024000000',
              'roomId': 'CGCOMMON1111|1|A2|932',
              'roomDisplay': '校本部 A2 A2-932',
              'powerBalance': 1.0,
              'powerText': '1.0 度',
              'coldWaterBalance': 2.0,
              'coldWaterText': '2.0 吨',
              'hotWaterBalance': 3.0,
              'hotWaterText': '3.0 元',
              'updatedAt': DateTime.now()
                  .subtract(const Duration(minutes: 31))
                  .toIso8601String(),
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

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: EcardPage(api: api))),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('1.0 度'), findsOneWidget);
    expect(directClient.balanceCalls, 1);

    directClient.complete({
      'powerBalance': 22.0,
      'du': '度',
      'formatPowerBalanceStr': '22.0 度',
      'coldWaterBalance': 4.5,
      'dun': '吨',
      'formatWaterBalanceStr': '4.5 吨',
      'hotWaterBalance': 8.0,
      'formatHotWaterBalanceStr': '8.0 元',
    });
    for (var index = 0; index < 5; index++) {
      await tester.pump();
    }

    expect(find.text('22.0 度'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
    debugDisableEcardDirectForTests = false;
    debugEcardDirectClientFactoryForTests = null;
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
      'courseId': 'course-1',
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
    expect(item.courseId, 'course-1');

    final detail = AttendanceDetail.fromJson({
      'academicYear': '2025-2026',
      'term': '1',
      'status': 'normal',
      'statusLabel': '正常',
      'offeringCollege': '基础与通识教育学院',
      'courseCode': 'GE1030',
      'courseName': '高等数学I(文)',
      'teachingClass': '教学班1',
      'teacher': '李老师',
      'rollCallTime': '2025-10-22 14:48:01',
      'classDate': '2025-10-22',
      'classTime': '10:40-12:00',
      'sections': '3-4',
      'studentId': '20250001',
      'studentName': '测试学生',
      'gender': '男',
      'college': '软件学院',
      'grade': '2025',
      'major': '软件工程',
      'className': '25软工1班',
      'remark': '已登记',
    });
    expect(detail.teacher, '李老师');
    expect(detail.classDate, '2025-10-22');
    expect(detail.remark, '已登记');
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
    expect(result.source.displayText, '登录状态已失效，请重新登录');
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
      'auth.jwxtCookies': 'jwxt-cookie',
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
    expect(prefs.getString('auth.jwxtCookies'), isNull);
    expect(prefs.getString('auth.account'), isNull);
    expect(prefs.getBool('auth.rememberPassword'), isNull);
  });

  test(
      'api requests reauthentication after device revocation while retaining account',
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
      throwsA(isA<ApiException>()),
    );
    final prefs = await SharedPreferences.getInstance();

    expect(reloginFailed, isTrue);
    expect(api.sessionId, isNull);
    expect(prefs.getString('auth.sessionId'), isNull);
    expect(prefs.getString('auth.credentialToken'), isNull);
    expect(prefs.getString('auth.account'), '2024000000');
    expect(prefs.getBool('auth.rememberPassword'), isTrue);
  });

  test('api coalesces concurrent relogin requests and refreshes the session',
      () async {
    SharedPreferences.setMockInitialValues({
      'auth.credentialToken': 'credential',
      'auth.account': '2024000000',
      'auth.rememberPassword': true,
    });
    final reloginStarted = Completer<void>();
    final releaseRelogin = Completer<void>();
    var reloginCalls = 0;
    var replacementCalls = 0;
    final api = ApiClient(
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/auth/relogin')) {
          reloginCalls++;
          if (!reloginStarted.isCompleted) reloginStarted.complete();
          await releaseRelogin.future;
          return http.Response(
            jsonEncode({
              'status': 'ok',
              'sessionId': 'new-session',
              'studentId': '2024000000',
              'credentialToken': 'new-credential',
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/me')) {
          if (request.headers['X-Session-Id'] != 'new-session') {
            return http.Response.bytes(
              utf8.encode(jsonEncode({'detail': '会话已过期'})),
              401,
            );
          }
          return http.Response.bytes(
            utf8.encode(
                jsonEncode({'studentId': '2024000000', 'name': '测试学生'})),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    )
      ..useSession('old-session')
      ..onSessionReplaced = (_) async {
        replacementCalls++;
      };

    final first = api.me(forceRefresh: true);
    await reloginStarted.future;
    final second = api.me(forceRefresh: true);
    await Future<void>.delayed(Duration.zero);
    releaseRelogin.complete();

    final results = await Future.wait([first, second]);

    expect(reloginCalls, 1);
    expect(replacementCalls, 1);
    expect(api.sessionId, 'new-session');
    expect(results.map((result) => result.data.name), everyElement('测试学生'));
  });

  test('api stores remembered account without password', () async {
    SharedPreferences.setMockInitialValues({
      'auth.password': 'legacy-password',
    });
    final api = ApiClient(httpClient: MockClient((request) async {
      return http.Response('not found', 404);
    }));

    await api.rememberAccount('2024000000');
    final prefs = await SharedPreferences.getInstance();

    expect(prefs.getBool('auth.rememberPassword'), isTrue);
    expect(prefs.getString('auth.account'), '2024000000');
    expect(prefs.getString('auth.password'), isNull);
  });

  test('api stores auto-login credential in secure storage', () async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient(httpClient: MockClient((request) async {
      return http.Response('not found', 404);
    }));

    await api.saveCredentialToken('secure-credential');
    final prefs = await SharedPreferences.getInstance();
    const secureStorage = FlutterSecureStorage();

    expect(prefs.getString('auth.credentialToken'), isNull);
    expect(
      await secureStorage.read(key: 'auth.credentialToken'),
      'secure-credential',
    );
  });

  test('loadSavedCredentials restores school cookies', () async {
    FlutterSecureStorage.setMockInitialValues({
      'auth.jwxtCookies': 'jwxt-cookie',
      'auth.ehallCookies': 'ehall-cookie',
      'auth.ehallAuthToken': 'ehall-token',
    });
    SharedPreferences.setMockInitialValues({'auth.account': '2024000000'});
    debugEnableSchoolDirectForTests = true;
    addTearDown(() => debugEnableSchoolDirectForTests = false);
    final api = ApiClient(httpClient: MockClient((request) async {
      return http.Response('not found', 404);
    }));

    await api.loadSavedCredentials();

    expect(api.jwxtCookies, 'jwxt-cookie');
    expect(api.ehallCookies, 'ehall-cookie');
    expect(api.ehallAuthToken, 'ehall-token');
  });

  test('session cleanup keeps the active session id after local clear',
      () async {
    SharedPreferences.setMockInitialValues({});
    final requestedPaths = <String>[];
    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        requestedPaths.add(request.url.path);
        expect(request.headers['X-Session-Id'], 'active-session');
        return http.Response(jsonEncode({'status': 'ok'}), 200);
      }),
    );
    api.useSession('active-session');
    api.clearCredentials();

    await api.revokeSession('active-session');

    expect(requestedPaths, ['/auth/logout']);
  });

  test('native academic reads prefer cloud API for cache reuse', () async {
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
      expect(request.url.host, 'jwxt.gzus.edu.cn');
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
        expect(request.url.path, '/schedule');
        return http.Response.bytes(
          utf8.encode(jsonEncode([
            {
              'name': '云端缓存课程',
              'weekday': 2,
              'startSection': 3,
              'endSection': 4,
            }
          ])),
          200,
        );
      }),
    )..setJwxtCookies('JSESSIONID=direct');
    await api.rememberAccount('2024000000');

    final result = await api.schedule(year: 2026, term: 2, forceRefresh: true);

    expect(directCalled, isFalse);
    expect(apiCalled, isTrue);
    expect(result.data.items.single.name, '云端缓存课程');
    expect(result.data.items.single.startSection, 3);
    expect(result.data.items.single.endSection, 4);
  });

  test(
      'native academic reads fall back to direct school endpoint when API fails',
      () async {
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
      expect(request.url.host, 'jwxt.gzus.edu.cn');
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
        expect(request.url.path, '/schedule');
        return http.Response('API unavailable', 502);
      }),
    )..setJwxtCookies('JSESSIONID=direct');
    await api.rememberAccount('2024000000');

    final result = await api.schedule(year: 2026, term: 2, forceRefresh: true);

    expect(directCalled, isTrue);
    expect(apiCalled, isTrue);
    expect(result.data.items.single.name, '直连课程');
  });

  testWidgets('renders login page', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const OneGzusApp());
    await tester.pumpAndSettle();

    expect(find.text('软帮手'), findsNWidgets(2));
    expect(find.text('一键登录'), findsNothing);
    expect(find.text('办事大厅一键登录'), findsNothing);
    expect(find.text('账号密码登录'), findsOneWidget);
  });

  testWidgets('account password login requires an account', (tester) async {
    SharedPreferences.setMockInitialValues({'auth.agreedToTerms': true});

    await tester.pumpWidget(const OneGzusApp());
    await tester.pumpAndSettle();

    final loginButton = find.widgetWithText(FilledButton, '账号密码登录');
    await tester.ensureVisible(loginButton);
    await tester.tap(loginButton);
    await tester.pump();

    expect(find.text('请输入学号'), findsNWidgets(2));
  });

  testWidgets('login page fits mobile viewport', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const OneGzusApp());
    await tester.pumpAndSettle();

    expect(find.text('软帮手'), findsNWidgets(2));
    expect(find.text('账号密码登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('login page uses split layout on desktop', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(
          api: _loginPageApi(),
          onLoggedIn: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('login-split-layout')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('login-carousel-fallback')), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('login page keeps password controls available on mobile',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(
          api: _loginPageApi(),
          onLoggedIn: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('login-stacked-layout')), findsOneWidget);
    expect(find.byKey(const ValueKey('login-carousel')), findsOneWidget);
    final passwordField = find.byType(TextField).at(1);
    expect(tester.widget<TextField>(passwordField).obscureText, isTrue);

    await tester.tap(find.byKey(const ValueKey('login-password-visibility')));
    await tester.pump();
    expect(tester.widget<TextField>(passwordField).obscureText, isFalse);
  });

  testWidgets('login carousel automatically advances and supports swiping',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(
          api: _loginPageApiWithSlides(),
          onLoggedIn: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第一张'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('login-carousel')),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('第二张'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('第一张'), findsOneWidget);
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
    expect(find.text('今日时间线'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-card-下一节课')), findsOneWidget);
  });

  testWidgets(
      'mobile dashboard content spans behind the bottom navigation on every tab',
      (tester) async {
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
    await _pumpDashboard(tester, const Size(390, 844));

    for (final label in ['首页', '信息', '应用', '课表', '更多']) {
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();

      final contentTop = tester
          .getTopLeft(find.byKey(const ValueKey('mobile-dashboard-content')))
          .dy;
      expect(contentTop, greaterThanOrEqualTo(32),
          reason: '$label 内容应位于状态栏安全区下方');
      final contentBottom = tester
          .getBottomLeft(find.byKey(const ValueKey('mobile-dashboard-content')))
          .dy;
      expect(contentBottom, 844, reason: '$label 内容不应为底栏预留遮挡区域');
      expect(tester.takeException(), isNull);
    }
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

  testWidgets('AsyncPanel keeps old data during silent refresh',
      (tester) async {
    final first = Completer<String>();
    final second = Completer<String>();
    final failing = Completer<String>();

    Widget build(Future<String> future) => MaterialApp(
          home: Scaffold(
            body: AsyncPanel<String>(
              future: future,
              builder: (data) => Text('data:$data'),
            ),
          ),
        );

    await tester.pumpWidget(build(first.future));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    first.complete('旧数据');
    await tester.pumpAndSettle();
    expect(find.text('data:旧数据'), findsOneWidget);

    // future 更换但新数据未就绪：继续显示旧数据，不闪加载动画
    await tester.pumpWidget(build(second.future));
    await tester.pump();
    expect(find.text('data:旧数据'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    second.complete('新数据');
    await tester.pumpAndSettle();
    expect(find.text('data:新数据'), findsOneWidget);

    // 静默刷新失败：保留旧数据，不显示错误面板
    await tester.pumpWidget(build(failing.future));
    failing.completeError(ApiException('网络错误'));
    await tester.pumpAndSettle();
    expect(find.text('data:新数据'), findsOneWidget);
    expect(find.text('网络错误'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切走再切回不重新请求、不闪加载动画', (tester) async {
    final requests = <String>[];
    final api = _mockApi(onRequest: requests.add);
    await _pumpDashboard(tester, const Size(390, 844), api: api);

    // 首次进入课表页（无论是否命中 dashboard 种子缓存，记录当时的请求数）
    await tester.tap(find.text('课表').last);
    await tester.pumpAndSettle();
    final requestsAfterFirstScheduleVisit = requests.length;

    // 切回首页：页面保活 + 静默刷新命中缓存，不闪加载动画
    await tester.tap(find.text('首页').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '切回首页不应闪加载动画');
    await tester.pumpAndSettle();
    expect(find.text('下一节课'), findsOneWidget);

    // 再次进入课表页：State 保活，不重新构建、不重新请求
    await tester.tap(find.text('课表').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '再次进入课表页不应闪加载动画');
    await tester.pumpAndSettle();
    expect(requests.length, requestsAfterFirstScheduleVisit,
        reason: '已访问过的页面切换不应重新请求');

    // 再次切回首页：同样不重新请求、不闪加载动画
    await tester.tap(find.text('首页').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '再次切回首页不应闪加载动画');
    await tester.pumpAndSettle();
    expect(requests.length, requestsAfterFirstScheduleVisit,
        reason: '已访问过的首页切换不应重新请求');
    expect(find.text('下一节课'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS 主界面从左边缘右滑按 Tab 访问历史返回且不保留离开页面', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _pumpDashboard(tester, const Size(390, 844));
      await tester.tap(find.text('课表').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('更多').last);
      await tester.pumpAndSettle();

      await _swipeFromLeftEdge(tester);
      await tester.pump();
      final morePageSlot = tester.widget<Offstage>(
        find.byKey(const ValueKey('page-slot-more')),
      );
      expect(morePageSlot.offstage, isTrue);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('schedule-floating-menu')),
        findsOneWidget,
      );

      await _swipeFromLeftEdge(tester);
      await tester.pumpAndSettle();
      expect(find.text('下一节课'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
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
    final now = DateTime.now();
    final period = academicPeriodOf(now);
    final startText = dateText(mondayOf(now));
    SharedPreferences.setMockInitialValues({
      'schedule.${period.$1}.${period.$2}.firstWeekStart': startText,
      'schedule.autoWeek': true,
      // 旧版本保存的周视图应自动迁移到新的周课表日历视图。
      'schedule.viewMode': 'week',
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

    expect(
        find.byKey(const ValueKey('schedule-floating-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-view-mode')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('schedule-floating-menu')));
    await tester.pumpAndSettle();

    expect(find.text('第1周'), findsNWidgets(2));
    expect(find.text('首周'), findsNothing);
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('schedule-menu-calendar')),
          )
          .selected,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('schedule-menu-tools')));
    await tester.pumpAndSettle();

    expect(find.text('课表工具'), findsWidgets);
    expect(find.text(startText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('schedule switches between today calendar and all views',
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

    expect(
        find.byKey(const ValueKey('schedule-floating-menu')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('schedule-floating-menu')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('schedule-menu-calendar')));
    await tester.pumpAndSettle();
    expect(find.text('09:00'), findsWidgets);
    expect(find.text('周一'), findsWidgets);
    expect(
        find.byKey(const ValueKey('schedule-calendar-view')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('schedule-floating-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-menu-all')));
    await tester.pumpAndSettle();
    expect(find.text('移动应用开发'), findsWidgets);
    expect(find.text('1条'), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('schedule-floating-menu')),
      const Offset(180, -120),
    );
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('schedule.viewMode'), 'all');
    expect(prefs.getDouble('schedule.floatingMenu.x'), isNotNull);
    expect(prefs.getDouble('schedule.floatingMenu.y'), isNotNull);
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
  ApiClient? api,
}) async {
  LiveActivityController.instance.resetForTest();
  debugHideEcardForTests = hideEcard;
  debugDisableEcardDirectForTests = true;
  addTearDown(() => debugHideEcardForTests = false);
  addTearDown(() => debugDisableEcardDirectForTests = false);
  addTearDown(LiveActivityController.instance.resetForTest);
  const homeWidgetChannel = MethodChannel('cn.gzus.pro/home_widgets');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(homeWidgetChannel, (call) async => null);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(homeWidgetChannel, null);
  });
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScaleFactor;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: DashboardShell(
          api: api ?? _mockApi(scheduleItems: scheduleItems),
          studentName: '测试学生',
          themeMode: ThemeMode.light,
          onThemeChanged: (_) {},
          onLogout: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _swipeFromLeftEdge(WidgetTester tester) async {
  final gesture = await tester.startGesture(const Offset(10, 360));
  await gesture.moveBy(const Offset(100, 0));
  await gesture.up();
}

ApiClient _loginPageApi() {
  return ApiClient(
    baseUrl: 'https://api.example.test',
    httpClient: MockClient((request) async {
      if (request.url.path == '/content/login-slides') {
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('not found', 404);
    }),
  );
}

ApiClient _loginPageApiWithSlides() {
  return ApiClient(
    baseUrl: 'https://api.example.test',
    httpClient: MockClient((request) async {
      if (request.url.path == '/content/login-slides') {
        return http.Response(
          jsonEncode([
            {
              'id': 1,
              'title': '第一张',
              'description': '第一张文案',
              'imageUrl': '/content/login-slides/1/image',
            },
            {
              'id': 2,
              'title': '第二张',
              'description': '第二张文案',
              'imageUrl': '/content/login-slides/2/image',
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path.startsWith('/content/login-slides/')) {
        return http.Response.bytes(const [0], 200,
            headers: {'content-type': 'image/png'});
      }
      return http.Response('not found', 404);
    }),
  );
}

ApiClient _mockApi({
  List<Map<String, Object?>>? scheduleItems,
  void Function(String path)? onRequest,
}) {
  final api = ApiClient(
    baseUrl: 'https://api.example.test',
    httpClient: MockClient((request) async {
      onRequest?.call('${request.url.path}?${request.url.query}');
      final path = request.url.path;
      Object body;
      switch (path) {
        case '/dashboard':
          final schedule = scheduleItems ??
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
          body = {
            'status': 'ok',
            'generatedAt': '2026-06-29T00:00:00Z',
            'modules': {
              'me': {
                'status': 'ok',
                'data': {
                  'studentId': '2024000000',
                  'name': '测试学生',
                  'college': '软件学院',
                  'major': '软件工程',
                  'className': '软件2401',
                  'grade': '2024',
                },
              },
              'schedule': {'status': 'ok', 'data': schedule},
              'attendance': {
                'status': 'ok',
                'data': {
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
                },
              },
              'exams': {
                'status': 'ok',
                'data': [
                  {
                    'courseName': '移动应用开发',
                    'time': '2026-06-20 09:00',
                    'location': 'A101',
                    'seat': '12',
                    'type': '期末',
                  }
                ],
              },
              'grades': {
                'status': 'ok',
                'data': [
                  {
                    'courseName': '移动应用开发',
                    'score': '92',
                    'credit': '3',
                    'gradePoint': '4.0',
                  }
                ],
              },
              'credits': {
                'status': 'ok',
                'data': [
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
                ],
              },
              'notices': {
                'status': 'ok',
                'data': [
                  {
                    'category': '通知',
                    'title': '期末考试安排',
                    'summary': '请及时查看考试安排',
                    'date': '2026-06-03',
                  }
                ],
              },
              'ecard': {
                'status': 'empty',
                'data': {'status': 'not_bound'}
              },
              'apps': {'status': 'empty', 'data': []},
              'progress': {
                'status': 'empty',
                'data': {'items': []}
              },
              'weather': {'status': 'empty', 'data': null},
            },
          };
          break;
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
            'status': 'ok',
            'cachedAt': '2026-06-03T08:00:00+08:00',
            'items': [
              {
                'title': '剩余 100 度',
                'amount': '2.5 度',
                'time': '2026-06-03',
                'date': '2026-06-03',
                'usage': 2.5,
                'unit': '度',
              }
            ],
          };
          break;
        case '/ecard/consumption/overview':
          body = {
            'status': 'ok',
            'months': [
              {
                'month': '2026-06',
                'recordedDays': 3,
                'totalUsage': 8.5,
                'averageDailyUsage': 2.83,
                'peakDate': '2026-06-03',
                'peakUsage': 4.0,
                'unit': '度',
                'cachedAt': '2026-06-03T08:00:00+08:00',
              }
            ],
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
  int balanceCalls = 0;

  @override
  Future<Map<String, dynamic>?> getBalance(String roomId,
      {String? studentId}) async {
    balanceCalls++;
    return balance;
  }
}

class _DeferredEcardDirectClient extends EcardDirectClient {
  final _balance = Completer<Map<String, dynamic>?>();
  int balanceCalls = 0;

  @override
  Future<Map<String, dynamic>?> getBalance(String roomId, {String? studentId}) {
    balanceCalls++;
    return _balance.future;
  }

  void complete(Map<String, dynamic> value) {
    _balance.complete(value);
  }
}
