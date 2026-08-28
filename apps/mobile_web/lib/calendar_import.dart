import 'package:flutter/services.dart';

/// 一条可直接写入系统日历的日程。
class CalendarImportEvent {
  const CalendarImportEvent({
    required this.title,
    this.description,
    this.location,
    required this.start,
    required this.end,
  });

  final String title;
  final String? description;
  final String? location;
  final DateTime start;
  final DateTime end;

  Map<String, dynamic> toPlatformMap() => {
        'title': title,
        if (description != null) 'description': description,
        if (location != null) 'location': location,
        'startMillis': start.millisecondsSinceEpoch,
        'endMillis': end.millisecondsSinceEpoch,
      };
}

/// 调用原生系统日历写入能力（Android CalendarProvider / iOS EventKit）。
class CalendarImportService {
  CalendarImportService._();

  static const MethodChannel _channel = MethodChannel('cn.gzus.pro/calendar');

  static Future<int> importEvents(List<CalendarImportEvent> events) async {
    if (events.isEmpty) return 0;
    try {
      final added = await _channel.invokeMethod<int>('importEvents', {
        'events': events.map((event) => event.toPlatformMap()).toList(),
      });
      return added ?? 0;
    } on MissingPluginException {
      throw const CalendarImportException('当前平台不支持直接导入系统日历');
    } on PlatformException catch (e) {
      throw CalendarImportException(
        e.message ?? e.code,
      );
    }
  }
}

class CalendarImportException implements Exception {
  const CalendarImportException(this.message);

  final String message;

  @override
  String toString() => message;
}
