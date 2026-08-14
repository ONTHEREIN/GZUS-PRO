import 'package:flutter/material.dart';

import '../responsive/breakpoints.dart';

/// 根据可用宽度计算网格列数。
int contentGridColumns(
  double width, {
  required double minTileWidth,
  int maxColumns = 4,
}) {
  if (width < minTileWidth * 1.6) return 1;
  return (width / minTileWidth).floor().clamp(2, maxColumns);
}

/// 与 [contentGridColumns] 配套使用的自适应网格布局。
SliverGridDelegate adaptiveGridDelegate({
  required double minTileWidth,
  double maxCrossAxisExtent = double.infinity,
  int maxColumns = 4,
  double mainAxisSpacing = 12.0,
  double crossAxisSpacing = 12.0,
  double childAspectRatio = 1.0,
  double? mainAxisExtent,
}) {
  return SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent:
        maxCrossAxisExtent.isFinite ? maxCrossAxisExtent : minTileWidth * 1.4,
    mainAxisSpacing: mainAxisSpacing,
    crossAxisSpacing: crossAxisSpacing,
    childAspectRatio: childAspectRatio,
    mainAxisExtent: mainAxisExtent,
  );
}

/// 按断点返回默认网格列数，用于无特殊要求的列表/卡片网格。
int gridColumnsForBreakpoint(GzusBreakpoint breakpoint, {int maxColumns = 4}) {
  return switch (breakpoint) {
    GzusBreakpoint.compact => 1,
    GzusBreakpoint.medium => 2,
    GzusBreakpoint.expanded => 3,
    GzusBreakpoint.large => maxColumns,
  };
}
