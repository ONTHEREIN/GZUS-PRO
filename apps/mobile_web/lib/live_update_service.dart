import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LiveUpdateService {
  static const _channel = MethodChannel('cn.gzus.pro/live_update');
  static final Map<int, Future<void>> _cancelTasks = {};
  static final Map<int, Timer> _progressTimers = {};

  /// Post a live update notification (Android only).
  /// [id] - unique notification id
  /// [title] - notification title
  /// [body] - notification body text
  /// [style] - "timer", "metric", or "progress"
  /// [endTimeMillis] - countdown target time in epoch millis (for timer style)
  /// [shortCriticalText] - short text for status chip (e.g. "5min", "低电量")
  /// [extras] - extras map for click intent
  static Future<bool> postLiveUpdate({
    required int id,
    required String title,
    required String body,
    String style = 'timer',
    int endTimeMillis = 0,
    String? shortCriticalText,
    Map<String, dynamic>? extras,
    bool? ongoing,
    int progressMax = 0,
    int progressCurrent = 0,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      debugPrint('[LiveUpdateService] Invoking postLiveUpdate on native channel: id=$id, title=$title, style=$style');
      final posted = await _channel.invokeMethod<bool>('postLiveUpdate', {
        'id': id,
        'title': title,
        'body': body,
        'style': style,
        'endTimeMillis': endTimeMillis,
        'shortCriticalText': shortCriticalText,
        'extras': extras != null ? jsonEncode(extras) : null,
        'ongoing': ongoing ?? style != 'metric',
        'progressMax': progressMax,
        'progressCurrent': progressCurrent,
      });
      debugPrint('[LiveUpdateService] Native channel returned: posted=$posted');
      if (posted == true &&
          endTimeMillis > DateTime.now().millisecondsSinceEpoch) {
        _scheduleCancel(id, endTimeMillis);
      }
      return posted ?? false;
    } on PlatformException catch (e) {
      debugPrint('[LiveUpdateService] PlatformException: $e');
      return false;
    }
  }

  static Future<bool> postTimedProgressLiveUpdate({
    required int id,
    required String title,
    required String body,
    required int startTimeMillis,
    required int endTimeMillis,
    required String shortCriticalText,
    Map<String, dynamic>? extras,
    bool ongoing = true,
    Duration updateInterval = const Duration(minutes: 1),
  }) async {
    if (endTimeMillis <= 0) {
      return postLiveUpdate(
        id: id,
        title: title,
        body: body,
        style: 'progress',
        shortCriticalText: shortCriticalText,
        extras: extras,
        ongoing: ongoing,
        progressMax: 100,
        progressCurrent: 100,
      );
    }
    _progressTimers.remove(id)?.cancel();

    Future<bool> postOnce() {
      final progress = _timeProgress(
        startTimeMillis: startTimeMillis,
        endTimeMillis: endTimeMillis,
      );
      return postLiveUpdate(
        id: id,
        title: title,
        body: body,
        style: 'progress',
        endTimeMillis: endTimeMillis,
        shortCriticalText: shortCriticalText,
        extras: {
          if (extras != null) ...extras,
          'style': 'progress',
          'progressMax': 100,
          'progressCurrent': progress,
        },
        ongoing: ongoing,
        progressMax: 100,
        progressCurrent: progress,
      );
    }

    final posted = await postOnce();
    if (!posted || endTimeMillis <= DateTime.now().millisecondsSinceEpoch) {
      return posted;
    }
    _progressTimers[id] = Timer.periodic(updateInterval, (timer) async {
      if (endTimeMillis <= DateTime.now().millisecondsSinceEpoch) {
        timer.cancel();
        _progressTimers.remove(id);
        await cancelLiveUpdate(id: id);
        return;
      }
      await postOnce();
    });
    return posted;
  }

  /// Cancel a live update notification by id.
  static Future<void> cancelLiveUpdate({required int id}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _progressTimers.remove(id)?.cancel();
    try {
      await _channel.invokeMethod('cancelLiveUpdate', {'id': id});
      _cancelTasks.remove(id);
    } on PlatformException {
      // Native bridge unavailable on this platform
    }
  }

  /// Check if the device supports promoted notifications.
  static Future<bool> canPostPromotedNotifications() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final result =
          await _channel.invokeMethod<bool>('canPostPromotedNotifications');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  static void _scheduleCancel(int id, int endTimeMillis) {
    _cancelTasks.remove(id);
    final delay = DateTime.fromMillisecondsSinceEpoch(endTimeMillis)
        .difference(DateTime.now());
    if (delay.isNegative) return;
    late final Future<void> task;
    task = Future<void>.delayed(delay, () async {
      if (_cancelTasks[id] != task) return;
      await cancelLiveUpdate(id: id);
    });
    _cancelTasks[id] = task;
  }

  static int _timeProgress({
    required int startTimeMillis,
    required int endTimeMillis,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final total = endTimeMillis - startTimeMillis;
    if (total <= 0) return 100;
    return (((now - startTimeMillis) / total) * 100).clamp(0, 100).round();
  }
}
