import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_flags.dart';

/// 首页模块在 Bento Grid 中的视觉分量。
///
/// 布局规则遵循桌面组件的信息密度：小卡只呈现一个状态，
/// 中卡提供一项主信息，大卡提供完整上下文。
enum HomeModuleSize {
  /// 大模块：最强的时间敏感信息。
  large,

  /// 中模块：一项主信息和两项辅助信息。
  medium,

  /// 小模块：轻量状态或单一摘要。
  small,
}

class HomeModuleConfig {
  const HomeModuleConfig(
    this.id,
    this.label,
    this.icon, {
    this.size = HomeModuleSize.large,
  });

  final String id;
  final String label;
  final IconData icon;
  final HomeModuleSize size;
}

class HomePreferences {
  static const orderKey = 'home.moduleOrder';
  static const hiddenKey = 'home.hiddenModules';
  static const sizesKey = 'home.moduleSizes';
  static const expandedKey = 'home.moreModulesExpanded';
  static const defaultModules = [
    // 首屏：按 iOS 桌面组件的视觉优先级排列。
    HomeModuleConfig('nextClass', '下一节课', Icons.watch_later,
        size: HomeModuleSize.large),
    HomeModuleConfig('todayTimeline', '今日时间线', Icons.view_timeline,
        size: HomeModuleSize.medium),
    HomeModuleConfig('examCountdown', '考试倒计时', Icons.timer,
        size: HomeModuleSize.small),
    HomeModuleConfig('utilities', '水电余额', Icons.water_drop,
        size: HomeModuleSize.small),
    HomeModuleConfig('grades', '本学期成绩', Icons.school,
        size: HomeModuleSize.medium),
    HomeModuleConfig('progress', '业务进度', Icons.route,
        size: HomeModuleSize.medium),

    // 更多模块：按需展开，避免首次进入首页加载无关信息。
    HomeModuleConfig('weekGrid', '周课表', Icons.grid_view,
        size: HomeModuleSize.large),
    HomeModuleConfig('attendance', '考勤统计', Icons.fact_check,
        size: HomeModuleSize.medium),
    HomeModuleConfig('credits', '学分进度', Icons.workspace_premium,
        size: HomeModuleSize.medium),
    HomeModuleConfig('notifications', '通知摘要', Icons.notifications_active,
        size: HomeModuleSize.medium),
    HomeModuleConfig('dailyCourses', '今日课程', Icons.format_list_bulleted,
        size: HomeModuleSize.medium),

    // small：轻量入口/信息摘要
    HomeModuleConfig('weather', '今日天气', Icons.wb_sunny,
        size: HomeModuleSize.small),
    HomeModuleConfig('profile', '个人资料', Icons.badge,
        size: HomeModuleSize.small),
    HomeModuleConfig('apps', '常用服务', Icons.apps, size: HomeModuleSize.small),
  ];

  static List<HomeModuleConfig> get availableModules =>
      hideEcardOnCurrentPlatform
          ? defaultModules.where((item) => item.id != 'utilities').toList()
          : defaultModules;

  static List<String> get defaultModuleIds =>
      availableModules.map((item) => item.id).toList();

  static Future<List<String>> loadOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(orderKey) ?? const [];
    return _normalizeOrder(saved);
  }

  static Future<Set<String>> loadHidden() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(hiddenKey) ?? const []).toSet();
  }

  static Future<Map<String, HomeModuleSize>> loadSizes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(sizesKey) ?? const [];
    final result = <String, HomeModuleSize>{};
    for (final entry in raw) {
      final parts = entry.split(':');
      if (parts.length != 2) continue;
      final size =
          HomeModuleSize.values.where((v) => v.name == parts[1]).firstOrNull;
      if (size != null) result[parts[0]] = size;
    }
    return result;
  }

  static Future<bool> loadMoreModulesExpanded() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(expandedKey) ?? false;
  }

  static Future<void> saveMoreModulesExpanded(bool expanded) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(expandedKey, expanded);
  }

  static Future<void> save({
    required List<String> order,
    required Set<String> hidden,
    required Map<String, HomeModuleSize> sizes,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(orderKey, _normalizeOrder(order));
    await prefs.setStringList(hiddenKey, hidden.toList());
    await prefs.setStringList(
      sizesKey,
      sizes.entries.map((e) => '${e.key}:${e.value.name}').toList(),
    );
  }

  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(orderKey);
    await prefs.remove(hiddenKey);
    await prefs.remove(sizesKey);
    await prefs.remove(expandedKey);
  }

  static List<String> _normalizeOrder(List<String> value) {
    final validIds = availableModules.map((item) => item.id).toSet();
    final result = <String>[];
    for (final id in value) {
      if (validIds.contains(id) && !result.contains(id)) result.add(id);
    }
    for (final config in availableModules) {
      if (!result.contains(config.id)) result.add(config.id);
    }
    return result;
  }

  static HomeModuleConfig configFor(
    String id, {
    HomeModuleSize? overrideSize,
  }) {
    final base = availableModules.firstWhere((item) => item.id == id);
    if (overrideSize == null || overrideSize == base.size) return base;
    return HomeModuleConfig(
      base.id,
      base.label,
      base.icon,
      size: overrideSize,
    );
  }
}
