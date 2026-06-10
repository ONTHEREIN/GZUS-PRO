import 'dart:convert';
import 'dart:async';
import 'dart:io' show HttpClient, SocketException;

import 'package:flutter/foundation.dart';
import 'package:http/io_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'persistent_cache.dart';

const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: '',
);

List<String> _parseApiBaseUrlCandidates(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return [];
  return trimmed
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

String _normalizeSingle(String url) {
  final normalized = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  if (defaultTargetPlatform == TargetPlatform.android) {
    final uri = Uri.tryParse(normalized);
    if (uri != null && (uri.host == '127.0.0.1' || uri.host == 'localhost')) {
      return uri.replace(host: '10.0.2.2').toString();
    }
  }
  return normalized;
}

String _defaultApiBaseUrl() {
  // 默认指向 Cloudflare Pages Worker（亚太节点，大陆用户延迟较低）
  // 可通过 `flutter build --dart-define=API_BASE_URL=...` 覆盖
  // 优先使用自定义域名（如果已配置），回退到 pages.dev 子域名
  const customDomain = 'https://onegzus.cc.cd';
  const cloudflareWorker = 'https://onegzus-onweb.pages.dev';

  if (kReleaseMode) return customDomain;

  // 开发环境：优先使用自定义域名，同时保留 Cloudflare Worker 作为回退候选
  return customDomain;
}

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

  bool get isStale => fromCache || fromLocalCache;
}

class DataResult<T> {
  const DataResult({required this.data, this.source = const DataSourceInfo()});

  final T data;
  final DataSourceInfo source;
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
    this.ehallCookies,
    this.ehallAuthToken,
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
        ehallCookies: json['ehallCookies'] as String?,
        ehallAuthToken: json['ehallAuthToken'] as String?,
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

  /// 办事大厅 WebView 登录态。
  final String? ehallCookies;
  final String? ehallAuthToken;
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
            : json;

  final String name;
  final String? teacher;
  final String? classroom;
  final int? weekday;
  final int? startSection;
  final int? endSection;
  final String? weeks;
  final String? kcbmc;
  final Map<String, dynamic> raw;

  bool occursInWeek(int week) {
    final spec = weeks?.trim();
    if (spec == null || spec.isEmpty) return true;
    return _weekSpecContains(spec, week);
  }
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
        summary = _noticeSummaryFromJson(json);

  final String category;
  final String title;
  final String? date;
  final String? url;
  final String? summary;
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
        updatedAt = json['updatedAt'] as String?;

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

http.Client _createDefaultClient() {
  if (kIsWeb) {
    return http.Client();
  }
  final ioClient = HttpClient();
  ioClient.userAgent = 'GZUS-PRO/1.0';
  return IOClient(ioClient);
}

class ApiClient {
  ApiClient({http.Client? httpClient, String? baseUrl, RequestCache? cache})
      : _http = httpClient ?? _createDefaultClient(),
        _cache = cache ?? RequestCache() {
    final raw = baseUrl ?? apiBaseUrl;
    _candidates = _buildCandidates(raw);
    this.baseUrl = _candidates.isEmpty ? '' : _candidates.first;
    _currentBaseUrl = this.baseUrl;
  }

  static List<String> _buildCandidates(String raw) {
    final list = _parseApiBaseUrlCandidates(raw);
    final defaults = _parseApiBaseUrlCandidates(_defaultApiBaseUrl());
    if (list.isEmpty) return defaults;
    final merged = list.map(_normalizeSingle).toList();
    for (final defaultUrl in defaults) {
      if (!merged.contains(defaultUrl)) {
        merged.add(defaultUrl);
      }
    }
    return merged;
  }

  final http.Client _http;
  late final String baseUrl;
  late final List<String> _candidates;
  final RequestCache _cache;
  final Map<String, Future<void>> _backgroundRefreshes = {};
  final Map<String, DateTime> _backgroundRefreshAt = {};
  String? sessionId;
  String? _studentId;
  PersistentCache? _persistentCache;
  Future<PersistentCache>? _persistentCacheFuture;
  String? _credentialToken;
  String? _ehallCookies;
  String? _ehallAuthToken;

  /// 当前使用的 baseUrl（可能因连接失败自动切换）
  String _currentBaseUrl = '';

  /// 当自动重新登录失败时调用的回调，UI 层可用来导航到登录页
  void Function()? onReloginFailed;

  /// --- Relogin backoff state ---
  /// Tracks the last time a relogin attempt was made and how many
  /// consecutive failures occurred.  Prevents hammering the CAS server
  /// when relogin keeps failing.
  DateTime? _lastReloginAttempt;
  int _consecutiveReloginFailures = 0;

  /// Minimum interval between relogin attempts (increases with failures).
  static const Duration _reloginMinInterval = Duration(seconds: 5);
  static const int _reloginMaxBackoffSeconds = 120;

  static const Duration _backgroundRefreshCooldown = Duration(minutes: 5);

  String get namespace => _studentId ?? sessionId ?? 'default';
  String? get studentId => _studentId;
  String? get ehallCookies => _ehallCookies;
  String? get ehallAuthToken => _ehallAuthToken;

  void setEhallCookies(String? value) {
    _ehallCookies = value;
  }

  void setEhallAuthToken(String? value) {
    _ehallAuthToken = value;
  }

  void useSession(String? value) {
    if (sessionId != value) _cache.clear();
    sessionId = value;
  }

  void setStudentId(String? value) {
    if (_studentId != value) {
      _studentId = value;
      _persistentCache = null;
      _persistentCacheFuture = null;
    }
  }

