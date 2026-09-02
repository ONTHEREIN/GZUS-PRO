import 'package:flutter/services.dart';

/// 一条可直接写入系统日历的日程。
class CalendarImportEvent {
  const CalendarImportEvent({
    required this.sourceId,
    required this.title,
    this.description,
    this.location,
    required this.start,
    required this.end,
  });

  final String sourceId;
  final String title;
  final String? description;
  final String? location;
  final DateTime start;
  final DateTime end;

  Map<String, dynamic> toPlatformMap() => {
        'title': title,
        'sourceId': sourceId,
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

  static Future<CalendarImportResult> importEvents(
      List<CalendarImportEvent> events) async {
    if (events.isEmpty) {
      return const CalendarImportResult(added: 0, updated: 0, skipped: 0);
    }
    try {
      final added = await _channel.invokeMethod<dynamic>('importEvents', {
        'events': events.map((event) => event.toPlatformMap()).toList(),
      });
      final result = added is Map
          ? Map<String, dynamic>.from(added)
          : {'added': added ?? 0, 'updated': 0, 'skipped': 0};
      return CalendarImportResult.fromJson(result);
    } on MissingPluginException {
      throw const CalendarImportException('当前平台不支持直接导入系统日历');
    } on PlatformException catch (e) {
      throw CalendarImportException(
        e.message ?? e.code,
      );
    }
  }
}

class CalendarImportResult {
  const CalendarImportResult({
    required this.added,
    required this.updated,
    required this.skipped,
  });

  factory CalendarImportResult.fromJson(Map<String, dynamic> json) {
    return CalendarImportResult(
      added: (json['added'] as num?)?.toInt() ?? 0,
      updated: (json['updated'] as num?)?.toInt() ?? 0,
      skipped: (json['skipped'] as num?)?.toInt() ?? 0,
    );
  }

  final int added;
  final int updated;
  final int skipped;

  int get total => added + updated + skipped;
}

class CalendarImportException implements Exception {
  const CalendarImportException(this.message);

  final String message;

  @override
  String toString() => message;
}
