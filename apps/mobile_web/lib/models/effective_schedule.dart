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

/// 一对日期之间的节次区间，整日为 1–16 节。
class ScheduleAdjustmentMove {
  const ScheduleAdjustmentMove({
    required this.sourceDate,
    required this.targetDate,
    required this.sourceStart,
    required this.sourceEnd,
    required this.targetStart,
  });
  final DateTime sourceDate;
  final DateTime targetDate;
  final int sourceStart;
  final int sourceEnd;
  final int targetStart;
  int get targetEnd => targetStart + sourceEnd - sourceStart;

  factory ScheduleAdjustmentMove.fromJson(Map<String, dynamic> json) =>
      ScheduleAdjustmentMove(
        sourceDate: DateTime.parse(json['sourceDate'] as String),
        targetDate: DateTime.parse(json['targetDate'] as String),
        sourceStart: json['sourceStart'] as int,
        sourceEnd: json['sourceEnd'] as int,
        targetStart: json['targetStart'] as int,
      );

  Map<String, dynamic> toJson() => {
        'sourceDate': dateText(sourceDate),
        'targetDate': dateText(targetDate),
        'sourceStart': sourceStart,
        'sourceEnd': sourceEnd,
        'targetStart': targetStart,
      };
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
    this.moves,
    this.metadata,
    this.createdAt,
  });

  final AdjustmentMetadata? metadata;
  final DateTime? createdAt;
  final List<ScheduleAdjustmentMove>? moves;
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
      metadata: json['metadata'] == null
          ? null
          : AdjustmentMetadata.fromJson(
              json['metadata'] as Map<String, dynamic>),
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.parse(json['createdAt'] as String),
      moves: (json['moves'] as List?)
          ?.map((item) =>
              ScheduleAdjustmentMove.fromJson(item as Map<String, dynamic>))
          .toList(),
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
        if (metadata != null) 'metadata': metadata!.json,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
        if (moves != null) 'moves': [for (final move in moves!) move.toJson()],
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
    if (adjustment.metadata != null) {
      var next = List<ScheduleOccurrence>.of(result);
      if (adjustment.metadata!.request.schemaVersion == 3) {
        next = applyAdjustmentBatch(
            next, adjustment.metadata!.request.pairs, firstWeekStart);
      } else {
        for (final pair in adjustment.metadata!.request.pairs) {
          next = applyAdjustmentPair(next, pair, firstWeekStart);
        }
      }
      result.clear();
      result.addAll(next);
      continue;
    }
    if (adjustment.moves?.isNotEmpty == true) {
      final next =
          applyScheduleAdjustmentMoves(result, adjustment, firstWeekStart);
      result.clear();
      result.addAll(next);
      continue;
    }
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

/// 区间以原始快照同时计算，拆分连堂课时保留未选中的节次。
List<ScheduleOccurrence> applyScheduleAdjustmentMoves(
  List<ScheduleOccurrence> occurrences,
  ScheduleAdjustmentRecord adjustment,
  DateTime firstWeekStart,
) {
  final result = <ScheduleOccurrence>[];
  for (final item in occurrences) {
    final start = item.course.startSection!;
    final end = item.course.endSection ?? start;
    ScheduleAdjustmentMove? selected;
    var reverse = false;
    for (final move in adjustment.moves!) {
      if (_sameDay(item.date, move.sourceDate)) {
        selected = move;
        break;
      }
      if (_sameDay(item.date, move.targetDate)) {
        selected = move;
        reverse = true;
        break;
      }
    }
    if (selected == null || (reverse && adjustment.conflictMode == 'coexist')) {
      result.add(item);
      continue;
    }
    final from = reverse ? selected.targetStart : selected.sourceStart;
    final to = reverse ? selected.targetEnd : selected.sourceEnd;
    final cutStart = start > from ? start : from;
    final cutEnd = end < to ? end : to;
    if (cutStart > cutEnd) {
      result.add(item);
      continue;
    }
    ScheduleOccurrence segment(int first, int last, DateTime date) {
      final moved = date != item.date;
      final split = first != start || last != end;
      final key =
          split ? '${item.occurrenceKey}:$first-$last' : item.occurrenceKey;
      return ScheduleOccurrence(
        course: item.course.copyWith(
            startSection: first,
            endSection: last,
            weekday: date.weekday,
            isLocal: moved || item.course.isLocal),
        date: date,
        week: weekFromDate(firstWeekStart, date),
        occurrenceKey: moved ? '$key->${dateText(date)}' : key,
        sourceDate: moved ? item.date : item.sourceDate,
      );
    }

    if (start < cutStart) {
      result.add(segment(start, cutStart - 1, item.date));
    }
    if (end > cutEnd) result.add(segment(cutEnd + 1, end, item.date));
    if (!reverse || adjustment.conflictMode == 'swap') {
      final date = reverse ? selected.sourceDate : selected.targetDate;
      final offset = reverse
          ? selected.sourceStart - selected.targetStart
          : selected.targetStart - selected.sourceStart;
      result.add(segment(cutStart + offset, cutEnd + offset, date));
    }
  }
  return result;
}
