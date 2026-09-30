import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api_client.dart';
import 'models/schedule_override.dart';
import 'schedule_adjustment_sync.dart';
import 'schedule_utils.dart';

/// 仅传本机规则与待同步队列，已同步调课由后台读取云端最新版本。
String widgetScheduleRequestJson({
  required int year,
  required int term,
  required DateTime firstWeekStart,
  required List<ScheduleOverride> overrides,
  required List<ScheduleAdjustmentRecord> pending,
}) =>
    jsonEncode({
      'year': year,
      'term': term,
      'firstWeekStart': dateText(firstWeekStart),
      'overrides': overrides.map((item) => item.toJson()).toList(),
      'pendingAdjustments': pending.map((item) => item.toJson()).toList(),
    });

List<Map<String, Object>> widgetScheduleItems(
        List<ScheduleOccurrence> occurrences) =>
    [
      for (final item in occurrences) _widgetScheduleItem(item),
    ];

Map<String, Object> _widgetScheduleItem(ScheduleOccurrence item) {
  final course = item.course;
  final start = course.startSection;
  final end = course.endSection ?? start;
  if (start == null ||
      end == null ||
      start < 1 ||
      end < start ||
      end > scheduleTimes.length) {
    throw FormatException('桌面组件课程节次无效：${course.name}');
  }
  return {
    'itemKey': item.occurrenceKey,
    'date': dateText(item.date),
    'week': item.week,
    'weekday': item.date.weekday,
    'startSection': start,
    'endSection': end,
    'time': '${scheduleTimes[start - 1].$1}-${scheduleTimes[end - 1].$2}',
    'name': course.name,
    'classroom': course.classroom ?? '',
    'teacher': course.teacher ?? '',
    'ongoing': false,
  };
}

/// 编辑课表时立即更新组件课表上下文，无需先返回首页，不改动其他组件模块。
Future<void> updateWidgetSchedule({
  required ApiClient api,
  required int year,
  required int term,
  required DateTime firstWeekStart,
  required List<ScheduleCourse> courses,
  required List<ScheduleAdjustmentRecord> adjustments,
  required List<ScheduleOverride> overrides,
  required bool Function() isCurrent,
}) async {
  if (kIsWeb) return;
  final namespace = api.namespace;
  final sessionId = api.sessionId;
  if (sessionId == null || sessionId.isEmpty) return;
  final pending = await ScheduleAdjustmentSync.loadQueue(namespace, year, term);
  if (!isCurrent() ||
      api.namespace != namespace ||
      api.sessionId != sessionId) {
    throw StateError('账号或会话已切换，拒绝更新旧课表组件');
  }
  final occurrences = expandEffectiveSchedule(
    courses: courses,
    firstWeekStart: firstWeekStart,
    adjustments: adjustments,
    overrides: overrides,
  );
  await const MethodChannel('cn.gzus.pro/home_widgets')
      .invokeMethod<void>('updateScheduleContext', {
    'widgetApiBaseUrl': api.baseUrl,
    'widgetSessionId': sessionId,
    'widgetYear': year,
    'widgetTerm': term,
    'widgetCurrentWeek':
        weekFromDate(firstWeekStart, DateTime.now()).clamp(1, 30),
    'widgetFirstWeekStartEpochMillis': firstWeekStart.millisecondsSinceEpoch,
    'widgetScheduleContextJson': widgetScheduleRequestJson(
      year: year,
      term: term,
      firstWeekStart: firstWeekStart,
      overrides: overrides,
      pending: pending,
    ),
    'effectiveCoursesJson': jsonEncode(widgetScheduleItems(occurrences)),
  }).timeout(const Duration(seconds: 2));
}
