import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api_client.dart';
import '../../app_providers.dart';
import '../../gzus_design.dart';
import '../../responsive/breakpoints.dart';
import '../../responsive/sizing.dart';
import '../../responsive/spacing.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/page_panel.dart';
import '../../widgets/page_silent_refresh.dart';

class CreditsPage extends ConsumerStatefulWidget {
  const CreditsPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  ConsumerState<CreditsPage> createState() => _CreditsPageState();
}

class _CreditsPageState extends ConsumerState<CreditsPage>
    with PageSilentRefresh<CreditsPage> {
  Future<void> _refreshCredits() async {
    ref.invalidate(creditsProvider(widget.api));
    await ref.read(creditsProvider(widget.api).future);
  }

  @override
  void silentRefresh() {
    if (!mounted) return;
    ref.invalidate(creditsProvider(widget.api));
  }

  @override
  Widget build(BuildContext context) {
    final creditsFuture = ref.watch(creditsProvider(widget.api).future);
    return PageRefresh(
      onRefresh: _refreshCredits,
      child: AsyncPanel<List<CreditItem>>(
        future: creditsFuture,
        initialData: widget.api.cachedCredits(),
        onSessionExpired: widget.onSessionExpired,
        builder: (items) => LayoutBuilder(
          builder: (context, constraints) {
            final breakpoint = constraints.maxWidth.gzusBreakpoint;
            final wide = breakpoint != GzusBreakpoint.compact;
            final pane = GzusSizing.splitPaneAdaptive(
              constraints.maxWidth,
              breakpoint,
              mediumRatio: 0.42,
              expandedRatio: 0.36,
              largeRatio: 0.32,
              minSide: 260,
              maxSide: 340,
            );
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: pane.side,
                    child: PagePanel(
                      title: '学分概览',
                      icon: Icons.auto_stories,
                      child: Column(
                        children: [
                          for (var index = 0;
                              index < items.length;
                              index++) ...[
                            _CreditProgressCard(
                              item: items[index],
                              index: index,
                              showDetails: false,
                            ),
                            if (index != items.length - 1)
                              const SizedBox(height: GzusSpacing.m),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: GzusSpacing.m),
                  Expanded(
                    child: PagePanel(
                      title: '分类明细',
                      icon: Icons.auto_stories,
                      expandChild: true,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Column(
                          children: [
                            for (var index = 0; index < items.length; index++)
                              Padding(
                                padding: EdgeInsets.only(
                                  bottom: index == items.length - 1
                                      ? GzusSpacing.none
                                      : GzusSpacing.m,
                                ),
                                child: _CreditDetailsCard(
                                  item: items[index],
                                  index: index,
                                  showTitle: true,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }
            return PagePanel(
              title: '学分统计',
              icon: Icons.auto_stories,
              expandChild: true,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  children: [
                    for (var index = 0; index < items.length; index++)
                      Padding(
                        padding: EdgeInsets.only(
                          bottom: index == items.length - 1
                              ? GzusSpacing.none
                              : GzusSpacing.m,
                        ),
                        child: _CreditProgressCard(
                          item: items[index],
                          index: index,
                          showDetails: true,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CreditProgressCard extends StatelessWidget {
  const _CreditProgressCard({
    required this.item,
    required this.index,
    required this.showDetails,
  });

  final CreditItem item;
  final int index;
  final bool showDetails;

  @override
  Widget build(BuildContext context) {
    final totals = _creditTotals(item);
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      key: Key('credit-primary-$index'),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: GzusInsets.card(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _creditTitle(item),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: GzusSpacing.l),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: _CreditMetric(
                    label: '已修学分',
                    value: _creditNumber(totals.earned),
                    alignEnd: false,
                  ),
                ),
                Container(width: 1, height: 38, color: gzusBorder(context)),
                Expanded(
                  child: _CreditMetric(
                    label: '应修学分',
                    value: _creditNumber(totals.expected),
                    alignEnd: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: GzusSpacing.m),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('完成进度', style: GzusTextStyles.metricLabel(context)),
                Text(
                  '${(totals.progress * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ],
            ),
            const SizedBox(height: GzusSpacing.s),
            LinearProgressIndicator(
              key: Key('credit-total-progress-$index'),
              value: totals.progress,
              minHeight: 8,
              borderRadius: BorderRadius.circular(8),
            ),
            if (showDetails) ...[
              const SizedBox(height: GzusSpacing.l),
              _CreditDetails(item: item, index: index),
            ],
          ],
        ),
      ),
    );
  }
}

class _CreditDetailsCard extends StatelessWidget {
  const _CreditDetailsCard({
    required this.item,
    required this.index,
    required this.showTitle,
  });

  final CreditItem item;
  final int index;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: Key('credit-details-$index'),
      child: Padding(
        padding: GzusInsets.card(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showTitle) ...[
              Text(
                _creditTitle(item),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: GzusSpacing.l),
            ],
            _CreditDetails(item: item, index: index),
          ],
        ),
      ),
    );
  }
}

class _CreditDetails extends StatelessWidget {
  const _CreditDetails({required this.item, required this.index});

  final CreditItem item;
  final int index;

  @override
  Widget build(BuildContext context) {
    final metrics = _creditSupplementaryMetrics(item);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (metrics.isNotEmpty) ...[
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = GzusSpacing.s;
              final metricWidth = (constraints.maxWidth - spacing) / 2;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final metric in metrics)
                    SizedBox(
                      width: metricWidth,
                      child: _SupplementaryMetric(metric: metric),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: GzusSpacing.l),
        ],
        Text('分类完成情况', style: GzusTextStyles.cardTitle(context)),
        const SizedBox(height: GzusSpacing.m),
        _CreditCategoryProgress(
          key: Key('credit-category-required-$index'),
          label: '必修',
          earned: item.requiredEarned,
          expected: item.requiredExpected,
        ),
        const SizedBox(height: GzusSpacing.m),
        _CreditCategoryProgress(
          key: Key('credit-category-elective-$index'),
          label: '选修',
          earned: item.electiveEarned,
          expected: item.electiveExpected,
        ),
        const SizedBox(height: GzusSpacing.m),
        _CreditCategoryProgress(
          key: Key('credit-category-other-$index'),
          label: '其他',
          earned: item.otherEarned,
          expected: item.otherExpected,
        ),
      ],
    );
  }
}

class _CreditMetric extends StatelessWidget {
  const _CreditMetric({
    required this.label,
    required this.value,
    required this.alignEnd,
  });

  final String label;
  final String value;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final alignment =
        alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    return Column(
      crossAxisAlignment: alignment,
      children: [
        Text(label, style: GzusTextStyles.metricLabel(context)),
        const SizedBox(height: GzusSpacing.xs),
        Text(
          value,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
      ],
    );
  }
}

class _SupplementaryMetric extends StatelessWidget {
  const _SupplementaryMetric({required this.metric});

  final _CreditMetricData metric;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(GzusSpacing.s),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(GzusRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(metric.label, style: GzusTextStyles.metricLabel(context)),
          const SizedBox(height: GzusSpacing.xs),
          Text(
            metric.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GzusTextStyles.metricValue(context),
          ),
        ],
      ),
    );
  }
}

class _CreditCategoryProgress extends StatelessWidget {
  const _CreditCategoryProgress({
    super.key,
    required this.label,
    required this.earned,
    required this.expected,
  });

  final String label;
  final double earned;
  final double expected;

  @override
  Widget build(BuildContext context) {
    final progress =
        expected <= 0 ? 0.0 : (earned / expected).clamp(0.0, 1.0).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(label, style: GzusTextStyles.bodyEmphasis(context)),
            const Spacer(),
            Text(
              '${_creditNumber(earned)} / ${_creditNumber(expected)}',
              style: GzusTextStyles.statisticLabel(context),
            ),
          ],
        ),
        const SizedBox(height: GzusSpacing.s),
        LinearProgressIndicator(
          value: progress,
          minHeight: 6,
          borderRadius: BorderRadius.circular(6),
        ),
      ],
    );
  }
}

