import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

typedef OnNotificationTap = void Function(Map<String, dynamic> extras);

class ScheduledLocalNotification {
  const ScheduledLocalNotification({
    required this.id,
    required this.scheduledAt,
    required this.title,
    required this.body,
    required this.extras,
  });

  final int id;
  final DateTime scheduledAt;
  final String title;
  final String body;
  final Map<String, dynamic> extras;
}

class LocalNotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static OnNotificationTap? _onTap;
  static bool _timezoneInitialized = false;

  static Future<void> init({OnNotificationTap? onTap}) async {
    _onTap = onTap;
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );
    _ensureTimezone();
    if (Platform.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.requestNotificationsPermission();
    }
  }

  static Future<void> replaceCourseReminders(
    List<ScheduledLocalNotification> reminders,
  ) async {
    await _cancelCourseReminders();
    if (reminders.isEmpty) return;
    _ensureTimezone();
    const androidDetails = AndroidNotificationDetails(
      'gzus_pro_course_reminders',
      '上下课提醒',
      channelDescription: '按课表发送的上下课提醒',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );
    for (final reminder in reminders) {
      final payload = jsonEncode(reminder.extras);
      await _plugin.zonedSchedule(
        id: reminder.id,
        title: reminder.title,
        body: reminder.body,
        scheduledDate: tz.TZDateTime.from(reminder.scheduledAt, tz.local),
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: payload,
      );
    }
  }

  static Future<void> cancelCourseReminders() async {
    await _cancelCourseReminders();
  }

  static Future<void> _cancelCourseReminders() async {
    final pending = await _plugin.pendingNotificationRequests();
    for (final request in pending) {
      final payload = request.payload;
      if (payload == null || !payload.contains('course_reminder')) continue;
      await _plugin.cancel(id: request.id);
    }
  }

  static void _ensureTimezone() {
    if (_timezoneInitialized) return;
    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
    _timezoneInitialized = true;
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
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
  }
}
