import 'package:flutter/services.dart';

class PermissionService {
  static const _channel = MethodChannel('cn.gzus.pro/permissions');

  static Future<bool> checkAutoStart() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('checkAutoStartPermission');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> checkBatteryOptimization() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('checkBatteryOptimization');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> checkNotificationPermission() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('checkNotificationPermission');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> checkExactAlarmPermission() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('checkExactAlarmPermission');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> openAutoStartSettings() async {
    try {
      final result = await _channel.invokeMethod<bool>('openAutoStartSettings');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> openBatteryOptimizationSettings() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('openBatteryOptimizationSettings');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> openExactAlarmSettings() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('openExactAlarmSettings');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> setHideFromRecents(bool hide) async {
    try {
      final result = await _channel
          .invokeMethod<bool>('setHideFromRecents', {'hide': hide});
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> checkLocationPermission() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('checkLocationPermission');
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> requestLocationPermission() async {
    try {
      await _channel.invokeMethod('requestLocationPermission');
    } catch (_) {}
  }
}
