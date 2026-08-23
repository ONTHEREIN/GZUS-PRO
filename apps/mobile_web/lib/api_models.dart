// 数据模型 + JSON 解析辅助，自 api_client.dart 拆分。
// 使用 part of 共享同一 library：下划线私有顶层函数（_isReadableNoticeItem、
// _doubleFromJson、_intValue 等）仍能与 ApiClient 互通，32 个 import 方无需改动。
part of 'api_client.dart';

class DataSourceInfo {
  const DataSourceInfo({
    this.fromCache = false,
    this.fromLocalCache = false,
    this.cachedAt,
    this.isOffline = false,
    this.needsRelogin = false,
  });

  final bool fromCache;
  final bool fromLocalCache;
  final DateTime? cachedAt;
  final bool isOffline;
  final bool needsRelogin;

  String get displayText {
    if (needsRelogin) return '教务系统会话已失效，请重新登录';
    if (fromLocalCache) return isOffline ? '离线缓存' : '本地缓存';
    if (fromCache) return '更新失败，显示上次数据';
    return '';
  }

  /// 联机时缓存优先并后台刷新属于正常路径，不视为过期；
  /// 仅离线回退或更新失败（显示旧数据）时才需要横幅提示。
  bool get isStale => fromCache || (fromLocalCache && isOffline);
}

class DataResult<T> {
  const DataResult({required this.data, this.source = const DataSourceInfo()});

  final T data;
  final DataSourceInfo source;
}

class DashboardModule {
  const DashboardModule({
    required this.status,
    this.data,
    this.source,
    this.cachedAt,
    this.error,
    this.durationMs,
  });

  factory DashboardModule.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const DashboardModule(status: 'empty');
    return DashboardModule(
      status: json['status'] as String? ?? 'empty',
      data: json['data'],
      source: json['source'] as String?,
      cachedAt: json['cachedAt'] as String?,
      error: json['error'] as String?,
      durationMs: json['durationMs'] is num
          ? (json['durationMs'] as num).round()
          : null,
    );
  }

  final String status;
  final dynamic data;
  final String? source;
  final String? cachedAt;
  final String? error;
  final int? durationMs;

  bool get hasUsableData =>
      data != null && status != 'error' && status != 'empty';

  List<Map<String, dynamic>> listData() {
    final raw = data;
    if (raw is! List<dynamic>) return const [];
    return raw.whereType<Map<String, dynamic>>().toList();
  }

  Map<String, dynamic>? objectData() {
    final raw = data;
    return raw is Map<String, dynamic> ? raw : null;
  }
}

class DashboardSnapshot {
  DashboardSnapshot({
    required this.status,
    required this.generatedAt,
    required this.modules,
    this.traceId,
  });

  factory DashboardSnapshot.fromJson(Map<String, dynamic> json) {
    final rawModules = json['modules'];
    final modules = <String, DashboardModule>{};
    if (rawModules is Map<String, dynamic>) {
      for (final entry in rawModules.entries) {
        final value = entry.value;
        modules[entry.key] = DashboardModule.fromJson(
          value is Map<String, dynamic> ? value : null,
        );
      }
    }
    return DashboardSnapshot(
      status: json['status'] as String? ?? 'ok',
      generatedAt: json['generatedAt'] as String? ??
          DateTime.now().toIso8601String(),
      modules: modules,
      traceId: json['traceId'] as String?,
    );
  }

  final String status;
  final String generatedAt;
  final String? traceId;
  final Map<String, DashboardModule> modules;

  DashboardModule module(String key) =>
      modules[key] ?? const DashboardModule(status: 'empty');
}

class CacheEntry<T> {
  final T data;
  final DateTime expiry;

  CacheEntry(this.data, this.expiry);
}

class RequestCache {
  final Map<String, CacheEntry<dynamic>> _cache = {};
  final Duration defaultTtl;
  final int maxEntries;

  RequestCache({
    this.defaultTtl = const Duration(minutes: 5),
    this.maxEntries = 128,
  });

  T? get<T>(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    if (DateTime.now().isAfter(entry.expiry)) {
      _cache.remove(key);
      return null;
    }
    return entry.data as T;
  }

  void set<T>(String key, T data, [Duration? ttl]) {
    if (!_cache.containsKey(key) && _cache.length >= maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    final expiry = DateTime.now().add(ttl ?? defaultTtl);
    _cache[key] = CacheEntry<dynamic>(data, expiry);
  }

  void clear() {
    _cache.clear();
  }

  void remove(String key) {
    _cache.remove(key);
  }
}

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isSingleDeviceConflict => message.contains('其他设备登录');

  @override
  String toString() => message;
}

class LoginResult {
  LoginResult({
    required this.status,
    this.sessionId,
    this.studentName,
    this.studentId,
    this.captchaToken,
    this.captchaImage,
    this.loginMethod,
    this.credentialToken,
    this.jwxtCookies,
    this.ehallCookies,
    this.ehallAuthToken,
    this.isAdmin,
  });

