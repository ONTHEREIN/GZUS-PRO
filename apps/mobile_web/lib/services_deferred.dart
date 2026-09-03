import 'dart:async';

import 'api_client.dart';
import 'web_push_service.dart' deferred as web_push_service;
import 'local_notification_service.dart' deferred as local_notification_service;
import 'push_service.dart' deferred as push_service;
import 'persistent_cache.dart' deferred as persistent_cache;
import 'ws_service.dart' deferred as ws_service;
import 'reminder_service.dart' deferred as reminder_service;
import 'update_service.dart' deferred as update_service;
import 'background_service.dart' deferred as background_service;

// Preload-only deferred imports: these libraries are warmed up in
// _loadOptionalServices() so their isolated chunks are downloaded before the
// user first navigates to them. They are referenced solely via loadLibrary(),
// which the analyzer flags as unused — hence the per-line ignore.
// ignore: unused_import
import 'ftp_upload_service.dart' deferred as ftp_upload_service;
// ignore: unused_import
import 'live_activity_service.dart' deferred as live_activity_service;
// ignore: unused_import
import 'live_update_service.dart' deferred as live_update_service;
// ignore: unused_import
import 'location_service.dart' deferred as location_service;
// ignore: unused_import
import 'avatar_open.dart' deferred as avatar_open;
// ignore: unused_import
import 'ics_download.dart' deferred as ics_download;
// ignore: unused_import
import 'leave_attachment.dart' deferred as leave_attachment;
import 'mobile_sso.dart' deferred as mobile_sso;
import 'web_pwa_cache.dart' deferred as web_pwa_cache;

class DeferredServices {
  static final DeferredServices _instance = DeferredServices._internal();

  factory DeferredServices() => _instance;

  DeferredServices._internal();

  bool _initialized = false;
  final Completer<void> _initCompleter = Completer<void>();

  Future<void> ensureInitialized() {
    if (_initialized) return Future.value();
    return _initCompleter.future;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      await _loadOptionalServices();
      _initialized = true;
      _initCompleter.complete();
    } catch (e) {
      _initCompleter.completeError(e);
      rethrow;
    }
  }

  Future<void> _loadOptionalServices() async {
    await Future.wait([
      ftp_upload_service.loadLibrary(),
      live_activity_service.loadLibrary(),
      live_update_service.loadLibrary(),
      location_service.loadLibrary(),
      avatar_open.loadLibrary(),
      ics_download.loadLibrary(),
      leave_attachment.loadLibrary(),
    ]);
  }
}

class LoginRequiredServices {
  static bool _initialized = false;
  static Future<void>? _initializing;
  static String? _apiBaseUrl;
  static String? _sessionId;

  static Future<void> initialize({
    required ApiClient api,
    required String apiBaseUrl,
    required String sessionId,
    void Function(Map<String, dynamic>)? onNotificationTap,
  }) async {
    final sameSession =
        _initialized && _apiBaseUrl == apiBaseUrl && _sessionId == sessionId;
    if (sameSession) return;

    final inFlight = _initializing;
    if (inFlight != null) {
      await inFlight;
      final stillSame =
          _initialized && _apiBaseUrl == apiBaseUrl && _sessionId == sessionId;
      if (stillSame) return;
    }

    final future = Future.wait([
      if (!_initialized) _initWebPushService(api, onNotificationTap),
      if (!_initialized) _initLocalNotificationService(onNotificationTap),
      if (!_initialized) _initPushService(api, onNotificationTap),
      _initLiveActivityService(api),
      _syncIosPushToken(api),
      if (!_initialized) _initPersistentCache(),
      _initWsService(apiBaseUrl, sessionId),
      if (!_initialized) _initReminderService(),
      if (!_initialized) _initUpdateService(),
      _initBackgroundService(apiBaseUrl, sessionId),
    ]).then((_) {});

    _initializing = future;
    try {
      await future;
      _apiBaseUrl = apiBaseUrl;
      _sessionId = sessionId;
      _initialized = true;
    } finally {
      if (_initializing == future) _initializing = null;
    }
  }

  static Future<void> _initWebPushService(
      ApiClient api, void Function(Map<String, dynamic>)? onTap) async {
    try {
      await web_push_service.loadLibrary();
      final service = web_push_service.WebPushService.instance;
      await service.init(onTap: onTap);
      if (await service.getPermissionStatus() != 'granted') return;
      final config = await api.getWebPushConfig();
      final publicKey = config['publicKey'] as String?;
      if (config['enabled'] != true || publicKey == null || publicKey.isEmpty) {
        return;
      }
      await service.subscribe(
        publicKey,
        apiBaseUrl: api.baseUrl,
        sessionId: api.sessionId ?? '',
      );
    } catch (_) {}
  }

