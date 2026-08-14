import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/badges.dart';
import '../../widgets/meta_text.dart';
import '../../widgets/open_browser.dart';
import '../../widgets/page_panel.dart';

String _noticeItemTitle(NoticeItem item) {
  final value = item.title.trim();
  return value.isEmpty ? '未命名通知' : value;
}

String _noticeDetailTitle(NoticeItem item, NoticeDetail detail) {
  final value = detail.title.trim();
  return value.isEmpty ? _noticeItemTitle(item) : value;
}

class NoticesPage extends StatefulWidget {
  const NoticesPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  State<NoticesPage> createState() => _NoticesPageState();
}

class _NoticesPageState extends State<NoticesPage> {
  int? _selectedIndex;
  late Future<List<NoticeItem>> _noticesFuture;

  @override
  void initState() {
    super.initState();
    _noticesFuture = _loadNotices();
  }

  @override
  void didUpdateWidget(covariant NoticesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      _noticesFuture = _loadNotices();
    }
  }

  Future<List<NoticeItem>> _loadNotices({bool forceRefresh = false}) =>
      widget.api.notices(forceRefresh: forceRefresh).then((r) => r.data);

  Future<void> _refreshNotices() async {
    setState(() => _noticesFuture = _loadNotices(forceRefresh: true));
    final items = await _noticesFuture;
    if (mounted && _selectedIndex != null && _selectedIndex! >= items.length) {
      setState(() => _selectedIndex = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: _refreshNotices,
      child: AsyncPanel<List<NoticeItem>>(
        future: _noticesFuture,
        emptyMessage: '暂无通知',
        onSessionExpired: widget.onSessionExpired,
        builder: (items) => LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 350,
                    child: PagePanel(
                      title: '通知',
                      icon: Icons.info_outline,
                      expandChild: true,
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) => GestureDetector(
                          onTap: () => setState(() => _selectedIndex = index),
                          child: Container(
                            decoration: _selectedIndex == index
                                ? BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primaryContainer,
                                    borderRadius: BorderRadius.circular(8),
                                  )
                                : null,
                            child: NoticeCard(item: items[index]),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PagePanel(
                      title: _selectedIndex != null
                          ? _noticeItemTitle(items[_selectedIndex!])
                          : '通知详情',
                      icon: Icons.article,
                      expandChild: true,
                      child: _selectedIndex != null
                          ? _NoticeDetailContent(
                              api: widget.api,
                              item: items[_selectedIndex!],
                              onSessionExpired: widget.onSessionExpired,
                            )
                          : const Center(child: Text('请选择一条通知查看详情')),
                    ),
                  ),
                ],
              );
            }
            return PagePanel(
              title: '通知',
              icon: Icons.info_outline,
              expandChild: true,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) => NoticeCard(item: items[index]),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NoticeDetailContent extends StatefulWidget {
  const _NoticeDetailContent(
      {required this.api, required this.item, this.onSessionExpired});
  final ApiClient api;
  final NoticeItem item;
  final VoidCallback? onSessionExpired;

  @override
  State<_NoticeDetailContent> createState() => _NoticeDetailContentState();
}

class _NoticeDetailContentState extends State<_NoticeDetailContent> {
  late Future<NoticeDetail> _detailFuture;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  @override
  void didUpdateWidget(covariant _NoticeDetailContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.url != widget.item.url) _loadDetail();
  }

  void _loadDetail() {
    if (widget.item.url != null && widget.item.url!.isNotEmpty) {
      _detailFuture =
          widget.api.fetchNoticeDetail(widget.item.url!).then((r) => r.data);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.item.url == null || widget.item.url!.isEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _noticeItemTitle(widget.item),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
            ),
            const SizedBox(height: 10),
            if (widget.item.date != null)
              Text(widget.item.date!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13)),
            const SizedBox(height: 12),
            if (widget.item.summary != null && widget.item.summary!.isNotEmpty)
              Text(widget.item.summary!,
                  style: const TextStyle(fontSize: 15, height: 1.6))
            else
              const Text('暂无详情内容'),
          ],
        ),
      );
    }
    return FutureBuilder<NoticeDetail>(
      future: _detailFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('加载失败: ${snapshot.error}'));
        }
        final detail = snapshot.data!;
        final title = _noticeDetailTitle(widget.item, detail);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                    ),
              ),
              const SizedBox(height: 10),
              if (detail.date != null)
                Text(detail.date!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 13)),
              const SizedBox(height: 8),
              Text(detail.contentHtml.replaceAll(RegExp(r'<[^>]*>'), ''),
                  style: const TextStyle(fontSize: 15, height: 1.6)),
            ],
          ),
        );
      },
    );
  }
}

class NoticeCard extends StatelessWidget {
  const NoticeCard({super.key, required this.item});

  final NoticeItem item;

  String get _title {
    return _noticeItemTitle(item);
  }

  String? get _summary {
    final value = item.summary?.trim();
    if (value == null || value.isEmpty || value == _title) return null;
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final summary = _summary;
    final hasUrl = item.url != null && item.url!.isNotEmpty;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const IconBadge(icon: Icons.info_outline, size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w800,
                              height: 1.25,
                            ) ??
                            TextStyle(
                              color: colorScheme.onSurface,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              height: 1.25,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          MetaText(item.category),
                          if (item.date != null) MetaText(item.date!),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (summary != null) ...[
              const SizedBox(height: 8),
              Text(
                summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ],
            if (hasUrl) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: () => openInAppBrowser(context, item.url),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('打开通知'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
