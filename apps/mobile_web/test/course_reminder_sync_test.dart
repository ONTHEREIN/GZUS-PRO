import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';
import 'package:gzus_pro_mobile_web/course_reminder_sync.dart';
import 'package:gzus_pro_mobile_web/models/schedule_override.dart';
import 'package:gzus_pro_mobile_web/reminder_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final firstWeek = DateTime(2026, 9, 7);
  final course = ScheduleCourse.fromJson({
    'name': '高等数学',
    'weekday': 1,
    'startSection': 1,
    'endSection': 2,
    'weeks': '1',
  });

  test('停课产生的空生效列表不再排入原始课程提醒', () {
    final occurrences = expandEffectiveSchedule(
      courses: [course],
      firstWeekStart: firstWeek,
      adjustments: const [],
      overrides: const [
        ScheduleOverride(id: 'hide', matchKey: 'name:高等数学', hidden: true),
      ],
    );
    expect(occurrences, isEmpty);
    final slots = ReminderService.buildCourseReminderSlots(
      settings: const CourseReminderSettings(enabled: true),
      now: DateTime(2026, 9, 7, 8),
      effectiveOccurrences: occurrences,
      horizonDays: 14,
    );
    expect(slots, isEmpty);
  });

  test('跨周调课只在目标日期排入上下课提醒', () {
    final target = DateTime(2026, 9, 14);
    final occurrences = expandEffectiveSchedule(
      courses: [course],
      firstWeekStart: firstWeek,
      adjustments: [
        ScheduleAdjustmentRecord(
          clientId: 'move',
          year: 2026,
          term: 1,
          sourceDate: firstWeek,
          targetDate: target,
          sourceOccurrenceKeys: const [],
          targetConflictKeys: const [],
          conflictMode: 'coexist',
          status: 'active',
          revision: 1,
        ),
      ],
    );
    final slots = ReminderService.buildCourseReminderSlots(
      settings: const CourseReminderSettings(enabled: true),
      now: DateTime(2026, 9, 7, 8),
      effectiveOccurrences: occurrences,
      horizonDays: 14,
    );
    expect(slots.map((slot) => slot.when), [
      DateTime(2026, 9, 14, 8, 50),
      DateTime(2026, 9, 14, 10, 15),
    ]);
  });

  test('Android 原生排程失败明确报错，重试仍发送空生效列表', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('cn.gzus.pro/background_service');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      expect(call.method, 'updateCourseReminders');
      final arguments = call.arguments as Map<Object?, Object?>;
      expect(arguments['effectiveOccurrencesJson'], '[]');
      if (calls == 1) {
        throw PlatformException(code: 'SCHEDULE_FAILED', message: '排程失败');
      }
      return true;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    Future<String> sync() => syncCourseRemindersToNative(
          courses: [course],
          beforeStartMinutes: 10,
          beforeEndMinutes: 5,
          firstWeekStart: firstWeek,
          effectiveOccurrences: const [],
          previousSignature: null,
        );
    await expectLater(sync(), throwsA(isA<PlatformException>()));
    expect(await sync(), isNotEmpty);
    expect(calls, 2);
  });

  test('同名同节次但不同教室的生效课程不会互相覆盖提醒', () {
    final occurrences = expandEffectiveSchedule(
      courses: [
        course.copyWith(classroom: 'A101'),
        course.copyWith(classroom: 'B202'),
      ],
      firstWeekStart: firstWeek,
      adjustments: const [],
    );
    final slots = ReminderService.buildCourseReminderSlots(
      settings: const CourseReminderSettings(enabled: true),
      now: DateTime(2026, 9, 7, 8),
      effectiveOccurrences: occurrences,
      horizonDays: 1,
    );
    expect(slots, hasLength(4));
    expect(slots.map((slot) => slot.id).toSet(), hasLength(4));
    expect(slots.map((slot) => slot.eventKey).toSet(), hasLength(4));
  });
}
