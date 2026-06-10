import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'permission_service.dart';
import 'background_service.dart';
import 'web_push_service.dart';

class BackgroundGuidePage extends StatefulWidget {
  const BackgroundGuidePage({super.key, required this.api, this.onComplete});

  final ApiClient api;
  final VoidCallback? onComplete;

  @override
  State<BackgroundGuidePage> createState() => _BackgroundGuidePageState();
}

class _BackgroundGuidePageState extends State<BackgroundGuidePage>
    with WidgetsBindingObserver {
  bool _autoStartGranted = false;
  bool _batteryOptimizationDisabled = false;
  bool _notificationGranted = false;
  bool _exactAlarmGranted = false;
  bool _hideFromRecents = false;
  bool _checking = true;
  bool _webPushSubscribed = false;

  /// 防止 _checkPermissions() 重入
  bool _busy = false;

  /// 首次检查是否已完成，用于决定是否显示加载指示器
  bool _initialCheckDone = false;

  /// 防抖：上次 resume 时间戳，跳过 1 秒内的重复回调
  int _lastResumeMs = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastResumeMs < 1000) return; // 1s 防抖
      _lastResumeMs = now;
      // 后台切回前台时只刷新权限状态，不显示加载指示器
      _refreshPermissions();
    }
  }

  /// 首次加载时的完整权限检查（显示加载指示器）
  Future<void> _checkPermissions() async {
    if (!mounted || _busy) return;
    _busy = true;
    if (!_initialCheckDone) {
      setState(() => _checking = true);
    }
    try {
      await _doCheckPermissions();
    } finally {
      if (mounted && !_initialCheckDone) {
        setState(() => _checking = false);
        _initialCheckDone = true;
      }
      _busy = false;
    }
  }

  /// 静默刷新权限状态（不显示加载指示器，用于 resume/操作后）
  Future<void> _refreshPermissions() async {
    if (!mounted || _busy) return;
    _busy = true;
    try {
      await _doCheckPermissions();
    } finally {
      _busy = false;
    }
  }

  /// 核心权限检查逻辑（不含 UI 状态变更）
  Future<void> _doCheckPermissions() async {
    bool autoStart = false, battery = false, notif = false, alarm = true;
    String permStatus = 'default';
    bool webSub = false;
    try {
      if (kIsWeb) {
        final webPush = WebPushService.instance;
        await webPush.init();
        final results = await Future.wait([
          webPush.getPermissionStatus(),
          webPush.isSubscribed(),
        ]);
        permStatus = results[0] as String;
        webSub = results[1] as bool;
      } else {
        final futures = <Future<bool>>[
          PermissionService.checkAutoStart(),
          PermissionService.checkBatteryOptimization(),
          PermissionService.checkNotificationPermission(),
        ];
        if (Platform.isAndroid) {
          futures.add(PermissionService.checkExactAlarmPermission());
        }
        final results = await Future.wait(futures).timeout(
          const Duration(seconds: 5),
        );
        autoStart = results[0];
        battery = results[1];
        notif = results[2];
        if (Platform.isAndroid && results.length > 3) {
          alarm = results[3];
        }
      }
    } catch (_) {
      // 超时或异常：保持现有状态，不清零
    }
    if (mounted) {
      setState(() {
        if (kIsWeb) {
          _notificationGranted = permStatus == 'granted';
          _webPushSubscribed = webSub;
        } else {
          _autoStartGranted = autoStart;
          _batteryOptimizationDisabled = battery;
          _notificationGranted = notif;
          _exactAlarmGranted = alarm;
        }
      });
    }
  }

  bool get _allGranted => kIsWeb
      ? (_notificationGranted && _webPushSubscribed)
      : (_autoStartGranted &&
          _batteryOptimizationDisabled &&
          _notificationGranted &&
          (!Platform.isAndroid || _exactAlarmGranted));

  Future<void> _openAutoStart() async {
    await PermissionService.openAutoStartSettings();
  }

  Future<void> _openBatteryOptimization() async {
    await PermissionService.openBatteryOptimizationSettings();
  }

  Future<void> _openExactAlarm() async {
    await PermissionService.openExactAlarmSettings();
  }

  Future<void> _requestNotification() async {
    if (_busy) return;
    if (kIsWeb) {
      final webPush = WebPushService.instance;
      await webPush.init();
      final granted = await webPush.requestPermission();
      if (granted) {
        bool subscribed = false;
        try {
          final config = await _fetchWebPushConfig();
          if (config != null && config['enabled'] == true) {
            final publicKey = config['publicKey'] as String?;
            if (publicKey != null && publicKey.isNotEmpty) {
              await webPush.subscribe(
                publicKey,
                apiBaseUrl: widget.api.baseUrl,
                sessionId: widget.api.sessionId ?? '',
              );
              subscribed = true;
            }
          }
        } catch (_) {}
        // 权限已授予，直接更新状态，无需重新走完整的异步检查
        if (mounted) {
          setState(() {
            _notificationGranted = true;
            _webPushSubscribed = subscribed;
          });
        }
        return;
      }
    } else {
      await PermissionService.checkNotificationPermission();
    }
    // 权限未授予（或非 Web 平台），静默刷新状态
    _refreshPermissions();
  }

  Future<Map<String, dynamic>?> _fetchWebPushConfig() async {
    try {
      return await widget.api.getWebPushConfig();
    } catch (_) {
      return null;
    }
  }

  Future<void> _complete() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('background_guide_completed', true);
      if (!kIsWeb) {
        await prefs.setBool('foreground_service_enabled', true);
        await prefs.setBool('hide_from_recents', _hideFromRecents);
        if (_hideFromRecents) {
          await PermissionService.setHideFromRecents(true);
        }
        await BackgroundService.enableForegroundService(
          apiBaseUrl: widget.api.baseUrl,
          sessionId: widget.api.sessionId ?? '',
        );
      }
    } catch (_) {
      // Ignore errors and proceed to navigate away.
    }
    if (!mounted) return;
    if (widget.onComplete != null) {
      widget.onComplete!();
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _skip() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('background_guide_completed', true);
      if (!kIsWeb) {
        await prefs.setBool('foreground_service_enabled', true);
        await BackgroundService.enableForegroundService(
          apiBaseUrl: widget.api.baseUrl,
          sessionId: widget.api.sessionId ?? '',
        );
      }
    } catch (_) {
      // Ignore errors and proceed to navigate away.
    }
    if (!mounted) return;
    if (widget.onComplete != null) {
      widget.onComplete!();
    } else {
      Navigator.of(context).pop();
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
                        color: colorScheme.tertiaryContainer
                            .withValues(alpha: 0.5),
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
                              kIsWeb
                                  ? '为了确保您能及时收到教务通知，请完成以下配置。'
                                  : '为了确保您能及时收到教务通知和课程提醒，请完成以下权限配置。',
                              style: TextStyle(
                                color: colorScheme.onTertiaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (!kIsWeb) ...[
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
                      if (Platform.isAndroid) ...[
                        _PermissionCard(
                          icon: Icons.alarm,
                          title: '精确闹钟',
                          description: '允许按课程时间准点触发上下课提醒',
                          isGranted: _exactAlarmGranted,
                          onAction: _openExactAlarm,
                          actionLabel: '去授权',
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                    _PermissionCard(
                      icon: Icons.notifications,
                      title: '通知权限',
                      description: kIsWeb ? '允许浏览器发送通知提醒' : '允许发送通知提醒',
                      isGranted: _notificationGranted,
                      onAction: _requestNotification,
                      actionLabel: '授予权限',
                    ),
                    if (!kIsWeb && Platform.isAndroid) ...[
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
    final stateColor = isGranted ? colorScheme.secondary : colorScheme.primary;
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
                    color:
                        isGranted ? colorScheme.secondary : colorScheme.error,
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
