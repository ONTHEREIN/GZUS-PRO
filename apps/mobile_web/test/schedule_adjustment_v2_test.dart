import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';

void main() {
  final first = DateTime(2026, 9, 7);
  final courses = [
    ScheduleCourse(
        name: '数学',
        teacher: '甲',
        classroom: '101',
        weekday: 1,
        startSection: 3,
        endSection: 4,
        weeks: '1',
        raw: const {'kch': 'M'}),
    ScheduleCourse(
        name: '重叠课程',
        teacher: '乙',
        classroom: '102',
        weekday: 1,
        startSection: 4,
        endSection: 4,
        weeks: '1',
        raw: const {'kch': 'O'}),
    ScheduleCourse(
        name: '英语',
        teacher: '丙',
        classroom: '103',
        weekday: 1,
        startSection: 7,
        endSection: 9,
        weeks: '1',
        raw: const {'kch': 'E'}),
  ];
  final items = expandEffectiveSchedule(
      courses: courses, firstWeekStart: first, adjustments: const []);
  AdjustmentPair pair(String action) => AdjustmentPair(
      sourceDate: first,
      targetDate: first,
      sourceStart: 4,
      sourceEnd: 4,
      targetStart: 8,
      sourceKeys: [
        items.firstWhere((o) => o.course.name == '数学').occurrenceKey
      ],
      action: action);
  Set<String> positions(List<ScheduleOccurrence> rows) => rows
      .map((o) =>
          '${o.course.name}:${o.course.startSection}-${o.course.endSection}')
      .toSet();

  test('Flutter 同日部分覆盖与服务端集成测试结果一致', () {
    final result = applyAdjustmentPair(items, pair('replace'), first);
    expect(positions(result),
        {'数学:3-3', '数学:8-8', '重叠课程:4-4', '英语:7-7', '英语:9-9'});
  });
  test('Flutter 区间交换全部重叠课程且保持实例标识与服务端一致', () {
    final result = applyAdjustmentPair(items, pair('swap'), first);
    expect(positions(result),
        {'数学:3-3', '数学:8-8', '重叠课程:8-8', '英语:7-7', '英语:9-9', '英语:4-4'});
    expect(
        result
            .firstWhere(
                (o) => o.course.name == '数学' && o.course.startSection == 8)
            .occurrenceKey,
        '${items.firstWhere((o) => o.course.name == '数学').occurrenceKey}:8-8');
  });
  test('V3 重叠来源独立移动且结果不依赖提交顺序', () {
    final selected = items.where((o) => o.course.name != '英语').toList();
    final pairs = [
      for (final o in selected)
        AdjustmentPair(
            sourceDate: first,
            targetDate: DateTime(2026, 9, 8),
            sourceStart: o.course.startSection!,
            sourceEnd: o.course.endSection!,
            targetStart: o.course.name == '数学' ? 1 : 5,
            sourceKeys: [o.occurrenceKey],
            action: 'move')
    ];
    final a = applyAdjustmentBatch(items, pairs, first);
    final b = applyAdjustmentBatch(items, pairs.reversed.toList(), first);
    expect(positions(a), {'数学:1-2', '重叠课程:5-5', '英语:7-9'});
    expect(a.map((o) => o.occurrenceKey).toSet(),
        b.map((o) => o.occurrenceKey).toSet());
    expect(items.first.course.startSection, 3);
  });
  test('V3 部分覆盖结果及拆分身份与服务端一致', () {
    final result = applyAdjustmentBatch(items, [pair('replace')], first);
    expect(positions(result),
        {'数学:3-3', '数学:8-8', '重叠课程:4-4', '英语:7-7', '英语:9-9'});
    expect(
        result
            .firstWhere(
                (o) => o.course.name == '数学' && o.course.startSection == 8)
            .occurrenceKey,
        '${items.first.occurrenceKey}:8-8');
  });
}
