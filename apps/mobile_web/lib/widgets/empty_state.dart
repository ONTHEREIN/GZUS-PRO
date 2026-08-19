import 'package:flutter/material.dart';

import '../gzus_design.dart';
import '../responsive/spacing.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    this.title,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.iconColor,
    this.iconBackgroundColor,
    this.actionLabel,
    this.onAction,
  });

  final String? title;
  final String message;
  final IconData icon;
  final Color? iconColor;
  final Color? iconBackgroundColor;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final effectiveIconColor = iconColor ?? colorScheme.onSurfaceVariant;
    final effectiveBgColor =
        iconBackgroundColor ?? gzusSurfaceSoft(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(GzusSpacing.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: effectiveBgColor,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(
                icon,
                size: 26,
                color: effectiveIconColor,
              ),
            ),
            const SizedBox(height: GzusSpacing.l),
            if (title != null) ...[
              Text(
                title!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: GzusSpacing.s),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: GzusSpacing.l),
              FilledButton.tonal(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误状态占位组件。
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.onRetry,
  });

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      title: '加载失败',
      message: message,
      icon: Icons.error_outline,
      iconColor: Theme.of(context).colorScheme.error,
      iconBackgroundColor:
          Theme.of(context).colorScheme.errorContainer,
      actionLabel: onRetry != null ? '重试' : null,
      onAction: onRetry,
    );
  }
}

/// 离线状态占位组件。
class OfflineState extends StatelessWidget {
  const OfflineState({
    super.key,
    this.onRetry,
  });

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      title: '网络连接异常',
      message: '请检查网络后重试，已缓存的数据仍可浏览。',
      icon: Icons.cloud_off_outlined,
      iconColor: Theme.of(context).colorScheme.tertiary,
      iconBackgroundColor:
          Theme.of(context).colorScheme.tertiaryContainer,
      actionLabel: onRetry != null ? '刷新' : null,
      onAction: onRetry,
    );
  }
}
