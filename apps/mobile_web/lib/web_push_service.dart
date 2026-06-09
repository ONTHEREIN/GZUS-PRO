import 'web_push_service_stub.dart'
    if (dart.library.html) 'web_push_service_web.dart' as impl;

typedef OnPushClick = void Function(Map<String, dynamic> extras);

abstract class WebPushService {
  static WebPushService? _instance;

  static WebPushService get instance {
    _instance ??= impl.createWebPushService();
    return _instance!;
  }

  static void dispose() {
    _instance = null;
  }

  factory WebPushService() => instance;

  Future<void> init({OnPushClick? onTap});
  
  Future<bool> isSupported();
  
  Future<bool> isSubscribed();

  /// Returns browser notification permission status: 'granted', 'denied', or 'default'.
  /// Does NOT trigger a permission prompt.
  Future<String> getPermissionStatus();
  
  Future<bool> requestPermission();
  
  Future<void> subscribe(
    String publicKey, {
    required String apiBaseUrl,
    required String sessionId,
  });
  
  Future<void> unsubscribe({
    required String apiBaseUrl,
    required String sessionId,
  });
  
  Future<void> clearCache();
}
