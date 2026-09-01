import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'live_activity_service.dart';
import 'local_notification_service.dart';
import 'live_update_service.dart';

class WsService {
  static WebSocketChannel? _channel;
  static String? _baseUrl;
  static String? _sessionId;
  static StreamSubscription? _subscription;
  static Timer? _reconnectTimer;
  static int _reconnectDelay = 1;
  static bool _intentionalClose = false;
  static bool _isPaused = false;

  static void configure({
    required String apiBaseUrl,
    required String sessionId,
  }) {
    if (_sessionId != null && _sessionId != sessionId) {
      disconnect();
    }
    _baseUrl = apiBaseUrl;
    _sessionId = sessionId;
  }

  static Future<void> connect() async {
    if (_baseUrl == null || _sessionId == null) {
      debugPrint(
          '[WsService] Cannot connect: baseUrl=${_baseUrl ?? "unset"}, hasSession=${_sessionId != null}');
      return;
    }
    if (kIsWeb) {
      debugPrint('[WsService] Skipping connect on web; polling is enabled');
      return;
    }
    if (_isPaused) {
      debugPrint('[WsService] Skipping connect: app is paused');
      return;
    }
    if (_channel != null) return;
    _intentionalClose = false;
    _cancelReconnect();
    try {
      final wsUrl = _buildWsUrl(_baseUrl!);
      debugPrint('[WsService] Connecting to ${_redactWsUrl(wsUrl)}');
      final channel = WebSocketChannel.connect(
        Uri.parse(wsUrl),
        protocols: null,
      );
      _channel = channel;
      await channel.ready;
      if (_channel != channel) return; // paused during connect
      debugPrint('[WsService] Connected successfully');
      _reconnectDelay = 1;
      _subscription = channel.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
    } catch (e) {
      debugPrint('[WsService] Connection failed: $e');
      _scheduleReconnect();
    }
  }

  static void disconnect() {
    _intentionalClose = true;
    _cancelReconnect();
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
  }

  static void pause() {
    debugPrint(
        '[WsService] pause() called, _isPaused=$_isPaused, _channel=${_channel != null ? "connected" : "null"}');
    _isPaused = true;
    _cancelReconnect();
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    debugPrint(
        '[WsService] pause() completed, _channel=${_channel != null ? "connected" : "null"}');
  }

  static void resume() {
    debugPrint('[WsService] resume() called, _isPaused=$_isPaused');
    if (!_isPaused) return;
    _isPaused = false;
    _intentionalClose = false;
    connect();
  }

  static void reconnectIfNeeded() {
    if (_intentionalClose) return;
    if (_channel != null) return;
    connect();
  }

