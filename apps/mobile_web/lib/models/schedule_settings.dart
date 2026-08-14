/// 按用户绑定的课表偏好设置（云端同步）。
///
/// [firstWeeks] 键为 "{year}-{term}"（如 "2026-1"），值为 yyyy-MM-dd 字符串
/// （已归一化为周一），与本地 SharedPreferences 键 schedule.$year.$term.firstWeekStart 对应。
class ScheduleSettings {
  const ScheduleSettings({
    required this.firstWeeks,
    required this.autoWeek,
    required this.onboardingCompleted,
  });

  final Map<String, String> firstWeeks;
  final bool autoWeek;
  final bool onboardingCompleted;

  factory ScheduleSettings.fromJson(Map<String, dynamic> json) {
    return ScheduleSettings(
      firstWeeks: Map<String, String>.from(
          json['firstWeeks'] as Map? ?? const {}),
      autoWeek: json['autoWeek'] as bool? ?? true,
      onboardingCompleted: json['onboardingCompleted'] as bool? ?? false,
    );
  }
}