  Future<PersistentCache> _getPersistentCache() async {
    final cache = _persistentCache;
    if (cache != null) return cache;

    final initializing = _persistentCacheFuture;
    if (initializing != null) return initializing;

    final cacheNamespace = namespace;
    final future = () async {
      final cache = PersistentCache(namespace: cacheNamespace);
      await cache.init();
      if (cacheNamespace == namespace) {
        _persistentCache = cache;
      }
      return cache;
    }();
    _persistentCacheFuture = future;
    try {
      return await future;
    } finally {
      if (_persistentCacheFuture == future) {
        _persistentCacheFuture = null;
      }
    }
  }

  DataSourceInfo _localSource(DateTime? cachedAt) => DataSourceInfo(
        fromLocalCache: true,
        cachedAt: cachedAt,
      );

  DataSourceInfo _offlineSource(DateTime? cachedAt, ApiException error) =>
      DataSourceInfo(
        fromLocalCache: true,
        cachedAt: cachedAt,
        isOffline: true,
        needsRelogin: error.statusCode == 401,
      );

  Map<String, dynamic>? _cachedObject(PersistentCache cache, String key) {
    final cached = cache.getRaw(key);
    return cached is Map<String, dynamic> ? cached : null;
  }

  List<Map<String, dynamic>>? _cachedList(PersistentCache cache, String key) {
    final cached = cache.getRaw(key);
    if (cached is! List<dynamic>) return null;
    final result = <Map<String, dynamic>>[];
    for (final item in cached) {
      if (item is! Map<String, dynamic>) return null;
      result.add(item);
    }
    return result;
  }

  void _queueBackgroundRefresh(
    String cacheKey,
    Future<void> Function() refresh,
  ) {
    if (_backgroundRefreshes.containsKey(cacheKey)) return;
    final lastRefresh = _backgroundRefreshAt[cacheKey];
    if (lastRefresh != null &&
        DateTime.now().difference(lastRefresh) < _backgroundRefreshCooldown) {
      return;
    }
    _backgroundRefreshAt[cacheKey] = DateTime.now();
    late final Future<void> refreshFuture;
    refreshFuture = refresh().catchError((_) {}).whenComplete(() {
      if (_backgroundRefreshes[cacheKey] == refreshFuture) {
        _backgroundRefreshes.remove(cacheKey);
      }
    });
    _backgroundRefreshes[cacheKey] = refreshFuture;
  }

  Future<DataResult<T>> _cacheFirstObject<T>({
    required String cacheKey,
    required Future<Map<String, dynamic>> Function() fetch,
    required T Function(Map<String, dynamic>) fromJson,
    bool forceRefresh = false,
    Duration? memoryTtl,
  }) async {
    if (!forceRefresh) {
      final memCached = _cache.get<Map<String, dynamic>>(cacheKey);
      if (memCached != null) {
        return DataResult<T>(data: fromJson(memCached));
      }
    }

    final pcache = await _getPersistentCache();

    Future<DataResult<T>> fetchAndCache() async {
      final data = await fetch();
      _cache.set(cacheKey, data, memoryTtl);
      await pcache.set(cacheKey, data);
      return DataResult<T>(data: fromJson(data));
    }

    if (!forceRefresh) {
      final cached = _cachedObject(pcache, cacheKey);
      if (cached != null) {
        _cache.set(cacheKey, cached, memoryTtl);
        _queueBackgroundRefresh(cacheKey, () async {
          await fetchAndCache();
        });
        return DataResult<T>(
          data: fromJson(cached),
          source: _localSource(pcache.getCachedAt(cacheKey)),
        );
      }
    }

    try {
      return await fetchAndCache();
    } on ApiException catch (e) {
      final cached = _cachedObject(pcache, cacheKey);
      if (cached != null) {
        return DataResult<T>(
          data: fromJson(cached),
          source: _offlineSource(pcache.getCachedAt(cacheKey), e),
        );
      }
      final memCached = _cache.get<Map<String, dynamic>>(cacheKey);
      if (memCached != null) {
        return DataResult<T>(
          data: fromJson(memCached),
          source: DataSourceInfo(
            fromCache: true,
            needsRelogin: e.statusCode == 401,
          ),
        );
      }
      rethrow;
    } catch (e) {
      final cached = _cachedObject(pcache, cacheKey);
      if (cached != null) {
        return DataResult<T>(
          data: fromJson(cached),
          source: _localSource(pcache.getCachedAt(cacheKey)),
        );
      }
      final memCached = _cache.get<Map<String, dynamic>>(cacheKey);
      if (memCached != null) {
        return DataResult<T>(
          data: fromJson(memCached),
          source: const DataSourceInfo(fromCache: true),
        );
      }
      rethrow;
    }
  }

