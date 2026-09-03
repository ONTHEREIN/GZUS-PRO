import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../home/cards/home_card_shell.dart';
import '../../home/cards/schedule_helpers.dart';

/// 首页周课表预览：沿用课表页的「日期表头 + 节次轴 + 课程块」结构。
class WeekGridLargeCard extends StatelessWidget {
  const WeekGridLargeCard({
    required this.courses,
    required this.firstWeekStart,
    required this.currentWeek,
    required this.onTap,
    super.key,
  });

  final List<ScheduleCourse> courses;
  final DateTime firstWeekStart;
  final int currentWeek;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HomeCardShell(
      title: '周课表',
      icon: Icons.calendar_month,
      density: HomeCardDensity.large,
      badge: '第$currentWeek周',
      onTap: onTap,
      child: HomeWeekCalendarPreview(
        courses: courses,
        firstWeekStart: firstWeekStart,
        currentWeek: currentWeek,
      ),
    );
  }
}

class WeekGridMediumCard extends StatelessWidget {
  const WeekGridMediumCard({
    required this.courses,
    required this.firstWeekStart,
    required this.currentWeek,
    required this.onTap,
    super.key,
  });

  final List<ScheduleCourse> courses;
  final DateTime firstWeekStart;
  final int currentWeek;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HomeCardShell(
      title: '周课表',
      icon: Icons.calendar_month,
      density: HomeCardDensity.medium,
      badge: '本周 ${courses.length} 节',
      onTap: onTap,
      child: HomeWeekCalendarPreview(
        courses: courses,
        firstWeekStart: firstWeekStart,
        currentWeek: currentWeek,
        compact: true,
      ),
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
              child: Text(
                '今天没课',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
              ),
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final item in todayCourses.take(2))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: homeCourseColor(
                              item.name,
                              Theme.of(context).brightness,
                            ),
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

/// 周课表日历缩略图。大卡显示 1-8 节，中卡压缩为 1-4 节，
/// 课程仍按照星期和节次定位，用户点击卡片即可进入完整课表。
class HomeWeekCalendarPreview extends StatelessWidget {
  const HomeWeekCalendarPreview({
    required this.courses,
    required this.firstWeekStart,
    required this.currentWeek,
    this.compact = false,
    super.key,
  });

  final List<ScheduleCourse> courses;
  final DateTime firstWeekStart;
  final int currentWeek;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final weekStart = firstWeekStart.add(Duration(days: (currentWeek - 1) * 7));
    final days = [
      for (var index = 0; index < 7; index++)
        weekStart.add(Duration(days: index)),
    ];
    final maxSection = compact ? 4 : 8;
    final visibleCourses = courses.where((course) {
      final start = course.startSection;
      return course.weekday != null &&
          course.weekday! >= 1 &&
          course.weekday! <= 7 &&
          start != null &&
          start >= 1 &&
          start <= maxSection &&
          course.occursInWeek(currentWeek);
    }).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final timeWidth = compact ? 27.0 : 32.0;
        final dayWidth = (constraints.maxWidth - timeWidth) / 7;
        final headerHeight = compact ? 29.0 : 40.0;
        final availableRowHeight =
            (constraints.maxHeight - headerHeight) / maxSection;
        final rowHeight = availableRowHeight.clamp(
          compact ? 15.0 : 20.0,
          compact ? 22.0 : 29.0,
        );
        final bodyHeight = rowHeight * maxSection;
        return Column(
          key: const ValueKey('home-week-calendar-preview'),
          children: [
            SizedBox(
              height: headerHeight,
              child: Row(
                children: [
                  SizedBox(width: timeWidth),
                  for (var index = 0; index < days.length; index++)
                    SizedBox(
                      width: dayWidth,
                      child: _HomeDayHeader(
                        day: days[index],
                        compact: compact,
                        isToday: _sameDay(days[index], DateTime.now()),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              height: bodyHeight,
              child: Stack(
                children: [
                  for (var day = 0; day < 7; day++)
                    Positioned(
                      left: timeWidth + dayWidth * day,
                      top: 0,
                      width: dayWidth,
                      height: bodyHeight,
                      child: Container(
                        decoration: BoxDecoration(
                          color: _sameDay(days[day], DateTime.now())
                              ? colorScheme.primaryContainer
                                  .withValues(alpha: 0.24)
                              : colorScheme.surfaceContainerLow,
                          border: Border(
                            left: BorderSide(
                              color: colorScheme.outlineVariant
                                  .withValues(alpha: 0.45),
                            ),
                          ),
                        ),
                      ),
                    ),
                  for (var row = 0; row <= maxSection; row++)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: row * rowHeight,
                      child: Container(
                        height: 1,
                        color:
                            colorScheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
                  for (var row = 0; row < maxSection; row++)
                    Positioned(
                      left: 0,
                      top: row * rowHeight,
                      width: timeWidth,
                      height: rowHeight,
                      child: Center(
                        child: Text(
                          '${row + 1}',
                          style: TextStyle(
                            fontSize: compact ? 9 : 10,
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  for (final course in visibleCourses)
                    _HomeCourseBlock(
                      course: course,
                      timeWidth: timeWidth,
                      dayWidth: dayWidth,
                      rowHeight: rowHeight,
                      compact: compact,
                      maxSection: maxSection,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  bool _sameDay(DateTime left, DateTime right) =>
      left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}

class _HomeDayHeader extends StatelessWidget {
  const _HomeDayHeader({
    required this.day,
    required this.compact,
    required this.isToday,
  });

  final DateTime day;
  final bool compact;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          compact ? weekdays[day.weekday - 1] : '周${weekdays[day.weekday - 1]}',
          maxLines: 1,
          style: TextStyle(
            fontSize: compact ? 9 : 10,
            fontWeight: FontWeight.w800,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 1),
        Container(
          width: compact ? 18 : 22,
          height: compact ? 18 : 22,
          alignment: Alignment.center,
          decoration: isToday
              ? BoxDecoration(
                  color: colorScheme.primary, shape: BoxShape.circle)
              : null,
          child: Text(
            '${day.day}',
            style: TextStyle(
              fontSize: compact ? 10 : 11,
              fontWeight: FontWeight.w800,
              color: isToday ? colorScheme.onPrimary : colorScheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

class _HomeCourseBlock extends StatelessWidget {
  const _HomeCourseBlock({
    required this.course,
    required this.timeWidth,
    required this.dayWidth,
    required this.rowHeight,
    required this.compact,
    required this.maxSection,
  });

  final ScheduleCourse course;
  final double timeWidth;
  final double dayWidth;
  final double rowHeight;
  final bool compact;
  final int maxSection;

  @override
  Widget build(BuildContext context) {
    final start = course.startSection!;
    final end = (course.endSection ?? start).clamp(start, maxSection);
    final span = end - start + 1;
    final color = homeCourseColor(course.name, Theme.of(context).brightness);
    return Positioned(
      left: timeWidth + (course.weekday! - 1) * dayWidth + 2,
      top: start * rowHeight + 2,
      width: dayWidth - 4,
      height: rowHeight * span - 4,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 3, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(compact ? 4 : 5),
        ),
        alignment: Alignment.center,
        child: Text(
          course.name,
          maxLines: compact ? 2 : (span == 1 ? 2 : 3),
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: compact ? 8 : 9,
            height: 1.05,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
