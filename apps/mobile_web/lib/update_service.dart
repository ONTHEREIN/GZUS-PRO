import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:in_app_update_me/in_app_update_me.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

/// 应用更新检查服务
class UpdateService {
  static const _lastCheckKey = 'update.last_check_ms';
  static const _checkInterval = Duration(hours: 24);

  static final UpdateService _instance = UpdateService._();
  factory UpdateService() => _instance;
  UpdateService._();

  final InAppUpdateMe _inAppUpdate = InAppUpdateMe();

  /// 检查更新（受频率限制，默认24小时一次）
  Future<void> checkForUpdateIfNeeded(
    ApiClient api,
    BuildContext context, {
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

    await _performCheck(api, context);
  }

  /// 强制检查更新（用户手动触发）
  Future<void> forceCheckForUpdate(
    ApiClient api,
    BuildContext context,
  ) async {
    if (kIsWeb) return;
    if (!Platform.isAndroid) return;

    await _performCheck(api, context);
  }

  Future<void> _performCheck(ApiClient api, BuildContext context) async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

      final updateInfo = await api.checkUpdate(
        platform: 'android',
        currentVersion: currentVersion,
        currentBuild: currentBuild,
      );

      // 记录检查时间
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _lastCheckKey, DateTime.now().millisecondsSinceEpoch);

      if (!updateInfo.updateAvailable) return;
      if (!context.mounted) return;

      if (updateInfo.forceUpdate) {
        _showForceUpdateDialog(context, updateInfo);
      } else {
        _showUpdateDialog(context, updateInfo);
      }
    } catch (_) {
      // 静默失败，不影响正常使用
    }
  }

  void _showUpdateDialog(BuildContext context, AppVersionInfo updateInfo) {
    final colorScheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发现新版本'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('最新版本：v${updateInfo.latestVersion}'),
            if (updateInfo.releaseNotes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                updateInfo.releaseNotes,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 14,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍后再说'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _startDownload(updateInfo);
            },
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }

  void _showForceUpdateDialog(BuildContext context, AppVersionInfo updateInfo) {
    final colorScheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('需要更新'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('当前版本过低，请更新到 v${updateInfo.latestVersion} 后继续使用。'),
              if (updateInfo.releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  updateInfo.releaseNotes,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _startDownload(updateInfo);
              },
              child: const Text('立即更新'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startDownload(AppVersionInfo updateInfo) async {
    if (updateInfo.downloadUrl.isEmpty) return;
    try {
      await _inAppUpdate.downloadAndInstallUpdate(updateInfo.downloadUrl);
    } catch (_) {
      // 下载安装失败，静默处理
    }
  }
}
