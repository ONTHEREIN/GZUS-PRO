import 'package:flutter/material.dart';

import '../../../responsive/spacing.dart';
import '../../home/cards/home_card_shell.dart';
import '../../home/cards/schedule_helpers.dart';

/// 下一节课卡片：大/中/小三种信息密度。
class NextClassLargeCard extends StatelessWidget {
  const NextClassLargeCard(
      {required this.course, required this.onTap, super.key});

  final TimedCourse? course;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final item = course;
    return HomeCardShell(
      title: '下一节课',
      icon: Icons.watch_later,
      density: HomeCardDensity.large,
      badge: item?.isOngoing == true ? '进行中' : '焦点',
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(GzusSpacing.l),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: item == null
            ? Text('今天没有更多课程', style: TextStyle(color: cs.onPrimaryContainer))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.course.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onPrimaryContainer,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      HomeMeta(icon: Icons.schedule, text: item.timeText),
                      if (item.course.classroom != null)
                        HomeMeta(
                            icon: Icons.location_on,
                            text: item.course.classroom!),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class NextClassMediumCard extends StatelessWidget {
  const NextClassMediumCard(
      {required this.course, required this.onTap, super.key});

  final TimedCourse? course;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final item = course;
    return HomeCardShell(
      title: '下一节课',
      icon: Icons.watch_later,
      density: HomeCardDensity.medium,
      badge: item?.isOngoing == true ? '进行中' : '下一节',
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(GzusSpacing.m),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: item == null
            ? Center(
                child: Text('今日无课',
                    style: TextStyle(color: cs.onPrimaryContainer)))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    item.course.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onPrimaryContainer,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 10),
                  HomeMeta(icon: Icons.schedule, text: item.timeText),
                  if (item.course.classroom != null) ...[
                    const SizedBox(height: 6),
                    HomeMeta(
                        icon: Icons.location_on, text: item.course.classroom!),
                  ],
                ],
              ),
      ),
    );
  }
}

class NextClassSmallCard extends StatelessWidget {
  const NextClassSmallCard(
      {required this.course, required this.onTap, super.key});

  final TimedCourse? course;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final item = course;
    return HomeCardShell(
      title: '下一节',
      icon: Icons.watch_later,
      density: HomeCardDensity.small,
      badge: item?.isOngoing == true ? '进行中' : null,
      onTap: onTap,
      child: item == null
          ? Center(
              child: Text('无',
                  style: TextStyle(
                      color: cs.onSurfaceVariant, fontWeight: FontWeight.w700)))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  item.course.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.timeText,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
    );
  }
}
