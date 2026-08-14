import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../responsive/breakpoints.dart';
import '../../responsive/sizing.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/badges.dart';
import '../../widgets/data_table.dart';
import '../../widgets/info_tile.dart';
import '../../widgets/page_panel.dart';
import '../../widgets/page_silent_refresh.dart';

class CreditsPage extends StatefulWidget {
  const CreditsPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  State<CreditsPage> createState() => _CreditsPageState();
}

class _CreditsPageState extends State<CreditsPage>
    with PageSilentRefresh<CreditsPage> {
  late Future<List<CreditItem>> _creditsFuture;

  @override
  void initState() {
    super.initState();
    _creditsFuture = _loadCredits();
  }

  @override
  void didUpdateWidget(covariant CreditsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      _creditsFuture = _loadCredits();
    }
  }

  Future<List<CreditItem>> _loadCredits({bool forceRefresh = false}) =>
      widget.api.credits(forceRefresh: forceRefresh).then((r) => r.data);

  Future<void> _refreshCredits() async {
    setState(() => _creditsFuture = _loadCredits(forceRefresh: true));
    await _creditsFuture;
  }

  @override
  void silentRefresh() {
    if (!mounted) return;
    setState(() => _creditsFuture = _loadCredits());
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: _refreshCredits,
      child: AsyncPanel<List<CreditItem>>(
        future: _creditsFuture,
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
                          for (final item in items) ...[
                            _CreditOverviewCard(item: item),
                            if (item != items.last) const SizedBox(height: 12),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PagePanel(
                      title: '学分统计',
                      icon: Icons.auto_stories,
                      expandChild: true,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Column(
                          children: [
                            for (final item in items)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: CreditCard(item: item),
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
                    for (final item in items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: CreditCard(item: item),
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

class _CreditOverviewCard extends StatelessWidget {
  const _CreditOverviewCard({required this.item});
  final CreditItem item;

  @override
  Widget build(BuildContext context) {
    final expected =
        item.requiredExpected + item.electiveExpected + item.otherExpected;
    final earned = item.requiredEarned + item.electiveEarned + item.otherEarned;
    final totalExpected =
        item.totalExpected == 0 ? expected : item.totalExpected;
    final totalEarned = item.totalEarned == 0 ? earned : item.totalEarned;
    final progress = expected <= 0 ? 0.0 : (earned / expected).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${item.name ?? '-'} · ${item.major ?? '-'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
                child: Text('已修 ${totalEarned.toStringAsFixed(1)}',
                    style: const TextStyle(fontSize: 13))),
            Text('应修 ${totalExpected.toStringAsFixed(1)}',
                style: const TextStyle(fontSize: 13)),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: progress),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            InfoTile(
                icon: Icons.check,
                label: '必修',
                value: '${item.requiredEarned}/${item.requiredExpected}'),
            InfoTile(
                icon: Icons.book,
                label: '选修',
                value: '${item.electiveEarned}/${item.electiveExpected}'),
          ],
        ),
      ],
    );
  }
}

class CreditCard extends StatelessWidget {
  const CreditCard({super.key, required this.item});

  final CreditItem item;

  @override
  Widget build(BuildContext context) {
    final expected =
        item.requiredExpected + item.electiveExpected + item.otherExpected;
    final earned = item.requiredEarned + item.electiveEarned + item.otherEarned;
    final totalExpected =
        item.totalExpected == 0 ? expected : item.totalExpected;
    final totalEarned = item.totalEarned == 0 ? earned : item.totalEarned;
    final progress = expected <= 0 ? 0.0 : (earned / expected).clamp(0.0, 1.0);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const IconBadge(icon: Icons.auto_stories, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${item.name ?? '-'} · ${item.major ?? '-'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                InfoTile(
                    icon: Icons.verified,
                    label: '培养方案总学分',
                    value: item.totalCredit ?? '-'),
                InfoTile(
                    icon: Icons.check_circle,
                    label: '已修学分',
                    value: totalEarned.toStringAsFixed(2)),
                InfoTile(
                    icon: Icons.list,
                    label: '应修合计',
                    value: totalExpected.toStringAsFixed(2)),
                InfoTile(
                    icon: Icons.auto_stories,
                    label: '选课学分',
                    value: item.selectedCredit ?? '-'),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 12),
            SimpleTable(
              headers: const ['类别', '应修', '实修'],
              rows: [
                ['必修', '${item.requiredExpected}', '${item.requiredEarned}'],
                ['选修', '${item.electiveExpected}', '${item.electiveEarned}'],
                ['其他', '${item.otherExpected}', '${item.otherEarned}'],
                ['合计', '$expected', '$earned'],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
