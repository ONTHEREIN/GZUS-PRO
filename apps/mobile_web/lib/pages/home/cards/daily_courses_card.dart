import 'package:flutter/material.dart';

import '../../../widgets/empty_state.dart';
import '../../../widgets/badges.dart';
import '../../home/cards/home_card_shell.dart';
import '../../home/cards/schedule_helpers.dart';

/// 今日课程卡片：大/中/小三种信息密度。
class DailyCoursesLargeCard extends StatelessWidget {
  const DailyCoursesLargeCard({
    required this.courses,
    required this.onTap,
    super.key,
  });

  final List<TimedCourse> courses;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HomeCardShell(
      title: '今日课程',
      icon: Icons.format_list_bulleted,
      density: HomeCardDensity.large,
      badge: '${courses.length} 节',
      onTap: onTap,
      child: courses.isEmpty
          ? const EmptyState(message: '今日无课')
          : Column(
              children: [
                for (final item in courses.take(3)) _CourseRow(course: item),
              ],
            ),
    );
  }
}

class DailyCoursesMediumCard extends StatelessWidget {
  const DailyCoursesMediumCard({
    required this.courses,
    required this.onTap,
    super.key,
  });

  final List<TimedCourse> courses;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HomeCardShell(
      title: '今日课程',
      icon: Icons.format_list_bulleted,
      density: HomeCardDensity.medium,
      badge: '${courses.length} 节',
      onTap: onTap,
      child: courses.isEmpty
          ? const EmptyState(message: '今日无课')
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final item in courses.take(2))
                  _CourseRow(course: item, compact: true),
              ],
            ),
    );
  }
}

class DailyCoursesSmallCard extends StatelessWidget {
  const DailyCoursesSmallCard({
    required this.courses,
    required this.onTap,
    super.key,
  });

  final List<TimedCourse> courses;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return HomeCardShell(
      title: '今日课程',
      icon: Icons.format_list_bulleted,
      density: HomeCardDensity.small,
      badge: '${courses.length} 节',
      onTap: onTap,
      child: courses.isEmpty
          ? Center(
              child: Text('无',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)))
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final item in courses.take(1))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.course.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          item.timeText,
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _CourseRow extends StatelessWidget {
  const _CourseRow({required this.course, this.compact = false});

  final TimedCourse course;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 7 : 9),
      child: Row(
        children: [
          SizedBox(
            width: compact ? 72.0 : 82.0,
            child: Text(
              course.timeText,
              style: TextStyle(
                  color: cs.onSurfaceVariant, fontSize: compact ? 11 : 12),
            ),
          ),
          Expanded(
            child: Text(
              course.course.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          StatusPill(
            label: course.isOngoing ? '进行中' : '待开始',
            color: course.isOngoing ? cs.primary : cs.tertiary,
          ),
        ],
      ),
    );
  }
}
