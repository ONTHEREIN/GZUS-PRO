import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'local_notification_service.dart';

class WsService {
  static WebSocketChannel? _channel;
  static String? _baseUrl;
  static String? _sessionId;
  static StreamSubscription? _subscription;
  static Timer? _reconnectTimer;
  static int _reconnectDelay = 1;
  static bool _intentionalClose = false;

  static void configure({
    required String apiBaseUrl,
    required String sessionId,
  }) {
    _baseUrl = apiBaseUrl;
    _sessionId = sessionId;
  }

  static Future<void> connect() async {
    if (_baseUrl == null || _sessionId == null) return;
    if (_channel != null) return;
    _intentionalClose = false;
    _cancelReconnect();
    try {
      final wsUrl = _buildWsUrl(_baseUrl!);
      _channel = WebSocketChannel.connect(
        Uri.parse(wsUrl),
        protocols: null,
      );
      await _channel!.ready;
      _reconnectDelay = 1;
      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  static void disconnect() {
    _intentionalClose = true;
    _cancelReconnect();
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
  }

  static void reconnectIfNeeded() {
    if (_intentionalClose) return;
    if (_channel != null) return;
    connect();
  }

  static String _buildWsUrl(String baseUrl) {
    final uri = Uri.parse(baseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final wsUri = uri.replace(scheme: scheme);
    return '${wsUri.replace(path: '${wsUri.path}/ws/notifications')}?sessionId=$_sessionId';
  }

  static void _onMessage(dynamic data) {
    if (data is! String) return;
    try {
      final msg = jsonDecode(data) as Map<String, dynamic>;
      final title = msg['title'] as String? ?? 'GZUS-PRO';
      final body = msg['body'] as String? ?? '';
      final extras = <String, dynamic>{};
      if (msg['type'] != null) extras['type'] = msg['type'];
      if (msg['url'] != null) extras['url'] = msg['url'];
      LocalNotificationService.show(
        title: title,
        body: body,
        extras: extras,
      );
    } catch (_) {}
  }

  static void _onError(dynamic error) {
    _scheduleReconnect();
  }

  static void _onDone() {
    if (!_intentionalClose) {
      _scheduleReconnect();
    }
  }

  static void _scheduleReconnect() {
    if (_intentionalClose) return;
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
