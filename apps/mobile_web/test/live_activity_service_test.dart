import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

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

  test('non-countdown events receive the four-hour design lifetime', () {
    final before = DateTime.now();
    final event = LiveActivityEvent(
      id: 'notice:1',
      type: 'new_notice',
      title: '新通知',
      body: '摘要',
    );
    final after = DateTime.now().add(const Duration(hours: 4, seconds: 1));

    expect(event.effectiveEndTime.isAfter(before), isTrue);
    expect(event.effectiveEndTime.isBefore(after), isTrue);
  });

  test('events expose the design priority order and business target', () {
    final activeCourse = LiveActivityEvent(
      id: 'course:active',
      type: 'course_reminder',
      title: '上课中',
      body: '数据结构',
      ongoing: true,
    );
    final utility = LiveActivityEvent(
      id: 'utility:low',
      type: 'ecard_reminder',
      title: '电量偏低',
      body: '42.6 度',
    );
    final business = LiveActivityEvent.fromMessage({
      'id': 'business:1',
      'type': 'business_update',
      'title': '业务更新',
      'body': '请假审批中',
    });

    expect(activeCourse.priority, 1);
    expect(utility.priority, 5);
    expect(business.priority, 4);
    expect(business.targetTab, 'business');
  });

  test('progress-style exam events still expose a live countdown', () {
    final start = DateTime(2026, 6, 8, 8);
    final exam = LiveActivityEvent.fromMessage({
      'id': 'exam:1',
      'type': 'exam_reminder',
      'title': '考试提醒',
      'body': '高数 09:00',
      'style': 'progress',
      'startTime': start.millisecondsSinceEpoch,
      'endTime': start.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      'progress': 0,
    });
    final utility = LiveActivityEvent.fromMessage({
      'id': 'ecard:1',
      'type': 'ecard_reminder',
      'title': '水电余额提醒',
      'body': '冷水 12.8 元 · 热水 8.6 元 · 电费 21.5 元',
      'style': 'progress',
      'startTime': start.millisecondsSinceEpoch,
      'endTime': start.add(const Duration(minutes: 30)).millisecondsSinceEpoch,
      'progress': 0.2,
    });

    expect(exam.isCountdown, isTrue);
    expect(exam.isTimer, isFalse);
    expect(utility.isCountdown, isFalse);
  });

  testWidgets('notification variants fit a narrow device at larger text',
      (tester) async {
    final controller = LiveActivityController.instance;
    controller.resetForTest();
    addTearDown(controller.resetForTest);
    addTearDown(() {
      tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
      tester.binding.setSurfaceSize(null);
    });
    tester.binding.platformDispatcher.textScaleFactorTestValue = 1.5;
    await tester.binding.setSurfaceSize(const Size(320, 568));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LiveActivityIsland(controller: controller),
      ),
    ));

    final events = <LiveActivityEvent>[
      LiveActivityEvent.fromMessage({
        'id': 'notice:1',
        'type': 'new_notice',
        'title': '新通知',
        'body': '关于本学期课程安排与考试周安排的通知',
        'shortCriticalText': '通知',
        'progress': 1,
      }),
      LiveActivityEvent.fromMessage({
        'id': 'grade:1',
        'type': 'grade_update',
        'title': '成绩更新',
        'body': '移动应用开发：92',
        'style': 'progress',
        'shortCriticalText': '成绩',
        'progress': 1,
      }),
      LiveActivityEvent.fromMessage({
        'id': 'ecard:1',
        'type': 'ecard_reminder',
        'title': '水电余额提醒',
        'body': '冷水 12.8 元 · 热水 8.6 元 · 电费 21.5 元',
        'style': 'progress',
        'shortCriticalText': '水电',
        'progress': 0.2,
      }),
    ];

    for (final event in events) {
      controller.show(event);
      await tester.pump();
      expect(tester.takeException(), isNull);
      controller.dismiss(event.id);
      await tester.pump();
    }
  });

  test('controller queues lower-priority events and promotes them in order',
      () {
    final controller = LiveActivityController.instance;
    controller.resetForTest();
    addTearDown(controller.resetForTest);
    final course = LiveActivityEvent(
      id: 'course:active',
      type: 'course_reminder',
      title: '上课中',
      body: '数据结构',
      ongoing: true,
    );
    final grade = LiveActivityEvent(
      id: 'grade:1',
      type: 'grade_update',
      title: '成绩更新',
      body: '新成绩',
    );
    final utility = LiveActivityEvent(
      id: 'utility:1',
      type: 'ecard_reminder',
      title: '电量偏低',
      body: '9 度',
    );

    controller.show(course);
    controller.show(utility);
    controller.show(grade);

    expect(controller.state.value.event?.id, course.id);
    expect(controller.queuedEvents.map((event) => event.id),
        containsAll(<String>[utility.id, grade.id]));

    controller.dismiss(course.id);
    expect(controller.state.value.event?.id, grade.id);
    controller.dismiss(grade.id);
    expect(controller.state.value.event?.id, utility.id);
  });
}
