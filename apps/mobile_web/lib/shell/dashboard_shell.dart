// 导航壳主体（自 main.dart 拆分）：响应式阈值常量 + DashboardShell 及其状态、
// _OfflineBanner 等壳级私有部件。
// part of main.dart 共享同一 library，私有符号互通、无需搬运 import。
part of '../main.dart';

const _mobileBreakpoint = 720.0;
const _compactNavBreakpoint = 1024.0;
const _mobileNavBarHeight = 68.0;
const _nativeIosLiquidTabBarHeight = 80.0;
const _mobileMainNavLimit = 4;
const _mobileContentBottomGap = 10.0;
const _iosBackGestureEdgeWidth = 24.0;
const _iosBackGestureMinDistance = 72.0;
const _homeGreetingCollapseDistance = 72.0;
const _maxResidentTabPages = 3;

class DashboardShell extends StatefulWidget {
  const DashboardShell({
    super.key,
    required this.api,
    required this.studentName,
    required this.themeMode,
    required this.onThemeChanged,
    required this.onLogout,
    this.seedColor = GzusColors.blue,
    this.onSeedColorChanged,
    this.onSettingsPressed,
    this.dataSource = const DataSourceInfo(),
    this.cloudFirstWeeks = const {},
    this.cloudAutoWeek,
    this.isAdmin = false,
    this.isOwner = false,
  });

  final ApiClient api;
  final String? studentName;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final Color seedColor;
  final ValueChanged<Color>? onSeedColorChanged;
  final VoidCallback onLogout;
  final VoidCallback? onSettingsPressed;
  final DataSourceInfo dataSource;

  /// 云端同步的各学期开学日期（键 "{year}-{term}"），本地缺失时兜底
  final Map<String, String> cloudFirstWeeks;

  /// 云端同步的自动周次开关；null 表示未保存过
  final bool? cloudAutoWeek;

  /// 管理后台身份（由 /admin/me 确认后传入，用于「更多」页显示管理入口）
  final bool isAdmin;
  final bool isOwner;

