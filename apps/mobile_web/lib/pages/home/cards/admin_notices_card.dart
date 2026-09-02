import 'dart:async';

import 'package:flutter/material.dart';

import '../../../api_client.dart';
import '../../home/cards/home_card_shell.dart';

/// 管理员发布的信息卡片：支持图片背景、文字说明和自动横向轮播。
class AdminNoticesLargeCard extends StatefulWidget {
  const AdminNoticesLargeCard({
    required this.api,
    required this.notices,
    required this.onTap,
    super.key,
  });

  final ApiClient api;
  final List<NoticeItem> notices;
  final VoidCallback onTap;

  @override
  State<AdminNoticesLargeCard> createState() => _AdminNoticesLargeCardState();
}

class _AdminNoticesLargeCardState extends State<AdminNoticesLargeCard> {
  late final PageController _pageController;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _restartTimer();
  }

  @override
  void didUpdateWidget(covariant AdminNoticesLargeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notices.length != widget.notices.length) {
      final page =
          _pageController.hasClients ? _pageController.page?.round() : 0;
      final maxPage = widget.notices.isEmpty ? 0 : widget.notices.length - 1;
      if ((page ?? 0) > maxPage) {
        _pageController.jumpToPage(maxPage);
      }
      _restartTimer();
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    if (widget.notices.length < 2) return;
    _timer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || !_pageController.hasClients || widget.notices.isEmpty) {
        return;
      }
      final current = _pageController.page?.round() ?? 0;
      final next = (current + 1) % widget.notices.length;
      _pageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HomeCardShell(
      title: '管理员信息',
      icon: Icons.campaign,
      density: HomeCardDensity.large,
      badge: '${widget.notices.length} 条',
      onTap: widget.onTap,
      child: widget.notices.isEmpty
          ? const Center(child: Text('暂无管理员信息'))
          : ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                children: [
                  PageView.builder(
                    key: const ValueKey('admin-notices-carousel'),
                    controller: _pageController,
                    itemCount: widget.notices.length,
                    onPageChanged: (_) => _restartTimer(),
                    itemBuilder: (context, index) => _AdminNoticeSlide(
                      api: widget.api,
                      notice: widget.notices[index],
                    ),
                  ),
                  if (widget.notices.length > 1)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 10,
                      child: _CarouselIndicator(
                        count: widget.notices.length,
                        controller: _pageController,
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _AdminNoticeSlide extends StatelessWidget {
  const _AdminNoticeSlide({required this.api, required this.notice});

  final ApiClient api;
  final NoticeItem notice;

  @override
  Widget build(BuildContext context) {
    final imageUrl = notice.coverUrl;
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
    final foreground = hasImage ? Colors.white : null;
    final muted = hasImage
        ? Colors.white.withValues(alpha: 0.82)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final text = notice.summary?.trim() ?? '';

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasImage)
          Image.network(
            api.resolveMediaUrl(imageUrl),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _noticePlaceholder(context),
          )
        else
          _noticePlaceholder(context),
        if (hasImage)
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xCC000000)],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notice.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (text.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: muted, height: 1.35),
                  ),
                ],
                if (notice.date != null && notice.date!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(notice.date!,
                      style: TextStyle(color: muted, fontSize: 12)),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _noticePlaceholder(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colorScheme.primaryContainer,
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Icon(
            Icons.campaign_outlined,
            size: 72,
            color: colorScheme.onPrimaryContainer.withValues(alpha: 0.22),
          ),
        ),
      ),
    );
  }
}

class _CarouselIndicator extends StatelessWidget {
  const _CarouselIndicator({required this.count, required this.controller});

  final int count;
  final PageController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final page = controller.hasClients ? controller.page ?? 0 : 0;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var index = 0; index < count; index++)
              Container(
                width: index == page.round() ? 18 : 6,
                height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: Colors.white
                      .withValues(alpha: index == page.round() ? 0.95 : 0.55),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
          ],
        );
      },
    );
  }
}
