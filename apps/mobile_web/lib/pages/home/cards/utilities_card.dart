import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../../responsive/spacing.dart';
import '../../home/cards/home_card_shell.dart';

/// 水电余额卡片：大/中/小三种信息密度。
class UtilitiesLargeCard extends StatelessWidget {
  const UtilitiesLargeCard(
      {required this.summary, required this.onTap, super.key});

  final EcardSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (!summary.isBound) {
      return _UnboundUtilitiesCard(onTap: onTap, compact: false);
    }
    return HomeCardShell(
      title: '水电费余额',
      icon: Icons.water_drop,
      density: HomeCardDensity.large,
      badge: '实时',
      onTap: onTap,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _UtilityMini(
                  icon: Icons.ac_unit,
                  label: '冷水',
                  value: summary.coldWaterText ?? '-',
                  color: _coldWaterColor(context),
                ),
              ),
              const SizedBox(width: GzusSpacing.s),
              Expanded(
                child: _UtilityMini(
                  icon: Icons.local_fire_department,
                  label: '热水',
                  value: summary.hotWaterText ?? '-',
                  color: _hotWaterColor(context),
                ),
              ),
              const SizedBox(width: GzusSpacing.s),
              Expanded(
                child: _UtilityMini(
                  icon: Icons.electric_bolt,
                  label: '电费',
                  value: summary.powerText ?? '-',
                  color: _powerColor(context),
                ),
              ),
            ],
          ),
          if (summary.roomDisplay != null) ...[
            const SizedBox(height: GzusSpacing.m),
            Text(
              summary.roomDisplay!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class UtilitiesMediumCard extends StatelessWidget {
  const UtilitiesMediumCard(
      {required this.summary, required this.onTap, super.key});

  final EcardSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (!summary.isBound) {
      return _UnboundUtilitiesCard(onTap: onTap, compact: false);
    }
    return HomeCardShell(
      title: '水电余额',
      icon: Icons.water_drop,
      density: HomeCardDensity.medium,
      badge: '实时',
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: _UtilityMini(
              icon: Icons.ac_unit,
              label: '冷水',
              value: summary.coldWaterText ?? '-',
              color: _coldWaterColor(context),
            ),
          ),
          const SizedBox(width: GzusSpacing.s),
          Expanded(
            child: _UtilityMini(
              icon: Icons.local_fire_department,
              label: '热水',
              value: summary.hotWaterText ?? '-',
              color: _hotWaterColor(context),
            ),
          ),
          const SizedBox(width: GzusSpacing.s),
          Expanded(
            child: _UtilityMini(
              icon: Icons.electric_bolt,
              label: '电费',
              value: summary.powerText ?? '-',
              color: _powerColor(context),
            ),
          ),
        ],
      ),
    );
  }
}

class UtilitiesSmallCard extends StatelessWidget {
  const UtilitiesSmallCard(
      {required this.summary, required this.onTap, super.key});

  final EcardSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (!summary.isBound) {
      return _UnboundUtilitiesCard(onTap: onTap, compact: true);
    }
    return HomeCardShell(
      title: '水电',
      icon: Icons.water_drop,
      density: HomeCardDensity.small,
      badge: '实时',
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: _UtilityMini(
              icon: Icons.electric_bolt,
              label: '电费余额',
              value: summary.powerText ?? '-',
              color: _powerColor(context),
              compact: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _UnboundUtilitiesCard extends StatelessWidget {
  const _UnboundUtilitiesCard({required this.onTap, required this.compact});

  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return HomeCardShell(
      title: compact ? '宿舍' : '宿舍绑定',
      icon: Icons.home_work,
      density: compact ? HomeCardDensity.small : HomeCardDensity.medium,
      badge: '未绑定',
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.add_home_outlined,
              size: compact ? 28 : 36,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 8),
          Text(
            '点击绑定宿舍',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
          ),
          if (!compact) ...[
            const SizedBox(height: 6),
            Text(
              '绑定后可查看水电余额',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

class _UtilityMini extends StatelessWidget {
  const _UtilityMini({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: BoxConstraints(minHeight: compact ? 64 : 96),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: compact ? 18 : 22),
          const SizedBox(height: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: compact ? 10 : null,
                ),
          ),
          const SizedBox(height: GzusSpacing.xs),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: compact ? 14 : null,
                ),
          ),
        ],
      ),
    );
  }
}

Color _coldWaterColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFF4FC3F7) : const Color(0xFF0288D1);
}

Color _hotWaterColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFFFF8A65) : const Color(0xFFD84315);
}

Color _powerColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? const Color(0xFFFFD54F) : const Color(0xFFF9A825);
}
