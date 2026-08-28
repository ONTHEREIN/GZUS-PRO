import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../../widgets/badges.dart';
import '../../../widgets/empty_state.dart';
import '../../home/cards/home_card_shell.dart';

/// 通知摘要卡片：大/中/小三种信息密度。
class NotificationsLargeCard extends StatelessWidget {
  const NotificationsLargeCard(
      {required this.notices, required this.onTap, super.key});

  final List<NoticeItem> notices;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HomeCardShell(
      title: '最新通知',
      icon: Icons.notifications_active,
      badge: '${notices.length}',
      onTap: onTap,
      child: notices.isEmpty
          ? const EmptyState(message: '暂无通知')
          : Column(
              children: [
                for (final item in notices.take(4)) _NoticeRow(item: item),
              ],
            ),
    );
  }
}

class NotificationsMediumCard extends StatelessWidget {
  const NotificationsMediumCard(
      {required this.notices, required this.onTap, super.key});

  final List<NoticeItem> notices;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HomeCardShell(
      title: '最新通知',
      icon: Icons.notifications_active,
      badge: '${notices.length}',
      onTap: onTap,
      child: notices.isEmpty
          ? const EmptyState(message: '暂无通知')
          : Column(
              children: [
                for (final item in notices.take(2)) _NoticeRow(item: item),
              ],
            ),
    );
  }
}

class NotificationsSmallCard extends StatelessWidget {
  const NotificationsSmallCard(
      {required this.notices, required this.onTap, super.key});

  final List<NoticeItem> notices;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return HomeCardShell(
      title: '通知',
      icon: Icons.notifications_active,
      badge: '${notices.length}',
      onTap: onTap,
      compact: true,
      child: notices.isEmpty
          ? Center(
              child: Text('暂无',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)))
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in notices.take(2))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• ${item.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.item});

  final NoticeItem item;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          const IconBadge(icon: Icons.campaign, size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(item.summary ?? item.category,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
