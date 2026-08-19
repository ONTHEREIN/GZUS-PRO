import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api_client.dart';
import '../../gzus_design.dart';
import '../../models/home_config.dart';
import '../../responsive/spacing.dart';
import '../../test_flags.dart';
import '../../schedule_utils.dart';
import '../../widgets/badges.dart';
import '../../responsive/breakpoints.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/page_panel.dart';
import '../../widgets/page_silent_refresh.dart';
import '../../widgets/grid_columns.dart';
import '../../widgets/progress.dart';
import '../../widgets/scale_tap.dart';

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
    this.loginMethod,
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
  final String? loginMethod;
  /// 登录态已知的姓名/学号，用于 me 模块缺失或失败时兜底展示，
  /// 保证首页个人信息始终与当前登录账号一致（而非空/占位）。
  final String? studentName;
  final String? studentId;

  bool get isPasswordLogin => loginMethod == 'password';

  /// 账密登录时首页隐藏的模块 id（依赖办事大厅 ehall 会话）
  static const passwordRestrictedModules = {
    'progress',
    'notifications',
    'apps',
  };

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with PageSilentRefresh<HomePage> {
  // 首页只请求一次 dashboard 快照，再派生各模块 Future，避免首屏请求风暴。
  late Future<HomeDashboardData> _dashboardFuture;
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

  @override
  void initState() {
    super.initState();
    _initFutures();
    _loadPreferences();
  }

  void _initFutures({bool forceRefresh = false}) {
    _dashboardFuture = _safeLoad(
      _loadDashboardData(forceRefresh: forceRefresh),
      _emptyDashboardData(),
    );
    _infoFuture = _dashboardFuture.then((data) => data.info);
    _scheduleFuture = _dashboardFuture.then(
      (data) => ScheduleResult(
        items: data.courses,
        raw: data.courses.map((item) => item.raw).toList(),
      ),
    );
    _noticesFuture = _dashboardFuture.then((data) => data.notices);
    _attendanceFuture = _dashboardFuture.then((data) => data.attendance);
    _creditsFuture = _dashboardFuture.then((data) => data.credits);
    _ecardFuture = _dashboardFuture.then((data) => data.ecard);
    _appsFuture = _dashboardFuture.then((data) => data.apps);
    _progressFuture = _dashboardFuture.then((data) => data.progressOverview);
    _weatherFuture = _dashboardFuture.then((data) => data.weather);
    _gradesFuture = _dashboardFuture.then((data) async {
      if (data.grades != null && data.grades!.isNotEmpty) return data.grades!;
      return _loadLocalGrades();
    });
    _examsFuture = _dashboardFuture.then((data) async {
      if (data.exams != null && data.exams!.isNotEmpty) return data.exams!;
      return _loadLocalExams();
    });
    unawaited(_dashboardFuture.then((_) => _updateHomeWidget()));
  }

  @override
  void silentRefresh() {
    if (!mounted) return;
    setState(() => _initFutures());
  }

  Future<HomeDashboardData> _loadDashboardData({
    bool forceRefresh = false,
  }) async {
    final result = await widget.api.dashboard(
      year: widget.year,
      term: widget.term,
      week: widget.currentWeek,
      forceRefresh: forceRefresh,
    );
    final snapshot = result.data;

    final info = snapshot.module('me').objectData();
    final schedule = snapshot.module('schedule').listData();
    final notices = snapshot.module('notices').listData();
    final attendance = snapshot.module('attendance').objectData();
    final credits = snapshot.module('credits').listData();
    final ecard = snapshot.module('ecard').objectData();
    final apps = snapshot.module('apps').listData();
    final progress = snapshot.module('progress').objectData();
    final weather = snapshot.module('weather').objectData();
    final grades = snapshot.module('grades').listData();
    final exams = snapshot.module('exams').listData();

    final parsedGrades = grades.map((e) => GradeItem.fromJson(e)).toList();
    final parsedExams = exams.map((e) => ExamItem.fromJson(e)).toList();
    if (parsedGrades.isNotEmpty) unawaited(_saveLocalGrades(parsedGrades));
    if (parsedExams.isNotEmpty) unawaited(_saveLocalExams(parsedExams));

    return HomeDashboardData(
      info: info != null && (info['name'] as String? ?? '').isNotEmpty
          ? StudentInfo.fromJson(info)
          : _fallbackStudentInfo(),
      courses: schedule.map((e) => ScheduleCourse.fromJson(e)).toList(),
      notices: notices.map((e) => NoticeItem.fromJson(e)).toList(),
      attendance: attendance != null
          ? AttendanceResponse.fromJson(attendance)
          : AttendanceResponse.fromJson({'status': 'empty', 'items': []}),
      credits: credits.map((e) => CreditItem.fromJson(e)).toList(),
      ecard: ecard != null
          ? EcardSummary.fromJson(ecard)
          : EcardSummary.fromJson({'status': 'not_bound'}),
      apps: widget.isPasswordLogin
          ? const <EhallApplicationItem>[]
          : apps.map((e) => EhallApplicationItem.fromJson(e)).toList(),
      progressOverview: widget.isPasswordLogin
          ? EhallProgressOverview.fromItems(const <EhallProgressItem>[])
          : progress != null
              ? EhallProgressOverview.fromJson(progress)
              : EhallProgressOverview.fromItems(const <EhallProgressItem>[]),
      weather: weather != null
          ? WeatherData.fromJson(weather)
          : await _loadLocalWeather(),
      grades: parsedGrades,
      exams: parsedExams,
    );
  }

  HomeDashboardData _emptyDashboardData() => HomeDashboardData(
        info: _fallbackStudentInfo(),
        courses: const [],
        notices: const [],
        attendance:
            AttendanceResponse.fromJson({'status': 'empty', 'items': []}),
        credits: const [],
        ecard: EcardSummary.fromJson({'status': 'not_bound'}),
        apps: const [],
        progressOverview:
            EhallProgressOverview.fromItems(const <EhallProgressItem>[]),
        weather: null,
        grades: const [],
        exams: const [],
      );

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
        oldWidget.firstWeekStart != widget.firstWeekStart ||
        oldWidget.loginMethod != widget.loginMethod) {
      _initFutures();
    }
  }

  Future<void> _loadPreferences() async {
    final order = await HomePreferences.loadOrder();
    final hidden = await HomePreferences.loadHidden();
    if (mounted) {
      setState(() {
        _moduleOrder = order;
        _hiddenModules = hidden;
      });
    }
  }

  Future<T> _safeLoad<T>(Future<T> future, T fallback) async {
    try {
      return await future;
    } catch (_) {
      return fallback;
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
                final spacing = breakpoint == GzusBreakpoint.compact ? 10.0 : 12.0;
                final visible = _moduleOrder
                    .where((id) => !_hiddenModules.contains(id))
                    .where((id) =>
                        !widget.isPasswordLogin ||
                        !HomePage.passwordRestrictedModules.contains(id))
                    .toList();
                final items = visible
                    .map((id) => _HomeLayoutItem(
                          id: id,
                          size: HomePreferences.configFor(id).size,
                          child: _homeModuleFor(id),
                        ))
                    .toList();
                return RefreshIndicator(
                  onRefresh: () async {
                    setState(() => _initFutures(forceRefresh: true));
                    await _dashboardFuture
                        .catchError((_) => _emptyDashboardData());
                    unawaited(_updateHomeWidget());
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 24),
                    children: _buildHomeLayoutRows(
                      items: items,
                      breakpoint: breakpoint,
                      spacing: spacing,
                    ),
                  ),
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
        _noticesFuture,
        _attendanceFuture,
        _creditsFuture,
        _ecardFuture,
        _appsFuture,
        _progressFuture,
        _weatherFuture,
        _gradesFuture,
        _examsFuture,
      ]).catchError((_) => List.filled(11, null));
      final data = HomeDashboardData(
        info: results[0] as StudentInfo? ?? _fallbackStudentInfo(),
        courses: (results[1] as ScheduleResult?)?.items ?? const [],
        notices: results[2] as List<NoticeItem>? ?? const [],
        attendance: results[3] as AttendanceResponse? ??
            AttendanceResponse.fromJson({'status': 'empty', 'items': []}),
        credits: results[4] as List<CreditItem>? ?? const [],
        ecard: results[5] as EcardSummary? ??
            EcardSummary.fromJson({'status': 'not_bound'}),
        apps: results[6] as List<EhallApplicationItem>? ?? const [],
        progressOverview: results[7] as EhallProgressOverview? ??
            EhallProgressOverview.fromItems(const []),
        weather: results[8] as WeatherData?,
        grades: results[9] as List<GradeItem>?,
        exams: results[10] as List<ExamItem>?,
      );
      await HomeWidgetBridge.update(
        data: data,
        currentWeek: widget.currentWeek,
        firstWeekStart: widget.firstWeekStart,
      );
    } catch (_) {}
  }

  Color _moduleColor(String id) {
    return switch (id) {
      'nextClass' || 'todayTimeline' || 'weekGrid' || 'dailyCourses' =>
        GzusColors.moduleSchedule,
      'grades' => GzusColors.moduleGrades,
      'attendance' => GzusColors.moduleAttendance,
      'utilities' => GzusColors.moduleEcard,
      'examCountdown' => GzusColors.moduleExams,
      'notifications' => GzusColors.moduleNotices,
      'apps' || 'progress' => GzusColors.moduleApplications,
      'credits' => GzusColors.moduleCredits,
      _ => GzusColors.blue,
    };
  }

  double _moduleMinHeight(String id) {
    return switch (HomePreferences.configFor(id).size) {
      HomeModuleSize.featured => 196,
      HomeModuleSize.medium => 180,
      HomeModuleSize.small => 120,
    };
  }

  Widget _homeModuleFor(String id) {
    final color = _moduleColor(id);
    switch (id) {
      case 'nextClass':
        return _AsyncModuleCard<ScheduleResult>(
          future: _scheduleFuture,
          title: '下一节课',
          icon: Icons.watch_later,
          accentColor: color,
          minHeight: _moduleMinHeight(id),
          builder: (data) {
            final timedCourses = _homeTimedCourses(
              data.items,
              currentWeek: widget.currentWeek,
              firstWeekStart: widget.firstWeekStart,
            );
            return _NextClassHomeCard(
              course: _nextTimedCourse(timedCourses),
              onTap: () => widget.onNavigate('schedule'),
            );
          },
        );
      case 'todayTimeline':
        return _AsyncModuleCard<ScheduleResult>(
          future: _scheduleFuture,
          title: '今日时间线',
          icon: Icons.view_timeline,
          accentColor: color,
          minHeight: _moduleMinHeight(id),
          builder: (data) {
            final timedCourses = _homeTimedCourses(
              data.items,
              currentWeek: widget.currentWeek,
              firstWeekStart: widget.firstWeekStart,
            );
            return _TodayTimelineHomeCard(
                courses: _todayTimedCourses(timedCourses));
          },
        );
      case 'weekGrid':
        return _AsyncModuleCard<ScheduleResult>(
          future: _scheduleFuture,
          title: '周课表',
          icon: Icons.grid_view,
          accentColor: color,
          minHeight: _moduleMinHeight(id),
          builder: (data) {
            return _WeekGridHomeCard(
              courses: data.items
                  .where((item) => item.occursInWeek(widget.currentWeek))
                  .toList(),
            );
          },
        );
      case 'dailyCourses':
        return _AsyncModuleCard<ScheduleResult>(
          future: _scheduleFuture,
          title: '今日课程',
          icon: Icons.format_list_bulleted,
          accentColor: color,
          minHeight: _moduleMinHeight(id),
          builder: (data) {
            final timedCourses = _homeTimedCourses(
              data.items,
              currentWeek: widget.currentWeek,
              firstWeekStart: widget.firstWeekStart,
            );
            return _DailyCoursesHomeCard(
                courses: _todayTimedCourses(timedCourses));
          },
        );
      case 'utilities':
        if (hideEcardOnCurrentPlatform) return const SizedBox.shrink();
        return _AsyncModuleCard<EcardSummary>(
          future: _ecardFuture,
          title: '水电余额',
          icon: Icons.water_drop,
          accentColor: color,
          minHeight: _moduleMinHeight(id),
          builder: (data) => _UtilitiesHomeCard(
              summary: data, onTap: () => widget.onNavigate('ecard')),
        );
      case 'progress':
        return _AsyncModuleCard<EhallProgressOverview>(
          future: _progressFuture,
          title: '业务进度',
          icon: Icons.route,
          accentColor: color,
          minHeight: _moduleMinHeight(id),
          builder: (data) => _BusinessProgressHomeCard(
              overview: data, onTap: () => widget.onNavigate('business')),
        );
      case 'notifications':
        return _AsyncModuleCard<List<NoticeItem>>(
          future: _noticesFuture,
          title: '通知摘要',
          icon: Icons.notifications_active,
          accentColor: color,
          minHeight: _moduleMinHeight(id),
          builder: (data) => _NotificationsHomeCard(
              notices: data, onTap: () => widget.onNavigate('notices')),
        );
      case 'attendance':
        return _AsyncModuleCard<AttendanceResponse>(
          future: _attendanceFuture,
          title: '考勤统计',
          icon: Icons.fact_check,
          accentColor: color,
          minHeight: _moduleMinHeight(id),
          builder: (data) => _AttendanceHomeCard(
              data: data, onTap: () => widget.onNavigate('attendance')),
        );
      case 'credits':
        return _AsyncModuleCard<List<CreditItem>>(
          future: _creditsFuture,
          title: '学分进度',
          icon: Icons.workspace_premium,
          accentColor: color,
          minHeight: _moduleMinHeight(id),
          builder: (data) => _CreditsHomeCard(
              credits: data, onTap: () => widget.onNavigate('credits')),
        );
      case 'weather':
        return _AsyncModuleCard<WeatherData?>(
          future: _weatherFuture,
          title: '今日天气',
          icon: Icons.wb_sunny,
          allowNull: true,
          accentColor: color,
          minHeight: _moduleMinHeight(id),
          builder: (data) => _WeatherHomeCard(weather: data),
        );
      case 'grades':
        return _AsyncModuleCard<List<GradeItem>>(
          future: _gradesFuture,
          title: '本学期成绩',
          icon: Icons.school,
          accentColor: color,
          minHeight: _moduleMinHeight(id),
          builder: (data) => _GradesHomeCard(
              grades: data, onTap: () => widget.onNavigate('grades')),
        );
      case 'examCountdown':
        return _AsyncModuleCard<List<ExamItem>>(
          future: _examsFuture,
          title: '考试倒计时',
          icon: Icons.timer,
          accentColor: color,
          minHeight: _moduleMinHeight(id),
          builder: (data) => _ExamCountdownHomeCard(
              exams: data, onTap: () => widget.onNavigate('exams')),
        );
      case 'profile':
        return _AsyncModuleCard<StudentInfo>(
          future: _infoFuture,
          title: '个人资料',
          icon: Icons.badge,
          accentColor: color,
          minHeight: _moduleMinHeight(id),
          builder: (data) => _ProfileHomeCard(
              info: data, onTap: () => widget.onNavigate('info')),
        );
      case 'apps':
        return _AsyncModuleCard<List<EhallApplicationItem>>(
          future: _appsFuture,
          title: '常用服务',
          icon: Icons.apps,
          accentColor: color,
          minHeight: _moduleMinHeight(id),
          builder: (data) => _AppsHomeCard(
              apps: data, onTap: () => widget.onNavigate('applications')),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  void _showCustomizeSheet(BuildContext context) {
    var order = [..._moduleOrder];
    var hidden = {..._hiddenModules};
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, localSetState) {
          Future<void> persist() async {
            await HomePreferences.save(order: order, hidden: hidden);
            if (mounted) {
              setState(() {
                _moduleOrder = [...order];
                _hiddenModules = {...hidden};
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
                          await persist();
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
                      onReorder: (oldIndex, newIndex) async {
                        if (oldIndex < newIndex) newIndex -= 1;
                        final id = order.removeAt(oldIndex);
                        order.insert(newIndex, id);
                        await persist();
                        localSetState(() {});
                      },
                      itemBuilder: (context, index) {
                        final id = order[index];
                        final config = HomePreferences.configFor(id);
                        final visible = !hidden.contains(id);
                        final restricted = widget.isPasswordLogin &&
                            HomePage.passwordRestrictedModules.contains(id);
                        return ListTile(
                          key: ValueKey(id),
                          leading: Icon(config.icon,
                              color: restricted
                                  ? Theme.of(context).disabledColor
                                  : null),
                          title: Text(config.label,
                              style: restricted
                                  ? TextStyle(
                                      color: Theme.of(context).disabledColor,
                                      decoration: TextDecoration.lineThrough)
                                  : null),
                          subtitle: restricted
                              ? const Text('需一键登录',
                                  style: TextStyle(fontSize: 11))
                              : null,
                          trailing: Switch(
                            value: visible && !restricted,
                            onChanged: restricted
                                ? null
                                : (value) async {
                                    if (value) {
                                      hidden.remove(id);
                                    } else {
                                      hidden.add(id);
                                    }
                                    await persist();
                                    localSetState(() {});
                                  },
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

/// 根据断点决定每种 size 每行放几个。
int _columnsForSize(HomeModuleSize size, GzusBreakpoint breakpoint) {
  final isCompact = breakpoint == GzusBreakpoint.compact;
  return switch (size) {
    HomeModuleSize.featured => 1,
    HomeModuleSize.medium => isCompact ? 1 : 2,
    HomeModuleSize.small => isCompact ? 2 : 3,
  };
}

/// 将模块按 size 分组为行，保持用户自定义顺序。
List<Widget> _buildHomeLayoutRows({
  required List<_HomeLayoutItem> items,
  required GzusBreakpoint breakpoint,
  required double spacing,
}) {
  final rows = <Widget>[];
  final buffer = <_HomeLayoutItem>[];
  HomeModuleSize? currentSize;

  void flushBuffer() {
    if (buffer.isEmpty) return;
    final maxColumns = _columnsForSize(currentSize!, breakpoint);
    final children = buffer.map((item) => item.child).toList();
    rows.add(
      _HomeRowGroup(
        children: children,
        maxColumns: maxColumns,
        spacing: spacing,
      ),
    );
    buffer.clear();
    currentSize = null;
  }

  for (final item in items) {
    if (currentSize != null && currentSize != item.size) {
      flushBuffer();
    }
    currentSize = item.size;
    buffer.add(item);
    final maxColumns = _columnsForSize(item.size, breakpoint);
    if (buffer.length >= maxColumns) {
      flushBuffer();
    }
  }
  flushBuffer();

  // 加入交错入场动画与行间距
  final result = <Widget>[];
  for (var i = 0; i < rows.length; i++) {
    if (i > 0) result.add(SizedBox(height: spacing));
    result.add(_StaggeredAppear(index: i, child: rows[i]));
  }
  result.add(const SizedBox(height: 24));
  return result;
}

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
  }) async {
    if (kIsWeb) return;
    final timedCourses = _homeTimedCourses(
      data.courses,
      currentWeek: currentWeek,
      firstWeekStart: firstWeekStart,
    );
    final today = _todayTimedCourses(timedCourses);
    final next = _nextTimedCourse(timedCourses);
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
    required this.title,
    required this.icon,
    required this.builder,
    this.allowNull = false,
    this.accentColor,
    this.minHeight = 196,
  });

  final Future<T> future;
  final String title;
  final IconData icon;
  final Widget Function(T data) builder;
  final bool allowNull;
  final Color? accentColor;
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
            return _buildCard(_lastData as T);
          }
          return _HomeCard(
            title: widget.title,
            icon: widget.icon,
            accentColor: widget.accentColor,
            minHeight: widget.minHeight,
            child: const _ShimmerPlaceholder(),
          );
        }
        if (snapshot.hasError) {
          if (_lastData != null) {
            // 静默刷新失败：保留旧数据
            return _buildCard(_lastData as T);
          }
          return _HomeCard(
            title: widget.title,
            icon: widget.icon,
            accentColor: widget.accentColor,
            minHeight: widget.minHeight,
            child: ErrorState(
              message: '模块数据加载失败',
              onRetry: () {
                if (mounted) setState(() {});
              },
            ),
          );
        }
        final data = snapshot.data;
        if (!widget.allowNull && data == null) {
          if (_lastData != null) {
            return _buildCard(_lastData as T);
          }
          return _HomeCard(
            title: widget.title,
            icon: widget.icon,
            accentColor: widget.accentColor,
            minHeight: widget.minHeight,
            child: EmptyState(
              title: '暂无数据',
              message: '该模块暂时没有内容',
              icon: widget.icon,
              iconColor: widget.accentColor,
              iconBackgroundColor: widget.accentColor != null
                  ? GzusColors.softColorOf(widget.accentColor!)
                  : null,
            ),
          );
        }
        _lastData = data;
        return _buildCard(data as T);
      },
    );
  }

  Widget _buildCard(T data) => _HomeCard(
        title: widget.title,
        icon: widget.icon,
        accentColor: widget.accentColor,
        minHeight: widget.minHeight,
        child: widget.builder(data),
      );
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

class _StaggeredAppear extends StatefulWidget {
  const _StaggeredAppear({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<_StaggeredAppear> createState() => _StaggeredAppearState();
}

class _StaggeredAppearState extends State<_StaggeredAppear>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  late final _anim =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.index * 60), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.08),
          end: Offset.zero,
        ).animate(_anim),
        child: widget.child,
      ),
    );
  }
}