  static String _buildWsUrl(String baseUrl) {
    final uri = Uri.parse(baseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final defaultPort = uri.scheme == 'https' ? 443 : 80;
    final wsUri = uri.replace(
      scheme: scheme,
      port: uri.hasPort ? uri.port : defaultPort,
    );
    return '${wsUri.replace(path: '${wsUri.path}/ws/notifications')}?sessionId=$_sessionId';
  }

  @visibleForTesting
  static String buildWsUrlForTest(String baseUrl, String sessionId) {
    _sessionId = sessionId;
    return _buildWsUrl(baseUrl);
  }

  static String _redactWsUrl(String url) {
    final uri = Uri.parse(url);
    return uri.replace(queryParameters: {'sessionId': '[REDACTED]'}).toString();
  }

  static void _onMessage(dynamic data) {
    if (data is! String) return;
    try {
      final msg = jsonDecode(data) as Map<String, dynamic>;
      debugPrint(
          '[WsService] Received message type=${msg['type'] ?? 'unknown'}');
      unawaited(handleNotificationMessage(msg));
    } catch (e) {
      debugPrint('[WsService] Failed to parse message: $e');
    }
  }

  static Future<void> handleNotificationMessage(
      Map<String, dynamic> msg) async {
    final title = msg['title'] as String? ?? '软帮手';
    final body = msg['body'] as String? ?? '';
    debugPrint(
        '[WsService] Showing notification: type=${msg['type'] ?? 'unknown'}, bodyLength=${body.length}');
    final extras = _extrasForMessage(msg);
    final notificationId = notificationIdForMessage(msg);
    LiveActivityController.instance.show(
      LiveActivityEvent.fromMessage({
        ...msg,
        'id': msg['id'] ?? notificationId.toString(),
        'title': title,
        'body': body,
        'extras': extras,
      }),
    );
    final liveUpdate =
        msg['liveUpdate'] == true || extras['liveUpdate'] == true;
    if (!liveUpdate) {
      await LocalNotificationService.show(
        id: notificationId,
        title: title,
        body: body,
        extras: extras,
      );
      return;
    }

    final style = (msg['style'] ?? extras['style'] ?? 'metric').toString();
    final endTimeMillis = _intValue(msg['endTime'] ?? extras['endTime']);
    final startTimeMillis = _intValue(
      msg['progressStartTime'] ??
          extras['progressStartTime'] ??
          DateTime.now().millisecondsSinceEpoch,
    );
    debugPrint(
        '[WsService] Posting LiveUpdate: style=$style, endTimeMillis=$endTimeMillis');
    final posted = style == 'progress' && endTimeMillis > 0
        ? await LiveUpdateService.postTimedProgressLiveUpdate(
            id: notificationId,
            title: title,
            body: body,
            startTimeMillis: startTimeMillis,
            endTimeMillis: endTimeMillis,
            shortCriticalText: msg['shortCriticalText'] as String? ?? '动态',
            extras: extras,
            ongoing: msg['ongoing'] as bool? ?? true,
          )
        : await LiveUpdateService.postLiveUpdate(
            id: notificationId,
            title: title,
            body: body,
            style: style,
            endTimeMillis: endTimeMillis,
            shortCriticalText: msg['shortCriticalText'] as String?,
            extras: extras,
            ongoing: msg['ongoing'] as bool? ?? style != 'metric',
            progressMax: _intValue(msg['progressMax']),
            progressCurrent: _intValue(msg['progressCurrent']),
          );
    debugPrint('[WsService] LiveUpdate post result: posted=$posted');
    if (!posted) {
      await LocalNotificationService.show(
        id: notificationId,
        title: title,
        body: body,
        extras: extras,
      );
    }
  }

  static int notificationIdForMessage(Map<String, dynamic> msg) {
    final id = msg['id']?.toString().trim();
    if (id != null && id.isNotEmpty) return id.hashCode.abs();
    return Object.hash(
      msg['type'] ?? '',
      msg['title'] ?? '',
      msg['body'] ?? '',
      msg['url'] ?? '',
    ).abs();
  }

  static Map<String, dynamic> _extrasForMessage(Map<String, dynamic> msg) {
    final rawExtras = msg['extras'];
    final extras = rawExtras is Map
        ? Map<String, dynamic>.from(rawExtras)
        : <String, dynamic>{};
    for (final key in const [
      'type',
      'url',
      'courseName',
      'studentId',
      'liveUpdate',
      'style',
      'endTime',
      'id',
      'shortCriticalText',
      'progressStartTime',
      'progressMax',
      'progressCurrent',
      'progress',
    ]) {
      if (msg[key] != null) extras[key] = msg[key];
    }
    return extras;
  }

  static int _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static void _onError(dynamic error) {
    debugPrint('[WsService] Stream error: $error');
    _subscription = null;
    _channel = null;
    _scheduleReconnect();
  }

  static void _onDone() {
    debugPrint(
        '[WsService] Stream closed, intentionalClose=$_intentionalClose, isPaused=$_isPaused');
    _subscription = null;
    _channel = null;
    if (!_intentionalClose && !_isPaused) {
      _scheduleReconnect();
    }
  }

  static void _scheduleReconnect() {
    if (_intentionalClose || _isPaused) return;
    _cancelReconnect();
    _reconnectTimer = Timer(Duration(seconds: _reconnectDelay), () {
      _reconnectDelay = (_reconnectDelay * 2).clamp(1, 60);
      connect();
    });
  }

  static void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }
}
