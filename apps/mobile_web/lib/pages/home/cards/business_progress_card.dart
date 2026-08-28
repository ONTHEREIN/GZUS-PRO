import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../../responsive/spacing.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/progress.dart';
import '../../home/cards/home_card_shell.dart';

/// 业务进度卡片：大/中/小三种信息密度。
class BusinessProgressLargeCard extends StatelessWidget {
  const BusinessProgressLargeCard({
    required this.overview,
    required this.onTap,
    super.key,
  });

  final EhallProgressOverview overview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final items = overview.items;
    final total =
        overview.categories.fold<int>(0, (sum, item) => sum + item.count);
    return HomeCardShell(
      title: '业务进度',
      icon: Icons.route,
      badge: '$total 项',
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProgressCategoryStrip(categories: overview.categories),
          const SizedBox(height: GzusSpacing.m),
          if (items.isEmpty)
            const EmptyState(message: '暂无业务进度')
          else
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final item in items) ProgressMiniRow(item: item),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class BusinessProgressMediumCard extends StatelessWidget {
  const BusinessProgressMediumCard({
    required this.overview,
    required this.onTap,
    super.key,
  });

  final EhallProgressOverview overview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final total =
        overview.categories.fold<int>(0, (sum, item) => sum + item.count);
    return HomeCardShell(
      title: '业务进度',
      icon: Icons.route,
      badge: '$total 项',
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProgressCategoryStrip(
            categories: overview.categories,
          ),
          if (overview.items.isNotEmpty) ...[
            const SizedBox(height: GzusSpacing.m),
            ProgressMiniRow(item: overview.items.first),
          ],
        ],
      ),
    );
  }
}

class BusinessProgressSmallCard extends StatelessWidget {
  const BusinessProgressSmallCard({
    required this.overview,
    required this.onTap,
    super.key,
  });

  final EhallProgressOverview overview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final total =
        overview.categories.fold<int>(0, (sum, item) => sum + item.count);
    final first = overview.items.firstOrNull;
    return HomeCardShell(
      title: '业务',
      icon: Icons.route,
      badge: '$total 项',
      onTap: onTap,
      compact: true,
      child: first == null
          ? const Center(child: Text('暂无进度'))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  first.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  first.statusLabel,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
    );
  }
}
