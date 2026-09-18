import 'dart:convert';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

import 'api_client.dart';
import 'background_service.dart' deferred as background_service;
import 'models/schedule_override.dart';
import 'push_service.dart' deferred as push_service;
import 'reminder_service.dart' deferred as reminder_service;
import 'schedule_utils.dart';

/// 使用同一份课表数据配置本地提醒、Android 原生提醒和云端课程提醒。
Future<String?> configureCourseReminders({
  required ApiClient api,
  required List<ScheduleCourse> courses,
  required DateTime firstWeekStart,
  required bool enabled,
  required int beforeStartMinutes,
  required int beforeEndMinutes,
  required List<ScheduleAdjustmentRecord> adjustments,
  required List<ScheduleOverride> overrides,
  required String? nativeReminderSignature,
}) async {
  final effectiveOccurrences = expandEffectiveSchedule(
    courses: courses,
    firstWeekStart: firstWeekStart,
    adjustments: adjustments,
    overrides: overrides,
    startDate: DateTime.now(),
    endDate: DateTime.now().add(const Duration(days: 30)),
  );
  await reminder_service.loadLibrary();
  await reminder_service.ReminderService.configureCourseReminders(
    courses: courses,
    firstWeekStart: firstWeekStart,
    settings: reminder_service.CourseReminderSettings(
      enabled: enabled,
      beforeStartMinutes: beforeStartMinutes,
      beforeEndMinutes: beforeEndMinutes,
    ),
    effectiveOccurrences: effectiveOccurrences,
  );
  final cloudStatus = await api.fetchBackgroundNotificationStatus();
  if (cloudStatus?.enabled == true) {
    await api.syncCloudCourseReminders(
      enabled: enabled,
      beforeStartMinutes: beforeStartMinutes,
      beforeEndMinutes: beforeEndMinutes,
      firstWeekStart: firstWeekStart,
      courses: courseReminderPayload(courses),
      effectiveOccurrences: effectiveOccurrencePayload(effectiveOccurrences),
    );
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      await push_service.loadLibrary();
      await push_service.PushService.syncIosCourseSchedule(
        api: api,
        eventKeys: reminder_service.ReminderService.localCourseEventKeys,
        validUntil: reminder_service.ReminderService.localCourseValidUntil ??
            DateTime.now(),
      );
    } else {
      await background_service.loadLibrary();
      await background_service.BackgroundService.cancelCourseReminders();
    }
    return enabled ? nativeReminderSignature : null;
  }

  if (!enabled) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await background_service.loadLibrary();
      await background_service.BackgroundService.cancelCourseReminders();
    }
    return null;
  }

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return syncCourseRemindersToNative(
      courses: courses,
      beforeStartMinutes: beforeStartMinutes,
      beforeEndMinutes: beforeEndMinutes,
      firstWeekStart: firstWeekStart,
      effectiveOccurrences: effectiveOccurrences,
      previousSignature: nativeReminderSignature,
    );
  }
  return nativeReminderSignature;
}

List<Map<String, dynamic>> courseReminderPayload(
  List<ScheduleCourse> courses,
) {
  return courses.where((course) {
    return course.weekday != null &&
        course.weekday! >= 1 &&
        course.weekday! <= 7 &&
        course.startSection != null &&
        course.startSection! >= 1 &&
        course.startSection! <= 16 &&
        course.endSection != null &&
        course.endSection! >= 1 &&
        course.endSection! <= 16;
  }).map((course) {
    final weeks = <int>[];
    for (var week = 1; week <= 30; week++) {
      if (course.occursInWeek(week)) weeks.add(week);
    }
    return {
      'name': course.name,
      'weekday': course.weekday ?? 0,
      'startSection': course.startSection ?? 0,
      'endSection': course.endSection ?? 0,
      'classroom': course.classroom ?? '',
      'teacher': course.teacher ?? '',
      'weeks': weeks,
    };
  }).toList();
}

List<Map<String, dynamic>> effectiveOccurrencePayload(
  List<ScheduleOccurrence> occurrences,
) {
  return [
    for (final occurrence in occurrences)
      {
        'date': dateText(occurrence.date),
        'name': occurrence.course.name,
        'startSection': occurrence.course.startSection,
        'endSection': occurrence.course.endSection,
        'classroom': occurrence.course.classroom ?? '',
        'teacher': occurrence.course.teacher ?? '',
      },
  ];
}

Future<String> syncCourseRemindersToNative({
  required List<ScheduleCourse> courses,
  required int beforeStartMinutes,
  required int beforeEndMinutes,
  required DateTime firstWeekStart,
  required List<ScheduleOccurrence> effectiveOccurrences,
  required String? previousSignature,
}) async {
  final coursesJson = jsonEncode(courseReminderPayload(courses));
  final effectiveOccurrencesJson = jsonEncode([
    for (final occurrence in effectiveOccurrences)
      {
        'date': dateText(occurrence.date),
        'name': occurrence.course.name,
        'startSection': occurrence.course.startSection,
        'endSection': occurrence.course.endSection,
        'classroom': occurrence.course.classroom ?? '',
        'teacher': occurrence.course.teacher ?? '',
        'occurrenceKey': occurrence.occurrenceKey,
      },
  ]);
  final firstWeekStartText = dateText(firstWeekStart);
  final signature =
      '$coursesJson|$effectiveOccurrencesJson|$beforeStartMinutes|$beforeEndMinutes|$firstWeekStartText';
  if (signature == previousSignature) return signature;
  await background_service.loadLibrary();
  await background_service.BackgroundService.updateCourseReminders(
    coursesJson: coursesJson,
    effectiveOccurrencesJson: effectiveOccurrencesJson,
    beforeStartMinutes: beforeStartMinutes,
    beforeEndMinutes: beforeEndMinutes,
    firstWeekStart: firstWeekStartText,
  );
  return signature;
}
