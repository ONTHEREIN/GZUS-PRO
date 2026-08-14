import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_flags.dart';

class HomeModuleConfig {
  const HomeModuleConfig(this.id, this.label, this.icon);

  final String id;
  final String label;
  final IconData icon;
}

class HomePreferences {
  static const orderKey = 'home.moduleOrder';
  static const hiddenKey = 'home.hiddenModules';
  static const defaultModules = [
    HomeModuleConfig('nextClass', '下一节课', Icons.watch_later),
    HomeModuleConfig('todayTimeline', '今日时间线', Icons.view_timeline),
    HomeModuleConfig('weekGrid', '周课表', Icons.grid_view),
    HomeModuleConfig('dailyCourses', '今日课程', Icons.format_list_bulleted),
    HomeModuleConfig('grades', '本学期成绩', Icons.school),
    HomeModuleConfig('utilities', '水电余额', Icons.water_drop),
    HomeModuleConfig('progress', '业务进度', Icons.route),
    HomeModuleConfig('notifications', '通知摘要', Icons.notifications_active),
    HomeModuleConfig('attendance', '考勤统计', Icons.fact_check),
    HomeModuleConfig('credits', '学分进度', Icons.workspace_premium),
    HomeModuleConfig('profile', '个人资料', Icons.badge),
    HomeModuleConfig('apps', '常用服务', Icons.apps),
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