/// 将若干等宽子项放入一行，不足 [maxColumns] 时右侧补空白占位，
/// 保证每行卡片宽度一致。
class _HomeRowGroup extends StatelessWidget {
  const _HomeRowGroup({
    required this.children,
    required this.maxColumns,
    required this.spacing,
  });

  final List<Widget> children;
  final int maxColumns;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < maxColumns; i++) ...[
          if (i > 0) SizedBox(width: spacing),
          Expanded(
            child: i < children.length ? children[i] : const SizedBox.shrink(),
          ),
        ],
      ],
    );
  }
}

class _HomeCard extends StatelessWidget {
  const _HomeCard({
    required this.title,
    required this.icon,
    required this.child,
    this.badge,
    this.onTap,
    this.fillChild = false,
    this.accentColor,
    this.minHeight = 196,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final String? badge;
  final VoidCallback? onTap;
  final bool fillChild;
  final Color? accentColor;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final effectiveAccent = accentColor ?? cs.primary;
    final accentSoft = GzusColors.softColorOf(effectiveAccent);
    return LayoutBuilder(
      builder: (context, constraints) {
        final canFillChild = fillChild && constraints.hasBoundedHeight;
        final content = Container(
          constraints: BoxConstraints(minHeight: minHeight),
          padding: const EdgeInsets.all(GzusSpacing.l),
          decoration: BoxDecoration(
            color: gzusSurface(context),
            borderRadius: BorderRadius.circular(GzusRadii.lg),
            border: Border(
              top: BorderSide(color: gzusBorder(context)),
              left: BorderSide(color: effectiveAccent, width: 3),
              right: BorderSide(color: gzusBorder(context)),
              bottom: BorderSide(color: gzusBorder(context)),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: canFillChild ? MainAxisSize.max : MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: accentSoft,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, size: 19, color: effectiveAccent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GzusTextStyles.moduleTitle(context),
                    ),
                  ),
                  if (badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: accentSoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        badge!,
                        style: TextStyle(
                          color: effectiveAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              canFillChild ? Expanded(child: child) : child,
            ],
          ),
        );
        if (onTap == null) return content;
        return ScaleTap(
          onTap: onTap,
          borderRadius: BorderRadius.circular(GzusRadii.lg),
          child: content,
        );
      },
    );
  }
}

class _TimedCourse {
  const _TimedCourse({
    required this.course,
    required this.start,
    required this.end,
  });

