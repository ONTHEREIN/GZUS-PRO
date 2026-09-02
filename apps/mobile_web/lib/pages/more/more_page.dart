import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../api_client.dart';
import '../../gzus_design.dart';
import '../../models/nav_config.dart';
import '../../responsive/breakpoints.dart';
import '../../responsive/spacing.dart';
import '../../test_flags.dart';
import '../../widgets/floating_page_scaffold.dart';
import '../../widgets/grid_columns.dart';
import '../../widgets/page_panel.dart';
import '../../widgets/scale_tap.dart';
import '../../widgets/seed_color_picker.dart';
import '../../update_service.dart' deferred as update_service;
import '../admin/admin_page.dart';

class MorePage extends StatefulWidget {
  const MorePage({
    super.key,
    required this.api,
    required this.navBarTabs,
    this.navBarLimit,
    required this.onNavigate,
    required this.onConfigChanged,
    this.year = 0,
    this.term = 1,
    this.themeMode = ThemeMode.system,
    this.onThemeChanged,
    this.seedColor = GzusColors.blue,
    this.onSeedColorChanged,
    this.onLogout,
    this.onYearChanged,
    this.onTermChanged,
    this.autoHideNavBar = true,
    this.onAutoHideNavBarChanged,
    this.onShowBackgroundGuide,
    this.onShowNotificationSettings,
    this.isAdmin = false,
    this.isOwner = false,
  });

  final ApiClient api;
  final List<NavTabConfig> navBarTabs;
  final int? navBarLimit;
  final ValueChanged<String> onNavigate;
  final VoidCallback onConfigChanged;
  final int year;
  final int term;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeChanged;
  final Color seedColor;
  final ValueChanged<Color>? onSeedColorChanged;
  final VoidCallback? onLogout;
  final ValueChanged<int>? onYearChanged;
  final ValueChanged<int>? onTermChanged;
  final bool autoHideNavBar;
  final ValueChanged<bool>? onAutoHideNavBarChanged;
  final VoidCallback? onShowBackgroundGuide;
  final VoidCallback? onShowNotificationSettings;

  /// 管理后台身份（由 main.dart 传入，控制「管理后台」入口显隐与 owner 权限）
  final bool isAdmin;
  final bool isOwner;

  @override
  State<MorePage> createState() => _MorePageState();
}

class _MorePageState extends State<MorePage> {
  bool _editing = false;
  late List<NavTabConfig> _barTabs;
  late List<NavTabConfig> _moreTabs;

  @override
  void initState() {
    super.initState();
    _updateTabs();
  }

