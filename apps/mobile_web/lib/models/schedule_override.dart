import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api_client.dart';

/// 课表「本地调课」条目：仅存本机（SharedPreferences，按学年学期隔离），
/// 不改动学校系统数据，只在课表页叠加显示。
///
/// 三种形态：
/// - 新增：[matchKey] 为 null → 在课表末尾追加 [course]（可填 [weeks] 限定周次）；
/// - 调整（替换）：[matchKey] 非空且 [hidden]=false → 把匹配到的学校课程整学期替换为 [course]；
/// - 停课（隐藏）：[matchKey] 非空且 [hidden]=true → 移除匹配到的学校课程；
///   填了 [weeks]（如 "8"）时表示仅这些周停课，周/日视图按当前周过滤，全部视图保留原条目。
class ScheduleOverride {
  const ScheduleOverride({
    required this.id,
    this.matchKey,
    this.matchWeekday,
    this.matchStartSection,
    this.weeks,
    required this.hidden,
    this.course,
    this.note,
  });

  final String id;
  /// 匹配键：`'kch:<课程代码>'` 或 `'name:<课程名>'`；null 表示新增课程。
  final String? matchKey;
  /// 可选匹配限定：星期（1-7）。
  final int? matchWeekday;
  /// 可选匹配限定：开始节次。
  final int? matchStartSection;
  /// 作用周次（同教务 `zcd` 格式，如 "8"、"1-16周(单)"）；空 = 全部周。
  final String? weeks;
  /// true = 停课（隐藏匹配课程）；false = 新增/替换显示 [course]。
  final bool hidden;
  /// 新增或替换后显示的课程内容。
  final ScheduleCourse? course;
  /// 备注（如调课原因）。
  final String? note;

  /// 新增课程
  bool get isAdd => matchKey == null && !hidden;
  /// 停课（隐藏）
  bool get isHide => matchKey != null && hidden;
  /// 调整（替换）
  bool get isReplace => matchKey != null && !hidden;