  Future<DataResult<List<T>>> _cacheFirstList<T>({
    required String cacheKey,
    required Future<List<Map<String, dynamic>>> Function() fetch,
    required T Function(Map<String, dynamic>) fromJson,
    bool forceRefresh = false,
    Duration? memoryTtl,
  }) async {
    if (!forceRefresh) {
      final memCached = _cache.get<List<dynamic>>(cacheKey);
      if (memCached != null) {
        return DataResult<List<T>>(
          data: memCached
              .whereType<Map<String, dynamic>>()
              .map((item) => fromJson(item))
              .toList(),
        );
      }
    }

    final pcache = await _getPersistentCache();

    Future<DataResult<List<T>>> fetchAndCache() async {
      final data = await fetch();
      _cache.set(cacheKey, data, memoryTtl);
      await pcache.set(cacheKey, data);
      return DataResult<List<T>>(
        data: data.map((item) => fromJson(item)).toList(),
      );
    }

    if (!forceRefresh) {
      final cached = _cachedList(pcache, cacheKey);
      if (cached != null) {
        _cache.set(cacheKey, cached, memoryTtl);
        _queueBackgroundRefresh(cacheKey, () async {
          await fetchAndCache();
        });
        return DataResult<List<T>>(
          data: cached.map((item) => fromJson(item)).toList(),
          source: _localSource(pcache.getCachedAt(cacheKey)),
        );
      }
    }

    try {
      return await fetchAndCache();
    } on ApiException catch (e) {
      final cached = _cachedList(pcache, cacheKey);
      if (cached != null) {
        return DataResult<List<T>>(
          data: cached.map((item) => fromJson(item)).toList(),
          source: _offlineSource(pcache.getCachedAt(cacheKey), e),
        );
      }
      final memCached = _cache.get<List<dynamic>>(cacheKey);
      if (memCached != null) {
        return DataResult<List<T>>(
          data: memCached
              .whereType<Map<String, dynamic>>()
              .map((item) => fromJson(item))
              .toList(),
          source: DataSourceInfo(
            fromCache: true,
            needsRelogin: e.statusCode == 401,
          ),
        );
      }
      rethrow;
    } catch (e) {
      final cached = _cachedList(pcache, cacheKey);
      if (cached != null) {
        return DataResult<List<T>>(
          data: cached.map((item) => fromJson(item)).toList(),
          source: _localSource(pcache.getCachedAt(cacheKey)),
        );
      }
      final memCached = _cache.get<List<dynamic>>(cacheKey);
      if (memCached != null) {
        return DataResult<List<T>>(
          data: memCached
              .whereType<Map<String, dynamic>>()
              .map((item) => fromJson(item))
              .toList(),
          source: const DataSourceInfo(fromCache: true),
        );
      }
      rethrow;
    }
  }

  String lySsoStartUrl({required String returnUrl}) {
    final url = _resolveBaseUrl();
    final uri = Uri.parse('$url/auth/ly/start');
    return uri.replace(queryParameters: {'return_url': returnUrl}).toString();
  }

  Future<LoginResult> login(String account, String password) async {
    final response = await _post('/auth/login', {
      'account': account,
      'password': password,
    });
    final result = LoginResult.fromJson(response);
    sessionId = result.sessionId;
    _captureTransientEhallAuth(result);
    _cache.clear();
    return result;
  }

  Future<LoginResult> submitCaptcha(String token, String code) async {
    final response = await _post('/auth/captcha', {
      'captchaToken': token,
      'code': code,
    });
    final result = LoginResult.fromJson(response);
    sessionId = result.sessionId;
    _captureTransientEhallAuth(result);
    _cache.clear();
    return result;
  }

  Future<LoginResult> completeLySso(String ssoCode) async {
    final response = await _post('/auth/ly/complete', {'ssoCode': ssoCode});
    final result = LoginResult.fromJson(response);
    sessionId = result.sessionId;
    _captureTransientEhallAuth(result);
    _cache.clear();
    return result;
  }

  Future<LoginResult> autoLogin(String account, String password) async {
    final response = await _post('/auth/auto-login', {
      'account': account,
      'password': password,
    });
    final result = LoginResult.fromJson(response);
    sessionId = result.sessionId;
    _captureTransientEhallAuth(result);
    _cache.clear();
    if (result.credentialToken != null) {
      _credentialToken = result.credentialToken;
    }
    return result;
  }

  Future<bool> checkHealth() async {
    if (_candidates.isEmpty) return false;
    // Probe all candidates in parallel
    final results = await Future.wait(
      _candidates.map((candidate) async {
        try {
          final response = await _http
              .get(Uri.parse('$candidate/health'), headers: _headers())
              .timeout(const Duration(seconds: 5));
          if (response.statusCode == 200) {
            return candidate;
          }
        } catch (_) {}
        return null;
      }),
    );
    for (final result in results) {
      if (result != null) {
        _currentBaseUrl = result;
        return true;
      }
    }
    return false;
  }

  Future<void> logout() async {
    try {
      final url = _resolveBaseUrl();
      await _http
          .post(Uri.parse('$url/auth/logout'),
              headers: _headers(), body: jsonEncode({}))
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Logout should proceed even if the server request fails.
    }
    sessionId = null;
    _credentialToken = null;
    _ehallCookies = null;
    _ehallAuthToken = null;
    _cache.clear();
  }

  /// 立即清除凭证，防止后续请求触发 relogin 重试
  void clearCredentials() {
    _credentialToken = null;
    _ehallCookies = null;
    _ehallAuthToken = null;
    _cache.clear();
  }

  Future<LoginResult> relogin() async {
    await loadSavedCredentials();
    if (_credentialToken != null) {
      try {
        return await _reloginWithCredentialToken(_credentialToken!);
      } on ApiException catch (exc) {
        if (exc.statusCode == 401) {
          await clearSavedCredentialToken();
        }
        rethrow;
      }
    }
    throw ApiException('教务系统会话已失效，请重新登录', statusCode: 401);
  }

  Future<LoginResult> _reloginWithCredentialToken(
      String credentialToken) async {
    // 直接发HTTP请求，不走 _withReloginRetry，避免 relogin 自身 401 时无限递归
    final url = _resolveBaseUrl();
    final response = await _http
        .post(Uri.parse('$url/auth/relogin'),
            headers: _headers(),
            body: jsonEncode({'credentialToken': credentialToken}))
        .timeout(_requestTimeout);
    final decoded = _decode(response);
    final result = LoginResult.fromJson(decoded as Map<String, dynamic>);
    sessionId = result.sessionId;
    _captureTransientEhallAuth(result);
    _cache.clear();

    await saveCredentialToken(result.credentialToken ?? credentialToken);
    await _saveEhallAuth(result);
    return result;
  }

  Future<void> saveCredentialToken(String? credentialToken) async {
    if (credentialToken == null || credentialToken.isEmpty) return;
    _credentialToken = credentialToken;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth.credentialToken', credentialToken);
  }

