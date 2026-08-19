import 'package:flutter/material.dart';

/// OneGZUS 统一动效时长与曲线。
///
/// 所有动画应优先使用本类常量，保持全应用动效节奏一致。
abstract final class GzusDurations {
  const GzusDurations._();

  /// 极短：用于微交互（按钮缩放、图标切换）。
  static const Duration instant = Duration(milliseconds: 100);

  /// 快速：用于小型 UI 反馈（snackbar、tooltip、小部件显隐）。
  static const Duration fast = Duration(milliseconds: 150);

  /// 常规：用于页面过渡、tab 切换、展开折叠。
  static const Duration normal = Duration(milliseconds: 250);

  /// 缓慢：用于大型元素入场、强调动画。
  static const Duration slow = Duration(milliseconds: 350);

  /// 页面入场：登录页、引导页等完整页面过渡。
  static const Duration pageEntrance = Duration(milliseconds: 450);
}

abstract final class GzusCurves {
  const GzusCurves._();

  /// 出场与入场都柔和，适合大多数过渡动画。
  static const Curve standard = Curves.easeInOutCubic;

  /// 出场快、收尾柔和，适合元素进入屏幕。
  static const Curve enter = Curves.easeOutCubic;

  /// 开始柔和、出场快，适合元素离开屏幕。
  static const Curve exit = Curves.easeInCubic;

  /// 带有轻微弹性，适合按钮按压、开关切换。
  static const Curve emphasis = Curves.easeOutBack;
}

/// 常用动画构造辅助。
abstract final class GzusAnimations {
  const GzusAnimations._();

  /// 页面淡入 + 上滑入场。
  static Widget fadeSlideIn({
    required Widget child,
    required Animation<double> animation,
    Offset slideBegin = const Offset(0, 0.04),
  }) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: GzusCurves.enter),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: slideBegin,
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: GzusCurves.enter)),
        child: child,
      ),
    );
  }

  /// 列表项依次入场动画间隔。
  static Duration staggerDelay(int index, {Duration base = const Duration(milliseconds: 40)}) {
    return base * index;
  }
}
