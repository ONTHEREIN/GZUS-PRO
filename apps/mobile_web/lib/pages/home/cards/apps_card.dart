import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../../widgets/badges.dart';
import '../../../widgets/empty_state.dart';
import '../../home/cards/home_card_shell.dart';

/// 常用服务卡片：大/中/小三种信息密度。
class AppsLargeCard extends StatelessWidget {
  const AppsLargeCard({required this.apps, required this.onTap, super.key});

  final List<EhallApplicationItem> apps;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _AppsCard(apps: apps, onTap: onTap, maxItems: 8);
  }
}

class AppsMediumCard extends StatelessWidget {
  const AppsMediumCard({required this.apps, required this.onTap, super.key});

  final List<EhallApplicationItem> apps;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _AppsCard(apps: apps, onTap: onTap, maxItems: 4);
  }
}

class AppsSmallCard extends StatelessWidget {
  const AppsSmallCard({required this.apps, required this.onTap, super.key});

  final List<EhallApplicationItem> apps;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final visible = apps.take(3).toList();
    return HomeCardShell(
      title: '服务',
      icon: Icons.apps,
      badge: '${apps.length}',
      onTap: onTap,
      compact: true,
      child: visible.isEmpty
          ? const Center(child: Text('暂无'))
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final app in visible)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const IconBadge(
                          icon: Icons.dashboard_customize, size: 28),
                      const SizedBox(height: 4),
                      Text(
                        app.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
              ],
            ),
    );
  }
}

class _AppsCard extends StatelessWidget {
  const _AppsCard({
    required this.apps,
    required this.onTap,
    required this.maxItems,
  });

  final List<EhallApplicationItem> apps;
  final VoidCallback onTap;
  final int maxItems;

  @override
  Widget build(BuildContext context) {
    final visible = apps.take(maxItems).toList();
    return HomeCardShell(
      title: '常用服务',
      icon: Icons.apps,
      badge: '${apps.length} 个',
      onTap: onTap,
      child: visible.isEmpty
          ? const EmptyState(message: '暂无应用')
          : LayoutBuilder(
              builder: (context, constraints) {
                final itemWidth = constraints.maxWidth < 240
                    ? constraints.maxWidth / 4 - 10
                    : (constraints.maxWidth / 4).clamp(64.0, 84.0);
                return Wrap(
                  alignment: WrapAlignment.start,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final app in visible)
                      SizedBox(
                        width: itemWidth,
                        child: Column(
                          children: [
                            const IconBadge(icon: Icons.dashboard_customize),
                            const SizedBox(height: 6),
                            Text(app.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}
