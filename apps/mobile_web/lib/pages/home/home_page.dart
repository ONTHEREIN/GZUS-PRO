import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api_client.dart';
import '../../gzus_design.dart';
import '../../location_service.dart';
import '../../permission_service.dart';
import '../../models/home_config.dart';
import '../../models/grade_models.dart';
import '../../responsive/spacing.dart';
import '../../test_flags.dart';
import '../../responsive/breakpoints.dart';
import '../../widgets/page_panel.dart';
import '../../widgets/page_silent_refresh.dart';
import 'cards/home_card_shell.dart';
import 'cards/schedule_helpers.dart';
import 'cards/next_class_card.dart';
import 'cards/today_timeline_card.dart';
import 'cards/week_grid_card.dart';
import 'cards/daily_courses_card.dart';
import 'cards/utilities_card.dart';
import 'cards/business_progress_card.dart';
import 'cards/notifications_card.dart';
import 'cards/attendance_card.dart';
import 'cards/credits_card.dart';
import 'cards/grades_card.dart';
import 'cards/exam_countdown_card.dart';
import 'cards/profile_card.dart';
import 'cards/apps_card.dart';
import 'cards/weather_card.dart';

class HomeDashboardData {
  const HomeDashboardData({
    required this.info,
    required this.courses,
    required this.notices,
    required this.attendance,
    required this.credits,
    required this.ecard,
    required this.apps,
    required this.progressOverview,
    this.weather,
    this.grades,
    this.exams,
  });

  final StudentInfo info;
  final List<ScheduleCourse> courses;
  final List<NoticeItem> notices;
  final AttendanceResponse attendance;
  final List<CreditItem> credits;
  final EcardSummary ecard;
  final List<EhallApplicationItem> apps;
  final EhallProgressOverview progressOverview;
  final WeatherData? weather;
  final List<GradeItem>? grades;
  final List<ExamItem>? exams;

