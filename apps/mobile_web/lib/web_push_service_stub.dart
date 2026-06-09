import 'web_push_service.dart';

class WebPushServiceStub implements WebPushService {
  @override
  Future<void> init({OnPushClick? onTap}) async {}

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<bool> isSubscribed() async => false;

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> subscribe(
    String publicKey, {
    required String apiBaseUrl,
    required String sessionId,
  }) async {}

  @override
  Future<void> unsubscribe({
    required String apiBaseUrl,
    required String sessionId,
  }) async {}

  @override
  Future<void> clearCache() async {}

}

WebPushService createWebPushService() => WebPushServiceStub();
