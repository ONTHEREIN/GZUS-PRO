import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../home/cards/home_card_shell.dart';

/// 个人资料卡片：大/中/小三种信息密度。
class ProfileLargeCard extends StatelessWidget {
  const ProfileLargeCard({required this.info, required this.onTap, super.key});

  final StudentInfo info;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HomeCardShell(
      title: '个人资料',
      icon: Icons.badge,
      density: HomeCardDensity.large,
      badge: '已认证',
      onTap: onTap,
      child: Row(
        children: [
          CircleAvatar(
            radius: 36,
            child: Text(info.name.isEmpty ? '-' : info.name.characters.first),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(info.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                HomeInfoLine('学号', info.studentId),
                HomeInfoLine('专业', info.major ?? '-'),
                HomeInfoLine('班级', info.className ?? '-'),
                if (info.gender != null) HomeInfoLine('性别', info.gender!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ProfileMediumCard extends StatelessWidget {
  const ProfileMediumCard({required this.info, required this.onTap, super.key});

  final StudentInfo info;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HomeCardShell(
      title: '个人资料',
      icon: Icons.badge,
      density: HomeCardDensity.medium,
      badge: '已认证',
      onTap: onTap,
      child: Row(
        children: [
          CircleAvatar(
            radius: 30,
            child: Text(info.name.isEmpty ? '-' : info.name.characters.first),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(info.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                HomeInfoLine('专业', info.major ?? '-'),
                HomeInfoLine('班级', info.className ?? '-'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ProfileSmallCard extends StatelessWidget {
  const ProfileSmallCard({required this.info, required this.onTap, super.key});

  final StudentInfo info;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HomeCardShell(
      title: '资料',
      icon: Icons.badge,
      density: HomeCardDensity.small,
      onTap: onTap,
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            child: Text(info.name.isEmpty ? '-' : info.name.characters.first),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  info.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800),
                ),
                if (info.className != null)
                  Text(
                    info.className!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
