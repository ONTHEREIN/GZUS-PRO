import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用更新检查服务（基于 Shiply）
class UpdateService {
  static const _lastCheckKey = 'update.last_check_ms';
  static const _checkInterval = Duration(hours: 24);
  static const _upgradeChannel = MethodChannel('cn.gzus.pro/upgrade');

  static final UpdateService _instance = UpdateService._();
  factory UpdateService() => _instance;
  UpdateService._();

  /// 检查更新（受频率限制，默认24小时一次）
  Future<void> checkForUpdateIfNeeded({
    bool forceCheck = false,
  }) async {
    if (kIsWeb) return;
    if (!Platform.isAndroid) return;

    if (!forceCheck) {
      final prefs = await SharedPreferences.getInstance();
      final lastCheck = prefs.getInt(_lastCheckKey) ?? 0;
      final elapsed = DateTime.now().millisecondsSinceEpoch - lastCheck;
      if (elapsed < _checkInterval.inMilliseconds) return;
    }

    await _performCheck(isManual: false);
  }

  /// 强制检查更新（用户手动触发）
  Future<void> forceCheckForUpdate() async {
    if (kIsWeb) return;
    if (!Platform.isAndroid) return;

    await _performCheck(isManual: true);
  }

  Future<void> _performCheck({required bool isManual}) async {
    try {
      await _upgradeChannel.invokeMethod('checkUpgrade', {
        'isManual': isManual,
      });

      // 记录检查时间
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _lastCheckKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // 静默失败，不影响正常使用
    }
  }

  /// 获取本地缓存的升级策略信息
  Future<Map<String, dynamic>?> getUpgradeStrategy() async {
    if (kIsWeb) return null;
    if (!Platform.isAndroid) return null;

    try {
      final result = await _upgradeChannel.invokeMethod('getUpgradeStrategy');
      if (result is Map) {
        return Map<String, dynamic>.from(result);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 是否有可用更新（基于本地缓存策略）
  Future<bool> hasUpdate() async {
    final strategy = await getUpgradeStrategy();
    return strategy?['hasUpdate'] == true;
  }
}
