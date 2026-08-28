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
                                        ?.copyWith(
                                            fontWeight: FontWeight.w700)),
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
              separatorBuilder: (_, __) =>
                  const SizedBox(height: GzusSpacing.xs),
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

class MobileNavBar extends StatefulWidget {
  const MobileNavBar({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onChanged,
    required this.visible,
  });

  final List<NavTabConfig> tabs;
  final int selected;
  final ValueChanged<int> onChanged;
  final bool visible;

  @override
  State<MobileNavBar> createState() => _MobileNavBarState();
}

class _MobileNavBarState extends State<MobileNavBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _visibilityController;
  late final Animation<Offset> _visibilityOffset;
  late final Animation<double> _visibilityOpacity;

  @override
  void initState() {
    super.initState();
    _visibilityController = AnimationController(
      vsync: this,
      value: widget.visible ? 1 : 0,
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _visibilityOffset = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _visibilityController,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );
    _visibilityOpacity = CurvedAnimation(
      parent: _visibilityController,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );
  }

  @override
  void didUpdateWidget(covariant MobileNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    if (widget.visible) {
      _visibilityController.forward();
      return;
    }
    _visibilityController.reverse();
  }

  @override
  void dispose() {
    _visibilityController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final colorScheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<LiquidGlassCapabilities>(
      valueListenable: LiquidGlassPlatform.capabilities,
      builder: (context, capabilities, _) {
        final useNativeTabBar = !kIsWeb &&
            defaultTargetPlatform == TargetPlatform.iOS &&
            capabilities.systemGlassSupported &&
            !capabilities.reduceTransparency;
        final nativeBottomInset =
            bottomPadding > 20 ? bottomPadding - 20 : GzusSpacing.s;
        final dock = Padding(
          padding: EdgeInsets.fromLTRB(
              GzusSpacing.m,
              0,
              GzusSpacing.m,
              useNativeTabBar
                  ? nativeBottomInset
                  : bottomPadding + GzusSpacing.s),
          child: SizedBox(
            height: useNativeTabBar
                ? _nativeIosLiquidTabBarHeight
                : _mobileNavBarHeight,
            child: useNativeTabBar
                ? NativeIosLiquidTabBar(
                    tabs: widget.tabs
                        .map((tab) => NativeLiquidTabBarItem(
                              title: tab.shortLabel,
                              systemImageName:
                                  _nativeSystemImageName(tab.tabId),
                            ))
                        .toList(growable: false),
                    selected: widget.selected,
                    onChanged: widget.onChanged,
                    tintColor: colorScheme.primary,
                  )
                : _FlutterMobileNavBar(
                    tabs: widget.tabs,
                    selected: widget.selected,
                    onChanged: widget.onChanged,
                    colorScheme: colorScheme,
                  ),
          ),
        );
        return IgnorePointer(
          ignoring: !widget.visible,
          child: FadeTransition(
            opacity: _visibilityOpacity,
            child: SlideTransition(
              position: _visibilityOffset,
              child: dock,
            ),
          ),
        );
      },
    );
  }
}

class _FlutterMobileNavBar extends StatelessWidget {
  const _FlutterMobileNavBar({
    required this.tabs,
    required this.selected,
    required this.onChanged,
    required this.colorScheme,
  });

  final List<NavTabConfig> tabs;
  final int selected;
  final ValueChanged<int> onChanged;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassSurface(
      padding: const EdgeInsets.symmetric(
          horizontal: GzusSpacing.xs, vertical: GzusSpacing.s),
      borderRadius: BorderRadius.circular(26),
      material: LiquidGlassMaterial.regular,
      semanticsLabel: '底部导航栏',
      child: Container(
        key: const ValueKey('mobile-bottom-nav'),
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++)
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(GzusRadii.sm),
                  onTap: () => onChanged(i),
                  child: i == selected
                      ? LiquidGlassSelectionIndicator(
                          borderRadius: BorderRadius.circular(GzusRadii.sm),
                          accentColor: colorScheme.primary,
                          child: _MobileNavItem(
                            tab: tabs[i],
                            selected: true,
                          ),
                        )
                      : _MobileNavItem(
                          tab: tabs[i],
                          selected: false,
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MobileNavItem extends StatelessWidget {
  const _MobileNavItem({required this.tab, required this.selected});

  final NavTabConfig tab;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    return Container(
      height: double.infinity,
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(GzusRadii.sm),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            tab.icon,
            size: largeText ? 20 : 24,
            color:
                selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
          ),
          SizedBox(height: largeText ? 2 : GzusSpacing.xs),
          Text(
            tab.shortLabel,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: theme.textTheme.labelSmall?.copyWith(
              color:
                  selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

String _nativeSystemImageName(String tabId) {
  const imageNames = <String, String>{
    'home': 'house.fill',
    'info': 'person.text.rectangle',
    'notices': 'bell.fill',
    'business': 'square.grid.2x2.fill',
    'applications': 'square.grid.3x3.fill',
    'schedule': 'calendar',
    'leave': 'checklist',
    'attendance': 'clock.fill',
    'exams': 'doc.text.fill',
    'grades': 'graduationcap.fill',
    'credits': 'books.vertical.fill',
    'ecard': 'drop.fill',
    'ftpUpload': 'arrow.up.doc.fill',
    'more': 'ellipsis.circle.fill',
  };
  final imageName = imageNames[tabId];
  if (imageName == null) {
    throw ArgumentError.value(tabId, 'tabId', '缺少原生底栏 SF Symbol 映射。');
  }
  return imageName;
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
