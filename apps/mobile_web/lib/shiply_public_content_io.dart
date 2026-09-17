import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:reshub_flutter/message_protocol_generated.dart';
import 'package:reshub_flutter/reshub_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shiply_public_content_models.dart';

const _androidResourceAppId = String.fromEnvironment(
  'SHIPLY_RESOURCE_ANDROID_APP_ID',
  defaultValue: '6fe87f3a4f',
);
const _androidResourceAppKey = String.fromEnvironment(
  'SHIPLY_RESOURCE_ANDROID_APP_KEY',
  defaultValue: '1428fb40-2640-4c74-a9b4-ea235190b290',
);
const _iosResourceAppId = String.fromEnvironment(
  'SHIPLY_RESOURCE_IOS_APP_ID',
  defaultValue: '8f9d6c4fe4',
);
const _iosResourceAppKey = String.fromEnvironment(
  'SHIPLY_RESOURCE_IOS_APP_KEY',
  defaultValue: '9ad9941e-fcbb-41d7-a2fa-9beb1491ca28',
);

class ShiplyPublicContentStore {
  static final ShiplyPublicContentStore instance = ShiplyPublicContentStore._();

  ShiplyPublicContentStore._();

  final ReshubFlutter _reshub = ReshubFlutter();
  ShiplyPublicContent? _cached;
  Future<void>? _initialization;

  ShiplyPublicContent? get cached => _cached;

  Future<void> initialize() {
    return _initialization ??= _initialize();
  }

  Future<ShiplyPublicContent> loadLatest() async {
    await initialize();
    LoadResult? result;
    var reason = 'Shiply 公共资源没有可用本地版本';
    try {
      result = await _reshub.loadLatest(shiplyPublicContentKey);
    } on PlatformException catch (error) {
      reason = 'Shiply SDK 请求失败: ${error.message ?? error.code}';
    } on MissingPluginException catch (error) {
      reason = 'Shiply Flutter 插件未注册: $error';
    }
    final loaded = await _tryReadModel(result?.resModel);
    if (loaded != null) {
      _cached = loaded;
      return loaded;
    }
    reason = result?.error?.msg ?? reason;

    // loadLatest 失败时，显式读取 SDK 已落盘的最新版本；这仍是 Shiply
    // 本地缓存，不会转向管理员公共内容 API。
    try {
      final cachedModel = await _reshub.getLatest(shiplyPublicContentKey);
      final cached = await _tryReadModel(cachedModel);
      if (cached != null) {
        _cached = cached;
        return cached;
      }
    } on PlatformException catch (error) {
      reason = '$reason; 读取 Shiply 本地缓存失败: ${error.message ?? error.code}';
    } on MissingPluginException catch (error) {
      reason = '$reason; 读取 Shiply 本地缓存失败: $error';
    }
    return _loadCachedAfterError(reason);
  }

  Future<ShiplyPublicContent?> _tryReadModel(ResModel? model) async {
    final localPath = model?.localPath;
    if (localPath == null && model?.originLocalPath == null) return null;
    try {
      return await _readContent(
          localPath ?? model!.originLocalPath!, model?.originLocalPath);
    } on ShiplyPublicContentException {
      return null;
    }
  }

  Future<void> _initialize() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw const ShiplyPublicContentException('Shiply 公共资源仅支持 Android/iOS');
    }
    final missing = <String>[
      if (_androidResourceAppId.isEmpty) 'SHIPLY_RESOURCE_ANDROID_APP_ID',
      if (_androidResourceAppKey.isEmpty) 'SHIPLY_RESOURCE_ANDROID_APP_KEY',
      if (_iosResourceAppId.isEmpty) 'SHIPLY_RESOURCE_IOS_APP_ID',
      if (_iosResourceAppKey.isEmpty) 'SHIPLY_RESOURCE_IOS_APP_KEY',
    ];
    if (missing.isNotEmpty) {
      throw ShiplyPublicContentException(
        'Shiply 公共资源产品配置缺失，请通过 --dart-define 设置: ${missing.join(', ')}',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    final deviceId = prefs.getString('shiply.deviceId') ?? _newDeviceId();
    await prefs.setString('shiply.deviceId', deviceId);
    final packageInfo = await PackageInfo.fromPlatform();
    ReshubFlutter.initReshubCenter(
      deviceId,
      packageInfo.version,
      kDebugMode,
      const <String, String>{},
    );
    if (Platform.isIOS) {
      ReshubFlutter.initReshub(_iosResourceAppId, _iosResourceAppKey, 'online');
      return;
    }
    ReshubFlutter.initReshub(
        _androidResourceAppId, _androidResourceAppKey, 'online');
  }

  Future<ShiplyPublicContent> _loadCachedAfterError(String reason) async {
    final cached = _cached;
    if (cached != null) return cached;
    throw ShiplyPublicContentException(
      'Shiply 公共资源暂不可用，且没有有效本地缓存: $reason',
    );
  }

  Future<ShiplyPublicContent> _readContent(
      String localPath, String? originLocalPath) async {
    final candidates = <String>[
      localPath,
      if (originLocalPath != null) originLocalPath
    ];
    for (final candidate in candidates) {
      final root = await _findResourceRoot(candidate);
      if (root == null) continue;
      final files = <String, String>{};
      for (final name in const [
        'manifest.json',
        'notices.json',
        'login_slides.json',
        'wechat_articles.json',
      ]) {
        final file = File('$root/$name');
        if (!await file.exists()) {
          throw ShiplyPublicContentException('Shiply 公共资源缺少文件: $name');
        }
        files[name] = await file.readAsString();
      }
      final content =
          ShiplyPublicContentParser.parse(rootPath: root, files: files);
      await _validateAssets(content);
      return content;
    }
    throw ShiplyPublicContentException('Shiply 本地资源路径无效: $localPath');
  }

  Future<String?> _findResourceRoot(String path) async {
    final candidate = Directory(path);
    if (await candidate.exists()) return candidate.path;
    final parent = Directory(File(path).parent.path);
    if (await File(path).exists() &&
        await File('${parent.path}/manifest.json').exists()) {
      return parent.path;
    }
    return null;
  }

  Future<void> _validateAssets(ShiplyPublicContent content) async {
    final paths = <String?>[
      ...content.notices.map((item) => item.localCoverPath),
      ...content.loginSlides.map((item) => item.localImagePath),
      ...content.wechatArticles.map((item) => item.localCoverPath),
    ].whereType<String>();
    for (final path in paths) {
      if (!await File(path).exists()) {
        throw ShiplyPublicContentException('Shiply 公共资源媒体文件不存在: $path');
      }
    }
  }

  String _newDeviceId() {
    final random = Random.secure();
    final suffix = List<int>.generate(16, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'gzus-$suffix';
  }
}
