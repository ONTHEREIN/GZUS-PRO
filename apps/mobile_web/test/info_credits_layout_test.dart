import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/pages/credits/credits_page.dart';
import 'package:gzus_pro_mobile_web/pages/info/info_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('个人信息在 320 与 390 宽度下保持双栏和整行字段', (tester) async {
    for (final width in [320.0, 390.0]) {
      await _pumpPage(
        tester,
        size: Size(width, 844),
        child: InfoPage(api: _infoApi(includeOptionalFields: true)),
      );

      final college =
          tester.getRect(find.byKey(const Key('info-tile-college')));
      final major = tester.getRect(find.byKey(const Key('info-tile-major')));
      final idNumber =
          tester.getRect(find.byKey(const Key('info-full-id-number')));

      expect(college.top, major.top);
      expect(major.left, greaterThan(college.left));
      expect((college.width - major.width).abs(), lessThan(0.1));
      expect(idNumber.width, greaterThan(college.width * 1.9));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('个人信息在缺少可选数据时收缩对应分组', (tester) async {
    await _pumpPage(
      tester,
      size: const Size(390, 844),
      child: InfoPage(api: _infoApi(includeOptionalFields: false)),
    );

    expect(find.byKey(const Key('info-section-academic')), findsOneWidget);
    expect(find.byKey(const Key('info-section-personal')), findsNothing);
    expect(find.byKey(const Key('info-section-contact')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('学分手机布局突出总进度并展示所有分类', (tester) async {
    await _pumpPage(
      tester,
      size: const Size(390, 844),
      child: CreditsPage(api: _creditsApi()),
    );

    final totalProgress = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('credit-total-progress-0')),
    );

    expect(totalProgress.value, 0.4375);
    expect(find.byKey(const Key('credit-category-required-0')), findsOneWidget);
    expect(find.byKey(const Key('credit-category-elective-0')), findsOneWidget);
    expect(find.byKey(const Key('credit-category-other-0')), findsOneWidget);
    expect(find.byKey(const Key('credit-primary-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('学分宽屏布局拆分概览与分类明细，并支持零应修学分', (tester) async {
    await _pumpPage(
      tester,
      size: const Size(900, 844),
      child: CreditsPage(api: _creditsApi()),
    );

    final totalProgress = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('credit-total-progress-1')),
    );

    expect(find.byKey(const Key('credit-primary-0')), findsOneWidget);
    expect(find.byKey(const Key('credit-details-0')), findsOneWidget);
    expect(find.byKey(const Key('credit-category-other-1')), findsOneWidget);
    expect(totalProgress.value, 0);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required Size size,
  required Widget child,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pumpAndSettle();
}

ApiClient _infoApi({required bool includeOptionalFields}) {
  return ApiClient(
    baseUrl: 'https://api.example.test',
    httpClient: MockClient((request) async {
      if (request.url.path != '/me') return http.Response('not found', 404);
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'studentId': '2024000000',
          'name': '测试学生',
          'college': '软件学院',
          'major': '软件工程',
          'className': '软件2401',
          'grade': '2024',
          if (includeOptionalFields) ...{
            'gender': '女',
            'idNumber': '440101200001011234',
            'birthDate': '2000-01-01',
            'ethnicity': '汉族',
            'politicalStatus': '共青团员',
            'phone': '13800138000',
            'email': 'student@example.test',
            'address': '贵州省贵阳市花溪区测试路 1 号',
          },
        })),
        200,
      );
    }),
  );
}

ApiClient _creditsApi() {
  return ApiClient(
    baseUrl: 'https://api.example.test',
    httpClient: MockClient((request) async {
      if (request.url.path != '/credits') {
        return http.Response('not found', 404);
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode([
          {
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
          },
          {
            'name': '测试学生',
            'major': '第二培养方案',
            'requiredExpected': 0,
            'electiveExpected': 0,
            'otherExpected': 0,
            'requiredEarned': 0,
            'electiveEarned': 0,
            'otherEarned': 0,
          },
        ])),
        200,
      );
    }),
  );
}
