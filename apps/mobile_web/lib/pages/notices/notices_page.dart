import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api_client.dart';
import '../../app_providers.dart';
import '../../responsive/breakpoints.dart';
import '../../responsive/sizing.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/badges.dart';
import '../../widgets/meta_text.dart';
import '../../widgets/open_browser.dart';
import '../../widgets/page_panel.dart';
import '../../widgets/page_silent_refresh.dart';

String _noticeItemTitle(NoticeItem item) {
  final value = item.title.trim();
  return value.isEmpty ? '未命名通知' : value;
}

String _noticeDetailTitle(NoticeItem item, NoticeDetail detail) {
  final value = detail.title.trim();
  return value.isEmpty ? _noticeItemTitle(item) : value;
}

class NoticesPage extends ConsumerStatefulWidget {
  const NoticesPage({super.key, required this.api, this.onSessionExpired});

  final ApiClient api;
  final VoidCallback? onSessionExpired;

  @override
  ConsumerState<NoticesPage> createState() => _NoticesPageState();
}

class _NoticesPageState extends ConsumerState<NoticesPage>
    with PageSilentRefresh<NoticesPage> {
  int? _selectedIndex;

  Future<void> _refreshNotices() async {
    ref.invalidate(noticesProvider(widget.api));
    final items = await ref.read(freshNoticesProvider(widget.api).future);
    ref.invalidate(noticesProvider(widget.api));
    if (mounted && _selectedIndex != null && _selectedIndex! >= items.length) {
      setState(() => _selectedIndex = null);
    }
  }

  @override
  void silentRefresh() {
    if (!mounted) return;
    ref.invalidate(noticesProvider(widget.api));
  }

  @override
  Widget build(BuildContext context) {
    final noticesFuture = ref.watch(noticesProvider(widget.api).future);
    return PageRefresh(
      onRefresh: _refreshNotices,
      child: AsyncPanel<List<NoticeItem>>(
        future: noticesFuture,
        initialData: widget.api.cachedNotices(),
        emptyMessage: '暂无通知',
        onSessionExpired: widget.onSessionExpired,
        builder: (items) => LayoutBuilder(
          builder: (context, constraints) {
            final breakpoint = constraints.maxWidth.gzusBreakpoint;
            final wide = breakpoint != GzusBreakpoint.compact;
            final pane = GzusSizing.splitPaneAdaptive(
              constraints.maxWidth,
              breakpoint,
              mediumRatio: 0.45,
              expandedRatio: 0.38,
              largeRatio: 0.34,
              minSide: 280,
              maxSide: 380,
            );
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: pane.side,
                    child: PagePanel(
                      title: '通知',
                      icon: Icons.info_outline,
                      expandChild: true,
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) => Container(
                          decoration: _selectedIndex == index
                              ? BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primaryContainer,
                                  borderRadius: BorderRadius.circular(8),
                                )
                              : null,
                          child: NoticeCard(
                            item: items[index],
                            api: widget.api,
                            resolveUrl: widget.api.resolveMediaUrl,
                            onTap: () => setState(() => _selectedIndex = index),
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
                itemBuilder: (context, index) => NoticeCard(
                  item: items[index],
                  api: widget.api,
                  resolveUrl: widget.api.resolveMediaUrl,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _NoticeDetailPage(
                        api: widget.api,
                        item: items[index],
                        onSessionExpired: widget.onSessionExpired,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NoticeDetailContent extends ConsumerStatefulWidget {
  const _NoticeDetailContent(
      {required this.api, required this.item, this.onSessionExpired});
  final ApiClient api;
  final NoticeItem item;
  final VoidCallback? onSessionExpired;

  @override
  ConsumerState<_NoticeDetailContent> createState() =>
      _NoticeDetailContentState();
}

class _NoticeDetailContentState extends ConsumerState<_NoticeDetailContent> {
  var _forceRefresh = false;

  @override
  Widget build(BuildContext context) {
    final coverUrl = _resolveCover();
    if (widget.item.source != NoticeSource.jwxt ||
        widget.item.url == null ||
        widget.item.url!.isEmpty) {
      return _NoticeDetailBody(
        api: widget.api,
        item: widget.item,
        title: _noticeItemTitle(widget.item),
        date: widget.item.date,
        coverUrl: coverUrl,
        content: widget.item.summary,
      );
    }
    final detailFuture = ref.watch(
      noticeDetailProvider(
        NoticeDetailRequest(
          client: widget.api,
          url: widget.item.url!,
          forceRefresh: _forceRefresh,
        ),
      ).future,
    );
    return FutureBuilder<NoticeDetail>(
      future: detailFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _NoticeDetailBody(
            api: widget.api,
            item: widget.item,
            title: _noticeItemTitle(widget.item),
            date: widget.item.date,
            coverUrl: coverUrl,
            content: widget.item.summary,
            error: '详情加载失败，请重试或打开原网页查看。',
            onRetry: _retryDetail,
          );
        }
        final detail = snapshot.data!;
        return _NoticeDetailBody(
          api: widget.api,
          item: widget.item,
          title: _noticeDetailTitle(widget.item, detail),
          date: detail.date ?? widget.item.date,
          coverUrl: coverUrl,
          content: _noticePlainText(detail.contentHtml),
        );
      },
    );
  }

  String? _resolveCover() {
    final cover = widget.item.coverUrl;
    if (cover == null || cover.isEmpty) return null;
    if (cover.startsWith('http://') || cover.startsWith('https://')) {
      return cover;
    }
    return widget.api.resolveMediaUrl(cover);
  }

  void _retryDetail() {
    final url = widget.item.url;
    if (url == null || url.isEmpty) return;
    ref.invalidate(
      noticeDetailProvider(
        NoticeDetailRequest(
          client: widget.api,
          url: url,
          forceRefresh: true,
        ),
      ),
    );
    setState(() => _forceRefresh = true);
  }
}

class _NoticeDetailPage extends StatelessWidget {
  const _NoticeDetailPage({
    required this.api,
    required this.item,
    this.onSessionExpired,
  });

  final ApiClient api;
  final NoticeItem item;
  final VoidCallback? onSessionExpired;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_noticeItemTitle(item))),
      body: SafeArea(
        child: _NoticeDetailContent(
          api: api,
          item: item,
          onSessionExpired: onSessionExpired,
        ),
      ),
    );
  }
}

class _NoticeDetailBody extends StatelessWidget {
  const _NoticeDetailBody({
    required this.api,
    required this.item,
    required this.title,
    required this.date,
    required this.coverUrl,
    required this.content,
    this.error,
    this.onRetry,
  });

  final ApiClient api;
  final NoticeItem item;
  final String title;
  final String? date;
  final String? coverUrl;
  final String? content;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final hasUrl = item.url != null && item.url!.isNotEmpty;
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
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              MetaText(item.category),
              if (date != null) MetaText(date!),
            ],
          ),
          if (coverUrl != null) ...[
            const SizedBox(height: 12),
            _NoticeCoverImage(url: coverUrl!),
          ],
          const SizedBox(height: 16),
          if (error != null) ...[
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试加载'),
              ),
            ],
          ],
          if (content != null && content!.trim().isNotEmpty)
            Text(content!, style: const TextStyle(fontSize: 15, height: 1.7))
          else if (error == null)
            const Text('暂无可展示的详情内容'),
          if (hasUrl) ...[
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              key: const ValueKey('notice-open-original'),
              onPressed: () => openInAppBrowser(context, item.url, api: api),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('打开原网页'),
            ),
          ],
        ],
      ),
    );
  }
}

