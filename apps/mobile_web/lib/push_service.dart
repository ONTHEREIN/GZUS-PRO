import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef OnPushTap = void Function(Map<String, dynamic> extras);

class PushService {
  static const _channel = MethodChannel('cn.gzus.pro/push');
  static String? _registrationId;
  static OnPushTap? _onTap;

  static String? get registrationId => _registrationId;

  static Future<void> init({OnPushTap? onTap}) async {
    _onTap = onTap;
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
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

  static void stop() {
    _registrationId = null;
  }

  static void resume() {}
}