  @override
  void didUpdateWidget(covariant MorePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navBarTabs != widget.navBarTabs) _updateTabs();
  }

  void _updateTabs() {
    final barIds = widget.navBarTabs.map((t) => t.tabId).toSet();
    _barTabs = [...widget.navBarTabs.where((t) => t.tabId != 'more')];
    _moreTabs =
        NavTabConfig.available.where((t) => !barIds.contains(t.tabId)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return _buildModernLayout(context);
  }

  /// 新布局入口保留独立方法，方便与旧布局逐项核对交互行为。
  Widget _buildModernLayout(BuildContext context) =>
      _buildRefreshLayout(context);

  /// 保留旧布局，便于与新版主页的交互路径逐项对照。
  // ignore: unused_element
  Widget _buildLegacyLayout(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final navBarLimit = widget.navBarLimit;
    final canAddNavBarTab =
        navBarLimit == null || _barTabs.length < navBarLimit;
    final navBarTitle = navBarLimit == null ? '边栏应用' : '底栏（最多$navBarLimit个）';
    return PagePanel(
      title: '更多',
      icon: Icons.more_horiz,
      expandChild: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_editing) ...[
            TextButton(
              onPressed: () async {
                await NavPreferences.reset();
                widget.onConfigChanged();
                setState(() {
                  _editing = false;
                  _updateTabs();
                });
              },
              child: const Text('恢复默认'),
            ),
            FilledButton(
              onPressed: () async {
                final tabIds = [..._barTabs.map((t) => t.tabId), 'more'];
                await NavPreferences.save(tabIds);
                widget.onConfigChanged();
                setState(() {
                  _editing = false;
                  _updateTabs();
                });
              },
              child: const Text('完成'),
            ),
          ] else
            IconButton(
              onPressed: () => setState(() => _editing = true),
              icon: const Icon(Icons.edit),
              tooltip: '编辑导航',
            ),
        ],
      ),
      child: CustomScrollView(
        slivers: [
          // 导航管理区
          if (_editing) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Text(navBarTitle,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant)),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final columns = contentGridColumns(
                    constraints.crossAxisExtent,
                    minTileWidth: 72,
                    maxColumns: 5,
                  );
                  return SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: columns < 3 ? 0.9 : 1,
                    ),
                    delegate: SliverChildListDelegate([
                      for (final tab in [..._barTabs])
                        _MoreGridItem(
                          tab: tab,
                          editing: true,
                          canRemove: !tab.isFixed,
                          onRemove: () {
                            if (!tab.isFixed && _barTabs.length > 2) {
                              setState(() {
                                _barTabs.remove(tab);
                                _moreTabs.add(tab);
                              });
                            }
                          },
                        ),
                    ]),
                  );
                },
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text('更多页',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant)),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final columns = contentGridColumns(
                    constraints.crossAxisExtent,
                    minTileWidth: 72,
                    maxColumns: 5,
                  );
                  return SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: columns < 3 ? 0.9 : 1,
                    ),
                    delegate: SliverChildListDelegate([
                      for (final tab in [..._moreTabs])
                        _MoreGridItem(
                          tab: tab,
                          editing: true,
                          canAdd: canAddNavBarTab,
                          onAdd: () {
                            if (canAddNavBarTab) {
                              setState(() {
                                _moreTabs.remove(tab);
                                _barTabs.add(tab);
                              });
                            }
                          },
                        ),
                    ]),
                  );
                },
              ),
            ),
          ] else ...[
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final columns = contentGridColumns(
                    constraints.crossAxisExtent,
                    minTileWidth: 72,
                    maxColumns: 5,
                  );
                  return SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: columns < 3 ? 0.9 : 1,
                    ),
                    delegate: SliverChildListDelegate([
                      for (final tab in [..._moreTabs])
                        _MoreGridItem(
                          tab: tab,
                          editing: false,
                          onTap: () => widget.onNavigate(tab.tabId),
                        ),
                    ]),
                  );
                },
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Divider(),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          // 快捷设置分组
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('快捷设置',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant)),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Card(
                elevation: 0,
                color: colorScheme.surfaceContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.onYearChanged != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Row(
                          children: [
                            const Icon(Icons.calendar_today, size: 20),
                            const SizedBox(width: 12),
                            const Text('学年'),
                            const Spacer(),
                            DropdownMenu<int>(
                              key: ValueKey('more-year-${widget.year}'),
                              initialSelection: widget.year,
                              enableSearch: false,
                              requestFocusOnTap: false,
                              onSelected: (v) {
                                if (v != null) widget.onYearChanged?.call(v);
                              },
                              dropdownMenuEntries: [
                                for (var y = DateTime.now().year;
                                    y >= DateTime.now().year - 5;
                                    y--)
                                  DropdownMenuEntry(value: y, label: '$y'),
                              ],
                            ),
                          ],
                        ),
                      ),
                    if (widget.onTermChanged != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Row(
                          children: [
                            const Icon(Icons.view_week, size: 20),
                            const SizedBox(width: 12),
                            const Text('学期'),
                            const Spacer(),
                            DropdownMenu<int>(
                              key: ValueKey('more-term-${widget.term}'),
                              initialSelection: widget.term,
                              enableSearch: false,
                              requestFocusOnTap: false,
                              onSelected: (v) {
                                if (v != null) widget.onTermChanged?.call(v);
                              },
                              dropdownMenuEntries: const [
                                DropdownMenuEntry(value: 1, label: '第1学期'),
                                DropdownMenuEntry(value: 2, label: '第2学期'),
                              ],
                            ),
                          ],
                        ),
                      ),
                    if (widget.onThemeChanged != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.palette, size: 20),
                                SizedBox(width: 12),
                                Text('外观模式'),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Center(
                              child: SegmentedButton<ThemeMode>(
                                segments: const [
                                  ButtonSegment(
                                    value: ThemeMode.light,
                                    label: Text('浅色'),
                                    icon: Icon(Icons.light_mode, size: 18),
                                  ),
                                  ButtonSegment(
                                    value: ThemeMode.system,
                                    label: Text('自动'),
                                    icon: Icon(Icons.brightness_auto, size: 18),
                                  ),
                                  ButtonSegment(
                                    value: ThemeMode.dark,
                                    label: Text('深色'),
                                    icon: Icon(Icons.dark_mode, size: 18),
                                  ),
                                ],
                                selected: {widget.themeMode},
                                onSelectionChanged: (s) =>
                                    widget.onThemeChanged?.call(s.first),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (widget.onSeedColorChanged != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.color_lens, size: 20),
                                SizedBox(width: 12),
                                Text('主题色'),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Center(
                              child: SeedColorPicker(
                                selectedColor: widget.seedColor,
                                onColorSelected: widget.onSeedColorChanged!,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (widget.onAutoHideNavBarChanged != null)
                      SwitchListTile(
                        value: widget.autoHideNavBar,
                        onChanged: widget.onAutoHideNavBarChanged,
                        secondary: const Icon(Icons.hide_source),
                        title: const Text('自动隐藏底栏'),
                        subtitle: const Text('滚动时自动隐藏底部导航栏'),
                      ),
                    if (widget.onShowBackgroundGuide != null)
                      ListTile(
                        leading: const Icon(Icons.settings),
                        title: const Text('后台'),
                        subtitle: const Text('设置后台保活和推送'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: widget.onShowBackgroundGuide,
                      ),
                    if (widget.isAdmin)
                      ListTile(
                        leading: const Icon(Icons.admin_panel_settings),
                        title: const Text('管理后台'),
                        subtitle: const Text('会话/统计/系统状态'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => AdminPage(
                                api: widget.api, isOwner: widget.isOwner),
                          ),
                        ),
                      ),
                    ListTile(
                      key: const ValueKey('home-widget-guide-tile'),
                      leading: const Icon(Icons.widgets),
                      title: const Text('桌面组件'),
                      subtitle: const Text('添加方法、显示内容和刷新说明'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (context) => const HomeWidgetGuidePage()),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.info),
                      title: const Text('关于'),
                      subtitle: const Text('应用信息与更新'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (context) => AboutPage(api: widget.api)),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          // 账户分组
          if (widget.onLogout != null) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('账户',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant)),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainer,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ListTile(
                    leading: Icon(Icons.logout, color: colorScheme.error),
                    title: Text('退出登录',
                        style: TextStyle(color: colorScheme.error)),
                    onTap: widget.onLogout,
                  ),
                ),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  Widget _buildRefreshLayout(BuildContext context) {
    final navBarLimit = widget.navBarLimit;
    final canAddNavBarTab =
        navBarLimit == null || _barTabs.length < navBarLimit;
    final navBarTitle = navBarLimit == null ? '边栏应用' : '底栏（最多$navBarLimit个）';
    return PagePanel(
      title: '更多',
      icon: Icons.more_horiz,
      expandChild: true,
      trailing: _buildPanelActions(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              constraints.maxWidth.gzusBreakpoint != GzusBreakpoint.compact;
          final navigation = _buildNavigationSection(
            context: context,
            navBarTitle: navBarTitle,
            canAddNavBarTab: canAddNavBarTab,
          );
          final settings = _buildSettingsSection(context);
          final account = _buildAccountSection(context);
          return SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: GzusSpacing.xl),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: navigation),
                      const SizedBox(width: GzusSpacing.l),
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            settings,
                            if (account != null) ...[
                              const SizedBox(height: GzusSpacing.l),
                              account,
                            ],
                          ],
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      navigation,
                      const SizedBox(height: GzusSpacing.l),
                      settings,
                      if (account != null) ...[
                        const SizedBox(height: GzusSpacing.l),
                        account,
                      ],
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _buildPanelActions() {
    if (!_editing) {
      return IconButton(
        onPressed: () => setState(() => _editing = true),
        icon: const Icon(Icons.edit_outlined),
        tooltip: '编辑导航',
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          onPressed: () async {
            await NavPreferences.reset();
            widget.onConfigChanged();
            setState(() {
              _editing = false;
              _updateTabs();
            });
          },
          child: const Text('恢复默认'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: () async {
            final tabIds = [..._barTabs.map((tab) => tab.tabId), 'more'];
            await NavPreferences.save(tabIds);
            widget.onConfigChanged();
            setState(() {
              _editing = false;
              _updateTabs();
            });
          },
          child: const Text('完成'),
        ),
      ],
    );
  }

  Widget _buildNavigationSection({
    required BuildContext context,
    required String navBarTitle,
    required bool canAddNavBarTab,
  }) {
    return _sectionCard(
      context: context,
      title: _editing ? '编辑导航' : '应用入口',
      icon: _editing ? Icons.edit_outlined : Icons.apps_outlined,
      child: _editing
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _navigationGroup(
                  context: context,
                  title: navBarTitle,
                  tabs: _barTabs,
                  emptyMessage: '至少保留两个导航应用。',
                  itemBuilder: (tab) => _MoreGridItem(
                    tab: tab,
                    editing: true,
                    canRemove: !tab.isFixed,
                    onRemove: () {
                      if (!tab.isFixed && _barTabs.length > 2) {
                        setState(() {
                          _barTabs.remove(tab);
                          _moreTabs.add(tab);
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(height: GzusSpacing.l),
                _navigationGroup(
                  context: context,
                  title: '更多页',
                  tabs: _moreTabs,
                  emptyMessage: '所有应用均已加入导航。',
                  itemBuilder: (tab) => _MoreGridItem(
                    tab: tab,
                    editing: true,
                    canAdd: canAddNavBarTab,
                    onAdd: () {
                      if (canAddNavBarTab) {
                        setState(() {
                          _moreTabs.remove(tab);
                          _barTabs.add(tab);
                        });
                      }
                    },
                  ),
                ),
              ],
            )
          : _navigationGroup(
              context: context,
              title: '可选应用',
              tabs: _moreTabs,
              emptyMessage: '所有应用均已固定到导航。',
              itemBuilder: (tab) => _MoreGridItem(
                tab: tab,
                editing: false,
                onTap: () => widget.onNavigate(tab.tabId),
              ),
            ),
    );
  }

  Widget _buildSettingsSection(BuildContext context) {
    final contentPadding = GzusInsets.cardDense(context);
    return _sectionCard(
      context: context,
      title: '快捷设置',
      icon: Icons.tune,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.onYearChanged != null)
            _settingSelectRow(
              icon: Icons.calendar_today_outlined,
              label: '学年',
              child: DropdownMenu<int>(
                key: ValueKey('more-year-${widget.year}'),
                initialSelection: widget.year,
                enableSearch: false,
                requestFocusOnTap: false,
                onSelected: (value) {
                  if (value != null) widget.onYearChanged?.call(value);
                },
                dropdownMenuEntries: [
                  for (var year = DateTime.now().year;
                      year >= DateTime.now().year - 5;
                      year--)
                    DropdownMenuEntry(value: year, label: '$year'),
                ],
              ),
            ),
          if (widget.onTermChanged != null)
            _settingSelectRow(
              icon: Icons.view_week_outlined,
              label: '学期',
              child: DropdownMenu<int>(
                key: ValueKey('more-term-${widget.term}'),
                initialSelection: widget.term,
                enableSearch: false,
                requestFocusOnTap: false,
                onSelected: (value) {
                  if (value != null) widget.onTermChanged?.call(value);
                },
                dropdownMenuEntries: const [
                  DropdownMenuEntry(value: 1, label: '第1学期'),
                  DropdownMenuEntry(value: 2, label: '第2学期'),
                ],
              ),
            ),
          if (widget.onThemeChanged != null)
            _settingBlock(
              context: context,
              icon: Icons.palette_outlined,
              title: '外观模式',
              child: Center(
                child: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('浅色'),
                      icon: Icon(Icons.light_mode_outlined, size: 18),
                    ),
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('自动'),
                      icon: Icon(Icons.brightness_auto, size: 18),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('深色'),
                      icon: Icon(Icons.dark_mode_outlined, size: 18),
                    ),
                  ],
                  selected: {widget.themeMode},
                  onSelectionChanged: (selection) =>
                      widget.onThemeChanged?.call(selection.first),
                ),
              ),
            ),
          if (widget.onSeedColorChanged != null)
            _settingBlock(
              context: context,
              icon: Icons.color_lens_outlined,
              title: '主题色',
              child: Center(
                child: SeedColorPicker(
                  selectedColor: widget.seedColor,
                  onColorSelected: widget.onSeedColorChanged!,
                ),
              ),
            ),
          if (widget.onAutoHideNavBarChanged != null)
            SwitchListTile(
              contentPadding: contentPadding,
              value: widget.autoHideNavBar,
              onChanged: widget.onAutoHideNavBarChanged,
              secondary: const Icon(Icons.hide_source_outlined),
              title: const Text('自动隐藏底栏'),
              subtitle: const Text('滚动时自动隐藏底部导航栏'),
            ),
          if (widget.onShowBackgroundGuide != null)
            _settingTile(
              key: null,
              icon: Icons.settings_outlined,
              title: '后台',
              subtitle: '设置后台保活和推送',
              titleColor: null,
              iconColor: null,
              onTap: widget.onShowBackgroundGuide!,
            ),
          if (widget.onShowNotificationSettings != null)
            _settingTile(
              key: const ValueKey('notification-settings-tile'),
              icon: Icons.notifications_active_outlined,
              title: '通知设置',
              subtitle: '统一管理教务、课程和水电提醒',
              titleColor: null,
              iconColor: null,
              onTap: widget.onShowNotificationSettings!,
            ),
          if (widget.isAdmin)
            _settingTile(
              key: null,
              icon: Icons.admin_panel_settings_outlined,
              title: '管理后台',
              subtitle: '会话/统计/系统状态',
              titleColor: null,
              iconColor: null,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) =>
                      AdminPage(api: widget.api, isOwner: widget.isOwner),
                ),
              ),
            ),
          _settingTile(
            key: const ValueKey('home-widget-guide-tile'),
            icon: Icons.widgets_outlined,
            title: '桌面组件',
            subtitle: '添加方法、显示内容和刷新说明',
            titleColor: null,
            iconColor: null,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const HomeWidgetGuidePage(),
              ),
            ),
          ),
          _settingTile(
            key: null,
            icon: Icons.info_outline,
            title: '关于',
            subtitle: '应用信息与更新',
            titleColor: null,
            iconColor: null,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => AboutPage(api: widget.api),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildAccountSection(BuildContext context) {
    final onLogout = widget.onLogout;
    if (onLogout == null) return null;
    final error = Theme.of(context).colorScheme.error;
    return _sectionCard(
      context: context,
      title: '账户',
      icon: Icons.person_outline,
      child: _settingTile(
        key: null,
        icon: Icons.logout,
        title: '退出登录',
        subtitle: '',
        titleColor: error,
        iconColor: error,
        onTap: onLogout,
      ),
    );
  }

  Widget _sectionCard({
    required BuildContext context,
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: GzusInsets.card(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: GzusSpacing.s),
                Text(
                  title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: GzusSpacing.m),
            child,
          ],
        ),
      ),
    );
  }

  Widget _navigationGroup({
    required BuildContext context,
    required String title,
    required List<NavTabConfig> tabs,
    required String emptyMessage,
    required Widget Function(NavTabConfig tab) itemBuilder,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.labelLarge),
        const SizedBox(height: GzusSpacing.s),
        if (tabs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: GzusSpacing.m),
            child: Text(emptyMessage, style: theme.textTheme.bodySmall),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = contentGridColumns(
                constraints.maxWidth,
                minTileWidth: 80,
                maxColumns: 5,
              );
              return GridView.count(
                crossAxisCount: columns,
                mainAxisSpacing: GzusSpacing.s,
                crossAxisSpacing: GzusSpacing.s,
                childAspectRatio: columns < 3 ? 0.9 : 1,
                physics: const NeverScrollableScrollPhysics(),
                shrinkWrap: true,
                children: [for (final tab in tabs) itemBuilder(tab)],
              );
            },
          ),
      ],
    );
  }

  Widget _settingSelectRow({
    required IconData icon,
    required String label,
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: GzusSpacing.xs),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: GzusSpacing.s),
          Text(label),
          const Spacer(),
          child,
        ],
      ),
    );
  }

  Widget _settingBlock({
    required BuildContext context,
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    return Padding(
      padding: GzusInsets.cardDense(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: GzusSpacing.s),
              Text(title),
            ],
          ),
          const SizedBox(height: GzusSpacing.s),
          child,
        ],
      ),
    );
  }

  Widget _settingTile({
    required Key? key,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color? titleColor,
    required Color? iconColor,
    required VoidCallback onTap,
  }) {
    return ListTile(
      key: key,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: iconColor),
      title: Text(title, style: TextStyle(color: titleColor)),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class HomeWidgetGuidePage extends StatelessWidget {
  const HomeWidgetGuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isIos = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    final items = [
      const _WidgetGuideItem(
        icon: Icons.schedule,
        title: '下一节课',
        example: '移动应用开发 · 09:00-10:20 · A2-301',
        detail: '适合放在首页第一屏，快速看下一节课、教室和老师。',
      ),
      if (!isIos)
        const _WidgetGuideItem(
          icon: Icons.today,
          title: '今日课表',
          example: '今日 4 节课，按时间列出前几节',
          detail: '适合需要完整确认当天课程顺序时使用。',
        ),
      if (!isIos && !hideEcardOnCurrentPlatform)
        const _WidgetGuideItem(
          icon: Icons.water_drop,
          title: '生活缴费',
          example: '电 9 度 · 冷水 12.3 吨 · 热水 4.6 吨',
          detail: '绑定宿舍后显示水电余额，点击进入生活缴费页。',
        ),
      if (!isIos)
        const _WidgetGuideItem(
          icon: Icons.assignment_turned_in,
          title: '业务进度',
          example: '请假审批 · 辅导员审核 · 70%',
          detail: '适合追踪请假、办事大厅等流程状态。',
        ),
    ];

    return FloatingPageScaffold(
      title: '桌面组件',
      icon: Icons.widgets,
      actions: const [],
      bottom: null,
      floatingActionButton: null,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          Text('添加方法',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          _GuideStep(
            index: 1,
            text: isIos
                ? '在 iPhone 主屏幕长按空白处，点击左上角“+”。'
                : '在 Android 桌面长按空白处，进入“小组件/Widget”。',
          ),
          _GuideStep(
            index: 2,
            text: isIos
                ? '搜索“软帮手”，可添加主屏组件；在锁屏编辑界面也可添加锁屏组件。'
                : '找到软帮手，选择需要的组件拖到桌面。',
          ),
          _GuideStep(
            index: 3,
            text: isIos
                ? '打开 App 登录并刷新首页，组件会同步最新课表。'
                : '打开 App 登录并刷新首页，组件会同步最新课表、水电和业务进度。',
          ),
          const SizedBox(height: 20),
          Text('组件示例',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final item in items)
            Card(
              elevation: 0,
              color: colorScheme.surfaceContainer,
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                leading: Icon(item.icon, color: colorScheme.primary),
                title: Text(item.title),
                subtitle: Text('${item.example}\n${item.detail}'),
                isThreeLine: true,
              ),
            ),
          const SizedBox(height: 10),
          Card(
            elevation: 0,
            color: colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '刷新规则：打开 App、首页数据更新或从组件点击进入 App 后会刷新。若桌面仍显示旧数据，先打开 App 到首页刷新；仍无变化时，检查后台保活设置。',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: colorScheme.onPrimaryContainer),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WidgetGuideItem {
  const _WidgetGuideItem({
    required this.icon,
    required this.title,
    required this.example,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String example;
  final String detail;
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: colorScheme.primaryContainer,
            child: Text('$index',
                style: TextStyle(
                  color: colorScheme.onPrimaryContainer,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                )),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _MoreGridItem extends StatelessWidget {
  const _MoreGridItem({
    required this.tab,
    this.editing = false,
    this.canRemove = false,
    this.canAdd = false,
    this.onTap,
    this.onRemove,
    this.onAdd,
  });

  final NavTabConfig tab;
  final bool editing;
  final bool canRemove;
  final bool canAdd;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inner = Container(
      decoration: BoxDecoration(
        color: gzusSurface(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: gzusBorder(context)),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(tab.icon, size: 28, color: theme.colorScheme.primary),
                  const SizedBox(height: 6),
                  Text(
                    tab.shortLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium,
                  ),
                ],
              ),
            ),
          ),
          if (editing && canRemove)
            Positioned(
              top: -6,
              right: -6,
              child: IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: Colors.white,
                style: const ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(Colors.red),
                  padding: WidgetStatePropertyAll(EdgeInsets.all(2)),
                ),
                onPressed: onRemove,
              ),
            ),
          if (editing && canAdd)
            Positioned(
              top: -6,
              right: -6,
              child: IconButton(
                icon: const Icon(Icons.add, size: 18),
                color: Colors.white,
                style: const ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(Color(0xFF1976D2)),
                  padding: WidgetStatePropertyAll(EdgeInsets.all(2)),
                ),
                onPressed: onAdd,
              ),
            ),
        ],
      ),
    );
    if (editing) return inner;
    return ScaleTap(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: inner,
    );
  }
}

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, required this.api});

  final ApiClient api;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _currentVersion = '0.0.0';
  int _currentBuild = 0;
  bool _checkingUpdate = false;
  bool _hasUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    setState(() {
      _currentVersion = packageInfo.version;
      _currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
    });
    await _silentCheckForUpdate();
  }

  Future<void> _silentCheckForUpdate() async {
    try {
      await update_service.loadLibrary();
      final hasUpdate = await update_service.UpdateService().hasUpdate();
      if (mounted) {
        setState(() => _hasUpdate = hasUpdate);
      }
    } catch (_) {}
  }

  Future<void> _checkForUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      await update_service.loadLibrary();
      await update_service.UpdateService().forceCheckForUpdate();
      await _silentCheckForUpdate();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('检查更新失败，请稍后重试')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _checkingUpdate = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return FloatingPageScaffold(
      title: '关于',
      icon: Icons.info_outline,
      actions: const [],
      bottom: null,
      floatingActionButton: null,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
              child: Column(
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Icon(Icons.school,
                        size: 40, color: colorScheme.primary),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '软帮手',
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text('OneGZUS',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Card(
                elevation: 0,
                color: colorScheme.surfaceContainer,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _InfoRow(label: '版本', value: _currentVersion),
                      _InfoRow(label: '构建号', value: '$_currentBuild'),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Card(
                elevation: 0,
                color: colorScheme.surfaceContainer,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: ListTile(
                  leading: const Icon(Icons.refresh),
                  title: const Text('检查更新'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_hasUpdate)
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                        ),
                      const SizedBox(width: 8),
                      if (_checkingUpdate)
                        const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      if (!_checkingUpdate) const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: _checkForUpdate,
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Card(
                elevation: 0,
                color: colorScheme.surfaceContainer,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: ListTile(
                  leading: const Icon(Icons.extension_outlined),
                  title: const Text('第三方库与开源组件'),
                  subtitle: const Text('查看本程序使用的组件与致谢'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) =>
                          const OpenSourceAcknowledgementsPage(),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(bottom: 32),
                child: Text('© 2026 软帮手 / OneGZUS',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class OpenSourceAcknowledgementsPage extends StatelessWidget {
  const OpenSourceAcknowledgementsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return FloatingPageScaffold(
      title: '第三方库与开源组件',
      icon: Icons.extension_outlined,
      actions: const [],
      bottom: null,
      floatingActionButton: null,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          Card(
            elevation: 0,
            color: colorScheme.surfaceContainer,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AboutSectionTitle(
                    icon: Icons.extension_outlined,
                    title: '第三方库与开源组件',
                  ),
                  SizedBox(height: 8),
                  _AboutLibraryTile(
                    name: 'Flutter / Dart',
                    description: '跨平台应用框架与运行时。',
                  ),
                  _AboutLibraryTile(
                    name: 'http、web_socket_channel',
                    description: '网络请求与实时连接能力。',
                  ),
                  _AboutLibraryTile(
                    name: 'shared_preferences、package_info_plus',
                    description: '本地偏好存储与应用版本信息读取。',
                  ),
                  _AboutLibraryTile(
                    name: 'webview_flutter、url_launcher、share_plus',
                    description: '网页承载、外部链接打开与系统分享。',
                  ),
                  _AboutLibraryTile(
                    name:
                        'flutter_local_notifications、file_picker、image_picker',
                    description: '本地通知、文件选择与图片选择。',
                  ),
                  _AboutLibraryTile(
                    name: 'FastAPI、Uvicorn、SQLAlchemy、Pydantic',
                    description: '服务端 API、数据模型与持久化基础。',
                  ),
                  _AboutLibraryTile(
                    name: 'httpx、asyncpg、aiosqlite、cryptography、Pillow、ddddocr',
                    description: '服务端网络访问、数据库连接、安全与图像处理。',
                  ),
                  _AboutLibraryTile(
                    name: 'Tencent Shiply、desugar_jdk_libs、CocoaPods',
                    description: '热更新、Android 兼容库与 iOS 依赖管理。',
                  ),
                  _AboutLibraryTile(
                    name: 'New School SDK',
                    description: '教务系统数据接口与课表解析能力。',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            color: colorScheme.surfaceContainer,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AboutSectionTitle(
                    icon: Icons.favorite_border,
                    title: '致谢',
                  ),
                  SizedBox(height: 12),
                  Text(
                    '软帮手（OneGZUS）的开发受益于 Flutter、Dart、Python、Android、iOS 生态及各开源项目维护者的持续贡献。感谢上述第三方库、开源组件和相关工具链为本程序提供稳定的基础能力。',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutSectionTitle extends StatelessWidget {
  const _AboutSectionTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _AboutLibraryTile extends StatelessWidget {
  const _AboutLibraryTile({required this.name, required this.description});

  final String name;
  final String description;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            description,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