  factory LoginResult.fromJson(Map<String, dynamic> json) => LoginResult(
        status: json['status'] as String,
        sessionId: json['sessionId'] as String?,
        studentName: json['studentName'] as String?,
        studentId: json['studentId'] as String?,
        captchaToken: json['captchaToken'] as String?,
        captchaImage: json['captchaImage'] as String?,
        loginMethod: json['loginMethod'] as String?,
        credentialToken: json['credentialToken'] as String?,
        jwxtCookies:
            json['jwxtCookies'] as String? ?? json['cookies'] as String?,
        ehallCookies: json['ehallCookies'] as String?,
        ehallAuthToken: json['ehallAuthToken'] as String?,
        isAdmin: json['isAdmin'] as bool?,
      );

  final String status;
  final String? sessionId;
  final String? studentName;
  final String? studentId;
  final String? captchaToken;
  final String? captchaImage;

  /// 登录方式: "password" 表示教务系统账密登录, "sso" 表示办事大厅一键登录
  final String? loginMethod;

  /// 用于自动重新登录的凭证令牌
  final String? credentialToken;

  /// 教务系统 cookies，仅原生移动端前台直连学校接口时使用。
  final String? jwxtCookies;

  /// 办事大厅 WebView 登录态。
  final String? ehallCookies;
  final String? ehallAuthToken;

  /// 管理后台标记：学号在 admin_users 白名单中时为 true。
  final bool? isAdmin;
}

class StudentInfo {
  StudentInfo({
    required this.studentId,
    required this.name,
    this.college,
    this.major,
    this.className,
    this.grade,
    this.gender,
    this.idNumber,
    this.birthDate,
    this.ethnicity,
    this.politicalStatus,
    this.enrollDate,
    this.nativePlace,
    this.studentStatus,
    this.educationLevel,
    this.phone,
    this.email,
    this.address,
    this.photoDataUrl,
  });

  factory StudentInfo.fromJson(Map<String, dynamic> json) => StudentInfo(
        studentId: json['studentId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        college: json['college'] as String?,
        major: json['major'] as String?,
        className: json['className'] as String?,
        grade: json['grade'] as String?,
        gender: json['gender'] as String?,
        idNumber: json['idNumber'] as String?,
        birthDate: json['birthDate'] as String?,
        ethnicity: json['ethnicity'] as String?,
        politicalStatus: json['politicalStatus'] as String?,
        enrollDate: json['enrollDate'] as String?,
        nativePlace: json['nativePlace'] as String?,
        studentStatus: json['studentStatus'] as String?,
        educationLevel: json['educationLevel'] as String?,
        phone: json['phone'] as String?,
        email: json['email'] as String?,
        address: json['address'] as String?,
        photoDataUrl: json['photoDataUrl'] as String?,
      );

  final String studentId;
  final String name;
  final String? college;
  final String? major;
  final String? className;
  final String? grade;
  final String? gender;
  final String? idNumber;
  final String? birthDate;
  final String? ethnicity;
  final String? politicalStatus;
  final String? enrollDate;
  final String? nativePlace;
  final String? studentStatus;
  final String? educationLevel;
  final String? phone;
  final String? email;
  final String? address;
  final String? photoDataUrl;
}

class ScheduleCourse {
  ScheduleCourse.fromJson(Map<String, dynamic> json)
      : name = json['name'] as String? ?? '',
        teacher = json['teacher'] as String?,
        classroom = json['classroom'] as String?,
        weekday = _intValue(json['weekday']),
        startSection = _intValue(json['startSection']),
        endSection = _intValue(json['endSection']),
        weeks = json['weeks'] as String?,
        kcbmc = json['kcbmc'] as String?,
        raw = json['raw'] is Map<String, dynamic>
            ? json['raw'] as Map<String, dynamic>
            : json,
        isLocal = false;

  /// 普通构造（本地调课新增/替换课程使用；[isLocal] 标记本地条目）。
  ScheduleCourse({
    required this.name,
    this.teacher,
    this.classroom,
    this.weekday,
    this.startSection,
    this.endSection,
    this.weeks,
    this.kcbmc,
    this.raw = const <String, dynamic>{},
    this.isLocal = false,
  });

  final String name;
  final String? teacher;
  final String? classroom;
  final int? weekday;
  final int? startSection;
  final int? endSection;
  final String? weeks;
  final String? kcbmc;
  final Map<String, dynamic> raw;

  /// 是否本地调课条目（新增/替换），渲染层据此显示「调」徽标。
  /// 仅存在于前端，不随 JSON 传输。
  final bool isLocal;

  bool occursInWeek(int week) {
    final spec = weeks?.trim();
    if (spec == null || spec.isEmpty) return true;
    return _weekSpecContains(spec, week);
  }

