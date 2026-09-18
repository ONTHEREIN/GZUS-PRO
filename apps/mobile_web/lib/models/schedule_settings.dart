/// 按用户绑定的课表偏好设置（云端同步）。
///
/// [firstWeeks] 键为 "{year}-{term}"（如 "2026-1"），值为 yyyy-MM-dd 字符串
/// （已归一化为周一），与本地账号作用域的 SharedPreferences 键对应。
class ScheduleSettings {
  const ScheduleSettings({
    required this.firstWeeks,
    required this.autoWeek,
    required this.onboardingCompleted,
    this.display,
  });

  final Map<String, String> firstWeeks;
  final bool autoWeek;
  final bool onboardingCompleted;
  final ScheduleDisplaySettings? display;

  factory ScheduleSettings.fromJson(Map<String, dynamic> json) {
    return ScheduleSettings(
      firstWeeks:
          Map<String, String>.from(json['firstWeeks'] as Map? ?? const {}),
      autoWeek: json['autoWeek'] as bool? ?? true,
      onboardingCompleted: json['onboardingCompleted'] as bool? ?? false,
      display: json['display'] is Map
          ? ScheduleDisplaySettings.fromJson(
              Map<String, dynamic>.from(json['display'] as Map),
            )
          : null,
    );
  }
}

class ScheduleDisplaySettings {
  const ScheduleDisplaySettings({
    required this.showTime,
    required this.showClassroom,
    required this.showTeacher,
  });

  final bool showTime;
  final bool showClassroom;
  final bool showTeacher;

  factory ScheduleDisplaySettings.fromJson(Map<String, dynamic> json) {
    return ScheduleDisplaySettings(
      showTime: json['showTime'] as bool? ?? true,
      showClassroom: json['showClassroom'] as bool? ?? true,
      showTeacher: json['showTeacher'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'showTime': showTime,
        'showClassroom': showClassroom,
        'showTeacher': showTeacher,
      };
}
