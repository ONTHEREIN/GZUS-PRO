import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../home/cards/home_card_shell.dart';
import '../../home/cards/schedule_helpers.dart';

/// 周课表卡片：大/中/小三种信息密度。
class WeekGridLargeCard extends StatelessWidget {
  const WeekGridLargeCard({
    required this.courses,
    required this.onTap,
    super.key,
  });

  final List<ScheduleCourse> courses;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const days = ['一', '二', '三', '四', '五', '六', '日'];
    const slots = [1, 3, 5, 7];
    return HomeCardShell(
      title: '周课表',
      icon: Icons.calendar_month,
      density: HomeCardDensity.large,
      badge: '紧凑',
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 400) {
            return _WeekSummary(courses: courses);
          }
          final labelWidth = constraints.maxWidth < 280 ? 28.0 : 36.0;
          final cellWidth =
              (constraints.maxWidth - labelWidth - 8) / days.length;
          final cellHeight =
              (constraints.maxHeight - 24 - 6 - 8) / slots.length;
          final fontSize =
              cellWidth < 44 ? 9.0 : (cellWidth < 58 ? 10.0 : 11.0);
          return Column(
            children: [
              Row(
                children: [
                  SizedBox(width: labelWidth),
                  for (final day in days)
                    Expanded(
                      child: Text('周$day',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: fontSize + 2)),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Column(
                  children: [
                    for (final slot in slots)
                      Expanded(
                        child: Row(
                          children: [
                            SizedBox(
                              width: labelWidth,
                              child: Text('$slot-${slot + 1}',
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                      fontSize: fontSize + 1)),
                            ),
                            for (var day = 1; day <= 7; day++)
                              Expanded(
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: onTap,
                                  child: _WeekGridCell(
                                    course: firstOrNull(courses.where((item) {
                                      final start = item.startSection ?? 0;
                                      return item.weekday == day &&
                                          start >= slot &&
                                          start <= slot + 1;
                                    })),
                                    height: cellHeight,
                                    fontSize: fontSize,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class WeekGridMediumCard extends StatelessWidget {
  const WeekGridMediumCard({
    required this.courses,
    required this.onTap,
    super.key,
  });

  final List<ScheduleCourse> courses;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HomeCardShell(
      title: '周课表',
      icon: Icons.calendar_month,
      density: HomeCardDensity.medium,
      badge: '本周',
      onTap: onTap,
      child: _WeekSummary(courses: courses),
    );
  }
}

class WeekGridSmallCard extends StatelessWidget {
  const WeekGridSmallCard({
    required this.courses,
    required this.onTap,
    super.key,
  });

  final List<ScheduleCourse> courses;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final todayWeekday = DateTime.now().weekday;
    final todayCourses = courses
        .where((c) => c.weekday == todayWeekday)
        .toList()
      ..sort((a, b) => (a.startSection ?? 0).compareTo(b.startSection ?? 0));
    return HomeCardShell(
      title: '周课表',
      icon: Icons.calendar_month,
      density: HomeCardDensity.small,
      badge: '今天',
      onTap: onTap,
      child: todayCourses.isEmpty
          ? Center(
              child: Text('今天没课',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)))
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final item in todayCourses.take(1))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: homeCourseColor(
                                item.name, Theme.of(context).brightness),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _WeekSummary extends StatelessWidget {
  const _WeekSummary({required this.courses});

  final List<ScheduleCourse> courses;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now().weekday;
    final todayCourses = courses.where((item) => item.weekday == today).toList()
      ..sort((a, b) => (a.startSection ?? 0).compareTo(b.startSection ?? 0));
    final first = todayCourses.firstOrNull;
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '本周 ${courses.length} 节 · 今日 ${todayCourses.length} 节',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Text(
            first?.name ?? '今天没课',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
        ],
      ),
    );
  }
}

class _WeekGridCell extends StatelessWidget {
  const _WeekGridCell({
    required this.course,
    required this.height,
    required this.fontSize,
  });

  final ScheduleCourse? course;
  final double height;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final item = course;
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: height,
      margin: const EdgeInsets.all(2),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: item == null
            ? cs.surfaceContainerHighest.withValues(alpha: 0.35)
            : homeCourseColor(item.name, Theme.of(context).brightness)
                .withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
      ),
      child: item == null
          ? null
          : Center(
              child: Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w800,
                  height: 1.05,
                ),
              ),
            ),
    );
  }
}
