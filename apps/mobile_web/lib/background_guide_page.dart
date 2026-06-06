import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'permission_service.dart';
import 'background_service.dart';

class BackgroundGuidePage extends StatefulWidget {
  const BackgroundGuidePage({super.key});

  @override
  State<BackgroundGuidePage> createState() => _BackgroundGuidePageState();
}

class _BackgroundGuidePageState extends State<BackgroundGuidePage> {
  bool _autoStartGranted = false;
  bool _batteryOptimizationDisabled = false;
  bool _notificationGranted = false;
  bool _hideFromRecents = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    if (!mounted) return;
    setState(() => _checking = true);
    final autoStart = await PermissionService.checkAutoStart();
    final battery = await PermissionService.checkBatteryOptimization();
    final notification = await PermissionService.checkNotificationPermission();
    if (!mounted) return;
    setState(() {
      _autoStartGranted = autoStart;
      _batteryOptimizationDisabled = battery;
      _notificationGranted = notification;
      _checking = false;
    });
  }

  bool get _allGranted =>
      _autoStartGranted && _batteryOptimizationDisabled && _notificationGranted;

  Future<void> _openAutoStart() async {
    await PermissionService.openAutoStartSettings();
  }

  Future<void> _openBatteryOptimization() async {
    await PermissionService.openBatteryOptimizationSettings();
  }

  Future<void> _requestNotification() async {
    await PermissionService.checkNotificationPermission();
    await _checkPermissions();
  }

  Future<void> _complete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('background_guide_completed', true);
    await prefs.setBool('hide_from_recents', _hideFromRecents);
    if (_hideFromRecents) {
      await PermissionService.setHideFromRecents(true);
    }
    await BackgroundService.enableForegroundService();
    if (mounted) {
      Navigator.of(context).pushReplacementNamed('/dashboard');
    }
  }

  Future<void> _skip() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('background_guide_completed', true);
    await prefs.setBool('foreground_service_enabled', true);
    await BackgroundService.enableForegroundService();
    if (mounted) {
      Navigator.of(context).pushReplacementNamed('/dashboard');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('优化推送体验'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: _checking
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color:
                            colorScheme.tertiaryContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: colorScheme.onTertiaryContainer,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '为了确保您能及时收到教务通知，请完成以下权限配置。',
                              style: TextStyle(
                                color: colorScheme.onTertiaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    _PermissionCard(
                      icon: Icons.power_settings_new,
                      title: '自启动权限',
                      description: '允许应用在开机时自动启动',
                      isGranted: _autoStartGranted,
                      onAction: _openAutoStart,
                      actionLabel: '打开设置',
                    ),
                    const SizedBox(height: 12),
                    _PermissionCard(
                      icon: Icons.battery_charging_full,
                      title: '电池优化',
                      description: '关闭电池优化以保持后台运行',
                      isGranted: _batteryOptimizationDisabled,
                      onAction: _openBatteryOptimization,
                      actionLabel: '关闭优化',
                    ),
                    const SizedBox(height: 12),
                    _PermissionCard(
                      icon: Icons.notifications,
                      title: '通知权限',
                      description: '允许发送通知提醒',
                      isGranted: _notificationGranted,
                      onAction: _requestNotification,
                      actionLabel: '授予权限',
                    ),
                    if (Platform.isAndroid) ...[
                      const SizedBox(height: 24),
                      SwitchListTile(
                        title: const Text('在最近任务中隐藏应用'),
                        subtitle: const Text('开启后可防止他人看到您正在使用此应用'),
                        value: _hideFromRecents,
                        onChanged: (value) {
                          setState(() => _hideFromRecents = value);
                        },
                      ),
                    ],
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: FilledButton(
                        onPressed: _allGranted ? _complete : null,
                        child: const Text('已完成配置'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: TextButton(
                        onPressed: _skip,
                        child: const Text('暂不配置'),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool isGranted;
  final VoidCallback onAction;
  final String actionLabel;

  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.isGranted,
    required this.onAction,
    required this.actionLabel,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final stateColor =
        isGranted ? colorScheme.secondary : colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: isGranted
                  ? colorScheme.secondaryContainer
                  : colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(
              isGranted ? Icons.check_circle : icon,
              color: stateColor,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isGranted ? '已开启' : '未开启',
                  style: TextStyle(
                    color: isGranted ? colorScheme.secondary : colorScheme.error,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: isGranted ? null : onAction,
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}
