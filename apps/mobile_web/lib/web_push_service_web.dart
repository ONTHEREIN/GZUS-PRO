import 'dart:async';
import 'dart:convert';

import 'package:js/js.dart';

import 'web_push_service.dart';

@JS()
external void gzusWebPushInit();

@JS()
external bool gzusWebPushIsSupported();

@JS()
external void gzusWebPushIsSubscribed(Function callback);

@JS()
external void gzusWebPushRequestPermission(Function callback);

@JS()
external String gzusWebPushGetPermissionStatus();

@JS()
external void gzusWebPushSubscribe(
  String publicKey,
  String apiBaseUrl,
  String sessionId,
  Function callback,
);

@JS()
external void gzusWebPushUnsubscribe(
  String apiBaseUrl,
  String sessionId,
  Function callback,
);

@JS()
external void gzusWebPushClearCache();

@JS()
external void gzusWebPushSetOnTap(Function callback);

class WebPushServiceImpl implements WebPushService {
  OnPushClick? _onTap;
  final Completer<void> _initCompleter = Completer();

  @override
  Future<void> init({OnPushClick? onTap}) async {
    _onTap = onTap;
    _setupMessageListener();
    _processUrlParams();
    try {
      gzusWebPushInit();
      gzusWebPushSetOnTap((extras) => _handlePushClick(extras));
    } catch (_) {}
    if (!_initCompleter.isCompleted) {
      _initCompleter.complete();
    }
  }

  void _setupMessageListener() {
    // Handled by gzus_pwa.js
  }

  void _processUrlParams() {
    final uri = Uri.base;
    final pushOpen = uri.queryParameters['pushOpen'];
    if (pushOpen != null && pushOpen.isNotEmpty) {
      try {
        final decoded = Uri.decodeComponent(pushOpen);
        final extras = json.decode(decoded) as Map<String, dynamic>;
        Future.microtask(() {
          _onTap?.call(extras);
        });
      } catch (_) {}
    }
  }

  void _handlePushClick(dynamic extras) {
    if (extras is Map) {
      final map = <String, dynamic>{};
      extras.forEach((key, value) {
        map[key.toString()] = value;
      });
      _onTap?.call(map);
    }
  }

  @override
  Future<bool> isSupported() async {
    await _initCompleter.future;
    try {
      return gzusWebPushIsSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isSubscribed() async {
    await _initCompleter.future;
    try {
      return await _callbackBool(gzusWebPushIsSubscribed);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    await _initCompleter.future;
    try {
      return await _callbackBool(gzusWebPushRequestPermission);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> getPermissionStatus() async {
    await _initCompleter.future;
    try {
      return gzusWebPushGetPermissionStatus();
    } catch (_) {
      return 'denied';
    }
  }

  @override
  Future<void> subscribe(
    String publicKey, {
    required String apiBaseUrl,
    required String sessionId,
  }) async {
    await _initCompleter.future;
    final ok = await _callbackBool(
      (callback) => gzusWebPushSubscribe(
        publicKey,
        apiBaseUrl,
        sessionId,
        callback,
      ),
    );
    if (!ok) {
      throw Exception('Failed to subscribe');
    }
  }

  @override
  Future<void> unsubscribe({
    required String apiBaseUrl,
    required String sessionId,
  }) async {
    await _initCompleter.future;
    try {
      await _callbackBool(
        (callback) => gzusWebPushUnsubscribe(
          apiBaseUrl,
          sessionId,
          callback,
        ),
      );
    } catch (_) {}
  }

  @override
  Future<void> clearCache() async {
    await _initCompleter.future;
    try {
      gzusWebPushClearCache();
    } catch (_) {}
  }

}

WebPushService createWebPushService() => WebPushServiceImpl();

Future<bool> _callbackBool(void Function(Function callback) invoke) {
  final completer = Completer<bool>();
  invoke((value) {
    if (!completer.isCompleted) {
      completer.complete(value == true);
    }
  });
  return completer.future.timeout(
    const Duration(seconds: 20),
    onTimeout: () => false,
  );
}