  Future<void> clearSavedCredentialToken() async {
    _credentialToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth.credentialToken');
  }

  Future<void> savePasswordCredentials(
    String account,
    String password, {
    required bool remember,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auth.rememberPassword', remember);
    await prefs.remove('auth.password');
    if (!remember) {
      await prefs.remove('auth.account');
      return;
    }
    await prefs.setString('auth.account', account);
  }

  Future<void> _saveEhallAuth(LoginResult result) async {
    final prefs = await SharedPreferences.getInstance();
    if (result.sessionId != null && result.sessionId!.isNotEmpty) {
      await prefs.setString('auth.sessionId', result.sessionId!);
    }
    if (result.ehallCookies != null && result.ehallCookies!.isNotEmpty) {
      await prefs.setString('auth.ehallCookies', result.ehallCookies!);
    } else {
      await prefs.remove('auth.ehallCookies');
    }
    if (result.ehallAuthToken != null && result.ehallAuthToken!.isNotEmpty) {
      await prefs.setString('auth.ehallAuthToken', result.ehallAuthToken!);
    } else {
      await prefs.remove('auth.ehallAuthToken');
    }
  }

  Future<void> loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    _credentialToken = prefs.getString('auth.credentialToken');
    _ehallCookies = prefs.getString('auth.ehallCookies');
    _ehallAuthToken = prefs.getString('auth.ehallAuthToken');
    await prefs.remove('auth.password');
  }

  void _captureTransientEhallAuth(LoginResult result) {
    _ehallCookies = result.ehallCookies;
    _ehallAuthToken = result.ehallAuthToken;
  }

  Future<DataResult<StudentInfo>> me({bool forceRefresh = false}) =>
      _cacheFirstObject<StudentInfo>(
        cacheKey: 'me',
        fetch: () => _get('/me'),
        fromJson: (json) => StudentInfo.fromJson(json),
        forceRefresh: forceRefresh,
      );

  /// Fetch student info asynchronously after login.
  /// This calls the /auth/student-info endpoint which was separated from
  /// the login flow to speed up login response time.
  Future<StudentInfo?> fetchStudentInfo() async {
    try {
      final data = await _get('/auth/student-info');
      final info = StudentInfo.fromJson(data['info'] as Map<String, dynamic>);
      final studentId = data['studentId'] as String?;
      if (studentId != null && studentId.isNotEmpty) {
        setStudentId(studentId);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth.studentId', studentId);
      }
      return info;
    } catch (_) {
      return null;
    }
  }

  Future<DataResult<ScheduleResult>> schedule(
      {required int year, required int term, bool forceRefresh = false}) async {
    final cacheKey = 'schedule_${year}_$term';
    return _cacheFirstList<ScheduleCourse>(
      cacheKey: cacheKey,
      fetch: () => _getList('/schedule?year=$year&term=$term'),
      fromJson: (json) => ScheduleCourse.fromJson(json),
      forceRefresh: forceRefresh,
    ).then(
      (result) => DataResult<ScheduleResult>(
        data: ScheduleResult(
          raw: result.data.map((item) => item.raw).toList(),
          items: result.data,
        ),
        source: result.source,
      ),
    );
  }

  Future<DataResult<List<ExamItem>>> exams(
          {required int year, required int term, bool forceRefresh = false}) =>
      _cacheFirstList<ExamItem>(
        cacheKey: 'exams_${year}_$term',
        fetch: () => _getList('/exams?year=$year&term=$term'),
        fromJson: (json) => ExamItem.fromJson(json),
        forceRefresh: forceRefresh,
      );

  Future<DataResult<List<GradeItem>>> grades(
          {required int year, required int term, bool forceRefresh = false}) =>
      _cacheFirstList<GradeItem>(
        cacheKey: 'grades_${year}_$term',
        fetch: () => _getList('/grades?year=$year&term=$term'),
        fromJson: (json) => GradeItem.fromJson(json),
        forceRefresh: forceRefresh,
      );

  Future<DataResult<AttendanceResponse>> attendance(
          {required int year, required int term, bool forceRefresh = false}) =>
      _cacheFirstObject<AttendanceResponse>(
        cacheKey: 'attendance_${year}_$term',
        fetch: () => _get('/attendance?year=$year&term=$term'),
        fromJson: (json) => AttendanceResponse.fromJson(json),
        forceRefresh: forceRefresh,
      );

  Future<DataResult<List<CreditItem>>> credits({bool forceRefresh = false}) =>
      _cacheFirstList<CreditItem>(
        cacheKey: 'credits',
        fetch: () => _getList('/credits'),
        fromJson: (json) => CreditItem.fromJson(json),
        forceRefresh: forceRefresh,
      );

  Future<DataResult<WeatherData>> weather({
    bool forceRefresh = false,
    double? lat,
    double? lon,
  }) =>
      _cacheFirstObject<WeatherData>(
        cacheKey: _weatherCacheKey(lat, lon),
        fetch: () => _get(_weatherPath(lat, lon)),
        fromJson: (json) => WeatherData.fromJson(json),
        forceRefresh: forceRefresh,
        memoryTtl: const Duration(minutes: 30),
      );

  String _weatherPath(double? lat, double? lon) {
    if (lat != null && lon != null) {
      return '/weather?lat=${lat.toStringAsFixed(2)}&lon=${lon.toStringAsFixed(2)}';
    }
    return '/weather';
  }

  String _weatherCacheKey(double? lat, double? lon) {
    if (lat != null && lon != null) {
      return 'weather_${lat.toStringAsFixed(2)}_${lon.toStringAsFixed(2)}';
    }
    return 'weather';
  }


