import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api_client.dart';
import 'permission_service.dart';

typedef OnPushTap = void Function(Map<String, dynamic> extras);

const _iosPushEnvironment = String.fromEnvironment(
  'IOS_PUSH_ENVIRONMENT',
  defaultValue: kDebugMode ? 'sandbox' : 'production',
);

class PushService {
  static const _channel = MethodChannel('cn.gzus.pro/push');
  static OnPushTap? _onTap;

  static Future<void> init({
    required ApiClient api,
    OnPushTap? onTap,
  }) async {
    _onTap = onTap;
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }
    await _consumeNotificationOpen();
  }

  static void stop() {
    _onTap = null;
  }

  static void resume() {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }
    _consumeNotificationOpen();
  }

  static Future<void> syncIosPushToken(ApiClient api) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    final granted = await PermissionService.checkNotificationPermission();
    if (!granted) return;
    final deviceToken =
        await _channel.invokeMethod<String>('requestRemotePushToken');
    if (deviceToken == null || deviceToken.isEmpty) {
      throw StateError('iOS 未返回 APNs 设备令牌');
    }
    if (_iosPushEnvironment != 'sandbox' &&
        _iosPushEnvironment != 'production') {
      throw StateError('IOS_PUSH_ENVIRONMENT 必须为 sandbox 或 production');
    }
    await api.registerIosPushToken(
      deviceToken: deviceToken,
      environment: _iosPushEnvironment,
    );
  }

  static Future<void> unregisterIosPushToken(
    ApiClient api,
    String activeSessionId,
  ) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    final deviceToken =
        await _channel.invokeMethod<String>('getRemotePushToken');
    if (deviceToken == null || deviceToken.isEmpty) return;
    await api.unregisterIosPushToken(
      activeSessionId: activeSessionId,
      deviceToken: deviceToken,
      environment: _iosPushEnvironment,
    );
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
