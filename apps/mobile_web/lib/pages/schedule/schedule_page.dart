import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api_client.dart';
import '../../calendar_import.dart';
import '../../course_reminder_sync.dart';
import '../../gzus_design.dart';
import '../../models/schedule_override.dart';
import '../../models/schedule_settings.dart';
import '../../onboarding_preferences.dart';
import '../../schedule_adjustment_sync.dart';
import '../../responsive/spacing.dart';
import '../../schedule_utils.dart';
import '../../background_service.dart' deferred as background_service;
import '../../ics_download.dart' deferred as ics_download;
import '../../reminder_service.dart' deferred as reminder_service;
import '../../responsive/breakpoints.dart';
import '../../widgets/async_panel.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/icon_label.dart';
import '../../widgets/page_panel.dart';
import 'schedule_overrides_page.dart';

class ScheduleOnboardingPage extends StatefulWidget {
  const ScheduleOnboardingPage({
    super.key,
    required this.api,
    required this.studentName,
    required this.onComplete,
  });

  final ApiClient api;
  final String? studentName;
  final VoidCallback onComplete;

  @override
  State<ScheduleOnboardingPage> createState() => _ScheduleOnboardingPageState();
}

class _ScheduleOnboardingPageState extends State<ScheduleOnboardingPage> {
  late int _year;
  late int _term;
  late DateTime _selected;
  bool _loading = false;
  bool _courseRemindersEnabled = false;
  int _courseStartReminderMinutes = 10;
  int _courseEndReminderMinutes = 5;
  bool _reminderSettingsLoading = true;

  @override
  void initState() {
    super.initState();
    final period = onboardingAcademicPeriodOf(DateTime.now());
    _year = period.$1;
    _term = period.$2;
    _selected = defaultFirstWeekStart(_year, _term);
    unawaited(_loadCourseReminderSettings());
  }

