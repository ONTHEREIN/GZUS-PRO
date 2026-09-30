import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/local_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('提醒检查初始化后仍能接收通知点击并跳转', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var initializations = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'initialize');
      initializations++;
      return true;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    final taps = <Map<String, dynamic>>[];
    await LocalNotificationService.init(onTap: taps.add);
    await LocalNotificationService.ensureInitialized();

    final delivered = Completer<void>();
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(
        'didReceiveNotificationResponse',
        {
          'notificationId': 42,
          'notificationResponseType': 0,
          'payload': jsonEncode({'targetTab': 'schedule', 'id': 'course:42'}),
        },
      )),
      (_) => delivered.complete(),
    );
    await delivered.future;

    expect(initializations, 1);
    expect(taps, [
      {'targetTab': 'schedule', 'id': 'course:42'},
    ]);
  });
}