_CreditTotals _creditTotals(CreditItem item) {
  final expected =
      item.requiredExpected + item.electiveExpected + item.otherExpected;
  final earned = item.requiredEarned + item.electiveEarned + item.otherEarned;
  final totalExpected = item.totalExpected == 0 ? expected : item.totalExpected;
  final totalEarned = item.totalEarned == 0 ? earned : item.totalEarned;
  final progress = totalExpected <= 0
      ? 0.0
      : (totalEarned / totalExpected).clamp(0.0, 1.0).toDouble();
  return _CreditTotals(
      expected: totalExpected, earned: totalEarned, progress: progress);
}

List<_CreditMetricData> _creditSupplementaryMetrics(CreditItem item) {
  final metrics = <_CreditMetricData>[];
  if (_hasCreditValue(item.totalCredit)) {
    metrics.add(
        _CreditMetricData(label: '培养方案总学分', value: item.totalCredit!.trim()));
  }
  if (_hasCreditValue(item.selectedCredit)) {
    metrics.add(
        _CreditMetricData(label: '选课学分', value: item.selectedCredit!.trim()));
  }
  return metrics;
}

bool _hasCreditValue(String? value) => value != null && value.trim().isNotEmpty;

String _creditNumber(double value) => value.toStringAsFixed(1);

String _creditTitle(CreditItem item) {
  final name = item.name?.trim() ?? '';
  final major = item.major?.trim() ?? '';
  if (name.isNotEmpty && major.isNotEmpty) return '$name · $major';
  if (major.isNotEmpty) return major;
  if (name.isNotEmpty) return name;
  return '学分统计';
}

class _CreditTotals {
  const _CreditTotals({
    required this.expected,
    required this.earned,
    required this.progress,
  });

  final double expected;
  final double earned;
  final double progress;
}

class _CreditMetricData {
  const _CreditMetricData({required this.label, required this.value});

  final String label;
  final String value;
}
