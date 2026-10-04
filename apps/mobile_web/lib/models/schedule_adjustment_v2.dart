part of '../api_client.dart';

class AdjustmentPair {
  const AdjustmentPair(
      {required this.sourceDate,
      required this.targetDate,
      required this.sourceStart,
      required this.sourceEnd,
      required this.targetStart,
      required this.sourceKeys,
      required this.action});
  final DateTime sourceDate, targetDate;
  final int sourceStart, sourceEnd, targetStart;
  final List<String> sourceKeys;
  final String action;
  int get targetEnd => targetStart + sourceEnd - sourceStart;
  factory AdjustmentPair.fromJson(Map<String, dynamic> row) {
    final action = row['action'] as String;
    if (!{'move', 'swap', 'replace', 'choose'}.contains(action)) {
      throw const FormatException('调课方式无效');
    }
    return AdjustmentPair(
        sourceDate: DateTime.parse(row['sourceDate'] as String),
        targetDate: DateTime.parse(row['targetDate'] as String),
        sourceStart: row['sourceStart'] as int,
        sourceEnd: row['sourceEnd'] as int,
        targetStart: row['targetStart'] as int,
        sourceKeys: (row['sourceKeys'] as List).cast<String>(),
        action: action);
  }
  String get itemId =>
      sourceKeys.isEmpty ? 'day:${dateText(sourceDate)}' : sourceKeys.join('|');
  Map<String, dynamic> toBatchJson() => {'itemId': itemId, ...toJson()};
  Map<String, dynamic> toJson() => {
        'sourceDate': dateText(sourceDate),
        'targetDate': dateText(targetDate),
        'sourceStart': sourceStart,
        'sourceEnd': sourceEnd,
        'targetStart': targetStart,
        'sourceKeys': sourceKeys,
        'action': action
      };
}

class AdjustmentRequest {
  const AdjustmentRequest(
      {required this.schemaVersion,
      required this.year,
      required this.term,
      required this.firstWeekStart,
      required this.operation,
      required this.pairs});
  final int schemaVersion, year, term;
  final DateTime firstWeekStart;
  final String operation;
  final List<AdjustmentPair> pairs;
  factory AdjustmentRequest.fromJson(Map<String, dynamic> row) {
    if (!{2, 3}.contains(row['schemaVersion']) ||
        !{'course', 'day', 'dayCover', 'partialDay'}
            .contains(row['operation'])) {
      throw const FormatException('调课协议版本或类型无效');
    }
    return AdjustmentRequest(
        schemaVersion: row['schemaVersion'] as int,
        year: row['year'] as int,
        term: row['term'] as int,
        firstWeekStart: DateTime.parse(row['firstWeekStart'] as String),
        operation: row['operation'] as String,
        pairs: [
          for (final p in row['pairs'] as List)
            AdjustmentPair.fromJson(p as Map<String, dynamic>)
        ]);
  }
  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'year': year,
        'term': term,
        'firstWeekStart': dateText(firstWeekStart),
        'operation': operation,
        'pairs': [
          for (final p in pairs)
            schemaVersion == 3 ? p.toBatchJson() : p.toJson()
        ]
      };
}

ScheduleOccurrence occurrenceFromJson(Map<String, dynamic> row) =>
    ScheduleOccurrence(
        course: ScheduleCourse.fromJson({...row, 'weeks': '${row['week']}'}),
        date: DateTime.parse(row['date'] as String),
        week: row['week'] as int,
        occurrenceKey: row['itemKey'] as String);
List<ScheduleOccurrence> occurrencesFromJson(Object? rows) => [
      for (final row in rows as List)
        occurrenceFromJson(row as Map<String, dynamic>)
    ];

class AdjustmentPairPreview {
  const AdjustmentPairPreview(
      {required this.pair,
      required this.before,
      required this.after,
      required this.conflicts,
      required this.labels});
  final AdjustmentPair pair;
  final List<ScheduleOccurrence> before, after, conflicts;
  final List<String> labels;
  factory AdjustmentPairPreview.fromJson(Map<String, dynamic> row) =>
      AdjustmentPairPreview(
          pair: AdjustmentPair.fromJson(row['pair'] as Map<String, dynamic>),
          before: occurrencesFromJson(row['before']),
          after: occurrencesFromJson(row['after']),
          conflicts: occurrencesFromJson(row['conflicts']),
          labels: (row['labels'] as List).cast<String>());
}

