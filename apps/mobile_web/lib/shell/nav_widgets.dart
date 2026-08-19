// 导航部件（自 main.dart 拆分）：_CenteredPage / AppSidebar / MobileNavBar。
// part of main.dart 共享同一 library。
part of '../main.dart';

// 通过 main.dart 已导入 responsive/spacing.dart，无需重复导入。

class _CenteredPage extends StatelessWidget {
  const _CenteredPage({required this.child, required this.maxWidth});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              minHeight: constraints.maxHeight,
              maxHeight: constraints.maxHeight,
            ),
            child: child,
          ),
        );
      },
    );
  }
}

String _settingsKey(int year, int term, String name) =>
    'schedule.$year.$term.$name';

class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onChanged,
    this.compact = false,
    this.dense = false,
    this.onToggleCompact,
  });

  final List<NavTabConfig> tabs;
  final int selected;
  final ValueChanged<int> onChanged;
  final bool compact;
  final bool dense;
  final VoidCallback? onToggleCompact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return AnimatedContainer(
      key: const ValueKey('app-sidebar'),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOutCubic,
      width: compact ? 86 : 248,
      clipBehavior: Clip.hardEdge,
      padding: EdgeInsets.fromLTRB(
          compact ? 10 : 16, dense ? 18 : 28, compact ? 10 : 16, 18),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(right: BorderSide(color: gzusBorder(context))),
      ),
      child: Column(
        crossAxisAlignment:
            compact ? CrossAxisAlignment.center : CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 10),
            child: Row(
              mainAxisAlignment:
                  compact ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                if (compact)
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: Container(
                      key: const ValueKey('compact-logo'),
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.25),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.asset(
                          'assets/icon.png',
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: Row(
                        key: const ValueKey('expanded-logo'),
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withValues(alpha: 0.25),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.asset(
                                'assets/icon.png',
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          const SizedBox(width: GzusSpacing.m),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('软帮手',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700)),
                                const SizedBox(height: 2),
                                Text('广州软件学院教务助手',
                                    style: theme.textTheme.bodySmall),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (!compact && onToggleCompact != null) ...[
                  const SizedBox(width: GzusSpacing.s),
                  IconButton(
                    onPressed: onToggleCompact,
                    icon: const Icon(Icons.keyboard_double_arrow_left),
                    tooltip: '折叠边栏',
                  ),
                ],
              ],
            ),
          ),
          if (compact && onToggleCompact != null) ...[
            const SizedBox(height: GzusSpacing.m),
            IconButton(
              onPressed: onToggleCompact,
              icon: const Icon(Icons.keyboard_double_arrow_right),
              tooltip: '展开边栏',
            ),
          ],
          const SizedBox(height: GzusSpacing.xxl),
          Expanded(
            child: ListView.separated(
              itemCount: tabs.length,
              separatorBuilder: (_, __) => const SizedBox(height: GzusSpacing.xs),
              itemBuilder: (context, i) {
                final tab = tabs[i];
                final active = i == selected;
                return InkWell(
                  borderRadius: BorderRadius.circular(GzusRadii.sm),
                  onTap: () => onChanged(i),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 0 : 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: active ? accentFill(context) : Colors.transparent,
                      borderRadius: BorderRadius.circular(GzusRadii.sm),
                    ),
                    child: Row(
                      mainAxisAlignment: compact
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                      children: [
                        Icon(
                          tab.icon,
                          size: 22,
                          color: active
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOutCubic,
                          alignment: Alignment.centerLeft,
                          child: compact
                              ? const SizedBox.shrink()
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(width: GzusSpacing.m),
                                    Text(
                                      tab.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          theme.textTheme.bodyMedium?.copyWith(
                                        color: active
                                            ? colorScheme.primary
                                            : colorScheme.onSurfaceVariant,
                                        fontWeight: active
                                            ? FontWeight.w800
                                            : FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class MobileNavBar extends StatelessWidget {
  const MobileNavBar({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onChanged,
  });

  final List<NavTabConfig> tabs;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          GzusSpacing.l, 0, GzusSpacing.l, bottomPadding + GzusSpacing.s),
      child: Container(
        height: _mobileNavBarHeight,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? colorScheme.primary.withValues(alpha: 0.16)
                  : Colors.black.withValues(alpha: 0.10),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: isDark
                  ? colorScheme.primary.withValues(alpha: 0.06)
                  : Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              key: const ValueKey('mobile-bottom-nav'),
              height: _mobileNavBarHeight,
              padding: const EdgeInsets.symmetric(
                  horizontal: GzusSpacing.xs, vertical: GzusSpacing.s),
              decoration: BoxDecoration(
                color: gzusSurface(context).withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(
                  color: gzusBorder(context).withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => onChanged(i),
                        child: Container(
                          height: double.infinity,
                          decoration: BoxDecoration(
                            color: i == selected
                                ? accentFill(context)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                tabs[i].icon,
                                size: 24,
                                color: i == selected
                                    ? colorScheme.primary
                                    : colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: GzusSpacing.xs),
                              Text(
                                tabs[i].shortLabel,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: i == selected
                                      ? colorScheme.primary
                                      : colorScheme.onSurfaceVariant,
                                  fontWeight: i == selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

List<NavTabConfig> _mobileNavTabs(List<NavTabConfig> tabs) {
  final result = <NavTabConfig>[];
  for (final tab in tabs) {
    if (result.length >= _mobileMainNavLimit) break;
    if (tab.tabId != 'more' && !result.any((item) => item.tabId == tab.tabId)) {
      result.add(tab);
    }
  }
  result.add(NavTabConfig.moreTab);
  return result;
}


