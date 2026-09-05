import 'package:flutter_test/flutter_test.dart';

import 'package:gzus_pro_mobile_web/pages/home/home_page.dart';

void main() {
  test('组件深链参数可解析为条目目标', () {
    final target = WidgetLaunchTarget.fromArguments({
      'tab': 'schedule',
      'kind': 'weekly',
      'itemKey': 'course-1:2:3',
      'week': '6',
      'weekday': 2,
      'startSection': 3,
    });

    expect(target, isNotNull);
    expect(target!.tab, 'schedule');
    expect(target.kind, 'weekly');
    expect(target.itemKey, 'course-1:2:3');
    expect(target.week, 6);
    expect(target.weekday, 2);
    expect(target.startSection, 3);
  });

  test('组件深链缺少 tab 时拒绝目标', () {
    expect(WidgetLaunchTarget.fromArguments({'kind': 'weekly'}), isNull);
    expect(WidgetLaunchTarget.fromArguments(null), isNull);
  });
}