  factory ScheduleOverride.fromJson(Map<String, dynamic> json) {
    return ScheduleOverride(
      id: json['id'] as String? ?? '',
      matchKey: json['matchKey'] as String?,
      matchWeekday: _intValue(json['matchWeekday']),
      matchStartSection: _intValue(json['matchStartSection']),
      weeks: json['weeks'] as String?,
      hidden: json['hidden'] as bool? ?? false,
      course: json['course'] is Map<String, dynamic>
          ? ScheduleCourse.fromJson(json['course'] as Map<String, dynamic>)
          : null,
      note: json['note'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        if (matchKey != null) 'matchKey': matchKey,
        if (matchWeekday != null) 'matchWeekday': matchWeekday,
        if (matchStartSection != null) 'matchStartSection': matchStartSection,
        if (weeks != null) 'weeks': weeks,
        'hidden': hidden,
        if (course != null) 'course': course!.toJson(),
        if (note != null) 'note': note,
      };

  /// 用已保存数据派生副本（表单保存时使用）。
  ScheduleOverride copyWith({
    String? matchKey,
    int? matchWeekday,
    int? matchStartSection,
    String? weeks,
    bool? hidden,
    ScheduleCourse? course,
    String? note,
  }) {
    return ScheduleOverride(
      id: id,
      matchKey: matchKey ?? this.matchKey,
      matchWeekday: matchWeekday ?? this.matchWeekday,
      matchStartSection: matchStartSection ?? this.matchStartSection,
      weeks: weeks ?? this.weeks,
      hidden: hidden ?? this.hidden,
      course: course ?? this.course,
      note: note ?? this.note,
    );
  }
}

/// 本地调课条目的持久化（SharedPreferences，按学年学期隔离）。
class ScheduleOverrideStore {
  static String keyOf(int year, int term) =>
      'schedule.localOverrides.$year.$term';

  static Future<List<ScheduleOverride>> load(int year, int term) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(keyOf(year, term));
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>? ?? const [];
      return [
        for (final item in list)
          if (item is Map<String, dynamic>)
            ScheduleOverride.fromJson(item),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(
      int year, int term, List<ScheduleOverride> overrides) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      keyOf(year, term),
      jsonEncode([for (final o in overrides) o.toJson()]),
    );
  }
}

/// 判断 [override] 是否匹配学校课程条目（matchKey + 可选的星期/节次限定）。
bool overrideMatches(ScheduleOverride override, ScheduleCourse course) {
  final key = override.matchKey;
  if (key == null) return false;
  if (key.startsWith('kch:')) {
    final kch = course.raw['kch'];
    if (kch == null || kch.toString() != key.substring(4)) return false;
  } else if (key.startsWith('name:')) {
    if (course.name != key.substring(5)) return false;
  } else {
    return false;
  }
  if (override.matchWeekday != null &&
      course.weekday != override.matchWeekday) {
    return false;
  }
  if (override.matchStartSection != null &&
      course.startSection != override.matchStartSection) {
    return false;
  }
  return true;
}

/// 把本地调课条目叠加到学校课表上：
/// 1. 匹配到的课程：整学期停课（[hidden] 且 weeks 为空）→ 移除；
///    周次限定停课 → 保留原条目（由渲染层按周过滤）；替换 → 换成 [ScheduleOverride.course]；
/// 2. 末尾追加所有「新增」课程。
///
/// 替换/新增课程标记 `isLocal=true`，渲染层据此显示「调」徽标。
List<ScheduleCourse> applyScheduleOverrides(
  List<ScheduleCourse> items,
  List<ScheduleOverride> overrides,
) {
  if (overrides.isEmpty) return items;
  final result = <ScheduleCourse>[];
  for (final item in items) {
    final override = _firstMatch(overrides, item);
    if (override == null) {
      result.add(item);
    } else if (override.hidden) {
      // 周次限定的停课保留原条目，周/日视图按当前周过滤
      final weeks = override.weeks?.trim();
      if (weeks == null || weeks.isEmpty) continue;
      result.add(item);
    } else if (override.course != null) {
      result.add(override.course!.copyWith(isLocal: true));
    }
  }
  for (final override in overrides) {
    if (override.isAdd && override.course != null) {
      result.add(override.course!.copyWith(isLocal: true));
    }
  }
  return result;
}

/// 周/日视图过滤：匹配到周次限定的停课条目且当前周在停课周内 → 隐藏。
/// [currentWeek] 为 null（全部视图）时周次限定不生效（保留原条目）。
/// 本地课程（含替换/新增）不参与停课匹配。
bool isHiddenByOverrides(
  ScheduleCourse course,
  List<ScheduleOverride> overrides, {
  int? currentWeek,
}) {
  if (course.isLocal) return false;
  for (final override in overrides) {
    if (!override.hidden || !overrideMatches(override, course)) continue;
    final weeks = override.weeks?.trim();
    if (weeks == null || weeks.isEmpty) return true;
    if (currentWeek != null && weekSpecContains(weeks, currentWeek)) {
      return true;
    }
  }
  return false;
}

ScheduleOverride? _firstMatch(
    List<ScheduleOverride> overrides, ScheduleCourse course) {
  for (final override in overrides) {
    if (overrideMatches(override, course)) return override;
  }
  return null;
}

int? _intValue(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// 生成课程匹配键：优先 kch（课程代码），否则课程名。
String? matchKeyForCourse(ScheduleCourse course) {
  final kch = course.raw['kch'];
  if (kch != null && kch.toString().trim().isNotEmpty) {
    return 'kch:${kch.toString().trim()}';
  }
  return 'name:${course.name}';
}

/// 构造「调至另一天」条目：把课程整体移到 [targetWeekday]
/// （节次/教室/教师/周次保持不变）。
///
/// [existing] 非空时（本地课程再次调天）在原条目上改 course 并保留匹配信息；
/// 否则生成一条替换学校课程的新条目。
ScheduleOverride buildMoveToDayOverride({
  required ScheduleCourse course,
  required int targetWeekday,
  ScheduleOverride? existing,
  String? id,
}) {
  final sourceCourse = existing?.course ?? course;
  final nextCourse = sourceCourse.copyWith(weekday: targetWeekday);
  final note =
      '从周${_weekdayChar(course.weekday)}调到周${_weekdayChar(targetWeekday)}';
  if (existing != null) {
    return existing.copyWith(course: nextCourse, note: note);
  }
  return ScheduleOverride(
    id: id ?? DateTime.now().microsecondsSinceEpoch.toString(),
    matchKey: matchKeyForCourse(course),
    matchWeekday: course.weekday,
    matchStartSection: course.startSection,
    hidden: false,
    course: nextCourse,
    note: note,
  );
}

String _weekdayChar(int? weekday) {
  if (weekday == null || weekday < 1 || weekday > 7) return '?';
  return '周${'一二三四五六日'[weekday - 1]}';
}

/// 判断周次描述（支持 "1-8周"、"1-16周(单)"、"3,5,7" 等格式）是否包含 [week]。
/// 无数字段视为包含所有周；空描述返回 true。
bool weekSpecContains(String spec, int week) {
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
    // 段内出现数字即视为明确指定周次（单/双周不匹配时同样按“指定了”处理）
    if (RegExp(r'\d').hasMatch(text)) foundNumber = true;
    final oddOnly = text.contains('单');
    final evenOnly = text.contains('双');
    if (oddOnly && week.isEven) continue;
    if (evenOnly && week.isOdd) continue;

    final ranges = RegExp(r'(\d+)\s*-\s*(\d+)').allMatches(text).toList();
    if (ranges.isNotEmpty) {
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
      if (int.tryParse(match.group(0)!) == week) return true;
    }
  }
  return !foundNumber;
}
