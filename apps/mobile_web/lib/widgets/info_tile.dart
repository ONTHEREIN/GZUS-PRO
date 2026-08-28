import 'package:flutter/material.dart';

import '../gzus_design.dart';
import '../responsive/breakpoints.dart';

/// 信息磁贴。
///
/// 不再固定宽度，而是尽可能占满父容器分配的空间；调用方通常将其放入
/// [Wrap] 或 [GridView]，让父容器决定每行数量。
class InfoTile extends StatelessWidget {
  const InfoTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.minWidth = 148.0,
    this.maxWidth = 260.0,
  });

  final String label;
  final String value;
  final IconData? icon;

  /// 最小宽度，用于在 [Wrap] 中约束子项。
  final double minWidth;

  /// 最大宽度，避免在超宽容器中过度拉伸。
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return GzusLayout(
      builder: (context, breakpoint) {
        final compact = breakpoint == GzusBreakpoint.compact;
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        return ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: minWidth,
            maxWidth: maxWidth,
            minHeight: compact ? 76 : 88,
          ),
          child: Container(
            padding: EdgeInsets.all(compact ? 10 : 14),
            decoration: BoxDecoration(
              color: gzusSurface(context),
              borderRadius: BorderRadius.circular(GzusRadii.md),
              border: Border.all(color: gzusBorder(context)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (icon != null) ...[
                  Icon(icon,
                      size: compact ? 18 : 22, color: colorScheme.primary),
                  SizedBox(width: compact ? 8 : 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
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
      },
    );
  }
}

class AccentPanel extends StatelessWidget {
  const AccentPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GzusLayout(
      builder: (context, breakpoint) {
        final compact = breakpoint == GzusBreakpoint.compact;
        return Container(
          padding: EdgeInsets.all(compact ? 12 : 16),
          decoration: BoxDecoration(
            color: gzusSurfaceSoft(context),
            borderRadius: BorderRadius.circular(GzusRadii.md),
            border: Border.all(color: gzusBorder(context)),
          ),
          child: child,
        );
      },
    );
  }
}
