import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api_client.dart';
import '../../schedule_utils.dart';
import '../../background_service.dart' deferred as background_service;
import '../../ics_download.dart' deferred as ics_download;
import '../../reminder_service.dart' deferred as reminder_service;
import '../../widgets/async_panel.dart';
import '../../widgets/badges.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/icon_label.dart';
import '../../widgets/page_panel.dart';

class ScheduleOnboardingPage extends StatefulWidget {
  const ScheduleOnboardingPage({
    super.key,
    required this.api,
    required this.studentName,
    required this.onComplete,
    required this.onSkip,
  });

  final ApiClient api;
  final String? studentName;
  final VoidCallback onComplete;
  final VoidCallback onSkip;

  @override
  State<ScheduleOnboardingPage> createState() => _ScheduleOnboardingPageState();
}

class _ScheduleOnboardingPageState extends State<ScheduleOnboardingPage> {
  late final int _year;
  late final int _term;
  late DateTime _selected;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _year = DateTime.now().month >= 9
        ? DateTime.now().year
        : DateTime.now().year - 1;
    _term = DateTime.now().month >= 9 || DateTime.now().month <= 1 ? 1 : 2;
    _selected = defaultFirstWeekStart(_year, _term);
  }

  String get _termLabel {
    return '$_year-${_term == 1 ? '第一学期' : '第二学期'}';
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
      // 保存到 SharedPreferences，键名与 _DashboardShellState 一致
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'schedule.$_year.$_term.firstWeekStart',
        dateText(_selected),
      );
      await prefs.setInt(
        'schedule.$_year.$_term.week',
        weekFromDate(_selected, DateTime.now(), clampToTerm: true),
      );
      if (!mounted) return;
      widget.onComplete();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final currentWeek = weekFromDate(_selected, DateTime.now(), clampToTerm: true);
    final weekdayName = _weekdayName(_selected.weekday);
    return Scaffold(
      appBar: AppBar(
        title: const Text('欢迎使用软帮手'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: _loading ? null : widget.onSkip,
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
                  // 顶部欢迎卡片
                  Container(
                    padding: const EdgeInsets.all(20),
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
                            Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: colorScheme.primary,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Icon(
                                Icons.waving_hand,
                                color: colorScheme.onPrimary,
                                size: 28,
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
                                    style: textTheme.headlineSmall?.copyWith(
                                      fontWeight: FontWeight.w900,
                                    ),
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
                  const SizedBox(height: 24),
                  // 学期信息
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.school,
                            size: 18, color: colorScheme.primary),
                        const SizedBox(width: 8),
                        Text(
                          '当前学期：$_termLabel',
                          style: textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // 日期选择卡片
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '第一周开始日期',
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
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
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
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
                  const SizedBox(height: 20),
                  // 操作按钮
                  FilledButton.icon(
                    onPressed: _loading ? null : _complete,
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
                            fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: TextButton(
                      onPressed: _loading ? null : widget.onSkip,
                      child: Text(
                        '暂不设置，使用默认日期',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
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
  ScheduleViewMode _viewMode = ScheduleViewMode.today;
  bool showJson = false;
  bool showAllCourses = false;
  bool courseRemindersEnabled = false;
  int courseStartReminderMinutes = 10;
  int courseEndReminderMinutes = 5;
  bool _exporting = false;
  String? manageError;
  String? _lastNativeReminderSignature;

  @override
  void initState() {
    super.initState();
    _scheduleFuture = _loadSchedule();
    _loadReminderSettings();
  }

  @override
  void didUpdateWidget(covariant SchedulePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.year != widget.year ||
        oldWidget.term != widget.term) {
      _scheduleFuture = _loadSchedule();
    }
  }

  Future<ScheduleResult> _loadSchedule({bool forceRefresh = false}) async {
    final result = await widget.api.schedule(
      year: widget.year,
      term: widget.term,
      forceRefresh: forceRefresh,
    );
    // 课表数据到位后统一配置提醒（内部均有签名守卫，重复调用无开销）
    unawaited(_applyCourseReminders(result.data.items));
    return result.data;
  }

  /// 应用课程提醒配置：本地通知（reminder_service）+ 原生后台同步。
  /// 只在课表数据或提醒设置变化时实际执行，避免 build 内重复触发。
  Future<void> _applyCourseReminders(List<ScheduleCourse> courses) async {
    try {
      await reminder_service.loadLibrary();
      reminder_service.ReminderService.configureCourseReminders(
        courses: courses,
        firstWeekStart: widget.firstWeekStart,
        settings: reminder_service.CourseReminderSettings(
          enabled: courseRemindersEnabled,
          beforeStartMinutes: courseStartReminderMinutes,
          beforeEndMinutes: courseEndReminderMinutes,
        ),
      );
      await _syncCourseRemindersToNative(
        courses,
        courseStartReminderMinutes,
        courseEndReminderMinutes,
        widget.firstWeekStart,
      );
    } catch (e) {
      debugPrint('课程提醒配置失败: $e');
    }
  }

  Future<void> _refreshSchedule() async {
    setState(() => _scheduleFuture = _loadSchedule(forceRefresh: true));
    await _scheduleFuture;
  }

  Future<void> _syncCourseRemindersToNative(
    List<ScheduleCourse> courses,
    int beforeStartMinutes,
    int beforeEndMinutes,
    DateTime firstWeekStart,
  ) async {
    final coursesList = courses.map((c) {
      final weeksList = <int>[];
      for (var w = 1; w <= 30; w++) {
        if (c.occursInWeek(w)) weeksList.add(w);
      }
      return {
        'name': c.name,
        'weekday': c.weekday ?? 0,
        'startSection': c.startSection ?? 0,
        'endSection': c.endSection ?? 0,
        'classroom': c.classroom ?? '',
        'teacher': c.teacher ?? '',
        'weeks': weeksList,
      };
    }).toList();
    final coursesJson = jsonEncode(coursesList);
    final firstWeekStr =
        '${firstWeekStart.year.toString().padLeft(4, '0')}-${firstWeekStart.month.toString().padLeft(2, '0')}-${firstWeekStart.day.toString().padLeft(2, '0')}';
    // 签名守卫：内容未变化时不重复向原生层全量推送
    final signature =
        '$coursesJson|$beforeStartMinutes|$beforeEndMinutes|$firstWeekStr';
    if (signature == _lastNativeReminderSignature) return;
    await background_service.loadLibrary();
    await background_service.BackgroundService.updateCourseReminders(
      coursesJson: coursesJson,
      beforeStartMinutes: beforeStartMinutes,
      beforeEndMinutes: beforeEndMinutes,
      firstWeekStart: firstWeekStr,
    );
    _lastNativeReminderSignature = signature;
  }

  @override
  Widget build(BuildContext context) {
    return PageRefresh(
      onRefresh: _refreshSchedule,
      child: AsyncPanel<ScheduleResult>(
        future: _scheduleFuture,
        onSessionExpired: widget.onSessionExpired,
        builder: (result) {
          final weekItems = result.items
              .where((item) => item.occursInWeek(widget.currentWeek))
              .toList();
          final todayItems = weekItems
              .where((item) => item.weekday == DateTime.now().weekday)
              .toList()
            ..sort(_compareScheduleCourses);
          final displayItems =
              _viewMode == ScheduleViewMode.all ? result.items : weekItems;
          return PagePanel(
            title: '课表',
            icon: Icons.calendar_month,
            expandChild: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ScheduleSummaryPanel(
                  currentWeek: widget.currentWeek,
                  firstWeekStart: widget.firstWeekStart,
                  todayCount: todayItems.length,
                  weekCount: weekItems.length,
                  totalCount: result.items.length,
                  nextCourse: _nextScheduleCourse(todayItems),
                ),
                const SizedBox(height: 10),
                _ScheduleViewSwitch(
                  selected: _viewMode,
                  onChanged: (mode) {
                    setState(() {
                      _viewMode = mode;
                      showAllCourses = mode == ScheduleViewMode.all;
                    });
                  },
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: _ScheduleToolsChip(
                    onPressed: () =>
                        _showScheduleTools(result.prettyJson, result.items),
                  ),
                ),
                const SizedBox(height: 10),
                if (result.items.isEmpty)
                  Expanded(
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(
                          height: 260,
                          child: EmptyState(message: '当前学期暂无课表'),
                        ),
                      ],
                    ),
                  )
                else if (displayItems.isEmpty)
                  Expanded(
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: 260,
                          child: EmptyState(
                              message: '第${widget.currentWeek}周暂无课程'),
                        ),
                      ],
                    ),
                  )
                else
                  Expanded(
                    child: ScheduleReadableView(
                      mode: _viewMode,
                      todayItems: todayItems,
                      weekItems: weekItems,
                      allItems: result.items,
                    ),
                  ),
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
                maxHeight: MediaQuery.sizeOf(context).height * 0.78,
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
                                  setState(() {
                                    showAllCourses = !showAllCourses;
                                    _viewMode = showAllCourses
                                        ? ScheduleViewMode.all
                                        : ScheduleViewMode.week;
                                  });
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
                                  const IconLabel(
                                    icon: Icons.notifications_active,
                                    label: '上下课提醒',
                                  ),
                                  Switch(
                                    value: courseRemindersEnabled,
                                    onChanged: (value) {
                                      _setCourseRemindersEnabled(value);
                                      localSetState(() {});
                                    },
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
                                    : () async {
                                        setState(() => _exporting = true);
                                        localSetState(() {});
                                        try {
                                          final ics = generateIcs(
                                            courses: items,
                                            firstWeekStart:
                                                widget.firstWeekStart,
                                            year: widget.year,
                                            term: widget.term,
                                          );
                                          final filename =
                                              '课表_${widget.year}_${widget.term}.ics';
                                          if (kIsWeb) {
                                            await ics_download.loadLibrary();
                                            await ics_download.downloadIcs(
                                                ics, filename);
                                          } else {
                                            await Share.shareXFiles(
                                              [
                                                XFile.fromData(
                                                  Uint8List.fromList(
                                                      utf8.encode(ics)),
                                                  name: filename,
                                                  mimeType: 'text/calendar',
                                                ),
                                              ],
                                              text: filename,
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
                                child: IconLabel(
                                  icon: Icons.download,
                                  label: _exporting ? '导出中...' : '导出 ICS',
                                ),
                              ),
                              TextButton(
                                onPressed: items.isEmpty || _exporting
                                    ? null
                                    : () async {
                                        setState(() => _exporting = true);
                                        localSetState(() {});
                                        try {
                                          final ics = generateIcs(
                                            courses: items,
                                            firstWeekStart:
                                                widget.firstWeekStart,
                                            year: widget.year,
                                            term: widget.term,
                                          );
                                          final filename =
                                              '课表_${widget.year}_${widget.term}.ics';
                                          if (kIsWeb) {
                                            await ics_download.loadLibrary();
                                            await ics_download.downloadIcs(
                                                ics, filename);
                                          } else {
                                            await Share.shareXFiles(
                                              [
                                                XFile.fromData(
                                                  Uint8List.fromList(
                                                      utf8.encode(ics)),
                                                  name: filename,
                                                  mimeType: 'text/calendar',
                                                ),
                                              ],
                                              text: filename,
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
                            ],
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

  Future<void> _loadReminderSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      courseRemindersEnabled =
          prefs.getBool('schedule.courseRemindersEnabled') ?? false;
      courseStartReminderMinutes =
          prefs.getInt('schedule.courseStartReminderMinutes') ?? 10;
      courseEndReminderMinutes =
          prefs.getInt('schedule.courseEndReminderMinutes') ?? 5;
    });
    // 设置加载完成后按最新配置应用一次提醒
    unawaited(_scheduleFuture.then((r) => _applyCourseReminders(r.items)));
  }

  Future<void> _setCourseRemindersEnabled(bool value) async {
    setState(() => courseRemindersEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('schedule.courseRemindersEnabled', value);
    if (!value) {
      reminder_service.loadLibrary().then((_) {
        reminder_service.ReminderService.cancelCourseReminders();
      });
    } else {
      // 开启时按当前课表立即配置
      unawaited(_scheduleFuture.then((r) => _applyCourseReminders(r.items)));
    }
  }
}

/// 课表工具按钮 — 放在 PagePanel 标题栏右侧的 chip 风格按钮
class _ScheduleToolsChip extends StatelessWidget {
  const _ScheduleToolsChip({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Material(
      key: const ValueKey('schedule-tools-button'),
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onPressed,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 14,
            vertical: compact ? 6 : 8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tune, size: 16, color: colorScheme.primary),
              SizedBox(width: compact ? 4 : 6),
              Text(
                '工具',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
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
    final initial = firstWeekStart.isBefore(firstDate) ||
            firstWeekStart.isAfter(lastDate)
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
    final autoWeekValue = weekFromDate(firstWeekStart, DateTime.now(), clampToTerm: true);
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

enum ScheduleViewMode { today, week, all }

class _ScheduleSummaryPanel extends StatelessWidget {
  const _ScheduleSummaryPanel({
    required this.currentWeek,
    required this.firstWeekStart,
    required this.todayCount,
    required this.weekCount,
    required this.totalCount,
    required this.nextCourse,
  });

  final int currentWeek;
  final DateTime firstWeekStart;
  final int todayCount;
  final int weekCount;
  final int totalCount;
  final ScheduleCourse? nextCourse;

  @override
  Widget build(BuildContext context) {
    final nextText = nextCourse == null
        ? '今日无后续课程'
        : '${_scheduleTimeText(nextCourse!)} · ${nextCourse!.name}';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .primaryContainer
            .withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(Icons.calendar_month,
                    color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '第$currentWeek周课表',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    Text(
                      nextText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MetricPill(
                  icon: Icons.today,
                  label: '今日',
                  value: '$todayCount节',
                  dense: true),
              MetricPill(
                  icon: Icons.view_week,
                  label: '本周',
                  value: '$weekCount节',
                  dense: true),
              MetricPill(
                  icon: Icons.list,
                  label: '全部',
                  value: '$totalCount门',
                  dense: true),
              MetricPill(
                icon: Icons.access_time,
                label: '首周',
                value: dateText(firstWeekStart),
                dense: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScheduleViewSwitch extends StatelessWidget {
  const _ScheduleViewSwitch({required this.selected, required this.onChanged});

  final ScheduleViewMode selected;
  final ValueChanged<ScheduleViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ScheduleViewMode>(
      key: const ValueKey('schedule-view-mode'),
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
            value: ScheduleViewMode.today,
            icon: Icon(Icons.today),
            label: Text('今日')),
        ButtonSegment(
            value: ScheduleViewMode.week,
            icon: Icon(Icons.view_week),
            label: Text('本周')),
        ButtonSegment(
            value: ScheduleViewMode.all,
            icon: Icon(Icons.format_list_bulleted),
            label: Text('全部')),
      ],
      selected: {selected},
      onSelectionChanged: (values) => onChanged(values.single),
    );
  }
}

class ScheduleReadableView extends StatelessWidget {
  const ScheduleReadableView({
    super.key,
    required this.mode,
    required this.todayItems,
    required this.weekItems,
    required this.allItems,
  });

  final ScheduleViewMode mode;
  final List<ScheduleCourse> todayItems;
  final List<ScheduleCourse> weekItems;
  final List<ScheduleCourse> allItems;

  @override
  Widget build(BuildContext context) {
    switch (mode) {
      case ScheduleViewMode.today:
        return _TodayReadableSchedule(items: todayItems);
      case ScheduleViewMode.week:
        if (MediaQuery.sizeOf(context).width < 600) {
          return _WeekReadableSchedule(items: weekItems);
        }
        return TimetableView(items: weekItems);
      case ScheduleViewMode.all:
        return _AllReadableSchedule(items: allItems);
    }
  }
}

class _TodayReadableSchedule extends StatelessWidget {
  const _TodayReadableSchedule({required this.items});

  final List<ScheduleCourse> items;

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
      itemBuilder: (context, index) =>
          _ScheduleCourseTile(course: sorted[index]),
    );
  }
}

class _WeekReadableSchedule extends StatelessWidget {
  const _WeekReadableSchedule({required this.items});

  final List<ScheduleCourse> items;

  @override
  Widget build(BuildContext context) {
    final byDay = <int, List<ScheduleCourse>>{
      for (var day = 1; day <= 7; day++) day: <ScheduleCourse>[],
    };
    for (final item in items) {
      final weekday = item.weekday;
      if (weekday != null && weekday >= 1 && weekday <= 7) {
        byDay[weekday]!.add(item);
      }
    }
    for (final list in byDay.values) {
      list.sort(_compareScheduleCourses);
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: 7,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final day = index + 1;
        final courses = byDay[day]!;
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
                  Text(_scheduleWeekdayText(day),
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w900)),
                  const Spacer(),
                  Text(courses.isEmpty ? '无课' : '${courses.length}节',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              if (courses.isNotEmpty) ...[
                const SizedBox(height: 10),
                for (final course in courses)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _CompactScheduleCourseTile(course: course),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _AllReadableSchedule extends StatelessWidget {
  const _AllReadableSchedule({required this.items});

  final List<ScheduleCourse> items;

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
                _CompactScheduleCourseTile(course: course),
            ],
          ),
        );
      },
    );
  }
}

class _ScheduleCourseTile extends StatelessWidget {
  const _ScheduleCourseTile({required this.course});

  final ScheduleCourse course;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _showReadableScheduleDetails(context, course),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
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
                    Text(course.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w900)),
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
  const _CompactScheduleCourseTile({required this.course});

  final ScheduleCourse course;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _showReadableScheduleDetails(context, course),
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
                  Text(course.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium),
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon,
            size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class TimetableView extends StatefulWidget {
  const TimetableView({super.key, required this.items});

  final List<ScheduleCourse> items;

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
    final compact = MediaQuery.sizeOf(context).width < 600;
    final effectiveLeftWidth = compact ? 34.0 : leftWidth;
    final effectiveHeaderHeight = compact ? 34.0 : headerHeight;
    final effectiveRowHeight = compact ? 64.0 : rowHeight;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: surface,
          border: Border.all(color: lineColor),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tableWidth = constraints.maxWidth;
            final availableDayWidth = (tableWidth - effectiveLeftWidth) / 7;
            final dayWidth = compact
                ? availableDayWidth.clamp(34.0, 72.0).toDouble()
                : availableDayWidth.clamp(minDayWidth, maxDayWidth).toDouble();
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
  });

  final ScheduleCourse course;
  final double dayWidth;
  final double rowHeight;
  final double leftWidth;
  final double headerHeight;
  final Color color;

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
      child: GestureDetector(
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
              border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
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
                  fontSize: dayWidth < 46 ? 8 : (dayWidth < 64 ? 10 : 14),
                  height: 1.08,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
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

ScheduleCourse? _nextScheduleCourse(List<ScheduleCourse> items) {
  final now = DateTime.now();
  for (final item in [...items]..sort(_compareScheduleCourses)) {
    final end = _scheduleCourseEnd(item, now);
    if (end != null && end.isAfter(now)) return item;
  }
  return null;
}

DateTime? _scheduleCourseEnd(ScheduleCourse course, DateTime date) {
  final section = course.endSection ?? course.startSection;
  if (section == null || section < 1 || section > scheduleTimes.length) {
    return null;
  }
  return _dateWithScheduleTime(date, scheduleTimes[section - 1].$2);
}

DateTime _dateWithScheduleTime(DateTime date, String time) {
  final parts = time.split(':');
  return DateTime(
    date.year,
    date.month,
    date.day,
    int.tryParse(parts.first) ?? 0,
    parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
  );
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
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = (hash + unit) % palette.length;
  }
  return palette[hash];
}

void _showReadableScheduleDetails(BuildContext context, ScheduleCourse course) {
  final rows = [
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
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
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
