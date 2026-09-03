import 'package:flutter_test/flutter_test.dart';

import 'package:gzus_pro_mobile_web/live_activity_service.dart';

void main() {
  test(
      'Live Activity event maps every supported tab and hides sensitive detail',
      () {
    const types = {
      'course_reminder': 'schedule',
      'exam_reminder': 'exams',
      'grade_update': 'grades',
      'new_notice': 'notices',
      'ecard_reminder': 'ecard',
      'attendance_update': 'attendance',
    };

    for (final entry in types.entries) {
      final event = LiveActivityEvent.fromMessage({
        'id': 'event:${entry.key}',
        'type': entry.key,
        'title': '摘要',
        'body': '点击进入应用查看详情',
        'shortCriticalText': entry.key,
        'progress': 1,
      });

      expect(event.targetTab, entry.value);
      expect(event.deepLink, 'cn.gzus.pro://activity?tab=${entry.value}');
      expect(event.body, isNot(contains('学号')));
    }
  });

  test('non-countdown events receive a bounded dismissal time', () {
    final before = DateTime.now();
    final event = LiveActivityEvent(
      id: 'notice:1',
      type: 'new_notice',
      title: '新通知',
      body: '摘要',
    );
    final after = DateTime.now().add(const Duration(minutes: 31));

    expect(event.effectiveEndTime, isNotNull);
    expect(event.effectiveEndTime!.isAfter(before), isTrue);
    expect(event.effectiveEndTime!.isBefore(after), isTrue);
  });
}
