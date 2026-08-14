import 'package:flutter/material.dart';

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w800)),
    );
  }
}

class IconBadge extends StatelessWidget {
  const IconBadge({super.key, required this.icon, this.size = 40});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(size >= 38 ? 16 : 12),
      ),
      child:
          Icon(icon, size: size * 0.48, color: colorScheme.onPrimaryContainer),
    );
  }
}

class MetricPill extends StatelessWidget {
  const MetricPill({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.width,
    this.dense = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final double? width;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final content = Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 12,
        vertical: dense ? 6 : 9,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(dense ? 12 : 16),
      ),
      child: Row(
        mainAxisSize: width == null ? MainAxisSize.min : MainAxisSize.max,
        children: [
          Icon(icon, size: dense ? 13 : 15, color: colorScheme.primary),
          SizedBox(width: dense ? 4 : 6),
          Flexible(
            child: Text(
              dense ? '$label$value' : '$label $value',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: dense ? 12 : null,
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (width != null) return SizedBox(width: width, child: content);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: (MediaQuery.sizeOf(context).width - 56)
            .clamp(136.0, 420.0)
            .toDouble(),
      ),
      child: content,
    );
  }
}
