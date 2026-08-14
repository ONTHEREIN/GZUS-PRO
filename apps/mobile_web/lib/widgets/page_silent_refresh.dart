import 'package:flutter/widgets.dart';

/// 页面静默刷新能力：导航壳在 Tab 重新激活时调用 [silentRefresh]，
/// 页面自行重拉数据（配合 AsyncPanel 的 stale-while-revalidate，不显示加载动画）。
mixin PageSilentRefresh<T extends StatefulWidget> on State<T> {
  void silentRefresh();
}
