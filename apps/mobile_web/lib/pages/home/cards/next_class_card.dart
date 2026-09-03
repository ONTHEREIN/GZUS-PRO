import 'package:flutter/material.dart';

import '../../../responsive/spacing.dart';
import '../../home/cards/home_card_shell.dart';
import '../../home/cards/schedule_helpers.dart';

class NextClassMediumCard extends StatelessWidget {
  const NextClassMediumCard(
      {required this.course, required this.onTap, super.key});

  final TimedCourse? course;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final item = course;
    final location = item?.course.classroom?.trim();
    return HomeCardShell(
      title: '下一节课',
      icon: Icons.watch_later,
      density: HomeCardDensity.medium,
      badge: item?.isOngoing == true ? '进行中' : '下一节',
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tight = constraints.maxHeight < 120;
          return Container(
            padding: EdgeInsets.all(tight ? 10 : GzusSpacing.m),
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
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Text(
                        item.course.name,
                        maxLines: tight ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onPrimaryContainer,
                          fontSize: tight ? 16 : 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: tight ? 4 : 10),
                      if (tight)
                        Row(
                          children: [
                            Expanded(
                              child: HomeMeta(
                                  icon: Icons.schedule, text: item.timeText),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: HomeMeta(
                                icon: Icons.location_on,
                                text: location?.isNotEmpty == true
                                    ? location!
                                    : '地点待定',
                              ),
                            ),
                          ],
                        )
                      else ...[
                        HomeMeta(icon: Icons.schedule, text: item.timeText),
                        const SizedBox(height: 6),
                        HomeMeta(
                          icon: Icons.location_on,
                          text:
                              location?.isNotEmpty == true ? location! : '地点待定',
                        ),
                      ],
                    ],
                  ),
          );
        },
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
                const SizedBox(height: 3),
                Text(
                  item.course.classroom ?? '地点待定',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                Text(
                  item.course.teacher ?? '老师待定',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
    );
  }
}
