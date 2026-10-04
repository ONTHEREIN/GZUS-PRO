import 'package:flutter/material.dart';
import '../../api_client.dart';
import '../../schedule_utils.dart';
import 'schedule_course_color.dart';

/// 周课表选择：同一天重叠课程分列，点击区域分别携带实例身份。
class ScheduleSelectionWeek extends StatelessWidget {
  const ScheduleSelectionWeek(
      {super.key,
      required this.rows,
      required this.selected,
      required this.firstDay,
      required this.onSelect});
  final List<ScheduleOccurrence> rows;
  final Set<String> selected;
  final DateTime firstDay;
  final ValueChanged<ScheduleOccurrence> onSelect;
  @override
  Widget build(BuildContext context) {
    final height = 54.0 * MediaQuery.textScalerOf(context).scale(1),
        width = 104.0;
    return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 52,
              child: Column(children: [
                const SizedBox(height: 48),
                for (var s = 1; s <= 16; s++)
                  SizedBox(
                      height: height,
                      child: Center(
                          child: Text('$s\n${scheduleTimes[s - 1].$1}',
                              style: Theme.of(context).textTheme.bodySmall)))
              ])),
          for (var day = 1; day <= 7; day++)
            SizedBox(
                width: width,
                child: Column(children: [
                  SizedBox(
                      height: 48,
                      child: Center(
                          child: Text('周${[
                        '一',
                        '二',
                        '三',
                        '四',
                        '五',
                        '六',
                        '日'
                      ][day - 1]}\n${dateText(firstDay.add(Duration(days: day - 1))).substring(5)}'))),
                  _day(
                      context,
                      rows.where((o) => o.date.weekday == day).toList(),
                      width,
                      height),
                ]))
        ]));
  }

  Widget _day(BuildContext context, List<ScheduleOccurrence> courses,
      double width, double height) {
    final sorted = [
      ...courses
    ]..sort((a, b) => a.course.startSection!.compareTo(b.course.startSection!));
    final lanes = <List<ScheduleOccurrence>>[];
    final positions = <String, int>{};
    for (final o in sorted) {
      var lane = 0;
      while (lane < lanes.length &&
          lanes[lane].any((a) =>
              (a.course.endSection ?? a.course.startSection!) >=
              o.course.startSection!)) {
        lane++;
      }
      if (lane == lanes.length) lanes.add([]);
      lanes[lane].add(o);
      positions[o.occurrenceKey] = lane;
    }
    final count = lanes.isEmpty ? 1 : lanes.length;
    return SizedBox(
        height: height * 16,
        child: Stack(children: [
          for (var s = 0; s < 16; s++)
            Positioned(
                top: s * height,
                left: 0,
                right: 0,
                child: Container(
                    height: height,
                    decoration: BoxDecoration(
                        border: Border.all(
                            color: Theme.of(context)
                                .dividerColor
                                .withValues(alpha: .25))))),
          for (final o in sorted)
            Positioned(
                top: (o.course.startSection! - 1) * height + 2,
                left: positions[o.occurrenceKey]! * width / count + 2,
                width: width / count - 4,
                height: ((o.course.endSection ?? o.course.startSection!) -
                            o.course.startSection! +
                            1) *
                        height -
                    4,
                child: Semantics(
                    selected: selected.contains(o.occurrenceKey),
                    button: true,
                    label:
                        '${o.course.name} ${dateText(o.date)} 第${o.course.startSection}至${o.course.endSection}节',
                    child: Material(
                        color: selected.contains(o.occurrenceKey)
                            ? const Color(0xFFFF315A).withValues(alpha: .14)
                            : Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: BorderSide(
                                color: scheduleCourseColor(o.course.name),
                                width: selected.contains(o.occurrenceKey)
                                    ? 3
                                    : 2)),
                        child: InkWell(
                            key: ValueKey(
                                'adjustment-course-${o.occurrenceKey}'),
                            onTap: () => onSelect(o),
                            child: Padding(
                                padding: const EdgeInsets.all(5),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (selected.contains(o.occurrenceKey))
                                        const Icon(Icons.check_circle,
                                            size: 16, color: Color(0xFFFF315A)),
                                      Expanded(
                                          child: Text(o.course.name,
                                              maxLines: 5,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall)),
                                      Text(
                                          '${o.course.startSection}–${o.course.endSection}节',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall)
                                    ]))))))
        ]));
  }
}