  final ScheduleCourse course;
  final DateTime start;
  final DateTime end;

  String get timeText =>
      '${_two(start.hour)}:${_two(start.minute)}-${_two(end.hour)}:${_two(end.minute)}';
  bool get isOngoing {
    final now = DateTime.now();
    return !now.isBefore(start) && now.isBefore(end);
  }
}

List<_TimedCourse> _homeTimedCourses(
  List<ScheduleCourse> courses, {
  required int currentWeek,
  required DateTime firstWeekStart,
}) {
  final result = <_TimedCourse>[];
  for (final course in courses) {
    final weekday = course.weekday;
    final startSection = course.startSection;
    final endSection = course.endSection ?? startSection;
    if (weekday == null ||
        startSection == null ||
        endSection == null ||
        weekday < 1 ||
        weekday > 7 ||
        startSection < 1 ||
        endSection < 1 ||
        startSection > scheduleTimes.length ||
        endSection > scheduleTimes.length ||
        !course.occursInWeek(currentWeek)) {
      continue;
    }
    final day =
        firstWeekStart.add(Duration(days: (currentWeek - 1) * 7 + weekday - 1));
    final startTime = _timeParts(scheduleTimes[startSection - 1].$1);
    final endTime = _timeParts(scheduleTimes[endSection - 1].$2);
    result.add(_TimedCourse(
      course: course,
      start: DateTime(day.year, day.month, day.day, startTime.$1, startTime.$2),
      end: DateTime(day.year, day.month, day.day, endTime.$1, endTime.$2),
    ));
  }
  result.sort((a, b) => a.start.compareTo(b.start));
  return result;
}

List<_TimedCourse> _todayTimedCourses(List<_TimedCourse> courses) {
  final now = DateTime.now();
  return courses
      .where((item) =>
          item.start.year == now.year &&
          item.start.month == now.month &&
          item.start.day == now.day)
      .toList();
}

_TimedCourse? _nextTimedCourse(List<_TimedCourse> courses) {
  final now = DateTime.now();
  final current = courses
      .where((item) => !now.isBefore(item.start) && now.isBefore(item.end));
  if (current.isNotEmpty) return current.first;
  final upcoming = courses.where((item) => item.start.isAfter(now));
  return upcoming.isEmpty ? null : upcoming.first;
}

String _two(int value) => value.toString().padLeft(2, '0');

(int, int) _timeParts(String value) {
  final parts = value.split(':');
  return (
    parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0,
    parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
  );
}

Color _homeCourseColor(String name, Brightness brightness) {
  const lightPalette = [
    Color(0xFF6750A4),
    Color(0xFF386A20),
    Color(0xFF0061A4),
    Color(0xFF7D5260),
    Color(0xFF9B3D2D),
    Color(0xFF006C67),
  ];
  const darkPalette = [
    Color(0xFF9A82DB),
    Color(0xFF6DA65A),
    Color(0xFF4FA3D1),
    Color(0xFFB87A8E),
    Color(0xFFD47A68),
    Color(0xFF4DB6AC),
  ];
  final palette = brightness == Brightness.dark ? darkPalette : lightPalette;
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = (hash + unit) % palette.length;
  }
  return palette[hash];
}

