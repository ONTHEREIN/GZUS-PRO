import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/models/schedule_override.dart';
import 'package:gzus_pro_mobile_web/pages/home/home_page.dart';
import 'package:gzus_pro_mobile_web/pages/home/cards/schedule_helpers.dart';
import 'package:gzus_pro_mobile_web/schedule_adjustment_sync.dart';
import 'package:gzus_pro_mobile_web/schedule_utils.dart';
import 'package:gzus_pro_mobile_web/widgets/page_silent_refresh.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object payload) => http.Response.bytes(
      utf8.encode(jsonEncode(payload)),
      200,
      headers: {'content-type': 'application/json'},
    );

Map<String, Object?> _snapshot(
  List<ScheduleCourse> courses,
  List<Map<String, Object?>> grades,
  List<Map<String, Object?>> exams,
) =>
    {
      'status': 'ok',
      'modules': {
        'me': {
          'status': 'ok',
          'data': {'name': '测试学生'}
        },
        'schedule': {
          'status': 'ok',
          'data': courses.map((c) => c.toJson()).toList()
        },
        'grades': {'status': 'ok', 'data': grades},
        'exams': {'status': 'ok', 'data': exams},
        'ecard': {
          'status': 'empty',
          'data': {'status': 'not_bound'}
        },
        'progress': {
          'status': 'empty',
          'data': {'items': <Object>[]}
        },
      },
    };

ApiClient _api(
        String owner, Future<http.Response> Function(http.Request) handler) =>
    ApiClient(
        baseUrl: 'https://api.example.test', httpClient: MockClient(handler))
      ..useSession(owner)
      ..setStudentId(owner);

