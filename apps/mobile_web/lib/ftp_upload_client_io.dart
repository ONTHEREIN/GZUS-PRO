import 'dart:async';
import 'dart:io';

import 'package:ftpconnect/ftpconnect.dart';
import 'package:flutter/services.dart';

import 'ftp_upload_models.dart';

const _channel = MethodChannel('cn.gzus.pro/ftp');

bool get isFtpSupported => true;

String get ftpPlatformLabel {
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isWindows) return 'Windows';
  if (Platform.isLinux) return 'Linux';
  return '原生客户端';
}

Future<void> testConnection(FtpConfig config) async {
  if (Platform.isAndroid) {
    await _invokeAndroid<void>('testConnection', config.toChannelArgs());
    return;
  }
  await _withClient<void>(config, (client) async {
    await client.currentDirectory();
  });
}

Future<List<FtpEntry>> listDirectory(FtpConfig config, String path) async {
  if (Platform.isAndroid) {
    final result = await _invokeAndroid<List<dynamic>>(
      'listDirectory',
      config.toChannelArgs(path: path),
    );
    return (result ?? const <dynamic>[])
        .whereType<Map<dynamic, dynamic>>()
        .map(FtpEntry.fromMap)
        .toList(growable: false);
  }
  return _withClient<List<FtpEntry>>(config, (client) async {
    await _changeToVirtualDirectory(client, path);
    final entries = await _listDirectoryEntries(client);
    final directory = _normalizeDirectory(path);
    return entries
        .where((entry) => entry.name != '.' && entry.name != '..')
        .map(
          (entry) => FtpEntry(
            name: entry.name,
            path: _childPath(directory, entry.name),
            isDirectory: entry.type == FTPEntryType.dir ||
                entry.type == FTPEntryType.link,
            size: entry.type == FTPEntryType.file ? entry.size ?? 0 : 0,
          ),
        )
        .toList(growable: false);
  });
}

Future<FtpUploadResult> uploadFile({
  required FtpConfig config,
  required String localPath,
  required String remoteDirectory,
}) async {
  if (Platform.isAndroid) {
    final result = await _invokeAndroid<Map<dynamic, dynamic>>(
      'uploadFile',
      config.toChannelArgs(path: remoteDirectory, localPath: localPath),
    );
    return FtpUploadResult.fromMap(result ?? const <dynamic, dynamic>{});
  }
  final localFile = File(localPath);
  if (!await localFile.exists()) {
    throw const FtpUploadException('FILE_NOT_FOUND', '本地文件不存在');
  }
  return _withClient<FtpUploadResult>(config, (client) async {
    await _changeToVirtualDirectory(client, remoteDirectory);
    final uploaded = await client.uploadFile(localFile);
    if (!uploaded) {
      throw const FtpUploadException('UPLOAD_FAILED', '上传失败');
    }
    return FtpUploadResult(
      remotePath: _childPath(remoteDirectory, _localFileName(localPath)),
      bytesSent: await localFile.length(),
    );
  });
}

Future<FtpDownloadResult> downloadFile({
  required FtpConfig config,
  required String remotePath,
  required String localPath,
}) async {
  if (Platform.isAndroid) {
    final result = await _invokeAndroid<Map<dynamic, dynamic>>(
      'downloadFile',
      {
        ...config.toChannelArgs(),
        'remotePath': remotePath,
        'localPath': localPath,
      },
    );
    return FtpDownloadResult.fromMap(result ?? const <dynamic, dynamic>{});
  }
  if (remotePath.trim().isEmpty) {
    throw const FtpUploadException('INVALID_ARGUMENT', '远程文件路径不能为空');
  }
  if (localPath.trim().isEmpty) {
    throw const FtpUploadException('INVALID_ARGUMENT', '本地保存路径不能为空');
  }
  final localFile = File(localPath);
  await localFile.parent.create(recursive: true);
  return _withClient<FtpDownloadResult>(config, (client) async {
    await _changeToVirtualDirectory(client, _parentDirectory(remotePath));
    final downloaded =
        await client.downloadFile(_fileName(remotePath), localFile);
    if (!downloaded) {
      if (await localFile.exists()) {
        await localFile.delete();
      }
      throw const FtpUploadException('DOWNLOAD_FAILED', '下载失败');
    }
    return FtpDownloadResult(
      localPath: localFile.path,
      bytesReceived: await localFile.length(),
    );
  });
}

