import 'package:flutter/material.dart';

import 'breakpoints.dart';

/// OneGZUS 统一间距 token。
///
/// 页面和组件应优先使用这些常量，而不是散落的 4/8/12/16/20/24 等手写值。
abstract final class GzusSpacing {
  const GzusSpacing._();

  static const double none = 0.0;
  static const double xs = 4.0;
  static const double s = 8.0;
  static const double m = 12.0;
  static const double l = 16.0;
  static const double xl = 24.0;
  static const double xxl = 32.0;
  static const double xxxl = 48.0;
}

/// 按断点返回统一内边距/外边距。
///
/// 典型用法：
/// ```dart
/// Padding(
///   padding: GzusInsets.page(context),
///   child: ...,
/// )
/// ```
abstract final class GzusInsets {
  const GzusInsets._();

  /// 页面壳与一级内容共用的水平 gutter。
  ///
  /// 标题横幅、页面内容和首页模块必须从同一条垂直基线开始，避免在
  /// 外层与组件内部重复叠加水平留白。
  static double contentGutter(BuildContext context) {
    return responsiveValue<double>(
      context.gzusBreakpoint,
      compact: GzusSpacing.m,
      medium: GzusSpacing.l,
      expanded: GzusSpacing.xl,
      large: GzusSpacing.xxl,
    );
  }

  /// 页面级水平内边距。
  static EdgeInsetsGeometry page(BuildContext context) {
    return EdgeInsets.symmetric(horizontal: contentGutter(context));
  }

  /// 页面内容区顶部内边距（兼顾标题栏/横幅）。
  static EdgeInsetsGeometry pageTop(BuildContext context) {
    return responsiveValue<EdgeInsets>(
      context.gzusBreakpoint,
      compact: const EdgeInsets.only(top: GzusSpacing.m),
      medium: const EdgeInsets.only(top: GzusSpacing.l),
      expanded: const EdgeInsets.only(top: GzusSpacing.xl),
      large: const EdgeInsets.only(top: GzusSpacing.xxl),
    );
  }

  /// 卡片内部内边距。
  static EdgeInsetsGeometry card(BuildContext context) {
    return responsiveValue<EdgeInsets>(
      context.gzusBreakpoint,
      compact: const EdgeInsets.all(GzusSpacing.m),
      medium: const EdgeInsets.all(GzusSpacing.l),
      expanded: const EdgeInsets.all(GzusSpacing.xl),
    );
  }

  /// 卡片紧凑内边距（用于信息磁贴、列表项等）。
  static EdgeInsetsGeometry cardDense(BuildContext context) {
    return responsiveValue<EdgeInsets>(
      context.gzusBreakpoint,
      compact: const EdgeInsets.all(GzusSpacing.s),
      medium: const EdgeInsets.all(GzusSpacing.m),
      expanded: const EdgeInsets.all(GzusSpacing.l),
    );
  }

  /// 面板（PagePanel 标题区）内边距。
  static EdgeInsetsGeometry panelHeader(BuildContext context) {
    return responsiveValue<EdgeInsets>(
      context.gzusBreakpoint,
      compact: const EdgeInsets.symmetric(
        horizontal: GzusSpacing.m,
        vertical: GzusSpacing.s,
      ),
      medium: const EdgeInsets.symmetric(
        horizontal: GzusSpacing.l,
        vertical: GzusSpacing.m,
      ),
      expanded: const EdgeInsets.symmetric(
        horizontal: GzusSpacing.xl,
        vertical: GzusSpacing.m,
      ),
    );
  }

  /// 固定 1:1 比例头像外框尺寸（替代原 112/144 硬编码）。
  static double avatarFrame(BuildContext context) {
    return responsiveValue<double>(
      context.gzusBreakpoint,
      compact: 96.0,
      medium: 112.0,
      expanded: 128.0,
      large: 144.0,
    );
  }
}

/// 按断点返回的圆角（保留现有规范，但提供统一入口）。
abstract final class GzusRadius {
  const GzusRadius._();

  static const double sm = 12.0;
  static const double md = 16.0;
  static const double lg = 20.0;
  static const double xl = 24.0;
}
