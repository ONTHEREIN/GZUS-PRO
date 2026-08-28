/// 课表与日期共享工具：消除 main.dart / api_client.dart / reminder_service.dart
/// 三处重复的周次计算、日期格式化与节次时间表定义。
library;

/// 返回给定日期所在周的周一（零点）。
DateTime mondayOf(DateTime date) {
  final day = DateTime(date.year, date.month, date.day);
  return day.subtract(Duration(days: day.weekday - DateTime.monday));
}

/// 根据日期推导当前应使用的学年学期（与后端 academic_period.py 保持一致）。
/// 8-12 月、1 月 → 第 1 学期（秋）；2-7 月 → 第 2 学期（春）。
/// 8 月起即按即将开始的新学年处理，避免暑假导入到上一学年。
(int, int) academicPeriodOf(DateTime date) {
  final year = date.month >= 8 ? date.year : date.year - 1;
  final term = date.month >= 8 || date.month == 1 ? 1 : 2;
  return (year, term);
}

/// 根据首次导入时间预填即将使用的学年学期。
///
/// 1 月仍使用上一学年第一学期；2-7 月预填上一学年第二学期；
/// 8 月起预填当学年第一学期，以便暑假新用户直接导入新课表。
(int, int) onboardingAcademicPeriodOf(DateTime date) {
  return academicPeriodOf(date);
}

/// 用已保存的各学期开学日期（键 "{year}-{term}"，值 yyyy-MM-dd）反推
/// 当前学期：学期区间为 [开学周一, 开学周一 + 30 周)，相邻学期区间可能重叠，
/// 多个命中取开学日期最新者。新学年已开始时，不允许上学年的遗留记录回退学期；
/// 无命中或数据缺失返回 null（回退 [academicPeriodOf]）。
(int, int)? academicPeriodFromFirstWeeks(
    Map<String, String> firstWeeks, DateTime date) {
  final today = DateTime(date.year, date.month, date.day);
  final currentAcademicYear = academicPeriodOf(today).$1;
  (DateTime, int, int)? best;
  for (final entry in firstWeeks.entries) {
    final parts = entry.key.split('-');
    if (parts.length != 2) continue;
    final year = int.tryParse(parts[0]);
    final term = int.tryParse(parts[1]);
    if (year == null || term == null || (term != 1 && term != 2)) continue;
    if (year < currentAcademicYear) continue;
    final start = DateTime.tryParse(entry.value);
    if (start == null) continue;
    final end = start.add(const Duration(days: 30 * 7));
    if (today.isBefore(start) || !today.isBefore(end)) continue;
    if (best == null || start.isAfter(best.$1)) {
      best = (start, year, term);
    }
  }
  return best == null ? null : (best.$2, best.$3);
}

/// 根据学年和学期推导默认的第一周周一。
/// 第 1 学期（秋）9 月 1 日起，第 2 学期（春）3 月 1 日起。
DateTime defaultFirstWeekStart(int year, int term) {
  final seed = term == 1 ? DateTime(year, 9, 1) : DateTime(year + 1, 3, 1);
  return mondayOf(seed);
}

/// 从考试时间文本解析出开始/结束时间；解析失败返回 null。
(DateTime, DateTime)? parseExamDateRange(String? time) {
  if (time == null) return null;
  final dateMatch =
      RegExp(r'(\d{4})[年/\-.](\d{1,2})[月/\-.](\d{1,2})').firstMatch(time);
  if (dateMatch == null) return null;
  final year = int.tryParse(dateMatch.group(1)!);
  final month = int.tryParse(dateMatch.group(2)!);
  final day = int.tryParse(dateMatch.group(3)!);
  if (year == null || month == null || day == null) return null;

  final timeMatches = RegExp(r'(\d{1,2}):(\d{2})').allMatches(time).toList();
  if (timeMatches.length >= 2) {
    final startHour = int.tryParse(timeMatches[0].group(1)!) ?? 0;
    final startMinute = int.tryParse(timeMatches[0].group(2)!) ?? 0;
    final endHour = int.tryParse(timeMatches[1].group(1)!) ?? 0;
    final endMinute = int.tryParse(timeMatches[1].group(2)!) ?? 0;
    return (
      DateTime(year, month, day, startHour, startMinute),
      DateTime(year, month, day, endHour, endMinute),
    );
  }
  return (DateTime(year, month, day, 9), DateTime(year, month, day, 11));
}

/// 计算 [date] 相对 [firstWeekStart]（学期第一周周一）的周次（1 起）。
/// 传入 [clampToTerm] 时把结果限制在 1..30（学期最大周数）。
int weekFromDate(DateTime firstWeekStart, DateTime date,
    {bool clampToTerm = false}) {
  final value =
      mondayOf(date).difference(mondayOf(firstWeekStart)).inDays ~/ 7 + 1;
  return clampToTerm ? value.clamp(1, 30) : value;
}

/// 格式化为 `yyyy-MM-dd`。
String dateText(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// 16 节课的起止时间（record 形式，`$1`=开始、`$2`=结束）。
const scheduleTimes = <(String, String)>[
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