  ScheduleCourse copyWith({
    String? name,
    String? teacher,
    String? classroom,
    int? weekday,
    int? startSection,
    int? endSection,
    String? weeks,
    String? kcbmc,
    Map<String, dynamic>? raw,
    bool? isLocal,
  }) {
    return ScheduleCourse(
      name: name ?? this.name,
      teacher: teacher ?? this.teacher,
      classroom: classroom ?? this.classroom,
      weekday: weekday ?? this.weekday,
      startSection: startSection ?? this.startSection,
      endSection: endSection ?? this.endSection,
      weeks: weeks ?? this.weeks,
      kcbmc: kcbmc ?? this.kcbmc,
      raw: raw ?? this.raw,
      isLocal: isLocal ?? this.isLocal,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        if (teacher != null) 'teacher': teacher,
        if (classroom != null) 'classroom': classroom,
        if (weekday != null) 'weekday': weekday,
        if (startSection != null) 'startSection': startSection,
        if (endSection != null) 'endSection': endSection,
        if (weeks != null) 'weeks': weeks,
        if (kcbmc != null) 'kcbmc': kcbmc,
        if (raw.isNotEmpty) 'raw': raw,
      };
}

int? _intValue(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

bool _weekSpecContains(String spec, int week) {
  final normalized = spec
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('，', ',')
      .replaceAll('；', ';')
      .replaceAll('、', ',');
  var foundNumber = false;
  for (final segment in normalized.split(RegExp(r'[,;]'))) {
    final text = segment.trim();
    if (text.isEmpty) continue;
    final oddOnly = text.contains('单');
    final evenOnly = text.contains('双');
    if (oddOnly && week.isEven) continue;
    if (evenOnly && week.isOdd) continue;

    final ranges = RegExp(r'(\d+)\s*-\s*(\d+)').allMatches(text).toList();
    if (ranges.isNotEmpty) {
      foundNumber = true;
      for (final match in ranges) {
        final start = int.tryParse(match.group(1)!);
        final end = int.tryParse(match.group(2)!);
        if (start != null && end != null && week >= start && week <= end) {
          return true;
        }
      }
      continue;
    }

    for (final match in RegExp(r'\d+').allMatches(text)) {
      foundNumber = true;
      if (int.tryParse(match.group(0)!) == week) return true;
    }
  }
  return !foundNumber;
}

class ScheduleResult {
  ScheduleResult({required this.items, required this.raw});

  final List<ScheduleCourse> items;
  final List<Map<String, dynamic>> raw;

  String get prettyJson => const JsonEncoder.withIndent('  ').convert(raw);
}

class ExamItem {
  ExamItem.fromJson(Map<String, dynamic> json)
      : courseName =
            json['courseName'] as String? ?? json['name'] as String? ?? '',
        name = json['name'] as String? ?? json['courseName'] as String? ?? '',
        date = json['date'] as String? ?? '',
        time = json['time'] as String? ?? '',
        weekday = json['weekday'] as String? ?? '',
        location = json['location'] as String?,
        seat = json['seat'] as String?,
        type = json['type'] as String?;

  final String courseName;
  final String name;
  final String date;
  final String? time;
  final String? weekday;
  final String? location;
  final String? seat;
  final String? type;

  /// 只显示时间部分（如 "09:00-11:00"），去掉日期部分
  String get timeDisplay {
    final t = time ?? '';
    final spaceIdx = t.indexOf(' ');
    return spaceIdx > 0 ? t.substring(spaceIdx + 1) : t;
  }
}

class AcademicPeriod {
  const AcademicPeriod(this.year, this.term);

  final int year;
  final int term;

  String get label => '$year-${year + 1}-$term';
}

class PeriodExam {
  PeriodExam(this.period, this.exam);

  final AcademicPeriod period;
  final ExamItem exam;
  int retakeIndex = 0;

  bool get isRetake => retakeIndex > 0;
  String get displayName => isRetake && !exam.courseName.contains('补')
      ? '${exam.courseName}（补）'
      : exam.courseName;
  String get examKind => isRetake ? '第${_cnNumber(retakeIndex)}次补考' : '普通考试';
}

String _cnNumber(int value) {
  const numbers = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];
  if (value >= 0 && value < numbers.length) return numbers[value];
  return '$value';
}

class GradeItem {
  GradeItem.fromJson(Map<String, dynamic> json)
      : courseName = json['courseName'] as String? ?? '',
        score = json['score'] as String?,
        credit = json['credit'] as String?,
        gradePoint = json['gradePoint'] as String?,
        term = json['term'] as String?;

