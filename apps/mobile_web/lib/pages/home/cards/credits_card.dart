import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../../gzus_design.dart';
import '../../../responsive/spacing.dart';
import '../../../widgets/progress.dart';
import '../../home/cards/home_card_shell.dart';

/// 学分进度卡片：大/中/小三种信息密度。
class CreditsLargeCard extends StatelessWidget {
  const CreditsLargeCard(
      {required this.credits, required this.onTap, super.key});

  final List<CreditItem> credits;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = credits.isEmpty ? null : credits.first;
    final expected = item?.totalExpected ?? 0;
    final earned = item?.totalEarned ?? 0;
    final progress = expected <= 0 ? 0.0 : (earned / expected).clamp(0.0, 1.0);
    return HomeCardShell(
      title: '学分进度',
      icon: Icons.workspace_premium,
      badge: item?.grade ?? '学分',
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${earned.toStringAsFixed(1)} / ${expected.toStringAsFixed(1)}',
            style: GzusTextStyles.statisticValue(context)?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 10),
          StaticProgressBar(value: progress),
          const SizedBox(height: GzusSpacing.m),
          HomeInfoLine(
              '必修',
              item == null
                  ? '-'
                  : '${item.requiredEarned.toStringAsFixed(1)} / ${item.requiredExpected.toStringAsFixed(1)}'),
          HomeInfoLine(
              '选修',
              item == null
                  ? '-'
                  : '${item.electiveEarned.toStringAsFixed(1)} / ${item.electiveExpected.toStringAsFixed(1)}'),
        ],
      ),
    );
  }
}

class CreditsMediumCard extends StatelessWidget {
  const CreditsMediumCard(
      {required this.credits, required this.onTap, super.key});

  final List<CreditItem> credits;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = credits.isEmpty ? null : credits.first;
    final expected = item?.totalExpected ?? 0;
    final earned = item?.totalEarned ?? 0;
    final progress = expected <= 0 ? 0.0 : (earned / expected).clamp(0.0, 1.0);
    return HomeCardShell(
      title: '学分进度',
      icon: Icons.workspace_premium,
      badge: item?.grade ?? '学分',
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${earned.toStringAsFixed(1)} / ${expected.toStringAsFixed(1)}',
            style: GzusTextStyles.statisticValue(context)?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 10),
          StaticProgressBar(value: progress),
        ],
      ),
    );
  }
}

class CreditsSmallCard extends StatelessWidget {
  const CreditsSmallCard(
      {required this.credits, required this.onTap, super.key});

  final List<CreditItem> credits;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = credits.isEmpty ? null : credits.first;
    final expected = item?.totalExpected ?? 0;
    final earned = item?.totalEarned ?? 0;
    final progress = expected <= 0 ? 0.0 : (earned / expected).clamp(0.0, 1.0);
    return HomeCardShell(
      title: '学分',
      icon: Icons.workspace_premium,
      badge: '${(progress * 100).round()}%',
      onTap: onTap,
      compact: true,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${earned.toStringAsFixed(1)} / ${expected.toStringAsFixed(1)}',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 6),
          StaticProgressBar(value: progress),
        ],
      ),
    );
  }
}
