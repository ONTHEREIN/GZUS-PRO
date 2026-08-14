/// 根据可用宽度计算网格列数。
int contentGridColumns(
  double width, {
  required double minTileWidth,
  int maxColumns = 4,
}) {
  if (width < minTileWidth * 1.6) return 1;
  return (width / minTileWidth).floor().clamp(2, maxColumns);
}
