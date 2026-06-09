import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FtpConfig {
  const FtpConfig({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.passiveMode = true,
    this.timeoutSeconds = 15,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final bool passiveMode;
  final int timeoutSeconds;

  Map<String, Object?> toChannelArgs({String? path, String? localPath}) {
    return {
      'host': host,
      'port': port,
      'username': username,
      'password': password,
      'passiveMode': passiveMode,
      'timeoutSeconds': timeoutSeconds,
      if (path != null) 'path': path,
      if (localPath != null) 'localPath': localPath,
    };
  }
}

class FtpEntry {
  const FtpEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;

  factory FtpEntry.fromMap(Map<dynamic, dynamic> map) {
    return FtpEntry(
      name: map['name']?.toString() ?? '',
      path: map['path']?.toString() ?? '',
      isDirectory: map['isDirectory'] == true,
      size: (map['size'] as num?)?.toInt() ?? 0,
    );
  }
}

class FtpUploadResult {
  const FtpUploadResult({required this.remotePath, required this.bytesSent});

  final String remotePath;
  final int bytesSent;

  factory FtpUploadResult.fromMap(Map<dynamic, dynamic> map) {
    return FtpUploadResult(
      remotePath: map['remotePath']?.toString() ?? '',
      bytesSent: (map['bytesSent'] as num?)?.toInt() ?? 0,
    );
  }
}

class FtpDownloadResult {
  const FtpDownloadResult({required this.localPath, required this.bytesReceived});

  final String localPath;
  final int bytesReceived;

  factory FtpDownloadResult.fromMap(Map<dynamic, dynamic> map) {
    return FtpDownloadResult(
      localPath: map['localPath']?.toString() ?? '',
      bytesReceived: (map['bytesReceived'] as num?)?.toInt() ?? 0,
    );
  }
}

class FtpUploadException implements Exception {
  const FtpUploadException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class SavedFtpSettings {
  const SavedFtpSettings({
    this.host = 'ftp.school.local',
    this.port = 21,
    this.username = '',
    this.password = '',
    this.passiveMode = true,
    this.lastDirectory = '/',
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final bool passiveMode;
  final String lastDirectory;
}

class FtpUploadService {
  FtpUploadService._();

  static const int maxFileBytes = 100 * 1024 * 1024;
  static const _channel = MethodChannel('cn.gzus.pro/ftp');
  static const _secureStorage = FlutterSecureStorage();
  static const _passwordKey = 'ftp.password';

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<SavedFtpSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final password = await _secureStorage.read(key: _passwordKey) ?? '';
    return SavedFtpSettings(
      host: prefs.getString('ftp.host') ?? 'ftp.school.local',
      port: prefs.getInt('ftp.port') ?? 21,
      username: prefs.getString('ftp.username') ?? '',
      password: password,
      passiveMode: prefs.getBool('ftp.passiveMode') ?? true,
      lastDirectory: prefs.getString('ftp.lastDirectory') ?? '/',
    );
  }

  static Future<void> saveSettings({
    required String host,
    required int port,
    required String username,
    required String password,
    required bool passiveMode,
    required String lastDirectory,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ftp.host', host);
    await prefs.setInt('ftp.port', port);
    await prefs.setString('ftp.username', username);
    await prefs.setBool('ftp.passiveMode', passiveMode);
    await prefs.setString('ftp.lastDirectory', lastDirectory);
    await _secureStorage.write(key: _passwordKey, value: password);
  }

  static Future<void> testConnection(FtpConfig config) async {
    await _invoke('testConnection', config.toChannelArgs());
  }

  static Future<List<FtpEntry>> listDirectory(
      FtpConfig config, String path) async {
    final result = await _invoke<List<dynamic>>(
        'listDirectory', config.toChannelArgs(path: path));
    return (result ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map(FtpEntry.fromMap)
        .toList();
  }

  static Future<FtpUploadResult> uploadFile({
    required FtpConfig config,
    required String localPath,
    required String remoteDirectory,
  }) async {
    final result = await _invoke<Map<dynamic, dynamic>>(
      'uploadFile',
      config.toChannelArgs(path: remoteDirectory, localPath: localPath),
    );
    return FtpUploadResult.fromMap(result ?? const {});
  }

  static Future<FtpDownloadResult> downloadFile({
    required FtpConfig config,
    required String remotePath,
    required String localPath,
  }) async {
    final result = await _invoke<Map<dynamic, dynamic>>(
      'downloadFile',
      {
        ...config.toChannelArgs(),
        'remotePath': remotePath,
        'localPath': localPath,
      },
    );
    return FtpDownloadResult.fromMap(result ?? const {});
  }

  static Future<T?> _invoke<T>(String method, Map<String, Object?> args) async {
    if (!isSupported) {
      throw const FtpUploadException('unsupported', '当前平台不支持客户端 FTP');
    }
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw FtpUploadException(e.code, e.message ?? 'FTP 操作失败');
    }
  }
}
