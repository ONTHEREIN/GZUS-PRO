import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/badges.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/grid_columns.dart';
import '../../widgets/meta_text.dart';
import '../../widgets/open_browser.dart';
import '../../widgets/page_panel.dart';
import '../../widgets/scale_tap.dart';

class ApplicationsPage extends StatefulWidget {
  const ApplicationsPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  State<ApplicationsPage> createState() => _ApplicationsPageState();
}

class _ApplicationsPageState extends State<ApplicationsPage> {
  String _query = '';
  String _department = '全部';
  String _type = '全部';
  String _tag = '全部';
  String? _loadError;
  bool _filtersExpanded = false;
  late Future<List<EhallApplicationItem>> _applicationsFuture;

  @override
  void initState() {
    super.initState();
    _applicationsFuture = _loadApplications();
  }

  @override
  void didUpdateWidget(covariant ApplicationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      _applicationsFuture = _loadApplications();
    }
  }

  Future<List<EhallApplicationItem>> _loadApplications({
    bool forceRefresh = false,
  }) async {
    try {
      final items = await widget.api
          .ehallApplications(forceRefresh: forceRefresh)
          .timeout(const Duration(seconds: 12));
      _loadError = null;
      return items;
    } catch (_) {
      _loadError = '办事大厅暂时不可用，下拉可重试';
      return const [];
    }
  }

  Future<void> _refreshApplications() async {
    setState(() => _applicationsFuture = _loadApplications(forceRefresh: true));
    await _applicationsFuture;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<EhallApplicationItem>>(
      future: _applicationsFuture,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState != ConnectionState.done;
        final items = snapshot.data ?? const <EhallApplicationItem>[];
        final departments = _values(items.map((item) => item.department));
        final types = _values(items.map((item) => item.type));
        final tags = _values(items.expand((item) => item.tags));
        final filtered = items.where(_matches).toList();
        final emptyMessage = _loadError ?? '没有匹配的应用';
        return PagePanel(
          title: '应用',
          icon: Icons.dashboard_customize,
          expandChild: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索应用',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InkWell(
                      onTap: () =>
                          setState(() => _filtersExpanded = !_filtersExpanded),
                      child: Row(
                        children: [
                          Icon(Icons.filter_list,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text('筛选',
                                style: TextStyle(fontWeight: FontWeight.w700)),
                          ),
                          Icon(_filtersExpanded
                              ? Icons.expand_less
                              : Icons.expand_more),
                        ],
                      ),
                    ),
                    if (_filtersExpanded) ...[
                      const SizedBox(height: 10),
                      _ApplicationFilterChips(
                        label: '部门',
                        values: departments,
                        selected: _department,
                        onChanged: (value) =>
                            setState(() => _department = value),
                      ),
                      _ApplicationFilterChips(
                        label: '分类',
                        values: types,
                        selected: _type,
                        onChanged: (value) => setState(() => _type = value),
                      ),
                      _ApplicationFilterChips(
                        label: '标签',
                        values: tags,
                        selected: _tag,
                        onChanged: (value) => setState(() => _tag = value),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '共 ${filtered.length} 个应用',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: PageRefresh(
                  onRefresh: _refreshApplications,
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : filtered.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: [
                                const SizedBox(height: 120),
                                EmptyState(message: emptyMessage),
                              ],
                            )
                          : LayoutBuilder(
                              builder: (context, constraints) {
                                final columns = contentGridColumns(
                                  constraints.maxWidth,
                                  minTileWidth: 170,
                                  maxColumns: 4,
                                );
                                return GridView.builder(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    crossAxisSpacing: 10,
                                    mainAxisSpacing: 10,
                                    childAspectRatio: columns == 1 ? 3.4 : 1.35,
                                  ),
                                  itemCount: filtered.length,
                                  itemBuilder: (context, index) =>
                                      _ApplicationItemTile(
                                          item: filtered[index]),
                                );
                              },
                            ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  bool _matches(EhallApplicationItem item) {
    final query = _query.trim().toLowerCase();
    final searchable = [
      item.title,
      item.department ?? '',
      item.type ?? '',
      item.summary ?? '',
      ...item.tags,
    ].join(' ').toLowerCase();
    return (_department == '全部' || item.department == _department) &&
        (_type == '全部' || item.type == _type) &&
        (_tag == '全部' || item.tags.contains(_tag)) &&
        (query.isEmpty || searchable.contains(query));
  }

  List<String> _values(Iterable<String?> values) {
    final result = values
        .map((value) => value?.trim())
        .where((value) => value != null && value.isNotEmpty)
        .cast<String>()
        .toSet()
        .toList()
      ..sort();
    return ['全部', ...result];
  }
}

class _ApplicationFilterChips extends StatelessWidget {
  const _ApplicationFilterChips({
    required this.label,
    required this.values,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final List<String> values;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    if (values.length <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var index = 0; index < values.length; index++)
            ChoiceChip(
              label: Text(index == 0 ? '$label: 全部' : values[index]),
              selected: selected == values[index],
              onSelected: (_) => onChanged(values[index]),
            ),
        ],
      ),
    );
  }
}

class _ApplicationItemTile extends StatelessWidget {
  const _ApplicationItemTile({required this.item});

  final EhallApplicationItem item;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final inner = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
        color: colorScheme.surface,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const IconBadge(icon: Icons.dashboard_customize, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (item.department != null && item.department!.isNotEmpty)
                      MetaText(item.department!),
                    if (item.type != null && item.type!.isNotEmpty)
                      MetaText(item.type!),
                    for (final tag in item.tags.take(2)) MetaText(tag),
                  ],
                ),
                if (item.summary != null && item.summary!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    item.summary!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.open_in_new, size: 18, color: colorScheme.primary),
        ],
      ),
    );
    return ScaleTap(
      onTap: () => openInAppBrowser(context, item.url),
      borderRadius: BorderRadius.circular(8),
      child: inner,
    );
  }
}