  Future<DataResult<List<NoticeItem>>> notices(
      {bool forceRefresh = false}) async {
    final result = await _cacheFirstList<NoticeItem>(
      cacheKey: 'notices',
      fetch: () => _getList('/notices'),
      fromJson: (json) => NoticeItem.fromJson(json),
      forceRefresh: forceRefresh,
      memoryTtl: const Duration(minutes: 2),
    );
    return DataResult<List<NoticeItem>>(
      data: result.data.where(_isReadableNoticeItem).toList(),
      source: result.source,
    );
  }

  Future<DataResult<NoticeDetail>> fetchNoticeDetail(
    String url, {
    bool forceRefresh = false,
  }) =>
      _cacheFirstObject<NoticeDetail>(
        cacheKey: 'notice_detail_${Uri.encodeComponent(url)}',
        fetch: () => _get('/notices/detail?url=${Uri.encodeComponent(url)}'),
        fromJson: (json) => NoticeDetail.fromJson(json),
        forceRefresh: forceRefresh,
      );

  Future<LeavePreviewResponse> previewLeave({
    required int year,
    required int term,
    required DateTime startDate,
    required DateTime endDate,
    required DateTime firstWeekStart,
  }) async {
    final data = await _post('/ehall/leave/preview', {
      'year': year,
      'term': term,
      'startDate': _dateOnly(startDate),
      'endDate': _dateOnly(endDate),
      'firstWeekStart': _dateOnly(firstWeekStart),
    });
    return LeavePreviewResponse.fromJson(data);
  }

  Future<LeaveFillResponse> fillLeave({
    required int year,
    required int term,
    required DateTime startDate,
    required DateTime endDate,
    required DateTime firstWeekStart,
    required String reason,
    required String attachmentName,
    required Uint8List attachmentBytes,
    List<MatchedTeacherItem> teacherHandlers = const [],
  }) async {
    final data = await _post('/ehall/leave/fill', {
      'year': year,
      'term': term,
      'startDate': _dateOnly(startDate),
      'endDate': _dateOnly(endDate),
      'firstWeekStart': _dateOnly(firstWeekStart),
      'reason': reason,
      'attachmentName': attachmentName,
      'attachmentContentBase64': base64Encode(attachmentBytes),
      if (teacherHandlers.isNotEmpty)
        'teacherHandlers':
            teacherHandlers.map((item) => item.toJson()).toList(),
    });
    return LeaveFillResponse.fromJson(data);
  }

  Future<bool> uploadLeaveAttachment({
    required String docUnid,
    required String processId,
    required String nodeName,
    required String localStore,
    required String attachmentName,
    required Uint8List attachmentBytes,
  }) async {
    final data = await _post('/ehall/leave/attachment', {
      'docUnid': docUnid,
      'processId': processId,
      'nodeName': nodeName,
      'localStore': localStore,
      'attachmentName': attachmentName,
      'attachmentContentBase64': base64Encode(attachmentBytes),
    });
    return data['uploaded'] as bool? ?? false;
  }

  Future<List<EhallAffairItem>> ehallAffairs(
          {bool forceRefresh = false}) async =>
      (await _cacheFirstList<EhallAffairItem>(
        cacheKey: 'ehall_affairs',
        fetch: () => _getList('/ehall/affairs'),
        fromJson: (json) => EhallAffairItem.fromJson(json),
        forceRefresh: forceRefresh,
        memoryTtl: const Duration(minutes: 10),
      ))
          .data;

  Future<List<EhallApplicationItem>> ehallApplications(
          {bool forceRefresh = false}) async =>
      (await _cacheFirstList<EhallApplicationItem>(
        cacheKey: 'ehall_applications',
        fetch: () => _getList('/ehall/applications'),
        fromJson: (json) => EhallApplicationItem.fromJson(json),
        forceRefresh: forceRefresh,
        memoryTtl: const Duration(minutes: 10),
      ))
          .data;

  Future<EhallProgressOverview> ehallProgressOverview(
          {bool forceRefresh = false}) async =>
      (await _cacheFirstObject<EhallProgressOverview>(
        cacheKey: 'ehall_progress_overview',
        fetch: () => _get('/ehall/progress'),
        fromJson: (json) => EhallProgressOverview.fromJson(json),
        forceRefresh: forceRefresh,
        memoryTtl: const Duration(minutes: 5),
      ))
          .data;

  Future<List<EhallProgressItem>> ehallProgress(
          {bool forceRefresh = false}) async =>
      (await ehallProgressOverview(forceRefresh: forceRefresh)).items;

  Future<List<EcardRoomItem>> ecardRooms({
    String? query,
    int limit = 100,
    bool forceRefresh = false,
  }) async {
    final path = query != null && query.trim().isNotEmpty
        ? '/ecard/rooms?q=${Uri.encodeQueryComponent(query.trim())}&limit=$limit'
        : '/ecard/rooms?limit=$limit';
    final result = await _cacheFirstList<EcardRoomItem>(
      cacheKey: query != null && query.trim().isNotEmpty
          ? 'ecard_rooms_q_${query.trim().toLowerCase()}'
          : 'ecard_rooms',
      fetch: () => _getList(path),
      fromJson: (json) => EcardRoomItem.fromJson(json),
      forceRefresh: forceRefresh,
      memoryTtl: const Duration(minutes: 30),
    );
    return result.data;
  }

  Future<DataResult<EcardSummary>> ecardSummary({bool forceRefresh = false}) =>
      _cacheFirstObject<EcardSummary>(
        cacheKey: 'ecard_summary',
        fetch: () => _get('/ecard/summary'),
        fromJson: (json) => EcardSummary.fromJson(json),
        forceRefresh: forceRefresh,
      );

