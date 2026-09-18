import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/live_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cn.gzus.pro/live_update');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('Android 实况通知资格可以区分三种状态', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    var nativeValue = 'available';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getPromotedNotificationStatus');
      return nativeValue;
    });

    expect(
      await LiveUpdateService.checkPromotedNotificationStatus(),
      AndroidPromotedNotificationStatus.available,
    );
    nativeValue = 'authorization_required';
    expect(
      await LiveUpdateService.checkPromotedNotificationStatus(),
      AndroidPromotedNotificationStatus.authorizationRequired,
    );
    nativeValue = 'unsupported';
    expect(
      await LiveUpdateService.checkPromotedNotificationStatus(),
      AndroidPromotedNotificationStatus.unsupported,
    );
  });

  test('未授权时可以通过原生通道打开 Android 通知设置', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    var opened = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'openPromotedNotificationSettings');
      opened = true;
      return true;
    });

    expect(await LiveUpdateService.openPromotedNotificationSettings(), isTrue);
    expect(opened, isTrue);
  });

  test('iOS 不会调用 Android 实况通知通道', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var called = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      called = true;
      return 'available';
    });

    expect(
      await LiveUpdateService.checkPromotedNotificationStatus(),
      AndroidPromotedNotificationStatus.unsupported,
    );
    expect(await LiveUpdateService.openPromotedNotificationSettings(), isFalse);
    expect(called, isFalse);
  });
}
