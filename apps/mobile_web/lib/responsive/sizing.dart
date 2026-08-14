import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'breakpoints.dart';

/// 通用尺寸约束工具。
abstract final class GzusSizing {
  const GzusSizing._();

  /// 将 [value] 限制在 [min] 与 [max] 之间。
  static double clamp(double value, {double min = 0.0, double? max}) {
    if (max != null && value > max) return max;
    if (value < min) return min;
    return value;
  }

  /// 按比例划分双栏宽度。
  ///
  /// - [ratio]：侧边栏占比，默认 0.38
  /// - [minSide]：侧边栏最小宽度
  /// - [maxSide]：侧边栏最大宽度
  /// 返回 `side`（侧边栏宽度）与 `main`（主内容区宽度）。
  static ({double side, double main}) splitPane(
    double totalWidth, {
    double ratio = 0.38,
    double minSide = 260.0,
    double maxSide = 360.0,
  }) {
    final side = clamp(totalWidth * ratio, min: minSide, max: maxSide);
    final main = math.max(0.0, totalWidth - side);
    return (side: side, main: main);
  }

  /// 在小屏下单列、中屏以上按比例分栏的宽度策略。
  ///
  /// 当 [breakpoint] 为 [GzusBreakpoint.compact] 时返回 `side: 0`，
  /// 调用方应切换为单列垂直堆叠。
  static ({double side, double main}) splitPaneAdaptive(
    double totalWidth,
    GzusBreakpoint breakpoint, {
    double compactRatio = 0.0,
    double mediumRatio = 0.4,
    double expandedRatio = 0.36,
    double largeRatio = 0.34,
    double minSide = 260.0,
    double maxSide = 360.0,
  }) {
    final ratio = responsiveValue<double>(
      breakpoint,
      compact: compactRatio,
      medium: mediumRatio,
      expanded: expandedRatio,
      large: largeRatio,
    );
    if (ratio <= 0 || breakpoint == GzusBreakpoint.compact) {
      return (side: 0.0, main: totalWidth);
    }
    return splitPane(
      totalWidth,
      ratio: ratio,
      minSide: minSide,
      maxSide: maxSide,
    );
  }

  /// 限制内容区最大宽度，避免超宽屏内容过度拉伸。
  static double contentMaxWidth(GzusBreakpoint breakpoint) {
    return responsiveValue<double>(
      breakpoint,
      compact: 720.0,
      medium: 840.0,
      expanded: 1100.0,
      large: 1280.0,
    );
  }
}

/// 居中内容容器，类似原 `_CenteredPage`，但使用统一断点。
class GzusCenteredContent extends StatelessWidget {
  const GzusCenteredContent({
    super.key,
    required this.child,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return GzusLayout(
      builder: (context, breakpoint) {
        final maxWidth = GzusSizing.contentMaxWidth(breakpoint);
        return Align(
          alignment: alignment,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: child,
          ),
        );
      },
    );
  }
}
