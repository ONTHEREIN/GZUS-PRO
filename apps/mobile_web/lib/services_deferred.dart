import 'dart:async';

import 'api_client.dart' deferred as api_client;

import 'web_push_service.dart' deferred as web_push_service;
import 'local_notification_service.dart' deferred as local_notification_service;
import 'push_service.dart' deferred as push_service;
import 'persistent_cache.dart' deferred as persistent_cache;
import 'ws_service.dart' deferred as ws_service;
import 'reminder_service.dart' deferred as reminder_service;
import 'update_service.dart' deferred as update_service;
import 'background_service.dart' deferred as background_service;

import 'ftp_upload_service.dart' deferred as ftp_upload_service;
import 'live_activity_service.dart' deferred as live_activity_service;
import 'live_update_service.dart' deferred as live_update_service;
import 'location_service.dart' deferred as location_service;
import 'avatar_open.dart' deferred as avatar_open;
import 'ics_download.dart' deferred as ics_download;
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

  static Future<void> initialize({
    required String apiBaseUrl,
    required String sessionId,
    void Function(Map<String, dynamic>)? onNotificationTap,
  }) async {
    if (_initialized) return;

    await Future.wait([
      _initWebPushService(onNotificationTap),
      _initLocalNotificationService(onNotificationTap),
      _initPushService(onNotificationTap),
      _initPersistentCache(),
      _initWsService(apiBaseUrl, sessionId),
      _initReminderService(),
      _initUpdateService(),
      _initBackgroundService(apiBaseUrl, sessionId),
    ]);

    _initialized = true;
  }

  static Future<void> _initWebPushService(
      void Function(Map<String, dynamic>)? onTap) async {
    try {
      await web_push_service.loadLibrary();
      await web_push_service.WebPushService.instance.init(onTap: onTap);
    } catch (_) {}
  }

  static Future<void> _initLocalNotificationService(
      void Function(Map<String, dynamic>)? onTap) async {
    try {
      await local_notification_service.loadLibrary();
      await local_notification_service.LocalNotificationService.init(onTap: onTap);
    } catch (_) {}
  }

  static Future<void> _initPushService(
      void Function(Map<String, dynamic>)? onTap) async {
    try {
      await push_service.loadLibrary();
      await push_service.PushService.init(onTap: onTap);
    } catch (_) {}
  }

  static Future<void> _initPersistentCache() async {
    try {
      await persistent_cache.loadLibrary();
    } catch (_) {}
  }

  static Future<void> _initWsService(String apiBaseUrl, String sessionId) async {
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

  static Future<void> unregisterPush(Function unregisterPushFunc) async {
    try {
      await unregisterPushFunc();
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

  static Future<String?> getPushRegistrationId() async {
    try {
      await push_service.loadLibrary();
      return push_service.PushService.registrationId;
    } catch (_) {
      return null;
    }
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
    dynamic api,
    String? attachmentName,
  }) async {
    try {
      await mobile_sso.loadLibrary();
      return mobile_sso.openAuthenticatedEhallUrl(
        context,
        url,
        fillScript: fillScript,
        api: api,
        attachmentName: attachmentName,
      );
    } catch (_) {
      return false;
    }
  }
}