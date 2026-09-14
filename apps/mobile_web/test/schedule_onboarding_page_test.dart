import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/gzus_design.dart';
import 'package:gzus_pro_mobile_web/pages/schedule/schedule_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('首次课表引导可直接配置上下课提醒', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: gzusTheme(Brightness.light),
        home: ScheduleOnboardingPage(
          api: ApiClient(baseUrl: 'https://api.example.test'),
          studentName: '测试同学',
          onComplete: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('上下课提醒'), findsOneWidget);
    expect(find.text('按课表在上课和下课前提醒你'), findsOneWidget);
    expect(find.text('上课前提醒'), findsNothing);

    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.text('上课前提醒'), findsOneWidget);
    expect(find.text('下课前提醒'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
