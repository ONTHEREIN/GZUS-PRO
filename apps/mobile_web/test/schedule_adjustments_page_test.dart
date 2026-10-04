import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/pages/schedule/schedule_adjustments_page.dart';

void main() {
  testWidgets('浮动入口工作台在窄屏大字体可进入记录并预览撤销', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final row = {
      'clientId': 'batch-ui',
      'year': 2026,
      'term': 1,
      'sourceDate': '2026-09-07',
      'targetDate': '2026-09-15',
      'sourceOccurrenceKeys': <String>[],
      'targetConflictKeys': <String>[],
      'conflictMode': 'swap',
      'status': 'active',
      'revision': 1,
      'moves': [
        {
          'sourceDate': '2026-09-07',
          'targetDate': '2026-09-15',
          'sourceStart': 2,
          'sourceEnd': 2,
          'targetStart': 1
        }
      ]
    };
    final api = ApiClient(
        baseUrl: 'http://localhost',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/restore-preview')) {
            return http.Response(
                jsonEncode({
                  'fingerprint': 'a' * 64,
                  'blockers': <String>[],
                  'before': <Object>[],
                  'after': <Object>[]
                }),
                200);
          }
          if (request.url.path.endsWith('/restore')) {
            return http.Response(
                jsonEncode({...row, 'status': 'restored', 'revision': 2}), 200);
          }
          if (request.url.path.endsWith('/effective')) {
            return http.Response('[]', 200);
          }
          if (request.url.path.endsWith('/v3')) {
            return http.Response(jsonEncode([row]), 200);
          }
          throw StateError('非预期接口：${request.url}');
        }));
    String? restoredId;
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(
                size: Size(320, 568), textScaler: TextScaler.linear(1.5)),
            child: ScheduleAdjustmentsPage(
                api: api,
                year: 2026,
                term: 1,
                firstWeekStart: DateTime(2026, 9, 7),
                courses: const [],
                overrides: const [],
                records: [ScheduleAdjustmentRecord.fromJson(row)],
                currentWeek: 1,
                presetCourse: null,
                presetOccurrenceKey: null,
                onSave: (record) async => [record],
                onRestore: (id) async {
                  restoredId = id;
                  return [
                    ScheduleAdjustmentRecord.fromJson(
                        {...row, 'status': 'restored', 'revision': 2})
                  ];
                }))));
    await tester.pumpAndSettle();
    final history = find.byKey(const ValueKey('adjustment-entry-history'));
    await tester.ensureVisible(history);
    await tester.tap(history);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('adjustment-record-batch-ui')));
    await tester.pumpAndSettle();
    final undo = find.byKey(const ValueKey('adjustment-undo-batch-ui'));
    await tester.ensureVisible(undo);
    await tester.tap(undo);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('adjustment-primary')));
    await tester.pumpAndSettle();
    expect(restoredId, 'batch-ui');
    expect(tester.takeException(), isNull);
  });
  testWidgets('跨周选课保留实例，清空范围后可重新选择并恢复草稿', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final courses = [
      for (final entry in [('math-1', '数学', 1), ('english-3', '英语', 3)])
        {
          'itemKey': entry.$1,
          'groupId': entry.$2,
          'name': entry.$2,
          'teacher': '老师',
          'classroom': '101',
          'weekday': 1,
          'startSection': 1,
          'endSection': 2,
          'week': entry.$3,
          'date': entry.$3 == 1 ? '2026-09-07' : '2026-09-21'
        }
    ];
    final api = ApiClient(
        baseUrl: 'http://localhost',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/effective')) {
            return http.Response.bytes(utf8.encode(jsonEncode(courses)), 200,
                headers: {'content-type': 'application/json; charset=utf-8'});
          }
          if (request.url.path.endsWith('/v3')) return http.Response('[]', 200);
          throw StateError('非预期接口：${request.url}');
        }));
    Widget page() => MaterialApp(
        home: ScheduleAdjustmentsPage(
            api: api,
            year: 2026,
            term: 1,
            firstWeekStart: DateTime(2026, 9, 7),
            courses: const [],
            overrides: const [],
            records: const [],
            currentWeek: 1,
            presetCourse: null,
            presetOccurrenceKey: null,
            onSave: (record) async => [record],
            onRestore: (id) async => []));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('adjustment-course-math-1')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const ValueKey('adjustment-week-next')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('adjustment-course-english-3')));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 门教学安排，共 2 次课程'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('adjustment-primary')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('adjustment-range-mode-数学-weeks')));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const ValueKey('adjustment-scope-数学-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('adjustment-scope-数学-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('adjustment-scope-数学-1')), findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const ValueKey('adjustment-scope-数学-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('adjustment-scope-数学-1')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('已选 2 门教学安排，共 2 次课程'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
