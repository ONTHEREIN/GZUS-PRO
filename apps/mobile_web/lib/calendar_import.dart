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

  static Future<List<CalendarTarget>> listCalendars() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('listCalendars');
      if (raw is! List) return const [];
      return [
        for (final item in raw)
          if (item is Map)
            CalendarTarget(
              identifier: item['identifier']?.toString() ?? '',
              title: item['title']?.toString() ?? '未命名日历',
              legacyEventCount:
                  (item['legacyEventCount'] as num?)?.toInt() ?? 0,
            ),
      ];
    } on PlatformException catch (e) {
      throw CalendarImportException(e.message ?? e.code);
    } on MissingPluginException {
      throw const CalendarImportException('当前平台不支持读取系统日历');
    }
  }

  static Future<CalendarImportResult> importEvents(
    List<CalendarImportEvent> events, {
    String? calendarIdentifier,
    bool cleanupStale = true,
    bool migrateLegacy = false,
  }) async {
    if (events.isEmpty) {
      return const CalendarImportResult(added: 0, updated: 0, skipped: 0);
    }
    try {
      final added = await _channel.invokeMethod<dynamic>('importEvents', {
        'events': events.map((event) => event.toPlatformMap()).toList(),
        if (calendarIdentifier != null)
          'calendarIdentifier': calendarIdentifier,
        'cleanupStale': cleanupStale,
        'migrateLegacy': migrateLegacy,
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

class CalendarTarget {
  const CalendarTarget({
    required this.identifier,
    required this.title,
    this.legacyEventCount = 0,
  });

  final String identifier;
  final String title;
  final int legacyEventCount;
}

class CalendarImportResult {
  const CalendarImportResult({
    required this.added,
    required this.updated,
    required this.skipped,
    this.deleted = 0,
    this.calendarName,
  });

  factory CalendarImportResult.fromJson(Map<String, dynamic> json) {
    return CalendarImportResult(
      added: (json['added'] as num?)?.toInt() ?? 0,
      updated: (json['updated'] as num?)?.toInt() ?? 0,
      skipped: (json['skipped'] as num?)?.toInt() ?? 0,
      deleted: (json['deleted'] as num?)?.toInt() ?? 0,
      calendarName: json['calendarName'] as String?,
    );
  }

  final int added;
  final int updated;
  final int skipped;
  final int deleted;
  final String? calendarName;

  int get total => added + updated + deleted + skipped;
}

class CalendarImportException implements Exception {
  const CalendarImportException(this.message);

  final String message;

  @override
  String toString() => message;
}
