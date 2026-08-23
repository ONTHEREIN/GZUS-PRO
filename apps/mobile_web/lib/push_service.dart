import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef OnPushTap = void Function(Map<String, dynamic> extras);

class PushService {
  static const _channel = MethodChannel('cn.gzus.pro/push');
  static OnPushTap? _onTap;

  static Future<void> init({OnPushTap? onTap}) async {
    _onTap = onTap;
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _consumeNotificationOpen();
    }
  }

  static void stop() {
    _onTap = null;
  }

  static void resume() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _consumeNotificationOpen();
  }

  static Future<void> _consumeNotificationOpen() async {
    try {
      final opened = await _channel
          .invokeMapMethod<String, dynamic>('consumeNotificationOpen');
      if (opened != null && opened.isNotEmpty) {
        _onTap?.call(Map<String, dynamic>.from(opened));
      }
    } on PlatformException {
      // Native notification-open cache is best effort.
    }
  }
}
