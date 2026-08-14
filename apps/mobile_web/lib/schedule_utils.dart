/// 课表与日期共享工具：消除 main.dart / api_client.dart / reminder_service.dart
/// 三处重复的周次计算、日期格式化与节次时间表定义。
library;

/// 返回给定日期所在周的周一（零点）。
DateTime mondayOf(DateTime date) {
  final day = DateTime(date.year, date.month, date.day);
  return day.subtract(Duration(days: day.weekday - DateTime.monday));
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