Future<T?> _invokeAndroid<T>(String method, Map<String, Object?> args) async {
  try {
    return await _channel.invokeMethod<T>(method, args);
  } on PlatformException catch (error) {
    throw FtpUploadException(error.code, error.message ?? 'FTP 操作失败');
  }
}

Future<T> _withClient<T>(
  FtpConfig config,
  Future<T> Function(FTPConnect client) operation,
) async {
  if (!config.passiveMode) {
    throw const FtpUploadException(
      'UNSUPPORTED',
      '当前原生平台的 FTP 客户端仅支持被动模式，请开启被动模式后重试',
    );
  }
  final client = FTPConnect(
    config.host,
    port: config.port,
    user: config.username,
    pass: config.password,
    timeout: config.timeoutSeconds,
  );
  client.transferMode = TransferMode.passive;
  var connected = false;
  try {
    connected = await client.connect();
    if (!connected) {
      throw const FtpUploadException('NETWORK_ERROR', '无法连接 FTP');
    }
    return await operation(client);
  } on FtpUploadException {
    rethrow;
  } on FTPConnectException catch (error) {
    throw _mapFtpConnectException(error);
  } on SocketException catch (error) {
    throw FtpUploadException('NETWORK_ERROR', 'FTP 网络错误：${error.message}');
  } on TimeoutException {
    throw const FtpUploadException('NETWORK_ERROR', 'FTP 连接超时');
  } finally {
    if (connected) {
      await client.disconnect();
    }
  }
}

Future<List<FTPEntry>> _listDirectoryEntries(FTPConnect client) async {
  try {
    return await client.listDirectoryContent();
  } on FTPConnectException {
    // 与 Android 客户端一致：MLSD 不可用时降级到广泛支持的 LIST。
    client.listCommand = ListCommand.list;
    return client.listDirectoryContent();
  }
}

Future<void> _changeToVirtualDirectory(FTPConnect client, String path) async {
  final serverPath = _serverDirectory(path);
  if (serverPath == null) return;
  final changed = await client.changeDirectory(serverPath);
  if (!changed) {
    throw FtpUploadException('DIRECTORY_NOT_FOUND', '无法打开目录：$path');
  }
}

FtpUploadException _mapFtpConnectException(FTPConnectException error) {
  final detail = [error.message, error.response]
      .whereType<String>()
      .where((item) => item.trim().isNotEmpty)
      .join('：');
  final normalized = detail.toLowerCase();
  if (normalized.contains('wrong username') ||
      normalized.contains('wrong account') ||
      normalized.contains('530')) {
    return FtpUploadException('AUTH_FAILED', detail);
  }
  if (normalized.contains('timeout') ||
      normalized.contains('could not connect') ||
      normalized.contains('connection refused')) {
    return FtpUploadException('NETWORK_ERROR', detail);
  }
  return FtpUploadException('FTP_ERROR', detail);
}

String _normalizeDirectory(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty || trimmed == '/') return '/';
  final prefixed = trimmed.startsWith('/') ? trimmed : '/$trimmed';
  return prefixed
      .replaceAll(RegExp(r'/{2,}'), '/')
      .replaceFirst(RegExp(r'/$'), '');
}

String? _serverDirectory(String path) {
  final normalized = _normalizeDirectory(path);
  if (normalized == '/') return null;
  return normalized.substring(1);
}

String _childPath(String directory, String name) {
  final normalized = _normalizeDirectory(directory);
  return normalized == '/' ? '/$name' : '$normalized/$name';
}

String _parentDirectory(String path) {
  final normalized = _normalizeDirectory(path);
  final index = normalized.lastIndexOf('/');
  return index <= 0 ? '/' : normalized.substring(0, index);
}

String _fileName(String path) {
  final normalized = _normalizeDirectory(path);
  final name = normalized.substring(normalized.lastIndexOf('/') + 1);
  if (name.isEmpty) {
    throw const FtpUploadException('INVALID_ARGUMENT', '文件名不能为空');
  }
  return name;
}

String _localFileName(String path) {
  final name = path.split(Platform.pathSeparator).last;
  if (name.isEmpty) {
    throw const FtpUploadException('INVALID_ARGUMENT', '本地文件名不能为空');
  }
  return name;
}
