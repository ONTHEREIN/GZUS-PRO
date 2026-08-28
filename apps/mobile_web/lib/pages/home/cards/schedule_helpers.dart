import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../../schedule_utils.dart';

/// 带起止时间的课程。
class TimedCourse {
  const TimedCourse({
    required this.course,
    required this.start,
    required this.end,
  });

  final ScheduleCourse course;
  final DateTime start;
  final DateTime end;

  String get timeText =>
      '${_two(start.hour)}:${_two(start.minute)}-${_two(end.hour)}:${_two(end.minute)}';

  bool get isOngoing {
    final now = DateTime.now();
    return !now.isBefore(start) && now.isBefore(end);
  }
}

List<TimedCourse> homeTimedCourses(
  List<ScheduleCourse> courses, {
  required int currentWeek,
  required DateTime firstWeekStart,
}) {
  final result = <TimedCourse>[];
  for (final course in courses) {
    final weekday = course.weekday;
    final startSection = course.startSection;
    final endSection = course.endSection ?? startSection;
    if (weekday == null ||
        startSection == null ||
        endSection == null ||
        weekday < 1 ||
        weekday > 7 ||
        startSection < 1 ||
        endSection < 1 ||
        startSection > scheduleTimes.length ||
        endSection > scheduleTimes.length ||
        !course.occursInWeek(currentWeek)) {
      continue;
    }
    final day =
        firstWeekStart.add(Duration(days: (currentWeek - 1) * 7 + weekday - 1));
    final startTime = _timeParts(scheduleTimes[startSection - 1].$1);
    final endTime = _timeParts(scheduleTimes[endSection - 1].$2);
    result.add(TimedCourse(
      course: course,
      start: DateTime(
        day.year,
        day.month,
        day.day,
        startTime.$1,
        startTime.$2,
      ),
      end: DateTime(
        day.year,
        day.month,
        day.day,
        endTime.$1,
        endTime.$2,
      ),
    ));
  }
  result.sort((a, b) => a.start.compareTo(b.start));
  return result;
}

List<TimedCourse> todayTimedCourses(List<TimedCourse> courses) {
  final now = DateTime.now();
  return courses
      .where((item) =>
          item.start.year == now.year &&
          item.start.month == now.month &&
          item.start.day == now.day)
      .toList();
}

TimedCourse? nextTimedCourse(List<TimedCourse> courses) {
  final now = DateTime.now();
  final current = courses.where(
    (item) => !now.isBefore(item.start) && now.isBefore(item.end),
  );
  if (current.isNotEmpty) return current.first;
  final upcoming = courses.where((item) => item.start.isAfter(now));
  return upcoming.isEmpty ? null : upcoming.first;
}

String _two(int value) => value.toString().padLeft(2, '0');

(int, int) _timeParts(String value) {
  final parts = value.split(':');
  return (
    parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0,
    parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
  );
}

Color homeCourseColor(String name, Brightness brightness) {
  const lightPalette = [
    Color(0xFF6750A4),
    Color(0xFF386A20),
    Color(0xFF0061A4),
    Color(0xFF7D5260),
    Color(0xFF9B3D2D),
    Color(0xFF006C67),
  ];
  const darkPalette = [
    Color(0xFF9A82DB),
    Color(0xFF6DA65A),
    Color(0xFF4FA3D1),
    Color(0xFFB87A8E),
    Color(0xFFD47A68),
    Color(0xFF4DB6AC),
  ];
  final palette = brightness == Brightness.dark ? darkPalette : lightPalette;
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = (hash + unit) % palette.length;
  }
  return palette[hash];
}

T? firstOrNull<T>(Iterable<T> values) {
  final iterator = values.iterator;
  return iterator.moveNext() ? iterator.current : null;
}
