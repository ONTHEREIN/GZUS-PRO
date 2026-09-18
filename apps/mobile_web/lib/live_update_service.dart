import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'live_activity_service.dart';

enum AndroidPromotedNotificationStatus {
  available('available'),
  authorizationRequired('authorization_required'),
  unsupported('unsupported');

  const AndroidPromotedNotificationStatus(this.nativeValue);

  final String nativeValue;

  static AndroidPromotedNotificationStatus fromNativeValue(String? value) {
    return switch (value) {
      'available' => AndroidPromotedNotificationStatus.available,
      'authorization_required' =>
        AndroidPromotedNotificationStatus.authorizationRequired,
      _ => AndroidPromotedNotificationStatus.unsupported,
    };
  }
}

class LiveUpdateService {
  static const _channel = MethodChannel('cn.gzus.pro/live_update');
  static final Map<int, Future<void>> _cancelTasks = {};
  static final Map<int, Timer> _progressTimers = {};

  /// 将 iOS/Android 共用的活动事件归一化后投递到 Android 原生通知。
  ///
  /// 课程和考试只要带有有效时间窗口，就沿用进度更新计时器；原生层会
  /// 将这类事件优先渲染为 chronometer。其它进度事件保持普通进度条，
  /// 成绩、水电和其它摘要事件则直接走可取消的标准通知。
  static Future<bool> postEvent({required LiveActivityEvent event}) async {
    final payload = event.toAndroidPayload();
    final startTimeMillis = payload['startTimeMillis'] as int? ?? 0;
    final endTimeMillis = payload['endTimeMillis'] as int? ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final isTimed = event.isCountdown && endTimeMillis > now;
    if (isTimed) {
      return postTimedProgressLiveUpdate(
        id: notificationIdForEventId(event.id),
        title: event.title,
        body: event.body,
        startTimeMillis: startTimeMillis > 0 ? startTimeMillis : now,
        endTimeMillis: endTimeMillis,
        shortCriticalText: payload['shortCriticalText'] as String,
        extras: payload,
        ongoing: event.ongoing,
      );
    }
    return postLiveUpdate(
      id: notificationIdForEventId(event.id),
      title: event.title,
      body: event.body,
      style: event.style,
      endTimeMillis: endTimeMillis,
      shortCriticalText: payload['shortCriticalText'] as String,
      extras: payload,
      ongoing: event.ongoing,
      progressMax: payload['progressMax'] as int? ?? 0,
      progressCurrent: payload['progressCurrent'] as int? ?? 0,
    );
  }

  /// 使用与 Android `String.hashCode` 相同的 UTF-16/31 倍乘算法生成稳定 ID。
  static int notificationIdForEventId(String eventId) {
    var hash = 0;
    for (final codeUnit in eventId.codeUnits) {
      hash = (hash * 31 + codeUnit) & 0xFFFFFFFF;
    }
    if (hash >= 0x80000000) hash -= 0x100000000;
    if (hash == -0x80000000) return 1;
    return hash.abs();
  }

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
      debugPrint(
          '[LiveUpdateService] Invoking postLiveUpdate on native channel: id=$id, title=$title, style=$style');
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
          'startTimeMillis': startTimeMillis,
          'endTimeMillis': endTimeMillis,
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

  /// 检查 Android 实况通知的推广资格，并区分授权不足与设备不支持。
  static Future<AndroidPromotedNotificationStatus>
      checkPromotedNotificationStatus() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return AndroidPromotedNotificationStatus.unsupported;
    }
    try {
      final result = await _channel.invokeMethod<String>(
        'getPromotedNotificationStatus',
      );
      return AndroidPromotedNotificationStatus.fromNativeValue(result);
    } on MissingPluginException {
      return AndroidPromotedNotificationStatus.unsupported;
    } on PlatformException {
      return AndroidPromotedNotificationStatus.unsupported;
    }
  }

  /// 打开当前应用的 Android 通知设置，供用户开启实况通知推广资格。
  static Future<bool> openPromotedNotificationSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>(
        'openPromotedNotificationSettings',
      );
      return result ?? false;
    } on MissingPluginException {
      return false;
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
