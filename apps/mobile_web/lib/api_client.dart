import 'dart:convert';

import 'package:http/http.dart' as http;

const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8000',
);

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
    this.captchaToken,
    this.captchaImage,
  });

  factory LoginResult.fromJson(Map<String, dynamic> json) => LoginResult(
        status: json['status'] as String,
        sessionId: json['sessionId'] as String?,
        studentName: json['studentName'] as String?,
        captchaToken: json['captchaToken'] as String?,
        captchaImage: json['captchaImage'] as String?,
      );

  final String status;
  final String? sessionId;
  final String? studentName;
  final String? captchaToken;
  final String? captchaImage;
}

class StudentInfo {
  StudentInfo({
    required this.studentId,
    required this.name,
    this.college,
    this.major,
    this.className,
    this.grade,
    this.photoDataUrl,
  });

  factory StudentInfo.fromJson(Map<String, dynamic> json) => StudentInfo(
        studentId: json['studentId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        college: json['college'] as String?,
        major: json['major'] as String?,
        className: json['className'] as String?,
        grade: json['grade'] as String?,
        photoDataUrl: json['photoDataUrl'] as String?,
      );

  final String studentId;
  final String name;
  final String? college;
  final String? major;
  final String? className;
  final String? grade;
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
      : courseName = json['courseName'] as String? ?? '',
        time = json['time'] as String?,
        location = json['location'] as String?,
        seat = json['seat'] as String?,
        type = json['type'] as String?;

  final String courseName;
  final String? time;
  final String? location;
  final String? seat;
  final String? type;
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

class AttendanceResponse {
  AttendanceResponse.fromJson(Map<String, dynamic> json)
      : status = json['status'] as String? ?? 'not_implemented',
        items = (json['items'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()
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
        total = json['total'] as int? ?? 0;

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
        title = json['title'] as String? ?? '',
        date = json['date'] as String?,
        url = json['url'] as String?,
        summary = json['summary'] as String?;

  final String category;
  final String title;
  final String? date;
  final String? url;
  final String? summary;
}

class ApiClient {
  ApiClient({http.Client? httpClient, this.baseUrl = apiBaseUrl})
      : _http = httpClient ?? http.Client();

  final http.Client _http;
  final String baseUrl;
  String? sessionId;

  void useSession(String? value) {
    sessionId = value;
  }

  String lySsoStartUrl({required String returnUrl}) {
    final uri = Uri.parse('$baseUrl/auth/ly/start');
    return uri.replace(queryParameters: {'return_url': returnUrl}).toString();
  }

  Future<LoginResult> login(String account, String password) async {
    final response = await _post('/auth/login', {
      'account': account,
      'password': password,
    });
    final result = LoginResult.fromJson(response);
    sessionId = result.sessionId;
    return result;
  }

  Future<LoginResult> submitCaptcha(String token, String code) async {
    final response = await _post('/auth/captcha', {
      'captchaToken': token,
      'code': code,
    });
    final result = LoginResult.fromJson(response);
    sessionId = result.sessionId;
    return result;
  }

  Future<LoginResult> completeLySso(String ssoCode) async {
    final response = await _post('/auth/ly/complete', {'ssoCode': ssoCode});
    final result = LoginResult.fromJson(response);
    sessionId = result.sessionId;
    return result;
  }

  Future<LoginResult> mobileCookieLogin(String account, String cookies) async {
    final response = await _post('/auth/mobile-cookie-login', {
      'account': account,
      'cookies': cookies,
    });
    final result = LoginResult.fromJson(response);
    sessionId = result.sessionId;
    return result;
  }

  Future<void> logout() async {
    await _post('/auth/logout', {});
    sessionId = null;
  }

  Future<StudentInfo> me() async => StudentInfo.fromJson(await _get('/me'));

  Future<ScheduleResult> schedule(
      {required int year, required int term}) async {
    final data = await _getList('/schedule?year=$year&term=$term');
    return ScheduleResult(
      raw: data,
      items: data.map((item) => ScheduleCourse.fromJson(item)).toList(),
    );
  }

  Future<List<ExamItem>> exams({required int year, required int term}) async {
    final data = await _getList('/exams?year=$year&term=$term');
    return data.map((item) => ExamItem.fromJson(item)).toList();
  }

  Future<List<GradeItem>> grades({required int year, required int term}) async {
    final data = await _getList('/grades?year=$year&term=$term');
    return data.map((item) => GradeItem.fromJson(item)).toList();
  }

  Future<AttendanceResponse> attendance(
      {required int year, required int term}) async {
    return AttendanceResponse.fromJson(
        await _get('/attendance?year=$year&term=$term'));
  }

  Future<List<CreditItem>> credits() async {
    final data = await _getList('/credits');
    return data.map((item) => CreditItem.fromJson(item)).toList();
  }

  Future<List<NoticeItem>> notices() async {
    final data = await _getList('/notices');
    return data.map((item) => NoticeItem.fromJson(item)).toList();
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final response =
        await _http.get(Uri.parse('$baseUrl$path'), headers: _headers());
    return _decodeObject(response);
  }

  Future<List<Map<String, dynamic>>> _getList(String path) async {
    final response =
        await _http.get(Uri.parse('$baseUrl$path'), headers: _headers());
    final decoded = _decode(response);
    return (decoded as List<dynamic>).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    final response = await _http.post(
      Uri.parse('$baseUrl$path'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    return _decodeObject(response);
  }

  Map<String, String> _headers() => {
        'Content-Type': 'application/json',
        if (sessionId != null) 'X-Session-Id': sessionId!,
      };

  Map<String, dynamic> _decodeObject(http.Response response) {
    final decoded = _decode(response);
    return decoded as Map<String, dynamic>;
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
