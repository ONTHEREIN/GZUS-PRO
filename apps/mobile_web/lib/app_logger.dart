import 'package:flutter/foundation.dart';

/// 轻量客户端诊断日志：仅保留最近条目，提交反馈时由用户主动随工单发送。
class AppLogger {
  AppLogger._();

  static const int _maximumEntries = 200;
  static const int _maximumMessageLength = 4 * 1024;
  static const int _maximumSnapshotLength = 90000;
  static final List<String> _entries = <String>[];
  static bool _initialized = false;

  static void initialize() {
    if (_initialized) return;
    _initialized = true;
    final previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      error('Flutter 未处理异常', details.exception,
          details.stack ?? StackTrace.current);
      previousFlutterError?.call(details);
    };
    PlatformDispatcher.instance.onError = (errorValue, stackTrace) {
      error('平台未处理异常', errorValue, stackTrace);
      return false;
    };
    info('应用启动：platform=${defaultTargetPlatform.name}, web=$kIsWeb');
  }

  static void info(String message) {
    _append('INFO', message);
  }

  static void warning(String message) {
    _append('WARN', message);
  }

  static void error(String message, Object errorValue, StackTrace stackTrace) {
    final detail =
        '$message: ${errorValue.runtimeType}: $errorValue\n$stackTrace';
    _append('ERROR', detail);
  }

  static String snapshot() {
    final header = [
      'GZUS-PRO 客户端诊断日志',
      'platform=${defaultTargetPlatform.name}, web=$kIsWeb',
      'generatedAt=${DateTime.now().toUtc().toIso8601String()}',
    ].join('\n');
    if (_entries.isEmpty) return '$header\n（当前没有额外日志）';
    final entries = _entries.join('\n');
    final recentEntries = entries.length > _maximumSnapshotLength
        ? entries.substring(entries.length - _maximumSnapshotLength)
        : entries;
    return '$header\n$recentEntries';
  }

  static void _append(String level, String message) {
    final trimmed = message.length > _maximumMessageLength
        ? '${message.substring(0, _maximumMessageLength)}…'
        : message;
    final timestamp = DateTime.now().toUtc().toIso8601String();
    _entries.add('[$timestamp] [$level] $trimmed');
    if (_entries.length > _maximumEntries) {
      _entries.removeRange(0, _entries.length - _maximumEntries);
    }
  }
}
