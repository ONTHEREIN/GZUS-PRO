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
  const FtpDownloadResult({
    required this.localPath,
    required this.bytesReceived,
  });

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
