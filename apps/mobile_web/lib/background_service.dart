import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BackgroundService {
  static const _channel = MethodChannel('cn.gzus.pro/background_service');

  static Future<void> enableForegroundService({
    String? apiBaseUrl,
    String? sessionId,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('startForegroundService', {
        if (apiBaseUrl != null) 'apiBaseUrl': apiBaseUrl,
        if (sessionId != null) 'sessionId': sessionId,
      });
    } on PlatformException {
      // Native bridge is unavailable on unsupported Android builds.
    }
  }

  static Future<void> disableForegroundService() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('stopForegroundService');
    } on PlatformException {
      // Native bridge is unavailable on unsupported Android builds.
    }
  }

  static Future<void> setHideFromRecents(bool hide) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('setHideFromRecents', {'hide': hide});
    } on PlatformException {
      // Native bridge is unavailable on unsupported Android builds.
    }
  }

  static Future<void> updateCourseReminders({
    required String coursesJson,
    int beforeStartMinutes = 10,
    int beforeEndMinutes = 5,
    String firstWeekStart = '',
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('updateCourseReminders', {
        'coursesJson': coursesJson,
        'beforeStartMinutes': beforeStartMinutes,
        'beforeEndMinutes': beforeEndMinutes,
        'firstWeekStart': firstWeekStart,
      });
    } on PlatformException {}
  }

  static Future<void> setAppForeground(bool foreground) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('setAppForeground', {'foreground': foreground});
    } on PlatformException {
      // Native bridge is unavailable on unsupported Android builds.
    }
  }
}
