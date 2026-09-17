part of '../api_client.dart';

/// 一条带具体日期的生效课程实例。课表、请假、提醒和日历都应消费此模型，
/// 避免调课后继续按原星期匹配。
class ScheduleOccurrence {
  const ScheduleOccurrence({
    required this.course,
    required this.date,
    required this.week,
    required this.occurrenceKey,
    this.sourceDate,
  });

  final ScheduleCourse course;
  final DateTime date;
  final int week;
  final String occurrenceKey;
  final DateTime? sourceDate;

  bool get isAdjusted => sourceDate != null;
}

/// 账号同步的日期级整日调课记录。
class ScheduleAdjustmentRecord {
  const ScheduleAdjustmentRecord({
    required this.clientId,
    required this.year,
    required this.term,
    required this.sourceDate,
    required this.targetDate,
    required this.sourceOccurrenceKeys,
    required this.targetConflictKeys,
    required this.conflictMode,
    required this.status,
    required this.revision,
    this.id,
  });

  final String clientId;
  final int year;
  final int term;
  final DateTime sourceDate;
  final DateTime targetDate;
  final List<String> sourceOccurrenceKeys;
  final List<String> targetConflictKeys;
  final String conflictMode;
  final String status;
  final int revision;
  final int? id;

  bool get isActive => status == 'active';

  factory ScheduleAdjustmentRecord.fromJson(Map<String, dynamic> json) {
    DateTime parseDate(Object? value) {
      final parsed = DateTime.tryParse(value?.toString() ?? '');
      if (parsed == null) throw FormatException('调课日期无效: $value');
      return DateTime(parsed.year, parsed.month, parsed.day);
    }

    List<String> strings(Object? value) {
      if (value is! List) return const [];
      return [for (final item in value) item.toString()];
    }

    return ScheduleAdjustmentRecord(
      clientId: json['clientId']?.toString() ?? '',
      year: (json['year'] as num?)?.toInt() ?? 0,
      term: (json['term'] as num?)?.toInt() ?? 0,
      sourceDate: parseDate(json['sourceDate']),
      targetDate: parseDate(json['targetDate']),
      sourceOccurrenceKeys: strings(json['sourceOccurrenceKeys']),
      targetConflictKeys: strings(json['targetConflictKeys']),
      conflictMode: json['conflictMode']?.toString() ?? 'coexist',
      status: json['status']?.toString() ?? 'active',
      revision: (json['revision'] as num?)?.toInt() ?? 1,
      id: (json['id'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'year': year,
        'term': term,
        'sourceDate': dateText(sourceDate),
        'targetDate': dateText(targetDate),
        'sourceOccurrenceKeys': sourceOccurrenceKeys,
        'targetConflictKeys': targetConflictKeys,
        'conflictMode': conflictMode,
        'status': status,
        'revision': revision,
        if (id != null) 'id': id,
      };
}

String scheduleOccurrenceKey(ScheduleCourse course, DateTime date) {
  final rawId = course.raw['courseId'] ??
      course.raw['kch_id'] ??
      course.raw['kch'] ??
      course.name;
  final identity = [
    rawId,
    course.startSection,
    course.endSection,
    course.teacher ?? '',
    course.classroom ?? '',
  ].join(':');
  return 'course:${dateText(date)}:$identity';
}

/// 展开原始周课表，并应用旧版本地规则和日期级整日调课。
List<ScheduleOccurrence> expandEffectiveSchedule({
  required List<ScheduleCourse> courses,
  required DateTime firstWeekStart,
  required List<ScheduleAdjustmentRecord> adjustments,
  List<ScheduleOverride> overrides = const [],
  DateTime? startDate,
  DateTime? endDate,
  int maxWeeks = 30,
}) {
  final normalized = applyScheduleOverrides(courses, overrides);
  final base = <ScheduleOccurrence>[];
  for (var week = 1; week <= maxWeeks; week++) {
    final monday = mondayOf(firstWeekStart).add(Duration(days: (week - 1) * 7));
    for (final original in normalized) {
      final weekday = original.weekday;
      final start = original.startSection;
      if (weekday == null || weekday < 1 || weekday > 7 || start == null) {
        continue;
      }
      if (!original.occursInWeek(week) ||
          isHiddenByOverrides(original, overrides, currentWeek: week)) {
        continue;
      }
      final date = monday.add(Duration(days: weekday - 1));
      base.add(
        ScheduleOccurrence(
          course: original,
          date: DateTime(date.year, date.month, date.day),
          week: week,
          occurrenceKey: scheduleOccurrenceKey(original, date),
        ),
      );
    }
  }

  final result = [...base];
  for (final adjustment in adjustments.where((item) => item.isActive)) {
    final moved = result
        .where((item) =>
            _sameDay(item.date, adjustment.sourceDate) &&
            (adjustment.sourceOccurrenceKeys.isEmpty ||
                adjustment.sourceOccurrenceKeys.contains(item.occurrenceKey)))
        .toList();
    if (moved.isEmpty) continue;
    result.removeWhere((item) => moved.contains(item));
    for (final item in moved) {
      final targetDate = adjustment.targetDate;
      final targetWeek = weekFromDate(firstWeekStart, targetDate);
      final targetCourse =
          item.course.copyWith(weekday: targetDate.weekday, isLocal: true);
      final movedOccurrence = ScheduleOccurrence(
        course: targetCourse,
        date: targetDate,
        week: targetWeek,
        occurrenceKey: '${item.occurrenceKey}->${dateText(targetDate)}',
        sourceDate: adjustment.sourceDate,
      );
      if (adjustment.conflictMode == 'replaceConflicts') {
        result.removeWhere((candidate) {
          if (!_sameDay(candidate.date, targetDate)) return false;
          if (adjustment.targetConflictKeys.isNotEmpty) {
            return adjustment.targetConflictKeys
                .contains(candidate.occurrenceKey);
          }
          return _sectionsOverlap(candidate.course, targetCourse);
        });
      }
      result.add(movedOccurrence);
    }
  }

  result.sort((a, b) {
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    return (a.course.startSection ?? 0).compareTo(b.course.startSection ?? 0);
  });
  return result.where((item) {
    final start = startDate == null ? true : !_dayBefore(item.date, startDate);
    final end = endDate == null ? true : !_dayAfter(item.date, endDate);
    return start && end;
  }).toList();
}

List<ScheduleOccurrence> effectiveOccurrencesForWeek({
  required List<ScheduleCourse> courses,
  required DateTime firstWeekStart,
  required int week,
  required List<ScheduleAdjustmentRecord> adjustments,
  List<ScheduleOverride> overrides = const [],
}) {
  final monday = mondayOf(firstWeekStart).add(Duration(days: (week - 1) * 7));
  return expandEffectiveSchedule(
    courses: courses,
    firstWeekStart: firstWeekStart,
    adjustments: adjustments,
    overrides: overrides,
    startDate: monday,
    endDate: monday.add(const Duration(days: 6)),
  );
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

bool _dayBefore(DateTime a, DateTime b) =>
    DateTime(a.year, a.month, a.day).isBefore(DateTime(b.year, b.month, b.day));

bool _dayAfter(DateTime a, DateTime b) =>
    DateTime(a.year, a.month, a.day).isAfter(DateTime(b.year, b.month, b.day));

bool _sectionsOverlap(ScheduleCourse a, ScheduleCourse b) {
  final aStart = a.startSection ?? 0;
  final aEnd = a.endSection ?? aStart;
  final bStart = b.startSection ?? 0;
  final bEnd = b.endSection ?? bStart;
  return aStart <= bEnd && bStart <= aEnd;
}
