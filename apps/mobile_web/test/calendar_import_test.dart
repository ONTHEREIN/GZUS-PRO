import 'package:flutter_test/flutter_test.dart';
import 'package:gzus_pro_mobile_web/api_client.dart';

void main() {
  test('scheduleCalendarEvents 展开单双周与节次时间', () {
    final events = scheduleCalendarEvents(
      courses: [
        ScheduleCourse(
          name: '高等数学(一)',
          teacher: '张老师',
          classroom: 'A101',
          weekday: 1,
          startSection: 1,
          endSection: 2,
          weeks: '1-16周(单)',
        ),
        ScheduleCourse(
          name: '大学英语',
          teacher: '李老师',
          classroom: 'B202',
          weekday: 1,
          startSection: 1,
          endSection: 2,
          weeks: '1-16周(双)',
        ),
      ],
      firstWeekStart: DateTime(2026, 9, 7),
      year: 2026,
      term: 1,
    );

    expect(events.length, 16);
    expect(events.first.title, '高等数学(一)');
    expect(events.first.start, DateTime(2026, 9, 7, 9, 0));
    expect(events.first.end, DateTime(2026, 9, 7, 10, 20));
    expect(events.first.location, 'A101');
    expect(events.first.description, contains('周次'));
    expect(events.first.sourceId, isNotEmpty);
  });

  test('examCalendarEvents 解析考试起止时间', () {
    final events = examCalendarEvents(
      exams: [
        PeriodExam(
          const AcademicPeriod(2026, 1),
          ExamItem.fromJson({
            'courseName': '大学英语',
            'time': '2026-06-20 09:00-11:00',
            'location': 'B202',
            'seat': '12',
            'type': '闭卷',
          }),
        ),
      ],
      year: 2026,
      term: 1,
    );

    expect(events.length, 1);
    expect(events.single.title, '大学英语 考试');
    expect(events.single.start, DateTime(2026, 6, 20, 9, 0));
    expect(events.single.end, DateTime(2026, 6, 20, 11, 0));
    expect(events.single.description, contains('座位: 12'));
    expect(events.single.sourceId, isNotEmpty);
  });
}