  final String courseName;
  final String? score;
  final String? credit;
  final String? gradePoint;
  final String? term;
}

class WeatherData {
  WeatherData.fromJson(Map<String, dynamic> json)
      : province = json['province'] as String? ?? '',
        city = json['city'] as String? ?? '',
        district = json['district'] as String? ?? '',
        weather = json['weather'] as String? ?? '--',
        weatherIcon = json['weather_icon'] as String? ?? '100',
        temperature = (json['temperature'] as num?)?.toDouble() ?? 0,
        windDirection = json['wind_direction'] as String? ?? '',
        windPower = json['wind_power'] as String? ?? '',
        humidity = (json['humidity'] as num?)?.toInt() ?? 0,
        tempMax = (json['temp_max'] as num?)?.toDouble(),
        tempMin = (json['temp_min'] as num?)?.toDouble(),
        forecast = (json['forecast'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((e) => WeatherForecast.fromJson(e))
            .toList();

  final String province;
  final String city;
  final String district;
  final String weather;
  final String weatherIcon;
  final double temperature;
  final String windDirection;
  final String windPower;
  final int humidity;
  final double? tempMax;
  final double? tempMin;
  final List<WeatherForecast> forecast;

  String get location =>
      district.isNotEmpty ? district : (city.isNotEmpty ? city : province);
}

class WeatherForecast {
  WeatherForecast.fromJson(Map<String, dynamic> json)
      : date = json['date'] as String? ?? '',
        week = json['week'] as String? ?? '',
        tempMax = (json['temp_max'] as num?)?.toDouble() ?? 0,
        tempMin = (json['temp_min'] as num?)?.toDouble() ?? 0,
        weatherDay = json['weather_day'] as String? ?? '';

  final String date;
  final String week;
  final double tempMax;
  final double tempMin;
  final String weatherDay;
}

class AttendanceResponse {
  AttendanceResponse.fromJson(Map<String, dynamic> json)
      : status = json['status'] as String? ?? 'not_implemented',
        items = (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((item) => AttendanceItem.fromJson(item))
            .toList();

  final String status;
  final List<AttendanceItem> items;
}

class AttendanceItem {
  AttendanceItem.fromJson(Map<String, dynamic> json)
      : courseName = json['courseName'] as String? ?? '',
        courseCode = json['courseCode'] as String?,
        academicYear = json['academicYear'] as String?,
        term = json['term'] as String?,
        normal = json['normal'] as int? ?? 0,
        late = json['late'] as int? ?? 0,
        leaveEarly = json['leaveEarly'] as int? ?? 0,
        absent = json['absent'] as int? ?? 0,
        leave = json['leave'] as int? ?? 0,
        total = json['total'] as int? ?? 0,
        records = (json['records'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((item) => AttendanceRecord.fromJson(item))
            .toList();

  final String courseName;
  final String? courseCode;
  final String? academicYear;
  final String? term;
  final int normal;
  final int late;
  final int leaveEarly;
  final int absent;
  final int leave;
  final int total;
  final List<AttendanceRecord> records;

  String get compareKey => '${courseCode ?? ''}|$courseName';

  int countFor(String status) {
    switch (status) {
      case 'late':
        return late;
      case 'leaveEarly':
        return leaveEarly;
      case 'absent':
        return absent;
      case 'leave':
        return leave;
      case 'normal':
        return normal;
      default:
        return 0;
    }
  }

  Map<String, dynamic> toSnapshotJson() => {
        'courseName': courseName,
        'courseCode': courseCode,
        'normal': normal,
        'late': late,
        'leaveEarly': leaveEarly,
        'absent': absent,
        'leave': leave,
        'total': total,
      };
}

class AttendanceRecord {
  AttendanceRecord.fromJson(Map<String, dynamic> json)
      : date = json['date'] as String?,
        status = json['status'] as String? ?? 'normal',
        statusLabel = json['statusLabel'] as String?,
        count = json['count'] as int? ?? 1,
        time = json['time'] as String?,
        remark = json['remark'] as String?;

  final String? date;
  final String status;
  final String? statusLabel;
  final int count;
  final String? time;
  final String? remark;

  String get normalizedDate {
    final value = date?.trim() ?? '';
    if (value.length >= 10) return value.substring(0, 10);
    return value;
  }
}

class CreditItem {
  CreditItem.fromJson(Map<String, dynamic> json)
      : studentId = json['studentId'] as String?,
        name = json['name'] as String?,
        college = json['college'] as String?,
        major = json['major'] as String?,
        grade = json['grade'] as String?,
        totalCredit = json['totalCredit'] as String?,
        requiredCredit = json['requiredCredit'] as String?,
        selectedCredit = json['selectedCredit'] as String?,
        requiredExpected = (json['requiredExpected'] as num?)?.toDouble() ?? 0,
        electiveExpected = (json['electiveExpected'] as num?)?.toDouble() ?? 0,
        otherExpected = (json['otherExpected'] as num?)?.toDouble() ?? 0,
        requiredEarned = (json['requiredEarned'] as num?)?.toDouble() ?? 0,
        electiveEarned = (json['electiveEarned'] as num?)?.toDouble() ?? 0,
        otherEarned = (json['otherEarned'] as num?)?.toDouble() ?? 0,
        totalExpected = (json['totalExpected'] as num?)?.toDouble() ?? 0,
        totalEarned = (json['totalEarned'] as num?)?.toDouble() ?? 0;

  final String? studentId;
  final String? name;
  final String? college;
  final String? major;
  final String? grade;
  final String? totalCredit;
  final String? requiredCredit;
  final String? selectedCredit;
  final double requiredExpected;
  final double electiveExpected;
  final double otherExpected;
  final double requiredEarned;
  final double electiveEarned;
  final double otherEarned;
  final double totalExpected;
  final double totalEarned;
}

class NoticeItem {
  NoticeItem.fromJson(Map<String, dynamic> json)
      : category = json['category'] as String? ?? '通知',
        title = _noticeTitleFromJson(json),
        date = json['date'] as String?,
        url = json['url'] as String?,
        summary = _noticeSummaryFromJson(json),
        coverUrl = _firstText(json, const ['coverUrl', 'cover_url', 'cover']);

  final String category;
  final String title;
  final String? date;
  final String? url;
  final String? summary;
  final String? coverUrl;
}

String _noticeTitleFromJson(Map<String, dynamic> json) {
  final direct = _firstText(json, const [
    'title',
    'noticeTitle',
    'name',
    'subject',
    'bt',
    'xxbt',
  ]);
  if (direct != null) return direct;

  final summary = _noticeSummaryFromJson(json);
  if (summary == null) return '';
  return summary.split(RegExp(r'[\r\n]')).first.trim();
}

String? _noticeSummaryFromJson(Map<String, dynamic> json) {
  return _firstText(json, const [
    'summary',
    'contentSummary',
    'content_summary',
    'description',
    'desc',
  ]);
}

String? _firstText(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value == null) continue;
    final text = _cleanNoticeText(value);
    if (text.isNotEmpty && !_looksGarbledNoticeText(text)) return text;
  }
  return null;
}

String _cleanNoticeText(Object? value) {
  if (value == null) return '';
  return value
      .toString()
      .replaceAll(RegExp('[\\u0000-\\u001F\\u007F-\\u009F\\uFFFD]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

bool _looksGarbledNoticeText(String text) {
  if (RegExp('[\\u0080-\\u009F\\uFFFD]').hasMatch(text)) return true;
  if (RegExp(r'[\u4E00-\u9FFF]').hasMatch(text)) return false;
  final hasMojibakeLetter = RegExp(
    r'[ÃÂÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿ]',
  ).hasMatch(text);
  final hasMojibakeMark =
      RegExp(r'[€œžŸ¢£¥§¨©ª«¬®¯°±²³´µ¶·¸¹º»¼½¾¿–—]').hasMatch(text);
  return hasMojibakeLetter && hasMojibakeMark;
}

bool _isReadableNoticeItem(NoticeItem item) {
  final title = _cleanNoticeText(item.title);
  final summary = _cleanNoticeText(item.summary);
  final category = _cleanNoticeText(item.category);
  final candidate = title.isNotEmpty ? title : summary;
  if (candidate.isEmpty) return false;
  if (_looksGarbledNoticeText(title) ||
      _looksGarbledNoticeText(summary) ||
      _looksGarbledNoticeText(category)) {
    return false;
  }
  return RegExp(r'[A-Za-z0-9\u4E00-\u9FFF]').hasMatch(candidate);
}

class NoticeDetail {
  NoticeDetail.fromJson(Map<String, dynamic> json)
      : title = json['title'] as String? ?? '',
        date = json['date'] as String?,
        contentHtml = json['contentHtml'] as String? ?? '',
        url = json['url'] as String? ?? '';

  final String title;
  final String? date;
  final String contentHtml;
  final String url;
}

class LeavePreviewResponse {
  LeavePreviewResponse.fromJson(Map<String, dynamic> json)
      : status = json['status'] as String? ?? 'ok',
        hasMissingFields = json['hasMissingFields'] as bool? ?? false,
        items = (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((item) => LeaveCourseItem.fromJson(item))
            .toList();

  final String status;
  final bool hasMissingFields;
  final List<LeaveCourseItem> items;
}

class LeaveCourseItem {
  LeaveCourseItem.fromJson(Map<String, dynamic> json)
      : courseName = json['courseName'] as String? ?? '',
        courseCode = json['courseCode'] as String?,
        teachingClassCode = json['teachingClassCode'] as String?,
        courseNature = json['courseNature'] as String?,
        credit = json['credit'] as String?,
        classTime = json['classTime'] as String? ?? '',
        classTimes = (json['classTimes'] as List<dynamic>? ?? const [])
            .map((item) => item.toString())
            .toList(),
        absenceCount = json['absenceCount'] as int? ?? 0,
        teacher = json['teacher'] as String?,
        missingFields = (json['missingFields'] as List<dynamic>? ?? const [])
            .map((item) => item.toString())
            .toList();

  final String courseName;
  final String? courseCode;
  final String? teachingClassCode;
  final String? courseNature;
  final String? credit;
  final String classTime;
  final List<String> classTimes;
  final int absenceCount;
  final String? teacher;
  final List<String> missingFields;
}

class LeaveFillResponse {
  LeaveFillResponse.fromJson(Map<String, dynamic> json)
      : status = json['status'] as String? ?? 'needs_manual',
        message = json['message'] as String? ?? '',
        formUrl = json['formUrl'] as String?,
        fillScript = json['fillScript'] as String?,
        handlerScript = json['handlerScript'] as String?,
        unmatchedTeachers =
            (json['unmatchedTeachers'] as List<dynamic>? ?? const [])
                .map((item) => item.toString())
                .toList(),
        matchedTeachers =
            (json['matchedTeachers'] as List<dynamic>? ?? const [])
                .whereType<Map<String, dynamic>>()
                .map((item) => MatchedTeacherItem.fromJson(item))
                .toList(),
        teacherCandidates =
            (json['teacherCandidates'] as List<dynamic>? ?? const [])
                .whereType<Map<String, dynamic>>()
                .map((item) => TeacherCandidateGroup.fromJson(item))
                .toList(),
        attachmentUploaded = json['attachmentUploaded'] as bool? ?? false,
        items = (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((item) => LeaveCourseItem.fromJson(item))
            .toList();

  final String status;
  final String message;
  final String? formUrl;
  final String? fillScript;
  final String? handlerScript;
  final List<String> unmatchedTeachers;
  final List<MatchedTeacherItem> matchedTeachers;
  final List<TeacherCandidateGroup> teacherCandidates;
  final bool attachmentUploaded;
  final List<LeaveCourseItem> items;

  String? get combinedScript {
    final fill = fillScript?.trim();
    final handler = handlerScript?.trim();
    if ((fill == null || fill.isEmpty) &&
        (handler == null || handler.isEmpty)) {
      return null;
    }
    return '''
(async () => {
  const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  function notice(message) {
    let box = document.getElementById('gzus-leave-automation-status');
    if (!box) {
      box = document.createElement('div');
      box.id = 'gzus-leave-automation-status';
      box.style.cssText = 'position:fixed;z-index:999999;right:16px;top:56px;max-width:360px;padding:10px 12px;background:#1677ff;color:#fff;border-radius:6px;font-size:14px;line-height:1.5;box-shadow:0 4px 14px rgba(0,0,0,.2)';
      document.body.appendChild(box);
    }
    box.textContent = message;
  }
  function installDialogBypass() {
    if (window.__gzusLeaveDialogBypassInstalled) return;
    window.__gzusLeaveDialogBypassInstalled = true;
    window.__gzusLeaveAlerts = [];
    window.__gzusLeaveNativeAlert = window.alert;
    window.__gzusLeaveNativeConfirm = window.confirm;
    window.alert = (message) => {
      window.__gzusLeaveAlerts.push(String(message ?? ''));
      console.warn('[GZUS leave alert]', message);
    };
    window.confirm = (message) => {
      window.__gzusLeaveAlerts.push(String(message ?? ''));
      console.warn('[GZUS leave confirm]', message);
      return true;
    };
  }
  function visible(el) {
    if (!el) return false;
    const style = getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden') return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }
  function refreshAttachmentList() {
    try {
      if (typeof LoadAttachments === 'function') LoadAttachments('file1');
    } catch (_) {}
    const frame = document.getElementById('fileframe_file1') || document.querySelector('iframe[id^="fileframe"]');
    if (frame?.src) {
      const base = frame.src.replace(/([?&])reload=1(&|\$)/, '\$1').replace(/[?&]\$/, '');
      frame.src = base + (base.includes('?') ? '&' : '?') + 'reload=1&_=' + Date.now();
    }
  }
  function clickHandleButton() {
    const button = document.querySelector('a.submitbtn[onclick*="prepareSubmit"], a.submitbtn');
    if (!button) return false;
    button.click();
    return true;
  }
  function handlerReady() {
    return Boolean(
      document.getElementById('WF_T10004') ||
      [...document.querySelectorAll('td,div,span,label')]
        .some((el) => visible(el) && /任课教师审批|辅导员审批/.test(el.innerText || ''))
    );
  }
  function cleanEasyUiMasks() {
    document.querySelectorAll('.window-mask').forEach((mask) => {
      mask.style.display = 'none';
      mask.style.pointerEvents = 'none';
    });
    document.querySelectorAll('.panel.window').forEach((panel) => {
      const title = panel.querySelector('.panel-title,.window-header')?.innerText || '';
      if (title && !title.includes('处理文档')) {
        panel.style.display = 'none';
      }
    });
  }
  function findFinalSubmitButton() {
    cleanEasyUiMasks();
    const candidates = [
      ...document.querySelectorAll('a,button,input[type="button"],input[type="submit"]')
    ].filter((el) => {
      const text = (el.innerText || el.value || '').trim();
      if (text !== '提交') return false;
      if (!visible(el)) return false;
      const href = el.getAttribute('href') || '';
      return !href.includes('javascript:history');
    });
    return candidates[0] || null;
  }

  installDialogBypass();
  notice('正在填写请假表单...');
  ${fill ?? ''}
  refreshAttachmentList();
  await delay(1000);
  notice('附件已上传，正在点击办理...');
  if (!clickHandleButton()) {
    notice('未找到办理按钮，请手动点击办理。');
    return;
  }
  for (let i = 0; i < 60 && !handlerReady(); i += 1) {
    await delay(500);
  }
  notice('正在选择任课教师经办人...');
  ${handler ?? ''}
  await delay(800);
  cleanEasyUiMasks();
  const finalSubmit = findFinalSubmitButton();
  if (finalSubmit) {
    try { finalSubmit.scrollIntoView({ block: 'center' }); } catch (_) {}
    finalSubmit.style.outline = '3px solid #ff4d4f';
    finalSubmit.style.outlineOffset = '2px';
    notice('已停在最终提交前。请检查后手动点击“提交”。');
    return;
  }
  notice('已选择经办人。未定位到最终提交按钮，请检查处理文档窗口。');
})();
''';
  }
}

class MatchedTeacherItem {
  MatchedTeacherItem({
    required this.teacher,
    required this.userid,
    required this.cnName,
    this.courseName,
  });

  MatchedTeacherItem.fromJson(Map<String, dynamic> json)
      : teacher = json['teacher'] as String? ?? '',
        userid = json['userid'] as String? ?? '',
        cnName = json['cnName'] as String? ?? '',
        courseName = json['courseName'] as String?;

  final String teacher;
  final String userid;
  final String cnName;
  final String? courseName;

  Map<String, dynamic> toJson() => {
        'teacher': teacher,
        'userid': userid,
        'cnName': cnName,
        if (courseName != null) 'courseName': courseName,
      };
}

class StaffCandidateItem {
  StaffCandidateItem.fromJson(Map<String, dynamic> json)
      : userid = json['userid'] as String? ?? '',
        cnName = json['cnName'] as String? ?? '',
        folderName = json['folderName'] as String?;

  final String userid;
  final String cnName;
  final String? folderName;
}

class TeacherCandidateGroup {
  TeacherCandidateGroup.fromJson(Map<String, dynamic> json)
      : teacher = json['teacher'] as String? ?? '',
        candidates = (json['candidates'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((item) => StaffCandidateItem.fromJson(item))
            .toList();

  final String teacher;
  final List<StaffCandidateItem> candidates;
}

class EhallAffairItem {
  EhallAffairItem.fromJson(Map<String, dynamic> json)
      : id = json['id'] as String?,
        title = json['title'] as String? ?? '',
        department = json['department'] as String?,
        type = json['type'] as String?,
        tags = (json['tags'] as List<dynamic>? ?? const [])
            .map((item) => item.toString())
            .where((item) => item.isNotEmpty)
            .toList(),
        summary = json['summary'] as String?,
        url = json['url'] as String?;

  final String? id;
  final String title;
  final String? department;
  final String? type;
  final List<String> tags;
  final String? summary;
  final String? url;
}

class EhallApplicationItem {
  EhallApplicationItem.fromJson(Map<String, dynamic> json)
      : id = json['id'] as String?,
        title = json['title'] as String? ?? '',
        department = json['department'] as String?,
        type = json['type'] as String?,
        tags = (json['tags'] as List<dynamic>? ?? const [])
            .map((item) => item.toString())
            .where((item) => item.isNotEmpty)
            .toList(),
        summary = json['summary'] as String?,
        url = json['url'] as String?;

  final String? id;
  final String title;
  final String? department;
  final String? type;
  final List<String> tags;
  final String? summary;
  final String? url;
}

class EhallProgressItem {
  EhallProgressItem.fromJson(Map<String, dynamic> json)
      : id = json['id'] as String?,
        title = json['title'] as String? ?? '',
        category = json['category'] as String? ?? '',
        status = json['status'] as String? ?? 'unknown',
        statusLabel = json['statusLabel'] as String? ?? '',
        date = json['date'] as String?,
        summary = json['summary'] as String?,
        currentNode = json['currentNode'] as String?,
        handler = json['handler'] as String?,
        progress = _intValue(json['progress']),
        url = json['url'] as String?;

  final String? id;
  final String title;
  final String category;
  final String status;
  final String statusLabel;
  final String? date;
  final String? summary;
  final String? currentNode;
  final String? handler;
  final int? progress;
  final String? url;
}

class EhallProgressCategory {
  EhallProgressCategory.fromJson(Map<String, dynamic> json)
      : label = json['label'] as String? ?? '',
        count = _intValue(json['count']) ?? 0;

  final String label;
  final int count;
}

class EhallProgressOverview {
  EhallProgressOverview({
    required this.categories,
    required this.items,
  });

  EhallProgressOverview.fromJson(Map<String, dynamic> json)
      : categories = (json['categories'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((item) => EhallProgressCategory.fromJson(item))
            .where((item) => item.label.isNotEmpty)
            .toList(),
        items = (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((item) => EhallProgressItem.fromJson(item))
            .toList();

  factory EhallProgressOverview.fromItems(List<EhallProgressItem> items) {
    const labels = ['待办', '申请', '已办', '关注', '待阅', '已阅', '草稿'];
    return EhallProgressOverview(
      categories: [
        for (final label in labels)
          EhallProgressCategory.fromJson({
            'label': label,
            'count': items.where((item) => item.category == label).length,
          }),
      ],
      items: items,
    );
  }

  final List<EhallProgressCategory> categories;
  final List<EhallProgressItem> items;

  int countFor(String label) {
    for (final category in categories) {
      if (category.label == label) return category.count;
    }
    return items.where((item) => item.category == label).length;
  }
}

class EcardRoomItem {
  EcardRoomItem.fromJson(Map<String, dynamic> json)
      : id = json['id'] as String? ?? '',
        schoolArea = json['schoolArea'] as String? ?? '',
        building = json['building'] as String? ?? '',
        room = json['room'] as String? ?? '',
        displayName = json['displayName'] as String? ?? '';

  final String id;
  final String schoolArea;
  final String building;
  final String room;
  final String displayName;
}

class EcardSummary {
  EcardSummary.fromJson(Map<String, dynamic> json)
      : status = json['status'] as String? ?? 'not_bound',
        studentId = json['studentId'] as String?,
        roomId = json['roomId'] as String?,
        roomDisplay = json['roomDisplay'] as String?,
        powerBalance = _doubleFromJson(json['powerBalance']),
        powerUnit = json['powerUnit'] as String? ?? '度',
        powerText = json['powerText'] as String?,
        coldWaterBalance = _doubleFromJson(json['coldWaterBalance']),
        coldWaterUnit = json['coldWaterUnit'] as String? ?? '吨',
        coldWaterText = json['coldWaterText'] as String?,
        hotWaterBalance = _doubleFromJson(json['hotWaterBalance']),
        hotWaterUnit = json['hotWaterUnit'] as String? ?? '元',
        hotWaterText = json['hotWaterText'] as String?,
        reminderEnabled = json['reminderEnabled'] as bool? ?? true,
        lowPowerThreshold = _doubleFromJson(json['lowPowerThreshold']) ?? 30.0,
        lowColdWaterThreshold =
            _doubleFromJson(json['lowColdWaterThreshold']) ?? 5.0,
        lowHotWaterThreshold =
            _doubleFromJson(json['lowHotWaterThreshold']) ?? 10.0,
        reminderTimes = (json['reminderTimes'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            ['08:00'],
        reminderItems = (json['reminderItems'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            ['power', 'cold_water', 'hot_water'],
        updatedAt = json['updatedAt'] as String?,
        stale = json['stale'] as bool? ?? false,
        staleReason = json['staleReason'] as String?;

  final String status;
  final String? studentId;
  final String? roomId;
  final String? roomDisplay;
  final double? powerBalance;
  final String powerUnit;
  final String? powerText;
  final double? coldWaterBalance;
  final String coldWaterUnit;
  final String? coldWaterText;
  final double? hotWaterBalance;
  final String hotWaterUnit;
  final String? hotWaterText;
  final bool reminderEnabled;
  final double lowPowerThreshold;
  final double lowColdWaterThreshold;
  final double lowHotWaterThreshold;
  final List<String> reminderTimes;
  final List<String> reminderItems;
  final String? updatedAt;
  final bool stale;
  final String? staleReason;

  bool get isBound => status == 'ok';
  bool get isLowPower =>
      powerBalance != null && powerBalance! < lowPowerThreshold;
  bool get isLowColdWater =>
      coldWaterBalance != null && coldWaterBalance! < lowColdWaterThreshold;
  bool get isLowHotWater =>
      hotWaterBalance != null && hotWaterBalance! < lowHotWaterThreshold;
  bool get isCriticalPower => powerBalance != null && powerBalance! < 10;
}

class EcardConsumptionResponse {
  EcardConsumptionResponse.fromJson(Map<String, dynamic> json)
      : status = json['status'] as String? ?? 'limited',
        message = json['message'] as String?,
        items = (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((item) => EcardConsumptionItem.fromJson(item))
            .toList();

  final String status;
  final String? message;
  final List<EcardConsumptionItem> items;
}

class EcardConsumptionItem {
  EcardConsumptionItem.fromJson(Map<String, dynamic> json)
      : title = json['title'] as String? ?? '',
        amount = json['amount'] as String? ?? '',
        time = json['time'] as String? ?? '';

  final String title;
  final String amount;
  final String time;
}

double? _doubleFromJson(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String && value.trim().isNotEmpty && value != 'null') {
    return double.tryParse(value);
  }
  return null;
}
