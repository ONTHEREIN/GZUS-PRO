import 'package:flutter/material.dart';

/// OneGZUS 统一响应式断点。
///
/// 全工程应优先使用本枚举，替代之前散落的 600/640/720/760/980 等手写阈值。
enum GzusBreakpoint {
  /// 手机竖屏，宽度 < 600
  compact,

  /// 大手机/小平板，600 <= 宽度 < 840
  medium,

  /// 平板/小桌面，840 <= 宽度 < 1200
  expanded,

  /// 桌面/宽屏，宽度 >= 1200
  large,
}

/// 断点阈值（单位：逻辑像素）。
abstract final class GzusBreakpoints {
  const GzusBreakpoints._();

  /// compact / medium 分界
  static const double compact = 600.0;

  /// medium / expanded 分界；与 DashboardShell 的底栏/侧边栏切换点（原 720）拉开差距，
  /// 避免 600~720 区间行为冲突。
  static const double medium = 840.0;

  /// expanded / large 分界；与 DashboardShell 的紧凑侧边栏切换点（原 1024）对齐。
  static const double expanded = 1200.0;
}

extension GzusBreakpointX on double {
  /// 将宽度映射到断点。
  GzusBreakpoint get gzusBreakpoint {
    if (this < GzusBreakpoints.compact) return GzusBreakpoint.compact;
    if (this < GzusBreakpoints.medium) return GzusBreakpoint.medium;
    if (this < GzusBreakpoints.expanded) return GzusBreakpoint.expanded;
    return GzusBreakpoint.large;
  }
}

extension GzusBreakpointContext on BuildContext {
  /// 基于屏幕宽度的当前断点。
  ///
  /// 注意：如果组件嵌套在侧边栏/面板内，应优先使用 [GzusLayout] 或 [LayoutBuilder]
  /// 获取父容器宽度，而不是直接调用此方法。
  GzusBreakpoint get gzusBreakpoint {
    return MediaQuery.sizeOf(this).width.gzusBreakpoint;
  }

  bool get isCompact => gzusBreakpoint == GzusBreakpoint.compact;
  bool get isMedium => gzusBreakpoint == GzusBreakpoint.medium;
  bool get isExpanded => gzusBreakpoint == GzusBreakpoint.expanded;
  bool get isLarge => gzusBreakpoint == GzusBreakpoint.large;

  /// 是否进入“宽屏”布局（展开侧边栏、左右分栏）。
  bool get isWide =>
      gzusBreakpoint == GzusBreakpoint.expanded ||
      gzusBreakpoint == GzusBreakpoint.large;
}

/// 将断点传给子树的便捷 Widget。
///
/// 用法：
/// ```dart
/// GzusLayout(
///   builder: (context, breakpoint) {
///     final compact = breakpoint == GzusBreakpoint.compact;
///     return ...;
///   },
/// )
/// ```
class GzusLayout extends StatelessWidget {
  const GzusLayout({
    super.key,
    required this.builder,
    this.child,
  });

  final Widget Function(BuildContext context, GzusBreakpoint breakpoint)
      builder;

  /// 可选的静态子组件，不参与断点计算，仅用于包装。
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final breakpoint = constraints.maxWidth.gzusBreakpoint;
        return builder(context, breakpoint);
      },
    );
  }
}

/// 按断点选择值的便捷函数。
///
/// 未提供的断点会向前继承最近较小的值：
/// - 只传 [compact] 时，其它断点都用 [compact]。
/// - 只传 [compact] 和 [medium] 时，[expanded]/[large] 用 [medium]。
T responsiveValue<T>(
  GzusBreakpoint breakpoint, {
  required T compact,
  T? medium,
  T? expanded,
  T? large,
}) {
  switch (breakpoint) {
    case GzusBreakpoint.compact:
      return compact;
    case GzusBreakpoint.medium:
      return medium ?? compact;
    case GzusBreakpoint.expanded:
      return expanded ?? medium ?? compact;
    case GzusBreakpoint.large:
      return large ?? expanded ?? medium ?? compact;
  }
}
