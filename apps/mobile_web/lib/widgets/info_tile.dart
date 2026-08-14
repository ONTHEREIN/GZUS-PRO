import 'package:flutter/material.dart';

import '../gzus_design.dart';

class InfoTile extends StatelessWidget {
  const InfoTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
  });

  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compact = screenWidth < 600;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tileWidth = compact
        ? ((screenWidth - 30) / 2).clamp(136.0, 220.0).toDouble()
        : 220.0;
    return SizedBox(
      width: tileWidth,
      height: compact ? 88 : 100,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.all(compact ? 10 : 14),
        decoration: BoxDecoration(
          color: gzusSurface(context),
          borderRadius: BorderRadius.circular(compact ? 16 : 20),
          border: Border.all(color: gzusBorder(context)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) ...[
              Icon(icon, size: compact ? 18 : 22, color: colorScheme.primary),
              SizedBox(width: compact ? 8 : 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: (compact
                            ? theme.textTheme.bodyMedium
                            : theme.textTheme.titleMedium)
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AccentPanel extends StatelessWidget {
  const AccentPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Container(
      padding: EdgeInsets.all(compact ? 12 : 16),
      decoration: BoxDecoration(
        color: gzusSurfaceSoft(context),
        borderRadius: BorderRadius.circular(compact ? 16 : 20),
        border: Border.all(color: gzusBorder(context)),
      ),
      child: child,
    );
  }
}