T? _firstOrNull<T>(Iterable<T> values) {
  final iterator = values.iterator;
  return iterator.moveNext() ? iterator.current : null;
}

class _NextClassHomeCard extends StatelessWidget {
  const _NextClassHomeCard({required this.course, required this.onTap});

  final _TimedCourse? course;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final item = course;
    return _HomeCard(
      title: '下一节课',
      icon: Icons.watch_later,
      badge: item?.isOngoing == true ? '进行中' : '焦点',
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(GzusSpacing.l),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: item == null
            ? Text('今天没有更多课程', style: TextStyle(color: cs.onPrimaryContainer))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.course.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onPrimaryContainer,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      _HomeMeta(icon: Icons.schedule, text: item.timeText),
                      if (item.course.classroom != null)
                        _HomeMeta(
                            icon: Icons.location_on,
                            text: item.course.classroom!),
                      if (item.course.teacher != null)
                        _HomeMeta(
                            icon: Icons.person, text: item.course.teacher!),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class _TodayTimelineHomeCard extends StatelessWidget {
  const _TodayTimelineHomeCard({required this.courses});

  final List<_TimedCourse> courses;

  @override
  Widget build(BuildContext context) {
    return _HomeCard(
      title: '今日时间线',
      icon: Icons.view_timeline,
      badge: '${courses.length} 节',
      fillChild: true,
      child: courses.isEmpty
          ? const EmptyState(message: '今日无课')
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in courses) _TimelineMiniRow(course: item),
                ],
              ),
            ),
    );
  }
}

