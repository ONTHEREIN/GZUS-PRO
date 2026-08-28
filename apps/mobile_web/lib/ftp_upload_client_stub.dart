import 'ftp_upload_models.dart';

bool get isFtpSupported => false;

String get ftpPlatformLabel => 'Web';

Never _unsupported() {
  throw const FtpUploadException('UNSUPPORTED', '当前平台不支持客户端 FTP');
}

Future<void> testConnection(FtpConfig config) async => _unsupported();

Future<List<FtpEntry>> listDirectory(FtpConfig config, String path) async =>
    _unsupported();

Future<FtpUploadResult> uploadFile({
  required FtpConfig config,
  required String localPath,
  required String remoteDirectory,
}) async =>
    _unsupported();

Future<FtpDownloadResult> downloadFile({
  required FtpConfig config,
  required String remotePath,
  required String localPath,
}) async =>
    _unsupported();
