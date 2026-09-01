import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/pages/attendance/attendance_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('点击课程卡加载明细并按状态筛选', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = ApiClient(
      baseUrl: 'https://api.example.test',
      httpClient: MockClient((request) async {
        switch (request.url.path) {
          case '/attendance':
            return _jsonResponse(
              body: {
                'status': 'ok',
                'items': [
                  {
                    'courseId': 'course-1',
                    'courseName': '移动应用开发',
                    'normal': 1,
                    'absent': 1,
                    'total': 2,
                  },
                ],
              },
              statusCode: 200,
            );
          case '/attendance/details':
            return _jsonResponse(
              body: {
                'items': [
                  {
                    'status': 'normal',
                    'statusLabel': '正常',
                    'courseName': '移动应用开发',
                    'classDate': '2026-06-03',
                    'teacher': '正常老师',
                  },
                  {
                    'status': 'absent',
                    'statusLabel': '旷课',
                    'courseName': '移动应用开发',
                    'classDate': '2026-06-02',
                    'teacher': '旷课老师',
                  },
                ],
              },
              statusCode: 200,
            );
          default:
            return _jsonResponse(
              body: {'detail': 'not found'},
              statusCode: 404,
            );
        }
      }),
    );
    api.useSession('session-1');

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: AttendancePage(api: api, year: 2025, term: 1),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey('attendance-detail-toggle-course-1')));
    await tester.pumpAndSettle();

    expect(find.text('显示 2 / 2 条点名记录'), findsOneWidget);
    expect(find.textContaining('正常老师'), findsOneWidget);
    expect(find.textContaining('旷课老师'), findsOneWidget);

    final absentFilter =
        find.byKey(const ValueKey('attendance-detail-status-absent'));
    await tester.tap(absentFilter);
    await tester.pumpAndSettle();

    expect(find.text('显示 1 / 2 条点名记录'), findsOneWidget);
    expect(find.textContaining('旷课老师'), findsOneWidget);
    expect(find.textContaining('正常老师'), findsNothing);
  });
}

http.Response _jsonResponse({
  required Map<String, dynamic> body,
  required int statusCode,
}) =>
    http.Response(
      jsonEncode(body),
      statusCode,
      headers: const {'content-type': 'application/json'},
    );
