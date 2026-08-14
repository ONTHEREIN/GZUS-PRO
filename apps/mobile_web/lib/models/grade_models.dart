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
