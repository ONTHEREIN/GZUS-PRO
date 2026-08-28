import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../../responsive/spacing.dart';
import '../../home/cards/home_card_shell.dart';

/// 考试倒计时卡片：大/中/小三种信息密度。
class ExamCountdownLargeCard extends StatelessWidget {
  const ExamCountdownLargeCard({this.exams, required this.onTap, super.key});

  final List<ExamItem>? exams;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _ExamCountdownCard(exams: exams, onTap: onTap, maxItems: 4);
  }
}

class ExamCountdownMediumCard extends StatelessWidget {
  const ExamCountdownMediumCard({this.exams, required this.onTap, super.key});

  final List<ExamItem>? exams;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _ExamCountdownCard(exams: exams, onTap: onTap, maxItems: 2);
  }
}

class ExamCountdownSmallCard extends StatelessWidget {
  const ExamCountdownSmallCard({this.exams, required this.onTap, super.key});

  final List<ExamItem>? exams;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final upcoming = _upcoming(exams ?? []);
    final first = upcoming.firstOrNull;
    final days = first == null ? null : _calcCountdown(first);
    final isUrgent = days != null && days >= 0 && days <= 3;
    return HomeCardShell(
      title: '考试',
      icon: Icons.timer,
      badge: upcoming.isEmpty ? '0' : '${upcoming.length}',
      onTap: onTap,
      compact: true,
      child: upcoming.isEmpty
          ? const Center(child: Text('暂无考试'))
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  first!.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  days == 0
                      ? '今天考试'
                      : days == null
                          ? '日期待定'
                          : '还有 $days 天',
                  style: TextStyle(
                    color: isUrgent
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                    fontWeight: isUrgent ? FontWeight.w700 : null,
                  ),
                ),
              ],
            ),
    );
  }
}

class _ExamCountdownCard extends StatelessWidget {
  const _ExamCountdownCard({
    required this.exams,
    required this.onTap,
    required this.maxItems,
  });

  final List<ExamItem>? exams;
  final VoidCallback onTap;
  final int maxItems;

  @override
  Widget build(BuildContext context) {
    final list = exams ?? [];
    final upcoming = _upcoming(list);

    return HomeCardShell(
      title: '考试倒计时',
      icon: Icons.timer,
      badge: '期末',
      onTap: onTap,
      child: upcoming.isEmpty
          ? const Center(child: Text('暂无即将到来的考试'))
          : ListView.separated(
              physics: const NeverScrollableScrollPhysics(),
              itemCount: upcoming.length.clamp(0, maxItems),
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final exam = upcoming[i];
                final days = _calcCountdown(exam);
                final dateObj = _examDate(exam);
                final day = dateObj?.day ?? 0;
                final month = dateObj?.month ?? 0;
                final isPast = days < 0;
                final isUrgent = days >= 0 && days <= 3;
                final isToday = days == 0;

                return Container(
                  padding: const EdgeInsets.all(GzusSpacing.m),
                  decoration: BoxDecoration(
                    color: isUrgent
                        ? Theme.of(context)
                            .colorScheme
                            .errorContainer
                            .withValues(alpha: 0.3)
                        : Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isUrgent
                          ? Theme.of(context)
                              .colorScheme
                              .error
                              .withValues(alpha: 0.3)
                          : Theme.of(context)
                              .dividerColor
                              .withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: isUrgent
                              ? Theme.of(context)
                                  .colorScheme
                                  .error
                                  .withValues(alpha: 0.12)
                              : Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('$day',
                                style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: isUrgent
                                        ? Theme.of(context).colorScheme.error
                                        : Theme.of(context)
                                            .colorScheme
                                            .primary)),
                            Text('$month月',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: isUrgent
                                        ? Theme.of(context).colorScheme.error
                                        : Theme.of(context)
                                            .colorScheme
                                            .primary)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(exam.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(
                                '${exam.weekday ?? ''}${(exam.weekday ?? '').isNotEmpty && exam.timeDisplay.isNotEmpty ? ' · ' : ''}${exam.timeDisplay}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant)),
                            Text(exam.location ?? '',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant)),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: isToday
                              ? Theme.of(context).colorScheme.error
                              : isPast
                                  ? Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.6)
                                  : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          children: [
                            Text(
                                days == 9999
                                    ? '?'
                                    : isToday
                                        ? '!'
                                        : '${days.abs()}',
                                style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: isToday
                                        ? Colors.white
                                        : isPast
                                            ? Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant
                                            : Theme.of(context)
                                                .colorScheme
                                                .onSurface)),
                            Text(
                                days == 9999
                                    ? '待定'
                                    : isToday
                                        ? '今天'
                                        : isPast
                                            ? '天前'
                                            : '天',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: isToday
                                        ? Colors.white
                                        : Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

DateTime? _examDate(ExamItem e) {
  var dateStr = e.date;
  if (dateStr.isEmpty) {
    final t = e.time ?? '';
    final spaceIdx = t.indexOf(' ');
    final parenIdx = t.indexOf('(');
    final separator = parenIdx > 0 ? parenIdx : spaceIdx;
    dateStr = separator > 0 ? t.substring(0, separator) : t;
  }
  return DateTime.tryParse(dateStr);
}

int _calcCountdown(ExamItem e) {
  final target = _examDate(e);
  if (target == null) return 9999;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return target.difference(today).inDays;
}

List<ExamItem> _upcoming(List<ExamItem> list) {
  return list.where((e) {
    final days = _calcCountdown(e);
    return days >= -7 || days == 9999;
  }).toList()
    ..sort((a, b) {
      final da = _calcCountdown(a);
      final db = _calcCountdown(b);
      if (da == 9999 && db == 9999) return 0;
      if (da == 9999) return 1;
      if (db == 9999) return -1;
      return da.compareTo(db);
    });
}
