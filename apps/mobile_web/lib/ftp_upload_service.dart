import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ftp_upload_client_stub.dart'
    if (dart.library.io) 'ftp_upload_client_io.dart' as ftp_client;
import 'ftp_upload_models.dart';

export 'ftp_upload_models.dart';

class FtpUploadService {
  FtpUploadService._();

  static const int maxFileBytes = 100 * 1024 * 1024;
  static const _secureStorage = FlutterSecureStorage();
  static const _passwordKey = 'ftp.password';

  static bool get isSupported => ftp_client.isFtpSupported;

  static String get platformLabel => ftp_client.ftpPlatformLabel;

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
    await ftp_client.testConnection(config);
  }

  static Future<List<FtpEntry>> listDirectory(
      FtpConfig config, String path) async {
    return ftp_client.listDirectory(config, path);
  }

  static Future<FtpUploadResult> uploadFile({
    required FtpConfig config,
    required String localPath,
    required String remoteDirectory,
  }) async {
    return ftp_client.uploadFile(
      config: config,
      localPath: localPath,
      remoteDirectory: remoteDirectory,
    );
  }

  static Future<FtpDownloadResult> downloadFile({
    required FtpConfig config,
    required String remotePath,
    required String localPath,
  }) async {
    return ftp_client.downloadFile(
      config: config,
      remotePath: remotePath,
      localPath: localPath,
    );
  }
}
