import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../../responsive/spacing.dart';
import '../../home/cards/home_card_shell.dart';

/// 本学期成绩卡片：大/中/小三种信息密度。
class GradesLargeCard extends StatelessWidget {
  const GradesLargeCard({this.grades, required this.onTap, super.key});

  final List<GradeItem>? grades;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _GradesCard(grades: grades, onTap: onTap, maxRows: 2);
  }
}

class GradesMediumCard extends StatelessWidget {
  const GradesMediumCard({this.grades, required this.onTap, super.key});

  final List<GradeItem>? grades;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _GradesCard(grades: grades, onTap: onTap, maxRows: 0);
  }
}

class GradesSmallCard extends StatelessWidget {
  const GradesSmallCard({this.grades, required this.onTap, super.key});

  final List<GradeItem>? grades;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final list = grades ?? [];
    final stats = _calcStats(list);
    return HomeCardShell(
      title: '成绩',
      icon: Icons.school,
      density: HomeCardDensity.small,
      badge: '${stats.count} 门',
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _GradeStatCompact(
            '平均绩点',
            stats.gpa,
            _gpaTagColor(double.parse(stats.gpa)),
          ),
        ],
      ),
    );
  }
}

class _GradesCard extends StatelessWidget {
  const _GradesCard({
    required this.grades,
    required this.onTap,
    required this.maxRows,
  });

  final List<GradeItem>? grades;
  final VoidCallback onTap;
  final int maxRows;

  @override
  Widget build(BuildContext context) {
    final list = grades ?? [];
    final stats = _calcStats(list);
    final sorted =
        list.where((g) => int.tryParse(g.score ?? '') != null).toList()
          ..sort((a, b) {
            final sa = int.parse(a.score!);
            final sb = int.parse(b.score!);
            return sb.compareTo(sa);
          });

    return HomeCardShell(
      title: '本学期成绩',
      icon: Icons.school,
      density: maxRows > 0 ? HomeCardDensity.large : HomeCardDensity.medium,
      badge: '${stats.count} 门',
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment:
            maxRows == 0 ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Text(stats.gpa,
                        style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            color: Theme.of(context).colorScheme.primary)),
                    Text('平均绩点',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ],
                ),
              ),
              Container(
                  width: 1, height: 40, color: Theme.of(context).dividerColor),
              Expanded(
                child: Column(
                  children: [
                    Text(stats.avg,
                        style: const TextStyle(
                            fontSize: 32, fontWeight: FontWeight.w800)),
                    Text('平均分',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
          if (maxRows > 0) ...[
            const Divider(height: 20),
            Expanded(
              child: sorted.isEmpty
                  ? const Center(child: Text('暂无成绩数据'))
                  : ListView.separated(
                      padding: EdgeInsets.zero,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: sorted.length.clamp(0, maxRows),
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: GzusSpacing.s),
                      itemBuilder: (context, i) {
                        final g = sorted[i];
                        final score = int.parse(g.score!);
                        final gpa = _scoreToGPA(g.score);
                        return Row(
                          children: [
                            Container(
                              width: 4,
                              height: 28,
                              decoration: BoxDecoration(
                                color: _scoreColor(
                                    score, Theme.of(context).colorScheme),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(g.courseName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600)),
                                  if (g.credit != null)
                                    Text('${g.credit} 学分',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant)),
                                ],
                              ),
                            ),
                            Text('$score',
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    color: _scoreColor(
                                        score, Theme.of(context).colorScheme))),
                            const SizedBox(width: GzusSpacing.s),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color:
                                    _gpaTagColor(gpa).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(gpa.toStringAsFixed(1),
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: _gpaTagColor(gpa))),
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

class _GradeStatCompact extends StatelessWidget {
  const _GradeStatCompact(this.label, this.value, this.color);

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w800,
              ),
        ),
        Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

({String gpa, String avg, int count}) _calcStats(List<GradeItem> list) {
  double totalGPA = 0;
  double totalScore = 0;
  int valid = 0;
  for (final g in list) {
    final s = int.tryParse(g.score ?? '');
    if (s != null) {
      totalGPA += _scoreToGPA(g.score);
      totalScore += s;
      valid++;
    }
  }
  if (valid == 0) return (gpa: '0.00', avg: '0.0', count: 0);
  return (
    gpa: (totalGPA / valid).toStringAsFixed(2),
    avg: (totalScore / valid).toStringAsFixed(1),
    count: valid,
  );
}

double _scoreToGPA(String? scoreStr) {
  final score = int.tryParse(scoreStr ?? '');
  if (score == null) return 0;
  if (score >= 90) return 4.0;
  if (score >= 85) return 3.7;
  if (score >= 82) return 3.3;
  if (score >= 78) return 3.0;
  if (score >= 75) return 2.7;
  if (score >= 72) return 2.3;
  if (score >= 68) return 2.0;
  if (score >= 66) return 1.7;
  if (score >= 64) return 1.3;
  if (score >= 60) return 1.0;
  return 0;
}

Color _scoreColor(int? score, ColorScheme cs) {
  if (score == null) return cs.onSurfaceVariant;
  if (score >= 90) return Colors.green;
  if (score >= 80) return cs.primary;
  if (score >= 60) return Colors.orange;
  return Colors.red;
}

Color _gpaTagColor(double gpa) {
  if (gpa >= 4.0) return Colors.green;
  if (gpa >= 3.0) return Colors.blue;
  if (gpa >= 2.0) return Colors.orange;
  return Colors.red;
}
