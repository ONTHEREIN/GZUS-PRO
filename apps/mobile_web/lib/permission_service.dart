import 'package:flutter/services.dart';

class PermissionService {
  static const _channel = MethodChannel('cn.gzus.pro/permissions');

  static Future<bool> checkAutoStart() async {
    try {
      final result = await _channel.invokeMethod<bool>('checkAutoStartPermission');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> checkBatteryOptimization() async {
    try {
      final result = await _channel.invokeMethod<bool>('checkBatteryOptimization');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> checkNotificationPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('checkNotificationPermission');
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
      final result = await _channel.invokeMethod<bool>('openBatteryOptimizationSettings');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> setHideFromRecents(bool hide) async {
    try {
      final result = await _channel.invokeMethod<bool>('setHideFromRecents', {'hide': hide});
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }
}