  Future<EcardSummary> bindEcardRoom(EcardRoomItem room) async {
    final data = await _post('/ecard/binding', {
      'roomId': room.id,
      'roomDisplay': room.displayName,
    });
    _cache.remove('ecard_rooms');
    _cache.set('ecard_summary', data);
    final pcache = await _getPersistentCache();
    await pcache.set('ecard_summary', data);
    return EcardSummary.fromJson(data);
  }

  Future<EcardSummary> refreshEcard() async {
    final data = await _post('/ecard/refresh', {});
    _cache.set('ecard_summary', data);
    final pcache = await _getPersistentCache();
    await pcache.set('ecard_summary', data);
    return EcardSummary.fromJson(data);
  }

  Future<EcardSummary> updateEcardReminder({
    bool? enabled,
    double? lowPowerThreshold,
    double? lowColdWaterThreshold,
    double? lowHotWaterThreshold,
    List<String>? reminderTimes,
    List<String>? reminderItems,
  }) async {
    final data = await _patch('/ecard/reminder', {
      if (enabled != null) 'enabled': enabled,
      if (lowPowerThreshold != null) 'lowPowerThreshold': lowPowerThreshold,
      if (lowColdWaterThreshold != null)
        'lowColdWaterThreshold': lowColdWaterThreshold,
      if (lowHotWaterThreshold != null)
        'lowHotWaterThreshold': lowHotWaterThreshold,
      if (reminderTimes != null) 'reminderTimes': reminderTimes,
      if (reminderItems != null) 'reminderItems': reminderItems,
    });
    _cache.set('ecard_summary', data);
    final pcache = await _getPersistentCache();
    await pcache.set('ecard_summary', data);
    return EcardSummary.fromJson(data);
  }

  Future<EcardConsumptionResponse> ecardConsumption(
          {String? month, bool forceRefresh = false}) async =>
      (await _cacheFirstObject<EcardConsumptionResponse>(
        cacheKey:
            month == null ? 'ecard_consumption' : 'ecard_consumption_$month',
        fetch: () => _get(month == null
            ? '/ecard/consumption'
            : '/ecard/consumption?month=$month'),
        fromJson: (json) => EcardConsumptionResponse.fromJson(json),
        forceRefresh: forceRefresh,
      ))
          .data;

  Future<void> registerPush(String registrationId,
      {String platform = 'android'}) async {
    await _post('/push/register', {
      'registrationId': registrationId,
      'platform': platform,
    });
  }

  Future<void> unregisterPush() async {
    try {
      final url = _resolveBaseUrl();
      await _http
          .post(Uri.parse('$url/push/unregister'),
              headers: _headers(), body: jsonEncode({}))
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Unregister should not block logout even if it fails.
    }
  }

  Future<List<Map<String, dynamic>>> pollPushMessages() async {
    final data = await _get('/push/poll');
    final messages = data['messages'];
    if (messages is! List<dynamic>) return const [];
    return [
      for (final item in messages)
        if (item is Map<String, dynamic>) item,
    ];
  }

  Future<Map<String, dynamic>> getWebPushConfig() async {
    final data = await _get('/push/web/config');
    return data;
  }

  static const Duration _requestTimeout = Duration(seconds: 30);
  static const Duration _connectTimeout = Duration(seconds: 10);
  static const int _maxRetries = 1;

  Future<Map<String, dynamic>> _get(String path) async {
    return _withReloginRetry(
      () async {
        final url = _requireBaseUrl();
        final response = await _http
            .get(Uri.parse('$url$path'), headers: _headers())
            .timeout(_connectTimeout)
            .timeout(_requestTimeout);
        return _decodeObject(response);
      },
    );
  }

  Future<List<Map<String, dynamic>>> _getList(String path) async {
    return _withReloginRetry(
      () async {
        final url = _requireBaseUrl();
        final response = await _http
            .get(Uri.parse('$url$path'), headers: _headers())
            .timeout(_connectTimeout)
            .timeout(_requestTimeout);
        final decoded = _decode(response);
        if (decoded is! List<dynamic>) {
          throw ApiException('服务器返回了意外的数据格式');
        }
        return decoded.whereType<Map<String, dynamic>>().toList();
      },
    );
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    return _withReloginRetry(
      () async {
        final url = _requireBaseUrl();
        final response = await _http
            .post(
              Uri.parse('$url$path'),
              headers: _headers(),
              body: jsonEncode(body),
            )
            .timeout(_connectTimeout)
            .timeout(_requestTimeout);
        return _decodeObject(response);
      },
    );
  }

  Future<Map<String, dynamic>> _patch(
      String path, Map<String, dynamic> body) async {
    return _withReloginRetry(
      () async {
        final url = _requireBaseUrl();
        final response = await _http
            .patch(
              Uri.parse('$url$path'),
              headers: _headers(),
              body: jsonEncode(body),
            )
            .timeout(_connectTimeout)
            .timeout(_requestTimeout);
        return _decodeObject(response);
      },
    );
  }

  String _resolveBaseUrl() {
    if (_currentBaseUrl.isEmpty) _currentBaseUrl = baseUrl;
    return _currentBaseUrl;
  }

  String _requireBaseUrl() {
    final url = _resolveBaseUrl();
    if (url.isEmpty) {
      throw ApiException('未配置 API_BASE_URL，请使用 Vercel 后端地址重新构建应用');
    }
    return url;
  }

  Future<void>? _warmupFuture;
  bool _warmedUp = false;

  void startWarmup() {
    if (_candidates.isEmpty) return;
    if (_warmedUp || _warmupFuture != null) return;
    _warmupFuture = _doWarmup();
  }

