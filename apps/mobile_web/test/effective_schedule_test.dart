import 'package:flutter_test/flutter_test.dart';

import 'package:gzus_pro_mobile_web/api_client.dart';

void main() {
  final firstWeek = DateTime(2026, 9, 7);

  ScheduleCourse course({required String name, required int weekday}) {
    return ScheduleCourse(
      name: name,
      weekday: weekday,
      startSection: 1,
      endSection: 2,
      weeks: '1',
      raw: {'kch': name},
    );
  }

  test('日期级调课移除源日并在目标日生成具体实例', () {
    final source = course(name: '高等数学', weekday: 1);
    final sourceDate = DateTime(2026, 9, 7);
    final targetDate = DateTime(2026, 9, 12);
    final adjustment = ScheduleAdjustmentRecord(
      clientId: 'move-1',
      year: 2026,
      term: 1,
      sourceDate: sourceDate,
      targetDate: targetDate,
      sourceOccurrenceKeys: [scheduleOccurrenceKey(source, sourceDate)],
      targetConflictKeys: const [],
      conflictMode: 'coexist',
      status: 'active',
      revision: 1,
    );

    final result = expandEffectiveSchedule(
      courses: [source],
      firstWeekStart: firstWeek,
      adjustments: [adjustment],
      startDate: sourceDate,
      endDate: targetDate,
    );

    expect(result, hasLength(1));
    expect(result.single.date, targetDate);
    expect(result.single.course.name, '高等数学');
    expect(result.single.course.weekday, DateTime.saturday);
    expect(result.single.isAdjusted, isTrue);
  });

  test('替换冲突只移除目标日重叠实例', () {
    final moved = course(name: '高等数学', weekday: 1);
    final existing = course(name: '大学英语', weekday: 6);
    final sourceDate = DateTime(2026, 9, 7);
    final targetDate = DateTime(2026, 9, 12);
    final adjustment = ScheduleAdjustmentRecord(
      clientId: 'move-2',
      year: 2026,
      term: 1,
      sourceDate: sourceDate,
      targetDate: targetDate,
      sourceOccurrenceKeys: [scheduleOccurrenceKey(moved, sourceDate)],
      targetConflictKeys: [scheduleOccurrenceKey(existing, targetDate)],
      conflictMode: 'replaceConflicts',
      status: 'active',
      revision: 1,
    );

    final result = expandEffectiveSchedule(
      courses: [moved, existing],
      firstWeekStart: firstWeek,
      adjustments: [adjustment],
      startDate: sourceDate,
      endDate: targetDate,
    );

    expect(result, hasLength(1));
    expect(result.single.course.name, '高等数学');
    expect(result.single.date, targetDate);
  });

  test('还原记录保持原始周课表', () {
    final source = course(name: '高等数学', weekday: 1);
    final sourceDate = DateTime(2026, 9, 7);
    final adjustment = ScheduleAdjustmentRecord(
      clientId: 'move-3',
      year: 2026,
      term: 1,
      sourceDate: sourceDate,
      targetDate: DateTime(2026, 9, 12),
      sourceOccurrenceKeys: [scheduleOccurrenceKey(source, sourceDate)],
      targetConflictKeys: const [],
      conflictMode: 'coexist',
      status: 'restored',
      revision: 2,
    );

    final result = expandEffectiveSchedule(
      courses: [source],
      firstWeekStart: firstWeek,
      adjustments: [adjustment],
      startDate: sourceDate,
      endDate: sourceDate,
    );

    expect(result, hasLength(1));
    expect(result.single.date, sourceDate);
    expect(result.single.course.name, '高等数学');
  });
}
