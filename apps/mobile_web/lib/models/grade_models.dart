import 'package:flutter/material.dart';

import '../api_client.dart';

class GradeAttempt {
  const GradeAttempt(this.period, this.grade);

  final AcademicPeriod period;
  final GradeItem grade;
}

class GradeGroup {
  GradeGroup(GradeAttempt first) : attempts = [first];

  final List<GradeAttempt> attempts;

  GradeAttempt get first => attempts.first;
  GradeAttempt get latest => attempts.last;
  bool get hasRetake => attempts.length > 1;
  String get displayName => hasRetake && !first.grade.courseName.contains('补')
      ? '${first.grade.courseName}（补）'
      : first.grade.courseName;
}

/// 归一化课程名（去空格、去补考标记），用于成绩/考试分组与高亮匹配。
String courseKey(String value) => value
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll('（补）', '')
    .replaceAll('(补)', '')
    .trim();

/// 学年学期列表的签名，用于判断成绩/考试周期是否变化。
String periodSignature(List<AcademicPeriod> periods) =>
    periods.map((period) => '${period.year}:${period.term}').join('|');

bool hasRetakeText(String? value) => value?.contains('补') ?? false;

Color retakeFill(int index) {
  final alpha = (0.10 + index * 0.04).clamp(0.12, 0.26).toDouble();
  return Colors.red.withValues(alpha: alpha);
}

Color retakeText(int index) => index >= 2 ? Colors.red.shade800 : Colors.red;

int periodSortValue(AcademicPeriod period) => period.year * 10 + period.term;

DateTime? examDateTime(String? value) {
  final text = value ?? '';
  final match = RegExp(
    r'(\d{4})[-/年.](\d{1,2})[-/月.](\d{1,2})(?:日)?(?:\s+(\d{1,2}):(\d{1,2}))?',
  ).firstMatch(text);
  if (match == null) return null;
  final year = int.tryParse(match.group(1)!);
  final month = int.tryParse(match.group(2)!);
  final day = int.tryParse(match.group(3)!);
  final hour = int.tryParse(match.group(4) ?? '0') ?? 0;
  final minute = int.tryParse(match.group(5) ?? '0') ?? 0;
  if (year == null || month == null || day == null) return null;
  return DateTime(year, month, day, hour, minute);
}

int compareExamsByTime(PeriodExam a, PeriodExam b) {
  final aTime = examDateTime(a.exam.time);
  final bTime = examDateTime(b.exam.time);
  if (aTime != null && bTime != null) return bTime.compareTo(aTime);
  if (aTime != null) return -1;
  if (bTime != null) return 1;
  final periodCompare =
      periodSortValue(a.period).compareTo(periodSortValue(b.period));
  if (periodCompare != 0) return periodCompare;
  return a.exam.courseName.compareTo(b.exam.courseName);
}

int compareExamsByTimeAsc(PeriodExam a, PeriodExam b) {
  final aTime = examDateTime(a.exam.time);
  final bTime = examDateTime(b.exam.time);
  if (aTime != null && bTime != null) return aTime.compareTo(bTime);
  if (aTime != null) return -1;
  if (bTime != null) return 1;
  final periodCompare =
      periodSortValue(a.period).compareTo(periodSortValue(b.period));
  if (periodCompare != 0) return periodCompare;
  return a.exam.courseName.compareTo(b.exam.courseName);
}