  Future<void> _doWarmup() async {
    try {
      // Probe all candidates in parallel, pick the first one that responds
      final results = await Future.wait(
        _candidates.map((candidate) async {
          try {
            final response = await _http
                .get(Uri.parse('$candidate/health'), headers: _headers())
                .timeout(const Duration(seconds: 5));
            if (response.statusCode == 200) {
              return candidate;
            }
          } on TimeoutException {
            // ignore
          } on http.ClientException {
            // ignore
          } on SocketException {
            // ignore
          }
          return null;
        }),
      );
      // Pick the first healthy candidate
      for (final result in results) {
        if (result != null) {
          _currentBaseUrl = result;
          return;
        }
      }
    } finally {
      _warmedUp = true;
    }
  }

  /// 在收到 401 时自动尝试 relogin 并重试原始请求
  Future<T> _withReloginRetry<T>(Future<T> Function() request) async {
    return _withFallback(request, tried: {});
  }

  /// 带候选地址切换的请求重试，每个候选地址只尝试一次
  Future<T> _withFallback<T>(
    Future<T> Function() request, {
    required Set<String> tried,
    int retryCount = 0,
  }) async {
    try {
      return await request();
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        await loadSavedCredentials();
        if (_credentialToken == null) {
          rethrow;
        }
        // --- Relogin with backoff ---
        // Avoid hammering CAS if relogin keeps failing.
        final now = DateTime.now();
        final backoffSeconds = (_reloginMinInterval.inSeconds *
                (1 << _consecutiveReloginFailures.clamp(0, 4)))
            .clamp(_reloginMinInterval.inSeconds, _reloginMaxBackoffSeconds);
        if (_lastReloginAttempt != null &&
            now.difference(_lastReloginAttempt!) <
                Duration(seconds: backoffSeconds)) {
          // Too soon to retry — rethrow so the caller sees the 401
          throw ApiException('教务系统会话已失效，请重新登录', statusCode: 401);
        }
        _lastReloginAttempt = now;
        bool reloginSucceeded = false;
        try {
          await relogin();
          reloginSucceeded = true;
          _consecutiveReloginFailures = 0; // reset on success
        } catch (e) {
          _consecutiveReloginFailures++;
          // relogin 本身失败，清除凭证和触发 onReloginFailed
          _credentialToken = null;
          onReloginFailed?.call();
          rethrow;
        }
        // relogin 成功，重试原始请求
        if (reloginSucceeded) {
          // 重试请求，如果仍然 401 说明该 API 需要特殊权限（如 ehall），
          // 不是 session 过期问题，直接抛出异常
          return await request();
        }
      }
      // 5xx errors: retry once on same host before switching
      if ((e.statusCode ?? 0) >= 500 && retryCount < _maxRetries) {
        return _withFallback(request, tried: tried, retryCount: retryCount + 1);
      }
      rethrow;
    } on TimeoutException {
      // Retry once on same host before switching candidates
      if (retryCount < _maxRetries) {
        return _withFallback(request, tried: tried, retryCount: retryCount + 1);
      }
      final next = _nextUntriedCandidate(tried);
      if (next != null) {
        _currentBaseUrl = next;
        return _withFallback(request, tried: {...tried, next});
      }
      final target = _resolveBaseUrl();
      throw ApiException('请求超时 ($target)，请检查网络连接');
    } on http.ClientException {
      // Retry once on same host before switching candidates
      if (retryCount < _maxRetries) {
        return _withFallback(request, tried: tried, retryCount: retryCount + 1);
      }
      final next = _nextUntriedCandidate(tried);
      if (next != null) {
        _currentBaseUrl = next;
        return _withFallback(request, tried: {...tried, next});
      }
      final target = _resolveBaseUrl();
      throw ApiException('无法连接服务器 ($target)，请确认服务已启动且设备在同一网络');
    } on SocketException {
      // Retry once on same host before switching candidates
      if (retryCount < _maxRetries) {
        return _withFallback(request, tried: tried, retryCount: retryCount + 1);
      }
      final next = _nextUntriedCandidate(tried);
      if (next != null) {
        _currentBaseUrl = next;
        return _withFallback(request, tried: {...tried, next});
      }
      final target = _resolveBaseUrl();
      throw ApiException('无法连接服务器 ($target)，请确认服务已启动且设备在同一网络');
    }
  }

  /// 返回下一个未尝试过的候选地址
  String? _nextUntriedCandidate(Set<String> tried) {
    final current = _resolveBaseUrl();
    final untried =
        _candidates.where((c) => !tried.contains(c) && c != current).toList();
    if (untried.isNotEmpty) return untried.first;
    return null;
  }

  Map<String, String> _headers() => {
        'Content-Type': 'application/json',
        'User-Agent': 'Mozilla/5.0 (Linux; Android 16) GZUS-PRO/1.0',
        if (sessionId != null) 'X-Session-Id': sessionId!,
      };

  Map<String, dynamic> _decodeObject(http.Response response) {
    final decoded = _decode(response);
    if (decoded is! Map<String, dynamic>) {
      throw ApiException('服务器返回了意外的数据格式');
    }
    return decoded;
  }

