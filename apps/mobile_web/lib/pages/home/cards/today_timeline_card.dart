import 'package:flutter/material.dart';

import '../../../responsive/spacing.dart';
import '../../../widgets/empty_state.dart';
import '../../home/cards/home_card_shell.dart';
import '../../home/cards/schedule_helpers.dart';

/// 今日时间线卡片：大/中/小三种信息密度。
class TodayTimelineLargeCard extends StatelessWidget {
  const TodayTimelineLargeCard({required this.courses, super.key});

  final List<TimedCourse> courses;

  @override
  Widget build(BuildContext context) {
    return HomeCardShell(
      title: '今日时间线',
      icon: Icons.view_timeline,
      badge: '${courses.length} 节',
      child: courses.isEmpty
          ? const EmptyState(message: '今日无课')
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in courses) _TimelineRow(course: item),
                ],
              ),
            ),
    );
  }
}

class TodayTimelineMediumCard extends StatelessWidget {
  const TodayTimelineMediumCard({required this.courses, super.key});

  final List<TimedCourse> courses;

  @override
  Widget build(BuildContext context) {
    return HomeCardShell(
      title: '今日时间线',
      icon: Icons.view_timeline,
      badge: '${courses.length} 节',
      child: courses.isEmpty
          ? const EmptyState(message: '今日无课')
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in courses.take(4))
                    _TimelineRow(course: item, compact: true),
                ],
              ),
            ),
    );
  }
}

class TodayTimelineSmallCard extends StatelessWidget {
  const TodayTimelineSmallCard({required this.courses, super.key});

  final List<TimedCourse> courses;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return HomeCardShell(
      title: '今日课程',
      icon: Icons.view_timeline,
      badge: courses.isEmpty ? '0' : '${courses.length} 节',
      compact: true,
      child: courses.isEmpty
          ? Center(
              child: Text('今日无课',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)))
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final item in courses.take(2))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: item.isOngoing
                                ? cs.error
                                : homeCourseColor(
                                    item.course.name,
                                    Theme.of(context).brightness,
                                  ),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${item.timeText} ${item.course.name}',
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

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.course, this.compact = false});

  final TimedCourse course;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = course.isOngoing
        ? cs.error
        : homeCourseColor(course.course.name, Theme.of(context).brightness);
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 8 : 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compactWidth = constraints.maxWidth < 260;
          final timeWidth = compactWidth ? 42.0 : 48.0;
          final dotSize = compactWidth ? 8.0 : 10.0;
          final gap = compactWidth ? 8.0 : 10.0;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: timeWidth,
                child: Text(
                  '${_two(course.start.hour)}:${_two(course.start.minute)}',
                  style: TextStyle(
                      color: cs.onSurfaceVariant, fontSize: compact ? 11 : 12),
                ),
              ),
              Container(
                width: dotSize,
                height: dotSize,
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              SizedBox(width: gap),
              Expanded(
                child: Container(
                  padding: EdgeInsets.all(compact ? 8 : GzusSpacing.m),
                  decoration: BoxDecoration(
                    color: course.isOngoing
                        ? cs.primaryContainer
                        : cs.surfaceContainerHighest.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(course.course.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: GzusSpacing.xs),
                      Text(
                        [course.course.classroom, course.course.teacher]
                            .where((item) => item != null && item.isNotEmpty)
                            .join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: compact ? 11 : 12),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

String _two(int value) => value.toString().padLeft(2, '0');
