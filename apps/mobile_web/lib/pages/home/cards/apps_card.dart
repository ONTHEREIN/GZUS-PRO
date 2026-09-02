import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../../widgets/badges.dart';
import '../../home/cards/home_card_shell.dart';

/// 常用服务卡片：大/中/小三种信息密度。
class AppsLargeCard extends StatelessWidget {
  const AppsLargeCard({required this.apps, required this.onTap, super.key});

  final List<EhallApplicationItem> apps;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _AppsCard(apps: apps, onTap: onTap, maxItems: 6);
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
    final app = apps.firstOrNull;
    return HomeCardShell(
      title: '服务',
      icon: Icons.apps,
      density: HomeCardDensity.small,
      badge: '${apps.length}',
      onTap: onTap,
      child: app == null
          ? const Center(child: Text('暂无'))
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const IconBadge(icon: Icons.dashboard_customize, size: 28),
                const SizedBox(height: 4),
                Text(
                  app.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
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
      density: maxItems == 6 ? HomeCardDensity.large : HomeCardDensity.medium,
      badge: '${apps.length} 个',
      onTap: onTap,
      child: visible.isEmpty
          ? const Center(child: Text('暂无应用'))
          : LayoutBuilder(
              builder: (context, constraints) {
                final columns = maxItems == 6 ? 3 : 2;
                final rows = (visible.length / columns).ceil();
                final rowHeight =
                    ((constraints.maxHeight - (rows - 1) * 10) / rows)
                        .clamp(48.0, 92.0);
                return Center(
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    itemCount: visible.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      mainAxisExtent: rowHeight,
                    ),
                    itemBuilder: (context, index) {
                      final app = visible[index];
                      final iconSize = rowHeight < 68 ? 28.0 : 36.0;
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconBadge(
                            icon: Icons.dashboard_customize,
                            size: iconSize,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            app.title,
                            maxLines: rowHeight < 68 ? 1 : 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      );
                    },
                  ),
                );
              },
            ),
    );
  }
}