  Future<void> _loadCourseReminderSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _courseRemindersEnabled = prefs.getBool(
            schedulePreferenceKey(
              widget.api.namespace,
              'courseRemindersEnabled',
            ),
          ) ??
          false;
      _courseStartReminderMinutes = prefs.getInt(
            schedulePreferenceKey(
              widget.api.namespace,
              'courseStartReminderMinutes',
            ),
          ) ??
          10;
      _courseEndReminderMinutes = prefs.getInt(
            schedulePreferenceKey(
              widget.api.namespace,
              'courseEndReminderMinutes',
            ),
          ) ??
          5;
      _reminderSettingsLoading = false;
    });
  }

  List<int> get _academicYears {
    final currentYear = onboardingAcademicPeriodOf(DateTime.now()).$1;
    return List<int>.generate(13, (index) => currentYear - 6 + index);
  }

  String get _termLabel {
    return '$_year-${_term == 1 ? '第一学期' : '第二学期'}';
  }

  void _changePeriod({required int year, required int term}) {
    setState(() {
      _year = year;
      _term = term;
      _selected = defaultFirstWeekStart(year, term);
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final firstDate = DateTime(now.year - 6, 1, 1);
    final lastDate = DateTime(now.year + 6, 12, 31);
    final initial = _selected.isBefore(firstDate) || _selected.isAfter(lastDate)
        ? now
        : _selected;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: '选择第一周开始日期',
    );
    if (picked == null || !mounted) return;
    // 自动对齐到所选日期所在周的周一
    final monday = mondayOf(picked);
    setState(() => _selected = monday);
    if (monday != picked) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('已自动对齐到所在周的周一：${dateText(monday)}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _complete() async {
    setState(() => _loading = true);
    try {
      // 保存到 SharedPreferences，键名与 DashboardShell 一致且按账号隔离。
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        scheduleAcademicPreferenceKey(
          widget.api.namespace,
          _year,
          _term,
          'firstWeekStart',
        ),
        dateText(_selected),
      );
      await prefs.setInt(
        scheduleAcademicPreferenceKey(
          widget.api.namespace,
          _year,
          _term,
          'week',
        ),
        weekFromDate(_selected, DateTime.now(), clampToTerm: true),
      );
      await prefs.setBool(
        schedulePreferenceKey(
          widget.api.namespace,
          'courseRemindersEnabled',
        ),
        _courseRemindersEnabled,
      );
      await prefs.setInt(
        schedulePreferenceKey(
          widget.api.namespace,
          'courseStartReminderMinutes',
        ),
        _courseStartReminderMinutes,
      );
      await prefs.setInt(
        schedulePreferenceKey(
          widget.api.namespace,
          'courseEndReminderMinutes',
        ),
        _courseEndReminderMinutes,
      );

      // 本地配置已经保存，进入下一步不应再等待云端请求或提醒服务。
      // 网络同步和提醒初始化放到后台，避免首次引导因网络/登录态切换卡在加载中。
      if (!mounted) return;
      widget.onComplete();
      unawaited(_syncScheduleSettingsToCloud());
      if (_courseRemindersEnabled) {
        unawaited(_configureCourseRemindersInBackground());
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('课表或提醒配置失败，请重试：$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _syncScheduleSettingsToCloud() async {
    try {
      await widget.api.saveScheduleSettings(
        firstWeeks: {'$_year-$_term': dateText(_selected)},
      );
    } catch (error) {
      debugPrint('同步开学日期到云端失败: error=${error.runtimeType}');
    }
  }

  Future<void> _configureCourseRemindersInBackground() async {
    try {
      final result = await widget.api.schedule(year: _year, term: _term);
      await configureCourseReminders(
        api: widget.api,
        courses: result.data.items,
        firstWeekStart: _selected,
        enabled: _courseRemindersEnabled,
        beforeStartMinutes: _courseStartReminderMinutes,
        beforeEndMinutes: _courseEndReminderMinutes,
        adjustments: const [],
        overrides: const [],
        nativeReminderSignature: null,
      );
    } catch (error) {
      debugPrint('后台初始化课程提醒失败: error=${error.runtimeType}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final currentWeek =
        weekFromDate(_selected, DateTime.now(), clampToTerm: true);
    final weekdayName = _weekdayName(_selected.weekday);
    return Scaffold(
      appBar: AppBar(
        title: const Text('欢迎使用软帮手'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: _loading || _reminderSettingsLoading ? null : _complete,
            child: const Text('使用默认'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(compact ? 18 : 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 步骤指示器
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '步骤 1 / 4',
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: colorScheme.outlineVariant,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: GzusSpacing.xl),
                  // 顶部欢迎卡片
                  Container(
                    padding: const EdgeInsets.all(GzusSpacing.l),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          colorScheme.primary.withValues(alpha: 0.18),
                          colorScheme.primaryContainer.withValues(alpha: 0.55),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Hero(
                              tag: 'app-logo',
                              child: Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  color: colorScheme.primary,
                                  borderRadius: BorderRadius.circular(18),
                                  boxShadow: [
                                    BoxShadow(
                                      color: colorScheme.primary
                                          .withValues(alpha: 0.25),
                                      blurRadius: 16,
                                      offset: const Offset(0, 6),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(18),
                                  child: Image.asset(
                                    'assets/icon.png',
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.studentName == null
                                        ? '你好！'
                                        : '你好，${widget.studentName}！',
                                    style: GzusTextStyles.pageTitle(context),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '让我们先设置一下课表',
                                    style: textTheme.bodyMedium?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '为了让课表、考试提醒和请假功能更准确，请选择本学期第一周的开始日期。选择任意一天后，系统会自动对齐到该日所在周的周一。',
                          style: textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: GzusSpacing.xl),
                  // 学年学期设置
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.school,
                                size: 18, color: colorScheme.primary),
                            const SizedBox(width: 8),
                            Text(
                              '学年学期',
                              style: textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<int>(
                                key: ValueKey<int>(_year),
                                initialValue: _year,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: '学年',
                                  border: OutlineInputBorder(),
                                ),
                                items: _academicYears
                                    .map(
                                      (year) => DropdownMenuItem<int>(
                                        value: year,
                                        child: Text('$year-${year + 1}学年'),
                                      ),
                                    )
                                    .toList(),
                                onChanged: _loading
                                    ? null
                                    : (year) {
                                        if (year == null) return;
                                        _changePeriod(year: year, term: _term);
                                      },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: DropdownButtonFormField<int>(
                                key: ValueKey<int>(_term),
                                initialValue: _term,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: '学期',
                                  border: OutlineInputBorder(),
                                ),
                                items: const [
                                  DropdownMenuItem<int>(
                                    value: 1,
                                    child: Text('第一学期'),
                                  ),
                                  DropdownMenuItem<int>(
                                    value: 2,
                                    child: Text('第二学期'),
                                  ),
                                ],
                                onChanged: _loading
                                    ? null
                                    : (term) {
                                        if (term == null) return;
                                        _changePeriod(year: _year, term: term);
                                      },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '已预填：$_termLabel',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        )
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // 日期选择卡片
                  Container(
                    padding: const EdgeInsets.all(GzusSpacing.l),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '第一周开始日期',
                          style: GzusTextStyles.cardTitle(context),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '选择第一周中的任意一天，将自动对齐到该周周一',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 14),
                        InkWell(
                          onTap: _pickDate,
                          borderRadius: BorderRadius.circular(14),
                          child: InputDecorator(
                            decoration: InputDecoration(
                              labelText: '已选日期',
                              prefixIcon:
                                  const Icon(Icons.calendar_month, size: 20),
                              suffixIcon:
                                  const Icon(Icons.arrow_drop_down, size: 22),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: Text(
                              '${dateText(_selected)}（$weekdayName）',
                              style:
                                  GzusTextStyles.cardTitle(context)?.copyWith(
                                color: colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _OnboardingInfoChip(
                              icon: Icons.view_week,
                              label: '今天为第$currentWeek周',
                            ),
                            _OnboardingInfoChip(
                              icon: Icons.event,
                              label: '学期：$_termLabel',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: GzusSpacing.xl),
                  _CourseReminderOnboardingCard(
                    enabled: _courseRemindersEnabled,
                    beforeStartMinutes: _courseStartReminderMinutes,
                    beforeEndMinutes: _courseEndReminderMinutes,
                    loading: _loading || _reminderSettingsLoading,
                    onEnabledChanged: (value) {
                      setState(() => _courseRemindersEnabled = value);
                    },
                    onBeforeStartChanged: (value) {
                      setState(() => _courseStartReminderMinutes = value);
                    },
                    onBeforeEndChanged: (value) {
                      setState(() => _courseEndReminderMinutes = value);
                    },
                  ),
                  const SizedBox(height: GzusSpacing.xl),
                  // 操作按钮
                  FilledButton.icon(
                    onPressed:
                        _loading || _reminderSettingsLoading ? null : _complete,
                    icon: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle_outline, size: 20),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '完成，开始使用',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: TextButton(
                      onPressed: _loading || _reminderSettingsLoading
                          ? null
                          : _complete,
                      child: Text(
                        '暂不设置，使用默认日期',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: GzusSpacing.xl),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _weekdayName(int weekday) {
    const names = {
      DateTime.monday: '周一',
      DateTime.tuesday: '周二',
      DateTime.wednesday: '周三',
      DateTime.thursday: '周四',
      DateTime.friday: '周五',
      DateTime.saturday: '周六',
      DateTime.sunday: '周日',
    };
    return names[weekday] ?? '未知';
  }
}

class _CourseReminderOnboardingCard extends StatelessWidget {
  const _CourseReminderOnboardingCard({
    required this.enabled,
    required this.beforeStartMinutes,
    required this.beforeEndMinutes,
    required this.loading,
    required this.onEnabledChanged,
    required this.onBeforeStartChanged,
    required this.onBeforeEndChanged,
  });

  final bool enabled;
  final int beforeStartMinutes;
  final int beforeEndMinutes;
  final bool loading;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<int> onBeforeStartChanged;
  final ValueChanged<int> onBeforeEndChanged;

  @override
  Widget build(BuildContext context) {
    const options = [5, 10, 15, 30, 60];
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.all(GzusSpacing.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.notifications_active_outlined),
              title: const Text('上下课提醒'),
              subtitle: const Text('按课表在上课和下课前提醒你'),
              value: enabled,
              onChanged: loading ? null : onEnabledChanged,
            ),
            if (enabled) ...[
              const SizedBox(height: GzusSpacing.s),
              DropdownButtonFormField<int>(
                initialValue: beforeStartMinutes,
                decoration: const InputDecoration(
                  labelText: '上课前提醒',
                  border: OutlineInputBorder(),
                ),
                items: options
                    .map(
                      (value) => DropdownMenuItem<int>(
                        value: value,
                        child: Text('$value 分钟'),
                      ),
                    )
                    .toList(growable: false),
                onChanged: loading
                    ? null
                    : (value) {
                        if (value != null) onBeforeStartChanged(value);
                      },
              ),
              const SizedBox(height: GzusSpacing.m),
              DropdownButtonFormField<int>(
                initialValue: beforeEndMinutes,
                decoration: const InputDecoration(
                  labelText: '下课前提醒',
                  border: OutlineInputBorder(),
                ),
                items: options
                    .map(
                      (value) => DropdownMenuItem<int>(
                        value: value,
                        child: Text('$value 分钟'),
                      ),
                    )
                    .toList(growable: false),
                onChanged: loading
                    ? null
                    : (value) {
                        if (value != null) onBeforeEndChanged(value);
                      },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OnboardingInfoChip extends StatelessWidget {
  const _OnboardingInfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colorScheme.onSecondaryContainer),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class SchedulePage extends StatefulWidget {
  const SchedulePage({
    super.key,
    required this.api,
    required this.year,
    required this.term,
    required this.currentWeek,
    required this.firstWeekStart,
    required this.autoWeek,
    required this.onFirstWeekChanged,
    required this.onCurrentWeekChanged,
    required this.onAutoWeekChanged,
    this.onSessionExpired,
  });

  final ApiClient api;
  final int year;
  final int term;
  final int currentWeek;
  final DateTime firstWeekStart;
  final bool autoWeek;
  final ValueChanged<DateTime> onFirstWeekChanged;
  final ValueChanged<int> onCurrentWeekChanged;
  final ValueChanged<bool> onAutoWeekChanged;
  final VoidCallback? onSessionExpired;

  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> {
  late Future<ScheduleResult> _scheduleFuture;
  ScheduleViewMode _viewMode = ScheduleViewMode.calendar;
  Offset? _floatingMenuPosition;
  bool showJson = false;
  bool showAllCourses = false;
  bool courseRemindersEnabled = false;
  int courseStartReminderMinutes = 10;
  int courseEndReminderMinutes = 5;
  bool _exporting = false;
  String? manageError;
  String? _reminderSyncError;
  bool _reminderSettingsLoaded = false;
  String? _lastNativeReminderSignature;
  bool showTime = true;
  bool showClassroom = true;
  bool showTeacher = true;

  /// 本地调课条目（本学期），叠加到学校课表上显示。
  List<ScheduleOverride> _overrides = const [];
  List<ScheduleAdjustmentRecord> _adjustments = const [];

  /// 最近一次叠加后的课表，供课程详情「调整此课」回调使用。
  List<ScheduleCourse> _lastItems = const [];

  @override
  void initState() {
    super.initState();
    _scheduleFuture = _loadSchedule();
    _loadReminderSettings();
    _loadOverrides();
    _loadAdjustments();
    _loadViewPreferences();
  }

  @override
  void didUpdateWidget(covariant SchedulePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.year != widget.year ||
        oldWidget.term != widget.term) {
      _scheduleFuture = _loadSchedule();
      _loadOverrides();
      _loadAdjustments();
    }
  }

  Future<void> _loadAdjustments() async {
    try {
      await ScheduleAdjustmentSync.flush(
        api: widget.api,
        year: widget.year,
        term: widget.term,
      );
      final records = await widget.api.fetchScheduleAdjustments(
        year: widget.year,
        term: widget.term,
      );
      if (!mounted) return;
      setState(() => _adjustments = records);
      _scheduleFuture = _loadSchedule();
    } catch (error) {
      debugPrint('同步日期调课失败: $error');
    }
  }

  /// 加载本地调课条目；内容有变化时重新取课表（api 有缓存，不会重复请求学校）。
  Future<void> _loadOverrides() async {
    final list = await ScheduleOverrideStore.load(widget.year, widget.term);
    if (!mounted) return;
    if (_sameOverrides(list, _overrides)) return;
    setState(() => _overrides = list);
    _scheduleFuture = _loadSchedule();
  }

  bool _sameOverrides(List<ScheduleOverride> a, List<ScheduleOverride> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (jsonEncode(a[i].toJson()) != jsonEncode(b[i].toJson())) {
        return false;
      }
    }
    return true;
  }

  Future<ScheduleResult> _loadSchedule({bool forceRefresh = false}) async {
    final result = await widget.api.schedule(
      year: widget.year,
      term: widget.term,
      forceRefresh: forceRefresh,
    );
    final merged = applyScheduleOverrides(result.data.items, _overrides);
    // 课表数据到位后统一配置提醒（内部均有签名守卫，重复调用无开销）；
    // 叠加后的课表用于提醒，停课/替换后的课程不再触发原时间提醒
    unawaited(_applyCourseReminders(merged));
    return ScheduleResult(items: merged, raw: result.data.raw);
  }

  /// 应用课程提醒配置：本地通知（reminder_service）+ 原生后台同步。
  /// 只在课表数据或提醒设置变化时实际执行，避免 build 内重复触发。
  Future<void> _applyCourseReminders(List<ScheduleCourse> courses) async {
    if (!_reminderSettingsLoaded) return;
    try {
      _lastNativeReminderSignature = await configureCourseReminders(
        api: widget.api,
        courses: courses,
        firstWeekStart: widget.firstWeekStart,
        enabled: courseRemindersEnabled,
        beforeStartMinutes: courseStartReminderMinutes,
        beforeEndMinutes: courseEndReminderMinutes,
        adjustments: _adjustments,
        overrides: _overrides,
        nativeReminderSignature: _lastNativeReminderSignature,
      );
      if (mounted) setState(() => _reminderSyncError = null);
    } catch (e) {
      if (mounted) setState(() => _reminderSyncError = e.toString());
      debugPrint('课程提醒配置失败: $e');
    }
  }

  Future<void> _refreshSchedule() async {
    setState(() {
      _scheduleFuture = _loadSchedule(forceRefresh: true);
    });
    await _scheduleFuture;
  }

  Future<void> _adjustDate(
    DateTime sourceDate,
    DateTime targetDate,
    String conflictMode,
  ) async {
    final sourceOccurrences = expandEffectiveSchedule(
      courses: _lastItems,
      firstWeekStart: widget.firstWeekStart,
      adjustments: _adjustments,
      overrides: _overrides,
      startDate: sourceDate,
      endDate: sourceDate,
    );
    if (sourceOccurrences.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('源日期没有可调课程')),
      );
      return;
    }
    final targetOccurrences = expandEffectiveSchedule(
      courses: _lastItems,
      firstWeekStart: widget.firstWeekStart,
      adjustments: _adjustments,
      overrides: _overrides,
      startDate: targetDate,
      endDate: targetDate,
    );
    final sourceKeys = [
      for (final item in sourceOccurrences) item.occurrenceKey
    ];
    final targetKeys = <String>[];
    if (conflictMode == 'replaceConflicts') {
      for (final source in sourceOccurrences) {
        for (final target in targetOccurrences) {
          final aStart = source.course.startSection ?? 0;
          final aEnd = source.course.endSection ?? aStart;
          final bStart = target.course.startSection ?? 0;
          final bEnd = target.course.endSection ?? bStart;
          if (aStart <= bEnd && bStart <= aEnd) {
            targetKeys.add(target.occurrenceKey);
          }
        }
      }
    }
    final adjustment = ScheduleAdjustmentRecord(
      clientId: '${DateTime.now().microsecondsSinceEpoch}',
      year: widget.year,
      term: widget.term,
      sourceDate: DateTime(sourceDate.year, sourceDate.month, sourceDate.day),
      targetDate: DateTime(targetDate.year, targetDate.month, targetDate.day),
      sourceOccurrenceKeys: sourceKeys,
      targetConflictKeys: targetKeys.toSet().toList(),
      conflictMode: conflictMode,
      status: 'active',
      revision: 1,
    );
    setState(() => _adjustments = [..._adjustments, adjustment]);
    // 日期级调整先在本地生效，提醒和原生组件随同一份生效实例立即重排。
    unawaited(
        _scheduleFuture.then((result) => _applyCourseReminders(result.items)));
    unawaited(_syncCalendarAfterAdjustment());
    await ScheduleAdjustmentSync.enqueue(adjustment);
    try {
      final synced = await widget.api.createScheduleAdjustment(adjustment);
      if (!mounted) return;
      setState(() {
        _adjustments = [
          for (final item in _adjustments)
            if (item.clientId == adjustment.clientId) synced else item,
        ];
      });
    } catch (error) {
      debugPrint('日期调课已加入离线队列: $error');
    }
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          '已将 ${dateText(sourceDate)} 调至 ${dateText(targetDate)}'
          '${conflictMode == 'replaceConflicts' ? '，已替换冲突课程' : '，两者并存'}',
        ),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: '撤回',
          onPressed: () => unawaited(_restoreAdjustment(adjustment.clientId)),
        ),
      ),
    );
  }

  Future<void> _restoreAdjustment(String clientId) async {
    final current =
        _adjustments.where((item) => item.clientId == clientId).firstOrNull;
    if (current == null) return;
    final restored = ScheduleAdjustmentRecord(
      clientId: current.clientId,
      year: current.year,
      term: current.term,
      sourceDate: current.sourceDate,
      targetDate: current.targetDate,
      sourceOccurrenceKeys: current.sourceOccurrenceKeys,
      targetConflictKeys: current.targetConflictKeys,
      conflictMode: current.conflictMode,
      status: 'restored',
      revision: current.revision + 1,
      id: current.id,
    );
    setState(() {
      _adjustments = [
        for (final item in _adjustments)
          item.clientId == clientId ? restored : item,
      ];
    });
    unawaited(
        _scheduleFuture.then((result) => _applyCourseReminders(result.items)));
    unawaited(_syncCalendarAfterAdjustment());
    await ScheduleAdjustmentSync.enqueue(restored);
    try {
      await widget.api.restoreScheduleAdjustment(
        clientId: current.clientId,
        expectedRevision: current.revision,
      );
    } catch (error) {
      debugPrint('撤回调课云端同步失败: $error');
    }
  }

  Future<void> _loadViewPreferences() async {
    // 新版课表固定以整周工作台为主视图；旧版保存的悬浮菜单模式不再接管首屏。
    final settings = await widget.api.fetchScheduleSettings();
    if (!mounted) return;
    setState(() {
      _viewMode = ScheduleViewMode.calendar;
      final display = settings?.display;
      if (display != null) {
        showTime = display.showTime;
        showClassroom = display.showClassroom;
        showTeacher = display.showTeacher;
      }
    });
  }

  Future<void> _saveDisplaySettings() async {
    await widget.api.saveScheduleSettings(
      display: ScheduleDisplaySettings(
        showTime: showTime,
        showClassroom: showClassroom,
        showTeacher: showTeacher,
      ),
    );
  }

  void _setViewMode(ScheduleViewMode mode) {
    setState(() {
      _viewMode = mode;
      showAllCourses = mode == ScheduleViewMode.all;
    });
    unawaited(_saveViewMode(mode));
  }

  Future<void> _saveViewMode(ScheduleViewMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('schedule.viewMode', mode.name);
  }

  Future<CalendarTarget?> _chooseCalendarTarget() async {
    final calendars = await CalendarImportService.listCalendars();
    if (calendars.isEmpty) {
      throw const CalendarImportException('没有可写入的系统日历，请先在系统日历中创建日历');
    }
    CalendarTarget? selected;
    if (calendars.length == 1 || !mounted) {
      selected = calendars.first;
    } else {
      selected = await showModalBottomSheet<CalendarTarget>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text('选择目标日历'),
                subtitle: Text('后续同步会记住这个日历'),
              ),
              for (final calendar in calendars)
                ListTile(
                  leading: const Icon(Icons.calendar_month),
                  title: Text(calendar.title),
                  onTap: () => Navigator.pop(sheetContext, calendar),
                ),
            ],
          ),
        ),
      );
    }
    if (selected == null) return null;
    final legacyInOtherCalendars = calendars
        .where((item) => item.identifier != selected!.identifier)
        .fold<int>(0, (sum, item) => sum + item.legacyEventCount);
    return CalendarTarget(
      identifier: selected.identifier,
      title: selected.title,
      legacyEventCount: legacyInOtherCalendars,
    );
  }

  void _setFloatingMenuPosition(Offset position) {
    setState(() => _floatingMenuPosition = position);
  }

  Future<void> _saveFloatingMenuPosition(Offset position) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('schedule.floatingMenu.x', position.dx);
    await prefs.setDouble('schedule.floatingMenu.y', position.dy);
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: _refreshSchedule,
      child: AsyncPanel<ScheduleResult>(
        future: _scheduleFuture,
        initialData:
            widget.api.cachedSchedule(year: widget.year, term: widget.term),
        onSessionExpired: widget.onSessionExpired,
        builder: (result) {
          _lastItems = result.items;
          final today = DateTime.now();
          final todayDate = DateTime(today.year, today.month, today.day);
          final effectiveTodayOccurrences = expandEffectiveSchedule(
            courses: result.items,
            firstWeekStart: widget.firstWeekStart,
            adjustments: _adjustments,
            overrides: _overrides,
            startDate: todayDate,
            endDate: todayDate,
          );
          final weekItems = result.items
              .where((item) =>
                  item.occursInWeek(widget.currentWeek) &&
                  !isHiddenByOverrides(item, _overrides,
                      currentWeek: widget.currentWeek))
              .toList();
          final todayItems = effectiveTodayOccurrences
              .map((item) => item.course)
              .toList()
            ..sort(_compareScheduleCourses);
          final displayItems = _viewMode == ScheduleViewMode.all ||
                  _viewMode == ScheduleViewMode.calendar
              ? result.items
              : weekItems;
          final content = result.items.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(
                      height: 260,
                      child: EmptyState(message: '当前学期暂无课表'),
                    ),
                  ],
                )
              : displayItems.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: 260,
                          child: EmptyState(
                              message: '第${widget.currentWeek}周暂无课程'),
                        ),
                      ],
                    )
                  : ScheduleReadableView(
                      mode: _viewMode,
                      todayItems: todayItems,
                      weekItems: weekItems,
                      allItems: result.items,
                      firstWeekStart: widget.firstWeekStart,
                      currentWeek: widget.currentWeek,
                      overrides: _overrides,
                      adjustments: _adjustments,
                      showTime: showTime,
                      showClassroom: showClassroom,
                      showTeacher: showTeacher,
                      onShowTools: () =>
                          _showScheduleTools(result.prettyJson, result.items),
                      onAdjustCourse: _adjustCourse,
                      onMoveToDay: _moveCourseToDay,
                      onAdjustDate: _adjustDate,
                    );
          final compact = MediaQuery.sizeOf(context).width < 600;
          if (compact) {
            return Stack(
              children: [
                content,
                Positioned.fill(
                  child: _ScheduleFloatingMenu(
                    selected: _viewMode,
                    currentWeek: widget.currentWeek,
                    todayCount: todayItems.length,
                    weekCount: weekItems.length,
                    totalCount: result.items.length,
                    position: _floatingMenuPosition,
                    onViewChanged: _setViewMode,
                    onToolsPressed: () =>
                        _showScheduleTools(result.prettyJson, result.items),
                    onPositionChanged: _setFloatingMenuPosition,
                    onPositionSettled: (position) {
                      _setFloatingMenuPosition(position);
                      unawaited(_saveFloatingMenuPosition(position));
                    },
                  ),
                ),
              ],
            );
          }
          return PagePanel(
            title: '课表',
            icon: Icons.calendar_month,
            expandChild: true,
            child: Column(
              children: [
                Expanded(child: content),
                if (showJson) ...[
                  const SizedBox(height: 10),
                  Flexible(child: JsonPanel(json: result.prettyJson)),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  void _showScheduleTools(String prettyJson, List<ScheduleCourse> items) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, localSetState) {
          final compact = MediaQuery.sizeOf(context).width < 600;
          final colorScheme = Theme.of(context).colorScheme;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: (MediaQuery.sizeOf(context).height * 0.78)
                    .clamp(360.0, 720.0),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 顶部拖拽指示条
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 4),
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // 标题行
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 18 : 24,
                      8,
                      compact ? 18 : 24,
                      0,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: accentFill(context),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.tune,
                              size: 18, color: colorScheme.primary),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '课表工具',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close, size: 20),
                          style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 20, indent: 18, endIndent: 18),
                  // 内容区
                  Flexible(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        compact ? 18 : 24,
                        0,
                        compact ? 18 : 24,
                        20,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 快捷操作区
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              TextButton(
                                onPressed: () {
                                  _setViewMode(showAllCourses
                                      ? ScheduleViewMode.week
                                      : ScheduleViewMode.all);
                                  localSetState(() {});
                                },
                                child: IconLabel(
                                  icon: Icons.visibility,
                                  label: showAllCourses ? '仅本周' : '全部课程',
                                ),
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconLabel(
                                    icon: Icons.notifications_active,
                                    label: _reminderSyncError == null
                                        ? '上下课提醒'
                                        : '提醒同步失败',
                                  ),
                                  Switch(
                                    value: courseRemindersEnabled,
                                    onChanged: (value) {
                                      _setCourseRemindersEnabled(value);
                                      localSetState(() {});
                                    },
                                  ),
                                  IconButton(
                                    tooltip: '提醒设置',
                                    icon: const Icon(Icons.tune, size: 20),
                                    onPressed: () =>
                                        _showCourseReminderSettings(),
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const IconLabel(
                                    icon: Icons.code,
                                    label: 'JSON',
                                  ),
                                  Switch(
                                    value: showJson,
                                    onChanged: (value) {
                                      setState(() => showJson = value);
                                      localSetState(() {});
                                    },
                                  ),
                                ],
                              ),
                              TextButton(
                                onPressed: items.isEmpty || _exporting
                                    ? null
                                    : () =>
                                        unawaited(_exportScheduleIcs(items)),
                                child: IconLabel(
                                  icon: Icons.download,
                                  label: _exporting ? '导出中...' : '导出 ICS',
                                ),
                              ),
                              TextButton(
                                onPressed: items.isEmpty || _exporting
                                    ? null
                                    : () async {
                                        final messenger =
                                            ScaffoldMessenger.maybeOf(
                                                sheetContext);
                                        setState(() => _exporting = true);
                                        localSetState(() {});
                                        try {
                                          if (kIsWeb) {
                                            final ics = generateIcs(
                                              courses: items,
                                              firstWeekStart:
                                                  widget.firstWeekStart,
                                              year: widget.year,
                                              term: widget.term,
                                              adjustments: _adjustments,
                                              overrides: _overrides,
                                            );
                                            final filename =
                                                '课表_${widget.year}_${widget.term}.ics';
                                            await ics_download.loadLibrary();
                                            await ics_download.downloadIcs(
                                                ics, filename);
                                          } else {
                                            final events =
                                                scheduleCalendarEvents(
                                              courses: items,
                                              firstWeekStart:
                                                  widget.firstWeekStart,
                                              year: widget.year,
                                              term: widget.term,
                                              adjustments: _adjustments,
                                              overrides: _overrides,
                                            );
                                            CalendarTarget? target;
                                            var migrateLegacy = false;
                                            if (!kIsWeb &&
                                                defaultTargetPlatform ==
                                                    TargetPlatform.iOS) {
                                              target =
                                                  await _chooseCalendarTarget();
                                              if (!mounted || target == null) {
                                                return;
                                              }
                                              if (target.legacyEventCount > 0 &&
                                                  mounted) {
                                                final pageContext = context;
                                                if (!pageContext.mounted) {
                                                  return;
                                                }
                                                migrateLegacy =
                                                    await showDialog<bool>(
                                                          context: pageContext,
                                                          builder:
                                                              (dialogContext) =>
                                                                  AlertDialog(
                                                            title: const Text(
                                                                '发现旧版课表日程'),
                                                            content: Text(
                                                                '在其他日历发现 ${target!.legacyEventCount} 条旧标记日程。是否迁移去重？'),
                                                            actions: [
                                                              TextButton(
                                                                onPressed: () =>
                                                                    Navigator.pop(
                                                                        dialogContext,
                                                                        false),
                                                                child:
                                                                    const Text(
                                                                        '保留不处理'),
                                                              ),
                                                              FilledButton(
                                                                onPressed: () =>
                                                                    Navigator.pop(
                                                                        dialogContext,
                                                                        true),
                                                                child:
                                                                    const Text(
                                                                        '迁移去重'),
                                                              ),
                                                            ],
                                                          ),
                                                        ) ??
                                                        false;
                                              }
                                            }
                                            final importResult =
                                                await CalendarImportService
                                                    .importEvents(
                                              events,
                                              calendarIdentifier:
                                                  target?.identifier,
                                              migrateLegacy: migrateLegacy,
                                            );
                                            final prefs =
                                                await SharedPreferences
                                                    .getInstance();
                                            await prefs.setBool(
                                                'schedule.calendarSyncEnabled',
                                                true);
                                            if (mounted) {
                                              messenger?.showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                      '日历${importResult.calendarName == null ? '' : '（${importResult.calendarName}）'}：新增 ${importResult.added} 条，更新 ${importResult.updated} 条，删除 ${importResult.deleted} 条，跳过 ${importResult.skipped} 条'),
                                                  duration: const Duration(
                                                      seconds: 2),
                                                ),
                                              );
                                            }
                                          }
                                        } on CalendarImportException catch (e) {
                                          if (mounted) {
                                            unawaited(
                                              _showCalendarImportFailure(
                                                  e, items),
                                            );
                                          }
                                        } finally {
                                          if (mounted) {
                                            setState(() => _exporting = false);
                                          }
                                          try {
                                            localSetState(() {});
                                          } catch (_) {}
                                        }
                                      },
                                child: const IconLabel(
                                  icon: Icons.event_available,
                                  label: '一键导入日历',
                                ),
                              ),
                              TextButton(
                                onPressed: () {
                                  Navigator.pop(sheetContext);
                                  _openOverridesPage(items);
                                },
                                child: IconLabel(
                                  icon: Icons.swap_horiz,
                                  label: _overrides.isEmpty
                                      ? '管理调课'
                                      : '管理调课(${_overrides.length})',
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed: () {
                                  Navigator.pop(sheetContext);
                                  _showAdjustmentHistory();
                                },
                                icon: const Icon(Icons.history, size: 18),
                                label: Text(
                                  _adjustments.isEmpty
                                      ? '调课记录'
                                      : '调课记录(${_adjustments.length})',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '显示字段（课程名始终显示）',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          SwitchListTile.adaptive(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('节次时间'),
                            value: showTime,
                            onChanged: (value) {
                              setState(() => showTime = value);
                              localSetState(() {});
                              unawaited(_saveDisplaySettings());
                            },
                          ),
                          SwitchListTile.adaptive(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('教室'),
                            value: showClassroom,
                            onChanged: (value) {
                              setState(() => showClassroom = value);
                              localSetState(() {});
                              unawaited(_saveDisplaySettings());
                            },
                          ),
                          SwitchListTile.adaptive(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('教师'),
                            value: showTeacher,
                            onChanged: (value) {
                              setState(() => showTeacher = value);
                              localSetState(() {});
                              unawaited(_saveDisplaySettings());
                            },
                          ),
                          const SizedBox(height: 12),
                          ScheduleInlineManage(
                            firstWeekStart: widget.firstWeekStart,
                            currentWeek: widget.currentWeek,
                            autoWeek: widget.autoWeek,
                            error: manageError,
                            onAutoWeekChanged: (value) {
                              widget.onAutoWeekChanged(value);
                              localSetState(() {});
                            },
                            onCurrentWeekChanged: (value) {
                              widget.onCurrentWeekChanged(value);
                              localSetState(() {});
                            },
                            onFirstWeekChanged: (value) {
                              widget.onFirstWeekChanged(value);
                              localSetState(() {});
                            },
                            onUseCurrentWeek: () {
                              widget.onFirstWeekChanged(DateTime.now());
                              localSetState(() {});
                            },
                          ),
                          if (showJson) ...[
                            const SizedBox(height: 12),
                            JsonPanel(json: prettyJson),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 打开本地调课管理页；返回后重新加载叠加结果。
  Future<void> _openOverridesPage(List<ScheduleCourse> items) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ScheduleOverridesPage(
          year: widget.year,
          term: widget.term,
          items: items,
          currentWeek: widget.currentWeek,
          onChanged: () {
            _loadOverrides();
          },
        ),
      ),
    );
    if (mounted) await _loadOverrides();
  }

  /// 查看日期级调课历史，并允许长期还原已生效的记录。
  Future<void> _showAdjustmentHistory() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, localSetState) {
          final records = [..._adjustments]
            ..sort((a, b) => b.targetDate.compareTo(a.targetDate));
          return AlertDialog(
            title: const Text('调课记录'),
            content: SizedBox(
              width: 420,
              child: records.isEmpty
                  ? const Text('本学期暂无日期级调课记录。')
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: records.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, index) {
                        final item = records[index];
                        final active = item.isActive;
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${dateText(item.sourceDate)} → ${dateText(item.targetDate)}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            '${item.conflictMode == 'replaceConflicts' ? '替换冲突课程' : '两者并存'} · ${active ? '已生效' : '已还原'}',
                          ),
                          trailing: active
                              ? TextButton(
                                  onPressed: () async {
                                    await _restoreAdjustment(item.clientId);
                                    if (context.mounted) localSetState(() {});
                                  },
                                  child: const Text('还原'),
                                )
                              : const Icon(Icons.check_circle_outline),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _syncCalendarAfterAdjustment() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('schedule.calendarSyncEnabled') ?? false) ||
        _lastItems.isEmpty) {
      return;
    }
    final events = scheduleCalendarEvents(
      courses: _lastItems,
      firstWeekStart: widget.firstWeekStart,
      year: widget.year,
      term: widget.term,
      adjustments: _adjustments,
      overrides: _overrides,
    );
    try {
      await CalendarImportService.importEvents(events);
    } catch (error) {
      debugPrint('调课后同步系统日历失败: $error');
    }
  }

  Future<void> _exportScheduleIcs(List<ScheduleCourse> items) async {
    if (_exporting || items.isEmpty) return;
    setState(() => _exporting = true);
    try {
      final ics = generateIcs(
        courses: items,
        firstWeekStart: widget.firstWeekStart,
        year: widget.year,
        term: widget.term,
        adjustments: _adjustments,
        overrides: _overrides,
      );
      final filename = '课表_${widget.year}_${widget.term}.ics';
      if (kIsWeb) {
        await ics_download.loadLibrary();
        await ics_download.downloadIcs(ics, filename);
      } else {
        await Share.shareXFiles(
          [
            XFile.fromData(
              Uint8List.fromList(utf8.encode(ics)),
              name: filename,
              mimeType: 'text/calendar',
            ),
          ],
          text: filename,
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _showCalendarImportFailure(
    CalendarImportException error,
    List<ScheduleCourse> items,
  ) async {
    if (!mounted) return;
    final canOpenSettings =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('无法导入系统日历'),
        content: Text('${error.message}\n\n你可以导出 ICS 文件，或前往系统设置检查日历权限。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          if (canOpenSettings)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'settings'),
              child: const Text('打开系统设置'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'ics'),
            child: const Text('导出 ICS'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'ics') {
      await _exportScheduleIcs(items);
    } else if (action == 'settings') {
      final opened = await launchUrl(Uri.parse('app-settings:'));
      if (!opened && mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('无法打开系统设置，请手动进入“设置 > OneGZUS”')),
        );
      }
    }
  }

  /// 课程详情「调整此课/编辑」入口：
  /// 学校课程 → 预填匹配信息打开调课表单；本地课程 → 找到对应条目编辑。
  void _adjustCourse(ScheduleCourse course) {
    if (course.isLocal) {
      final override = _overrideForLocalCourse(course);
      if (override == null) return;
      showScheduleOverrideEditor(
        context,
        items: _lastItems,
        existing: override,
        presetWeek: widget.currentWeek,
        onSave: _saveOverrideFromPage,
      );
    } else {
      showScheduleOverrideEditor(
        context,
        items: _lastItems,
        presetCourse: course,
        presetWeek: widget.currentWeek,
        onSave: _saveOverrideFromPage,
      );
    }
  }

  /// 课程详情「调到另一天」入口：节次/教室/教师不变，只改星期。
  /// 本地课程沿用其条目继续调整；学校课程生成替换条目。
  void _moveCourseToDay(ScheduleCourse course) {
    final existing = course.isLocal ? _overrideForLocalCourse(course) : null;
    showMoveToDaySheet(
      context,
      course: course,
      existing: existing,
      onSave: _saveOverrideFromPage,
    );
  }

  ScheduleOverride? _overrideForLocalCourse(ScheduleCourse course) {
    for (final override in _overrides) {
      final local = override.course;
      if (local != null &&
          local.name == course.name &&
          local.weekday == course.weekday &&
          local.startSection == course.startSection) {
        return override;
      }
    }
    return null;
  }

  /// 表单保存：写入本地存储并重新叠加课表。
  Future<void> _saveOverrideFromPage(ScheduleOverride override) async {
    final list = [..._overrides];
    final index = list.indexWhere((o) => o.id == override.id);
    if (index >= 0) {
      list[index] = override;
    } else {
      list.add(override);
    }
    await ScheduleOverrideStore.save(widget.year, widget.term, list);
    if (!mounted) return;
    setState(() => _overrides = list);
    _scheduleFuture = _loadSchedule();
  }

  Future<void> _loadReminderSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      courseRemindersEnabled = prefs.getBool(
            schedulePreferenceKey(
              widget.api.namespace,
              'courseRemindersEnabled',
            ),
          ) ??
          false;
      courseStartReminderMinutes = prefs.getInt(
            schedulePreferenceKey(
              widget.api.namespace,
              'courseStartReminderMinutes',
            ),
          ) ??
          10;
      courseEndReminderMinutes = prefs.getInt(
            schedulePreferenceKey(
              widget.api.namespace,
              'courseEndReminderMinutes',
            ),
          ) ??
          5;
      _reminderSettingsLoaded = true;
    });
    // 设置加载完成后按最新配置应用一次提醒
    unawaited(_scheduleFuture.then((r) => _applyCourseReminders(r.items)));
  }

  Future<void> _setCourseRemindersEnabled(bool value) async {
    setState(() => courseRemindersEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
      schedulePreferenceKey(widget.api.namespace, 'courseRemindersEnabled'),
      value,
    );
    if (!value) {
      reminder_service.loadLibrary().then((_) {
        reminder_service.ReminderService.cancelCourseReminders();
      });
      unawaited(background_service.loadLibrary().then(
          (_) => background_service.BackgroundService.cancelCourseReminders()));
      unawaited(_scheduleFuture.then((r) => _applyCourseReminders(r.items)));
    } else {
      // 开启时按当前课表立即配置
      unawaited(_scheduleFuture.then((r) => _applyCourseReminders(r.items)));
    }
  }

  Future<void> _showCourseReminderSettings() async {
    var enabled = courseRemindersEnabled;
    var beforeStart = courseStartReminderMinutes;
    var beforeEnd = courseEndReminderMinutes;
    const options = [5, 10, 15, 30, 60];
    final result = await showDialog<(bool, int, int)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('上下课提醒'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('开启提醒'),
                value: enabled,
                onChanged: (value) => setDialogState(() => enabled = value),
              ),
              DropdownButtonFormField<int>(
                initialValue: beforeStart,
                decoration: const InputDecoration(labelText: '上课前提醒'),
                items: options
                    .map((value) => DropdownMenuItem(
                        value: value, child: Text('$value 分钟')))
                    .toList(),
                onChanged: (value) {
                  if (value != null) setDialogState(() => beforeStart = value);
                },
              ),
              DropdownButtonFormField<int>(
                initialValue: beforeEnd,
                decoration: const InputDecoration(labelText: '下课前提醒'),
                items: options
                    .map((value) => DropdownMenuItem(
                        value: value, child: Text('$value 分钟')))
                    .toList(),
                onChanged: (value) {
                  if (value != null) setDialogState(() => beforeEnd = value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(
                  dialogContext, (enabled, beforeStart, beforeEnd)),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    final (newEnabled, newStart, newEnd) = result;
    setState(() {
      courseRemindersEnabled = newEnabled;
      courseStartReminderMinutes = newStart;
      courseEndReminderMinutes = newEnd;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
      schedulePreferenceKey(widget.api.namespace, 'courseRemindersEnabled'),
      newEnabled,
    );
    await prefs.setInt(
      schedulePreferenceKey(widget.api.namespace, 'courseStartReminderMinutes'),
      newStart,
    );
    await prefs.setInt(
      schedulePreferenceKey(widget.api.namespace, 'courseEndReminderMinutes'),
      newEnd,
    );
    unawaited(_scheduleFuture.then((r) => _applyCourseReminders(r.items)));
  }
}

class ScheduleInlineManage extends StatelessWidget {
  const ScheduleInlineManage({
    super.key,
    required this.firstWeekStart,
    required this.currentWeek,
    required this.autoWeek,
    required this.error,
    required this.onAutoWeekChanged,
    required this.onCurrentWeekChanged,
    required this.onFirstWeekChanged,
    required this.onUseCurrentWeek,
  });

  final DateTime firstWeekStart;
  final int currentWeek;
  final bool autoWeek;
  final String? error;
  final ValueChanged<bool> onAutoWeekChanged;
  final ValueChanged<int> onCurrentWeekChanged;
  final ValueChanged<DateTime> onFirstWeekChanged;
  final VoidCallback onUseCurrentWeek;

  Future<void> _pickDate(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final now = DateTime.now();
    final firstDate = DateTime(now.year - 6, 1, 1);
    final lastDate = DateTime(now.year + 6, 12, 31);
    final initial =
        firstWeekStart.isBefore(firstDate) || firstWeekStart.isAfter(lastDate)
            ? now
            : firstWeekStart;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: '选择第一周开始日期',
    );
    if (picked == null) return;
    // 自动对齐到所选日期所在周的周一
    final monday = mondayOf(picked);
    if (monday != picked) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text('已自动对齐到所在周的周一：${dateText(monday)}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    onFirstWeekChanged(monday);
  }

  @override
  Widget build(BuildContext context) {
    final autoWeekValue =
        weekFromDate(firstWeekStart, DateTime.now(), clampToTerm: true);
    final compact = MediaQuery.sizeOf(context).width < 600;
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.all(compact ? 14 : 16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '第一周与周次',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: () => _pickDate(context),
            borderRadius: BorderRadius.circular(12),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: '第一周开始日期',
                prefixIcon: Icon(Icons.calendar_month),
                suffixIcon: Icon(Icons.arrow_drop_down),
              ),
              child: Text(
                dateText(firstWeekStart),
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton(
                onPressed: onUseCurrentWeek,
                child: const IconLabel(
                  icon: Icons.access_time,
                  label: '今天所在周设为第1周',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: IconLabel(
                  icon: Icons.schedule,
                  label: '自动计算：第$autoWeekValue周',
                ),
              ),
              Switch(value: autoWeek, onChanged: onAutoWeekChanged),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: DropdownMenu<int>(
              initialSelection: currentWeek,
              width: compact ? MediaQuery.sizeOf(context).width - 96 : 260,
              enableSearch: false,
              requestFocusOnTap: false,
              onSelected: autoWeek
                  ? null
                  : (value) {
                      if (value != null) onCurrentWeekChanged(value);
                    },
              dropdownMenuEntries: [
                for (var week = 1; week <= 30; week++)
                  DropdownMenuEntry(value: week, label: '第$week周'),
              ],
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, style: TextStyle(color: colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

enum ScheduleViewMode { today, week, calendar, all }

/// 手机端课表的可拖动二级菜单：将低频视图和工具收纳为一个圆点。
class _ScheduleFloatingMenu extends StatefulWidget {
  const _ScheduleFloatingMenu({
    required this.selected,
    required this.currentWeek,
    required this.todayCount,
    required this.weekCount,
    required this.totalCount,
    required this.position,
    required this.onViewChanged,
    required this.onToolsPressed,
    required this.onPositionChanged,
    required this.onPositionSettled,
  });

  final ScheduleViewMode selected;
  final int currentWeek;
  final int todayCount;
  final int weekCount;
  final int totalCount;
  final Offset? position;
  final ValueChanged<ScheduleViewMode> onViewChanged;
  final VoidCallback onToolsPressed;
  final ValueChanged<Offset> onPositionChanged;
  final ValueChanged<Offset> onPositionSettled;

  @override
  State<_ScheduleFloatingMenu> createState() => _ScheduleFloatingMenuState();
}

class _ScheduleFloatingMenuState extends State<_ScheduleFloatingMenu> {
  // 入口贴近拾光的右上角交换图标，不再遮挡课程网格。
  static const _buttonSize = 36.0;
  static const _panelWidth = 244.0;
  static const _panelHeight = 224.0;
  bool _isOpen = false;

  Offset _positionFor(Size size, EdgeInsets viewPadding) {
    final maxX = (size.width - _buttonSize).clamp(0.0, double.infinity);
    final maxY = (size.height - _buttonSize).clamp(0.0, double.infinity);
    final saved = widget.position;
    if (saved == null) return Offset(maxX, viewPadding.top + 4);
    return Offset(maxX * saved.dx, maxY * saved.dy);
  }

  Offset _fractionFor(Offset position, Size size, EdgeInsets viewPadding) {
    final maxX = (size.width - _buttonSize).clamp(0.0, double.infinity);
    final maxY = (size.height - _buttonSize).clamp(0.0, double.infinity);
    return Offset(
      maxX == 0 ? 0 : (position.dx / maxX).clamp(0.0, 1.0),
      maxY == 0 ? 0 : (position.dy / maxY).clamp(0.0, 1.0),
    );
  }

  Offset _clampPosition(Offset position, Size size, EdgeInsets viewPadding) {
    final maxX = (size.width - _buttonSize).clamp(0.0, double.infinity);
    final maxY = (size.height - _buttonSize).clamp(0.0, double.infinity);
    return Offset(
      position.dx.clamp(0.0, maxX).toDouble(),
      position.dy.clamp(0.0, maxY).toDouble(),
    );
  }

  Offset _snapToNearestEdge(
      Offset position, Size size, EdgeInsets viewPadding) {
    final clamped = _clampPosition(position, size, viewPadding);
    final maxX = (size.width - _buttonSize).clamp(0.0, double.infinity);
    final maxY = (size.height - _buttonSize).clamp(0.0, double.infinity);
    final distances = [
      (clamped.dx, 'left'),
      (maxX - clamped.dx, 'right'),
      (clamped.dy, 'top'),
      (maxY - clamped.dy, 'bottom'),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    return switch (distances.first.$2) {
      'left' => Offset(0, clamped.dy),
      'right' => Offset(maxX, clamped.dy),
      'top' => Offset(clamped.dx, 0),
      'bottom' => Offset(clamped.dx, maxY),
      _ => clamped,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final viewPadding = MediaQuery.paddingOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final position = _positionFor(size, viewPadding);
        final panelLeft = position.dx <= size.width / 2
            ? position.dx
            : (position.dx - _panelWidth + _buttonSize)
                .clamp(0.0, size.width - _panelWidth);
        final panelTop = position.dy > size.height / 2
            ? (position.dy - _panelHeight - 8)
                .clamp(8.0, size.height - _panelHeight)
            : (position.dy + _buttonSize + 8)
                .clamp(8.0, size.height - _panelHeight);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            if (_isOpen)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => setState(() => _isOpen = false),
                ),
              ),
            if (_isOpen)
              Positioned(
                left: panelLeft.toDouble(),
                top: panelTop.toDouble(),
                width: _panelWidth,
                child: Material(
                  key: const ValueKey('schedule-floating-menu-panel'),
                  color: colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                  elevation: 8,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '第${widget.currentWeek}周',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w900,
                                  ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '今日 ${widget.todayCount} 节 · 本周 ${widget.weekCount} 节 · 共 ${widget.totalCount} 门',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final entry in _viewItems)
                              ChoiceChip(
                                key: ValueKey('schedule-menu-${entry.$1.name}'),
                                avatar: Icon(entry.$2, size: 16),
                                label: Text(entry.$3),
                                // 「本周」与「周课表」展示同一套周日历；
                                // 旧版本保存的 week 仍让周课表入口保持高亮。
                                selected: widget.selected == entry.$1 ||
                                    (entry.$1 == ScheduleViewMode.calendar &&
                                        widget.selected ==
                                            ScheduleViewMode.week),
                                onSelected: (_) {
                                  widget.onViewChanged(entry.$1);
                                  setState(() => _isOpen = false);
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          key: const ValueKey('schedule-menu-tools'),
                          onPressed: () {
                            setState(() => _isOpen = false);
                            widget.onToolsPressed();
                          },
                          icon: const Icon(Icons.tune, size: 18),
                          label: const Text('课表工具'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Positioned(
              left: position.dx,
              top: position.dy,
              child: Semantics(
                button: true,
                label: '课表视图与工具菜单',
                child: GestureDetector(
                  onPanStart: (_) => setState(() => _isOpen = false),
                  onPanUpdate: (details) {
                    final next = _clampPosition(
                      position + details.delta,
                      size,
                      viewPadding,
                    );
                    widget.onPositionChanged(
                        _fractionFor(next, size, viewPadding));
                  },
                  onPanEnd: (_) {
                    final snapped =
                        _snapToNearestEdge(position, size, viewPadding);
                    widget.onPositionSettled(
                        _fractionFor(snapped, size, viewPadding));
                  },
                  onTap: () => setState(() => _isOpen = !_isOpen),
                  child: Material(
                    key: const ValueKey('schedule-floating-menu'),
                    color: colorScheme.primaryContainer,
                    shape: const CircleBorder(),
                    elevation: 5,
                    child: SizedBox(
                      width: _buttonSize,
                      height: _buttonSize,
                      child: Icon(
                        _isOpen ? Icons.close : Icons.more_horiz,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static const _viewItems = [
    (ScheduleViewMode.today, Icons.today, '今日'),
    (ScheduleViewMode.week, Icons.calendar_today, '本周'),
    (ScheduleViewMode.calendar, Icons.calendar_view_week, '周课表'),
    (ScheduleViewMode.all, Icons.format_list_bulleted, '全部'),
  ];
}

class ScheduleReadableView extends StatelessWidget {
  const ScheduleReadableView({
    super.key,
    required this.mode,
    required this.todayItems,
    required this.weekItems,
    required this.allItems,
    required this.firstWeekStart,
    required this.currentWeek,
    required this.overrides,
    required this.adjustments,
    required this.showTime,
    required this.showClassroom,
    required this.showTeacher,
    this.onAdjustCourse,
    this.onMoveToDay,
    this.onAdjustDate,
    this.onShowTools,
  });

  final ScheduleViewMode mode;
  final List<ScheduleCourse> todayItems;
  final List<ScheduleCourse> weekItems;
  final List<ScheduleCourse> allItems;
  final DateTime firstWeekStart;
  final int currentWeek;
  final List<ScheduleOverride> overrides;
  final List<ScheduleAdjustmentRecord> adjustments;
  final bool showTime;
  final bool showClassroom;
  final bool showTeacher;
  final void Function(ScheduleCourse course)? onAdjustCourse;
  final void Function(ScheduleCourse course)? onMoveToDay;
  final void Function(
          DateTime sourceDate, DateTime targetDate, String conflictMode)?
      onAdjustDate;
  final VoidCallback? onShowTools;

  @override
  Widget build(BuildContext context) {
    switch (mode) {
      case ScheduleViewMode.today:
        return _TodayReadableSchedule(
            items: todayItems,
            onAdjustCourse: onAdjustCourse,
            onMoveToDay: onMoveToDay);
      case ScheduleViewMode.week:
      case ScheduleViewMode.calendar:
        return _CalendarScheduleView(
          items: allItems,
          firstWeekStart: firstWeekStart,
          currentWeek: currentWeek,
          overrides: overrides,
          adjustments: adjustments,
          showTime: showTime,
          showClassroom: showClassroom,
          showTeacher: showTeacher,
          onAdjustCourse: onAdjustCourse,
          onMoveToDay: onMoveToDay,
          onAdjustDate: onAdjustDate,
          onShowTools: onShowTools,
        );
      case ScheduleViewMode.all:
        return _AllReadableSchedule(
            items: allItems,
            onAdjustCourse: onAdjustCourse,
            onMoveToDay: onMoveToDay);
    }
  }
}

class _TodayReadableSchedule extends StatelessWidget {
  const _TodayReadableSchedule({
    required this.items,
    this.onAdjustCourse,
    this.onMoveToDay,
  });

  final List<ScheduleCourse> items;
  final void Function(ScheduleCourse course)? onAdjustCourse;
  final void Function(ScheduleCourse course)? onMoveToDay;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 260, child: EmptyState(message: '今天暂无课程')),
        ],
      );
    }
    final sorted = [...items]..sort(_compareScheduleCourses);
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: sorted.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _ScheduleCourseTile(
        course: sorted[index],
        onAdjustCourse: onAdjustCourse,
        onMoveToDay: onMoveToDay,
      ),
    );
  }
}

class _AllReadableSchedule extends StatelessWidget {
  const _AllReadableSchedule({
    required this.items,
    this.onAdjustCourse,
    this.onMoveToDay,
  });

  final List<ScheduleCourse> items;
  final void Function(ScheduleCourse course)? onAdjustCourse;
  final void Function(ScheduleCourse course)? onMoveToDay;

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<ScheduleCourse>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.name, () => []).add(item);
    }
    final names = grouped.keys.toList()..sort();
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: names.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final name = names[index];
        final courses = grouped[name]!..sort(_compareScheduleCourses);
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _CourseColorMark(name: name),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w900)),
                  ),
                  Text('${courses.length}条',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 10),
              for (final course in courses)
                _CompactScheduleCourseTile(
                  course: course,
                  onAdjustCourse: onAdjustCourse,
                  onMoveToDay: onMoveToDay,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 日历月视图：6 行 × 7 列网格展示当月课程。
/// 顶部可翻月/回本月，并标注当月覆盖的周次范围；
/// 点击日期格子空白处弹出当日课程面板，点击课程块直接看详情。
/// 课程过滤复用周视图逻辑：星期 + 周次（clamp 到 1..30）+ 本地停课。
/// 日历周视图（WakeUp 风格）：一屏横排一周 7 天，横向滑动翻周。
/// 顶部显示当前周日期范围（含月），左右按钮/滑动手势切换周次，
/// 当天格高亮，点击日期弹出当日课程面板，点击课程块直接看详情。
class _CalendarScheduleView extends StatefulWidget {
  const _CalendarScheduleView({
    required this.items,
    required this.firstWeekStart,
    required this.currentWeek,
    required this.overrides,
    required this.adjustments,
    required this.showTime,
    required this.showClassroom,
    required this.showTeacher,
    this.onAdjustCourse,
    this.onMoveToDay,
    this.onAdjustDate,
    this.onShowTools,
  });

  final List<ScheduleCourse> items;
  final DateTime firstWeekStart;
  final int currentWeek;
  final List<ScheduleOverride> overrides;
  final List<ScheduleAdjustmentRecord> adjustments;
  final bool showTime;
  final bool showClassroom;
  final bool showTeacher;
  final void Function(ScheduleCourse course)? onAdjustCourse;
  final void Function(ScheduleCourse course)? onMoveToDay;
  final void Function(
          DateTime sourceDate, DateTime targetDate, String conflictMode)?
      onAdjustDate;
  final VoidCallback? onShowTools;

  @override
  State<_CalendarScheduleView> createState() => _CalendarScheduleViewState();
}

class _CalendarScheduleViewState extends State<_CalendarScheduleView> {
  late final PageController _pageController;
  late int _weekIndex;
  double _zoomScale = 1;
  double _gestureStartZoom = 1;
  final Map<int, Offset> _activePointers = <int, Offset>{};
  double? _initialPinchDistance;

  // 首屏已经是完整七天的最小宽度；再缩小只会制造无意义的右侧留白。
  static const _minZoomScale = 1.0;
  static const _maxZoomScale = 2.4;

  @override
  void initState() {
    super.initState();
    _weekIndex = widget.currentWeek;
    _pageController = PageController(initialPage: widget.currentWeek);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _CalendarScheduleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentWeek != widget.currentWeek &&
        widget.currentWeek >= 1 &&
        widget.currentWeek <= 30) {
      _goToWeek(widget.currentWeek);
    }
  }

  void _goToWeek(int week) {
    final target = week.clamp(1, 30);
    if (target == _weekIndex) return;
    _weekIndex = target;
    _pageController.jumpToPage(target);
  }

  void _setZoom(double value) {
    final next = value.clamp(_minZoomScale, _maxZoomScale).toDouble();
    setState(() => _zoomScale = next);
  }

  void _resetZoom() => _setZoom(1);

  void _onPointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.localPosition;
    _beginPinchIfReady();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_activePointers.containsKey(event.pointer)) return;
    _activePointers[event.pointer] = event.localPosition;
    final initialDistance = _initialPinchDistance;
    if (initialDistance == null || initialDistance <= 0) return;
    final distance = _pinchDistance();
    if (distance == null) return;
    _setZoom(_gestureStartZoom * distance / initialDistance);
  }

  void _onPointerEnd(PointerEvent event) {
    _activePointers.remove(event.pointer);
    _initialPinchDistance = null;
    _beginPinchIfReady();
  }

  void _beginPinchIfReady() {
    final distance = _pinchDistance();
    if (distance == null || distance <= 0) return;
    _gestureStartZoom = _zoomScale;
    _initialPinchDistance = distance;
  }

  double? _pinchDistance() {
    if (_activePointers.length < 2) return null;
    final points = _activePointers.values.take(2).toList(growable: false);
    return (points.first - points.last).distance;
  }

  void _showAdjustDateSheet(DateTime sourceDate) {
    widget.onAdjustDate == null
        ? _showDayCourses(context, sourceDate)
        : _pickAdjustmentTarget(sourceDate);
  }

  Future<void> _pickAdjustmentTarget(DateTime sourceDate) async {
    final first = mondayOf(widget.firstWeekStart);
    final last = first.add(const Duration(days: 209));
    var selected = sourceDate.add(const Duration(days: 1));
    if (selected.isAfter(last)) selected = first;
    final target = await showDatePicker(
      context: context,
      initialDate: selected,
      firstDate: first,
      lastDate: last,
      helpText: '选择调课目标日期',
    );
    if (target == null || !mounted || _sameDay(target, sourceDate)) return;
    final mode = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('目标日有冲突时如何处理？'),
        content: const Text('源日期课程会自动停课；目标日期重叠节次可替换或并存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'cancel'),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, 'coexist'),
            child: const Text('两者并存'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'replaceConflicts'),
            child: const Text('替换冲突课程'),
          ),
        ],
      ),
    );
    if (mode == null || mode == 'cancel' || !mounted) return;
    widget.onAdjustDate!(sourceDate, target, mode);
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// [date] 当天应显示的生效课程实例。
  List<ScheduleCourse> _coursesOn(DateTime date) {
    return [
      for (final occurrence in expandEffectiveSchedule(
        courses: widget.items,
        firstWeekStart: widget.firstWeekStart,
        adjustments: widget.adjustments,
        overrides: widget.overrides,
        startDate: date,
        endDate: date,
      ))
        occurrence.course,
    ]..sort(_compareScheduleCourses);
  }

  /// 第 [week] 周应显示的课程（整周，供节次网格定位）：星期匹配 + 周次匹配
  /// + 本地停课过滤；按节次排序。
  List<ScheduleCourse> _weekCourses(int week) {
    if (week < 1 || week > 30) return const [];
    final seen = <String>{};
    return [
      for (final occurrence in effectiveOccurrencesForWeek(
        courses: widget.items,
        firstWeekStart: widget.firstWeekStart,
        week: week,
        adjustments: widget.adjustments,
        overrides: widget.overrides,
      ))
        // 以具体实例键去重；同一节次的「两者并存」课程不能被课程名合并掉。
        if (seen.add(occurrence.occurrenceKey)) occurrence.course,
    ]..sort(_compareScheduleCourses);
  }

  /// 本周课程的最大结束节次（网格行数），至少 8 节。
  int _maxSectionFor(List<ScheduleCourse> courses) {
    var max = 8;
    for (final course in courses) {
      final end = course.endSection ?? course.startSection ?? 0;
      if (end > max) max = end;
    }
    return max.clamp(8, 16);
  }

  void _showDayCourses(BuildContext context, DateTime date) {
    final theme = Theme.of(context);
    final courses = _coursesOn(date);
    final week = weekFromDate(widget.firstWeekStart, date);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.calendar_month,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${date.month}月${date.day}日 '
                      '${_scheduleWeekdayText(date.weekday)}'
                      '${week >= 1 && week <= 30 ? ' · 第$week周' : ''}',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('共${courses.length}节课', style: theme.textTheme.bodySmall),
              const SizedBox(height: 10),
              if (courses.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: Text('当日无课', style: theme.textTheme.bodyMedium),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: courses.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 2),
                    itemBuilder: (context, index) => _CompactScheduleCourseTile(
                      course: courses[index],
                      onAdjustCourse: widget.onAdjustCourse,
                      onMoveToDay: widget.onMoveToDay,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 第 [week] 周的周一（从学期第一周周一顺延）。
  DateTime _mondayOfWeek(int week) =>
      widget.firstWeekStart.add(Duration(days: (week - 1) * 7));

  /// 第 [week] 周的完整 7 天。
  List<DateTime> _daysOfWeek(int week) => [
        for (var i = 0; i < 7; i++) _mondayOfWeek(week).add(Duration(days: i)),
      ];

  String _weekTitle(int week) {
    if (week < 1 || week > 30) return '该周不在本学期';
    return '第$week周';
  }

  /// 某周的短日期范围（周次选择器格子里用），如「8/31-9/6」。
  String _weekShortRange(int week) {
    final start = _mondayOfWeek(week);
    final end = start.add(const Duration(days: 6));
    return '${start.month}/${start.day}-${end.month}/${end.day}';
  }

  double _rowHeightFor(
    List<ScheduleCourse> courses,
    double dayWidth,
    bool compact,
  ) {
    final baseHeight = compact ? 76.0 : 70.0;
    final charactersPerLine = ((dayWidth - 10) / 14).floor().clamp(1, 20);
    var requiredHeight = baseHeight;
    for (final course in courses) {
      final start = course.startSection;
      if (start == null) continue;
      final end = course.endSection ?? start;
      final span = end >= start ? end - start + 1 : 1;
      final titleLines = (course.name.runes.length / charactersPerLine).ceil();
      final hasClassroom = _cleanScheduleText(course.classroom) != null;
      final contentHeight = 26 + titleLines * 18 + (hasClassroom ? 15 : 0);
      final requiredForSpan = contentHeight / span;
      if (requiredForSpan > requiredHeight) requiredHeight = requiredForSpan;
    }
    return requiredHeight;
  }

  /// 点击顶部周次标题弹出的底部周次选择器：
  /// 1-30 周快速跳转，标记当前日期所在周（「本周」）。
  void _showWeekPicker(BuildContext context) {
    final theme = Theme.of(context);
    final current = widget.currentWeek;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '跳转周次',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _goToWeek(current);
                    },
                    child: const Text('回到本周'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: GridView.count(
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  crossAxisCount: 5,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.55,
                  children: [
                    for (var week = 1; week <= 30; week++)
                      _WeekPickerCell(
                        week: week,
                        rangeText: _weekShortRange(week),
                        isCurrentWeek: week == current,
                        isSelected: week == _weekIndex,
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _goToWeek(week);
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final today = DateUtils.dateOnly(DateTime.now());

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = MediaQuery.sizeOf(context).width < 600;
        final topControlsHeight = compact ? 62.0 : 66.0;
        const minPageHeight = 240.0;
        final pageViewHeight = constraints.hasBoundedHeight
            ? (constraints.maxHeight - topControlsHeight - 4)
                .clamp(minPageHeight, double.infinity)
                .toDouble()
            : 600.0;
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: compact ? 56 : 60,
                child: Center(
                  child: InkWell(
                    onTap: () => _showWeekPicker(context),
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _weekTitle(_weekIndex),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.4,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Icon(Icons.expand_more,
                              size: 18, color: colorScheme.onSurfaceVariant),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                key: const ValueKey('schedule-calendar-view'),
                height: pageViewHeight,
                child: PageView.builder(
                  controller: _pageController,
                  onPageChanged: (page) => setState(() => _weekIndex = page),
                  itemCount: 32,
                  itemBuilder: (context, index) {
                    final week = index;
                    final days = _daysOfWeek(week);
                    final inTerm = week >= 1 && week <= 30;
                    final weekItems =
                        inTerm ? _weekCourses(week) : const <ScheduleCourse>[];
                    // 参照拾光的排版：节次轴只保留阅读时间所需的宽度，
                    // 剩余空间完整分给 7 个等宽日期列，避免右侧出现小缝。
                    final baseTimeColWidth = compact ? 36.0 : 46.0;
                    final availableGridWidth = constraints.maxWidth;
                    final baseDayWidth =
                        (availableGridWidth - baseTimeColWidth) / 7;
                    final baseRowHeight =
                        _rowHeightFor(weekItems, baseDayWidth, compact)
                            .clamp(34.0, 74.0)
                            .toDouble();
                    // 缩放直接参与列宽、行高和课程块排版；不再缩放整张
                    // 画布，因此「按宽度适配」始终铺满视口，不会留下右侧空白。
                    final timeColWidth = baseTimeColWidth * _zoomScale;
                    final dayWidth = baseDayWidth * _zoomScale;
                    final gridWidth = availableGridWidth * _zoomScale;
                    final rowHeight = baseRowHeight * _zoomScale;
                    final maxSection = _maxSectionFor(weekItems);
                    if (!inTerm) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: _OutOfTermCell(week: week),
                      );
                    }
                    return Listener(
                      onPointerDown: _onPointerDown,
                      onPointerMove: _onPointerMove,
                      onPointerUp: _onPointerEnd,
                      onPointerCancel: _onPointerEnd,
                      child: GestureDetector(
                        onDoubleTap: _resetZoom,
                        child: ClipRect(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            physics: gridWidth > constraints.maxWidth
                                ? const ClampingScrollPhysics()
                                : const NeverScrollableScrollPhysics(),
                            child: SizedBox(
                              key: const ValueKey('schedule-week-grid'),
                              width: gridWidth,
                              child: SingleChildScrollView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // 星期 + 日期表头（左侧时间列宽占位，与网格列对齐）。
                                    Row(
                                      children: [
                                        SizedBox(width: timeColWidth),
                                        for (final day in days)
                                          SizedBox(
                                            width: dayWidth,
                                            child: GestureDetector(
                                              onLongPress: () =>
                                                  _showAdjustDateSheet(day),
                                              child: Column(
                                                children: [
                                                  Text(
                                                    _scheduleWeekdayText(
                                                        day.weekday),
                                                    style: theme
                                                        .textTheme.bodyMedium
                                                        ?.copyWith(
                                                            fontWeight:
                                                                FontWeight
                                                                    .w800),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Container(
                                                    width: 36,
                                                    height: 36,
                                                    alignment: Alignment.center,
                                                    decoration: day == today
                                                        ? BoxDecoration(
                                                            color: colorScheme
                                                                .primary,
                                                            shape:
                                                                BoxShape.circle)
                                                        : null,
                                                    child: Text(
                                                      '${day.day}',
                                                      style: TextStyle(
                                                        fontSize: 15,
                                                        fontWeight: day == today
                                                            ? FontWeight.w800
                                                            : FontWeight.w600,
                                                        color: day == today
                                                            ? colorScheme
                                                                .onPrimary
                                                            : colorScheme
                                                                .onSurface,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    SizedBox(
                                      height: maxSection * rowHeight,
                                      child: _WeekTimeGrid(
                                        days: days,
                                        items: weekItems,
                                        maxSection: maxSection,
                                        timeColWidth: timeColWidth,
                                        dayWidth: dayWidth,
                                        gridWidth: gridWidth,
                                        rowHeight: rowHeight,
                                        today: today,
                                        onEmptyDayTap: (day) =>
                                            _showDayCourses(context, day),
                                        onAdjustCourse: widget.onAdjustCourse,
                                        onMoveToDay: widget.onMoveToDay,
                                        showTime: widget.showTime,
                                        showClassroom: widget.showClassroom,
                                        showTeacher: widget.showTeacher,
                                        contentScale: _zoomScale,
                                      ),
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
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 周次选择器中的单个周格：本周用主题色描边 + 「本周」标记。
class _WeekPickerCell extends StatelessWidget {
  const _WeekPickerCell({
    required this.week,
    required this.rangeText,
    required this.isCurrentWeek,
    required this.isSelected,
    required this.onTap,
  });

  final int week;
  final String rangeText;
  final bool isCurrentWeek;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final selected = isSelected || isCurrentWeek;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primaryContainer.withValues(alpha: 0.55)
              : colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isCurrentWeek
                ? colorScheme.primary
                : colorScheme.outlineVariant,
            width: isCurrentWeek ? 1.4 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '第$week周',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: selected
                        ? colorScheme.onPrimaryContainer
                        : colorScheme.onSurface,
                  ),
                ),
                if (isCurrentWeek) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      '本周',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(
              rangeText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: selected
                    ? colorScheme.onPrimaryContainer.withValues(alpha: 0.75)
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 学期外周页（第 0 / 31 周边界）：整屏占位提示。
class _OutOfTermCell extends StatelessWidget {
  const _OutOfTermCell({required this.week});

  final int week;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant, width: 1),
      ),
      child: Center(
        child: Text(
          week < 1 ? '假期' : '已结课',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// 拾光风格周网格：左侧节次时间轴 + 7 天列，水平线分隔节次行，
/// 课程块按开始节次纵向定位（块高 = 节数跨度），点击空白处弹当日课程面板。
class _WeekTimeGrid extends StatelessWidget {
  const _WeekTimeGrid({
    required this.days,
    required this.items,
    required this.maxSection,
    required this.timeColWidth,
    required this.dayWidth,
    required this.gridWidth,
    required this.rowHeight,
    required this.today,
    required this.showTime,
    required this.showClassroom,
    required this.showTeacher,
    required this.contentScale,
    required this.onEmptyDayTap,
    this.onAdjustCourse,
    this.onMoveToDay,
  });

  final List<DateTime> days;
  final List<ScheduleCourse> items;
  final int maxSection;
  final double timeColWidth;
  final double dayWidth;
  final double gridWidth;
  final double rowHeight;
  final DateTime today;
  final bool showTime;
  final bool showClassroom;
  final bool showTeacher;
  final double contentScale;
  final void Function(DateTime day) onEmptyDayTap;
  final void Function(ScheduleCourse course)? onAdjustCourse;
  final void Function(ScheduleCourse course)? onMoveToDay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final lineColor = colorScheme.outlineVariant.withValues(alpha: 0.45);
    final totalHeight = maxSection * rowHeight;

    return Stack(
      children: [
        // 7 天列背景（今天高亮），点击空白处弹当日课程面板
        for (var day = 0; day < 7; day++)
          Positioned(
            left: timeColWidth + dayWidth * day,
            top: 0,
            width: dayWidth,
            height: totalHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onEmptyDayTap(days[day]),
              child: Container(
                decoration: BoxDecoration(
                  color: days[day] == today
                      ? colorScheme.primaryContainer.withValues(alpha: 0.16)
                      : colorScheme.surface,
                  border: Border(
                    left: BorderSide(color: lineColor),
                    right: BorderSide(color: lineColor),
                  ),
                ),
              ),
            ),
          ),
        // 水平分隔线（节次行边界）
        for (var row = 0; row <= maxSection; row++)
          Positioned(
            left: 0,
            top: row * rowHeight,
            width: gridWidth,
            height: 1,
            child: Container(color: lineColor),
          ),
        // 左侧节次时间轴
        for (var row = 0; row < maxSection; row++)
          Positioned(
            left: 0,
            top: row * rowHeight,
            width: timeColWidth,
            height: rowHeight,
            child: Center(
              child: row < scheduleTimes.length
                  ? FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '${row + 1}',
                            style: TextStyle(
                              fontSize: (16 * contentScale).clamp(13.0, 22.0),
                              fontWeight: FontWeight.w700,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            scheduleTimes[row].$1,
                            style: TextStyle(
                              fontSize: (8.5 * contentScale).clamp(8.0, 13.0),
                              fontWeight: FontWeight.w500,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            scheduleTimes[row].$2,
                            style: TextStyle(
                              fontSize: (8.5 * contentScale).clamp(8.0, 13.0),
                              fontWeight: FontWeight.w500,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        // 课程块（按节次定位，块高 = 节数跨度）
        for (final course in items)
          if (course.weekday != null && course.startSection != null)
            _buildCourseBlock(context, course, dayWidth),
      ],
    );
  }

  Widget _buildCourseBlock(
      BuildContext context, ScheduleCourse course, double colWidth) {
    final weekday = course.weekday!;
    final start = course.startSection!;
    final end = course.endSection ?? start;
    final span = end >= start ? end - start + 1 : 1;
    const gap = 2.0;
    return Positioned(
      left: timeColWidth + (weekday - 1) * colWidth + gap,
      top: (start - 1) * rowHeight + gap,
      width: colWidth - gap * 2,
      height: span * rowHeight - gap * 2,
      child: _CalendarCourseChip(
        course: course,
        showTime: showTime,
        showClassroom: showClassroom,
        showTeacher: showTeacher,
        contentScale: contentScale,
        onTap: () => _showReadableScheduleDetails(
            context, course, onAdjustCourse, onMoveToDay),
      ),
    );
  }
}

/// 周网格中的课程块（拾光风格）：浅色调色板、深色文字和紧凑圆角。
class _CalendarCourseChip extends StatelessWidget {
  const _CalendarCourseChip({
    required this.course,
    required this.onTap,
    required this.showTime,
    required this.showClassroom,
    required this.showTeacher,
    required this.contentScale,
  });

  final ScheduleCourse course;
  final VoidCallback onTap;
  final bool showTime;
  final bool showClassroom;
  final bool showTeacher;
  final double contentScale;

  @override
  Widget build(BuildContext context) {
    final classroom = _cleanScheduleText(course.classroom);
    final startSection = course.startSection;
    final startTime = startSection != null &&
            startSection >= 1 &&
            startSection <= scheduleTimes.length
        ? scheduleTimes[startSection - 1].$1
        : '时间待定';
    return GestureDetector(
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final paddingX = (4 * contentScale).clamp(2.0, 8.0);
          final paddingY = (3 * contentScale).clamp(2.0, 7.0);
          final titleFontSize = (14 * contentScale).clamp(14.0, 20.0);
          final detailFontSize = (11 * contentScale).clamp(11.0, 16.0);
          final teacherFontSize = (10 * contentScale).clamp(8.0, 16.0);
          final contentHeight = constraints.maxHeight - paddingY * 2;
          // 课程名永远显示；用户开启的可选字段仅在格子确有空间时显示。
          final showTimeInCell =
              showTime && contentHeight >= titleFontSize * 2.4 + detailFontSize;
          final showClassroomInCell = showClassroom &&
              classroom != null &&
              contentHeight >= titleFontSize * 2.8 + detailFontSize;
          final teacher = _cleanScheduleText(course.teacher);
          final showTeacherInCell = showTeacher &&
              teacher != null &&
              contentHeight >=
                  titleFontSize * 3.3 + detailFontSize + teacherFontSize;
          final reservedHeight =
              (showTimeInCell ? detailFontSize * 1.2 + 2 : 0) +
                  (showClassroomInCell ? detailFontSize * 1.2 + 1 : 0) +
                  (showTeacherInCell ? teacherFontSize * 1.1 : 0);
          final titleLines =
              ((contentHeight - reservedHeight) / (titleFontSize * 1.2))
                  .floor()
                  .clamp(1, 8)
                  .toInt();
          return Container(
            padding:
                EdgeInsets.symmetric(horizontal: paddingX, vertical: paddingY),
            decoration: BoxDecoration(
              color: _scheduleCourseColor(course.name),
              borderRadius:
                  BorderRadius.circular((5 * contentScale).clamp(4.0, 9.0)),
              border: course.isLocal
                  ? Border.all(color: const Color(0xFF1976D2), width: 1.4)
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showTimeInCell) ...[
                  Text(
                    startTime,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.72),
                      fontSize: detailFontSize,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                Expanded(
                  child: Text(
                    course.name,
                    maxLines: titleLines,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.88),
                      fontSize: titleFontSize,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (showClassroomInCell) ...[
                  const SizedBox(height: 1),
                  Text(
                    classroom,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.72),
                      fontSize: detailFontSize,
                      height: 1.2,
                    ),
                  ),
                ],
                if (showTeacherInCell)
                  Text(
                    teacher,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.72),
                      fontSize: teacherFontSize,
                      height: 1.1,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ScheduleCourseTile extends StatelessWidget {
  const _ScheduleCourseTile({
    required this.course,
    this.onAdjustCourse,
    this.onMoveToDay,
  });

  final ScheduleCourse course;
  final void Function(ScheduleCourse course)? onAdjustCourse;
  final void Function(ScheduleCourse course)? onMoveToDay;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _showReadableScheduleDetails(
            context, course, onAdjustCourse, onMoveToDay),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: course.isLocal
                  ? Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.55)
                  : Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 5,
                height: 76,
                decoration: BoxDecoration(
                  color: _scheduleCourseColor(course.name),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 82,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_scheduleTimeText(course),
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    Text(_scheduleSectionText(course),
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (course.isLocal) ...[
                          const _LocalCourseBadge(),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(course.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w900)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 5,
                      children: [
                        _ScheduleMeta(
                            icon: Icons.room,
                            text:
                                _cleanScheduleText(course.classroom) ?? '地点待定'),
                        _ScheduleMeta(
                            icon: Icons.person,
                            text: _cleanScheduleText(course.teacher) ?? '教师待定'),
                        if (_cleanScheduleText(course.weeks) != null)
                          _ScheduleMeta(
                              icon: Icons.date_range,
                              text: _cleanScheduleText(course.weeks)!),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactScheduleCourseTile extends StatelessWidget {
  const _CompactScheduleCourseTile({
    required this.course,
    this.onAdjustCourse,
    this.onMoveToDay,
  });

  final ScheduleCourse course;
  final void Function(ScheduleCourse course)? onAdjustCourse;
  final void Function(ScheduleCourse course)? onMoveToDay;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _showReadableScheduleDetails(
          context, course, onAdjustCourse, onMoveToDay),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            _CourseColorMark(name: course.name),
            const SizedBox(width: 10),
            SizedBox(width: 84, child: Text(_scheduleTimeText(course))),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (course.isLocal) ...[
                        const _LocalCourseBadge(),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(course.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium),
                      ),
                    ],
                  ),
                  Text(
                    [
                      _scheduleSectionText(course),
                      _cleanScheduleText(course.classroom),
                      _cleanScheduleText(course.teacher),
                    ].whereType<String>().join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CourseColorMark extends StatelessWidget {
  const _CourseColorMark({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 34,
      decoration: BoxDecoration(
        color: _scheduleCourseColor(name),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

class _ScheduleMeta extends StatelessWidget {
  const _ScheduleMeta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        width: constraints.maxWidth,
        child: Row(
          children: [
            Icon(icon,
                size: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TimetableView extends StatefulWidget {
  const TimetableView({
    super.key,
    required this.items,
    this.onAdjustCourse,
    this.onMoveToDay,
  });

  final List<ScheduleCourse> items;
  final void Function(ScheduleCourse course)? onAdjustCourse;
  final void Function(ScheduleCourse course)? onMoveToDay;

  @override
  State<TimetableView> createState() => _TimetableViewState();
}

class _TimetableViewState extends State<TimetableView> {
  final verticalController = ScrollController();

  static const leftWidth = 70.0;
  static const headerHeight = 56.0;
  static const rowHeight = 76.0;
  static const minDayWidth = 112.0;
  static const maxDayWidth = 148.0;
  static const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  static const times = [
    ('09:00', '09:40'),
    ('09:40', '10:20'),
    ('10:40', '11:20'),
    ('11:20', '12:00'),
    ('12:30', '13:10'),
    ('13:10', '13:50'),
    ('14:00', '14:40'),
    ('14:40', '15:20'),
    ('15:30', '16:10'),
    ('16:10', '16:50'),
    ('17:00', '17:40'),
    ('17:40', '18:20'),
    ('19:00', '19:40'),
    ('19:40', '20:20'),
    ('20:30', '21:10'),
    ('21:10', '21:50'),
  ];
  static const palette = [
    Color(0xFF8E2F43),
    Color(0xFF006C67),
    Color(0xFF1E5A85),
    Color(0xFF8B4D00),
    Color(0xFF654597),
    Color(0xFF9D1734),
    Color(0xFF0E3F63),
    Color(0xFF9B3D2D),
    Color(0xFF1F4E94),
  ];

  @override
  void dispose() {
    verticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineColor = theme.colorScheme.outlineVariant;
    final surface = theme.colorScheme.surfaceContainer;
    final periodCount = _periodCount();

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: surface,
          border: Border.all(color: lineColor),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final breakpoint = constraints.maxWidth.gzusBreakpoint;
            final compact = breakpoint == GzusBreakpoint.compact;
            final effectiveLeftWidth = compact ? 34.0 : leftWidth;
            final effectiveHeaderHeight = compact ? 34.0 : headerHeight;
            final effectiveRowHeight = compact ? 64.0 : rowHeight;
            final effectiveMinDayWidth = compact ? 34.0 : minDayWidth;
            final effectiveMaxDayWidth = compact
                ? 72.0
                : (breakpoint == GzusBreakpoint.medium ? 128.0 : maxDayWidth);

            final tableWidth = constraints.maxWidth;
            final availableDayWidth = (tableWidth - effectiveLeftWidth) / 7;
            final dayWidth = compact
                ? availableDayWidth
                    .clamp(effectiveMinDayWidth, effectiveMaxDayWidth)
                    .toDouble()
                : availableDayWidth
                    .clamp(effectiveMinDayWidth, effectiveMaxDayWidth)
                    .toDouble();
            final effectiveTableWidth = compact
                ? tableWidth
                : (effectiveLeftWidth + dayWidth * 7)
                    .clamp(tableWidth, double.infinity)
                    .toDouble();
            final tableHeight =
                effectiveHeaderHeight + effectiveRowHeight * periodCount;

            return Scrollbar(
              controller: verticalController,
              child: SingleChildScrollView(
                controller: verticalController,
                physics: const AlwaysScrollableScrollPhysics(),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: compact
                      ? const NeverScrollableScrollPhysics()
                      : const ClampingScrollPhysics(),
                  child: SizedBox(
                    width: effectiveTableWidth,
                    height: tableHeight,
                    child: Stack(
                      children: [
                        _TimetableGrid(
                          leftWidth: effectiveLeftWidth,
                          headerHeight: effectiveHeaderHeight,
                          dayWidth: dayWidth,
                          rowHeight: effectiveRowHeight,
                          periodCount: periodCount,
                          lineColor: lineColor,
                        ),
                        Positioned(
                          left: 0,
                          top: 0,
                          width: effectiveLeftWidth,
                          height: effectiveHeaderHeight,
                          child: const _HeaderCell(label: '节'),
                        ),
                        for (var day = 0; day < 7; day++)
                          Positioned(
                            left: effectiveLeftWidth + dayWidth * day,
                            top: 0,
                            width: dayWidth,
                            height: effectiveHeaderHeight,
                            child: _HeaderCell(
                              label:
                                  compact ? weekdays[day] : '周${weekdays[day]}',
                            ),
                          ),
                        for (var index = 0; index < periodCount; index++)
                          Positioned(
                            left: 0,
                            top: effectiveHeaderHeight +
                                effectiveRowHeight * index,
                            width: effectiveLeftWidth,
                            height: effectiveRowHeight,
                            child: _PeriodCell(
                              section: index + 1,
                              time: index < times.length ? times[index] : null,
                            ),
                          ),
                        for (final item in widget.items)
                          if (_hasPosition(item))
                            _CourseBlock(
                              course: item,
                              dayWidth: dayWidth,
                              rowHeight: effectiveRowHeight,
                              leftWidth: effectiveLeftWidth,
                              headerHeight: effectiveHeaderHeight,
                              color: _courseColor(item.name),
                              onAdjustCourse: widget.onAdjustCourse,
                              onMoveToDay: widget.onMoveToDay,
                            ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  int _periodCount() {
    var count = 16;
    for (final item in widget.items) {
      final end = item.endSection ?? item.startSection ?? 0;
      if (end > count) count = end;
    }
    return count;
  }

  bool _hasPosition(ScheduleCourse item) {
    final weekday = item.weekday;
    final start = item.startSection;
    if (weekday == null || weekday < 1 || weekday > 7) return false;
    return start != null && start > 0;
  }

  Color _courseColor(String name) {
    var hash = 0;
    for (final unit in name.codeUnits) {
      hash = (hash + unit) % palette.length;
    }
    return palette[hash];
  }
}

class _TimetableGrid extends StatelessWidget {
  const _TimetableGrid({
    required this.leftWidth,
    required this.headerHeight,
    required this.dayWidth,
    required this.rowHeight,
    required this.periodCount,
    required this.lineColor,
  });

  final double leftWidth;
  final double headerHeight;
  final double dayWidth;
  final double rowHeight;
  final int periodCount;
  final Color lineColor;

  @override
  Widget build(BuildContext context) {
    final fadedLine = lineColor.withValues(alpha: 0.7);
    return Stack(
      children: [
        for (var day = 0; day <= 7; day++)
          Positioned(
            left: leftWidth + dayWidth * day,
            top: 0,
            bottom: 0,
            child: Container(width: 1, color: fadedLine),
          ),
        for (var index = 0; index <= periodCount; index++)
          Positioned(
            left: 0,
            right: 0,
            top: headerHeight + rowHeight * index,
            child: Container(height: 1, color: fadedLine),
          ),
        Positioned(
          left: 0,
          top: headerHeight,
          bottom: 0,
          child: Container(width: 1, color: fadedLine),
        ),
      ],
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 54;
        return Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: compact ? 11 : 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      },
    );
  }
}

class _PeriodCell extends StatelessWidget {
  const _PeriodCell({required this.section, required this.time});

  final int section;
  final (String, String)? time;

  @override
  Widget build(BuildContext context) {
    final inactive = Theme.of(context).colorScheme.onSurfaceVariant;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 44;
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 1 : 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$section',
                style: TextStyle(
                  fontSize: compact ? 12 : 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (time != null) ...[
                SizedBox(height: compact ? 2 : 4),
                Text(
                  time!.$1,
                  style: TextStyle(
                    fontSize: compact ? 7 : 11,
                    color: inactive,
                    height: 1,
                  ),
                ),
                Text(
                  time!.$2,
                  style: TextStyle(
                    fontSize: compact ? 7 : 11,
                    color: inactive,
                    height: 1,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _CourseBlock extends StatelessWidget {
  const _CourseBlock({
    required this.course,
    required this.dayWidth,
    required this.rowHeight,
    required this.leftWidth,
    required this.headerHeight,
    required this.color,
    this.onAdjustCourse,
    this.onMoveToDay,
  });

  final ScheduleCourse course;
  final double dayWidth;
  final double rowHeight;
  final double leftWidth;
  final double headerHeight;
  final Color color;
  final void Function(ScheduleCourse course)? onAdjustCourse;
  final void Function(ScheduleCourse course)? onMoveToDay;

  @override
  Widget build(BuildContext context) {
    final weekday = course.weekday!;
    final start = course.startSection!;
    final end = course.endSection ?? start;
    final span = end >= start ? end - start + 1 : 1;
    final detail = _detailText(span);

    return Positioned(
      left: leftWidth + (weekday - 1) * dayWidth + 2,
      top: headerHeight + (start - 1) * rowHeight + 3,
      width: dayWidth - 4,
      height: rowHeight * span - 6,
      child: Stack(
        children: [
          GestureDetector(
            onTap: () => _showDetails(context, start, end),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: dayWidth < 52 ? 2 : 8,
                  vertical: dayWidth < 52 ? 4 : 10,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(8),
                  border: course.isLocal
                      ? Border.all(color: Colors.white, width: 1.4)
                      : Border.all(color: Colors.white.withValues(alpha: 0.45)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    detail,
                    textAlign: TextAlign.center,
                    maxLines: span <= 1 ? 4 : span * 4,
                    overflow: TextOverflow.fade,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: dayWidth < 40
                          ? 8
                          : (dayWidth < 52 ? 9 : (dayWidth < 72 ? 11 : 14)),
                      height: 1.08,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (course.isLocal)
            Positioned(
              top: 3,
              right: 3,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '调',
                  style: TextStyle(
                    color: Colors.black87,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _detailText(int span) {
    final lines = <String>[course.name];
    final room = _clean(course.classroom);
    final teacher = _clean(course.teacher);
    if (room != null) lines.add('@$room');
    if (span >= 2 && teacher != null) lines.add(teacher);
    return lines.join('\n');
  }

  String? _clean(String? value) {
    final cleaned = value?.trim();
    if (cleaned == null || cleaned.isEmpty) return null;
    return cleaned;
  }

  void _showDetails(BuildContext context, int start, int end) {
    final standardRows = [
      if (course.isLocal) (Icons.edit, '来源', '本地调课'),
      ..._priorityRawRows(),
      (Icons.menu_book, '课程', course.name),
      (Icons.calendar_month, '星期', '周${course.weekday}'),
      (Icons.schedule, '节次', '第$start-${end >= start ? end : start}节'),
      if (_clean(course.classroom) != null)
        (Icons.room, '教室', _clean(course.classroom)!),
      if (_clean(course.teacher) != null)
        (Icons.people, '教师', _clean(course.teacher)!),
      if (_clean(course.weeks) != null)
        (Icons.access_time, '周次', _clean(course.weeks)!),
    ];
    final rawRows = course.raw.entries
        .where((entry) =>
            !_priorityRawKeys.contains(entry.key) &&
            _rawValueText(entry.value).isNotEmpty)
        .map((entry) => (_rawLabel(entry.key), _rawValueText(entry.value)))
        .toList();

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(course.name),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final row in standardRows)
                  _DetailRow(icon: row.$1, label: row.$2, value: row.$3),
                if (rawRows.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ExpansionTile(
                    title: const Text('原始字段'),
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final row in rawRows)
                            _DetailRow(label: row.$1, value: row.$2),
                        ],
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (onAdjustCourse != null)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                onAdjustCourse!(course);
              },
              child: Text(course.isLocal ? '编辑' : '调整此课'),
            ),
          if (onMoveToDay != null)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                onMoveToDay!(course);
              },
              child: const Text('调到另一天'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  List<(IconData, String, String)> _priorityRawRows() {
    return [
      for (final key in _priorityRawKeys)
        if (_rawValueText(course.raw[key]).isNotEmpty)
          (Icons.info_outline, _rawLabel(key), _rawValueText(course.raw[key])),
    ];
  }

  static const _priorityRawKeys = ['jxbmc', 'kch', 'kcxz'];

  String _rawValueText(dynamic value) {
    if (value == null) return '';
    if (value is String) return value.trim();
    if (value is num || value is bool) return value.toString();
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  String _rawLabel(String key) {
    const labels = {
      'kch': '课程代码(kch)',
      'kcmc': '课程名称(kcmc)',
      'jxb_id': '班级编号(jxb_id)',
      'jxbmc': '班级编号(jxbmc)',
      'jsxm': '教师(jsxm)',
      'xm': '教师/姓名(xm)',
      'cdmc': '教室(cdmc)',
      'xqj': '星期(xqj)',
      'ksjc': '开始节次(ksjc)',
      'jcs': '节次(jcs)',
      'zcd': '周次(zcd)',
      'xf': '学分(xf)',
      'xnm': '学年(xnm)',
      'xqm': '学期(xqm)',
      'kcxz': '课程性质(kcxz)',
    };
    return labels[key] ?? key;
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, this.icon});

  final IconData? icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon,
                size: 15,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
          SizedBox(
            width: icon == null ? 132 : 116,
            child: Text(
              label,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: value.contains('\n')
                  ? const TextStyle(fontFamily: 'Consolas', fontSize: 12)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

int _compareScheduleCourses(ScheduleCourse a, ScheduleCourse b) {
  final day = (a.weekday ?? 99).compareTo(b.weekday ?? 99);
  if (day != 0) return day;
  final section = (a.startSection ?? 99).compareTo(b.startSection ?? 99);
  if (section != 0) return section;
  return a.name.compareTo(b.name);
}

String _scheduleTimeText(ScheduleCourse course) {
  final start = course.startSection;
  final end = course.endSection ?? start;
  if (start == null || start < 1 || start > scheduleTimes.length) {
    return '时间待定';
  }
  final startText = scheduleTimes[start - 1].$1;
  final endText = end != null && end >= 1 && end <= scheduleTimes.length
      ? scheduleTimes[end - 1].$2
      : scheduleTimes[start - 1].$2;
  return '$startText-$endText';
}

String _scheduleSectionText(ScheduleCourse course) {
  final start = course.startSection;
  final end = course.endSection ?? start;
  if (start == null) return '节次待定';
  return '第$start-${end != null && end >= start ? end : start}节';
}

String _scheduleWeekdayText(int weekday) {
  const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  if (weekday < 1 || weekday > 7) return '未知';
  return names[weekday - 1];
}

String? _cleanScheduleText(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  return text;
}

Color _scheduleCourseColor(String name) {
  const palette = [
    Color(0xFFFF9CCB),
    Color(0xFFFFE38B),
    Color(0xFFB9FF8A),
    Color(0xFF8EDDF3),
    Color(0xFFF3A6E7),
    Color(0xFFA9EFAF),
    Color(0xFFB8D7FF),
    Color(0xFFFFB9A8),
    Color(0xFFD7C5FF),
  ];
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = (hash + unit) % palette.length;
  }
  return palette[hash];
}

void _showReadableScheduleDetails(BuildContext context, ScheduleCourse course,
    [void Function(ScheduleCourse course)? onAdjustCourse,
    void Function(ScheduleCourse course)? onMoveToDay]) {
  final rows = [
    if (course.isLocal) (Icons.edit, '来源', '本地调课'),
    (Icons.menu_book, '课程', course.name),
    (
      Icons.calendar_month,
      '星期',
      course.weekday == null ? '星期待定' : _scheduleWeekdayText(course.weekday!)
    ),
    (Icons.schedule, '时间', _scheduleTimeText(course)),
    (Icons.schedule, '节次', _scheduleSectionText(course)),
    if (_cleanScheduleText(course.classroom) != null)
      (Icons.room, '教室', _cleanScheduleText(course.classroom)!),
    if (_cleanScheduleText(course.teacher) != null)
      (Icons.people, '教师', _cleanScheduleText(course.teacher)!),
    if (_cleanScheduleText(course.weeks) != null)
      (Icons.access_time, '周次', _cleanScheduleText(course.weeks)!),
  ];
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(course.name),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final row in rows)
              _DetailRow(icon: row.$1, label: row.$2, value: row.$3),
          ],
        ),
      ),
      actions: [
        if (onAdjustCourse != null)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              onAdjustCourse(course);
            },
            child: Text(course.isLocal ? '编辑' : '调整此课'),
          ),
        if (onMoveToDay != null)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              onMoveToDay(course);
            },
            child: const Text('调到另一天'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

/// 本地调课条目的小徽标（「调」）。
class _LocalCourseBadge extends StatelessWidget {
  const _LocalCourseBadge();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '调',
        style: TextStyle(
          color: colorScheme.onPrimaryContainer,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class JsonPanel extends StatelessWidget {
  const JsonPanel({super.key, required this.json});

  final String json;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 360),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          json,
          style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
        ),
      ),
    );
  }
}