class _TimelineMiniRow extends StatelessWidget {
  const _TimelineMiniRow({required this.course});

  final _TimedCourse course;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color =
        course.isOngoing ? cs.error : _homeCourseColor(course.course.name, Theme.of(context).brightness);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 260;
          final timeWidth = compact ? 42.0 : 48.0;
          final dotSize = compact ? 8.0 : 10.0;
          final gap = compact ? 8.0 : 10.0;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: timeWidth,
                child: Text(
                  '${_two(course.start.hour)}:${_two(course.start.minute)}',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
              ),
              Container(
                width: dotSize,
                height: dotSize,
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              SizedBox(width: gap),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(GzusSpacing.m),
                  decoration: BoxDecoration(
                    color: course.isOngoing
                        ? cs.primaryContainer
                        : cs.surfaceContainerHighest.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(course.course.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: GzusSpacing.xs),
                      Text(
                        [course.course.classroom, course.course.teacher]
                            .where((item) => item != null && item.isNotEmpty)
                            .join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _WeekGridHomeCard extends StatelessWidget {
  const _WeekGridHomeCard({required this.courses});

  final List<ScheduleCourse> courses;

  @override
  Widget build(BuildContext context) {
    const days = ['一', '二', '三', '四', '五'];
    const slots = [1, 3, 5, 7];
    return _HomeCard(
      title: '周课表',
      icon: Icons.grid_view,
      badge: '紧凑',
      fillChild: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final labelWidth = constraints.maxWidth < 280 ? 28.0 : 36.0;
          final cellWidth =
              (constraints.maxWidth - labelWidth - 8) / days.length;
          final cellHeight =
              (constraints.maxHeight - 24 - 6 - 8) / slots.length;
          final fontSize =
              cellWidth < 44 ? 9.0 : (cellWidth < 58 ? 10.0 : 11.0);
          return Column(
            children: [
              Row(
                children: [
                  SizedBox(width: labelWidth),
                  for (final day in days)
                    Expanded(
                      child: Text('周$day',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: fontSize + 2)),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Column(
                  children: [
                    for (final slot in slots)
                      Expanded(
                        child: Row(
                          children: [
                            SizedBox(
                              width: labelWidth,
                              child: Text('$slot-${slot + 1}',
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                      fontSize: fontSize + 1)),
                            ),
                            for (var day = 1; day <= 5; day++)
                              Expanded(
                                child: _WeekGridCell(
                                  course: _firstOrNull(courses.where((item) {
                                    final start = item.startSection ?? 0;
                                    return item.weekday == day &&
                                        start >= slot &&
                                        start <= slot + 1;
                                  })),
                                  height: cellHeight,
                                  fontSize: fontSize,
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _WeekGridCell extends StatelessWidget {
  const _WeekGridCell({
    required this.course,
    required this.height,
    required this.fontSize,
  });

  final ScheduleCourse? course;
  final double height;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final item = course;
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: height,
      margin: const EdgeInsets.all(2),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: item == null
            ? cs.surfaceContainerHighest.withValues(alpha: 0.35)
            : _homeCourseColor(item.name, Theme.of(context).brightness).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
      ),
      child: item == null
          ? null
          : Center(
              child: Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w800,
                  height: 1.05,
                ),
              ),
            ),
    );
  }
}

class _DailyCoursesHomeCard extends StatelessWidget {
  const _DailyCoursesHomeCard({required this.courses});

  static const double _maxListHeight = 270;

  final List<_TimedCourse> courses;

  @override
  Widget build(BuildContext context) {
    return _HomeCard(
      title: '今日课程',
      icon: Icons.format_list_bulleted,
      badge: '列表',
      child: courses.isEmpty
          ? const EmptyState(message: '今日无课')
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _maxListHeight),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final item in courses) _CompactCourseRow(course: item),
                  ],
                ),
              ),
            ),
    );
  }
}

class _CompactCourseRow extends StatelessWidget {
  const _CompactCourseRow({required this.course});

  final _TimedCourse course;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        children: [
          SizedBox(
            width: 82,
            child: Text(course.timeText,
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
          ),
          Expanded(
            child: Text(course.course.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          StatusPill(
            label: course.isOngoing ? '进行中' : '待开始',
            color: course.isOngoing ? cs.primary : cs.tertiary,
          ),
        ],
      ),
    );
  }
}

class _UtilitiesHomeCard extends StatelessWidget {
  const _UtilitiesHomeCard({required this.summary, required this.onTap});

  final EcardSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final coldWaterColor =
        isDark ? const Color(0xFF4FC3F7) : const Color(0xFF0288D1);
    final hotWaterColor =
        isDark ? const Color(0xFFFF8A65) : const Color(0xFFD84315);
    final powerColor =
        isDark ? const Color(0xFFFFD54F) : const Color(0xFFF9A825);
    if (!summary.isBound) {
      return _HomeCard(
        title: '宿舍绑定',
        icon: Icons.home_work,
        badge: '未绑定',
        onTap: onTap,
        child: Column(
          children: [
            const SizedBox(height: GzusSpacing.xs),
            Icon(Icons.add_home_outlined,
                size: 36, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 10),
            Text(
              '点击绑定宿舍',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
            const SizedBox(height: GzusSpacing.xs),
            Text(
              '绑定后可实时查看冷水、热水、电费余额',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }
    return _HomeCard(
      title: '水电费余额',
      icon: Icons.water_drop,
      badge: '实时',
      onTap: onTap,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _UtilityMini(
                  icon: Icons.ac_unit,
                  label: '冷水',
                  value: summary.coldWaterText ?? '-',
                  color: coldWaterColor,
                ),
              ),
              const SizedBox(width: GzusSpacing.s),
              Expanded(
                child: _UtilityMini(
                  icon: Icons.local_fire_department,
                  label: '热水',
                  value: summary.hotWaterText ?? '-',
                  color: hotWaterColor,
                ),
              ),
              const SizedBox(width: GzusSpacing.s),
              Expanded(
                child: _UtilityMini(
                  icon: Icons.electric_bolt,
                  label: '电费',
                  value: summary.powerText ?? '-',
                  color: powerColor,
                ),
              ),
            ],
          ),
          if (summary.roomDisplay != null) ...[
            const SizedBox(height: GzusSpacing.m),
            Text(summary.roomDisplay!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

class _UtilityMini extends StatelessWidget {
  const _UtilityMini({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(minHeight: 96),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 10),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: GzusSpacing.xs),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

class _BusinessProgressHomeCard extends StatelessWidget {
  const _BusinessProgressHomeCard(
      {required this.overview, required this.onTap});

  final EhallProgressOverview overview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final items = overview.items;
    final total = overview.categories.fold<int>(
      0,
      (sum, item) => sum + item.count,
    );
    return _HomeCard(
      title: '业务进度',
      icon: Icons.route,
      badge: '$total 项',
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProgressCategoryStrip(categories: overview.categories),
          const SizedBox(height: GzusSpacing.m),
          if (items.isEmpty)
            const EmptyState(message: '暂无业务进度')
          else
            SizedBox(
              height: 130,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final item in items) ProgressMiniRow(item: item),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NotificationsHomeCard extends StatelessWidget {
  const _NotificationsHomeCard({required this.notices, required this.onTap});

  final List<NoticeItem> notices;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _HomeCard(
      title: '最新通知',
      icon: Icons.notifications_active,
      badge: '${notices.length}',
      onTap: onTap,
      child: notices.isEmpty
          ? const EmptyState(message: '暂无通知')
          : Column(
              children: [
                for (final item in notices.take(4)) _NoticeMiniRow(item: item),
              ],
            ),
    );
  }
}

class _NoticeMiniRow extends StatelessWidget {
  const _NoticeMiniRow({required this.item});

  final NoticeItem item;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          const IconBadge(icon: Icons.campaign, size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(item.summary ?? item.category,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AttendanceHomeCard extends StatelessWidget {
  const _AttendanceHomeCard({required this.data, required this.onTap});

  final AttendanceResponse data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final normal = data.items.fold(0, (sum, item) => sum + item.normal);
    final late = data.items.fold(0, (sum, item) => sum + item.late);
    final early = data.items.fold(0, (sum, item) => sum + item.leaveEarly);
    final absent = data.items.fold(0, (sum, item) => sum + item.absent);
    final normalColor =
        isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32);
    final lateColor =
        isDark ? const Color(0xFFFFB74D) : const Color(0xFFF57C00);
    final earlyColor =
        isDark ? const Color(0xFFBA68C8) : const Color(0xFF7B1FA2);
    final absentColor =
        isDark ? const Color(0xFFE57373) : const Color(0xFFC62828);
    return _HomeCard(
      title: '本月考勤统计',
      icon: Icons.fact_check,
      badge: '${data.items.length} 门',
      onTap: onTap,
      child: Row(
        children: [
          Expanded(child: _AttendanceStatMini('正常', normal, normalColor)),
          Expanded(child: _AttendanceStatMini('迟到', late, lateColor)),
          Expanded(child: _AttendanceStatMini('早退', early, earlyColor)),
          Expanded(child: _AttendanceStatMini('旷课', absent, absentColor)),
        ],
      ),
    );
  }
}

class _AttendanceStatMini extends StatelessWidget {
  const _AttendanceStatMini(this.label, this.value, this.color);

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            '$value',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: GzusSpacing.xs),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _CreditsHomeCard extends StatelessWidget {
  const _CreditsHomeCard({required this.credits, required this.onTap});

  final List<CreditItem> credits;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = credits.isEmpty ? null : credits.first;
    final expected = item?.totalExpected ?? 0;
    final earned = item?.totalEarned ?? 0;
    final progress = expected <= 0 ? 0.0 : (earned / expected).clamp(0.0, 1.0);
    return _HomeCard(
      title: '学分进度',
      icon: Icons.workspace_premium,
      badge: item?.grade ?? '学分',
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${earned.toStringAsFixed(1)} / ${expected.toStringAsFixed(1)}',
            style: GzusTextStyles.statisticValue(context)?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
          const SizedBox(height: 10),
          StaticProgressBar(value: progress),
          const SizedBox(height: GzusSpacing.m),
          _HomeInfoLine(
              '必修',
              item == null
                  ? '-'
                  : '${item.requiredEarned.toStringAsFixed(1)} / ${item.requiredExpected.toStringAsFixed(1)}'),
          _HomeInfoLine(
              '选修',
              item == null
                  ? '-'
                  : '${item.electiveEarned.toStringAsFixed(1)} / ${item.electiveExpected.toStringAsFixed(1)}'),
        ],
      ),
    );
  }
}

class _ProfileHomeCard extends StatelessWidget {
  const _ProfileHomeCard({required this.info, required this.onTap});

  final StudentInfo info;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GzusLayout(
      builder: (context, breakpoint) {
        final compact = breakpoint == GzusBreakpoint.compact;
        return _HomeCard(
          title: '个人资料',
          icon: Icons.badge,
          badge: '已认证',
          onTap: onTap,
          child: Row(
            children: [
              CircleAvatar(
                radius: compact ? 30 : 36,
                child:
                    Text(info.name.isEmpty ? '-' : info.name.characters.first),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(info.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 6),
                    _HomeInfoLine('学号', info.studentId),
                    _HomeInfoLine('专业', info.major ?? '-'),
                    _HomeInfoLine('班级', info.className ?? '-'),
                    if (info.gender != null) _HomeInfoLine('性别', info.gender!),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AppsHomeCard extends StatelessWidget {
  const _AppsHomeCard({required this.apps, required this.onTap});

  final List<EhallApplicationItem> apps;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final visible = apps.take(8).toList();
    return _HomeCard(
      title: '常用服务',
      icon: Icons.apps,
      badge: '${apps.length} 个',
      onTap: onTap,
      child: visible.isEmpty
          ? const EmptyState(message: '暂无应用')
          : LayoutBuilder(
              builder: (context, constraints) {
                final itemWidth = constraints.maxWidth < 240
                    ? constraints.maxWidth / 4 - 10
                    : (constraints.maxWidth / 4).clamp(64.0, 84.0);
                return Wrap(
                  alignment: WrapAlignment.start,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final app in visible)
                      SizedBox(
                        width: itemWidth,
                        child: Column(
                          children: [
                            const IconBadge(icon: Icons.dashboard_customize),
                            const SizedBox(height: 6),
                            Text(app.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}

class _WeatherHomeCard extends StatelessWidget {
  const _WeatherHomeCard({this.weather});

  final WeatherData? weather;

  IconData _weatherIcon(String? weatherText) {
    final w = weatherText ?? '';
    if (w.contains('雨')) return Icons.water_drop;
    if (w.contains('雪')) return Icons.ac_unit;
    if (w.contains('云') || w.contains('阴')) return Icons.wb_cloudy;
    return Icons.wb_sunny;
  }

  Color _weatherColor(String? weatherText, BuildContext context) {
    final w = weatherText ?? '';
    if (w.contains('雨')) return Colors.blue;
    if (w.contains('雪')) return Colors.lightBlue;
    if (w.contains('云') || w.contains('阴')) return Colors.grey;
    return Theme.of(context).colorScheme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final w = weather;
    if (w == null) {
      return const _HomeCard(
        title: '今日天气',
        icon: Icons.wb_sunny,
        badge: '--',
        child: Center(child: Text('天气数据加载失败')),
      );
    }

    final forecast =
        w.forecast.length > 1 ? w.forecast.sublist(1, 4) : <WeatherForecast>[];

    return _HomeCard(
      title: '今日天气',
      icon: Icons.wb_sunny,
      badge: w.location,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(_weatherIcon(w.weather),
                  size: 40, color: _weatherColor(w.weather, context)),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${w.temperature.round()}°',
                      style: const TextStyle(
                          fontSize: 36, fontWeight: FontWeight.w200)),
                  Text(
                    '${w.weather}  ${w.tempMin != null ? w.tempMin!.round() : '--'}°~${w.tempMax != null ? w.tempMax!.round() : '--'}°',
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: GzusSpacing.m),
          Row(
            children: [
              _HomeMeta(icon: Icons.water_drop, text: '湿度 ${w.humidity}%'),
              const SizedBox(width: 16),
              _HomeMeta(
                  icon: Icons.air, text: '${w.windDirection} ${w.windPower}'),
            ],
          ),
          if (forecast.isNotEmpty) ...[
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final f in forecast)
                  Column(
                    children: [
                      Text(f.week,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                      const SizedBox(height: GzusSpacing.xs),
                      Icon(_weatherIcon(f.weatherDay),
                          size: 20,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(height: GzusSpacing.xs),
                      Text('${f.tempMax.round()}°',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700)),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _GradesHomeCard extends StatelessWidget {
  const _GradesHomeCard({this.grades, required this.onTap});

  final List<GradeItem>? grades;
  final VoidCallback onTap;

  double _scoreToGPA(String? scoreStr) {
    final score = int.tryParse(scoreStr ?? '');
    if (score == null) return 0;
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

  ({String gpa, String avg, int count}) _calcStats(List<GradeItem> list) {
    double totalGPA = 0;
    double totalScore = 0;
    int valid = 0;
    for (final g in list) {
      final s = int.tryParse(g.score ?? '');
      if (s != null) {
        totalGPA += _scoreToGPA(g.score);
        totalScore += s;
        valid++;
      }
    }
    if (valid == 0) return (gpa: '0.00', avg: '0.0', count: 0);
    return (
      gpa: (totalGPA / valid).toStringAsFixed(2),
      avg: (totalScore / valid).toStringAsFixed(1),
      count: valid,
    );
  }

  Color _scoreColor(int? score, ColorScheme cs) {
    if (score == null) return cs.onSurfaceVariant;
    if (score >= 90) return Colors.green;
    if (score >= 80) return cs.primary;
    if (score >= 60) return Colors.orange;
    return Colors.red;
  }

  Color _gpaTagColor(double gpa, ColorScheme cs) {
    if (gpa >= 4.0) return Colors.green;
    if (gpa >= 3.0) return cs.primary;
    if (gpa >= 2.0) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final list = grades ?? [];
    final stats = _calcStats(list);
    final sorted =
        list.where((g) => int.tryParse(g.score ?? '') != null).toList()
          ..sort((a, b) {
            final sa = int.parse(a.score!);
            final sb = int.parse(b.score!);
            return sb.compareTo(sa);
          });

    return _HomeCard(
      title: '本学期成绩',
      icon: Icons.school,
      badge: '${stats.count} 门',
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Text(stats.gpa,
                        style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            color: Theme.of(context).colorScheme.primary)),
                    Text('平均绩点',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ],
                ),
              ),
              Container(
                  width: 1, height: 40, color: Theme.of(context).dividerColor),
              Expanded(
                child: Column(
                  children: [
                    Text(stats.avg,
                        style: const TextStyle(
                            fontSize: 32, fontWeight: FontWeight.w800)),
                    Text('平均分',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 20),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 120, maxHeight: 220),
            child: sorted.isEmpty
                ? const Center(child: Text('暂无成绩数据'))
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    physics: const ClampingScrollPhysics(),
                    itemCount: sorted.length.clamp(0, 6),
                    separatorBuilder: (_, __) => const SizedBox(height: GzusSpacing.s),
                    itemBuilder: (context, i) {
                      final g = sorted[i];
                      final score = int.parse(g.score!);
                      final gpa = _scoreToGPA(g.score);
                      return Row(
                        children: [
                          Container(
                            width: 4,
                            height: 28,
                            decoration: BoxDecoration(
                              color: _scoreColor(
                                  score, Theme.of(context).colorScheme),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(g.courseName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600)),
                                if (g.credit != null)
                                  Text('${g.credit} 学分',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant)),
                              ],
                            ),
                          ),
                          Text('$score',
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: _scoreColor(
                                      score, Theme.of(context).colorScheme))),
                          const SizedBox(width: GzusSpacing.s),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: _gpaTagColor(
                                      gpa, Theme.of(context).colorScheme)
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(gpa.toStringAsFixed(1),
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: _gpaTagColor(
                                        gpa, Theme.of(context).colorScheme))),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ExamCountdownHomeCard extends StatelessWidget {
  const _ExamCountdownHomeCard({this.exams, required this.onTap});

  final List<ExamItem>? exams;
  final VoidCallback onTap;

  DateTime? _examDate(ExamItem e) {
    var dateStr = e.date;
    if (dateStr.isEmpty) {
      final t = e.time ?? '';
      final spaceIdx = t.indexOf(' ');
      dateStr = spaceIdx > 0 ? t.substring(0, spaceIdx) : t;
    }
    return DateTime.tryParse(dateStr);
  }

  int _calcCountdown(ExamItem e) {
    final target = _examDate(e);
    if (target == null) return 9999;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return target.difference(today).inDays;
  }

  List<ExamItem> _upcoming(List<ExamItem> list) {
    return list.where((e) {
      final days = _calcCountdown(e);
      return days >= -7 || days == 9999;
    }).toList()
      ..sort((a, b) {
        final da = _calcCountdown(a);
        final db = _calcCountdown(b);
        if (da == 9999 && db == 9999) return 0;
        if (da == 9999) return 1;
        if (db == 9999) return -1;
        return da.compareTo(db);
      });
  }

  @override
  Widget build(BuildContext context) {
    final list = exams ?? [];
    final upcoming = _upcoming(list);

    return _HomeCard(
      title: '考试倒计时',
      icon: Icons.timer,
      badge: '期末',
      onTap: onTap,
      child: upcoming.isEmpty
          ? const Center(child: Text('暂无即将到来的考试'))
          : ListView.separated(
              physics: const NeverScrollableScrollPhysics(),
              itemCount: upcoming.length.clamp(0, 4),
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final exam = upcoming[i];
                final days = _calcCountdown(exam);
                final dateObj = _examDate(exam);
                final day = dateObj?.day ?? 0;
                final month = dateObj?.month ?? 0;
                final isPast = days < 0;
                final isUrgent = days >= 0 && days <= 3;
                final isToday = days == 0;

                return Container(
                  padding: const EdgeInsets.all(GzusSpacing.m),
                  decoration: BoxDecoration(
                    color: isUrgent
                        ? Theme.of(context)
                            .colorScheme
                            .errorContainer
                            .withValues(alpha: 0.3)
                        : Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isUrgent
                          ? Theme.of(context)
                              .colorScheme
                              .error
                              .withValues(alpha: 0.3)
                          : Theme.of(context)
                              .dividerColor
                              .withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: isUrgent
                              ? Theme.of(context)
                                  .colorScheme
                                  .error
                                  .withValues(alpha: 0.12)
                              : Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('$day',
                                style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: isUrgent
                                        ? Theme.of(context).colorScheme.error
                                        : Theme.of(context)
                                            .colorScheme
                                            .primary)),
                            Text('$month月',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: isUrgent
                                        ? Theme.of(context).colorScheme.error
                                        : Theme.of(context)
                                            .colorScheme
                                            .primary)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(exam.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(
                                '${exam.weekday ?? ''}${(exam.weekday ?? '').isNotEmpty && exam.timeDisplay.isNotEmpty ? ' · ' : ''}${exam.timeDisplay}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant)),
                            Text(exam.location ?? '',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant)),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: isToday
                              ? Theme.of(context).colorScheme.error
                              : isPast
                                  ? Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.6)
                                  : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          children: [
                            Text(
                                days == 9999
                                    ? '?'
                                    : isToday
                                        ? '!'
                                        : '${days.abs()}',
                                style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: isToday
                                        ? Colors.white
                                        : isPast
                                            ? Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant
                                            : Theme.of(context)
                                                .colorScheme
                                                .onSurface)),
                            Text(
                                days == 9999
                                    ? '待定'
                                    : isToday
                                        ? '今天'
                                        : isPast
                                            ? '天前'
                                            : '天',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: isToday
                                        ? Colors.white
                                        : Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant)),
                          ],
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

class _HomeMeta extends StatelessWidget {
  const _HomeMeta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 4),
        Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

class _HomeInfoLine extends StatelessWidget {
  const _HomeInfoLine(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: Text(label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
