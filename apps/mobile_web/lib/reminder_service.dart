import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'live_activity_service.dart';
import 'live_update_service.dart';
import 'local_notification_service.dart';
import 'permission_service.dart';
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
    required this.location,
    required this.countdownTarget,
    required this.shortCriticalText,
    required this.eventKey,
  });

  final int id;
  final DateTime remindAt;
  DateTime get when => remindAt;
  final String title;
  final String body;
  final String courseName;
  final String? location;
  final DateTime countdownTarget;
  final String shortCriticalText;
  final String eventKey;
}

class ReminderService {
  static final List<Timer> _courseTimers = [];
  static final List<Timer> _cancelTimers = [];
  static String? _courseSignature;
  static List<String> _localCourseEventKeys = const [];
  static DateTime? _localCourseValidUntil;
  static List<ScheduledLocalNotification> _localCourseNotifications = const [];

  static int get pendingCourseReminderCount => _courseTimers.length;

  static List<String> get localCourseEventKeys => _localCourseEventKeys;

  static DateTime? get localCourseValidUntil => _localCourseValidUntil;

  static bool get hasLocalCoursePlan => _courseSignature != null;

  static Future<void> configureCourseReminders({
    required List<ScheduleCourse> courses,
    required DateTime firstWeekStart,
    required CourseReminderSettings settings,
    required List<ScheduleOccurrence> effectiveOccurrences,
  }) async {
    final signature = _signature(
      courses,
      firstWeekStart,
      settings,
      effectiveOccurrences,
    );
    if (_courseSignature == signature) return;
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        settings.enabled &&
        !await PermissionService.checkNotificationPermission()) {
      // 首次课表引导早于通知权限页；未授权时暂不调用 iOS 排程接口，
      // 等用户授权后由课表页按同一配置重新建立提醒计划。
      _cancelActiveTimers();
      _courseSignature = null;
      _localCourseEventKeys = const [];
      _localCourseValidUntil = null;
      _localCourseNotifications = const [];
      return;
    }
    // 登录后的推送服务初始化与首次引导可能并行；先等待原生通知插件完成初始化，
    // 避免 iOS 在插件尚未就绪时调用原生排程接口后 Future 永不返回。
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android)) {
      await LocalNotificationService.ensureInitialized();
    }
    _cancelActiveTimers();
    // 原生排程失败时允许同一配置重试，只有成功后才确认签名。
    _courseSignature = null;
    if (!settings.enabled) {
      _localCourseEventKeys = const [];
      _localCourseValidUntil = null;
      _localCourseNotifications = const [];
      await LocalNotificationService.cancelCourseReminders();
      _courseSignature = signature;
      return;
    }

    final now = DateTime.now();
    final slots = buildCourseReminderSlots(
      settings: settings,
      now: now,
      effectiveOccurrences: effectiveOccurrences,
      horizonDays: 14,
    );
    _localCourseEventKeys = [for (final slot in slots) slot.eventKey];
    _localCourseValidUntil = slots.isEmpty
        ? null
        : slots.last.remindAt.add(const Duration(minutes: 2));
    _localCourseNotifications = [
      for (final slot in slots)
        ScheduledLocalNotification(
          id: slot.id,
          scheduledAt: slot.remindAt,
          title: slot.title,
          body: slot.body,
          extras: {
            'id': 'course:${slot.id}',
            'type': 'course_reminder',
            'targetTab': 'schedule',
            'courseName': slot.courseName,
            'location': slot.location,
            'eventKey': slot.eventKey,
          },
        ),
    ];
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      await LocalNotificationService.replaceCourseReminders(
        _localCourseNotifications,
      );
      _courseSignature = signature;
      return;
    }
    for (final slot in slots) {
      final delay = slot.remindAt.difference(now);
      _courseTimers.add(Timer(delay, () async {
        final event = LiveActivityEvent(
          id: slot.id.toString(),
          type: 'course_reminder',
          title: slot.title,
          body: slot.body,
          style: 'progress',
          startTime: slot.remindAt,
          endTime: slot.countdownTarget,
          shortText: '上课',
          targetTab: 'schedule',
          ongoing: true,
          progress: _slotProgress(slot),
          courseName: slot.courseName,
          location: slot.location,
        );
        final extras = {
          'type': 'course_reminder',
          'courseName': slot.courseName,
          'location': slot.location,
        };
        LiveActivityController.instance.show(event);
        final iosPosted = await LiveActivityService.startOrUpdate(event);
        final posted =
            iosPosted || await LiveUpdateService.postEvent(event: event);
        if (!posted) {
          await LocalNotificationService.show(
            id: slot.id,
            title: slot.title,
            body: slot.body,
            extras: extras,
          );
        }
        final cancelDelay = slot.countdownTarget.difference(DateTime.now());
        final notificationId =
            LiveUpdateService.notificationIdForEventId(event.id);
        if (cancelDelay.isNegative) {
          LiveUpdateService.cancelLiveUpdate(id: notificationId);
          unawaited(LiveActivityService.end(event, immediate: false));
        } else {
          _cancelTimers.add(Timer(cancelDelay, () {
            LiveUpdateService.cancelLiveUpdate(id: notificationId);
            unawaited(LiveActivityService.end(event, immediate: false));
          }));
        }
      }));
    }
    _courseSignature = signature;
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
    _localCourseEventKeys = const [];
    _localCourseValidUntil = null;
    _localCourseNotifications = const [];
    unawaited(LocalNotificationService.cancelCourseReminders());
  }

  static Future<void> refreshLocalCourseReminders() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    // 进程重启后内存中的课程列表尚未恢复时，不要把系统已经保存的计划清空。
    // 课表页重新加载课程后会通过 configureCourseReminders 重建计划。
    if (!hasLocalCoursePlan) return;
    await LocalNotificationService.replaceCourseReminders(
      _localCourseNotifications,
    );
  }

  static void _cancelActiveTimers() {
    for (final timer in _courseTimers) {
      timer.cancel();
    }
    _courseTimers.clear();
    for (final timer in _cancelTimers) {
      timer.cancel();
    }
    _cancelTimers.clear();
  }

  /// 只按日期明确的生效课程排程；空列表表示没有课程。
  static List<CourseReminderSlot> buildCourseReminderSlots({
    required CourseReminderSettings settings,
    required DateTime now,
    required List<ScheduleOccurrence> effectiveOccurrences,
    required int horizonDays,
  }) {
    if (!settings.enabled) return const [];
    return _buildEffectiveCourseReminderSlots(
      occurrences: effectiveOccurrences,
      settings: settings,
      now: now,
      horizonDays: horizonDays,
    );
  }

  static String _signature(
    List<ScheduleCourse> courses,
    DateTime firstWeekStart,
    CourseReminderSettings settings,
    List<ScheduleOccurrence> effectiveOccurrences,
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
      effectiveOccurrences
          .map((item) =>
              '${item.occurrenceKey}|${dateText(item.date)}|${item.course.name}|${item.course.startSection}|${item.course.endSection}|${item.course.classroom}|${item.course.teacher}')
          .join(';'),
    ].join('#');
  }

  static List<CourseReminderSlot> _buildEffectiveCourseReminderSlots({
    required List<ScheduleOccurrence> occurrences,
    required CourseReminderSettings settings,
    required DateTime now,
    required int horizonDays,
  }) {
    final endAt = now.add(Duration(days: horizonDays));
    final slots = <CourseReminderSlot>[];
    for (final occurrence in occurrences) {
      final course = occurrence.course;
      final startSection = course.startSection;
      if (startSection == null ||
          startSection < 1 ||
          startSection > scheduleTimes.length ||
          occurrence.date.isBefore(DateTime(now.year, now.month, now.day)) ||
          occurrence.date.isAfter(endAt)) {
        continue;
      }
      final safeEndSection = (course.endSection ?? startSection)
          .clamp(1, scheduleTimes.length)
          .toInt();
      final day = DateTime(
        occurrence.date.year,
        occurrence.date.month,
        occurrence.date.day,
      );
      final classStart = _atTime(day, scheduleTimes[startSection - 1].$1);
      final classEnd = _atTime(day, scheduleTimes[safeEndSection - 1].$2);
      final startReminder =
          classStart.subtract(Duration(minutes: settings.beforeStartMinutes));
      final endReminder =
          classEnd.subtract(Duration(minutes: settings.beforeEndMinutes));
      if (startReminder.isAfter(now) && !startReminder.isAfter(endAt)) {
        slots.add(CourseReminderSlot(
          id: _slotId(occurrence.occurrenceKey, startReminder, 'start'),
          remindAt: startReminder,
          title: '即将上课',
          body: _courseBody(course, classStart,
              prefix: '${settings.beforeStartMinutes} 分钟后'),
          courseName: course.name,
          location: course.classroom,
          countdownTarget: classStart,
          shortCriticalText: '${settings.beforeStartMinutes}min',
          eventKey: _eventKey('start', occurrence.occurrenceKey, startReminder),
        ));
      }
      if (endReminder.isAfter(now) && !endReminder.isAfter(endAt)) {
        slots.add(CourseReminderSlot(
          id: _slotId(occurrence.occurrenceKey, endReminder, 'end'),
          remindAt: endReminder,
          title: '即将下课',
          body: _courseBody(course, classEnd,
              prefix: '${settings.beforeEndMinutes} 分钟后下课'),
          courseName: course.name,
          location: course.classroom,
          countdownTarget: classEnd,
          shortCriticalText: '${settings.beforeEndMinutes}min',
          eventKey: _eventKey('end', occurrence.occurrenceKey, endReminder),
        ));
      }
    }
    slots.sort((a, b) => a.remindAt.compareTo(b.remindAt));
    return slots.take(64).toList();
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

  static int _slotId(String occurrenceKey, DateTime remindAt, String kind) {
    return Object.hash(occurrenceKey, remindAt.millisecondsSinceEpoch, kind)
        .abs();
  }

  static String _eventKey(String kind, String courseName, DateTime remindAt) {
    final date = dateText(remindAt);
    final hour = remindAt.hour.toString().padLeft(2, '0');
    final minute = remindAt.minute.toString().padLeft(2, '0');
    return 'course:$kind:$courseName:$date:$hour:$minute';
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
