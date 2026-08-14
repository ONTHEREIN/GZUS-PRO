/// 课表与日期共享工具：消除 main.dart / api_client.dart / reminder_service.dart
/// 三处重复的周次计算、日期格式化与节次时间表定义。
library;

/// 返回给定日期所在周的周一（零点）。
DateTime mondayOf(DateTime date) {
  final day = DateTime(date.year, date.month, date.day);
  return day.subtract(Duration(days: day.weekday - DateTime.monday));
}

/// 根据日期推导学年学期（月份启发式，与后端 academic_period.py 保持一致）。
/// 9-12 月、1 月 → 第 1 学期（秋）；2-8 月 → 第 2 学期（春）。
/// 学年从 9 月跨年（9 月起的学年号 = 当前自然年）。
(int, int) academicPeriodOf(DateTime date) {
  final year = date.month >= 9 ? date.year : date.year - 1;
  final term = date.month >= 9 || date.month <= 1 ? 1 : 2;
  return (year, term);
}

/// 用已保存的各学期开学日期（键 "{year}-{term}"，值 yyyy-MM-dd）反推
/// 当前学期：学期区间为 [开学周一, 开学周一 + 30 周)，相邻学期区间可能重叠，
/// 多个命中取开学日期最新者；无命中或数据缺失返回 null（回退 [academicPeriodOf]）。
(int, int)? academicPeriodFromFirstWeeks(
    Map<String, String> firstWeeks, DateTime date) {
  final today = DateTime(date.year, date.month, date.day);
  (DateTime, int, int)? best;
  for (final entry in firstWeeks.entries) {
    final parts = entry.key.split('-');
    if (parts.length != 2) continue;
    final year = int.tryParse(parts[0]);
    final term = int.tryParse(parts[1]);
    if (year == null || term == null || (term != 1 && term != 2)) continue;
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

/// 计算 [date] 相对 [firstWeekStart]（学期第一周周一）的周次（1 起）。
/// 传入 [clampToTerm] 时把结果限制在 1..30（学期最大周数）。
int weekFromDate(DateTime firstWeekStart, DateTime date,
    {bool clampToTerm = false}) {
  final value = mondayOf(date).difference(mondayOf(firstWeekStart)).inDays ~/ 7 + 1;
  return clampToTerm ? value.clamp(1, 30) : value;
}

/// 格式化为 `yyyy-MM-dd`。
String dateText(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// 生成 [year] 年 [month] 月的日历网格：6 行 × 7 列共 42 天，
/// 周一开头，首尾用相邻月的日期补位（如 2026-09 → 首日 8/31、末日 10/11）。
List<DateTime> calendarMonthDays(int year, int month) {
  final first = DateTime(year, month, 1);
  final gridStart = mondayOf(first);
  return List.generate(42, (index) => gridStart.add(Duration(days: index)));
}

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