  List<EhallProgressItem> get progress => progressOverview.items;
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.api,
    required this.year,
    required this.term,
    required this.currentWeek,
    required this.firstWeekStart,
    required this.onNavigate,
    this.onSessionExpired,
    this.headerScrollProgress,
    this.studentName,
    this.studentId,
  });

  final ApiClient api;
  final int year;
  final int term;
  final int currentWeek;
  final DateTime firstWeekStart;
  final ValueChanged<String> onNavigate;
  final VoidCallback? onSessionExpired;
  final ValueListenable<double>? headerScrollProgress;

  /// 登录态已知的姓名/学号，用于 me 模块缺失或失败时兜底展示，
  /// 保证首页个人信息始终与当前登录账号一致（而非空/占位）。
  final String? studentName;
  final String? studentId;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with PageSilentRefresh<HomePage> {
  // 首页只请求一次 dashboard 快照，各模块独立解析，避免单个坏数据清空整页。
  late Future<DashboardSnapshot> _dashboardFuture;
  late Future<StudentInfo> _infoFuture;
  late Future<ScheduleResult> _scheduleFuture;
  late Future<List<NoticeItem>> _noticesFuture;
  late Future<AttendanceResponse> _attendanceFuture;
  late Future<List<CreditItem>> _creditsFuture;
  late Future<EcardSummary> _ecardFuture;
  late Future<List<EhallApplicationItem>> _appsFuture;
  late Future<EhallProgressOverview> _progressFuture;
  late Future<WeatherData?> _weatherFuture;
  late Future<List<GradeItem>> _gradesFuture;
  late Future<List<ExamItem>> _examsFuture;

  List<String> _moduleOrder = HomePreferences.defaultModuleIds;
  Set<String> _hiddenModules = {};
  Map<String, HomeModuleSize> _moduleSizes = {};
  bool _moreModulesExpanded = false;
  bool _moreModuleDataLoaded = false;

  static const _primaryModuleIds = <String>{
    'nextClass',
    'todayTimeline',
    'examCountdown',
    'utilities',
    'grades',
    'progress',
  };
  static const _initialDashboardModules = <String>[
    'me',
    'schedule',
    'grades',
    'exams',
    'progress',
    'ecard',
  ];

  @override
  void initState() {
    super.initState();
    _initFutures();
    _loadPreferences();
  }

  void _initFutures({bool forceRefresh = false}) {
    _moreModuleDataLoaded = false;
    _dashboardFuture = _loadDashboardSnapshot(forceRefresh: forceRefresh);
    _infoFuture = _dashboardFuture.then(_parseInfo);
    _scheduleFuture = _dashboardFuture.then(
      (snapshot) {
        final courses = _moduleList(snapshot, 'schedule', '课表')
            .map(ScheduleCourse.fromJson)
            .toList();
        return ScheduleResult(
          items: courses,
          raw: courses.map((item) => item.raw).toList(),
        );
      },
    );
    _noticesFuture = Future<List<NoticeItem>>.value(const <NoticeItem>[]);
    _attendanceFuture = Future<AttendanceResponse>.value(
      AttendanceResponse.fromJson(
        const <String, dynamic>{'status': 'empty', 'items': <Object>[]},
      ),
    );
    _creditsFuture = Future<List<CreditItem>>.value(const <CreditItem>[]);
    _ecardFuture = _dashboardFuture.then((snapshot) {
      final data = _moduleObject(snapshot, 'ecard', '水电费');
      return EcardSummary.fromJson(data ?? const <String, dynamic>{});
    });
    _appsFuture = Future<List<EhallApplicationItem>>.value(
      const <EhallApplicationItem>[],
    );
    _progressFuture = _dashboardFuture.then((snapshot) {
      final data = _moduleObject(snapshot, 'progress', '业务进度');
      return data == null
          ? EhallProgressOverview.fromItems(const <EhallProgressItem>[])
          : EhallProgressOverview.fromJson(data);
    });
    // 天气属于“更多模块”，首屏不请求定位和天气服务。
    _weatherFuture = Future<WeatherData?>.value(null);
    _gradesFuture = _dashboardFuture.then((snapshot) async {
      final grades = _moduleList(snapshot, 'grades', '成绩')
          .map(GradeItem.fromJson)
          .toList();
      if (grades.isNotEmpty) {
        unawaited(_saveLocalGrades(grades));
        return grades;
      }
      return _loadLocalGrades();
    });
    _examsFuture = _dashboardFuture.then((snapshot) async {
      final exams =
          _moduleList(snapshot, 'exams', '考试').map(ExamItem.fromJson).toList();
      if (exams.isNotEmpty) {
        unawaited(_saveLocalExams(exams));
        return exams;
      }
      return _loadLocalExams();
    });
    unawaited(_updateHomeWidget());
    if (_moreModulesExpanded) {
      unawaited(_loadMoreModuleData(forceRefresh: forceRefresh));
    }
  }

  @override
  void silentRefresh() {
    if (!mounted) return;
    setState(() => _initFutures());
  }

  void _retryDashboard() {
    if (!mounted) return;
    setState(() => _initFutures(forceRefresh: true));
  }

  Future<void> _refreshDashboard() async {
    _retryDashboard();
    try {
      final snapshot = await _dashboardFuture;
      final failedModules = _dashboardRefreshFailures(snapshot);
      if (failedModules.isEmpty || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('部分模块刷新失败：${failedModules.join('；')}')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('首页刷新失败：$error')),
      );
    }
  }

  List<String> _dashboardRefreshFailures(DashboardSnapshot snapshot) {
    const labels = {
      'me': '个人信息',
      'schedule': '课表',
      'notices': '通知',
      'attendance': '考勤',
      'credits': '学分',
      'grades': '成绩',
      'exams': '考试',
      'apps': '常用服务',
      'progress': '业务进度',
    };
    final failures = <String>[];
    for (final entry in snapshot.modules.entries) {
      final reason = entry.value.error?.trim();
      if (entry.value.status != 'error' || reason == null || reason.isEmpty) {
        continue;
      }
      failures.add('${labels[entry.key] ?? entry.key}：$reason');
    }
    return failures;
  }

  Future<DashboardSnapshot> _loadDashboardSnapshot({
    bool forceRefresh = false,
    List<String>? modules,
  }) async {
    final result = await widget.api.dashboard(
      year: widget.year,
      term: widget.term,
      week: widget.currentWeek,
      modules: modules ?? _initialDashboardModules,
      forceRefresh: forceRefresh,
    );
    if (result.data.status != 'ok') {
      throw ApiException('首页数据加载失败：服务器状态为 ${result.data.status}');
    }
    return result.data;
  }

  Future<void> _loadMoreModuleData({bool forceRefresh = false}) async {
    if (_moreModuleDataLoaded && !forceRefresh) return;
    final snapshotFuture = _loadDashboardSnapshot(
      forceRefresh: forceRefresh,
      modules: const ['notices', 'attendance', 'credits', 'apps'],
    );
    setState(() {
      _moreModuleDataLoaded = true;
      _noticesFuture = snapshotFuture.then(
        (snapshot) => _moduleList(snapshot, 'notices', '通知')
            .map(NoticeItem.fromJson)
            .toList(),
      );
      _attendanceFuture = snapshotFuture.then((snapshot) {
        final data = _moduleObject(snapshot, 'attendance', '考勤');
        return AttendanceResponse.fromJson(
          data ?? <String, dynamic>{'status': 'empty', 'items': const []},
        );
      });
      _creditsFuture = snapshotFuture.then(
        (snapshot) => _moduleList(snapshot, 'credits', '学分')
            .map(CreditItem.fromJson)
            .toList(),
      );
      _appsFuture = snapshotFuture.then(
        (snapshot) => _moduleList(snapshot, 'apps', '常用服务')
            .map(EhallApplicationItem.fromJson)
            .toList(),
      );
      _weatherFuture = _loadWeatherForMoreModules();
    });
  }

  Future<WeatherData?> _loadWeatherForMoreModules() async {
    try {
      await PermissionService.requestLocationPermission();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final position = await LocationService.getCoarseLocation();
      final result =
          await widget.api.weather(lat: position?.lat, lon: position?.lon);
      unawaited(_saveLocalWeather(result.data));
      return result.data;
    } catch (_) {
      return _loadLocalWeather();
    }
  }

  DashboardModule _module(
    DashboardSnapshot snapshot,
    String key,
    String label,
  ) {
    final module = snapshot.module(key);
    if (module.status == 'error') {
      final reason = module.error?.trim();
      throw ApiException(
        '$label模块加载失败：${reason == null || reason.isEmpty ? '服务器未提供失败原因' : reason}',
      );
    }
    return module;
  }

  List<Map<String, dynamic>> _moduleList(
    DashboardSnapshot snapshot,
    String key,
    String label,
  ) {
    final module = _module(snapshot, key, label);
    if (module.data == null && module.status == 'empty') return const [];
    final data = module.data;
    if (data is! List<dynamic>) {
      throw FormatException('$label模块数据格式错误：预期列表，实际为 ${data.runtimeType}');
    }
    final items = <Map<String, dynamic>>[];
    for (final item in data) {
      if (item is! Map<String, dynamic>) {
        throw FormatException(
          '$label模块数据格式错误：列表项实际为 ${item.runtimeType}',
        );
      }
      items.add(item);
    }
    return items;
  }

  Map<String, dynamic>? _moduleObject(
    DashboardSnapshot snapshot,
    String key,
    String label,
  ) {
    final module = _module(snapshot, key, label);
    if (module.data == null && module.status == 'empty') return null;
    final data = module.data;
    if (data is! Map<String, dynamic>) {
      throw FormatException('$label模块数据格式错误：预期对象，实际为 ${data.runtimeType}');
    }
    return data;
  }

  StudentInfo _parseInfo(DashboardSnapshot snapshot) {
    final data = _moduleObject(snapshot, 'me', '个人信息');
    if (data == null || (data['name'] as String? ?? '').isEmpty) {
      return _fallbackStudentInfo();
    }
    return StudentInfo.fromJson(data);
  }

  /// me 模块缺失/失败时的兜底身份：优先用当前登录账号的姓名/学号，
  /// 而不是硬编码占位，避免个人信息与实际账号不一致。
  StudentInfo _fallbackStudentInfo() => StudentInfo(
        studentId: widget.studentId ?? '',
        name: widget.studentName ?? '软帮手',
      );

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.year != widget.year ||
        oldWidget.term != widget.term ||
        oldWidget.currentWeek != widget.currentWeek ||
        oldWidget.firstWeekStart != widget.firstWeekStart) {
      _initFutures();
    }
  }

  Future<void> _loadPreferences() async {
    final results = await Future.wait([
      HomePreferences.loadOrder(),
      HomePreferences.loadHidden(),
      HomePreferences.loadSizes(),
      HomePreferences.loadMoreModulesExpanded(),
    ]);
    if (mounted) {
      setState(() {
        _moduleOrder = results[0] as List<String>;
        _hiddenModules = results[1] as Set<String>;
        _moduleSizes = results[2] as Map<String, HomeModuleSize>;
        _moreModulesExpanded = results[3] as bool;
      });
      if (_moreModulesExpanded) {
        unawaited(_loadMoreModuleData());
      }
    }
  }

  static const _weatherKey = 'local.weather';
  // v2：旧版本曾把伪造的示例成绩/考试写入 local.grades/local.exams，
  // 升级键名以丢弃这些假数据，避免老用户继续看到与真实成绩不符的内容。
  static const _gradesKey = 'local.grades.v2';
  static const _examsKey = 'local.exams.v2';

  Future<WeatherData?> _loadLocalWeather() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_weatherKey);
      if (raw != null) return WeatherData.fromJson(jsonDecode(raw));
    } catch (_) {}
    final def = _defaultWeather();
    _saveLocalWeather(def);
    return def;
  }

  Future<void> _saveLocalWeather(WeatherData data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_weatherKey, jsonEncode(_weatherToJson(data)));
    } catch (_) {}
  }

  WeatherData _defaultWeather() {
    final now = DateTime.now();
    const weekdays = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    final forecastDays = <Map<String, String>>[];
    for (var i = 1; i <= 4; i++) {
      final d = now.add(Duration(days: i));
      final dateStr =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      forecastDays.add({
        'date': dateStr,
        'week': weekdays[d.weekday % 7],
        'temp_max': (30 + (i % 3)).toString(),
        'temp_min': (22 + (i % 3)).toString(),
        'weather_day': ['晴', '多云', '阵雨', '多云'][i - 1],
      });
    }
    return WeatherData.fromJson({
      'city': '广州',
      'district': '大学城',
      'weather': '晴',
      'weather_icon': '100',
      'temperature': 28,
      'wind_direction': '东南风',
      'wind_power': '2级',
      'humidity': 65,
      'temp_max': 32,
      'temp_min': 24,
      'forecast': forecastDays,
    });
  }

  Map<String, dynamic> _weatherToJson(WeatherData w) {
    return {
      'province': w.province,
      'city': w.city,
      'district': w.district,
      'weather': w.weather,
      'weather_icon': w.weatherIcon,
      'temperature': w.temperature,
      'wind_direction': w.windDirection,
      'wind_power': w.windPower,
      'humidity': w.humidity,
      'temp_max': w.tempMax,
      'temp_min': w.tempMin,
      'forecast': w.forecast
          .map((f) => {
                'date': f.date,
                'week': f.week,
                'temp_max': f.tempMax,
                'temp_min': f.tempMin,
                'weather_day': f.weatherDay,
              })
          .toList(),
    };
  }

  Future<List<GradeItem>> _loadLocalGrades() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_gradesKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List<dynamic>;
        return list
            .whereType<Map<String, dynamic>>()
            .map((e) => GradeItem.fromJson(e))
            .toList();
      }
    } catch (_) {}
    // 无本地真实成绩时返回空列表，绝不展示/落盘伪造的示例成绩。
    return const [];
  }

  Future<void> _saveLocalGrades(List<GradeItem> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = data
          .map((g) => {
                'courseName': g.courseName,
                'score': g.score,
                'credit': g.credit,
                'gradePoint': g.gradePoint,
                'term': g.term,
              })
          .toList();
      await prefs.setString(_gradesKey, jsonEncode(list));
    } catch (_) {}
  }

  Future<List<ExamItem>> _loadLocalExams() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_examsKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List<dynamic>;
        return list
            .whereType<Map<String, dynamic>>()
            .map((e) => ExamItem.fromJson(e))
            .toList();
      }
    } catch (_) {}
    // 无本地真实考试数据时返回空列表，绝不展示/落盘伪造的示例考试。
    return const [];
  }

  Future<void> _saveLocalExams(List<ExamItem> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = data
          .map((e) => {
                'name': e.name,
                'date': e.date,
                'time': e.time,
                'weekday': e.weekday,
                'location': e.location,
              })
          .toList();
      await prefs.setString(_examsKey, jsonEncode(list));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return PagePanel(
      title: '首页',
      icon: Icons.home,
      expandChild: true,
      headerScrollProgress: widget.headerScrollProgress,
      trailing: TextButton.icon(
        onPressed: () => _showCustomizeSheet(context),
        icon: const Icon(Icons.tune, size: 18),
        label: const Text('自定义'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: GzusLayout(
              builder: (context, breakpoint) {
                final spacing =
                    breakpoint == GzusBreakpoint.compact ? 10.0 : 12.0;
                final visible = _moduleOrder
                    .where((id) => !_hiddenModules.contains(id))
                    .where(
                      (id) =>
                          _moreModulesExpanded ||
                          _primaryModuleIds.contains(id),
                    )
                    .toList();
                final items = visible.map((id) {
                  final size = _sizeFor(id);
                  return _HomeLayoutItem(
                    id: id,
                    size: size,
                    child: _homeModuleFor(id, size),
                  );
                }).toList();
                ListView buildList() => ListView(
                      clipBehavior: Clip.none,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 24),
                      children: _buildHomeBentoGrid(
                        items: items,
                        spacing: spacing,
                        compact: breakpoint == GzusBreakpoint.compact,
                      )..add(
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Center(
                              child: FilledButton.tonalIcon(
                                key: const ValueKey('home-more-modules-toggle'),
                                onPressed: () async {
                                  final next = !_moreModulesExpanded;
                                  await HomePreferences.saveMoreModulesExpanded(
                                      next);
                                  if (mounted) {
                                    setState(() => _moreModulesExpanded = next);
                                  }
                                  if (next) {
                                    unawaited(_loadMoreModuleData());
                                  }
                                },
                                icon: Icon(
                                  _moreModulesExpanded
                                      ? Icons.keyboard_arrow_up
                                      : Icons.keyboard_arrow_down,
                                ),
                                label: Text(
                                  _moreModulesExpanded ? '收起更多模块' : '更多模块',
                                ),
                              ),
                            ),
                          ),
                        ),
                    );
                return RefreshIndicator(
                  onRefresh: _refreshDashboard,
                  child: buildList(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _updateHomeWidget() async {
    try {
      final results = await Future.wait([
        _infoFuture,
        _scheduleFuture,
        _ecardFuture,
        _progressFuture,
        _gradesFuture,
        _examsFuture,
      ].map((future) =>
          future.then<Object?>((value) => value, onError: (_, __) => null)));
      final data = HomeDashboardData(
        info: results[0] as StudentInfo? ?? _fallbackStudentInfo(),
        courses: (results[1] as ScheduleResult?)?.items ?? const [],
        notices: const [],
        attendance:
            AttendanceResponse.fromJson({'status': 'empty', 'items': []}),
        credits: const [],
        ecard: results[2] as EcardSummary? ??
            EcardSummary.fromJson({'status': 'not_bound'}),
        apps: const [],
        progressOverview: results[3] as EhallProgressOverview? ??
            EhallProgressOverview.fromItems(const []),
        grades: results[4] as List<GradeItem>?,
        exams: results[5] as List<ExamItem>?,
      );
      await HomeWidgetBridge.update(
        data: data,
        currentWeek: widget.currentWeek,
        firstWeekStart: widget.firstWeekStart,
        apiBaseUrl: widget.api.baseUrl,
        sessionId: widget.api.sessionId ?? '',
        year: widget.year,
        term: widget.term,
      );
    } catch (_) {}
  }

  /// 根据模块尺寸返回应占行数（小=1，中=2，大=2）。
  int _rowSpanFor(HomeModuleSize size) {
    return switch (size) {
      HomeModuleSize.large => 2,
      HomeModuleSize.medium => 1,
      HomeModuleSize.small => 1,
    };
  }

  double _moduleHeight(HomeModuleSize size, GzusBreakpoint breakpoint) {
    final rowHeight = breakpoint == GzusBreakpoint.compact ? 170.0 : 180.0;
    return rowHeight * _rowSpanFor(size);
  }

  HomeModuleSize _sizeFor(String id) {
    return _moduleSizes[id] ?? HomePreferences.configFor(id).size;
  }

  HomeCardDensity _cardDensity(HomeModuleSize size) {
    return switch (size) {
      HomeModuleSize.large => HomeCardDensity.large,
      HomeModuleSize.medium => HomeCardDensity.medium,
      HomeModuleSize.small => HomeCardDensity.small,
    };
  }

  Widget _homeModuleFor(String id, HomeModuleSize size) {
    switch (id) {
      case 'nextClass':
        return _AsyncModuleCard<ScheduleResult>(
          future: _scheduleFuture,
          onRetry: _retryDashboard,
          title: '下一节课',
          icon: Icons.watch_later,
          density: _cardDensity(size),
          minHeight: _moduleHeight(size, context.gzusBreakpoint),
          builder: (data) {
            final timedCourses = homeTimedCourses(
              data.items,
              currentWeek: widget.currentWeek,
              firstWeekStart: widget.firstWeekStart,
            );
            final course = nextTimedCourse(timedCourses);
            void onTap() => widget.onNavigate('schedule');
            return switch (size) {
              HomeModuleSize.large => NextClassLargeCard(
                  course: course,
                  onTap: onTap,
                  key: const ValueKey('nextClass-large'),
                ),
              HomeModuleSize.medium => NextClassMediumCard(
                  course: course,
                  onTap: onTap,
                  key: const ValueKey('nextClass-medium'),
                ),
              HomeModuleSize.small => NextClassSmallCard(
                  course: course,
                  onTap: onTap,
                  key: const ValueKey('nextClass-small'),
                ),
            };
          },
        );
      case 'todayTimeline':
        return _AsyncModuleCard<ScheduleResult>(
          future: _scheduleFuture,
          onRetry: _retryDashboard,
          title: '今日时间线',
          icon: Icons.view_timeline,
          density: _cardDensity(size),
          minHeight: _moduleHeight(size, context.gzusBreakpoint),
          builder: (data) {
            final timedCourses = homeTimedCourses(
              data.items,
              currentWeek: widget.currentWeek,
              firstWeekStart: widget.firstWeekStart,
            );
            final courses = todayTimedCourses(timedCourses);
            void onTap() => widget.onNavigate('schedule');
            return switch (size) {
              HomeModuleSize.large => TodayTimelineLargeCard(
                  courses: courses,
                  onTap: onTap,
                  key: const ValueKey('todayTimeline-large'),
                ),
              HomeModuleSize.medium => TodayTimelineMediumCard(
                  courses: courses,
                  onTap: onTap,
                  key: const ValueKey('todayTimeline-medium'),
                ),
              HomeModuleSize.small => TodayTimelineSmallCard(
                  courses: courses,
                  onTap: onTap,
                  key: const ValueKey('todayTimeline-small'),
                ),
            };
          },
        );
      case 'weekGrid':
        return _AsyncModuleCard<ScheduleResult>(
          future: _scheduleFuture,
          onRetry: _retryDashboard,
          title: '周课表',
          icon: Icons.grid_view,
          density: _cardDensity(size),
          minHeight: _moduleHeight(size, context.gzusBreakpoint),
          builder: (data) {
            final courses = data.items
                .where((item) => item.occursInWeek(widget.currentWeek))
                .toList();
            void onTap() => widget.onNavigate('schedule');
            return switch (size) {
              HomeModuleSize.large => WeekGridLargeCard(
                  courses: courses,
                  onTap: onTap,
                  key: const ValueKey('weekGrid-large'),
                ),
              HomeModuleSize.medium => WeekGridMediumCard(
                  courses: courses,
                  onTap: onTap,
                  key: const ValueKey('weekGrid-medium'),
                ),
              HomeModuleSize.small => WeekGridSmallCard(
                  courses: courses,
                  onTap: onTap,
                  key: const ValueKey('weekGrid-small'),
                ),
            };
          },
        );
      case 'dailyCourses':
        return _AsyncModuleCard<ScheduleResult>(
          future: _scheduleFuture,
          onRetry: _retryDashboard,
          title: '今日课程',
          icon: Icons.format_list_bulleted,
          density: _cardDensity(size),
          minHeight: _moduleHeight(size, context.gzusBreakpoint),
          builder: (data) {
            final timedCourses = homeTimedCourses(
              data.items,
              currentWeek: widget.currentWeek,
              firstWeekStart: widget.firstWeekStart,
            );
            final courses = todayTimedCourses(timedCourses);
            void onTap() => widget.onNavigate('schedule');
            return switch (size) {
              HomeModuleSize.large => DailyCoursesLargeCard(
                  courses: courses,
                  onTap: onTap,
                  key: const ValueKey('dailyCourses-large'),
                ),
              HomeModuleSize.medium => DailyCoursesMediumCard(
                  courses: courses,
                  onTap: onTap,
                  key: const ValueKey('dailyCourses-medium'),
                ),
              HomeModuleSize.small => DailyCoursesSmallCard(
                  courses: courses,
                  onTap: onTap,
                  key: const ValueKey('dailyCourses-small'),
                ),
            };
          },
        );
      case 'utilities':
        if (hideEcardOnCurrentPlatform) return const SizedBox.shrink();
        return _AsyncModuleCard<EcardSummary>(
          future: _ecardFuture,
          onRetry: _retryDashboard,
          title: '水电费余额',
          icon: Icons.water_drop,
          density: _cardDensity(size),
          minHeight: _moduleHeight(size, context.gzusBreakpoint),
          builder: (data) {
            void onTap() => widget.onNavigate('ecard');
            return switch (size) {
              HomeModuleSize.large => UtilitiesLargeCard(
                  summary: data,
                  onTap: onTap,
                  key: const ValueKey('utilities-large'),
                ),
              HomeModuleSize.medium => UtilitiesMediumCard(
                  summary: data,
                  onTap: onTap,
                  key: const ValueKey('utilities-medium'),
                ),
              HomeModuleSize.small => UtilitiesSmallCard(
                  summary: data,
                  onTap: onTap,
                  key: const ValueKey('utilities-small'),
                ),
            };
          },
        );
      case 'progress':
        return _AsyncModuleCard<EhallProgressOverview>(
          future: _progressFuture,
          onRetry: _retryDashboard,
          title: '业务进度',
          icon: Icons.route,
          density: _cardDensity(size),
          minHeight: _moduleHeight(size, context.gzusBreakpoint),
          builder: (data) {
            void onTap() => widget.onNavigate('business');
            return switch (size) {
              HomeModuleSize.large => BusinessProgressLargeCard(
                  overview: data,
                  onTap: onTap,
                  key: const ValueKey('progress-large'),
                ),
              HomeModuleSize.medium => BusinessProgressMediumCard(
                  overview: data,
                  onTap: onTap,
                  key: const ValueKey('progress-medium'),
                ),
              HomeModuleSize.small => BusinessProgressSmallCard(
                  overview: data,
                  onTap: onTap,
                  key: const ValueKey('progress-small'),
                ),
            };
          },
        );
      case 'notifications':
        return _AsyncModuleCard<List<NoticeItem>>(
          future: _noticesFuture,
          onRetry: _retryDashboard,
          title: '最新通知',
          icon: Icons.notifications_active,
          density: _cardDensity(size),
          minHeight: _moduleHeight(size, context.gzusBreakpoint),
          builder: (data) {
            void onTap() => widget.onNavigate('notices');
            return switch (size) {
              HomeModuleSize.large => NotificationsLargeCard(
                  notices: data,
                  onTap: onTap,
                  key: const ValueKey('notifications-large'),
                ),
              HomeModuleSize.medium => NotificationsMediumCard(
                  notices: data,
                  onTap: onTap,
                  key: const ValueKey('notifications-medium'),
                ),
              HomeModuleSize.small => NotificationsSmallCard(
                  notices: data,
                  onTap: onTap,
                  key: const ValueKey('notifications-small'),
                ),
            };
          },
        );
      case 'attendance':
        return _AsyncModuleCard<AttendanceResponse>(
          future: _attendanceFuture,
          onRetry: _retryDashboard,
          title: '本月考勤统计',
          icon: Icons.fact_check,
          density: _cardDensity(size),
          minHeight: _moduleHeight(size, context.gzusBreakpoint),
          builder: (data) {
            void onTap() => widget.onNavigate('attendance');
            return switch (size) {
              HomeModuleSize.large => AttendanceLargeCard(
                  data: data,
                  onTap: onTap,
                  key: const ValueKey('attendance-large'),
                ),
              HomeModuleSize.medium => AttendanceMediumCard(
                  data: data,
                  onTap: onTap,
                  key: const ValueKey('attendance-medium'),
                ),
              HomeModuleSize.small => AttendanceSmallCard(
                  data: data,
                  onTap: onTap,
                  key: const ValueKey('attendance-small'),
                ),
            };
          },
        );
      case 'credits':
        return _AsyncModuleCard<List<CreditItem>>(
          future: _creditsFuture,
          onRetry: _retryDashboard,
          title: '学分进度',
          icon: Icons.workspace_premium,
          density: _cardDensity(size),
          minHeight: _moduleHeight(size, context.gzusBreakpoint),
          builder: (data) {
            void onTap() => widget.onNavigate('credits');
            return switch (size) {
              HomeModuleSize.large => CreditsLargeCard(
                  credits: data,
                  onTap: onTap,
                  key: const ValueKey('credits-large'),
                ),
              HomeModuleSize.medium => CreditsMediumCard(
                  credits: data,
                  onTap: onTap,
                  key: const ValueKey('credits-medium'),
                ),
              HomeModuleSize.small => CreditsSmallCard(
                  credits: data,
                  onTap: onTap,
                  key: const ValueKey('credits-small'),
                ),
            };
          },
        );
      case 'weather':
        return _AsyncModuleCard<WeatherData?>(
          future: _weatherFuture,
          onRetry: _retryDashboard,
          title: '今日天气',
          icon: Icons.wb_sunny,
          density: _cardDensity(size),
          allowNull: true,
          minHeight: _moduleHeight(size, context.gzusBreakpoint),
          builder: (data) => switch (size) {
            HomeModuleSize.large => WeatherLargeCard(
                weather: data,
                key: const ValueKey('weather-large'),
              ),
            HomeModuleSize.medium => WeatherMediumCard(
                weather: data,
                key: const ValueKey('weather-medium'),
              ),
            HomeModuleSize.small => WeatherSmallCard(
                weather: data,
                key: const ValueKey('weather-small'),
              ),
          },
        );
      case 'grades':
        return _AsyncModuleCard<List<GradeItem>>(
          future: _gradesFuture,
          onRetry: _retryDashboard,
          title: '本学期成绩',
          icon: Icons.school,
          density: _cardDensity(size),
          minHeight: _moduleHeight(size, context.gzusBreakpoint),
          builder: (data) {
            void onTap() => widget.onNavigate('grades');
            return switch (size) {
              HomeModuleSize.large => GradesLargeCard(
                  grades: data,
                  onTap: onTap,
                  key: const ValueKey('grades-large'),
                ),
              HomeModuleSize.medium => GradesMediumCard(
                  grades: data,
                  onTap: onTap,
                  key: const ValueKey('grades-medium'),
                ),
              HomeModuleSize.small => GradesSmallCard(
                  grades: data,
                  onTap: onTap,
                  key: const ValueKey('grades-small'),
                ),
            };
          },
        );
      case 'examCountdown':
        return _AsyncModuleCard<List<ExamItem>>(
          future: _examsFuture,
          onRetry: _retryDashboard,
          title: '考试倒计时',
          icon: Icons.timer,
          density: _cardDensity(size),
          minHeight: _moduleHeight(size, context.gzusBreakpoint),
          builder: (data) {
            void onTap() => widget.onNavigate('exams');
            return switch (size) {
              HomeModuleSize.large => ExamCountdownLargeCard(
                  exams: data,
                  onTap: onTap,
                  key: const ValueKey('examCountdown-large'),
                ),
              HomeModuleSize.medium => ExamCountdownMediumCard(
                  exams: data,
                  onTap: onTap,
                  key: const ValueKey('examCountdown-medium'),
                ),
              HomeModuleSize.small => ExamCountdownSmallCard(
                  exams: data,
                  onTap: onTap,
                  key: const ValueKey('examCountdown-small'),
                ),
            };
          },
        );
      case 'profile':
        return _AsyncModuleCard<StudentInfo>(
          future: _infoFuture,
          onRetry: _retryDashboard,
          title: '个人资料',
          icon: Icons.badge,
          density: _cardDensity(size),
          minHeight: _moduleHeight(size, context.gzusBreakpoint),
          builder: (data) {
            void onTap() => widget.onNavigate('info');
            return switch (size) {
              HomeModuleSize.large => ProfileLargeCard(
                  info: data,
                  onTap: onTap,
                  key: const ValueKey('profile-large'),
                ),
              HomeModuleSize.medium => ProfileMediumCard(
                  info: data,
                  onTap: onTap,
                  key: const ValueKey('profile-medium'),
                ),
              HomeModuleSize.small => ProfileSmallCard(
                  info: data,
                  onTap: onTap,
                  key: const ValueKey('profile-small'),
                ),
            };
          },
        );
      case 'apps':
        return _AsyncModuleCard<List<EhallApplicationItem>>(
          future: _appsFuture,
          onRetry: _retryDashboard,
          title: '常用服务',
          icon: Icons.apps,
          density: _cardDensity(size),
          minHeight: _moduleHeight(size, context.gzusBreakpoint),
          builder: (data) {
            void onTap() => widget.onNavigate('applications');
            return switch (size) {
              HomeModuleSize.large => AppsLargeCard(
                  apps: data,
                  onTap: onTap,
                  key: const ValueKey('apps-large'),
                ),
              HomeModuleSize.medium => AppsMediumCard(
                  apps: data,
                  onTap: onTap,
                  key: const ValueKey('apps-medium'),
                ),
              HomeModuleSize.small => AppsSmallCard(
                  apps: data,
                  onTap: onTap,
                  key: const ValueKey('apps-small'),
                ),
            };
          },
        );
      default:
        return const SizedBox.shrink();
    }
  }

  void _showCustomizeSheet(BuildContext context) {
    var order = [..._moduleOrder];
    var hidden = {..._hiddenModules};
    var sizes = {..._moduleSizes};
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, localSetState) {
          Future<void> persist() async {
            await HomePreferences.save(
              order: order,
              hidden: hidden,
              sizes: sizes,
            );
            if (mounted) {
              setState(() {
                _moduleOrder = [...order];
                _hiddenModules = {...hidden};
                _moduleSizes = {...sizes};
              });
            }
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '自定义首页',
                          style: GzusTextStyles.sectionTitle(context),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          await HomePreferences.reset();
                          order = HomePreferences.defaultModuleIds;
                          hidden = {};
                          sizes = {};
                          await persist();
                          await HomePreferences.saveMoreModulesExpanded(false);
                          if (mounted) {
                            setState(() => _moreModulesExpanded = false);
                          }
                          localSetState(() {});
                        },
                        child: const Text('恢复默认'),
                      ),
                    ],
                  ),
                  const SizedBox(height: GzusSpacing.s),
                  Expanded(
                    child: ReorderableListView.builder(
                      itemCount: order.length,
                      onReorderItem: (oldIndex, newIndex) async {
                        final id = order.removeAt(oldIndex);
                        order.insert(newIndex, id);
                        await persist();
                        localSetState(() {});
                      },
                      itemBuilder: (context, index) {
                        final id = order[index];
                        final size =
                            sizes[id] ?? HomePreferences.configFor(id).size;
                        final config =
                            HomePreferences.configFor(id, overrideSize: size);
                        final visible = !hidden.contains(id);
                        return ListTile(
                          key: ValueKey(id),
                          leading: Icon(config.icon),
                          title: Text(config.label),
                          subtitle: Text(_sizeLabel(size)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _SizeChip(
                                label: '大',
                                selected: size == HomeModuleSize.large,
                                onSelected: () async {
                                  sizes[id] = HomeModuleSize.large;
                                  await persist();
                                  localSetState(() {});
                                },
                              ),
                              const SizedBox(width: 4),
                              _SizeChip(
                                label: '中',
                                selected: size == HomeModuleSize.medium,
                                onSelected: () async {
                                  sizes[id] = HomeModuleSize.medium;
                                  await persist();
                                  localSetState(() {});
                                },
                              ),
                              const SizedBox(width: 4),
                              _SizeChip(
                                label: '小',
                                selected: size == HomeModuleSize.small,
                                onSelected: () async {
                                  sizes[id] = HomeModuleSize.small;
                                  await persist();
                                  localSetState(() {});
                                },
                              ),
                              const SizedBox(width: 8),
                              Switch(
                                value: visible,
                                onChanged: (value) async {
                                  if (value) {
                                    hidden.remove(id);
                                  } else {
                                    hidden.add(id);
                                  }
                                  await persist();
                                  localSetState(() {});
                                },
                              ),
                            ],
                          ),
                        );
                      },
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
}

/// 首页模块在列表中的布局元数据。
String _sizeLabel(HomeModuleSize size) {
  return switch (size) {
    HomeModuleSize.large => '大模块',
    HomeModuleSize.medium => '中模块',
    HomeModuleSize.small => '小模块',
  };
}

class _SizeChip extends StatelessWidget {
  const _SizeChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected ? cs.primary : cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onSelected,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? cs.onPrimary : cs.onSurface,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// 首页模块在列表中的布局元数据。
class _HomeLayoutItem {
  const _HomeLayoutItem({
    required this.id,
    required this.size,
    required this.child,
  });

  final String id;
  final HomeModuleSize size;
  final Widget child;
}

/// 将模块排入真正的二维网格；每个单元只可被一个模块占用。
List<Widget> _buildHomeBentoGrid({
  required List<_HomeLayoutItem> items,
  required double spacing,
  required bool compact,
}) {
  return [
    _HomeBentoGrid(items: items, spacing: spacing, compact: compact),
    const SizedBox(height: 24),
  ];
}

class _HomeBentoGrid extends StatelessWidget {
  const _HomeBentoGrid({
    required this.items,
    required this.spacing,
    required this.compact,
  });

  final List<_HomeLayoutItem> items;
  final double spacing;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final columns = compact ? 2 : 4;
    final unitHeight = compact ? 170.0 : 180.0;
    final placements = _placeHomeModules(items, columns, compact);
    if (placements.isEmpty) {
      return const SizedBox.shrink();
    }
    final rows = placements.fold<int>(
      0,
      (maxRows, item) =>
          maxRows > item.row + item.rowSpan ? maxRows : item.row + item.rowSpan,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final unitWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return SizedBox(
          height: rows * unitHeight + (rows - 1) * spacing,
          child: Stack(
            children: [
              for (final placement in placements)
                Positioned(
                  left: placement.column * (unitWidth + spacing),
                  top: placement.row * (unitHeight + spacing),
                  width: placement.columnSpan * unitWidth +
                      (placement.columnSpan - 1) * spacing,
                  height: placement.rowSpan * unitHeight +
                      (placement.rowSpan - 1) * spacing,
                  child: placement.item.child,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _HomeModulePlacement {
  const _HomeModulePlacement({
    required this.item,
    required this.column,
    required this.row,
    required this.columnSpan,
    required this.rowSpan,
  });

  final _HomeLayoutItem item;
  final int column;
  final int row;
  final int columnSpan;
  final int rowSpan;
}

List<_HomeModulePlacement> _placeHomeModules(
  List<_HomeLayoutItem> items,
  int columns,
  bool compact,
) {
  final occupied = <List<bool>>[];
  final result = <_HomeModulePlacement>[];

  void ensureRows(int count) {
    while (occupied.length < count) {
      occupied.add(List<bool>.filled(columns, false));
    }
  }

  bool fits(int row, int column, int columnSpan, int rowSpan) {
    if (column + columnSpan > columns) return false;
    ensureRows(row + rowSpan);
    for (var y = row; y < row + rowSpan; y++) {
      for (var x = column; x < column + columnSpan; x++) {
        if (occupied[y][x]) return false;
      }
    }
    return true;
  }

  for (final item in items) {
    final (columnSpan, rowSpan) = switch (item.size) {
      HomeModuleSize.small => (1, 1),
      HomeModuleSize.medium => (2, 1),
      HomeModuleSize.large => (compact ? 2 : 4, 2),
    };
    var row = 0;
    var column = 0;
    while (!fits(row, column, columnSpan, rowSpan)) {
      column++;
      if (column >= columns) {
        column = 0;
        row++;
      }
    }
    for (var y = row; y < row + rowSpan; y++) {
      for (var x = column; x < column + columnSpan; x++) {
        occupied[y][x] = true;
      }
    }
    result.add(_HomeModulePlacement(
      item: item,
      column: column,
      row: row,
      columnSpan: columnSpan,
      rowSpan: rowSpan,
    ));
  }
  return result;
}

String _two(int value) => value.toString().padLeft(2, '0');

class HomeWidgetBridge {
  static const _channel = MethodChannel('cn.gzus.pro/home_widgets');
  static ValueChanged<String?>? _onLaunch;

  static void setLaunchHandler(ValueChanged<String?>? handler) {
    if (kIsWeb) return;
    _onLaunch = handler;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'launch') return null;
      final args = call.arguments;
      final tab = args is Map ? args['tab']?.toString() : null;
      _onLaunch?.call(tab);
      return true;
    });
  }

  static Future<void> update({
    required HomeDashboardData data,
    required int currentWeek,
    required DateTime firstWeekStart,
    required String apiBaseUrl,
    required String sessionId,
    required int year,
    required int term,
  }) async {
    if (kIsWeb) return;
    final timedCourses = homeTimedCourses(
      data.courses,
      currentWeek: currentWeek,
      firstWeekStart: firstWeekStart,
    );
    final today = todayTimedCourses(timedCourses);
    final next = nextTimedCourse(timedCourses);
    final nextLocation = _notBlank(next?.course.classroom) ?? '-';
    final utilityDetail = _cleanJoin([
      _notBlank(data.ecard.updatedAt) == null
          ? null
          : '更新 ${data.ecard.updatedAt}',
      data.ecard.isBound ? '点击查看生活缴费' : '点击绑定宿舍',
    ], ' · ');
    final progress = data.progress.isEmpty ? null : data.progress.first;
    final progressMeta = progress == null
        ? '办事大厅'
        : _cleanJoin([
            _notBlank(progress.statusLabel),
            _notBlank(progress.currentNode),
            _notBlank(progress.category),
          ], ' · ');
    final upcomingExams = _widgetUpcomingExams(data.exams ?? const []);
    final validGrades = (data.grades ?? const [])
        .where((grade) => int.tryParse(grade.score ?? '') != null)
        .toList()
      ..sort((a, b) => int.parse(b.score!).compareTo(int.parse(a.score!)));
    final gradeStats = _widgetGradeStats(validGrades);
    try {
      await _channel.invokeMethod('update', {
        'nextTitle': next?.course.name ?? '暂无下一节课',
        'nextMeta':
            next == null ? '今天没有更多课程' : '${next.timeText} · $nextLocation',
        'nextDetail': next == null
            ? '点击查看课表'
            : _cleanJoin([
                _notBlank(next.course.teacher),
                next.isOngoing ? '进行中' : '待开始',
              ], ' · '),
        'nextClassroom': next?.course.classroom ?? '',
        'nextTeacher': next?.course.teacher ?? '',
        'nextStatus':
            next == null ? 'none' : (next.isOngoing ? 'ongoing' : 'upcoming'),
        'nextTime': next?.timeText ?? '',
        'nextStartEpochMillis': next?.start.millisecondsSinceEpoch ?? 0,
        'nextEndEpochMillis': next?.end.millisecondsSinceEpoch ?? 0,
        'widgetUpdatedAtEpochMillis': DateTime.now().millisecondsSinceEpoch,
        'todayTitle': today.isEmpty ? '今日无课' : '今日 ${today.length} 节课',
        'todayMeta': '第$currentWeek周 · ${today.length} 节课',
        'todayItems': today
            .take(4)
            .map((item) => '${item.timeText} ${item.course.name}')
            .toList(),
        'todayCoursesJson': jsonEncode(today
            .map((item) => {
                  'time': '${_two(item.start.hour)}:${_two(item.start.minute)}',
                  'name': item.course.name,
                  'info': [item.course.classroom, item.course.teacher]
                      .where((s) => s != null && s.isNotEmpty)
                      .join(' · '),
                  'ongoing': item.isOngoing,
                })
            .toList()),
        'utilityTitle':
            data.ecard.isBound ? (data.ecard.roomDisplay ?? '生活缴费') : '未绑定宿舍',
        'utilityMeta':
            '电 ${data.ecard.powerText ?? '-'} · 冷水 ${data.ecard.coldWaterText ?? '-'} · 热水 ${data.ecard.hotWaterText ?? '-'}',
        'utilityDetail': utilityDetail,
        'utilityColdWater': data.ecard.coldWaterText ?? '-',
        'utilityHotWater': data.ecard.hotWaterText ?? '-',
        'utilityElectricity': data.ecard.powerText ?? '-',
        'utilityRoomInfo': _cleanJoin([
          data.ecard.roomDisplay,
          _notBlank(data.ecard.updatedAt) == null
              ? null
              : '更新 ${data.ecard.updatedAt}',
        ], ' · '),
        'progressTitle': progress == null ? '暂无业务进度' : progress.title,
        'progressMeta': progressMeta,
        'progressDetail': progress == null
            ? '点击查看办事大厅'
            : _cleanJoin([
                progress.progress == null ? null : '${progress.progress}%',
                _notBlank(progress.date),
                _notBlank(progress.summary),
              ], ' · '),
        'progressItemsJson': jsonEncode(data.progress
            .map((item) => {
                  'title': item.title,
                  'status': item.statusLabel,
                  'node': item.currentNode ?? '',
                  'progress': item.progress?.toString() ?? '',
                  'date': item.date ?? '',
                })
            .toList()),
        'examCount': '${upcomingExams.length}',
        'examItemsJson': jsonEncode(upcomingExams.take(3).map((exam) {
          final days = _widgetExamCountdown(exam);
          return {
            'name': exam.name,
            'date': exam.date,
            'time': exam.timeDisplay,
            'location': exam.location ?? '',
            'days': days,
            'urgent': days >= 0 && days <= 3,
          };
        }).toList()),
        'gradeGpa': gradeStats.gpa,
        'gradeAverage': gradeStats.average,
        'gradeCount': '${gradeStats.count}',
        'gradeItemsJson': jsonEncode(validGrades
            .take(2)
            .map((grade) => {
                  'name': grade.courseName,
                  'score': grade.score ?? '-',
                  'credit': grade.credit ?? '',
                  'gpa': _widgetGpa(grade.score).toStringAsFixed(1),
                })
            .toList()),
        'utilityIsBound': data.ecard.isBound,
        'utilityLowPower': data.ecard.isLowPower,
        'widgetApiBaseUrl': apiBaseUrl,
        'widgetSessionId': sessionId,
        'widgetYear': year,
        'widgetTerm': term,
        'widgetCurrentWeek': currentWeek,
      }).timeout(const Duration(milliseconds: 300));
    } catch (_) {}
  }

  static Future<String?> consumeInitialTab() async {
    if (kIsWeb) return null;
    try {
      return await _channel
          .invokeMethod<String>('consumeInitialTab')
          .timeout(const Duration(milliseconds: 300));
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearRefreshConfiguration() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('clearRefreshConfiguration');
    } on PlatformException {
      return;
    }
  }

  static Future<void> replaceRefreshSession({
    required String apiBaseUrl,
    required String sessionId,
  }) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('replaceRefreshSession', {
        'widgetApiBaseUrl': apiBaseUrl,
        'widgetSessionId': sessionId,
      });
    } on PlatformException {
      return;
    }
  }

  static String? _notBlank(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static String _cleanJoin(Iterable<String?> values, String separator) {
    return values
        .whereType<String>()
        .where((item) => item.isNotEmpty)
        .join(separator);
  }
}

({String gpa, String average, int count}) _widgetGradeStats(
  List<GradeItem> grades,
) {
  if (grades.isEmpty) return (gpa: '0.00', average: '0.0', count: 0);
  final scores = grades.map((grade) => int.parse(grade.score!)).toList();
  final gpa =
      scores.map((score) => _widgetGpa('$score')).reduce((a, b) => a + b) /
          scores.length;
  final average = scores.reduce((a, b) => a + b) / scores.length;
  return (
    gpa: gpa.toStringAsFixed(2),
    average: average.toStringAsFixed(1),
    count: scores.length,
  );
}

double _widgetGpa(String? scoreText) {
  final score = int.tryParse(scoreText ?? '') ?? 0;
  if (score >= 90) return 4.0;
  if (score >= 85) return 3.7;
  if (score >= 82) return 3.3;
  if (score >= 78) return 3.0;
  if (score >= 75) return 2.7;
  if (score >= 72) return 2.3;
  if (score >= 68) return 2.0;
  if (score >= 66) return 1.7;
  if (score >= 64) return 1.3;
  if (score >= 60) return 1.0;
  return 0;
}

DateTime? _widgetExamDate(ExamItem exam) {
  return examDateTime(exam.date) ?? examDateTime(exam.time);
}

int _widgetExamCountdown(ExamItem exam) {
  final target = _widgetExamDate(exam);
  if (target == null) return 9999;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return target.difference(today).inDays;
}

List<ExamItem> _widgetUpcomingExams(List<ExamItem> exams) {
  final upcoming = exams.where((exam) {
    final days = _widgetExamCountdown(exam);
    return days >= -7 || days == 9999;
  }).toList();
  upcoming.sort((a, b) {
    final left = _widgetExamCountdown(a);
    final right = _widgetExamCountdown(b);
    if (left == 9999) return right == 9999 ? 0 : 1;
    if (right == 9999) return -1;
    return left.compareTo(right);
  });
  return upcoming;
}

class NotificationOpenBridge {
  static ValueChanged<String>? _onOpenTab;

  static void setOpenTabHandler(ValueChanged<String>? handler) {
    _onOpenTab = handler;
  }

  static void openTab(String tabId) {
    _onOpenTab?.call(tabId);
  }
}

/// 分模块异步加载的卡片包装器：首次加载显示骨架屏；
/// 静默刷新（future 更换）期间保留旧内容，不闪骨架屏。
class _AsyncModuleCard<T> extends StatefulWidget {
  const _AsyncModuleCard({
    required this.future,
    required this.onRetry,
    required this.title,
    required this.icon,
    required this.density,
    required this.builder,
    this.allowNull = false,
    this.minHeight = 196,
  });

  final Future<T> future;
  final VoidCallback onRetry;
  final String title;
  final IconData icon;
  final HomeCardDensity density;
  final Widget Function(T data) builder;
  final bool allowNull;
  final double minHeight;

  @override
  State<_AsyncModuleCard<T>> createState() => _AsyncModuleCardState<T>();
}

class _AsyncModuleCardState<T> extends State<_AsyncModuleCard<T>> {
  T? _lastData;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: widget.future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          if (_lastData != null) {
            // 静默刷新中：展示旧数据，不闪骨架屏
            return widget.builder(_lastData as T);
          }
          return HomeCardShell(
            title: widget.title,
            icon: widget.icon,
            density: widget.density,
            child: const _ShimmerPlaceholder(),
          );
        }
        if (snapshot.hasError) {
          if (_lastData != null) {
            // 静默刷新失败：保留旧数据
            return widget.builder(_lastData as T);
          }
          return HomeCardShell(
            title: widget.title,
            icon: widget.icon,
            density: widget.density,
            child: _AsyncModuleError(
              message: snapshot.error.toString(),
              onRetry: widget.onRetry,
            ),
          );
        }
        final data = snapshot.data;
        if (!widget.allowNull && data == null) {
          if (_lastData != null) {
            return widget.builder(_lastData as T);
          }
          return HomeCardShell(
            title: widget.title,
            icon: widget.icon,
            density: widget.density,
            child: _AsyncModuleEmpty(icon: widget.icon),
          );
        }
        _lastData = data;
        return widget.builder(data as T);
      },
    );
  }
}

/// 骨架屏占位组件
class _ShimmerPlaceholder extends StatelessWidget {
  const _ShimmerPlaceholder();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDark ? GzusColors.darkSurfaceSoft : GzusColors.surfaceSoft;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _placeholderLine(color, 0.6),
        const SizedBox(height: 10),
        _placeholderLine(color, 0.9),
        const SizedBox(height: 10),
        _placeholderLine(color, 0.4),
        const SizedBox(height: 10),
        _placeholderLine(color, 0.7),
      ],
    );
  }

  Widget _placeholderLine(Color color, double widthFactor) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      alignment: Alignment.centerLeft,
      child: Container(
        height: 14,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

/// 异步模块加载失败时的紧凑提示，适配小模块高度。
class _AsyncModuleError extends StatelessWidget {
  const _AsyncModuleError({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: cs.error, size: 22),
            const SizedBox(height: 4),
            Text(
              '加载失败',
              style: TextStyle(
                color: cs.error,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('重试', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 异步模块无数据时的紧凑提示，适配小模块高度。
class _AsyncModuleEmpty extends StatelessWidget {
  const _AsyncModuleEmpty({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: cs.onSurfaceVariant, size: 24),
          const SizedBox(height: 6),
          Text(
            '暂无数据',
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
