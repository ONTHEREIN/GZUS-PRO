import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

typedef OnNotificationTap = void Function(Map<String, dynamic> extras);

class LocalNotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static OnNotificationTap? _onTap;

  static Future<void> init({OnNotificationTap? onTap}) async {
    _onTap = onTap;
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );
    if (Platform.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.requestNotificationsPermission();
    }
  }

  static Future<bool> requestWebNotificationPermission() async => true;

  static void _onNotificationResponse(NotificationResponse response) {
    if (_onTap == null) return;
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    try {
      final extras = jsonDecode(payload) as Map<String, dynamic>;
      _onTap!(extras);
    } catch (_) {}
  }

  static Future<void> show({
    required String title,
    required String body,
    Map<String, dynamic>? extras,
    int id = 0,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'gzus_pro_notifications',
      '软帮手通知',
      channelDescription: '教务系统通知推送',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details =
        NotificationDetails(android: androidDetails, iOS: iosDetails);
    final payload = extras != null ? jsonEncode(extras) : null;
    await _plugin.show(id, title, body, details, payload: payload);
  }
}
