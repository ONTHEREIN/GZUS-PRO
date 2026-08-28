import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../../responsive/spacing.dart';
import '../../home/cards/home_card_shell.dart';

/// 考勤统计卡片：大/中/小三种信息密度。
class AttendanceLargeCard extends StatelessWidget {
  const AttendanceLargeCard(
      {required this.data, required this.onTap, super.key});

  final AttendanceResponse data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _AttendanceCard(
      data: data,
      onTap: onTap,
      showAll: false,
    );
  }
}

class AttendanceMediumCard extends StatelessWidget {
  const AttendanceMediumCard(
      {required this.data, required this.onTap, super.key});

  final AttendanceResponse data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _AttendanceCard(
      data: data,
      onTap: onTap,
      showAll: true,
    );
  }
}

class AttendanceSmallCard extends StatelessWidget {
  const AttendanceSmallCard(
      {required this.data, required this.onTap, super.key});

  final AttendanceResponse data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final abnormal = data.items.fold(
      0,
      (sum, item) => sum + item.late + item.leaveEarly + item.absent,
    );
    return HomeCardShell(
      title: '考勤',
      icon: Icons.fact_check,
      density: HomeCardDensity.small,
      badge: '${data.items.length} 门',
      onTap: onTap,
      child: Center(
        child: _AttendanceStatCompact(
          abnormal == 0 ? '本月无异常' : '异常记录',
          abnormal,
          abnormal == 0 ? _normalColor(context) : _absentColor(context),
        ),
      ),
    );
  }
}

class _AttendanceCard extends StatelessWidget {
  const _AttendanceCard({
    required this.data,
    required this.onTap,
    required this.showAll,
  });

  final AttendanceResponse data;
  final VoidCallback onTap;
  final bool showAll;

  @override
  Widget build(BuildContext context) {
    final normal = data.items.fold(0, (sum, item) => sum + item.normal);
    final late = data.items.fold(0, (sum, item) => sum + item.late);
    final early = data.items.fold(0, (sum, item) => sum + item.leaveEarly);
    final absent = data.items.fold(0, (sum, item) => sum + item.absent);
    return HomeCardShell(
      title: '本月考勤统计',
      icon: Icons.fact_check,
      density: showAll ? HomeCardDensity.large : HomeCardDensity.medium,
      badge: '${data.items.length} 门',
      onTap: onTap,
      child: Row(
        children: showAll
            ? [
                Expanded(
                    child: _AttendanceStatMini(
                        '正常', normal, _normalColor(context))),
                Expanded(
                    child:
                        _AttendanceStatMini('迟到', late, _lateColor(context))),
                Expanded(
                    child:
                        _AttendanceStatMini('早退', early, _earlyColor(context))),
                Expanded(
                    child: _AttendanceStatMini(
                        '旷课', absent, _absentColor(context))),
              ]
            : [
                Expanded(
                    child: _AttendanceStatMini(
                        '正常', normal, _normalColor(context))),
                Expanded(
                    child: _AttendanceStatMini(
                        '异常', late + early + absent, _absentColor(context))),
              ],
      ),
    );
  }
}

class _AttendanceStatMini extends StatelessWidget {
  const _AttendanceStatMini(this.label, this.value, this.color);

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            '$value',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: GzusSpacing.xs),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _AttendanceStatCompact extends StatelessWidget {
  const _AttendanceStatCompact(this.label, this.value, this.color);

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
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

Color _normalColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32);
}

Color _lateColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFFFFB74D) : const Color(0xFFF57C00);
}

Color _earlyColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFFBA68C8) : const Color(0xFF7B1FA2);
}

Color _absentColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFFE57373) : const Color(0xFFC62828);
}
