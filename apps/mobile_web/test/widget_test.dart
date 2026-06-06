import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/main.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/reminder_service.dart';
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
        'studentId': '2540232101',
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
    expect(result.source.displayText, '需重新登录才能更新');
  });

  testWidgets('renders login page', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const GzusProApp());
    await tester.pumpAndSettle();

    expect(find.text('GZUS-PRO'), findsOneWidget);
    expect(find.text('推荐使用办事大厅统一登录'), findsOneWidget);
    expect(find.text('办事大厅统一登录'), findsOneWidget);
    expect(find.text('教务系统登录'), findsWidgets);
  });

  testWidgets('mobile sso is enabled without account', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const GzusProApp());
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

    await tester.pumpWidget(const GzusProApp());
    await tester.pumpAndSettle();

    expect(find.text('GZUS-PRO'), findsOneWidget);
    expect(find.text('办事大厅统一登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dashboard uses bottom tabs on mobile', (tester) async {
    await _pumpDashboard(tester, const Size(390, 844));

    expect(find.byKey(const ValueKey('mobile-bottom-nav')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-sidebar')), findsNothing);
    expect(find.byKey(const ValueKey('dashboard-header-tools')), findsNothing);
    expect(find.byKey(const ValueKey('mobile-header-toggle')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mobile-header-toggle')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('dashboard-header-tools')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mobile-header-toggle')));
    await tester.pumpAndSettle();
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
    expect(find.text('业务进度'), findsWidgets);
  });

  testWidgets('dashboard uses sidebar on desktop', (tester) async {
    await _pumpDashboard(tester, const Size(1180, 820));

    expect(find.byKey(const ValueKey('app-sidebar')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-bottom-nav')), findsNothing);
  });

  testWidgets('mobile dashboard tabs fit every page', (tester) async {
    await _pumpDashboard(tester, const Size(390, 844));

    for (final label in ['首页', '应用', '课表', '请假', '更多']) {
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$label should fit');
    }
  });

  testWidgets('home customization hides a module', (tester) async {
    await _pumpDashboard(tester, const Size(390, 844));

    await tester.tap(find.text('自定义'));
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
          darkMode: false,
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
    await tester.tap(find.text('校本部 A2 A2-932'));
    await tester.pumpAndSettle();

    expect(find.text('生活缴费'), findsWidgets);
    expect(find.text('电费'), findsOneWidget);
    expect(find.text('9 度'), findsOneWidget);
    expect(find.text('冷水'), findsOneWidget);
    expect(find.text('热水'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ecard page shows limited consumption state', (tester) async {
    await _pumpDashboard(tester, const Size(1180, 820));

    await tester.tap(find.text('生活缴费').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('校本部 A2 A2-932'));
    await tester.pumpAndSettle();

    expect(find.text('电费消费记录'), findsOneWidget);
    expect(find.text('一卡通流水接口受限'), findsOneWidget);
  });

  testWidgets('ecard page fits mobile width', (tester) async {
    await _pumpDashboard(tester, const Size(390, 844));

    await tester.tap(find.text('更多').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('缴费').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('校本部 A2 A2-932'));
    await tester.pumpAndSettle();

    expect(find.text('每日提醒'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpDashboard(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: DashboardShell(
        api: _mockApi(),
        studentName: '测试学生',
        darkMode: false,
        onThemeChanged: (_) {},
        onLogout: () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ApiClient _mockApi() {
  return ApiClient(
    httpClient: MockClient((request) async {
      final path = request.url.path;
      Object body;
      switch (path) {
        case '/me':
          body = {
            'studentId': '2540232101',
            'name': '测试学生',
            'college': '软件学院',
            'major': '软件工程',
            'className': '软件2401',
            'grade': '2024',
          };
          break;
        case '/schedule':
          body = [
            {
              'name': '移动应用开发',
              'teacher': '张老师',
              'classroom': 'A101',
              'weekday': 1,
              'startSection': 1,
              'endSection': 2,
              'weeks': '1-16',
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
              'studentId': '2540232101',
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
}
