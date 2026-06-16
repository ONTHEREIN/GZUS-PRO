import 'dart:async';

import 'api_client.dart';
import 'live_activity_service.dart';
import 'live_update_service.dart';
import 'local_notification_service.dart';

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
    final normalizedFirstWeek = _mondayOf(firstWeekStart);
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
          startSection > _sectionTimes.length) {
        continue;
      }
      final safeStartSection = startSection;
      final safeEndSection = (course.endSection ?? safeStartSection)
          .clamp(1, _sectionTimes.length)
          .toInt();
      for (var day = _mondayOf(now);
          !day.isAfter(endAt);
          day = day.add(const Duration(days: 1))) {
        if (day.weekday != weekday) continue;
        final week = _weekFromDate(normalizedFirstWeek, day);
        if (week < 1 || !course.occursInWeek(week)) continue;

        final startTime = _sectionTimes[safeStartSection - 1].start;
        final endTime = _sectionTimes[safeEndSection - 1].end;
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
      _mondayOf(firstWeekStart).toIso8601String(),
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

  static DateTime _mondayOf(DateTime value) {
    final date = DateTime(value.year, value.month, value.day);
    return date.subtract(Duration(days: date.weekday - DateTime.monday));
  }

  static int _weekFromDate(DateTime firstWeekStart, DateTime date) {
    return _mondayOf(date).difference(_mondayOf(firstWeekStart)).inDays ~/ 7 +
        1;
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

class _SectionTime {
  const _SectionTime(this.start, this.end);

  final String start;
  final String end;
}

const _sectionTimes = [
  _SectionTime('09:00', '09:40'),
  _SectionTime('09:40', '10:20'),
  _SectionTime('10:40', '11:20'),
  _SectionTime('11:20', '12:00'),
  _SectionTime('12:30', '13:10'),
  _SectionTime('13:10', '13:50'),
  _SectionTime('14:00', '14:40'),
  _SectionTime('14:40', '15:20'),
  _SectionTime('15:30', '16:10'),
  _SectionTime('16:10', '16:50'),
  _SectionTime('17:00', '17:40'),
  _SectionTime('17:40', '18:20'),
  _SectionTime('19:00', '19:40'),
  _SectionTime('19:40', '20:20'),
  _SectionTime('20:30', '21:10'),
  _SectionTime('21:10', '21:50'),
];