  static Future<void> _initLocalNotificationService(
      void Function(Map<String, dynamic>)? onTap) async {
    try {
      await local_notification_service.loadLibrary();
      await local_notification_service.LocalNotificationService.init(
          onTap: onTap);
    } catch (_) {}
  }

  static Future<void> _initPushService(
      ApiClient api, void Function(Map<String, dynamic>)? onTap) async {
    try {
      await push_service.loadLibrary();
      await push_service.PushService.init(api: api, onTap: onTap);
    } catch (_) {}
  }

  static Future<void> _syncIosPushToken(ApiClient api) async {
    try {
      await push_service.loadLibrary();
      await push_service.PushService.syncIosPushToken(api);
    } catch (_) {}
  }

  static Future<void> _initLiveActivityService(ApiClient api) async {
    try {
      await live_activity_service.loadLibrary();
      await live_activity_service.LiveActivityService.initialize(api: api);
    } catch (_) {}
  }

  static Future<void> _initPersistentCache() async {
    try {
      await persistent_cache.loadLibrary();
    } catch (_) {}
  }

  static Future<void> _initWsService(
      String apiBaseUrl, String sessionId) async {
    try {
      await ws_service.loadLibrary();
      ws_service.WsService.configure(
        apiBaseUrl: apiBaseUrl,
        sessionId: sessionId,
      );
      await ws_service.WsService.connect();
    } catch (_) {}
  }

  static Future<void> _initReminderService() async {
    try {
      await reminder_service.loadLibrary();
    } catch (_) {}
  }

  static Future<void> _initUpdateService() async {
    try {
      await update_service.loadLibrary();
    } catch (_) {}
  }

  static Future<void> _initBackgroundService(
      String apiBaseUrl, String sessionId) async {
    try {
      await background_service.loadLibrary();
      await background_service.BackgroundService.enableForegroundService(
        apiBaseUrl: apiBaseUrl,
        sessionId: sessionId,
      );
    } catch (_) {}
  }

  static void disconnect() {
    try {
      ws_service.WsService.disconnect();
    } catch (_) {}
    try {
      live_activity_service.LiveActivityService.stop();
    } catch (_) {}
    _initialized = false;
    _apiBaseUrl = null;
    _sessionId = null;
    _initializing = null;
  }

  static void cancelCourseReminders() {
    try {
      reminder_service.ReminderService.cancelCourseReminders();
    } catch (_) {}
  }

  static Future<void> disableBackgroundService() async {
    try {
      await background_service.BackgroundService.disableForegroundService();
    } catch (_) {}
  }

  static Future<void> unsubscribeWebPush(
      String apiBaseUrl, String sessionId) async {
    try {
      await web_push_service.WebPushService.instance.unsubscribe(
        apiBaseUrl: apiBaseUrl,
        sessionId: sessionId,
      );
    } catch (_) {}
  }

  static Future<void> syncIosPushToken(ApiClient api) async {
    await push_service.loadLibrary();
    await push_service.PushService.syncIosPushToken(api);
  }

  static Future<void> unregisterIosPushToken(
    ApiClient api,
    String activeSessionId,
  ) async {
    await push_service.loadLibrary();
    await push_service.PushService.unregisterIosPushToken(api, activeSessionId);
  }

  static Future<void> checkForUpdate() async {
    try {
      await update_service.loadLibrary();
      update_service.UpdateService().checkForUpdateIfNeeded();
    } catch (_) {}
  }

  static Future<void> clearPwaApiCache() async {
    try {
      await web_pwa_cache.loadLibrary();
      web_pwa_cache.clearPwaApiCache();
    } catch (_) {}
  }

  static Future<void> clearPersistentCache(String studentId) async {
    try {
      await persistent_cache.loadLibrary();
      await persistent_cache.PersistentCache.clearForStudent(studentId);
    } catch (_) {}
  }

  static Future<bool> openAuthenticatedEhallUrl(
    dynamic context,
    String url, {
    String? fillScript,
    required ApiClient api,
  }) async {
    try {
      await mobile_sso.loadLibrary();
      return mobile_sso.openAuthenticatedEhallUrl(
        context,
        url,
        fillScript: fillScript,
        api: api,
      );
    } catch (_) {
      return false;
    }
  }
}
