class BackgroundNotificationStatus {
  const BackgroundNotificationStatus({
    required this.enabled,
    required this.courseRemindersEnabled,
    required this.lastCheckedAt,
    required this.lastError,
    required this.courseSyncError,
    required this.noticesEnabled,
    required this.gradesEnabled,
    required this.examsEnabled,
    required this.attendanceEnabled,
    required this.attendanceLastCheckedAt,
    required this.attendanceLastError,
  });

  factory BackgroundNotificationStatus.fromJson(Map<String, dynamic> json) {
    final rawCheckedAt = json['lastCheckedAt'] as String?;
    final rawAttendanceCheckedAt = json['attendanceLastCheckedAt'] as String?;
    return BackgroundNotificationStatus(
      enabled: json['enabled'] == true,
      courseRemindersEnabled: json['courseRemindersEnabled'] == true,
      lastCheckedAt:
          rawCheckedAt == null ? null : DateTime.tryParse(rawCheckedAt),
      lastError: json['lastError'] as String?,
      courseSyncError: json['courseSyncError'] as String?,
      noticesEnabled: json['noticesEnabled'] != false,
      gradesEnabled: json['gradesEnabled'] != false,
      examsEnabled: json['examsEnabled'] != false,
      attendanceEnabled: json['attendanceEnabled'] != false,
      attendanceLastCheckedAt: rawAttendanceCheckedAt == null
          ? null
          : DateTime.tryParse(rawAttendanceCheckedAt),
      attendanceLastError: json['attendanceLastError'] as String?,
    );
  }

  final bool enabled;
  final bool courseRemindersEnabled;
  final DateTime? lastCheckedAt;
  final String? lastError;
  final String? courseSyncError;
  final bool noticesEnabled;
  final bool gradesEnabled;
  final bool examsEnabled;
  final bool attendanceEnabled;
  final DateTime? attendanceLastCheckedAt;
  final String? attendanceLastError;
}
