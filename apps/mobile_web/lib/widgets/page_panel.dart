import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../responsive/breakpoints.dart';
import 'floating_page_scaffold.dart';

Color accentFill(BuildContext context) =>
    Theme.of(context).colorScheme.primary.withValues(alpha: 0.12);

class PagePanel extends StatefulWidget {
  const PagePanel({
    super.key,
    required this.title,
    required this.child,
    this.expandChild = false,
    this.icon,
    this.trailing,
    this.headerScrollProgress,
  });

  final String title;
  final Widget child;
  final bool expandChild;
  final IconData? icon;
  final Widget? trailing;
  final ValueListenable<double>? headerScrollProgress;

  @override
  State<PagePanel> createState() => _PagePanelState();
}

class _PagePanelState extends State<PagePanel> {
  final GlobalKey _headerKey = GlobalKey();
  final ValueNotifier<double> _localProgress = ValueNotifier(0);
  double _headerHeight = 0;

  @override
  void dispose() {
    _localProgress.dispose();
    super.dispose();
  }

  bool _onBodyScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final next =
        (notification.metrics.pixels.clamp(0.0, headerFloatingScrollDistance) /
                headerFloatingScrollDistance)
            .toDouble();
    if ((_localProgress.value - next).abs() >= 0.001) {
      _localProgress.value = next;
    }
    return false;
  }

  bool _onHeaderSizeChanged(SizeChangedLayoutNotification notification) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final height = _headerKey.currentContext?.size?.height;
      if (height == null || (height - _headerHeight).abs() < 0.5) return;
      setState(() => _headerHeight = height);
    });
    return false;
  }

  EdgeInsets _headerPadding(GzusBreakpoint breakpoint, double progress) {
    final normal = switch (breakpoint) {
      GzusBreakpoint.compact =>
        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      GzusBreakpoint.medium =>
        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      GzusBreakpoint.expanded ||
      GzusBreakpoint.large =>
        const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
    };
    final floating = switch (breakpoint) {
      GzusBreakpoint.compact =>
        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      GzusBreakpoint.medium =>
        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      GzusBreakpoint.expanded ||
      GzusBreakpoint.large =>
        const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
    };
    return EdgeInsets.lerp(normal, floating, progress)!;
  }

  Widget _buildHeader(
    BuildContext context,
    GzusBreakpoint breakpoint,
    double progress,
  ) {
    final theme = Theme.of(context);
    final compact = breakpoint == GzusBreakpoint.compact;
    final content = Row(
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon!,
              size: compact ? 20 : 22, color: theme.colorScheme.primary),
          SizedBox(width: compact ? 8 : 10),
        ],
        Expanded(
          child: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (compact
                    ? theme.textTheme.titleLarge
                    : theme.textTheme.headlineSmall)
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        if (widget.trailing != null) ...[
          SizedBox(width: compact ? 8 : 12),
          widget.trailing!,
        ],
      ],
    );
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: _onHeaderSizeChanged,
      child: SizeChangedLayoutNotifier(
        child: KeyedSubtree(
          key: const ValueKey('page-panel-banner'),
          child: FloatingHeaderSurface(
            key: _headerKey,
            progress: progress,
            normalPadding: _headerPadding(breakpoint, 0),
            floatingPadding: _headerPadding(breakpoint, 1),
            semanticsLabel: '悬浮页面标题区域',
            child: content,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GzusLayout(
      builder: (context, breakpoint) {
        final compact = breakpoint == GzusBreakpoint.compact;
        final progress = widget.headerScrollProgress ?? _localProgress;
        final body = widget.headerScrollProgress == null
            ? NotificationListener<ScrollNotification>(
                onNotification: _onBodyScroll,
                child: widget.child,
              )
            : widget.child;
        return Padding(
          padding: EdgeInsets.only(bottom: compact ? 4 : 8),
          child: ValueListenableBuilder<double>(
            valueListenable: progress,
            child: body,
            builder: (context, value, child) {
              final header = _buildHeader(context, breakpoint, value);
              final gap = compact ? 10.0 : 16.0;
              if (!widget.expandChild) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [header, SizedBox(height: gap), child!],
                );
              }
              final headerInset =
                  (_headerHeight == 0 ? 56.0 : _headerHeight) + gap;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.only(top: headerInset),
                      child: child,
                    ),
                  ),
                  Positioned(top: 0, left: 0, right: 0, child: header),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
