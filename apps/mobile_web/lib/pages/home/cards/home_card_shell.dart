import 'package:flutter/material.dart';

import '../../../gzus_design.dart';
import '../../../responsive/spacing.dart';
import '../../../widgets/scale_tap.dart';

/// 首页模块卡片基础容器。
///
/// 所有大/中/小模块统一使用该容器，仅在内部内容上区分信息密度。
enum HomeCardDensity {
  large,
  medium,
  small,
}

class HomeCardShell extends StatelessWidget {
  const HomeCardShell({
    required this.title,
    required this.icon,
    required this.child,
    required this.density,
    this.badge,
    this.onTap,
    super.key,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final HomeCardDensity density;
  final String? badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accentSoft = GzusColors.softColorOf(cs.primary);

    final isSmall = density == HomeCardDensity.small;
    final isLarge = density == HomeCardDensity.large;
    final iconSize = isSmall ? 16.0 : 19.0;
    final iconBoxSize = isSmall ? 28.0 : 34.0;
    final iconBoxRadius = isSmall ? 10.0 : 12.0;
    final titleStyle = isSmall
        ? Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            )
        : GzusTextStyles.moduleTitle(context);
    final headerSpacing = isSmall ? 8.0 : (isLarge ? 14.0 : 10.0);
    final padding = isSmall
        ? const EdgeInsets.all(GzusSpacing.m)
        : EdgeInsets.all(isLarge ? GzusSpacing.l : GzusSpacing.m);
    final badgePadding = isSmall
        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
        : const EdgeInsets.symmetric(horizontal: 8, vertical: 3);

    final content = Container(
      key: ValueKey('home-card-$title'),
      decoration: BoxDecoration(
        color: gzusSurface(context),
        borderRadius: BorderRadius.circular(GzusRadii.lg),
        border: Border.all(color: gzusBorder(context)),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: iconBoxSize,
                  height: iconBoxSize,
                  decoration: BoxDecoration(
                    color: accentSoft,
                    borderRadius: BorderRadius.circular(iconBoxRadius),
                  ),
                  child: Icon(icon, size: iconSize, color: cs.primary),
                ),
                SizedBox(width: isSmall ? 8 : 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                ),
                if (badge != null)
                  Container(
                    padding: badgePadding,
                    decoration: BoxDecoration(
                      color: accentSoft,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      badge!,
                      style: TextStyle(
                        color: cs.primary,
                        fontSize: isSmall ? 10 : 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(height: headerSpacing),
            Expanded(
              child: child,
            ),
          ],
        ),
      ),
    );

    if (onTap == null) return content;
    return ScaleTap(
      onTap: onTap,
      borderRadius: BorderRadius.circular(GzusRadii.lg),
      child: content,
    );
  }
}

/// 通用信息行：标签 + 值。
class HomeInfoLine extends StatelessWidget {
  const HomeInfoLine(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// 通用元数据标签：图标 + 文本。
class HomeMeta extends StatelessWidget {
  const HomeMeta({required this.icon, required this.text, super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 144),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 4),
          Flexible(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
