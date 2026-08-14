import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_flags.dart';

/// 账密登录时禁止导航到的 tab（这些功能依赖 ehall 一站式会话）。
const passwordRestrictedTabs = {
  'notices',
  'business',
  'applications',
  'leave',
};

class NavTabConfig {
  const NavTabConfig({
    required this.tabId,
    required this.icon,
    required this.label,
    this.shortLabel = '',
    this.isFixed = false,
  });

  final String tabId;
  final IconData icon;
  final String label;
  final String shortLabel;
  final bool isFixed;

  static const all = [
    NavTabConfig(
        tabId: 'home',
        icon: Icons.home,
        label: '首页',
        shortLabel: '首页',
        isFixed: true),
    NavTabConfig(
        tabId: 'info',
        icon: Icons.badge,
        label: '个人信息',
        shortLabel: '信息',
        isFixed: true),
    NavTabConfig(
        tabId: 'notices',
        icon: Icons.notifications,
        label: '通知',
        shortLabel: '通知'),
    NavTabConfig(
        tabId: 'business', icon: Icons.apps, label: '业务', shortLabel: '业务'),
    NavTabConfig(
        tabId: 'applications',
        icon: Icons.dashboard_customize,
        label: '应用',
        shortLabel: '应用'),
    NavTabConfig(
        tabId: 'schedule',
        icon: Icons.calendar_month,
        label: '课表',
        shortLabel: '课表',
        isFixed: true),
    NavTabConfig(
        tabId: 'leave',
        icon: Icons.fact_check,
        label: '自动请假',
        shortLabel: '请假'),
    NavTabConfig(
        tabId: 'attendance',
        icon: Icons.schedule,
        label: '考勤',
        shortLabel: '考勤'),
    NavTabConfig(
        tabId: 'exams', icon: Icons.assignment, label: '考试', shortLabel: '考试'),
    NavTabConfig(
        tabId: 'grades', icon: Icons.school, label: '成绩', shortLabel: '成绩'),
    NavTabConfig(
        tabId: 'credits',
        icon: Icons.auto_stories,
        label: '学分',
        shortLabel: '学分'),
    NavTabConfig(
        tabId: 'ecard',
        icon: Icons.water_drop,
        label: '生活缴费',
        shortLabel: '缴费'),
    NavTabConfig(
        tabId: 'ftpUpload',
        icon: Icons.upload_file,
        label: '作业上传',
        shortLabel: '上传'),
  ];

  static List<NavTabConfig> get available => hideEcardOnCurrentPlatform
      ? all.where((tab) => tab.tabId != 'ecard').toList()
      : all;

  static const moreTab = NavTabConfig(
      tabId: 'more',
      icon: Icons.more_horiz,
      label: '更多',
      shortLabel: '更多',
      isFixed: true);

  static List<String> get defaultNavBar {
    final ids = [
      'home',
      'info',
      'applications',
      'schedule',
      'leave',
      'attendance',
      'exams',
      'grades',
      'credits',
      if (!hideEcardOnCurrentPlatform) 'ecard',
      'more',
    ];
    return ids;
  }

  static List<NavTabConfig> get defaultTabs => defaultNavBar
      .map((id) => id == 'more'
          ? moreTab
          : available.firstWhere((tab) => tab.tabId == id))
      .toList();

  Map<String, dynamic> toJson() => {
        'tabId': tabId,
        'icon': icon.codePoint,
        'label': label,
        'shortLabel': shortLabel,
        'isFixed': isFixed,
      };
}

class NavPreferences {
  static const _key = 'nav_bar_config';
  static const _autoHideKey = 'auto_hide_nav_bar';

  static Future<List<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? NavTabConfig.defaultNavBar;
  }

  static Future<void> save(List<String> tabIds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, tabIds);
  }

  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<bool> loadAutoHideNavBar() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoHideKey) ?? true;
  }

  static Future<void> saveAutoHideNavBar(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoHideKey, value);
  }
}
