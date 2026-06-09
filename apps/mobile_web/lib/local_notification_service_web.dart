// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html';

typedef OnNotificationTap = void Function(Map<String, dynamic> extras);

class LocalNotificationService {
  static Future<void> init({OnNotificationTap? onTap}) async {}

  static Future<bool> requestWebNotificationPermission() async {
    try {
      final permission = Notification.permission;
      if (permission == 'granted') {
        return true;
      }
      final result = await Notification.requestPermission();
      return result == 'granted';
    } catch (_) {
      return false;
    }
  }

  static Future<void> show({
    required String title,
    required String body,
    Map<String, dynamic>? extras,
    int id = 0,
  }) async {
    try {
      if (Notification.permission == 'granted') {
        Notification(
          title,
          body: body,
          tag: id.toString(),
        );
      }
    } catch (_) {}
  }
}
