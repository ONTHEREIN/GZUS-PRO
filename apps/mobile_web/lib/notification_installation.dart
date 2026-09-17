import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class NotificationInstallation {
  static const _preferenceKey = 'notification.installationId';

  static Future<String> id() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_preferenceKey)?.trim();
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final value = List<String>.generate(
      32,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    await prefs.setString(_preferenceKey, value);
    return value;
  }
}
