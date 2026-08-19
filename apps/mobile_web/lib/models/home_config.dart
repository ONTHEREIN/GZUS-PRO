import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_flags.dart';

/// 首页模块在 Dashboard 中的视觉分量。
enum HomeModuleSize {
  /// 通宽大卡片，单列独占一行，用于最重要/信息密度高的模块。
  featured,

  /// 半宽卡片，一行两个，用于常规数据模块。
  medium,

  /// 紧凑磁贴，一行多个或作为小卡片，用于入口型/轻量模块。
  small,
}

class HomeModuleConfig {
  const HomeModuleConfig(
    this.id,
    this.label,
    this.icon, {
    this.size = HomeModuleSize.medium,
  });

  final String id;
  final String label;
  final IconData icon;
  final HomeModuleSize size;
}

class HomePreferences {
  static const orderKey = 'home.moduleOrder';
  static const hiddenKey = 'home.hiddenModules';
  static const defaultModules = [
    // featured：时间敏感、信息密度高
    HomeModuleConfig('nextClass', '下一节课', Icons.watch_later,
        size: HomeModuleSize.featured),
    HomeModuleConfig('todayTimeline', '今日时间线', Icons.view_timeline,
        size: HomeModuleSize.featured),
    HomeModuleConfig('examCountdown', '考试倒计时', Icons.timer,
        size: HomeModuleSize.featured),
    HomeModuleConfig('weekGrid', '周课表', Icons.grid_view,
        size: HomeModuleSize.featured),

    // medium：常规数据卡片
    HomeModuleConfig('grades', '本学期成绩', Icons.school,
        size: HomeModuleSize.medium),
    HomeModuleConfig('attendance', '考勤统计', Icons.fact_check,
        size: HomeModuleSize.medium),
    HomeModuleConfig('credits', '学分进度', Icons.workspace_premium,
        size: HomeModuleSize.medium),
    HomeModuleConfig('utilities', '水电余额', Icons.water_drop,
        size: HomeModuleSize.medium),
    HomeModuleConfig('progress', '业务进度', Icons.route,
        size: HomeModuleSize.medium),
    HomeModuleConfig('notifications', '通知摘要', Icons.notifications_active,
        size: HomeModuleSize.medium),
    HomeModuleConfig('dailyCourses', '今日课程', Icons.format_list_bulleted,
        size: HomeModuleSize.medium),

    // small：轻量入口/信息
    HomeModuleConfig('weather', '今日天气', Icons.wb_sunny,
        size: HomeModuleSize.small),
    HomeModuleConfig('profile', '个人资料', Icons.badge,
        size: HomeModuleSize.small),
    HomeModuleConfig('apps', '常用服务', Icons.apps,
        size: HomeModuleSize.small),
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

  static Future<void> save({
    required List<String> order,
    required Set<String> hidden,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(orderKey, _normalizeOrder(order));
    await prefs.setStringList(hiddenKey, hidden.toList());
  }

  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(orderKey);
    await prefs.remove(hiddenKey);
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

  static HomeModuleConfig configFor(String id) =>
      availableModules.firstWhere((item) => item.id == id);
}
