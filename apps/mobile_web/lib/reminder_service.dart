import 'dart:async';

import 'api_client.dart';
import 'live_activity_service.dart';
import 'live_update_service.dart';
import 'local_notification_service.dart';
import 'schedule_utils.dart';

class CourseReminderSettings {
  const CourseReminderSettings({
    required this.enabled,
    this.beforeStartMinutes = 10,
    this.beforeEndMinutes = 5,
  });

  final bool enabled;
  final int beforeStartMinutes;
  final int beforeEndMinutes;
}

class CourseReminderSlot {
  const CourseReminderSlot({
    required this.id,
    required this.remindAt,
    required this.title,
    required this.body,
    required this.courseName,
    required this.countdownTarget,
    required this.shortCriticalText,
  });

  final int id;
  final DateTime remindAt;
  DateTime get when => remindAt;
  final String title;
  final String body;
  final String courseName;
  final DateTime countdownTarget;
  final String shortCriticalText;
}

class ReminderService {
  static final List<Timer> _courseTimers = [];
  static final List<Timer> _cancelTimers = [];
  static String? _courseSignature;

  static int get pendingCourseReminderCount => _courseTimers.length;

  static void configureCourseReminders({
    required List<ScheduleCourse> courses,
    required DateTime firstWeekStart,
    required CourseReminderSettings settings,
  }) {
    final signature = _signature(courses, firstWeekStart, settings);
    if (_courseSignature == signature) return;
    cancelCourseReminders();
    _courseSignature = signature;
    if (!settings.enabled) return;

    final now = DateTime.now();
    final slots = buildCourseReminderSlots(
      courses: courses,
      firstWeekStart: firstWeekStart,
      settings: settings,
      now: now,
    );
    for (final slot in slots) {
      final delay = slot.remindAt.difference(now);
      _courseTimers.add(Timer(delay, () async {
        final extras = {
          'type': 'course_reminder',
          'courseName': slot.courseName,
        };
        LiveActivityController.instance.show(
          LiveActivityEvent(
            id: slot.id.toString(),
            type: 'course_reminder',
            title: slot.title,
            body: slot.body,
            style: 'progress',
            endTime: slot.countdownTarget,
            shortText: '上课',
            targetTab: 'schedule',
            ongoing: true,
            progress: _slotProgress(slot),
          ),
        );
        final posted = await LiveUpdateService.postTimedProgressLiveUpdate(
          id: slot.id,
          title: slot.title,
          body: slot.body,
          startTimeMillis: slot.remindAt.millisecondsSinceEpoch,
          endTimeMillis: slot.countdownTarget.millisecondsSinceEpoch,
          shortCriticalText: '上课',
          extras: extras,
        );
        if (!posted) {
          await LocalNotificationService.show(
            id: slot.id,
            title: slot.title,
            body: slot.body,
            extras: extras,
          );
        }
        final cancelDelay = slot.countdownTarget.difference(DateTime.now());
        if (cancelDelay.isNegative) {
          LiveUpdateService.cancelLiveUpdate(id: slot.id);
        } else {
          _cancelTimers.add(Timer(cancelDelay, () {
            LiveUpdateService.cancelLiveUpdate(id: slot.id);
          }));
        }
      }));
    }
  }

  static void cancelCourseReminders() {
    for (final timer in _courseTimers) {
      timer.cancel();
    }
    _courseTimers.clear();
    for (final timer in _cancelTimers) {
      timer.cancel();
    }
    _cancelTimers.clear();
    _courseSignature = null;
  }

