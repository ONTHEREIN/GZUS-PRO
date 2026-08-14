import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../gzus_design.dart';
import '../../widgets/async_panel.dart';

/// 总览页签：会话/推送/水电费/缓存/管理员数量统计卡。
class OverviewTab extends StatefulWidget {
  const OverviewTab({super.key, required this.api});

  final ApiClient api;

  @override
  State<OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<OverviewTab> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.adminOverview();
  }

  void _refresh() {
    setState(() {
      _future = widget.api.adminOverview();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: () async {
        _refresh();
        await _future;
      },
      child: AsyncPanel<Map<String, dynamic>>(
        future: _future,
        emptyMessage: '暂无统计',
        builder: (data) {
          final entries = <(String, String, IconData, Color)>[
            ('活跃会话', '${data['activeSessions'] ?? 0}', Icons.wifi_tethering,
                GzusColors.green),
            ('总会话', '${data['totalSessions'] ?? 0}', Icons.person_outline,
                GzusColors.blue),
            ('今日登录', '${data['sessionsToday'] ?? 0}', Icons.login,
                GzusColors.blue),
            ('已下线', '${data['revokedSessions'] ?? 0}', Icons.block,
                GzusColors.red),
            ('极光推送', '${data['pushRegistrations'] ?? 0}', Icons.notifications,
                GzusColors.amber),
            ('Web 推送', '${data['webPushSubscriptions'] ?? 0}',
                Icons.notifications_active_outlined, GzusColors.amber),
            ('水电费绑定', '${data['ecardBindings'] ?? 0}', Icons.electric_bolt,
                GzusColors.green),
            ('缓存条目', '${data['cacheEntries'] ?? 0}', Icons.storage,
                GzusColors.muted),
            ('管理员', '${data['adminUsers'] ?? 0}', Icons.admin_panel_settings,
                GzusColors.blue),
          ];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              GridView.count(
                crossAxisCount:
                    MediaQuery.sizeOf(context).width >= 600 ? 3 : 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.5,
                children: [
                  for (final (label, value, icon, color) in entries)
                    _StatCard(
                      icon: icon,
                      label: label,
                      value: value,
                      color: color,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainer,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('统计口径'),
                  subtitle: Text('活跃会话：25 分钟内有过请求且未下线的会话；'
                      '今日登录：按 UTC 当天创建。'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GzusTextStyles.caption(context),
                  ),
                ),
              ],
            ),
            Text(
              value,
              style:
                  GzusTextStyles.metricValue(context)?.copyWith(fontSize: 26),
            ),
          ],
        ),
      ),
    );
  }
}
