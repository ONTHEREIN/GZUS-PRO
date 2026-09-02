class BackgroundNotificationStatus {
  const BackgroundNotificationStatus({
    required this.enabled,
    required this.courseRemindersEnabled,
    required this.lastCheckedAt,
    required this.lastError,
    required this.courseSyncError,
  });

  factory BackgroundNotificationStatus.fromJson(Map<String, dynamic> json) {
    final rawCheckedAt = json['lastCheckedAt'] as String?;
    return BackgroundNotificationStatus(
      enabled: json['enabled'] == true,
      courseRemindersEnabled: json['courseRemindersEnabled'] == true,
      lastCheckedAt:
          rawCheckedAt == null ? null : DateTime.tryParse(rawCheckedAt),
      lastError: json['lastError'] as String?,
      courseSyncError: json['courseSyncError'] as String?,
    );
  }

  final bool enabled;
  final bool courseRemindersEnabled;
  final DateTime? lastCheckedAt;
  final String? lastError;
  final String? courseSyncError;
}
