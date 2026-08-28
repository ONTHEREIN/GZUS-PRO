import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../gzus_design.dart';
import 'liquid_glass.dart';

/// 标题从常规面板连续过渡为玻璃悬浮表面的滚动距离。
const headerFloatingScrollDistance = 72.0;

/// 常规页面标题的中性底材；滚动后平滑叠加玻璃表面。
class FrostedBanner extends StatelessWidget {
  const FrostedBanner({
    super.key,
    required this.child,
    required this.padding,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: gzusSurface(context).withValues(alpha: dark ? 0.78 : 0.88),
        borderRadius: BorderRadius.circular(GzusRadii.lg),
        border: Border.all(color: gzusBorder(context)),
        boxShadow: gzusShadow(context),
      ),
      child: child,
    );
  }
}

/// 复用标题表面。内容与背景始终保持在同一个布局树中，避免临界滚动位置跳变。
class FloatingHeaderSurface extends StatelessWidget {
  const FloatingHeaderSurface({
    super.key,
    required this.child,
    required this.progress,
    required this.normalPadding,
    required this.floatingPadding,
    required this.semanticsLabel,
  });

  final Widget child;
  final double progress;
  final EdgeInsets normalPadding;
  final EdgeInsets floatingPadding;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final value = progress.clamp(0.0, 1.0).toDouble();
    final radius = BorderRadius.circular(
      lerpDouble(GzusRadii.lg, GzusRadii.xl, value)!,
    );
    final padding = EdgeInsets.lerp(normalPadding, floatingPadding, value)!;

    return Semantics(
      label: semanticsLabel,
      container: true,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 1 - value,
                child: const FrostedBanner(
                  padding: EdgeInsets.zero,
                  child: SizedBox.expand(),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Opacity(
                  opacity: value,
                  child: LiquidGlassSurface(
                    key: const ValueKey('page-panel-glass-surface'),
                    padding: EdgeInsets.zero,
                    borderRadius: radius,
                    material: LiquidGlassMaterial.clear,
                    semanticsLabel: semanticsLabel,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// 带连续玻璃悬浮顶栏的应用内二级页面壳。
class FloatingPageScaffold extends StatefulWidget {
  const FloatingPageScaffold({
    super.key,
    required this.title,
    required this.icon,
    required this.actions,
    required this.bottom,
    required this.floatingActionButton,
    required this.body,
  });

  final String title;
  final IconData? icon;
  final List<Widget> actions;
  final PreferredSizeWidget? bottom;
  final Widget? floatingActionButton;
  final Widget body;

  @override
  State<FloatingPageScaffold> createState() => _FloatingPageScaffoldState();
}

class _FloatingPageScaffoldState extends State<FloatingPageScaffold> {
  final ValueNotifier<double> _progress = ValueNotifier(0);

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final next =
        (notification.metrics.pixels.clamp(0.0, headerFloatingScrollDistance) /
                headerFloatingScrollDistance)
            .toDouble();
    if ((_progress.value - next).abs() >= 0.001) _progress.value = next;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      floatingActionButton: widget.floatingActionButton,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<double>(
              valueListenable: _progress,
              builder: (context, value, _) => FloatingHeaderSurface(
                progress: value,
                normalPadding: const EdgeInsets.fromLTRB(16, 10, 12, 8),
                floatingPadding: const EdgeInsets.fromLTRB(16, 10, 12, 8),
                semanticsLabel: '悬浮页面标题区域',
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (canPop)
                          IconButton(
                            onPressed: Navigator.of(context).pop,
                            icon: const Icon(Icons.arrow_back),
                            tooltip: '返回',
                          ),
                        if (widget.icon != null) ...[
                          Icon(widget.icon!, color: theme.colorScheme.primary),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        ...widget.actions,
                      ],
                    ),
                    if (widget.bottom != null) widget.bottom!,
                  ],
                ),
              ),
            ),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScrollNotification,
                child: widget.body,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
