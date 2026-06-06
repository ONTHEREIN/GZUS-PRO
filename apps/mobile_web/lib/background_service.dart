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
}
