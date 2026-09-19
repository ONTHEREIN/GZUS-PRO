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

typedef _ContentParser<T> = T Function(
    String rootPath, Map<String, String> files);
typedef _AssetPaths<T> = List<String?> Function(T content);

class ShiplyPublicContentStore {
  static final ShiplyPublicContentStore instance = ShiplyPublicContentStore._();

  ShiplyPublicContentStore._();

  final ReshubFlutter _reshub = ReshubFlutter();
  Future<void>? _initialization;
  ShiplyLoginContent? _loginCached;
  ShiplyHomeContent? _homeCached;

  ShiplyLoginContent? get cachedLogin => _loginCached;
  ShiplyHomeContent? get cachedHome => _homeCached;

  Future<void> initialize() {
    return _initialization ??= _initialize();
  }

  Future<ShiplyLoginContent> loadLoginLatest() async {
    final content = await _loadLatest<ShiplyLoginContent>(
      resourceKey: shiplyLoginContentKey,
      requiredJsonFiles: const ['manifest.json', 'login_slides.json'],
      parser: (rootPath, files) => ShiplyPublicContentParser.parseLogin(
          rootPath: rootPath, files: files),
      assetPaths: (value) =>
          value.loginSlides.map((item) => item.localImagePath).toList(),
    );
    _loginCached = content;
    return content;
  }

  Future<ShiplyHomeContent> loadHomeLatest() async {
    final content = await _loadLatest<ShiplyHomeContent>(
      resourceKey: shiplyHomeContentKey,
      requiredJsonFiles: const [
        'manifest.json',
        'notices.json',
        'wechat_articles.json',
      ],
      parser: (rootPath, files) =>
          ShiplyPublicContentParser.parseHome(rootPath: rootPath, files: files),
      assetPaths: (value) => [
        ...value.notices.map((item) => item.localCoverPath),
        ...value.wechatArticles.map((item) => item.localCoverPath),
      ],
    );
    _homeCached = content;
    return content;
  }

  Future<T> _loadLatest<T>({
    required String resourceKey,
    required List<String> requiredJsonFiles,
    required _ContentParser<T> parser,
    required _AssetPaths<T> assetPaths,
  }) async {
    await initialize();
    LoadResult? result;
    var reason = 'Shiply 资源没有可用本地版本';
    try {
      result = await _reshub.loadLatest(resourceKey);
    } on PlatformException catch (error) {
      reason = 'Shiply SDK 请求失败: ${error.message ?? error.code}';
    } on MissingPluginException catch (error) {
      reason = 'Shiply Flutter 插件未注册: $error';
    }
    final loaded = await _tryReadModel(
      result?.resModel,
      resourceKey,
      requiredJsonFiles,
      parser,
      assetPaths,
    );
    if (loaded != null) return loaded;
    reason = result?.error?.msg ?? reason;

    try {
      final cachedModel = await _reshub.getLatest(resourceKey);
      final cached = await _tryReadModel(
        cachedModel,
        resourceKey,
        requiredJsonFiles,
        parser,
        assetPaths,
      );
      if (cached != null) return cached;
    } on PlatformException catch (error) {
      reason = '$reason; 读取 Shiply 本地缓存失败: ${error.message ?? error.code}';
    } on MissingPluginException catch (error) {
      reason = '$reason; 读取 Shiply 本地缓存失败: $error';
    }
    throw ShiplyPublicContentException(
      'Shiply 资源 $resourceKey 暂不可用，且没有有效本地缓存: $reason',
    );
  }

  Future<T?> _tryReadModel<T>(
    ResModel? model,
    String resourceKey,
    List<String> requiredJsonFiles,
    _ContentParser<T> parser,
    _AssetPaths<T> assetPaths,
  ) async {
    final localPath = model?.localPath;
    if (localPath == null && model?.originLocalPath == null) return null;
    try {
      return await _readContent<T>(
        localPath ?? model!.originLocalPath!,
        model?.originLocalPath,
        resourceKey,
        requiredJsonFiles,
        parser,
        assetPaths,
      );
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
        deviceId, packageInfo.version, kDebugMode, const {});
    if (Platform.isIOS) {
      ReshubFlutter.initReshub(_iosResourceAppId, _iosResourceAppKey, 'online');
      return;
    }
    ReshubFlutter.initReshub(
        _androidResourceAppId, _androidResourceAppKey, 'online');
  }

  Future<T> _readContent<T>(
    String localPath,
    String? originLocalPath,
    String resourceKey,
    List<String> requiredJsonFiles,
    _ContentParser<T> parser,
    _AssetPaths<T> assetPaths,
  ) async {
    final candidates = <String>[
      localPath,
      if (originLocalPath != null) originLocalPath
    ];
    for (final candidate in candidates) {
      final root = await _findResourceRoot(candidate);
      if (root == null) continue;
      final files = <String, String>{};
      for (final name in requiredJsonFiles) {
        final file = File('$root/$name');
        if (!await file.exists()) {
          throw ShiplyPublicContentException(
              'Shiply 资源 $resourceKey 缺少文件: $name');
        }
        files[name] = await file.readAsString();
      }
      final content = parser(root, files);
      await _validateAssets(resourceKey, assetPaths(content));
      return content;
    }
    throw ShiplyPublicContentException(
        'Shiply 资源 $resourceKey 本地路径无效: $localPath');
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

  Future<void> _validateAssets(String resourceKey, List<String?> paths) async {
    for (final path in paths.whereType<String>()) {
      if (!await File(path).exists()) {
        throw ShiplyPublicContentException(
            'Shiply 资源 $resourceKey 媒体文件不存在: $path');
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
