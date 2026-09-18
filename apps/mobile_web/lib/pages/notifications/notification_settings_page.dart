import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api_client.dart';
import '../../live_update_service.dart';
import '../../live_activity_service.dart';
import '../../models/background_notification_status.dart';
import '../home/home_page.dart';
import '../../push_service.dart';
import '../../responsive/breakpoints.dart';
import '../../test_flags.dart';
import '../../widgets/page_panel.dart';

/// 统一管理所有会触发通知的功能入口。
///
/// 后台持续通知的开关和通知类别直接写入服务端；课程、水电提醒保留各自
/// 的详细设置页，但从这里可以直达，避免用户在多个页面里寻找入口。
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({
    super.key,
    required this.api,
    this.onOpenBackgroundGuide,
    required this.onOpenSchedule,
    required this.onOpenEcard,
  });

  final ApiClient api;
  final VoidCallback? onOpenBackgroundGuide;
  final VoidCallback onOpenSchedule;
  final VoidCallback onOpenEcard;

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage>
    with WidgetsBindingObserver {
  BackgroundNotificationStatus? _background;
  EcardSummary? _ecard;
  String? _error;
  bool _loading = true;
  bool _liveActivityEnabled = true;
  String? _savingKey;
  bool? _iosNotificationReady;
  AndroidPromotedNotificationStatus? _androidPromotedNotificationStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
    unawaited(_loadLiveActivityPreference());
    unawaited(_loadIosNotificationStatus());
    unawaited(_loadAndroidPromotedNotificationStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadAndroidPromotedNotificationStatus());
    }
  }

  Future<void> _loadAndroidPromotedNotificationStatus() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final status = await LiveUpdateService.checkPromotedNotificationStatus();
    if (mounted) setState(() => _androidPromotedNotificationStatus = status);
  }

  Future<void> _openAndroidPromotedNotificationSettings() async {
    final opened = await LiveUpdateService.openPromotedNotificationSettings();
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开系统通知设置，请手动进入应用通知设置')),
      );
    }
  }

  Future<void> _loadIosNotificationStatus() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      final ready = await PushService.checkIosPushReady();
      if (mounted) setState(() => _iosNotificationReady = ready);
    } on PlatformException {
      if (mounted) setState(() => _iosNotificationReady = false);
    }
  }

  Future<void> _loadLiveActivityPreference() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _liveActivityEnabled =
          prefs.getBool('live_activities_enabled') ?? true);
    }
  }

  Future<void> _setLiveActivityEnabled(bool value) async {
    if (_savingKey != null) return;
    setState(() {
      _savingKey = 'live_activity';
      _liveActivityEnabled = value;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('live_activities_enabled', value);
      await LiveActivityService.setEnabled(enabled: value);
    } catch (error) {
      if (mounted) {
        setState(() {
          _liveActivityEnabled = !value;
          _error = error.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _savingKey = null);
    }
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object?>([
        widget.api.fetchBackgroundNotificationStatus(),
        if (!hideEcardOnCurrentPlatform)
          widget.api.ecardSummary().then((result) => result.data),
      ]);
      if (!mounted) return;
      setState(() {
        _background = results[0] as BackgroundNotificationStatus?;
        _ecard =
            hideEcardOnCurrentPlatform ? null : results[1] as EcardSummary?;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _setPreference(String key, bool value) async {
    final current = _background;
    if (current == null || !current.enabled || _savingKey != null) return;
    setState(() => _savingKey = key);
    try {
      final next = await widget.api.updateNotificationPreferences(
        noticesEnabled: key == 'notices' ? value : null,
        gradesEnabled: key == 'grades' ? value : null,
        examsEnabled: key == 'exams' ? value : null,
        attendanceEnabled: key == 'attendance' ? value : null,
      );
      if (!mounted) return;
      setState(() => _background = next);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _savingKey = null);
    }
  }

  Future<void> _setEcardEnabled(bool value) async {
    final current = _ecard;
    if (current == null || _savingKey != null) return;
    setState(() => _savingKey = 'ecard');
    try {
      final next = await widget.api.updateEcardReminder(enabled: value);
      if (!mounted) return;
      setState(() => _ecard = next);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _savingKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = context.gzusBreakpoint == GzusBreakpoint.compact
        ? MediaQuery.paddingOf(context).bottom + 104
        : 24.0;
    return PagePanel(
      title: '通知设置',
      icon: Icons.notifications_active,
      expandChild: true,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                // 移动端底部导航栏悬浮在内容之上，额外避让导航栏和系统手势区。
                padding: EdgeInsets.fromLTRB(4, 4, 4, bottomPadding),
                children: [
                  if (_error != null)
                    _ErrorBanner(
                        message: _error!,
                        onClose: () => setState(() => _error = null)),
                  _BackgroundSummary(
                    enabled: _background?.enabled == true,
                    suspended: _background?.suspended == true,
                    suspensionReason: _background?.suspensionReason,
                    nextRetryAt: _background?.nextRetryAt,
                    lastCheckedAt: _background?.lastCheckedAt,
                    onTap: widget.onOpenBackgroundGuide,
                  ),
                  if (_androidPromotedNotificationStatus != null) ...[
                    const SizedBox(height: 14),
                    _AndroidPromotedNotificationTile(
                      status: _androidPromotedNotificationStatus!,
                      onOpenSettings: _openAndroidPromotedNotificationSettings,
                    ),
                  ],
                  const SizedBox(height: 14),
                  _NotificationHistory(api: widget.api),
                  if (_iosNotificationReady != null) ...[
                    const SizedBox(height: 8),
                    ListTile(
                      leading: Icon(
                        _iosNotificationReady!
                            ? Icons.check_circle
                            : Icons.warning,
                      ),
                      title: const Text('iPhone 普通通知通道'),
                      subtitle: Text(_iosNotificationReady!
                          ? '通知权限与 APNs 设备令牌正常'
                          : '请在系统设置开启通知，并重新打开 App 注册 APNs'),
                    ),
                  ],
                  const SizedBox(height: 14),
                  _SettingsSection(
                    title: '课程提醒',
                    children: [
                      _linkTile(
                        title: '上下课提醒',
                        subtitle: _background?.courseRemindersEnabled == true
                            ? '已开启，可调整提前时间'
                            : '在首次引导或课表中开启并设置提前时间',
                        icon: Icons.schedule_outlined,
                        onTap: widget.onOpenSchedule,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _SettingsSection(
                    title: '教务动态',
                    children: [
                      _preferenceTile(
                        keyName: 'notices',
                        title: '新通知',
                        subtitle: '教务处与办事大厅的新增通知',
                        icon: Icons.campaign_outlined,
                        value: _background?.noticesEnabled ?? true,
                      ),
                      _preferenceTile(
                        keyName: 'grades',
                        title: '成绩更新',
                        subtitle: '成绩或绩点发生变化时提醒',
                        icon: Icons.school_outlined,
                        value: _background?.gradesEnabled ?? true,
                      ),
                      _preferenceTile(
                        keyName: 'exams',
                        title: '考试提醒',
                        subtitle: '新考试安排及考前提醒',
                        icon: Icons.event_note_outlined,
                        value: _background?.examsEnabled ?? true,
                      ),
                      _preferenceTile(
                        keyName: 'attendance',
                        title: '考勤异常',
                        subtitle: _attendanceSubtitle(),
                        icon: Icons.fact_check_outlined,
                        value: _background?.attendanceEnabled ?? true,
                      ),
                      if (!kIsWeb &&
                          defaultTargetPlatform == TargetPlatform.iOS)
                        SwitchListTile(
                          secondary: const Icon(Icons.dynamic_feed_outlined),
                          title: const Text('灵动岛活动'),
                          subtitle: const Text('在灵动岛或锁屏显示课程、考试和教务动态摘要'),
                          value: _liveActivityEnabled,
                          onChanged: _savingKey == null
                              ? _setLiveActivityEnabled
                              : null,
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _SettingsSection(
                    title: '课程与生活',
                    children: [
                      if (_ecard != null)
                        SwitchListTile(
                          secondary: const Icon(Icons.water_drop_outlined),
                          title: const Text('水电费低余额提醒'),
                          subtitle: Text(
                              _ecard!.isBound ? '已绑定宿舍，可在一卡通页调整阈值' : '请先绑定宿舍'),
                          value: _ecard!.reminderEnabled,
                          onChanged: _ecard!.isBound && _savingKey == null
                              ? _setEcardEnabled
                              : null,
                        ),
                      if (_ecard != null)
                        _linkTile(
                          title: '水电费提醒详情',
                          subtitle: '提醒时间、项目和低余额阈值',
                          icon: Icons.tune_outlined,
                          onTap: widget.onOpenEcard,
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    kIsWeb
                        ? '系统通知权限与浏览器推送订阅在“后台通知”中配置。'
                        : '系统通知权限在“后台通知”中配置；关闭类别后，后台不会再发送该类提醒。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
    );
  }

  String _attendanceSubtitle() {
    final status = _background;
    if (status == null || !status.enabled) {
      return '开启后台持续通知后，检测迟到、早退、缺勤或请假变化';
    }
    if (status.attendanceLastError != null) {
      return '最近检查失败：${status.attendanceLastError}';
    }
    if (status.attendanceLastCheckedAt == null) {
      return '等待首次检查（首次检查只建立考勤基线）';
    }
    final checked = status.attendanceLastCheckedAt!;
    return '最近检查 ${checked.hour.toString().padLeft(2, '0')}:${checked.minute.toString().padLeft(2, '0')} · 仅新增异常时提醒';
  }

  Widget _preferenceTile({
    required String keyName,
    required String title,
    required String subtitle,
    required IconData icon,
    required bool value,
  }) {
    final enabled = _background?.enabled == true;
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: enabled && _savingKey == null
          ? (next) => _setPreference(keyName, next)
          : null,
    );
  }

  Widget _linkTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _AndroidPromotedNotificationTile extends StatelessWidget {
  const _AndroidPromotedNotificationTile({
    required this.status,
    required this.onOpenSettings,
  });

  final AndroidPromotedNotificationStatus status;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (title, subtitle, icon, color, actionable) = switch (status) {
      AndroidPromotedNotificationStatus.available => (
          'Android 实况通知推广资格：当前可用',
          '符合条件的常驻通知可以显示为系统实况通知',
          Icons.check_circle_outline,
          colors.primary,
          false,
        ),
      AndroidPromotedNotificationStatus.authorizationRequired => (
          'Android 实况通知推广资格：系统未授权',
          '请在系统通知设置中允许实况更新，点击此处打开设置',
          Icons.notifications_paused_outlined,
          colors.error,
          true,
        ),
      AndroidPromotedNotificationStatus.unsupported => (
          'Android 实况通知推广资格：设备不支持',
          '需要 Android 16 或更高版本，并且设备支持实况通知推广',
          Icons.devices_other_outlined,
          colors.onSurfaceVariant,
          false,
        ),
    };
    return Card(
      elevation: 0,
      color: status == AndroidPromotedNotificationStatus.authorizationRequired
          ? colors.errorContainer
          : colors.surfaceContainerLow,
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: actionable ? const Icon(Icons.open_in_new) : null,
        onTap: actionable ? onOpenSettings : null,
      ),
    );
  }
}

class _NotificationHistory extends StatefulWidget {
  const _NotificationHistory({required this.api});

  final ApiClient api;

  @override
  State<_NotificationHistory> createState() => _NotificationHistoryState();
}

class _NotificationHistoryState extends State<_NotificationHistory> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.notificationEvents();
  }

  Future<void> _markRead(Map<String, dynamic> event) async {
    final id = event['id']?.toString();
    if (id == null || id.isEmpty) return;
    await widget.api.markNotificationRead(id);
    if (!mounted) return;
    setState(() {
      event['readAt'] = DateTime.now().toUtc().toIso8601String();
    });
    final type = event['type']?.toString();
    final tab = switch (type) {
      'exam_reminder' => 'exams',
      'ecard_reminder' => 'ecard',
      'new_notice' => 'notices',
      'grade_update' => 'grades',
      'attendance_update' => 'attendance',
      _ => null,
    };
    if (tab != null) {
      if (mounted) Navigator.of(context).pop();
      NotificationOpenBridge.openTab(tab);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsSection(
      title: '提醒记录',
      children: [
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return ListTile(
                leading: const Icon(Icons.error_outline),
                title: const Text('提醒记录加载失败'),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => setState(() {
                    _future = widget.api.notificationEvents();
                  }),
                ),
              );
            }
            final events = snapshot.data ?? const [];
            if (events.isEmpty) {
              return const ListTile(
                leading: Icon(Icons.notifications_none),
                title: Text('暂无动态提醒'),
              );
            }
            return Column(
              children: [
                for (final event in events.take(10))
                  ListTile(
                    leading: Icon(
                      event['readAt'] == null
                          ? Icons.markunread_outlined
                          : Icons.notifications_none,
                    ),
                    title: Text(event['title']?.toString() ?? '提醒'),
                    subtitle: Text(
                      event['body']?.toString() ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: event['readAt'] == null
                        ? const Icon(Icons.chevron_right)
                        : null,
                    onTap:
                        event['readAt'] == null ? () => _markRead(event) : null,
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _BackgroundSummary extends StatelessWidget {
  const _BackgroundSummary({
    required this.enabled,
    required this.suspended,
    required this.suspensionReason,
    required this.nextRetryAt,
    required this.lastCheckedAt,
    required this.onTap,
  });

  final bool enabled;
  final bool suspended;
  final String? suspensionReason;
  final DateTime? nextRetryAt;
  final DateTime? lastCheckedAt;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final retryText = nextRetryAt == null
        ? ''
        : '预计 ${nextRetryAt!.toLocal().hour.toString().padLeft(2, '0')}:${nextRetryAt!.toLocal().minute.toString().padLeft(2, '0')} 自动重试';
    final detail = suspended
        ? '后台监测已暂停：${suspensionReason ?? '校方设备或会话数达到上限'}${retryText.isEmpty ? '' : ' · $retryText'}'
        : enabled
            ? lastCheckedAt == null
                ? '后台持续通知已开启'
                : '后台持续通知已开启 · 最近检查 ${lastCheckedAt!.hour.toString().padLeft(2, '0')}:${lastCheckedAt!.minute.toString().padLeft(2, '0')}'
            : '未开启后台持续通知，类别设置将在开启后生效';
    return Card(
      elevation: 0,
      color: suspended
          ? colors.errorContainer
          : enabled
              ? colors.primaryContainer
              : colors.surfaceContainerLow,
      child: ListTile(
        leading: Icon(suspended
            ? Icons.pause_circle_outline
            : enabled
                ? Icons.notifications_active
                : Icons.notifications_off),
        title: const Text('后台通知'),
        subtitle: Text(detail),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        Card(elevation: 0, child: Column(children: children)),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        leading: const Icon(Icons.error_outline),
        title: const Text('保存失败'),
        subtitle: Text(message),
        trailing: IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
      ),
    );
  }
}
