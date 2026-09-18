import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/first_run_onboarding_page.dart';
import 'package:gzus_pro_mobile_web/gzus_design.dart';
import 'package:gzus_pro_mobile_web/onboarding_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('首次引导会从保存步骤恢复并保存下一步', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final api = ApiClient(
        baseUrl: 'https://api.example.test',
        httpClient: MockClient(
          (request) async => http.Response(jsonEncode(<String, Object>{}), 200),
        ),
      );
      final steps = <int>[];

      await tester.pumpWidget(
        MaterialApp(
          theme: gzusTheme(Brightness.light),
          home: FirstRunOnboardingPage(
            api: api,
            studentName: '测试同学',
            initialStep: 3,
            onStepChanged: steps.add,
            onComplete: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('软帮手能为你做什么？'), findsOneWidget);
      await tester.tap(find.text('继续设置提醒'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(steps, [4]);
      expect(
        prefs.getInt(onboardingPreferenceKey(api.namespace, 'firstRunStep')),
        4,
      );
      expect(find.text('优化推送体验'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
