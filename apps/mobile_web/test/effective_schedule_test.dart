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
  test('多日单节交换拆分连堂课，JSON 云端往返及撤销保持一致', () {
    final math = course(name: '数学', weekday: 1).copyWith(weeks: '1,3');
    final english = course(name: '英语', weekday: 2).copyWith(weeks: '2');
    final record = ScheduleAdjustmentRecord(
      clientId: 'batch',
      year: 2026,
      term: 1,
      sourceDate: DateTime(2026, 9, 7),
      targetDate: DateTime(2026, 9, 15),
      sourceOccurrenceKeys: const [],
      targetConflictKeys: const [],
      conflictMode: 'swap',
      status: 'active',
      revision: 1,
      moves: [
        ScheduleAdjustmentMove(
            sourceDate: DateTime(2026, 9, 7),
            targetDate: DateTime(2026, 9, 15),
            sourceStart: 2,
            sourceEnd: 2,
            targetStart: 1),
        ScheduleAdjustmentMove(
            sourceDate: DateTime(2026, 9, 21),
            targetDate: DateTime(2026, 9, 29),
            sourceStart: 2,
            sourceEnd: 2,
            targetStart: 1),
      ],
    );
    final synced = ScheduleAdjustmentRecord.fromJson(record.toJson());
    final result = expandEffectiveSchedule(
        courses: [math, english],
        firstWeekStart: firstWeek,
        adjustments: [synced]);
    final selected = result.where((item) =>
        [DateTime(2026, 9, 7), DateTime(2026, 9, 15)].contains(item.date));
    expect(
        selected
            .map((item) =>
                '${item.date.day}:${item.course.name}:${item.course.startSection}-${item.course.endSection}')
            .toSet(),
        {'7:数学:1-1', '7:英语:2-2', '15:数学:1-1', '15:英语:2-2'});
    expect(
        result.any((item) =>
            item.date == DateTime(2026, 9, 29) && item.course.name == '数学'),
        isTrue);
    final restored = ScheduleAdjustmentRecord.fromJson(
        {...record.toJson(), 'status': 'restored', 'revision': 2});
    final original = expandEffectiveSchedule(
        courses: [math, english],
        firstWeekStart: firstWeek,
        adjustments: [restored]);
    expect(original, hasLength(3));
    expect(
        original.every((item) =>
            item.course.startSection == 1 && item.course.endSection == 2),
        isTrue);
  });
}