  dynamic _decode(http.Response response) {
    final body = utf8.decode(response.bodyBytes);
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      if (response.statusCode >= 500) {
        throw ApiException('服务暂时不可用，请稍后重试', statusCode: response.statusCode);
      }
      throw ApiException(body.trim().isEmpty ? '请求失败' : body.trim(),
          statusCode: response.statusCode);
    }
    if (response.statusCode >= 400) {
      final detail = decoded is Map<String, dynamic> ? decoded['detail'] : null;
      throw ApiException(
        detail?.toString() ?? '请求失败',
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }
}

String _dateOnly(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

const icsScheduleTimes = [
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

List<int> parseWeeks(String? weeks) {
  if (weeks == null || weeks.trim().isEmpty) return [];
  final normalized = weeks
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('，', ',')
      .replaceAll('；', ';')
      .replaceAll('、', ',');
  final result = <int>{};
  for (final segment in normalized.split(RegExp(r'[,;]'))) {
    final text = segment.trim();
    if (text.isEmpty) continue;
    final oddOnly = text.contains('单');
    final evenOnly = text.contains('双');
    final ranges = RegExp(r'(\d+)\s*-\s*(\d+)').allMatches(text).toList();
    if (ranges.isNotEmpty) {
      for (final match in ranges) {
        final start = int.tryParse(match.group(1)!);
        final end = int.tryParse(match.group(2)!);
        if (start != null && end != null) {
          for (var w = start; w <= end; w++) {
            if (oddOnly && w.isEven) continue;
            if (evenOnly && w.isOdd) continue;
            result.add(w);
          }
        }
      }
      continue;
    }
    for (final match in RegExp(r'\d+').allMatches(text)) {
      final w = int.tryParse(match.group(0)!);
      if (w != null) {
        if (oddOnly && w.isEven) continue;
        if (evenOnly && w.isOdd) continue;
        result.add(w);
      }
    }
  }
  return result.toList()..sort();
}

String generateIcs({
  required List<ScheduleCourse> courses,
  required DateTime firstWeekStart,
  required int year,
  required int term,
}) {
  final lines = <String>[];
  lines.add('BEGIN:VCALENDAR');
  lines.add('PRODID:-//OneGZUS//Schedule//CN');
  lines.add('VERSION:2.0');
  for (final course in courses) {
    if (course.weekday == null ||
        course.startSection == null ||
        course.endSection == null) {
      continue;
    }
    final weeks = parseWeeks(course.weeks);
    final startTime = icsScheduleTimes[course.startSection! - 1].$1;
    final endTime = icsScheduleTimes[course.endSection! - 1].$2;
    for (final week in weeks) {
      final date = firstWeekStart
          .add(Duration(days: (week - 1) * 7 + (course.weekday! - 1)));
      final dateStr =
          '${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
      lines.add('BEGIN:VEVENT');
      lines.add(
          'UID:gzus-${course.name.hashCode.abs()}-$week-${course.weekday}@onegzus');
      lines.add('DTSTART:${dateStr}T${startTime.replaceAll(':', '')}00');
      lines.add('DTEND:${dateStr}T${endTime.replaceAll(':', '')}00');
      lines.add('SUMMARY:${course.name}');
      if (course.classroom != null && course.classroom!.isNotEmpty) {
        lines.add('LOCATION:${course.classroom}');
      }
      if (course.teacher != null && course.teacher!.isNotEmpty) {
        lines.add('DESCRIPTION:教师: ${course.teacher}');
      }
      lines.add('END:VEVENT');
    }
  }
  lines.add('END:VCALENDAR');
  return lines.join('\r\n');
}

String generateExamIcs({
  required List<PeriodExam> exams,
  required int year,
  required int term,
}) {
  final lines = <String>[];
  lines.add('BEGIN:VCALENDAR');
  lines.add('PRODID:-//OneGZUS//Exams//CN');
  lines.add('VERSION:2.0');
  for (final pe in exams) {
    final exam = pe.exam;
    lines.add('BEGIN:VEVENT');
    lines.add(
        'UID:gzus-exam-${exam.courseName.hashCode.abs()}-${pe.period.year}-${pe.period.term}@onegzus');
    lines.add('SUMMARY:${exam.courseName} 考试');
    final parsed = _parseExamDateTime(exam.time);
    if (parsed != null) {
      lines.add('DTSTART:${parsed.$1}');
      lines.add('DTEND:${parsed.$2}');
    }
    if (exam.location != null && exam.location!.isNotEmpty) {
      lines.add('LOCATION:${exam.location}');
    }
    final descParts = <String>[];
    if (exam.time != null) descParts.add('时间: ${exam.time}');
    if (exam.type != null) descParts.add('类型: ${exam.type}');
    if (exam.seat != null) descParts.add('座位: ${exam.seat}');
    if (descParts.isNotEmpty) {
      lines.add('DESCRIPTION:${descParts.join(' \\n ')}');
    }
    lines.add('END:VEVENT');
  }
  lines.add('END:VCALENDAR');
  return lines.join('\r\n');
}

(String, String)? _parseExamDateTime(String? time) {
  if (time == null) return null;
  final dateMatch =
      RegExp(r'(\d{4})[年/\-.](\d{1,2})[月/\-.](\d{1,2})').firstMatch(time);
  if (dateMatch == null) return null;
  final year = int.tryParse(dateMatch.group(1)!);
  final month = int.tryParse(dateMatch.group(2)!);
  final day = int.tryParse(dateMatch.group(3)!);
  if (year == null || month == null || day == null) return null;
  final dateStr =
      '$year${month.toString().padLeft(2, '0')}${day.toString().padLeft(2, '0')}';
  final timeMatch = RegExp(r'(\d{1,2}):(\d{2})').allMatches(time).toList();
  if (timeMatch.length >= 2) {
    final sh = int.tryParse(timeMatch[0].group(1)!) ?? 0;
    final sm = int.tryParse(timeMatch[0].group(2)!) ?? 0;
    final eh = int.tryParse(timeMatch[1].group(1)!) ?? 0;
    final em = int.tryParse(timeMatch[1].group(2)!) ?? 0;
    return (
      '${dateStr}T${sh.toString().padLeft(2, '0')}${sm.toString().padLeft(2, '0')}00',
      '${dateStr}T${eh.toString().padLeft(2, '0')}${em.toString().padLeft(2, '0')}00',
    );
  }
  return ('${dateStr}T090000', '${dateStr}T110000');
}