class AdjustmentPreview {
  const AdjustmentPreview(
      {required this.fingerprint,
      required this.ready,
      required this.pairs,
      required this.affectedCount,
      required this.batchConflicts,
      required this.before,
      required this.after});
  final String fingerprint;
  final bool ready;
  final int affectedCount;
  final List<AdjustmentPairPreview> pairs;
  final List<String> batchConflicts;
  final List<ScheduleOccurrence> before, after;
  factory AdjustmentPreview.fromJson(Map<String, dynamic> row) =>
      AdjustmentPreview(
          fingerprint: row['fingerprint'] as String,
          ready: row['ready'] as bool,
          affectedCount: row['affectedCount'] as int,
          batchConflicts: [
            for (final c in (row['batchConflicts'] as List? ?? []))
              '${(c as Map<String, dynamic>)["message"]}：${occurrencesFromJson(c["courses"]).map((o) => '${o.course.name} ${dateText(o.date)} ${o.course.startSection}–${o.course.endSection}节').join('；')}'
          ],
          before: occurrencesFromJson(row['before'] ?? []),
          after: occurrencesFromJson(row['after'] ?? []),
          pairs: [
            for (final p in row['pairs'] as List)
              AdjustmentPairPreview.fromJson(p as Map<String, dynamic>)
          ]);
}

class AdjustmentMetadata {
  const AdjustmentMetadata(
      {required this.request, required this.preview, required this.json});
  final AdjustmentRequest request;
  final AdjustmentPreview preview;
  final Map<String, dynamic> json;
  factory AdjustmentMetadata.fromJson(Map<String, dynamic> row) =>
      AdjustmentMetadata(
          request: AdjustmentRequest.fromJson(
              row['request'] as Map<String, dynamic>),
          preview: AdjustmentPreview.fromJson(
              row['preview'] as Map<String, dynamic>),
          json: row);
}

class AdjustmentRestorePreview {
  const AdjustmentRestorePreview(
      {required this.fingerprint,
      required this.blockers,
      required this.before,
      required this.after});
  final String fingerprint;
  final List<String> blockers;
  final List<ScheduleOccurrence> before, after;
  factory AdjustmentRestorePreview.fromJson(Map<String, dynamic> row) =>
      AdjustmentRestorePreview(
          fingerprint: row['fingerprint'] as String,
          blockers: (row['blockers'] as List).cast<String>(),
          before: occurrencesFromJson(row['before']),
          after: occurrencesFromJson(row['after']));
}

List<ScheduleOccurrence> applyAdjustmentPair(List<ScheduleOccurrence> items,
    AdjustmentPair pair, DateTime firstWeekStart) {
  final result = <ScheduleOccurrence>[];
  for (final item in items) {
    final start = item.course.startSection!;
    final end = item.course.endSection ?? start;
    var source = _sameDay(item.date, pair.sourceDate) &&
        start <= pair.sourceEnd &&
        pair.sourceStart <= end;
    final target = _sameDay(item.date, pair.targetDate) &&
        start <= pair.targetEnd &&
        pair.targetStart <= end;
    if (source &&
        pair.action != 'swap' &&
        !pair.sourceKeys.contains(item.occurrenceKey)) {
      source = false;
    }
    if ((!source && !target) ||
        (target && {'move', 'choose'}.contains(pair.action))) {
      result.add(item);
      continue;
    }
    final first = source ? pair.sourceStart : pair.targetStart;
    final last = source ? pair.sourceEnd : pair.targetEnd;
    final cutStart = start > first ? start : first;
    final cutEnd = end < last ? end : last;
    ScheduleOccurrence segment(int a, int b, DateTime date) {
      final moved = !_sameDay(date, item.date);
      final key = a != start || b != end
          ? '${item.occurrenceKey}:$a-$b'
          : item.occurrenceKey;
      return ScheduleOccurrence(
          course: item.course.copyWith(
              startSection: a,
              endSection: b,
              weekday: date.weekday,
              isLocal: moved || a != start || b != end || item.course.isLocal),
          date: date,
          week: weekFromDate(firstWeekStart, date),
          occurrenceKey: moved ? '$key->${dateText(date)}' : key,
          sourceDate:
              moved || a != start || b != end ? item.date : item.sourceDate);
    }

    if (start < cutStart) result.add(segment(start, cutStart - 1, item.date));
    if (end > cutEnd) result.add(segment(cutEnd + 1, end, item.date));
    if (source || pair.action == 'swap') {
      final offset = source
          ? pair.targetStart - pair.sourceStart
          : pair.sourceStart - pair.targetStart;
      result.add(segment(cutStart + offset, cutEnd + offset,
          source ? pair.targetDate : pair.sourceDate));
    }
  }
  return result;
}

