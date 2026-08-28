import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/background_guide_page.dart';

void main() {
  const permissionChannel = MethodChannel('cn.gzus.pro/permissions');

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, (call) async {
      if (call.method == 'checkNotificationPermission') return true;
      if (call.method == 'requestNotificationPermission') return true;
      throw PlatformException(code: 'UNIMPLEMENTED');
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
  });

  testWidgets('iOS 引导仅展示通知权限且授权后可完成', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BackgroundGuidePage(
          api: ApiClient(baseUrl: 'https://api.example.test'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('通知权限'), findsOneWidget);
    expect(find.text('自启动权限'), findsNothing);
    expect(find.text('电池优化'), findsNothing);
    expect(find.text('精确闹钟'), findsNothing);

    final completeButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '已完成配置'),
    );
    expect(completeButton.onPressed, isNotNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
