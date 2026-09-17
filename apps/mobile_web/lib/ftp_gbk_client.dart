import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gbk_codec/gbk_codec.dart';

enum GbkFtpEntryType { file, directory, link, unknown }

class GbkFtpEntry {
  const GbkFtpEntry({
    required this.name,
    required this.type,
    required this.size,
  });

  final String name;
  final GbkFtpEntryType type;
  final int size;
}

class GbkFtpException implements Exception {
  const GbkFtpException(this.message, {this.response, this.code});

  final String message;
  final String? response;
  final int? code;

  @override
  String toString() => message;
}

class GbkFtpClient {
  GbkFtpClient({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.timeoutSeconds,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final int timeoutSeconds;
  final List<int> _controlBuffer = <int>[];

  Socket? _controlSocket;
  StreamIterator<Uint8List>? _controlChunks;

  Future<bool> connect() async {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: Duration(seconds: timeoutSeconds),
      );
      _controlSocket = socket;
      _controlChunks = StreamIterator<Uint8List>(socket);

      var response = await _readResponse();
      _requirePositiveReply(response, 'FTP 服务器拒绝连接');

      response = await _sendCommand('USER $username');
      if (response.code == 331) {
        response = await _sendCommand('PASS $password');
      }
      _requirePositiveReply(response, 'FTP 登录失败');

      response = await _sendCommand('TYPE I');
      _requirePositiveReply(response, 'FTP 无法切换到二进制传输模式');
      return true;
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  Future<void> disconnect() async {
    final iterator = _controlChunks;
    final socket = _controlSocket;
    _controlChunks = null;
    _controlSocket = null;
    socket?.destroy();
    if (iterator != null) {
      await iterator.cancel();
    }
  }

  Future<String> currentDirectory() async {
    final response = await _sendCommand('PWD');
    _requirePositiveReply(response, '无法获取 FTP 当前目录');
    final match = RegExp(r'"([^"]*)"').firstMatch(response.message);
    if (match == null) {
      throw GbkFtpException('FTP 服务器返回的当前目录格式无效', response: response.message);
    }
    return match.group(1)!;
  }

  Future<bool> changeDirectory(String path) async {
    final response = await _sendCommand('CWD $path');
    return response.isPositiveCompletion;
  }

  Future<List<GbkFtpEntry>> listDirectoryContent() async {
    try {
      return await _listWithCommand('MLSD', _parseMlsdListing);
    } on GbkFtpException catch (error) {
      if (!_canFallbackToList(error.code)) {
        rethrow;
      }
      return _listWithCommand('LIST', _parseListListing);
    }
  }

  Future<bool> uploadFile(File file, String remoteName) async {
    final dataPort = await _openDataPort();
    await _sendCommandWithoutWaiting('STOR $remoteName');
    final dataSocket = await _connectDataSocket(dataPort);
    try {
      final response = await _readResponse();
      _requireTransferReply(response);
      await dataSocket.addStream(file.openRead());
      await dataSocket.flush();
      await dataSocket.close();
      await _finishTransfer(response);
      return true;
    } finally {
      dataSocket.destroy();
    }
  }

  Future<bool> downloadFile(String remoteName, File localFile) async {
    final dataPort = await _openDataPort();
    await _sendCommandWithoutWaiting('RETR $remoteName');
    final dataSocket = await _connectDataSocket(dataPort);
    IOSink? sink;
    try {
      final response = await _readResponse();
      _requireTransferReply(response);
      sink = localFile.openWrite(mode: FileMode.writeOnly);
      await for (final chunk in dataSocket) {
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      await _finishTransfer(response);
      return true;
    } finally {
      if (sink != null) {
        await sink.close();
      }
      dataSocket.destroy();
    }
  }

  Future<List<GbkFtpEntry>> _listWithCommand(
    String command,
    List<GbkFtpEntry> Function(String listing) parser,
  ) async {
    final dataPort = await _openDataPort();
    await _sendCommandWithoutWaiting(command);
    final dataSocket = await _connectDataSocket(dataPort);
    try {
      final response = await _readResponse();
      _requireTransferReply(response);
      final bytes = <int>[];
      await for (final chunk in dataSocket) {
        bytes.addAll(chunk);
      }
      await _finishTransfer(response);
      return parser(gbk_bytes.decode(bytes));
    } finally {
      dataSocket.destroy();
    }
  }

  Future<int> _openDataPort() async {
    final response = await _sendCommand('PASV');
    _requirePositiveReply(response, 'FTP 被动模式开启失败');
    return _passivePort(response.message);
  }

  Future<Socket> _connectDataSocket(int port) {
    return Socket.connect(
      host,
      port,
      timeout: Duration(seconds: timeoutSeconds),
    );
  }

  Future<void> _finishTransfer(_FtpReply response) async {
    if (response.code == 125 || response.code == 150) {
      final completion = await _readResponse();
      _requirePositiveReply(completion, 'FTP 数据传输失败');
    }
  }

  Future<_FtpReply> _sendCommand(String command) async {
    await _sendCommandWithoutWaiting(command);
    return _readResponse();
  }

  Future<void> _sendCommandWithoutWaiting(String command) async {
    final socket = _requireControlSocket();
    socket.add(<int>[...gbk_bytes.encode(command), 13, 10]);
    await socket.flush();
  }

  Future<_FtpReply> _readResponse() async {
    final firstLine = gbk_bytes.decode(await _readLine());
    if (firstLine.length < 3) {
      throw GbkFtpException('FTP 服务器响应格式无效', response: firstLine);
    }
    final code = int.tryParse(firstLine.substring(0, 3));
    if (code == null) {
      throw GbkFtpException('FTP 服务器响应码无效', response: firstLine);
    }

    final lines = <String>[firstLine];
    if (firstLine.length >= 4 && firstLine[3] == '-') {
      final endMarker = '$code ';
      while (true) {
        final line = gbk_bytes.decode(await _readLine());
        lines.add(line);
        if (line.startsWith(endMarker)) {
          break;
        }
      }
    }
    return _FtpReply(code, lines.join('\n'));
  }

  Future<List<int>> _readLine() async {
    while (true) {
      final lineEnd = _controlBuffer.indexOf(10);
      if (lineEnd >= 0) {
        final line = _controlBuffer.sublist(0, lineEnd);
        _controlBuffer.removeRange(0, lineEnd + 1);
        if (line.isNotEmpty && line.last == 13) {
          line.removeLast();
        }
        return line;
      }

      final iterator = _controlChunks;
      if (iterator == null || !await iterator.moveNext()) {
        throw const GbkFtpException('FTP 控制连接已关闭');
      }
      _controlBuffer.addAll(iterator.current);
    }
  }

  Socket _requireControlSocket() {
    final socket = _controlSocket;
    if (socket == null) {
      throw const GbkFtpException('FTP 尚未连接');
    }
    return socket;
  }

  static void _requirePositiveReply(_FtpReply response, String message) {
    if (!response.isPositiveCompletion) {
      throw GbkFtpException(message,
          response: response.message, code: response.code);
    }
  }

  static void _requireTransferReply(_FtpReply response) {
    if (response.code != 125 &&
        response.code != 150 &&
        !response.isPositiveCompletion) {
      throw GbkFtpException('FTP 数据传输失败',
          response: response.message, code: response.code);
    }
  }

  static int _passivePort(String message) {
    final match = RegExp(r'\((?:\d+,){4}(\d+),(\d+)\)').firstMatch(message);
    if (match == null) {
      throw GbkFtpException('FTP 被动模式响应格式无效', response: message);
    }
    final high = int.parse(match.group(1)!);
    final low = int.parse(match.group(2)!);
    return high * 256 + low;
  }

  static bool _canFallbackToList(int? code) {
    return code == 500 || code == 501 || code == 502 || code == 504;
  }

  static List<GbkFtpEntry> _parseMlsdListing(String listing) {
    final entries = <GbkFtpEntry>[];
    for (final rawLine in const LineSplitter().convert(listing)) {
      final line = rawLine.trimRight();
      if (line.trim().isEmpty) {
        continue;
      }
      final separator = line.indexOf(' ');
      if (separator <= 0 || separator == line.length - 1) {
        continue;
      }
      var type = GbkFtpEntryType.unknown;
      var size = 0;
      for (final fact in line.substring(0, separator).split(';')) {
        final parts = fact.split('=');
        if (parts.length < 2) {
          continue;
        }
        final value = parts.sublist(1).join('=').toLowerCase();
        switch (parts.first.toLowerCase()) {
          case 'type':
            type = value == 'dir'
                ? GbkFtpEntryType.directory
                : value == 'file'
                    ? GbkFtpEntryType.file
                    : GbkFtpEntryType.link;
          case 'size':
            size = int.tryParse(value) ?? 0;
        }
      }
      entries.add(GbkFtpEntry(
        name: line.substring(separator + 1),
        type: type,
        size: size,
      ));
    }
    return entries;
  }

  static List<GbkFtpEntry> _parseListListing(String listing) {
    final entries = <GbkFtpEntry>[];
    final unixPattern = RegExp(
      r'^([\-ld])\S*\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4})\s+(.+)$',
    );
    final windowsPattern = RegExp(
      r'^\d{2}-\d{2}-\d{2}\s+\d{2}:\d{2}(?:AM|PM)\s+(<DIR>|\d+)\s+(.+)$',
      caseSensitive: false,
    );
    for (final rawLine in const LineSplitter().convert(listing)) {
      final line = rawLine.trimRight();
      final unixMatch = unixPattern.firstMatch(line);
      if (unixMatch != null) {
        final marker = unixMatch.group(1)!;
        entries.add(GbkFtpEntry(
          name: unixMatch.group(3)!,
          type: marker == 'd'
              ? GbkFtpEntryType.directory
              : marker == 'l'
                  ? GbkFtpEntryType.link
                  : GbkFtpEntryType.file,
          size: int.tryParse(unixMatch.group(2)!) ?? 0,
        ));
        continue;
      }
      final windowsMatch = windowsPattern.firstMatch(line);
      if (windowsMatch != null) {
        final sizeOrDirectory = windowsMatch.group(1)!;
        entries.add(GbkFtpEntry(
          name: windowsMatch.group(2)!,
          type: sizeOrDirectory.toUpperCase() == '<DIR>'
              ? GbkFtpEntryType.directory
              : GbkFtpEntryType.file,
          size: int.tryParse(sizeOrDirectory) ?? 0,
        ));
      }
    }
    return entries;
  }
}

class _FtpReply {
  const _FtpReply(this.code, this.message);

  final int code;
  final String message;

  bool get isPositiveCompletion => code >= 200 && code < 300;
}
