import 'dart:ui';

import 'package:flutter/material.dart';

import '../gzus_design.dart';
import '../responsive/breakpoints.dart';
import '../responsive/spacing.dart';

Color accentFill(BuildContext context) =>
    Theme.of(context).colorScheme.primary.withValues(alpha: 0.12);

class FrostedBanner extends StatelessWidget {
  const FrostedBanner({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(GzusRadii.lg),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: gzusSurface(context).withValues(alpha: dark ? 0.62 : 0.72),
            borderRadius: BorderRadius.circular(GzusRadii.lg),
            border: Border.all(
              color: Colors.white.withValues(alpha: dark ? 0.10 : 0.55),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.18 : 0.045),
                blurRadius: 22,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class PagePanel extends StatelessWidget {
  const PagePanel({
    super.key,
    required this.title,
    required this.child,
    this.expandChild = false,
    this.icon,
    this.trailing,
  });

  final String title;
  final Widget child;
  final bool expandChild;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return GzusLayout(
      builder: (context, breakpoint) {
        final compact = breakpoint == GzusBreakpoint.compact;
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FrostedBanner(
              padding: GzusInsets.panelHeader(context),
              child: Row(
                children: [
                  if (icon != null) ...[
                    Container(
                      width: compact ? 34 : 42,
                      height: compact ? 34 : 42,
                      decoration: BoxDecoration(
                        color: accentFill(context),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon!,
                          size: compact ? 19 : 22, color: colorScheme.primary),
                    ),
                    SizedBox(width: compact ? 8 : 12),
                  ],
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: (compact
                              ? theme.textTheme.titleLarge
                              : theme.textTheme.headlineSmall)
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (trailing != null) ...[
                    SizedBox(width: compact ? 8 : 12),
                    trailing!,
                  ],
                ],
              ),
            ),
            SizedBox(height: compact ? 6 : 14),
            if (expandChild) Expanded(child: child) else child,
          ],
        );
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 4 : 8,
            vertical: compact ? 4 : 8,
          ),
          child: content,
        );
      },
    );
  }
}