  static List<CourseReminderSlot> buildCourseReminderSlots({
    required List<ScheduleCourse> courses,
    required DateTime firstWeekStart,
    required CourseReminderSettings settings,
    required DateTime now,
    int horizonDays = 14,
  }) {
    if (!settings.enabled) return const [];
    final normalizedFirstWeek = mondayOf(firstWeekStart);
    final endAt = now.add(Duration(days: horizonDays));
    final slots = <CourseReminderSlot>[];

    for (final course in courses) {
      final weekday = course.weekday;
      final startSection = course.startSection;
      if (weekday == null ||
          weekday < 1 ||
          weekday > 7 ||
          startSection == null ||
          startSection < 1 ||
          startSection > scheduleTimes.length) {
        continue;
      }
      final safeStartSection = startSection;
      final safeEndSection = (course.endSection ?? safeStartSection)
          .clamp(1, scheduleTimes.length)
          .toInt();
      for (var day = mondayOf(now);
          !day.isAfter(endAt);
          day = day.add(const Duration(days: 1))) {
        if (day.weekday != weekday) continue;
        final week = weekFromDate(normalizedFirstWeek, day);
        if (week < 1 || !course.occursInWeek(week)) continue;

        final startTime = scheduleTimes[safeStartSection - 1].$1;
        final endTime = scheduleTimes[safeEndSection - 1].$2;
        final classStart = _atTime(day, startTime);
        final classEnd = _atTime(day, endTime);
        final startReminder =
            classStart.subtract(Duration(minutes: settings.beforeStartMinutes));
        final endReminder =
            classEnd.subtract(Duration(minutes: settings.beforeEndMinutes));

        if (startReminder.isAfter(now) && !startReminder.isAfter(endAt)) {
          slots.add(CourseReminderSlot(
            id: _slotId(course, startReminder, 'start'),
            remindAt: startReminder,
            title: '即将上课',
            body: _courseBody(course, classStart,
                prefix: '${settings.beforeStartMinutes} 分钟后'),
            courseName: course.name,
            countdownTarget: classStart,
            shortCriticalText: '${settings.beforeStartMinutes}min',
          ));
        }
        if (endReminder.isAfter(now) && !endReminder.isAfter(endAt)) {
          slots.add(CourseReminderSlot(
            id: _slotId(course, endReminder, 'end'),
            remindAt: endReminder,
            title: '即将下课',
            body: _courseBody(course, classEnd,
                prefix: '${settings.beforeEndMinutes} 分钟后下课'),
            courseName: course.name,
            countdownTarget: classEnd,
            shortCriticalText: '${settings.beforeEndMinutes}min',
          ));
        }
      }
    }
    slots.sort((a, b) => a.remindAt.compareTo(b.remindAt));
    return slots.take(64).toList();
  }

  static String _signature(
    List<ScheduleCourse> courses,
    DateTime firstWeekStart,
    CourseReminderSettings settings,
  ) {
    final coursePart = courses
        .map((c) =>
            '${c.name}|${c.weekday}|${c.startSection}|${c.endSection}|${c.weeks}|${c.classroom}')
        .join(';');
    return [
      settings.enabled,
      settings.beforeStartMinutes,
      settings.beforeEndMinutes,
      mondayOf(firstWeekStart).toIso8601String(),
      coursePart,
    ].join('#');
  }

  static String _courseBody(ScheduleCourse course, DateTime time,
      {required String prefix}) {
    final room = course.classroom == null || course.classroom!.isEmpty
        ? ''
        : ' · ${course.classroom}';
    final teacher = course.teacher == null || course.teacher!.isEmpty
        ? ''
        : ' · ${course.teacher}';
    return '$prefix：${_timeText(time)} ${course.name}$room$teacher';
  }

  static int _slotId(ScheduleCourse course, DateTime remindAt, String kind) {
    return Object.hash(course.name, course.weekday, course.startSection,
            course.endSection, remindAt.millisecondsSinceEpoch, kind)
        .abs();
  }

  static DateTime _atTime(DateTime day, String hhmm) {
    final parts = hhmm.split(':');
    return DateTime(
      day.year,
      day.month,
      day.day,
      int.parse(parts[0]),
      int.parse(parts[1]),
    );
  }

  static String _timeText(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  static double _slotProgress(CourseReminderSlot slot) {
    final total = slot.countdownTarget.difference(slot.remindAt).inMilliseconds;
    if (total <= 0) return 1;
    final elapsed = DateTime.now().difference(slot.remindAt).inMilliseconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }
}