String _noticePlainText(String value) {
  return value
      .replaceAll(
          RegExp(r'<(?:br|/p|/div|/li)[^>]*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

class _NoticeCoverImage extends StatelessWidget {
  const _NoticeCoverImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Image.network(
          url,
          width: double.infinity,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Container(
            color: colorScheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: Icon(
              Icons.image_not_supported_outlined,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          loadingBuilder: (_, child, progress) {
            if (progress == null) return child;
            return Container(
              color: colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          },
        ),
      ),
    );
  }
}

class NoticeCard extends StatelessWidget {
  const NoticeCard({
    super.key,
    required this.item,
    required this.api,
    this.resolveUrl,
    this.onTap,
  });

  final NoticeItem item;
  final ApiClient api;

  /// 把相对路径封面（如校历 /admin/notices/1/image）解析为完整 URL。
  final String? Function(String path)? resolveUrl;
  final VoidCallback? onTap;

  String get _title {
    return _noticeItemTitle(item);
  }

  String? get _summary {
    final value = item.summary?.trim();
    if (value == null || value.isEmpty || value == _title) return null;
    return value;
  }

  String? get _coverUrl {
    final cover = item.coverUrl;
    if (cover == null || cover.isEmpty) return null;
    if (cover.startsWith('http://') || cover.startsWith('https://')) {
      return cover;
    }
    return resolveUrl?.call(cover);
  }

  IconData get _icon {
    if (item.category.contains('公众号')) return Icons.campaign;
    if (item.category.contains('校历')) return Icons.calendar_month;
    return Icons.info_outline;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final summary = _summary;
    final coverUrl = _coverUrl;

    return Card(
      key: ValueKey<String>('notice-card-${item.url ?? item.title}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconBadge(icon: _icon, size: 32),
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
              if (coverUrl != null) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Image.network(
                      coverUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _coverPlaceholder(context),
                      loadingBuilder: (_, child, progress) {
                        if (progress == null) return child;
                        return Container(
                          color: colorScheme.surfaceContainerHighest,
                          alignment: Alignment.center,
                          child: const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _coverPlaceholder(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      color: colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(Icons.image_not_supported_outlined,
          color: colorScheme.onSurfaceVariant),
    );
  }
}