/// 给课程详情携带精确实例身份，避免周历翻页后仍预选原来的周次。
ScheduleCourse courseForOccurrence(ScheduleOccurrence occurrence) =>
    occurrence.course.copyWith(raw: {
      ...occurrence.course.raw,
      'effectiveOccurrenceKey': occurrence.occurrenceKey,
      'effectiveDate': dateText(occurrence.date)
    });

/// 将生效实例按位置归并；全部课程展示真实剩余周次与调后位置。
List<ScheduleCourse> groupScheduleOccurrences(
    List<ScheduleOccurrence> occurrences) {
  final groups = <String, List<ScheduleOccurrence>>{};
  for (final item in occurrences) {
    final course = item.course;
    final key = jsonEncode([
      course.raw['courseId'] ??
          course.raw['kch_id'] ??
          course.raw['kch'] ??
          course.name,
      course.name,
      course.teacher,
      course.classroom,
      course.weekday,
      course.startSection,
      course.endSection
    ]);
    groups.putIfAbsent(key, () => []).add(item);
  }
  return [
    for (final rows in groups.values)
      rows.first.course.copyWith(
          weeks: (rows.map((o) => o.week).toSet().toList()..sort()).join(','),
          isLocal: rows.any((o) => o.isAdjusted || o.course.isLocal))
  ];
}

/// V3 从同一快照按实例节次合并变更，不让后续项读到前一项的结果。
List<ScheduleOccurrence> applyAdjustmentBatch(List<ScheduleOccurrence> items,
    List<AdjustmentPair> pairs, DateTime firstWeekStart) {
  final removed = <String, Set<int>>{};
  final moved = <ScheduleOccurrence>[];
  ScheduleOccurrence segment(
      ScheduleOccurrence o, int a, int b, DateTime date) {
    final start = o.course.startSection!, end = o.course.endSection ?? start;
    final split = a != start || b != end;
    final differentDay = !_sameDay(date, o.date);
    final key = split ? '${o.occurrenceKey}:$a-$b' : o.occurrenceKey;
    return ScheduleOccurrence(
        course: o.course.copyWith(
            startSection: a,
            endSection: b,
            weekday: date.weekday,
            isLocal: split || differentDay || o.course.isLocal),
        date: date,
        week: weekFromDate(firstWeekStart, date),
        occurrenceKey: differentDay ? '$key->${dateText(date)}' : key,
        sourceDate: split || differentDay ? o.date : o.sourceDate);
  }

  for (final p in pairs) {
    for (final o in items) {
      final start = o.course.startSection!, end = o.course.endSection ?? start;
      final source = _sameDay(o.date, p.sourceDate) &&
          start <= p.sourceEnd &&
          p.sourceStart <= end &&
          (p.action == 'swap' || p.sourceKeys.contains(o.occurrenceKey));
      final target = _sameDay(o.date, p.targetDate) &&
          start <= p.targetEnd &&
          p.targetStart <= end &&
          {'swap', 'replace'}.contains(p.action);
      if (!source && !target) continue;
      final first = source ? p.sourceStart : p.targetStart,
          last = source ? p.sourceEnd : p.targetEnd;
      final a = start > first ? start : first, b = end < last ? end : last;
      removed
          .putIfAbsent(o.occurrenceKey, () => {})
          .addAll([for (var s = a; s <= b; s++) s]);
      if (source || p.action == 'swap') {
        final offset = source
            ? p.targetStart - p.sourceStart
            : p.sourceStart - p.targetStart;
        moved.add(segment(
            o, a + offset, b + offset, source ? p.targetDate : p.sourceDate));
      }
    }
  }
  final result = <ScheduleOccurrence>[...moved];
  for (final o in items) {
    final sections = removed[o.occurrenceKey];
    if (sections == null) {
      result.add(o);
      continue;
    }
    final end = o.course.endSection ?? o.course.startSection!;
    int? first;
    for (var s = o.course.startSection!; s <= end + 1; s++) {
      if (s <= end && !sections.contains(s)) {
        first ??= s;
      } else if (first != null) {
        result.add(segment(o, first, s - 1, o.date));
        first = null;
      }
    }
  }
  return result;
}