  @override
  State<DashboardShell> createState() => _DashboardShellState();
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.source});

  final DataSourceInfo source;

  @override
  Widget build(BuildContext context) {
    if (!source.isStale) return const SizedBox.shrink();
    final text = source.displayText;
    final timeStr =
        source.cachedAt != null ? '上次更新：${_formatTime(source.cachedAt!)}' : '';
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: GzusSpacing.m, vertical: GzusSpacing.xs),
      color: source.needsRelogin
          ? theme.colorScheme.errorContainer
          : theme.colorScheme.tertiaryContainer,
      child: Row(
        children: [
          Icon(
            source.isOffline ? Icons.cloud_off : Icons.cloud_queue,
            size: 14,
            color: source.needsRelogin
                ? theme.colorScheme.onErrorContainer
                : theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: GzusSpacing.s),
          Expanded(
            child: Text(
              timeStr.isNotEmpty ? '$text · $timeStr' : text,
              style: TextStyle(
                fontSize: 11,
                color: source.needsRelogin
                    ? theme.colorScheme.onErrorContainer
                    : theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _DashboardShellState extends State<DashboardShell> {
  int index = 0;
  late int year;
  late int term;
  late DateTime firstWeekStart;
  late int currentWeek;
  bool autoWeek = true;

  /// 用户是否手动切换过学期（切换后启动时的自动校正不再覆盖）。
  bool _userPinnedPeriod = false;

  /// 启动时的学期自动校正是否已执行过（只跑一次）。
  bool _periodAutoCorrected = false;
  List<NavTabConfig> _navBarTabs = NavTabConfig.defaultTabs;
  String? _highlightCourse;
  String? _overrideTabId;
  final List<String> _tabHistory = [];
  int? _iosBackGesturePointer;
  Offset? _iosBackGestureStart;
  DateTime? _lastBackTime;
  bool _autoHideNavBar = true;
  final ValueNotifier<bool> _navBarVisible = ValueNotifier(true);
  final ValueNotifier<double> _homeHeaderScrollProgress = ValueNotifier(0);
  bool _sidebarCollapsed = false;
  double _lastScrollOffset = 0;

  /// 已访问页面的保活缓存：首次访问时构建，之后常驻 IndexedStack 不销毁，
  /// 切换 Tab 只换 index，页面 State/滚动位置/选中项全部保留。
  final Map<String, Widget> _pageCache = {};
  final Map<String, GlobalKey> _pageKeys = {};
  final Set<String> _visitedTabs = {};
  final Map<String, DateTime> _lastSilentRefresh = {};
  final List<String> _residentTabs = ['home'];

  /// 页面参数代数：学年/学期/周次等参数变化时 +1，
  /// 触发缓存页面重建 widget 实例（GlobalKey 保证 State 不销毁，走 didUpdateWidget）。
  int _pageGeneration = 0;
  final Map<String, int> _pageGen = {};
  bool? _lastCompact;

  @override
  void initState() {
    super.initState();
    final period = academicPeriodOf(DateTime.now());
    year = period.$1;
    term = period.$2;
    firstWeekStart = defaultFirstWeekStart(year, term);
    currentWeek =
        weekFromDate(firstWeekStart, DateTime.now(), clampToTerm: true);
    HomeWidgetBridge.setLaunchHandler(_handleWidgetLaunch);
    NotificationOpenBridge.setOpenTabHandler(_navigateToTab);
    LiveActivityController.instance.onOpen = _handleLiveActivityOpen;
    _loadNavConfig().then((_) => _consumeWidgetLaunch());
    _loadAutoHideSetting();
    _loadScheduleSettings();
    _autoCorrectPeriodOnce();
  }

  @override
  void dispose() {
    HomeWidgetBridge.setLaunchHandler(null);
    NotificationOpenBridge.setOpenTabHandler(null);
    LiveActivityController.instance.onOpen = null;
    _navBarVisible.dispose();
    _homeHeaderScrollProgress.dispose();
    super.dispose();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    _updateHomeHeaderScrollProgress(notification);
    if (!_autoHideNavBar) return false;
    if (notification is ScrollUpdateNotification) {
      final currentOffset = notification.metrics.pixels;
      final delta = currentOffset - _lastScrollOffset;
      if (delta > 8 && _navBarVisible.value) {
        _navBarVisible.value = false;
      } else if (delta < -8 && !_navBarVisible.value) {
        _navBarVisible.value = true;
      } else if (currentOffset <= 0 && !_navBarVisible.value) {
        _navBarVisible.value = true;
      }
      _lastScrollOffset = currentOffset;
    } else if (notification is ScrollEndNotification) {
      if (!_navBarVisible.value && notification.metrics.pixels <= 0) {
        _navBarVisible.value = true;
      }
    }
    return false;
  }

  double _mobileContentBottomInset(BuildContext context, bool navBarVisible) {
    if (!navBarVisible) return _mobileContentBottomGap;
    return MediaQuery.paddingOf(context).bottom +
        _mobileNavBarHeight +
        GzusSpacing.s +
        _mobileContentBottomGap;
  }

  void _updateHomeHeaderScrollProgress(ScrollNotification notification) {
    if (_activeTabId != 'home' ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical) {
      return;
    }
    final progress =
        (notification.metrics.pixels.clamp(0.0, _homeGreetingCollapseDistance) /
                _homeGreetingCollapseDistance)
            .toDouble();
    if ((_homeHeaderScrollProgress.value - progress).abs() < 0.001) return;
    _homeHeaderScrollProgress.value = progress;
  }

  void _resetHomeHeaderScrollProgress() {
    if (_homeHeaderScrollProgress.value == 0) return;
    _homeHeaderScrollProgress.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    if (_navBarTabs.isNotEmpty && index >= _navBarTabs.length) index = 0;
    final activeTabId = _overrideTabId ??
        (_navBarTabs.isNotEmpty ? _navBarTabs[index].tabId : null);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_goBackInTabHistory()) return;
        final now = DateTime.now();
        if (_lastBackTime != null &&
            now.difference(_lastBackTime!).inSeconds < 2) {
          SystemNavigator.pop();
          return;
        }
        _lastBackTime = now;
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('再按一次退出应用'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < _mobileBreakpoint;
            // 断点翻转时重建缓存页面（如 more 页的移动/宽屏参数）
            if (_lastCompact != null && _lastCompact != compact) {
              _pageGeneration++;
            }
            _lastCompact = compact;
            final mobileTabs = _mobileNavTabs(_navBarTabs);
            final effectiveSelected = _overrideTabId != null ? -1 : index;
            final activeMobileIndex =
                mobileTabs.indexWhere((t) => t.tabId == activeTabId);
            final moreMobileIndex =
                mobileTabs.indexWhere((t) => t.tabId == 'more');
            final mobileSelected =
                activeMobileIndex >= 0 ? activeMobileIndex : moreMobileIndex;
            if (compact) {
              return _withIosBackGesture(Stack(
                children: [
                  Positioned.fill(
                    child:
                        LiquidGlassAmbientBackdrop(seedColor: widget.seedColor),
                  ),
                  SafeArea(
                    bottom: false,
                    child: Column(
                      children: [
                        _OfflineBanner(source: widget.dataSource),
                        if (activeTabId == 'home')
                          ValueListenableBuilder<double>(
                            valueListenable: _homeHeaderScrollProgress,
                            builder: (context, progress, _) {
                              final visibleFraction = 1 - progress;
                              return ClipRect(
                                child: Align(
                                  key: const ValueKey('mobile-home-greeting'),
                                  alignment: Alignment.topCenter,
                                  heightFactor: visibleFraction,
                                  child: IgnorePointer(
                                    ignoring: progress >= 1,
                                    child: ExcludeSemantics(
                                      excluding: progress >= 1,
                                      child: Opacity(
                                        opacity: visibleFraction,
                                        child: Padding(
                                          padding: EdgeInsets.fromLTRB(
                                            GzusInsets.contentGutter(context),
                                            GzusSpacing.m,
                                            GzusInsets.contentGutter(context),
                                            GzusSpacing.s,
                                          ),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      '你好，${widget.studentName ?? '软帮手'}',
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleLarge,
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      '$year-${term == 1 ? '第一学期' : '第二学期'} · 第 $currentWeek 周',
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .bodySmall,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (widget.isAdmin)
                                                IconButton(
                                                  onPressed:
                                                      widget.onSettingsPressed,
                                                  icon: const Icon(Icons
                                                      .admin_panel_settings),
                                                  tooltip: '管理后台',
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        Expanded(
                          child: ValueListenableBuilder<bool>(
                            valueListenable: _navBarVisible,
                            builder: (context, visible, _) {
                              final navBarVisible = !_autoHideNavBar || visible;
                              return NotificationListener<ScrollNotification>(
                                onNotification: _onScrollNotification,
                                child: AnimatedPadding(
                                  duration: const Duration(milliseconds: 200),
                                  curve: Curves.easeInOut,
                                  padding: EdgeInsets.fromLTRB(
                                    GzusInsets.contentGutter(context),
                                    8,
                                    GzusInsets.contentGutter(context),
                                    _mobileContentBottomInset(
                                      context,
                                      navBarVisible,
                                    ),
                                  ),
                                  child: Theme(
                                    data: Theme.of(context).copyWith(
                                      scaffoldBackgroundColor:
                                          Colors.transparent,
                                    ),
                                    child: KeyedSubtree(
                                      key: const ValueKey(
                                        'mobile-dashboard-content',
                                      ),
                                      child: _CenteredPage(
                                        maxWidth: 720,
                                        child: _buildPageStack(activeTabId),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _navBarVisible,
                      builder: (context, visible, _) {
                        final show = !_autoHideNavBar || visible;
                        return MobileNavBar(
                          tabs: mobileTabs,
                          selected:
                              mobileSelected.clamp(0, mobileTabs.length - 1),
                          visible: show,
                          onChanged: (value) async {
                            _navBarVisible.value = true;
                            final selectedTab = mobileTabs[value];
                            _navigateToTab(selectedTab.tabId);
                          },
                        );
                      },
                    ),
                  ),
                  LiveActivityIsland(
                    controller: LiveActivityController.instance,
                  ),
                ],
              ));
            }
            final dense = constraints.maxWidth < _compactNavBreakpoint;
            return _withIosBackGesture(Stack(
              children: [
                Positioned.fill(
                  child:
                      LiquidGlassAmbientBackdrop(seedColor: widget.seedColor),
                ),
                Row(
                  children: [
                    AppSidebar(
                      tabs: _navBarTabs,
                      selected: effectiveSelected,
                      compact: _sidebarCollapsed,
                      dense: dense,
                      onToggleCompact: () {
                        setState(() => _sidebarCollapsed = !_sidebarCollapsed);
                      },
                      onChanged: (value) async {
                        _navBarVisible.value = true;
                        _navigateToTab(_navBarTabs[value].tabId);
                      },
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          _OfflineBanner(source: widget.dataSource),
                          Expanded(
                            child: SafeArea(
                              child: Padding(
                                padding: EdgeInsets.all(
                                  GzusInsets.contentGutter(context),
                                ),
                                child: NotificationListener<ScrollNotification>(
                                  onNotification: _onScrollNotification,
                                  child: _CenteredPage(
                                    maxWidth: 1280,
                                    child: _buildPageStack(activeTabId),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                LiveActivityIsland(
                  controller: LiveActivityController.instance,
                ),
              ],
            ));
          },
        ),
      ),
    );
  }

  Future<void> _loadAutoHideSetting() async {
    final value = await NavPreferences.loadAutoHideNavBar();
    if (mounted) setState(() => _autoHideNavBar = value);
  }

  Future<void> _loadNavConfig() async {
    final tabIds = await NavPreferences.load();
    final tabs = <NavTabConfig>[];
    final normalizedTabIds =
        tabIds.contains('home') ? tabIds : ['home', ...tabIds];
    for (final id in normalizedTabIds) {
      if (id == 'more') {
        tabs.add(NavTabConfig.moreTab);
      } else {
        final found = NavTabConfig.available.where((t) => t.tabId == id);
        if (found.isNotEmpty) tabs.add(found.first);
      }
    }
    if (mounted) {
      _pageGeneration++;
      setState(() {
        _navBarTabs = _filterRestrictedTabs(tabs);
        final homeIdx = tabs.indexWhere((t) => t.tabId == 'home');
        index = homeIdx >= 0 ? homeIdx : 0;
      });
    }
  }

  List<NavTabConfig> _filterRestrictedTabs(List<NavTabConfig> tabs) {
    return tabs
        .where((t) => !hideEcardOnCurrentPlatform || t.tabId != 'ecard')
        .toList();
  }

  /// 惰性保活页面栈：页面首次激活时才构建，之后常驻 IndexedStack 不销毁；
  /// 切换 Tab 只换 index，激活的子页淡入。
  Widget _buildPageStack(String? activeTabId) {
    if (activeTabId == null) return const SizedBox.shrink();
    _retainTab(activeTabId);
    final children = <Widget>[
      for (final tabId in _residentTabs)
        _pageSlot(tabId, active: tabId == activeTabId),
    ];
    final activeIndex = _residentTabs.indexOf(activeTabId);
    return IndexedStack(index: activeIndex, children: children);
  }

  /// 保留当前和最近访问的少量页面，限制重页面、定时器和滚动树无限累积。
  void _retainTab(String tabId) {
    _residentTabs.remove(tabId);
    _residentTabs.add(tabId);
    while (_residentTabs.length > _maxResidentTabPages) {
      final evictedTabId = _residentTabs.removeAt(0);
      _pageCache.remove(evictedTabId);
      _pageKeys.remove(evictedTabId);
      _pageGen.remove(evictedTabId);
      _visitedTabs.remove(evictedTabId);
      _lastSilentRefresh.remove(evictedTabId);
    }
  }

  /// 单个页面的保活槽位：未访问时用占位符，访问后缓存页面实例；
  /// GlobalKey 保证参数变化重建 widget 实例时 State 不销毁。
  Widget _pageSlot(String tabId, {required bool active}) {
    final key = _pageKeys.putIfAbsent(
        tabId, () => GlobalKey(debugLabel: 'page-$tabId'));
    final Widget child;
    if (_visitedTabs.contains(tabId) || active) {
      _visitedTabs.add(tabId);
      child = _pageFor(tabId);
    } else {
      child = const SizedBox.shrink();
    }
    return KeyedSubtree(
      key: key,
      child: TickerMode(
        enabled: active,
        child: AnimatedOpacity(
          opacity: active ? 1 : 0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          child: child,
        ),
      ),
    );
  }

  /// 返回页面的缓存 widget 实例；参数代数变化时用当前参数重建（State 保留，
  /// 变化通过各页已有的 didUpdateWidget 传播）。
  Widget _pageFor(String tabId) {
    final cached = _pageCache[tabId];
    if (cached != null && _pageGen[tabId] == _pageGeneration) return cached;
    final built = _buildPage(tabId);
    _pageCache[tabId] = built;
    _pageGen[tabId] = _pageGeneration;
    return built;
  }

  /// Tab 激活：首次访问由 initState 自行拉取；再次访问且距上次超过 60 秒时
  /// 触发页面静默刷新（显示旧数据、后台拉新）。
  void _activateTab(String tabId) {
    if (tabId != 'home') _resetHomeHeaderScrollProgress();
    _retainTab(tabId);
    final firstVisit = !_visitedTabs.contains(tabId);
    _visitedTabs.add(tabId);
    if (firstVisit) return;
    final last = _lastSilentRefresh[tabId];
    final now = DateTime.now();
    if (last != null && now.difference(last).inSeconds < 60) return;
    _lastSilentRefresh[tabId] = now;
    final state = _pageKeys[tabId]?.currentState;
    if (state is PageSilentRefresh) state.silentRefresh();
  }

  Widget _buildPage(String tabId) {
    switch (tabId) {
      case 'home':
        return HomePage(
          api: widget.api,
          year: year,
          term: term,
          currentWeek: currentWeek,
          firstWeekStart: firstWeekStart,
          onNavigate: _navigateToTab,
          onSessionExpired: widget.onLogout,
          headerScrollProgress: _homeHeaderScrollProgress,
          studentName: widget.studentName,
          studentId: widget.api.studentId,
        );
      case 'info':
        return InfoPage(api: widget.api, onSessionExpired: widget.onLogout);
      case 'notices':
        return NoticesPage(api: widget.api, onSessionExpired: widget.onLogout);
      case 'business':
        return BusinessPage(api: widget.api, onSessionExpired: widget.onLogout);
      case 'applications':
        return ApplicationsPage(
            api: widget.api, onSessionExpired: widget.onLogout);
      case 'schedule':
        return SchedulePage(
            api: widget.api,
            year: year,
            term: term,
            currentWeek: currentWeek,
            firstWeekStart: firstWeekStart,
            autoWeek: autoWeek,
            onFirstWeekChanged: _setFirstWeekStart,
            onCurrentWeekChanged: _setCurrentWeek,
            onAutoWeekChanged: _setAutoWeek,
            onSessionExpired: widget.onLogout);
      case 'attendance':
        return AttendancePage(
            api: widget.api,
            year: year,
            term: term,
            onSessionExpired: widget.onLogout);
      case 'leave':
        if (hideEcardOnCurrentPlatform) {
          return const WebUnsupportedPage(
            title: '自动请假',
            icon: Icons.fact_check,
            message: '自动请假功能需要在手机 App 中使用，Web 端暂不支持自动填写表单。',
          );
        }
        return AutoLeavePage(
            api: widget.api,
            year: year,
            term: term,
            firstWeekStart: firstWeekStart,
            onSessionExpired: widget.onLogout);
      case 'exams':
        return ExamsPage(
            api: widget.api,
            periods: _allAcademicPeriods(),
            year: year,
            term: term,
            onSessionExpired: widget.onLogout,
            highlightCourse: _highlightCourse);
      case 'grades':
        return GradesPage(
            api: widget.api,
            periods: _allAcademicPeriods(),
            year: year,
            term: term,
            onSessionExpired: widget.onLogout,
            onNavigateToExam: (courseName) {
              setState(() {
                _highlightCourse = courseName;
                _pageGeneration++;
              });
              _navigateToTab('exams');
              Future.delayed(const Duration(seconds: 2), () {
                if (mounted) {
                  setState(() => _highlightCourse = null);
                  _pageGeneration++;
                }
              });
            });
      case 'credits':
        return CreditsPage(api: widget.api, onSessionExpired: widget.onLogout);
      case 'ecard':
        return EcardPage(api: widget.api, onSessionExpired: widget.onLogout);
      case 'ftpUpload':
        return const FtpUploadPage();
      case 'more':
        final compactLayout =
            MediaQuery.sizeOf(context).width < _mobileBreakpoint;
        return MorePage(
            api: widget.api,
            navBarTabs:
                compactLayout ? _mobileNavTabs(_navBarTabs) : _navBarTabs,
            navBarLimit: compactLayout ? _mobileMainNavLimit : null,
            onNavigate: _navigateToTab,
            onConfigChanged: _loadNavConfig,
            year: year,
            term: term,
            themeMode: widget.themeMode,
            onThemeChanged: widget.onThemeChanged,
            seedColor: widget.seedColor,
            onSeedColorChanged: widget.onSeedColorChanged,
            onLogout: widget.onLogout,
            onYearChanged: (v) => _setAcademicPeriod(v, term),
            onTermChanged: (v) => _setAcademicPeriod(year, v),
            autoHideNavBar: _autoHideNavBar,
            onAutoHideNavBarChanged: (v) async {
              await NavPreferences.saveAutoHideNavBar(v);
              if (!mounted) return;
              _navBarVisible.value = true;
              setState(() => _autoHideNavBar = v);
            },
            onShowBackgroundGuide: widget.onSettingsPressed,
            isAdmin: widget.isAdmin,
            isOwner: widget.isOwner);
      default:
        return const SizedBox.shrink();
    }
  }

  void _navigateToTab(String tabId) {
    if (hideEcardOnCurrentPlatform && tabId == 'ecard') return;
    final activeTabId = _activeTabId;
    if (activeTabId == tabId) return;
    _recordTabHistory(activeTabId);
    _activateTab(tabId);
    final idx = _navBarTabs.indexWhere((t) => t.tabId == tabId);
    if (idx >= 0) {
      _navBarVisible.value = true;
      setState(() {
        index = idx;
        _overrideTabId = null;
      });
      return;
    }
    final tabConfig = NavTabConfig.available.where((t) => t.tabId == tabId);
    if (tabConfig.isEmpty) return;
    _navBarVisible.value = true;
    setState(() {
      _overrideTabId = tabId;
    });
  }

  String? get _activeTabId {
    if (_overrideTabId != null) return _overrideTabId;
    if (_navBarTabs.isEmpty || index >= _navBarTabs.length) return null;
    return _navBarTabs[index].tabId;
  }

  Widget _withIosBackGesture(Widget child) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handleIosBackGestureStart,
      onPointerMove: _handleIosBackGestureMove,
      onPointerUp: _clearIosBackGesture,
      onPointerCancel: _clearIosBackGesture,
      child: child,
    );
  }

  bool get _isIosBackGestureEnabled =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      _tabHistory.isNotEmpty;

  void _handleIosBackGestureStart(PointerDownEvent event) {
    if (!_isIosBackGestureEnabled ||
        event.localPosition.dx > _iosBackGestureEdgeWidth) {
      return;
    }
    _iosBackGesturePointer = event.pointer;
    _iosBackGestureStart = event.localPosition;
  }

  void _handleIosBackGestureMove(PointerMoveEvent event) {
    if (event.pointer != _iosBackGesturePointer ||
        _iosBackGestureStart == null) {
      return;
    }
    final delta = event.localPosition - _iosBackGestureStart!;
    if (delta.dx < _iosBackGestureMinDistance ||
        delta.dx.abs() <= delta.dy.abs()) {
      return;
    }
    _clearIosBackGesture(event);
    _goBackInTabHistory();
  }

  void _clearIosBackGesture(PointerEvent event) {
    if (event.pointer != _iosBackGesturePointer) return;
    _iosBackGesturePointer = null;
    _iosBackGestureStart = null;
  }

  void _recordTabHistory(String? tabId) {
    if (tabId == null || tabId.isEmpty) return;
    if (_tabHistory.isNotEmpty && _tabHistory.last == tabId) return;
    _tabHistory.add(tabId);
  }

  bool _goBackInTabHistory() {
    if (_tabHistory.isEmpty) return false;
    final tabId = _tabHistory.removeLast();
    _activateTab(tabId);
    final idx = _navBarTabs.indexWhere((tab) => tab.tabId == tabId);
    _navBarVisible.value = true;
    setState(() {
      index = idx >= 0 ? idx : index;
      _overrideTabId = idx >= 0 ? null : tabId;
    });
    return true;
  }

  Future<void> _consumeWidgetLaunch() async {
    final tab = await HomeWidgetBridge.consumeInitialTab();
    _handleWidgetLaunch(tab);
  }

  void _handleWidgetLaunch(String? tab) {
    if (!mounted || tab == null || tab.isEmpty || tab == 'home') return;
    _navigateToTab(tab);
  }

  void _handleLiveActivityOpen(LiveActivityEvent event) {
    final tab = event.targetTab;
    if (tab != null && tab.isNotEmpty) {
      _navigateToTab(tab);
      return;
    }
    final url = event.url;
    if (url != null && url.isNotEmpty) {
      unawaited(openInAppBrowser(context, url, api: widget.api));
    }
  }

  List<AcademicPeriod> _allAcademicPeriods() => [
        for (var value = year - 5; value <= year; value++)
          for (var valueTerm = 1; valueTerm <= 2; valueTerm++)
            AcademicPeriod(value, valueTerm),
      ];

  Future<void> _loadScheduleSettings() async {
    final loadYear = year;
    final loadTerm = term;
    final prefs = await SharedPreferences.getInstance();
    final firstWeekText =
        prefs.getString(_settingsKey(loadYear, loadTerm, 'firstWeekStart'));
    // 本地缺失时回退云端（按学期），最后才用默认推导值
    final cloudText = firstWeekText == null
        ? widget.cloudFirstWeeks['$loadYear-$loadTerm']
        : null;
    final savedAuto =
        prefs.getBool('schedule.autoWeek') ?? widget.cloudAutoWeek ?? autoWeek;
    final defaultStart = defaultFirstWeekStart(loadYear, loadTerm);
    final parsedStart = DateTime.tryParse(firstWeekText ?? cloudText ?? '');
    final start = parsedStart ?? defaultStart;
    final savedWeek = prefs.getInt(_settingsKey(loadYear, loadTerm, 'week'));
    if (!mounted || loadYear != year || loadTerm != term) return;
    setState(() {
      firstWeekStart = start;
      autoWeek = savedAuto;
      currentWeek = savedAuto
          ? weekFromDate(start, DateTime.now(), clampToTerm: true)
          : (savedWeek ??
              weekFromDate(start, DateTime.now(), clampToTerm: true));
    });
  }

  /// 启动时用已保存的开学日期反推当前学期并自动校正一次（best-effort）。
  /// 本地和云端记录同时参与判断，本地优先，避免本地刚更新时被云端旧记录覆盖；
  /// 用户手动切换过学期后不再校正。
  Future<void> _autoCorrectPeriodOnce() async {
    if (_periodAutoCorrected) return;
    _periodAutoCorrected = true;
    final firstWeeks = Map<String, String>.from(widget.cloudFirstWeeks);
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      const prefix = 'schedule.';
      const suffix = '.firstWeekStart';
      if (!key.startsWith(prefix) || !key.endsWith(suffix)) continue;
      final value = prefs.getString(key);
      if (value == null || value.isEmpty) continue;
      final mid = key.substring(prefix.length, key.length - suffix.length);
      firstWeeks[mid.replaceAll('.', '-')] = value;
    }
    final resolved = academicPeriodFromFirstWeeks(firstWeeks, DateTime.now());
    if (resolved == null || resolved == (year, term)) return;
    if (!mounted || _userPinnedPeriod) return;
    setState(() {
      year = resolved.$1;
      term = resolved.$2;
      firstWeekStart = defaultFirstWeekStart(year, term);
      currentWeek =
          weekFromDate(firstWeekStart, DateTime.now(), clampToTerm: true);
      _pageGeneration++;
    });
    _loadScheduleSettings();
  }

  Future<void> _saveScheduleSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _settingsKey(year, term, 'firstWeekStart'),
      dateText(firstWeekStart),
    );
    await prefs.setInt(_settingsKey(year, term, 'week'), currentWeek);
    await prefs.setBool('schedule.autoWeek', autoWeek);
    unawaited(_syncScheduleSettingsToCloud());
  }

  /// 把当前学期的开学日期合并进云端（best-effort，失败仅打印日志）。
  Future<void> _syncScheduleSettingsToCloud() async {
    try {
      final merged = Map<String, String>.from(widget.cloudFirstWeeks)
        ..['$year-$term'] = dateText(firstWeekStart);
      await widget.api.saveScheduleSettings(
        firstWeeks: merged,
        autoWeek: autoWeek,
      );
    } catch (error) {
      debugPrint('同步开学日期到云端失败: error=${error.runtimeType}');
    }
  }

  void _setAcademicPeriod(int nextYear, int nextTerm) {
    _userPinnedPeriod = true;
    setState(() {
      year = nextYear;
      term = nextTerm;
      firstWeekStart = defaultFirstWeekStart(nextYear, nextTerm);
      currentWeek =
          weekFromDate(firstWeekStart, DateTime.now(), clampToTerm: true);
      _pageGeneration++;
    });
    _loadScheduleSettings();
  }

  void _setFirstWeekStart(DateTime value) {
    // 兜底归一化：确保首周开始日期始终为周一
    final monday = mondayOf(value);
    setState(() {
      firstWeekStart = monday;
      if (autoWeek) {
        currentWeek = weekFromDate(monday, DateTime.now(), clampToTerm: true);
      }
      _pageGeneration++;
    });
    _saveScheduleSettings();
  }

  void _setCurrentWeek(int value) {
    setState(() {
      currentWeek = value.clamp(1, 30);
      autoWeek = false;
      _pageGeneration++;
    });
    _saveScheduleSettings();
  }

  void _setAutoWeek(bool value) {
    setState(() {
      autoWeek = value;
      if (value) {
        currentWeek =
            weekFromDate(firstWeekStart, DateTime.now(), clampToTerm: true);
      }
      _pageGeneration++;
    });
    _saveScheduleSettings();
  }
}
