import 'package:flutter/material.dart';

import '../gzus_design.dart';
import '../responsive/breakpoints.dart';
import 'badges.dart';
import 'page_panel.dart';

class MobileRecordCard extends StatelessWidget {
  const MobileRecordCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.rows,
    this.highlight = false,
    this.extraRows,
    this.trailing,
    this.highlighted = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<(IconData, String, String)> rows;
  final bool highlight;
  final List<Widget>? extraRows;
  final Widget? trailing;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return GzusLayout(
      builder: (context, breakpoint) {
        final compact = breakpoint == GzusBreakpoint.compact;
        final colorScheme = Theme.of(context).colorScheme;
        final cardColor = highlighted
            ? colorScheme.primaryContainer.withValues(alpha: 0.55)
            : highlight
                ? colorScheme.secondaryContainer.withValues(alpha: 0.5)
                : null;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: cardColor ?? gzusSurface(context),
            borderRadius: BorderRadius.circular(compact ? 16 : 20),
            border: Border.all(color: gzusBorder(context)),
          ),
          child: Padding(
            padding: EdgeInsets.all(compact ? 12 : 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IconBadge(icon: icon, size: compact ? 32 : 40),
                    SizedBox(width: compact ? 10 : 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: compact ? 15 : 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (trailing != null) ...[
                                const SizedBox(width: 8),
                                trailing!,
                              ],
                            ],
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              subtitle!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                                fontSize: compact ? 12 : 13,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (rows.isNotEmpty) ...[
                  SizedBox(height: compact ? 10 : 14),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final itemWidth = compact
                          ? ((constraints.maxWidth - 8) / 2).clamp(118.0, 220.0)
                          : null;
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final row in rows)
                            MetricPill(
                              icon: row.$1,
                              label: row.$2,
                              value: row.$3,
                              width: itemWidth?.toDouble(),
                              dense: compact,
                            ),
                        ],
                      );
                    },
                  ),
                ],
                if (extraRows != null && extraRows!.isNotEmpty) ...[
                  SizedBox(height: compact ? 10 : 14),
                  ...extraRows!,
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class SimpleTable extends StatelessWidget {
  const SimpleTable({
    super.key,
    required this.headers,
    required this.rows,
    this.highlightedRows = const {},
    this.rowHighlightColors = const {},
    this.rowTextColors = const {},
    this.columnFlexs = const [],
    this.minColumnWidth = 88.0,
  });

  final List<String> headers;
  final List<List<String>> rows;
  final Set<int> highlightedRows;
  final Map<int, Color> rowHighlightColors;
  final Map<int, Color> rowTextColors;
  final List<int> columnFlexs;

  /// 每列最小宽度。若同时提供 [columnFlexs]，则按 flex 比例放大最小宽度。
  final double minColumnWidth;

  @override
  Widget build(BuildContext context) {
    final border = BorderSide(color: gzusBorder(context));
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalFlex = columnFlexs.isEmpty
            ? headers.length
            : columnFlexs.take(headers.length).fold<int>(0, (a, b) => a + b);
        final minWidth = totalFlex * minColumnWidth;
        final tableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth.clamp(minWidth, double.infinity).toDouble()
            : minWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Column(
                children: [
                  SimpleTableRow(
                      values: headers,
                      strong: true,
                      border: border,
                      columnFlexs: columnFlexs,
                      minColumnWidth: minColumnWidth),
                  for (var i = 0; i < rows.length; i++)
                    SimpleTableRow(
                      values: rows[i],
                      border: border,
                      highlighted: highlightedRows.contains(i),
                      highlightColor: rowHighlightColors[i],
                      textColor: rowTextColors[i],
                      columnFlexs: columnFlexs,
                      minColumnWidth: minColumnWidth,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class SimpleTableRow extends StatelessWidget {
  const SimpleTableRow({
    super.key,
    required this.values,
    required this.border,
    this.strong = false,
    this.highlighted = false,
    this.highlightColor,
    this.textColor,
    this.columnFlexs = const [],
    this.minColumnWidth = 88.0,
  });

  final List<String> values;
  final BorderSide border;
  final bool strong;
  final bool highlighted;
  final Color? highlightColor;
  final Color? textColor;
  final List<int> columnFlexs;
  final double minColumnWidth;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        color: highlighted
            ? highlightColor ?? accentFill(context)
            : strong
                ? gzusSurfaceSoft(context)
                : gzusSurface(context),
        border: Border(bottom: border),
      ),
      child: SimpleTableRowContent(
        values: values,
        color: highlighted ? textColor ?? accent : null,
        strong: strong || highlighted,
        columnFlexs: columnFlexs,
        minColumnWidth: minColumnWidth,
      ),
    );
  }
}

class SimpleTableRowContent extends StatelessWidget {
  const SimpleTableRowContent({
    super.key,
    required this.values,
    this.color,
    this.strong = false,
    this.columnFlexs = const [],
    this.minColumnWidth = 88.0,
  });

  final List<String> values;
  final Color? color;
  final bool strong;
  final List<int> columnFlexs;
  final double minColumnWidth;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < values.length; i++)
          Expanded(
            flex: i < columnFlexs.length ? columnFlexs[i] : 1,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: minColumnWidth *
                    (i < columnFlexs.length ? columnFlexs[i] : 1),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: _AutoScrollText(
                  text: values[i],
                  style: TextStyle(
                    color: color,
                    fontWeight: strong ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _AutoScrollText extends StatefulWidget {
  const _AutoScrollText({required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<_AutoScrollText> createState() => _AutoScrollTextState();
}

class _AutoScrollTextState extends State<_AutoScrollText> {
  final _controller = ScrollController();
  bool _needsScroll = false;
  bool _scrollForward = true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScrollChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
  }

  @override
  void didUpdateWidget(covariant _AutoScrollText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _needsScroll = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
    }
  }

  void _checkOverflow() {
    if (!_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    final needs = max > 0;
    if (needs != _needsScroll) {
      setState(() => _needsScroll = needs);
      if (needs) _autoScroll();
    }
  }

  void _onScrollChanged() {
    if (!_controller.hasClients || !_needsScroll) return;
    final pos = _controller.position.pixels;
    final max = _controller.position.maxScrollExtent;
    if (_scrollForward && pos >= max) {
      _scrollForward = false;
      Future.delayed(const Duration(seconds: 2), _autoScroll);
    } else if (!_scrollForward && pos <= 0) {
      _scrollForward = true;
      Future.delayed(const Duration(seconds: 2), _autoScroll);
    }
  }

  void _autoScroll() {
    if (!_controller.hasClients || !_needsScroll || !mounted) return;
    final max = _controller.position.maxScrollExtent;
    _controller.animateTo(
      _scrollForward ? max : 0,
      duration: Duration(milliseconds: (max * 15).round().clamp(800, 3000)),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      controller: _controller,
      child: Text(
        widget.text,
        softWrap: false,
        style: widget.style,
      ),
    );
  }
}
