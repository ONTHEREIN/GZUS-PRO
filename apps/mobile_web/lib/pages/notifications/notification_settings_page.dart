import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../api_client.dart';
import '../../models/background_notification_status.dart';
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

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  BackgroundNotificationStatus? _background;
  EcardSummary? _ecard;
  String? _error;
  bool _loading = true;
  String? _savingKey;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
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
    return PagePanel(
      title: '通知设置',
      icon: Icons.notifications_active,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 24),
                children: [
                  if (_error != null)
                    _ErrorBanner(
                        message: _error!,
                        onClose: () => setState(() => _error = null)),
                  _BackgroundSummary(
                    enabled: _background?.enabled == true,
                    lastCheckedAt: _background?.lastCheckedAt,
                    onTap: widget.onOpenBackgroundGuide,
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
                        subtitle: '迟到、早退、缺勤或请假变化',
                        icon: Icons.fact_check_outlined,
                        value: _background?.attendanceEnabled ?? true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _SettingsSection(
                    title: '课程与生活',
                    children: [
                      _linkTile(
                        title: '上下课提醒',
                        subtitle: _background?.courseRemindersEnabled == true
                            ? '已开启，可调整提前时间'
                            : '在课表工具中开启并设置提前时间',
                        icon: Icons.schedule_outlined,
                        onTap: widget.onOpenSchedule,
                      ),
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

class _BackgroundSummary extends StatelessWidget {
  const _BackgroundSummary({
    required this.enabled,
    required this.lastCheckedAt,
    required this.onTap,
  });

  final bool enabled;
  final DateTime? lastCheckedAt;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final detail = enabled
        ? lastCheckedAt == null
            ? '后台持续通知已开启'
            : '后台持续通知已开启 · 最近检查 ${lastCheckedAt!.hour.toString().padLeft(2, '0')}:${lastCheckedAt!.minute.toString().padLeft(2, '0')}'
        : '未开启后台持续通知，类别设置将在开启后生效';
    return Card(
      elevation: 0,
      color: enabled ? colors.primaryContainer : colors.surfaceContainerLow,
      child: ListTile(
        leading: Icon(
            enabled ? Icons.notifications_active : Icons.notifications_off),
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
