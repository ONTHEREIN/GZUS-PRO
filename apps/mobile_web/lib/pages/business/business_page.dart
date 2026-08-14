import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/business_item_tile.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/grid_columns.dart';
import '../../widgets/open_browser.dart';
import '../../widgets/page_panel.dart';
import '../../widgets/progress.dart';

class _BusinessProgressSection extends StatefulWidget {
  const _BusinessProgressSection({
    required this.api,
    required this.refreshVersion,
    this.onSessionExpired,
  });

  final ApiClient api;
  final int refreshVersion;
  final VoidCallback? onSessionExpired;

  @override
  State<_BusinessProgressSection> createState() =>
      _BusinessProgressSectionState();
}

class _BusinessProgressSectionState extends State<_BusinessProgressSection> {
  String _status = '全部';
  bool _expanded = false;
  late Future<EhallProgressOverview> _progressFuture;

  @override
  void initState() {
    super.initState();
    _progressFuture = widget.api.ehallProgressOverview();
  }

  @override
  void didUpdateWidget(covariant _BusinessProgressSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.refreshVersion != widget.refreshVersion) {
      _progressFuture = widget.api.ehallProgressOverview(
        forceRefresh: oldWidget.refreshVersion != widget.refreshVersion,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EhallProgressOverview>(
      future: _progressFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 72,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          // 不再在 401 时触发 onSessionExpired，_withFallback 已处理 relogin
          return const SizedBox.shrink();
        }
        final overview = snapshot.data ??
            EhallProgressOverview.fromItems(const <EhallProgressItem>[]);
        final items = overview.items;
        final statuses = [
          '全部',
          ...items
              .map((item) => item.statusLabel)
              .where((item) => item.isNotEmpty)
              .toSet(),
        ];
        final filtered = _status == '全部'
            ? items
            : items.where((item) => item.statusLabel == _status).toList();
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.route,
                      size: 20, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('业务进度',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                  Text('${filtered.length} 项',
                      style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(width: 4),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon:
                        Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
                ],
              ),
              if (_expanded) ...[
                const SizedBox(height: 10),
                ProgressCategoryStrip(categories: overview.categories),
                const SizedBox(height: 10),
                SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: statuses.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final status = statuses[index];
                      return ChoiceChip(
                        label: Text(status),
                        selected: _status == status,
                        onSelected: (_) => setState(() => _status = status),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                if (filtered.isEmpty)
                  const EmptyState(message: '暂无业务进度')
                else
                  Column(
                    children: [
                      for (final item in filtered.take(5))
                        InkWell(
                          onTap: () => openInAppBrowser(context, item.url),
                          child: ProgressMiniRow(item: item),
                        ),
                    ],
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class BusinessPage extends StatefulWidget {
  const BusinessPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  State<BusinessPage> createState() => _BusinessPageState();
}

class _BusinessPageState extends State<BusinessPage> {
  String _query = '';
  String _department = '全部';
  int _refreshVersion = 0;
  late Future<List<EhallAffairItem>> _affairsFuture;

  @override
  void initState() {
    super.initState();
    _affairsFuture = _loadAffairs();
  }

  @override
  void didUpdateWidget(covariant BusinessPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      _affairsFuture = _loadAffairs();
    }
  }

  Future<List<EhallAffairItem>> _loadAffairs({bool forceRefresh = false}) =>
      widget.api.ehallAffairs(forceRefresh: forceRefresh);

  Future<void> _refreshAffairs() async {
    setState(() {
      _refreshVersion++;
      _affairsFuture = _loadAffairs(forceRefresh: true);
    });
    await _affairsFuture;
  }

  @override
  Widget build(BuildContext context) {
    return AsyncPanel<List<EhallAffairItem>>(
      future: _affairsFuture,
      emptyMessage: '暂无业务',
      onSessionExpired: widget.onSessionExpired,
      builder: (items) {
        final departments = _departments(items);
        final filtered = items.where((item) {
          final query = _query.trim().toLowerCase();
          final matchesDepartment =
              _department == '全部' || item.department == _department;
          final searchable = [
            item.title,
            item.department ?? '',
            item.type ?? '',
            item.summary ?? '',
            ...item.tags,
          ].join(' ').toLowerCase();
          return matchesDepartment &&
              (query.isEmpty || searchable.contains(query));
        }).toList();
        return PagePanel(
          title: '业务',
          icon: Icons.apps,
          expandChild: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BusinessProgressSection(
                api: widget.api,
                refreshVersion: _refreshVersion,
                onSessionExpired: widget.onSessionExpired,
              ),
              const SizedBox(height: 12),
              _BusinessFilters(
                departments: departments,
                selectedDepartment: _department,
                onQueryChanged: (value) => setState(() => _query = value),
                onDepartmentChanged: (value) =>
                    setState(() => _department = value),
              ),
              const SizedBox(height: 12),
              Text(
                '共 ${filtered.length} 项',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: PageRefresh(
                  onRefresh: _refreshAffairs,
                  child: filtered.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 120),
                            EmptyState(message: '没有匹配的业务'),
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
                              physics: const AlwaysScrollableScrollPhysics(),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                                childAspectRatio: columns == 1
                                    ? 2.2
                                    : (columns == 2 ? 1.45 : 1.35),
                              ),
                              itemCount: filtered.length,
                              itemBuilder: (context, index) =>
                                  BusinessItemTile(item: filtered[index]),
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

  List<String> _departments(List<EhallAffairItem> items) {
    final values = items
        .map((item) => item.department?.trim())
        .where((value) => value != null && value.isNotEmpty)
        .cast<String>()
        .toSet()
        .toList()
      ..sort();
    return ['全部', ...values];
  }
}

class _BusinessFilters extends StatelessWidget {
  const _BusinessFilters({
    required this.departments,
    required this.selectedDepartment,
    required this.onQueryChanged,
    required this.onDepartmentChanged,
  });

  final List<String> departments;
  final String selectedDepartment;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onDepartmentChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          onChanged: onQueryChanged,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: '搜索业务',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: departments.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final department = departments[index];
              return ChoiceChip(
                label: Text(department),
                selected: selectedDepartment == department,
                onSelected: (_) => onDepartmentChanged(department),
              );
            },
          ),
        ),
      ],
    );
  }
}