Future<void> _pumpHome(
  WidgetTester tester,
  ApiClient api,
  int year,
  int term,
  int week,
  DateTime firstWeek,
  GlobalKey<State<HomePage>> key,
) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: HomePage(
      key: key,
      api: api,
      year: year,
      term: term,
      currentWeek: week,
      firstWeekStart: firstWeek,
      studentName: '测试学生',
      studentId: api.studentId,
      onNavigate: (_) {},
    ),
  ));
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cn.gzus.pro/home_widgets');
  final updates = <Map<String, Object?>>[];
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    updates.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'update') {
        updates.add(Map<String, Object?>.from(call.arguments as Map));
      }
      return true;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('周日的下一节课包含跨周移动后的下周一，不受原周次限制', () {
    final source = ScheduleCourse(
        name: '高等数学', weekday: 1, startSection: 1, endSection: 2, weeks: '1');
    final occurrences = expandEffectiveSchedule(
      courses: [source],
      firstWeekStart: DateTime(2026, 9, 7),
      adjustments: [
        ScheduleAdjustmentRecord(
          clientId: 'move',
          year: 2026,
          term: 1,
          sourceDate: DateTime(2026, 9, 7),
          targetDate: DateTime(2026, 9, 14),
          sourceOccurrenceKeys: const [],
          targetConflictKeys: const [],
          conflictMode: 'coexist',
          status: 'active',
          revision: 1,
        )
      ],
    );
    final timed = homeTimedCourses(occurrences);
    final sunday = DateTime(2026, 9, 13, 20);
    expect(todayTimedCourses(timed, sunday), isEmpty);
    expect(nextTimedCourse(timed, sunday)?.start, DateTime(2026, 9, 14, 9));
    expect(timed.single.occurrence.week, 2);
  });

  testWidgets('跨周调课更新下一节课，组件始终显示实际本周而非首页所选周', (tester) async {
    final now = DateTime.now();
    final firstWeek = mondayOf(now);
    final target = firstWeek.add(const Duration(days: 7));
    final source = ScheduleCourse(
        name: '高等数学',
        weekday: 1,
        startSection: 1,
        endSection: 2,
        classroom: 'A101',
        weeks: '1');
    await ScheduleAdjustmentSync.enqueue(
        'A',
        ScheduleAdjustmentRecord(
          clientId: 'pending',
          year: now.year,
          term: 1,
          sourceDate: firstWeek,
          targetDate: target,
          sourceOccurrenceKeys: const [],
          targetConflictKeys: const [],
          conflictMode: 'coexist',
          status: 'active',
          revision: 1,
        ));
    final api = _api(
        'A',
        (request) async => request.url.path == '/dashboard'
            ? _json(_snapshot([source], const [], const []))
            : _json(<Object>[]));
    await _pumpHome(
        tester, api, now.year, 1, 2, firstWeek, GlobalKey<State<HomePage>>());

    final payload = updates.single;
    final weekly = jsonDecode(payload['weeklyCoursesJson'] as String) as List;
    expect(weekly, isEmpty);
    final effective =
        jsonDecode(payload['effectiveCoursesJson'] as String) as List;
    expect(effective.single['week'], 2);
    expect(effective.single['date'], dateText(target));
    final context =
        jsonDecode(payload['widgetScheduleContextJson'] as String) as Map;
    expect(
        (context['pendingAdjustments'] as List).single['clientId'], 'pending');
    expect(
        payload['nextStartEpochMillis'],
        DateTime(target.year, target.month, target.day, 9)
            .millisecondsSinceEpoch);
    final nextCard = find.byKey(const ValueKey('home-card-下一节课'));
    expect(find.descendant(of: nextCard, matching: find.text('高等数学')),
        findsOneWidget);
    expect(
        find.descendant(
            of: nextCard, matching: find.textContaining(dateText(target))),
        findsOneWidget);
  });

  testWidgets('停课不会以原始课程填入首页和前台组件', (tester) async {
    final now = DateTime.now();
    final source = ScheduleCourse(
        name: '停课课程',
        weekday: now.weekday,
        startSection: 1,
        endSection: 2,
        weeks: '1');
    await ScheduleOverrideStore.save('A', now.year, 1, const [
      ScheduleOverride(id: 'hide', matchKey: 'name:停课课程', hidden: true),
    ]);
    final api = _api(
        'A',
        (request) async => request.url.path == '/dashboard'
            ? _json(_snapshot([source], const [], const []))
            : _json(<Object>[]));
    await _pumpHome(tester, api, now.year, 1, 1, mondayOf(now),
        GlobalKey<State<HomePage>>());
    expect(updates.single['nextStatus'], 'none');
    expect(jsonDecode(updates.single['weeklyCoursesJson'] as String), isEmpty);
    expect(jsonDecode(updates.single['todayCoursesJson'] as String), isEmpty);
    expect(find.text('停课课程'), findsNothing);
  });

  testWidgets('账号与学期切换不会读取旧成绩考试缓存或保留旧卡片', (tester) async {
    final now = DateTime.now();
    final examDay = dateText(now.add(const Duration(days: 3)));
    SharedPreferences.setMockInitialValues({
      'local.grades.v2': jsonEncode([
        {'courseName': '无归属旧成绩', 'score': '95'}
      ]),
      'local.exams.v2': jsonEncode([
        {'name': '无归属旧考试', 'date': examDay}
      ]),
    });
    final api = _api('A', (request) async {
      if (request.url.path != '/dashboard') return _json(<Object>[]);
      final ownData = request.headers['X-Session-Id'] == 'A' &&
          request.url.queryParameters['term'] == '1';
      return _json(_snapshot(
        const [],
        ownData
            ? [
                {'courseName': 'A专属成绩', 'score': '90', 'credit': '3'}
              ]
            : const [],
        ownData
            ? [
                {'name': 'A专属考试', 'date': examDay, 'time': '09:00-10:00'}
              ]
            : const [],
      ));
    });
    final key = GlobalKey<State<HomePage>>();
    await _pumpHome(tester, api, now.year, 1, 1, mondayOf(now), key);
    expect(updates.last['gradeCount'], '1');
    expect(updates.last['examCount'], '1');

    api.useSession('B');
    api.setStudentId('B');
    await _pumpHome(tester, api, now.year, 1, 1, mondayOf(now), key);
    expect(updates.last['gradeCount'], '0');
    expect(updates.last['examCount'], '0');
    expect(find.text('A专属成绩'), findsNothing);
    expect(find.text('A专属考试'), findsNothing);
    expect(find.text('无归属旧成绩'), findsNothing);
    expect(find.text('无归属旧考试'), findsNothing);

    api.useSession('A');
    api.setStudentId('A');
    await _pumpHome(tester, api, now.year, 2, 1, mondayOf(now), key);
    expect(updates.last['gradeCount'], '0');
    expect(updates.last['examCount'], '0');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('local.grades.A.${now.year}.1'), isTrue);
    expect(prefs.containsKey('local.grades.B.${now.year}.1'), isFalse);
  });

  testWidgets('调课读取失败明确显示错误且不会把原始课表覆盖到组件', (tester) async {
    final now = DateTime.now();
    var failAdjustments = false;
    final api = _api('A', (request) async {
      if (request.url.path == '/dashboard') {
        return _json(_snapshot([
          ScheduleCourse(
              name: '课表课程',
              weekday: now.weekday,
              startSection: 1,
              endSection: 2,
              weeks: '1')
        ], const [], const []));
      }
      return failAdjustments
          ? http.Response('upstream unavailable', 503)
          : _json(<Object>[]);
    });
    final key = GlobalKey<State<HomePage>>();
    await _pumpHome(tester, api, now.year, 1, 1, mondayOf(now), key);
    expect(updates, hasLength(1));
    failAdjustments = true;
    (key.currentState! as PageSilentRefresh<HomePage>).silentRefresh();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(updates, hasLength(1));
    final nextCard = find.byKey(const ValueKey('home-card-下一节课'));
    expect(
        find.descendant(
            of: nextCard,
            matching: find.byKey(const ValueKey('home-module-error'))),
        findsOneWidget);
    expect(find.descendant(of: nextCard, matching: find.text('课表课程')),
        findsNothing);
  });

  testWidgets('旧账号的迟到响应不能覆盖新账号组件或写入新账号缓存', (tester) async {
    final now = DateTime.now();
    final release = Completer<void>();
    final started = Completer<void>();
    final api = _api('A', (request) async {
      if (request.url.path != '/dashboard') return _json(<Object>[]);
      if (request.headers['X-Session-Id'] == 'A') {
        if (!started.isCompleted) started.complete();
        await release.future;
        return _json(_snapshot(const [], [
          {'courseName': '迟到成绩', 'score': '99'}
        ], const []));
      }
      return _json(_snapshot(const [], const [], const []));
    });
    final key = GlobalKey<State<HomePage>>();
    await _pumpHome(tester, api, now.year, 1, 1, mondayOf(now), key);
    await started.future;
    api.useSession('B');
    api.setStudentId('B');
    await _pumpHome(tester, api, now.year, 1, 1, mondayOf(now), key);
    expect(updates.single['widgetSessionId'], 'B');
    release.complete();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(updates, hasLength(1));
    expect(find.text('迟到成绩'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('local.grades.B.${now.year}.1'), isFalse);
    expect(prefs.getString('local.grades.A.${now.year}.1'), contains('迟到成绩'));
  });
}
